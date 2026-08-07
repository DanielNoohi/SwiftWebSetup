#!/usr/bin/env bash
#
# SwiftWebSetup - install.sh
# One-command entrypoint: fetch repo scripts and run host or Docker WordPress bootstrap.
#
# Unattended:
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --unattended
# Interactive:
#   curl -fsSL .../install.sh -o /tmp/swiftweb-install.sh && sudo bash /tmp/swiftweb-install.sh

set -euo pipefail

if command -v file >/dev/null 2>&1 && file "$0" | grep -q "CRLF"; then
	echo "[*] Converting script line endings from CRLF to LF..."
	tmpfix=$(mktemp)
	tr -d '\r' <"$0" >"$tmpfix"
	chmod +x "$tmpfix"
	exec bash "$tmpfix" "$@"
	exit
fi

REPO_URL="https://github.com/DanielNoohi/SwiftWebSetup"
RAW_URL="https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main"
REPO_DIR="${SWIFTWEB_REPO_DIR:-/tmp/SwiftWebSetup}"

DEPLOY_MODE="host"
INNER_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}$*${NC}" >&2; }
warn() { echo -e "${YELLOW}$*${NC}" >&2; }
error() { echo -e "${RED}$*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}" >&2; }

show_help() {
	cat <<EOF
SwiftWebSetup - One-Command WordPress Production Bootstrap (Ubuntu VPS)

USAGE:
  curl -fsSL ${RAW_URL}/install.sh -o /tmp/swiftweb-install.sh
  sudo bash /tmp/swiftweb-install.sh [OPTIONS]

  curl -fsSL ${RAW_URL}/install.sh | sudo bash -s -- --unattended [OPTIONS]

OPTIONS:
  --docker            Docker deploy (default: native host install)
  --unattended        Non-interactive
  --force             Wipe and reinstall
  --backup-only       (host) backup web root + DB, exit
  --domain DOMAIN     Site domain
  --title TITLE       Site title
  --admin USER        Admin username
  --email EMAIL       Admin email
  --name NAME         (docker) project prefix
  --port PORT         (docker) published port
  --ssl               (host) HTTPS via certbot (needs --domain)
  --fail2ban          (host) install fail2ban
  --auto-updates      (host) enable unattended-upgrades
  --dry-run           Preview only
  -h, --help          Show help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--docker)
		DEPLOY_MODE="docker"
		shift
		;;
	--unattended | --force | --dry-run | --ssl | --backup-only | --fail2ban | --auto-updates)
		INNER_ARGS+=("$1")
		shift
		;;
	--domain | --title | --admin | --email | --name | --port)
		[[ $# -ge 2 ]] || {
			error "Missing value for $1"
			exit 1
		}
		INNER_ARGS+=("$1" "$2")
		shift 2
		;;
	-h | --help)
		show_help
		exit 0
		;;
	*)
		error "Unknown option: $1"
		show_help
		exit 1
		;;
	esac
done

if [[ ${EUID} -ne 0 ]]; then
	error "This script must be run as root (use sudo)"
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/host-install.sh" && -f "$SCRIPT_DIR/docker-way.sh" && -f "$SCRIPT_DIR/lib/common.sh" ]]; then
	REPO_DIR="$SCRIPT_DIR"
	info "Using local checkout: $REPO_DIR"
else
	info "Installing base dependencies (curl, git, ca-certificates)..."
	apt-get update -qq
	apt-get install -y -qq curl ca-certificates git >/dev/null

	info "Fetching SwiftWebSetup into ${REPO_DIR}..."
	if [[ -d "$REPO_DIR/.git" ]]; then
		git -C "$REPO_DIR" fetch origin
		git -C "$REPO_DIR" reset --hard origin/main
	elif [[ -e "$REPO_DIR" ]]; then
		warn "Removing incomplete ${REPO_DIR}..."
		rm -rf "$REPO_DIR"
		git clone --depth 1 "$REPO_URL" "$REPO_DIR"
	else
		if ! git clone --depth 1 "$REPO_URL" "$REPO_DIR"; then
			warn "git clone failed — falling back to raw script download..."
			mkdir -p "$REPO_DIR/lib"
			curl -fsSL "$RAW_URL/host-install.sh" -o "$REPO_DIR/host-install.sh"
			curl -fsSL "$RAW_URL/web-install.sh" -o "$REPO_DIR/web-install.sh"
			curl -fsSL "$RAW_URL/docker-way.sh" -o "$REPO_DIR/docker-way.sh"
			curl -fsSL "$RAW_URL/lib/common.sh" -o "$REPO_DIR/lib/common.sh"
		fi
	fi
fi

chmod +x "$REPO_DIR"/host-install.sh "$REPO_DIR"/web-install.sh "$REPO_DIR"/docker-way.sh 2>/dev/null || true

info "Starting ${DEPLOY_MODE} deployment..."
set +e
if [[ "$DEPLOY_MODE" == "docker" ]]; then
	bash "$REPO_DIR/docker-way.sh" "${INNER_ARGS[@]}"
	rc=$?
else
	bash "$REPO_DIR/host-install.sh" "${INNER_ARGS[@]}"
	rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
	error "Installer failed (exit $rc)"
	exit "$rc"
fi

success "Deployment complete!"
info "Credentials: /root/swiftwebsetup-credentials.txt (host) or /root/swiftwebsetup-docker-credentials.txt (Docker)"
exit 0
