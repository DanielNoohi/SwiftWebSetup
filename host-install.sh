#!/usr/bin/env bash
#
# SwiftWebSetup - host-install.sh
# Native VPS install: Apache + PHP + MariaDB + official WordPress (WP-CLI as www-data)
#
# Usage: sudo bash host-install.sh [options]
#   web-install.sh is a compatibility wrapper that execs this script.

set -euo pipefail

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
LOG_FILE="/var/log/swiftwebsetup-web-install.log"
CREDENTIALS_FILE="/root/swiftwebsetup-credentials.txt"
BACKUP_ROOT="/root/swiftweb-backups"
WP_PATH="/var/www/html"
WP_BIN="/usr/local/bin/wpcli"

DRY_RUN=false
UNATTENDED=false
FORCE=false
SSL=false
BACKUP_ONLY=false
FAIL2BAN=false
AUTO_UPDATES=false
DOMAIN="${DOMAIN:-}"
SITE_TITLE="${SITE_TITLE:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--unattended)
			UNATTENDED=true
			shift
			;;
		--force)
			FORCE=true
			shift
			;;
		--ssl)
			SSL=true
			shift
			;;
		--backup-only)
			BACKUP_ONLY=true
			shift
			;;
		--fail2ban)
			FAIL2BAN=true
			shift
			;;
		--auto-updates)
			AUTO_UPDATES=true
			shift
			;;
		--domain)
			DOMAIN="$2"
			shift 2
			;;
		--title)
			SITE_TITLE="$2"
			shift 2
			;;
		--admin)
			ADMIN_USER="$2"
			shift 2
			;;
		--email)
			ADMIN_EMAIL="$2"
			shift 2
			;;
		-h | --help)
			cat <<EOF
Usage: sudo bash $SCRIPT_NAME [opts]
  --dry-run         preview (no changes)
  --unattended      non-interactive (env / flags only)
  --force           wipe web root + WordPress DB and reinstall
  --backup-only     backup web root + DB, then exit
  --ssl             HTTPS via certbot (requires --domain)
  --fail2ban        install & enable fail2ban (sshd)
  --auto-updates    enable unattended-upgrades
  --domain D        site domain (default: server IP)
  --title T         site title
  --admin U         admin username
  --email E         admin email
EOF
			exit 0
			;;
		*)
			error "Unknown option: $1 (see --help)"
			exit 1
			;;
		esac
	done
fi

trap 'install_fail_hint' ERR

run_wp() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] wp $*"
		return 0
	fi
	log_cmd "wp $*"
	# CI runners OOM on chown -R of the full tree; --allow-root avoids needing www-data ownership
	if is_ci || ! id www-data &>/dev/null; then
		if is_ci; then
			"$WP_BIN" --allow-root --path="$WP_PATH" "$@"
		else
			warn "www-data missing — falling back to --allow-root"
			"$WP_BIN" --allow-root --path="$WP_PATH" "$@"
		fi
	else
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" "$@"
	fi
}

wp_is_installed() {
	[[ -f "$WP_PATH/wp-config.php" ]] || return 1
	[[ -x "$WP_BIN" ]] || return 1
	if is_ci || ! id www-data &>/dev/null; then
		"$WP_BIN" --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1
	else
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" core is-installed >/dev/null 2>&1
	fi
}

configure_firewall() {
	if is_ci; then
		info "CI environment detected — skipping UFW"
		return 0
	fi
	info "Configuring UFW (SSH first, then HTTP/HTTPS, then enable)..."
	run_cmd ufw allow OpenSSH
	run_cmd ufw allow 'Apache Full'
	run_cmd ufw --force enable || warn "UFW enable skipped/failed — leaving firewall unchanged"
	run_cmd ufw status || true
}

write_vhost() {
	local vhost="/etc/apache2/sites-available/000-default.conf"
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Write Apache vhost to $vhost"
		return 0
	fi
	info "Writing Apache vhost (DirectoryIndex prefers index.php)..."
	if [[ -n "$DOMAIN" ]]; then
		cat >"$vhost" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAdmin webmaster@localhost
    DocumentRoot ${WP_PATH}
    DirectoryIndex index.php index.html
    <Directory ${WP_PATH}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
	else
		cat >"$vhost" <<'APACHECONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    DirectoryIndex index.php index.html
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHECONF
	fi
	run_cmd a2ensite 000-default >/dev/null 2>&1 || true
	if systemctl is-active --quiet apache2 2>/dev/null; then
		run_cmd systemctl reload apache2 || true
	else
		info "Apache not running yet — vhost saved; start comes after file placement"
	fi
}

tune_php_for_wordpress() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Write PHP WordPress defaults"
		return 0
	fi
	local conf dir
	for dir in /etc/php/*/apache2/conf.d /etc/php/*/cli/conf.d; do
		[[ -d "$dir" ]] || continue
		conf="${dir}/99-swiftweb-wordpress.ini"
		cat >"$conf" <<'EOF'
; SwiftWebSetup — sensible WordPress defaults
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
max_input_time = 300
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
EOF
		info "PHP tuning: $conf"
	done
	if systemctl is-active --quiet apache2 2>/dev/null; then
		systemctl reload apache2 2>/dev/null || true
	fi
}

install_wpcli() {
	if [[ ! -x "$WP_BIN" ]]; then
		info "Installing WP-CLI..."
		run_cmd wget -q -O "$WP_BIN" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
		run_cmd chmod +x "$WP_BIN"
	fi
	run_cmd ln -sf "$WP_BIN" /usr/local/bin/wp 2>/dev/null || true
}

download_wordpress() {
	info "Downloading WordPress core from wordpress.org (latest)..."
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Download + extract WordPress core (skipped)"
		return 0
	fi
	# Prefer a disk-backed path under /var (same FS as DocumentRoot).
	# /tmp is often tmpfs on cloud runners and OOMs during extract+move.
	local extract_root="${SWIFTWEB_EXTRACT_ROOT:-/var/tmp/swiftweb-wp}"
	if is_ci; then
		extract_root="/var/www/swiftweb-extract"
	fi
	run_cmd rm -rf "$extract_root"
	run_cmd mkdir -p "$extract_root"

	info "Fetching WordPress tarball..."
	local tarball="/var/tmp/latest.tar.gz"
	run_cmd wget -q -O "$tarball" https://wordpress.org/latest.tar.gz
	if ! gzip -t "$tarball" 2>/dev/null; then
		error "Downloaded file is not a valid gzip tarball"
		exit 1
	fi
	info "Extracting WordPress archive to ${extract_root}..."
	if ! tar -xzf "$tarball" -C "$extract_root"; then
		error "tar extract failed (check free memory/disk)"
		free -m || true
		df -h "$(dirname "$extract_root")" || true
		exit 1
	fi
	rm -f "$tarball" 2>/dev/null || true

	[[ -f "${extract_root}/wordpress/wp-settings.php" ]] || {
		error "WordPress extract missing wp-settings.php"
		exit 1
	}
	SWIFTWEB_WP_EXTRACT="${extract_root}/wordpress"
	export SWIFTWEB_WP_EXTRACT
	success "WordPress core extracted at ${SWIFTWEB_WP_EXTRACT}"
}

ci_ensure_swap() {
	is_ci || return 0
	if swapon --show 2>/dev/null | grep -q .; then
		return 0
	fi
	info "CI: enabling 1G swapfile"
	if [[ ! -f /swapfile ]]; then
		fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null
	fi
	swapon /swapfile 2>/dev/null || warn "Could not enable swap"
}

place_wordpress_files() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Place WordPress files into $WP_PATH"
		return 0
	fi
	if [[ -d "$WP_PATH" ]]; then
		if [[ "$FORCE" == true ]]; then
			backup_dir "$WP_PATH"
			run_cmd rm -rf "$WP_PATH"
		else
			clear_default_indexes "$WP_PATH"
		fi
	fi
	run_cmd mkdir -p "$(dirname "$WP_PATH")"

	local src="${SWIFTWEB_WP_EXTRACT:-/var/www/swiftweb-extract/wordpress}"
	[[ -d "$src" ]] || src="/var/tmp/swiftweb-wp/wordpress"
	[[ -d "$src" ]] || {
		error "WordPress extract not found (SWIFTWEB_WP_EXTRACT=${SWIFTWEB_WP_EXTRACT:-unset})"
		exit 1
	}

	info "Placing WordPress from $src -> $WP_PATH"
	rm -rf "$WP_PATH"
	info "Removed old $WP_PATH (if any)"
	if mv "$src" "$WP_PATH"; then
		info "Placed WordPress via mv"
		rmdir "$(dirname "$src")" 2>/dev/null || rm -rf "$(dirname "$src")" 2>/dev/null || true
	else
		error "mv failed; falling back to cp -a"
		run_cmd mkdir -p "$WP_PATH"
		run_cmd cp -a "$src"/. "$WP_PATH/"
		rm -rf "$(dirname "$src")" 2>/dev/null || true
	fi
	success "WordPress files are in $WP_PATH"

	clear_default_indexes "$WP_PATH"
	[[ -f "$WP_PATH/index.php" ]] || {
		error "WordPress index.php missing after copy"
		exit 1
	}
	rm -f "$WP_PATH/index.html" 2>/dev/null || true
}

# MariaDB admin via local root socket (script runs as root on Ubuntu).
# Keep unix_socket auth for root@localhost — ALTER USER ... IDENTIFIED BY breaks
# subsequent passwordless socket logins and fails the install under set -e.
mariadb_socket() {
	if command -v mariadb &>/dev/null; then
		mariadb --protocol=socket -u root
	else
		mysql --protocol=socket -u root
	fi
}

secure_mariadb_and_db() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Secure MariaDB + create/reset WP database"
		return 0
	fi

	info "Configuring MariaDB and WordPress database (unix_socket root)..."

	# Soften anonymous/test accounts; do not change root auth plugin.
	mariadb_socket <<SQL || warn "MariaDB housekeeping statements had warnings; continuing"
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

	# Credentials file still records a generated value; on Ubuntu, prefer:
	#   sudo mariadb
	# (unix_socket) rather than password login for system root.
	if [[ "$FORCE" == true ]]; then
		info "Force mode: DROP + recreate WordPress database ${WP_DB_NAME}"
		mariadb_socket <<SQL
DROP DATABASE IF EXISTS \`${WP_DB_NAME}\`;
CREATE DATABASE \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
ALTER USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
	else
		mariadb_socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
ALTER USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
	fi
}

default_htaccess() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Write .htaccess"
		return 0
	fi
	cat >"$WP_PATH/.htaccess" <<'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress

# Security
<IfModule mod_headers.c>
  Header set X-Content-Type-Options "nosniff"
  Header set X-Frame-Options "SAMEORIGIN"
  Header set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
<Files wp-config.php>
  Require all denied
</Files>
Options -Indexes
EOF
	run_cmd chown www-data:www-data "$WP_PATH/.htaccess"
	run_cmd chmod 644 "$WP_PATH/.htaccess"
}

verify_site() {
	local url="$1"
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] skip live verify"
		return 0
	fi
	local installed=false
	if is_ci || ! id www-data &>/dev/null; then
		"$WP_BIN" --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1 && installed=true
	else
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" core is-installed >/dev/null 2>&1 && installed=true
	fi
	if [[ "$installed" != true ]]; then
		error "VERIFICATION FAILED: wp core is-installed reports NOT installed"
		return 1
	fi
	verify_wordpress_http "$url"
}

do_backup_only() {
	info "=== Backup only ==="
	local stamp dest
	stamp=$(date +%Y%m%d_%H%M%S)
	dest="${BACKUP_ROOT}/${stamp}"
	run_cmd mkdir -p "$dest"
	if [[ -d "$WP_PATH" ]]; then
		run_cmd cp -a "$WP_PATH" "${dest}/html"
	else
		warn "No $WP_PATH to back up"
	fi
	WP_DB_NAME="${WP_DB_NAME:-wordpress}"
	MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
	if command -v mariadb-dump &>/dev/null || command -v mysqldump &>/dev/null; then
		local dump_bin=mariadb-dump
		command -v mariadb-dump &>/dev/null || dump_bin=mysqldump
		if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
			MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$dump_bin" -u root "$WP_DB_NAME" >"${dest}/${WP_DB_NAME}.sql" 2>/dev/null ||
				"$dump_bin" -u root "$WP_DB_NAME" >"${dest}/${WP_DB_NAME}.sql" || warn "DB dump failed"
		else
			"$dump_bin" -u root "$WP_DB_NAME" >"${dest}/${WP_DB_NAME}.sql" 2>/dev/null || warn "DB dump failed (set MYSQL_ROOT_PASSWORD?)"
		fi
	fi
	success "Backup written to ${dest}"
}

optional_hardening() {
	if [[ "$FAIL2BAN" == true ]]; then
		info "Installing fail2ban..."
		run_cmd apt-get install -y fail2ban
		run_cmd systemctl enable --now fail2ban
	fi
	if [[ "$AUTO_UPDATES" == true ]]; then
		info "Enabling unattended-upgrades..."
		run_cmd apt-get install -y unattended-upgrades
		run_cmd dpkg-reconfigure -f noninteractive unattended-upgrades || true
	fi
}

main() {
	info "=== SwiftWebSetup: Host WordPress (VPS) ==="
	[[ "$DRY_RUN" == true ]] && warn "DRY-RUN: nothing will be changed"

	check_root
	check_os
	ensure_python
	touch "$LOG_FILE" 2>/dev/null || true

	if [[ "$BACKUP_ONLY" == true ]]; then
		do_backup_only
		trap - ERR
		exit 0
	fi

	collect_site_config
	WP_DB_NAME="${WP_DB_NAME:-wordpress}"
	WP_DB_USER="${WP_DB_USER:-wp_user}"
	WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password 32)}"
	MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password 32)}"
	SITE_URL="$(get_site_url)"

	ci_ensure_swap
	install_wpcli

	if [[ "$FORCE" != true ]] && wp_is_installed; then
		warn "WordPress already installed at $WP_PATH."
		warn "Re-run with --force to wipe files + DB and reinstall."
		[[ -f "$CREDENTIALS_FILE" ]] && info "Credentials: $CREDENTIALS_FILE"
		trap - ERR
		exit 0
	fi

	info "apt update + install Apache, PHP, and tools..."
	run_cmd apt-get update
	local pkgs=(apache2 php libapache2-mod-php php-mysql php-cli php-common
		php-curl php-gd php-mbstring php-xml php-zip php-opcache curl wget ca-certificates)
	# UFW is unused in CI (configure_firewall no-ops); skip to reduce runner pressure
	if ! is_ci; then
		pkgs+=(ufw)
	fi
	# sudo is required for www-data WP-CLI; usually preinstalled on VPS images
	command -v sudo >/dev/null 2>&1 || pkgs+=(sudo)
	run_cmd apt-get install -y "${pkgs[@]}"

	run_cmd a2enmod rewrite headers
	run_cmd systemctl enable apache2
	# Defer Apache start on CI until files are in place (saves RAM during MariaDB install)
	if ! is_ci; then
		run_cmd systemctl start apache2
		[[ "$DRY_RUN" != true ]] && wait_for_active apache2
	fi
	tune_php_for_wordpress

	# Fetch WordPress after Apache packages so /var/www layout is stable; before MariaDB for RAM
	download_wordpress

	export DEBIAN_FRONTEND=noninteractive
	export NEEDRESTART_MODE=a
	# GitHub runners / some images ship MySQL — remove it so MariaDB can install cleanly
	if dpkg -l mysql-server 2>/dev/null | grep -q '^ii'; then
		warn "Removing conflicting mysql-server package..."
		run_cmd systemctl stop mysql || true
		run_cmd apt-get remove -y --purge mysql-server mysql-client || true
		run_cmd apt-get autoremove -y || true
	fi
	info "Installing MariaDB..."
	run_cmd apt-get install -y mariadb-server
	run_cmd systemctl enable mariadb || run_cmd systemctl enable mysql || true
	run_cmd systemctl start mariadb || run_cmd systemctl start mysql
	if [[ "$DRY_RUN" != true ]]; then
		if ! wait_for_active mariadb 60 && ! wait_for_active mysql 60; then
			error "Neither mariadb nor mysql became active"
			systemctl status mariadb --no-pager || systemctl status mysql --no-pager || true
			exit 1
		fi
		# Shrink InnoDB buffer on CI runners so tar/WP-CLI are less likely to OOM
		if is_ci; then
			info "CI: applying low-memory MariaDB settings"
			cat >/etc/mysql/mariadb.conf.d/99-swiftweb-ci.cnf <<'EOF' || true
[mysqld]
innodb_buffer_pool_size=64M
key_buffer_size=8M
max_connections=30
performance_schema=OFF
EOF
			systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
			sleep 2
		fi
		# Wait until the unix socket actually accepts queries (service "active" is not enough)
		local ready=0
		local i
		for ((i = 0; i < 60; i++)); do
			if mariadb_socket <<<"SELECT 1;" >/dev/null 2>&1; then
				ready=1
				break
			fi
			sleep 1
		done
		[[ "$ready" -eq 1 ]] || {
			error "MariaDB is running but not accepting socket connections"
			systemctl status mariadb --no-pager || systemctl status mysql --no-pager || true
			journalctl -u mariadb -n 40 --no-pager || journalctl -u mysql -n 40 --no-pager || true
			exit 1
		}
		success "MariaDB accepting socket connections"
	fi

	secure_mariadb_and_db
	place_wordpress_files

	info "Writing wp-config.php..."
	if [[ "$DRY_RUN" != true ]]; then
		run_cmd cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"
		if is_ci; then
			info "CI: keeping tarball permissions; WP-CLI uses --allow-root"
		else
			run_cmd chown -R www-data:www-data "$WP_PATH"
			run_cmd chmod -R u=rwX,g=rX,o=rX "$WP_PATH"
		fi

		run_wp config set DB_NAME "$WP_DB_NAME" --skip-check
		run_wp config set DB_USER "$WP_DB_USER" --skip-check
		run_wp config set DB_PASSWORD "$WP_DB_PASSWORD" --skip-check
		run_wp config set DB_HOST "localhost" --skip-check
		run_wp config shuffle-salts
	fi

	write_vhost

	# Start Apache after vhost + files exist (CI deferred start to reduce peak RAM)
	if is_ci || ! systemctl is-active --quiet apache2 2>/dev/null; then
		run_cmd systemctl start apache2
		[[ "$DRY_RUN" != true ]] && wait_for_active apache2
	else
		run_cmd systemctl reload apache2 || true
	fi

	if [[ "$DRY_RUN" != true ]]; then
		if ! wp_is_installed; then
			info "Running wp core install (as www-data)..."
			run_wp core install \
				--url="$SITE_URL" \
				--title="$SITE_TITLE" \
				--admin_user="$ADMIN_USER" \
				--admin_password="$ADMIN_PASSWORD" \
				--admin_email="$ADMIN_EMAIL" \
				--skip-email || {
				error "wp core install failed"
				exit 1
			}
		else
			warn "WordPress already installed in DB (skipping core install)"
		fi

		run_wp rewrite structure '/%postname%/' --hard || true
		if [[ -n "$DOMAIN" ]]; then
			run_wp option update siteurl "$SITE_URL" || true
			run_wp option update home "$SITE_URL" || true
		fi
		run_wp plugin delete akismet || true
	fi

	default_htaccess
	clear_default_indexes "$WP_PATH"
	configure_firewall
	optional_hardening

	if [[ "$SSL" == true ]]; then
		if [[ -n "$DOMAIN" ]]; then
			info "Enabling HTTPS via certbot for $DOMAIN..."
			run_cmd apt-get install -y certbot python3-certbot-apache
			run_cmd certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect
			SITE_URL="https://${DOMAIN}"
			if [[ "$DRY_RUN" != true ]]; then
				run_wp option update siteurl "$SITE_URL" || true
				run_wp option update home "$SITE_URL" || true
			fi
		else
			warn "--ssl requires --domain; skipping"
		fi
	fi

	verify_site "$SITE_URL"

	# Credentials ONLY after success
	if [[ "$DRY_RUN" != true ]]; then
		save_credentials "host"
	fi
	trap - ERR
	print_summary_card "host"
	warn "Re-run with --force to wipe files + DB and reinstall. Use --backup-only to snapshot first."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
