#!/usr/bin/env bash
# SwiftWebSetup - shared helpers (sourced by installers; do not execute directly)
# shellcheck shell=bash

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# Optional globals set by callers: LOG_FILE, CREDENTIALS_FILE, DRY_RUN,
# WP_DB_PASSWORD, ADMIN_PASSWORD, MYSQL_ROOT_PASSWORD, DOMAIN, WORDPRESS_PORT

log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	echo -e "${timestamp} [${level}] ${msg}" >&2
	if [[ -n "${LOG_FILE:-}" ]]; then
		# Strip ANSI for the log file
		local plain
		plain=$(echo -e "${msg}" | sed 's/\x1b\[[0-9;]*m//g')
		echo "${timestamp} [${level}] ${plain}" >>"${LOG_FILE}" 2>/dev/null || true
	fi
}

info() { log "INFO" "${BLUE}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

credential() {
	local file="${CREDENTIALS_FILE:-}"
	[[ -n "$file" ]] || {
		error "CREDENTIALS_FILE not set"
		return 1
	}
	echo "$*" >>"$file"
}

# Scrub known secrets from a command line before logging
scrub_secrets() {
	local line="$1"
	[[ -n "${WP_DB_PASSWORD:-}" ]] && line=${line//"$WP_DB_PASSWORD"/********}
	[[ -n "${ADMIN_PASSWORD:-}" ]] && line=${line//"$ADMIN_PASSWORD"/********}
	[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] && line=${line//"$MYSQL_ROOT_PASSWORD"/********}
	printf '%s' "$line"
}

log_cmd() {
	local line
	line=$(scrub_secrets "$*")
	if [[ -n "${LOG_FILE:-}" ]]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') [CMD] ${line}" >>"${LOG_FILE}" 2>/dev/null || true
	fi
}

# Array-safe runner (no eval). Honors DRY_RUN.
run_cmd() {
	if [[ "${DRY_RUN:-false}" == true ]]; then
		info "[DRY-RUN] $*"
		return 0
	fi
	log_cmd "$*"
	"$@" || {
		error "Command failed: $(scrub_secrets "$*")"
		return 1
	}
}

check_root() {
	if [[ ${EUID} -ne 0 ]]; then
		error "Please run as root (sudo)."
		exit 1
	fi
}

check_os() {
	[[ -f /etc/os-release ]] || {
		error "Cannot determine OS"
		exit 1
	}
	# shellcheck disable=SC1091
	. /etc/os-release
	if [[ "$ID" != "ubuntu" ]] || ! [[ "$VERSION_ID" =~ ^(20\.04|22\.04|24\.04)$ ]]; then
		warn "Untested on ${PRETTY_NAME}. Supported: Ubuntu 20.04/22.04/24.04."
		if [[ "${UNATTENDED:-false}" != true ]]; then
			read -rp "Continue anyway? (y/N) " ch
			[[ "$ch" =~ ^[Yy]$ ]] || exit 1
		fi
	fi
	info "OS: ${PRETTY_NAME}"
}

ensure_python() {
	if ! command -v python3 &>/dev/null; then
		info "Installing python3 (password generation)..."
		run_cmd apt-get update -qq
		run_cmd apt-get install -y python3
	fi
}

gen_password() {
	local len="${1:-32}" pass=""
	if command -v python3 &>/dev/null; then
		pass=$(python3 - "$len" <<'PY'
import secrets, string, sys
n = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits + "!@#%^*_-+=<>~"
print("".join(secrets.choice(alphabet) for _ in range(n)))
PY
		)
	else
		pass=$(tr -dc 'A-Za-z0-9!@#%^*_-+=<>~' </dev/urandom | head -c "$len")
	fi
	printf '%s' "$pass"
}

server_ip() {
	hostname -I 2>/dev/null | awk '{print $1}'
}

get_site_url() {
	if [[ -n "${DOMAIN:-}" ]]; then
		printf 'http://%s' "$DOMAIN"
	else
		local ip port
		ip=$(server_ip)
		port="${WORDPRESS_PORT:-80}"
		if [[ "$port" == "80" ]]; then
			printf 'http://%s' "$ip"
		else
			printf 'http://%s:%s' "$ip" "$port"
		fi
	fi
}

wait_for_active() {
	local svc="$1" t="${2:-30}" i=0
	while ! systemctl is-active --quiet "$svc"; do
		sleep 1
		((i++)) || true
		if [[ $i -ge $t ]]; then
			error "Service $svc not active after ${t}s"
			return 1
		fi
	done
	success "Service $svc active"
}

backup_dir() {
	[[ -e "$1" ]] || return 0
	local b="${1}.backup.$(date +%Y%m%d_%H%M%S)"
	run_cmd cp -a "$1" "$b"
	info "Backed up $1 -> $b"
}

# Remove Apache/Debian/nginx welcome pages that shadow index.php
clear_default_indexes() {
	local root="${1:-/var/www/html}"
	[[ "${DRY_RUN:-false}" == true ]] && {
		info "[DRY-RUN] clear default indexes in $root"
		return 0
	}
	rm -f "$root/index.html" \
		"$root/index.html.debian" \
		"$root/index.htm" \
		"$root/index.nginx-debian.html" \
		2>/dev/null || true
}

# Strong HTTP verification: WordPress markers, reject default test pages
verify_wordpress_http() {
	local url="$1"
	local body code login_code
	info "Verifying WordPress at ${url}..."

	body=$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || echo "000")

	if echo "$body" | grep -qiE 'It works!|Apache2 (Ubuntu|Debian) Default Page|Welcome to nginx!'; then
		error "VERIFICATION FAILED: default web-server test page detected at ${url}"
		return 1
	fi
	if [[ "$code" != "200" ]] && [[ "$code" != "301" ]] && [[ "$code" != "302" ]]; then
		error "VERIFICATION FAILED: ${url} returned HTTP ${code}"
		return 1
	fi
	if ! echo "$body" | grep -qE 'wp-content|wp-includes|wp-json|wordpress'; then
		error "VERIFICATION FAILED: ${url} does not look like WordPress"
		return 1
	fi

	login_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${url%/}/wp-login.php" 2>/dev/null || echo "000")
	if [[ "$login_code" != "200" ]]; then
		error "VERIFICATION FAILED: wp-login.php returned HTTP ${login_code}"
		return 1
	fi

	success "Verified: ${url} serves WordPress (homepage + wp-login.php)"
	return 0
}

ensure_credentials_file() {
	local f="${CREDENTIALS_FILE:?CREDENTIALS_FILE required}"
	run_cmd touch "$f"
	run_cmd chmod 600 "$f"
	local mode
	mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%OLp' "$f" 2>/dev/null || echo "")
	if [[ -n "$mode" && "$mode" != "600" ]]; then
		error "Could not set credentials file to 0600 (got $mode)"
		exit 1
	fi
}
