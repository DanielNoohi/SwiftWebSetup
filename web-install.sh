#!/usr/bin/env bash
#
# SwiftWebSetup - web-install.sh
# Host LAMP + official WordPress (fully installed via WP-CLI as www-data)
#
# Usage: sudo bash web-install.sh [--dry-run] [--unattended] [--force] [--domain D]
#          [--title T] [--admin U] [--email E] [--ssl]

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
LOG_FILE="/var/log/swiftwebsetup-web-install.log"
CREDENTIALS_FILE="/root/swiftwebsetup-credentials.txt"
WP_PATH="/var/www/html"
WP_BIN="/usr/local/bin/wpcli"

DRY_RUN=false
UNATTENDED=false
FORCE=false
SSL=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) DRY_RUN=true; shift ;;
		--unattended) UNATTENDED=true; shift ;;
		--force) FORCE=true; shift ;;
		--ssl) SSL=true; shift ;;
		--domain) DOMAIN="$2"; shift 2 ;;
		--title) SITE_TITLE="$2"; shift 2 ;;
		--admin) ADMIN_USER="$2"; shift 2 ;;
		--email) ADMIN_EMAIL="$2"; shift 2 ;;
		-h | --help)
			echo "Usage: sudo bash $SCRIPT_NAME [opts]"
			echo "  --dry-run      preview (no changes)"
			echo "  --unattended   non-interactive (env vars)"
			echo "  --force        wipe web root + WordPress DB and reinstall"
			echo "  --ssl          enable HTTPS via certbot (needs --domain)"
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

# WP-CLI as www-data (fallback to --allow-root only if sudo -u fails)
run_wp() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] wp $*"
		return 0
	fi
	log_cmd "wp $*"
	if id www-data &>/dev/null; then
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" "$@"
	else
		warn "www-data missing — falling back to --allow-root"
		"$WP_BIN" --allow-root --path="$WP_PATH" "$@"
	fi
}

wp_is_installed() {
	[[ -f "$WP_PATH/wp-config.php" ]] || return 1
	[[ -x "$WP_BIN" ]] || return 1
	if id www-data &>/dev/null; then
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" core is-installed >/dev/null 2>&1
	else
		"$WP_BIN" --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1
	fi
}

configure_firewall() {
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
	run_cmd systemctl reload apache2
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
	info "Downloading WordPress core from wordpress.org..."
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Download + extract WordPress core (skipped)"
		return 0
	fi
	run_cmd wget -q -O /tmp/latest.tar.gz https://wordpress.org/latest.tar.gz
	if ! gzip -t /tmp/latest.tar.gz 2>/dev/null; then
		error "Downloaded file is not a valid gzip tarball"
		exit 1
	fi
	run_cmd rm -rf /tmp/swiftweb-wp
	run_cmd mkdir -p /tmp/swiftweb-wp
	run_cmd tar -xzf /tmp/latest.tar.gz -C /tmp/swiftweb-wp
	[[ -f /tmp/swiftweb-wp/wordpress/wp-settings.php ]] || {
		error "WordPress extract missing wp-settings.php"
		exit 1
	}
}

# Place official core into DocumentRoot; never leave Apache default index.html
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
			# First-time / non-force: strip welcome pages that shadow index.php
			clear_default_indexes "$WP_PATH"
		fi
	fi
	run_cmd mkdir -p "$WP_PATH"
	run_cmd cp -a /tmp/swiftweb-wp/wordpress/. "$WP_PATH/"
	clear_default_indexes "$WP_PATH"
	[[ -f "$WP_PATH/index.php" ]] || {
		error "WordPress index.php missing after copy"
		exit 1
	}
	# Ensure no leftover default HTML index remains
	[[ ! -f "$WP_PATH/index.html" ]] || rm -f "$WP_PATH/index.html"
}

mariadb_root() {
	# Fresh installs allow socket root without password; after secure, use password.
	if mariadb -u root -e "SELECT 1" &>/dev/null; then
		mariadb -u root "$@"
	else
		mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"
	fi
}

secure_mariadb_and_db() {
	if [[ "$DRY_RUN" == true ]]; then
		info "[DRY-RUN] Secure MariaDB + create/reset WP database"
		return 0
	fi

	mariadb_root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

	if [[ "$FORCE" == true ]]; then
		info "Force mode: DROP + recreate WordPress database ${WP_DB_NAME}"
		mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL
DROP DATABASE IF EXISTS \`${WP_DB_NAME}\`;
CREATE DATABASE \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
ALTER USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
	else
		mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL
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
	if id www-data &>/dev/null; then
		sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" core is-installed >/dev/null 2>&1 && installed=true
	else
		"$WP_BIN" --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1 && installed=true
	fi
	if [[ "$installed" != true ]]; then
		error "VERIFICATION FAILED: wp core is-installed reports NOT installed"
		return 1
	fi
	verify_wordpress_http "$url"
}

main() {
	info "=== SwiftWebSetup: WordPress Bootstrap ==="
	[[ "$DRY_RUN" == true ]] && warn "DRY-RUN: nothing will be changed"

	check_root
	check_os
	ensure_python
	touch "$LOG_FILE" 2>/dev/null || true

	DOMAIN="${DOMAIN:-}"
	SITE_TITLE="${SITE_TITLE:-My WordPress Site}"
	ADMIN_USER="${ADMIN_USER:-admin}"
	ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
	SITE_URL="$(get_site_url)"

	install_wpcli

	if [[ "$FORCE" != true ]] && wp_is_installed; then
		warn "WordPress already installed at $WP_PATH."
		warn "Re-run with --force to wipe files + DB and reinstall."
		info "Credentials: $CREDENTIALS_FILE"
		exit 0
	fi

	ensure_credentials_file
	credential "# SwiftWebSetup credentials - $(date)"

	WP_DB_NAME="${WP_DB_NAME:-wordpress}"
	WP_DB_USER="${WP_DB_USER:-wp_user}"
	WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password)}"
	MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password)}"
	ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_password)}"

	credential "Site URL:  $SITE_URL"
	credential "Site title: $SITE_TITLE"
	credential "Admin user: $ADMIN_USER"
	credential "Admin pass: $ADMIN_PASSWORD"
	credential "Admin email: $ADMIN_EMAIL"
	credential "DB: db=$WP_DB_NAME user=$WP_DB_USER pass=$WP_DB_PASSWORD"
	credential "MariaDB root: $MYSQL_ROOT_PASSWORD"

	info "apt update + install LAMP packages..."
	run_cmd apt-get update
	run_cmd apt-get install -y apache2 php libapache2-mod-php php-mysql php-cli php-common \
		php-curl php-gd php-mbstring php-xml php-zip php-opcache curl wget ca-certificates ufw sudo

	run_cmd a2enmod rewrite headers
	run_cmd systemctl enable apache2
	run_cmd systemctl start apache2
	[[ "$DRY_RUN" != true ]] && wait_for_active apache2

	export DEBIAN_FRONTEND=noninteractive
	run_cmd apt-get install -y mariadb-server
	run_cmd systemctl enable mariadb
	run_cmd systemctl start mariadb
	[[ "$DRY_RUN" != true ]] && wait_for_active mariadb

	secure_mariadb_and_db
	download_wordpress
	place_wordpress_files

	info "Writing wp-config.php..."
	if [[ "$DRY_RUN" != true ]]; then
		run_cmd cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"
		run_cmd chown -R www-data:www-data "$WP_PATH"
		run_cmd find "$WP_PATH" -type d -exec chmod 755 {} \;
		run_cmd find "$WP_PATH" -type f -exec chmod 644 {} \;

		run_wp config set DB_NAME "$WP_DB_NAME" --skip-check
		run_wp config set DB_USER "$WP_DB_USER" --skip-check
		run_wp config set DB_PASSWORD "$WP_DB_PASSWORD" --skip-check
		run_wp config set DB_HOST "localhost" --skip-check
		run_wp config shuffle-salts
	fi

	write_vhost

	if [[ "$DRY_RUN" != true ]]; then
		if ! sudo -u www-data -- "$WP_BIN" --path="$WP_PATH" core is-installed >/dev/null 2>&1; then
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
		# Raw WP policy: keep default themes; drop akismet only
		run_wp plugin delete akismet || true
	fi

	default_htaccess
	clear_default_indexes "$WP_PATH"
	configure_firewall

	if [[ "$SSL" == true ]]; then
		if [[ -n "$DOMAIN" ]]; then
			info "Enabling HTTPS via certbot for $DOMAIN..."
			run_cmd apt-get install -y certbot python3-certbot-apache
			run_cmd certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect
		else
			warn "--ssl requires --domain; skipping"
		fi
	fi

	verify_site "$SITE_URL"

	success "=== DONE ==="
	info "Site:        $SITE_URL"
	info "Admin URL:   $SITE_URL/wp-admin/"
	info "Credentials: $CREDENTIALS_FILE (0600)"
	info "Log:         $LOG_FILE"
	warn "Re-run with --force to wipe files + DB and reinstall."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
