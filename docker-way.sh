#!/usr/bin/env bash
#
# SwiftWebSetup - docker-way.sh
# Docker WordPress + MariaDB via Compose; install completed with wordpress:cli
#
# Usage: sudo bash docker-way.sh [--dry-run] [--unattended] [--force]
#          [--name NAME] [--port PORT] [--domain D] [--title T] [--admin U] [--email E]

set -euo pipefail

# CRLF self-heal (literal backslash-r)
if command -v file >/dev/null 2>&1 && file "$0" | grep -q "CRLF"; then
	echo "[*] Converting script line endings from CRLF to LF..."
	tmpfix=$(mktemp)
	tr -d '\r' <"$0" >"$tmpfix"
	chmod +x "$tmpfix"
	exec bash "$tmpfix" "$@"
	exit
fi

_SWIFTWEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SWIFTWEB_ROOT}/lib/common.sh"

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-docker-way.log"
CREDENTIALS_FILE="/root/swiftwebsetup-docker-credentials.txt"
DRY_RUN=false
UNATTENDED=false
FORCE=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""
PROJECT_NAME="${PROJECT_NAME:-swiftweb}"
WORDPRESS_PORT="${WORDPRESS_PORT:-80}"
COMPOSE_DIR="/opt/${PROJECT_NAME}"

# Floating php8.3 tags stay aligned between app + CLI (avoid hard skew vs LAMP latest)
WP_IMAGE="${WP_IMAGE:-wordpress:php8.3-apache}"
WP_CLI_IMAGE="${WP_CLI_IMAGE:-wordpress:cli-php8.3}"
DB_IMAGE="${DB_IMAGE:-mariadb:10.11}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) DRY_RUN=true; shift ;;
		--unattended) UNATTENDED=true; shift ;;
		--force) FORCE=true; shift ;;
		--name)
			PROJECT_NAME="$2"
			COMPOSE_DIR="/opt/${PROJECT_NAME}"
			shift 2
			;;
		--port) WORDPRESS_PORT="$2"; shift 2 ;;
		--domain) DOMAIN="$2"; shift 2 ;;
		--title) SITE_TITLE="$2"; shift 2 ;;
		--admin) ADMIN_USER="$2"; shift 2 ;;
		--email) ADMIN_EMAIL="$2"; shift 2 ;;
		-h | --help)
			echo "Usage: sudo bash $SCRIPT_NAME [opts]"
			echo "  --dry-run      preview (no changes)"
			echo "  --unattended   non-interactive (env vars)"
			echo "  --force        recreate project (wipe volumes) and reinstall"
			echo "  --name NAME    project prefix (default: swiftweb)"
			echo "  --port PORT    host port for WordPress (default: 80)"
			echo "  --domain D     site domain (default: server IP)"
			echo "  --title T      site title"
			echo "  --admin U      admin username"
			echo "  --email E      admin email"
			exit 0
			;;
		*)
			error "Unknown option: $1 (see --help)"
			exit 1
			;;
		esac
	done
fi

ask_password() {
	if [[ "$UNATTENDED" == true ]] || [[ -n "${ADMIN_PASSWORD:-}" ]]; then
		[[ -z "${ADMIN_PASSWORD:-}" ]] && ADMIN_PASSWORD=$(gen_password)
		return
	fi
	local entered=""
	read -s -r -p "Admin password (Enter to auto-generate): " entered
	echo
	if [[ -n "$entered" ]]; then
		ADMIN_PASSWORD="$entered"
	else
		ADMIN_PASSWORD=$(gen_password)
	fi
}

install_docker() {
	if command -v docker &>/dev/null && docker compose version &>/dev/null; then
		info "Docker + Compose plugin already installed"
		return 0
	fi
	info "Installing Docker..."
	run_cmd apt-get update
	run_cmd apt-get install -y ca-certificates curl gnupg lsb-release
	run_cmd install -d -m 0755 /etc/apt/keyrings
	local keyring="/etc/apt/keyrings/docker.gpg"
	local list="/etc/apt/sources.list.d/docker.list"
	if [[ ! -f "$keyring" ]]; then
		run_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker-gpg
		run_cmd gpg --dearmor -o "$keyring" /tmp/docker-gpg
		run_cmd chmod a+r "$keyring"
	fi
	if [[ ! -f "$list" ]]; then
		local arch codename
		arch=$(dpkg --print-architecture)
		codename=$(lsb_release -cs)
		printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/ubuntu %s stable\n' \
			"$arch" "$keyring" "$codename" >"$list"
	fi
	run_cmd apt-get update
	run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
	run_cmd systemctl enable --now docker
	success "Docker installed"
}

# Prints ONLY the directory path on stdout (logs go to stderr via info/)
create_compose_file() {
	local dir="$COMPOSE_DIR"
	info "Creating project directory $dir"
	run_cmd mkdir -p "$dir"

	if [[ "$DRY_RUN" == true ]]; then
		printf '%s\n' "$dir"
		return 0
	fi

	cat >"$dir/docker-compose.yml" <<EOF
services:
  db:
    image: ${DB_IMAGE}
    container_name: ${PROJECT_NAME}-db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: \${WP_DB_NAME}
      MARIADB_USER: \${WP_DB_USER}
      MARIADB_PASSWORD: \${WP_DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - ${PROJECT_NAME}_net
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 12

  wordpress:
    image: ${WP_IMAGE}
    container_name: ${PROJECT_NAME}-wordpress
    restart: unless-stopped
    ports:
      - "${WORDPRESS_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: \${WP_DB_NAME}
      WORDPRESS_DB_USER: \${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WP_DB_PASSWORD}
    volumes:
      - wp_data:/var/www/html
    networks:
      - ${PROJECT_NAME}_net
    depends_on:
      db:
        condition: service_healthy

  wpcli:
    image: ${WP_CLI_IMAGE}
    container_name: ${PROJECT_NAME}-wpcli
    restart: "no"
    user: "33:33"
    volumes:
      - wp_data:/var/www/html
    networks:
      - ${PROJECT_NAME}_net
    depends_on:
      - db
      - wordpress
    entrypoint: ["/bin/sh", "-c", "sleep infinity"]

volumes:
  db_data:
  wp_data:

networks:
  ${PROJECT_NAME}_net:
EOF

	cat >"$dir/.env" <<EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
WP_DB_NAME=${WP_DB_NAME}
WP_DB_USER=${WP_DB_USER}
WP_DB_PASSWORD=${WP_DB_PASSWORD}
EOF
	run_cmd chmod 600 "$dir/.env"
	printf '%s\n' "$dir"
}

dc() {
	local dir="$1"
	shift
	docker compose -f "${dir}/docker-compose.yml" "$@"
}

complete_wp_install() {
	local dir="$1" url="$2"
	info "Waiting for wpcli + WordPress files..."
	local t=180 i=0
	while ((i < t)); do
		if dc "$dir" exec -T wpcli wp core version --path=/var/www/html --allow-root >/dev/null 2>&1; then
			break
		fi
		sleep 2
		((i += 2)) || true
	done
	if ((i >= t)); then
		error "wpcli container did not become ready in time"
		dc "$dir" logs wpcli 2>/dev/null | tail -30 || true
		return 1
	fi

	if [[ "$FORCE" != true ]] && dc "$dir" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
		warn "WordPress already installed — leaving site intact (use --force to reinstall)"
		return 0
	fi

	info "Running wp core install via wpcli service..."
	dc "$dir" exec -T wpcli wp core install \
		--path=/var/www/html \
		--url="$url" \
		--title="$SITE_TITLE" \
		--admin_user="$ADMIN_USER" \
		--admin_password="$ADMIN_PASSWORD" \
		--admin_email="$ADMIN_EMAIL" \
		--skip-email --allow-root || {
		error "wp core install failed"
		return 1
	}

	dc "$dir" exec -T wpcli wp rewrite structure '/%postname%/' --path=/var/www/html --hard --allow-root || true
	if [[ -n "$DOMAIN" ]]; then
		dc "$dir" exec -T wpcli wp option update siteurl "$url" --path=/var/www/html --allow-root || true
		dc "$dir" exec -T wpcli wp option update home "$url" --path=/var/www/html --allow-root || true
	fi
	dc "$dir" exec -T wpcli wp plugin delete akismet --path=/var/www/html --allow-root || true
	return 0
}

verify_site() {
	local url="$1" dir="$2"
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] skip live verify"
		return 0
	fi
	if ! dc "$dir" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
		error "VERIFICATION FAILED: wp core is-installed reports NOT installed"
		return 1
	fi
	verify_wordpress_http "$url"
}

configure_firewall() {
	info "Configuring UFW (SSH first, then WordPress port)..."
	run_cmd ufw allow OpenSSH
	run_cmd ufw allow "${WORDPRESS_PORT}/tcp"
	run_cmd ufw --force enable || warn "UFW enable skipped/failed"
	run_cmd ufw status || true
}

main() {
	info "=== SwiftWebSetup: Docker WordPress ==="
	[[ "$DRY_RUN" == true ]] && warn "DRY-RUN: nothing will be changed"

	check_root
	check_os
	ensure_python
	touch "$LOG_FILE" 2>/dev/null || true

	DOMAIN="${DOMAIN:-}"
	SITE_TITLE="${SITE_TITLE:-My WordPress Site}"
	ADMIN_USER="${ADMIN_USER:-admin}"
	ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
	WP_DB_NAME="${WP_DB_NAME:-wordpress}"
	WP_DB_USER="${WP_DB_USER:-wp_user}"
	WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password)}"
	MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password)}"
	ask_password

	SITE_URL="$(get_site_url)"

	ensure_credentials_file
	credential "# SwiftWebSetup Docker credentials - $(date)"
	credential "Site URL:  $SITE_URL"
	credential "Admin user: $ADMIN_USER"
	credential "Admin pass: $ADMIN_PASSWORD"
	credential "Admin email: $ADMIN_EMAIL"
	credential "DB: db=$WP_DB_NAME user=$WP_DB_USER pass=$WP_DB_PASSWORD"
	credential "MariaDB root: $MYSQL_ROOT_PASSWORD"
	credential "Images: $WP_IMAGE + $WP_CLI_IMAGE + $DB_IMAGE"

	install_docker

	local dir
	dir=$(create_compose_file)
	info "Compose project at $dir"

	if [[ "$FORCE" != true && -f "$dir/docker-compose.yml" ]]; then
		if docker compose -f "$dir/docker-compose.yml" ps --status running >/dev/null 2>&1 &&
			dc "$dir" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
			warn "WordPress already deployed at $dir."
			warn "Re-run with --force to wipe volumes and reinstall."
			exit 0
		fi
	fi

	if [[ "$FORCE" == true ]]; then
		warn "Force mode: docker compose down -v (wipe volumes)..."
		run_cmd docker compose -f "$dir/docker-compose.yml" down -v || true
		# Recreate compose files with current env/passwords
		dir=$(create_compose_file)
	fi

	info "Starting containers (db + wordpress + wpcli)..."
	run_cmd docker compose -f "$dir/docker-compose.yml" up -d

	if [[ "$DRY_RUN" != true ]]; then
		complete_wp_install "$dir" "$SITE_URL"
		configure_firewall
		verify_site "$SITE_URL" "$dir"
	fi

	success "=== DONE ==="
	info "Site:        $SITE_URL"
	info "Admin URL:   $SITE_URL/wp-admin/"
	info "Project:     $dir"
	info "Credentials: $CREDENTIALS_FILE (0600)"
	info "Log:         $LOG_FILE"
	info "Manage:      docker compose -f $dir/docker-compose.yml up -d|down|logs -f"
	warn "Re-run with --force to wipe volumes and reinstall."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
