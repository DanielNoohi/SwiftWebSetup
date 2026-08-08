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

# True in CI even when sudo strips CI/GITHUB_ACTIONS from the environment.
is_ci() {
	[[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
	[[ -n "${RUNNER_OS:-}" || -n "${RUNNER_NAME:-}" ]] && return 0
	# GitHub-hosted Actions workspace layout
	[[ -d /home/runner/work ]] && return 0
	return 1
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
	local len=32
	[[ $# -ge 1 ]] && len="$1"
	local pass=""
	# Alphanumeric only: safe in .env, SQL single-quoted strings, and shell.
	if command -v python3 &>/dev/null; then
		pass=$(
			python3 - "$len" <<'PY'
import secrets, string, sys
n = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(n)))
PY
		)
	else
		pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len")
	fi
	printf '%s' "$pass"
}

server_ip() {
	# Prefer loopback in CI so verify curls a reachable address on the runner
	if is_ci; then
		printf '%s' "127.0.0.1"
		return 0
	fi
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
	local b
	b="${1}.backup.$(date +%Y%m%d_%H%M%S)"
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

# Strong HTTP verification: WordPress markers, reject default test pages.
# Callers should already have confirmed `wp core is-installed` when possible.
verify_wordpress_http() {
	local url="$1"
	local body code login_code
	local urls=("$url")
	# Always also try loopback when verifying a non-loopback URL
	if [[ "$url" != *"127.0.0.1"* && "$url" != *"localhost"* ]]; then
		local port
		port="${WORDPRESS_PORT:-80}"
		if [[ "$port" == "80" ]]; then
			urls+=("http://127.0.0.1")
		else
			urls+=("http://127.0.0.1:${port}")
		fi
	fi

	info "Verifying WordPress at ${url}..."

	local u ok=false
	for u in "${urls[@]}"; do
		body=$(curl -fsSL -L --max-time 25 "$u" 2>/dev/null || true)
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$u" 2>/dev/null || echo "000")
		login_code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 25 "${u%/}/wp-login.php" 2>/dev/null || echo "000")

		if [[ -z "$body" ]]; then
			continue
		fi
		if printf '%s' "$body" | grep -qiE 'It works!|Apache2 (Ubuntu|Debian) Default Page|Welcome to nginx!'; then
			continue
		fi
		# wp-login.php may 302 depending on siteurl; accept success-class codes
		if [[ "$login_code" != "200" && "$login_code" != "301" && "$login_code" != "302" ]]; then
			continue
		fi
		# Prefer explicit WP markers; also accept a non-default page when login works
		# (callers typically already ran `wp core is-installed`).
		if printf '%s' "$body" | grep -qiE 'wp-content|wp-includes|wp-json|/wp-login|wp-block|wp-embed'; then
			ok=true
		elif [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
			ok=true
		fi
		if [[ "$ok" == true ]]; then
			success "Verified: ${u} serves WordPress (homepage HTTP ${code}, wp-login HTTP ${login_code})"
			break
		fi
	done

	if [[ "$ok" != true ]]; then
		error "VERIFICATION FAILED: could not confirm WordPress at ${url}"
		error "Debug: curl -I ${url} => $(curl -sI --max-time 10 "$url" 2>/dev/null | head -n 5 | tr '\n' ' ')"
		error "Debug: wp-login => HTTP $(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 "${url%/}/wp-login.php" 2>/dev/null || echo 000)"
		error "Debug: body head => $(curl -fsSL -L --max-time 10 "$url" 2>/dev/null | head -c 240 | tr '\n' ' ')"
		return 1
	fi
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

# Prompt for site settings (interactive). Flags/env already set win.
# Sets: DOMAIN SITE_TITLE ADMIN_USER ADMIN_EMAIL ADMIN_PASSWORD SSL (maybe)
collect_site_config() {
	local default_email
	default_email="admin@$(hostname -f 2>/dev/null | cut -d' ' -f1 || echo localhost)"
	if [[ "${UNATTENDED:-false}" == true ]]; then
		SITE_TITLE="${SITE_TITLE:-My WordPress Site}"
		ADMIN_USER="${ADMIN_USER:-admin}"
		ADMIN_EMAIL="${ADMIN_EMAIL:-$default_email}"
		DOMAIN="${DOMAIN:-}"
		[[ -z "${ADMIN_PASSWORD:-}" ]] && ADMIN_PASSWORD=$(gen_password 32)
		return 0
	fi

	local tmp
	if [[ -z "${SITE_TITLE:-}" ]]; then
		read -rp "Site title [My WordPress Site]: " tmp
		SITE_TITLE="${tmp:-My WordPress Site}"
	fi
	if [[ -z "${ADMIN_USER:-}" ]]; then
		read -rp "Admin username [admin]: " tmp
		ADMIN_USER="${tmp:-admin}"
	fi
	if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
		local entered="" confirm=""
		read -s -r -p "Admin password (Enter to auto-generate): " entered
		echo
		if [[ -n "$entered" ]]; then
			read -s -r -p "Confirm admin password: " confirm
			echo
			if [[ "$entered" != "$confirm" ]]; then
				error "Passwords do not match"
				exit 1
			fi
			ADMIN_PASSWORD="$entered"
		else
			ADMIN_PASSWORD=$(gen_password 32)
			info "Generated admin password (saved to credentials file after success)"
		fi
	fi
	if [[ -z "${ADMIN_EMAIL:-}" ]]; then
		read -rp "Admin email [${default_email}]: " tmp
		ADMIN_EMAIL="${tmp:-$default_email}"
	fi
	if [[ -z "${DOMAIN:-}" ]]; then
		read -rp "Domain (leave empty for server IP): " tmp
		DOMAIN="${tmp:-}"
	fi
	# HTTPS: if domain set and SSL not forced; host path only (Docker sets SKIP_SSL_PROMPT)
	if [[ -n "${DOMAIN}" && "${SSL:-false}" != true && "${SKIP_SSL_PROMPT:-false}" != true ]]; then
		read -rp "Enable HTTPS (Let's Encrypt) for ${DOMAIN}? [Y/n]: " tmp
		tmp="${tmp:-Y}"
		if [[ "$tmp" =~ ^[Yy]$ ]]; then
			SSL=true
		fi
	fi
}

# Rewrite credentials file (call ONLY after successful verify)
save_credentials() {
	local mode="${1:-host}"
	ensure_credentials_file
	{
		echo "# SwiftWebSetup credentials — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "# Mode: ${mode}"
		echo "# KEEP THIS FILE SECRET (mode 0600)"
		echo "Site URL: ${SITE_URL}"
		echo "Admin URL: ${SITE_URL}/wp-admin/"
		echo "Site title: ${SITE_TITLE}"
		echo "Admin user: ${ADMIN_USER}"
		echo "Admin pass: ${ADMIN_PASSWORD}"
		echo "Admin email: ${ADMIN_EMAIL}"
		echo "DB name: ${WP_DB_NAME}"
		echo "DB user: ${WP_DB_USER}"
		echo "DB pass: ${WP_DB_PASSWORD}"
		if [[ "$mode" == "host" ]]; then
			echo "MariaDB root: unix_socket (run: sudo mariadb) — generated token for records: ${MYSQL_ROOT_PASSWORD}"
		else
			echo "MariaDB root: ${MYSQL_ROOT_PASSWORD}"
		fi
		[[ -n "${EXTRA_CRED_LINES:-}" ]] && printf '%s\n' "${EXTRA_CRED_LINES}"
	} >"${CREDENTIALS_FILE}"
	chmod 600 "${CREDENTIALS_FILE}"
}

print_summary_card() {
	local mode="${1:-host}"
	echo >&2
	success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	success "  WordPress is live"
	success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	info "  Site:        ${SITE_URL}"
	info "  Admin:       ${SITE_URL}/wp-admin/"
	info "  Username:    ${ADMIN_USER}"
	if [[ "${UNATTENDED:-false}" == true ]]; then
		info "  Password:    (see credentials file)"
	else
		info "  Password:    ${ADMIN_PASSWORD}"
	fi
	info "  Credentials: ${CREDENTIALS_FILE} (0600)"
	[[ -n "${LOG_FILE:-}" ]] && info "  Log:         ${LOG_FILE}"
	[[ "$mode" == "docker" && -n "${COMPOSE_DIR:-}" ]] && info "  Compose:     ${COMPOSE_DIR}"
	success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo >&2
}

install_fail_hint() {
	# Prefer args from: trap 'install_fail_hint "$LINENO" "$BASH_COMMAND"' ERR
	local line="${1:-${BASH_LINENO[0]:-?}}"
	local cmd="${2:-${BASH_COMMAND:-unknown}}"
	error "Install did not finish cleanly (line ${line}: ${cmd})."
	warn "Fix the error above, then re-run with --force to wipe and retry (or restore from a backup)."
}
