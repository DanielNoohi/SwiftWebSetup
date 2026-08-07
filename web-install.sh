#!/usr/bin/env bash
#
# SwiftWebSetup - web-install.sh
# One-command WordPress production bootstrap: Apache + PHP + MariaDB + WordPress (fully installed)
#
# Usage: sudo bash web-install.sh [--dry-run] [--unattended] [--force] [--domain D] [--title T] [--admin U] [--email E] [--ssl]
#
# Environment variables (unattended mode):
#   SITE_TITLE ADMIN_USER ADMIN_PASSWORD ADMIN_EMAIL DOMAIN FORCE
#   WP_DB_NAME WP_DB_USER WP_DB_PASSWORD MYSQL_ROOT_PASSWORD

set -euo pipefail

# ── CRLF self-heal (literal backslash-r) ──────────────────────────────
if file "$0" | grep -q "CRLF"; then
    echo "[*] Converting script line endings from CRLF to LF..."
    tmpfix=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfix"
    chmod +x "$tmpfix"
    exec bash "$tmpfix" "$@"
    exit
fi

# ── Colors ────────────────────────────────────────────────────────────
export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-web-install.log"
CREDENTIALS_FILE="/root/swiftwebsetup-credentials.txt"
WP_PATH="/var/www/html"

# Flags
DRY_RUN=false
UNATTENDED=false
FORCE=false
SSL=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""

# Parse args (only when executed directly; source-safe for bats)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --unattended) UNATTENDED=true; shift ;;
        --force)      FORCE=true; shift ;;
        --ssl)        SSL=true; shift ;;
        --domain)     DOMAIN="$2"; shift 2 ;;
        --title)      SITE_TITLE="$2"; shift 2 ;;
        --admin)      ADMIN_USER="$2"; shift 2 ;;
        --email)      ADMIN_EMAIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo bash $SCRIPT_NAME [opts]"
            echo "  --dry-run      preview (no changes)"
            echo "  --unattended   non-interactive (env vars)"
            echo "  --force        wipe existing WP files/DB and reinstall"
            echo "  --ssl          enable HTTPS via certbot (needs --domain)"
            echo "  --domain D     site domain (default: server IP)"
            echo "  --title T      site title"
            echo "  --admin U      admin username"
            echo "  --email E      admin email"
            exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done
fi

# ── Logging (secrets NEVER to LOG_FILE) ───────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}
info()    { log "INFO"    "${BLUE}$*${NC}"; }
warn()    { log "WARN"    "${YELLOW}$*${NC}"; }
error()   { log "ERROR"   "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Secrets go ONLY to the 0600 credential file, never into the log
credential() { echo "$*" >> "$CREDENTIALS_FILE"; }

# Scrubbed command-line logger
log_cmd() {
    local line="$1"
    line=${line//"$WP_DB_PASSWORD"/"********"}
    line=${line//"$ADMIN_PASSWORD"/"********"}
    line=${line//"$MYSQL_ROOT_PASSWORD"/"********"}
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CMD] ${line}" >> "$LOG_FILE" 2>/dev/null || true
}

# Safe execution: array form, no eval. Logs are scrubbed of secrets.
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    log_cmd "$*"
    "$@" || { error "Command failed: $*"; return 1; }
}

# Run wp-cli (--allow-root because we execute as root)
wp() { run_cmd /usr/local/bin/wpcli --allow-root "$@"; }

# ── Guard helpers ─────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Please run as root (sudo)."
        exit 1
    fi
}

check_os() {
    [[ -f /etc/os-release ]] || { error "Cannot determine OS"; exit 1; }
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || ! [[ "$VERSION_ID" =~ ^(20\.04|22\.04|24\.04)$ ]]; then
        if [[ "$UNATTENDED" != true ]]; then
            read -rp "Untested on $PRETTY_NAME. Continue? (y/N) " ch
            [[ "$ch" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
    info "OS: $PRETTY_NAME"
}

ensure_python() {
    if ! command -v python3 &>/dev/null; then
        info "Installing python3 (needed for password generation)..."
        run_cmd apt-get update
        run_cmd apt-get install -y python3
    fi
}

# Cryptographically strong password; python3 secrets preferred, urandom fallback
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

wait_for_active() {
    local svc="$1" t="${2:-30}" i=0
    while ! systemctl is-active --quiet "$svc"; do
        sleep 1; ((i++))
        [[ $i -ge $t ]] && { error "Service $svc not active after ${t}s"; return 1; }
    done
    success "Service $svc active"
}

backup_dir() {
    [[ -d "$1" ]] || return 0
    local b="${1}.backup.$(date +%Y%m%d_%H%M%S)"
    run_cmd cp -a "$1" "$b"
    info "Backed up $1 -> $b"
}

server_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# Already-installed check
wp_is_installed() {
    [[ -f "$WP_PATH/wp-config.php" ]] || return 1
    [[ -x /usr/local/bin/wpcli ]] || return 1
    /usr/local/bin/wpcli --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1
}

# ── Steps ─────────────────────────────────────────────────────────────
configure_firewall() {
    info "Configuring UFW (SSH first, then HTTP/HTTPS, then enable)..."
    run_cmd ufw allow OpenSSH
    run_cmd ufw allow 'Apache Full'
    run_cmd ufw --force enable || warn "UFW enable skipped/failed — leaving firewall config unchanged"
    run_cmd ufw status
}

write_vhost() {
    backup_dir /etc/apache2/sites-available 2>/dev/null || true
    local vhost="/etc/apache2/sites-available/000-default.conf"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Write Apache vhost to $vhost"
        return 0
    fi
    info "Writing Apache vhost..."
    if [[ -n "$DOMAIN" ]]; then
        # 'EOF' unquoted => expand ${DOMAIN}; escape \${APACHE_LOG_DIR} stays literal
        cat > "$vhost" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAdmin webmaster@localhost
    DocumentRoot $WP_PATH
    <Directory $WP_PATH>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    else
        cat > "$vhost" <<'APACHECONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
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
    if [[ ! -f /usr/local/bin/wpcli ]]; then
        info "Installing WP-CLI..."
        run_cmd wget -q -O /usr/local/bin/wpcli https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        run_cmd chmod +x /usr/local/bin/wpcli
    fi
    # symlink convenience `wp` (our wrapper shadows `command -v wp` safely)
    run_cmd ln -sf /usr/local/bin/wpcli /usr/local/bin/wp 2>/dev/null || true
}

# ensure wp-cli present
install_wp_core_dir() { install_wpcli; }

# write wp-config.php DB_* + salts via WP-CLI (robust quoting)
install_wp_core_config() {
    local p="$1"
    run_cmd /usr/local/bin/wpcli --allow-root --path="$p" config set DB_NAME "$WP_DB_NAME" --skip-check
    run_cmd /usr/local/bin/wpcli --allow-root --path="$p" config set DB_USER "$WP_DB_USER" --skip-check
    run_cmd /usr/local/bin/wpcli --allow-root --path="$p" config set DB_PASSWORD "$WP_DB_PASSWORD" --skip-check
    run_cmd /usr/local/bin/wpcli --allow-root --path="$p" config set DB_HOST "localhost" --skip-check
    run_cmd /usr/local/bin/wpcli --allow-root --path="$p" config shuffle-salts
}

download_wordpress() {
    info "Downloading WordPress core from wordpress.org..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Download + extract WordPress core (skipped)"
        return 0
    fi
    run_cmd wget -q -O /tmp/latest.tar.gz https://wordpress.org/latest.tar.gz
    # integrity: must be a real gzip archive, not an HTML error page
    if ! gzip -t /tmp/latest.tar.gz 2>/dev/null; then
        error "Downloaded file is not a valid gzip tarball (blocked/mirror error?)"
        exit 1
    fi
    run_cmd rm -rf /tmp/swiftweb-wp
    run_cmd mkdir -p /tmp/swiftweb-wp
    run_cmd tar -xzf /tmp/latest.tar.gz -C /tmp/swiftweb-wp
}

verify_site() {
    local url="$1"
    info "Verifying site at ${url}..."
    if ! /usr/local/bin/wpcli --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1; then
        error "VERIFICATION FAILED: wp core is-installed reports NOT installed"
        return 1
    fi
    # Homepage must look like WordPress, not an Apache/nginx test page
    local body
    body=$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)
    if [[ "$body" =~ wp-content || "$body" =~ wp-includes || "$body" =~ wp-json ]]; then
        success "Verified: ${url} serves a WordPress site"
        return 0
    fi
    error "VERIFICATION FAILED: ${url} did not return a WordPress page"
    return 1
}

get_site_url() {
    if [[ -n "$DOMAIN" ]]; then
        printf 'http://%s' "$DOMAIN"
    else
        printf 'http://%s' "$(server_ip)"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
    info "=== SwiftWebSetup: WordPress Bootstrap ==="
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN: nothing will be changed"

    check_root
    check_os
    ensure_python

    # After this, every config var is resolved from flags or env.
    DOMAIN="${DOMAIN:-${SITE_URL_DOMAIN:-}}"
    SITE_TITLE="${SITE_TITLE:-${WP_SITE_TITLE:-My WordPress Site}}"
    ADMIN_USER="${ADMIN_USER:-${WP_ADMIN_USER:-admin}}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-${WP_ADMIN_EMAIL:-admin@example.com}}"

    SITE_URL="$(get_site_url)"

    # Idempotent: a live WP site already there → back off unless --force
    if ! [[ "$FORCE" == true ]] && wp_is_installed; then
        warn "WordPress already installed at $WP_PATH."
        warn "Re-run with --force to wipe files/DB and reinstall."
        info "Credentials: $CREDENTIALS_FILE"
        exit 0
    fi

    # Credentials file (0600)
    run_cmd touch "$CREDENTIALS_FILE"
    run_cmd chmod 600 "$CREDENTIALS_FILE"
    credential "# SwiftWebSetup credentials - $(date)"

    # Passwords
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

    # Package setup
    info "apt update + install LAMP packages..."
    run_cmd apt-get update
    run_cmd apt-get install -y apache2 php libapache2-mod-php php-mysql php-cli php-common \
        php-curl php-gd php-mbstring php-xml php-zip php-opcache curl wget ca-certificates ufw

    run_cmd a2enmod rewrite headers
    run_cmd systemctl enable apache2
    run_cmd systemctl start apache2
    [[ "$DRY_RUN" != true ]] && wait_for_active apache2

    export DEBIAN_FRONTEND=noninteractive
    run_cmd apt-get install -y mariadb-server
    run_cmd systemctl enable mariadb
    run_cmd systemctl start mariadb
    [[ "$DRY_RUN" != true ]] && wait_for_active mariadb

    # Secure MariaDB (modern syntax, 20.04/22.04/24.04)
    if [[ "$DRY_RUN" != true ]]; then
        mariadb -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
        mariadb -u root -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`$WP_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$WP_DB_NAME\`.* TO '$WP_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    else
        run_cmd mariadb -u root -e "Locked: create db/user (dry-run)"
    fi

    install_wp_core_dir
    download_wordpress

    # Place files (backup old unless --force)
    if [[ -d "$WP_PATH" ]] && [[ "$FORCE" == true ]]; then
        backup_dir "$WP_PATH"
        run_cmd rm -rf "$WP_PATH"
    fi
    run_cmd mkdir -p "$WP_PATH"
    run_cmd cp -a /tmp/swiftweb-wp/wordpress/. "$WP_PATH/"

    # wp-config
    info "Writing wp-config.php..."
    run_cmd cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"
    install_wp_core_config "$WP_PATH"

    # Permissions
    run_cmd chown -R www-data:www-data "$WP_PATH"
    run_cmd find "$WP_PATH" -type d -exec chmod 755 {} \;
    run_cmd find "$WP_PATH" -type f -exec chmod 644 {} \;

    write_vhost "$SITE_URL"

    # Complete install via WP-CLI
    if ! /usr/local/bin/wpcli --allow-root --path="$WP_PATH" core is-installed >/dev/null 2>&1; then
        info "Running wp core install..."
        /usr/local/bin/wpcli --allow-root --path="$WP_PATH" core install \
            --url="$SITE_URL" \
            --title="$SITE_TITLE" \
            --admin_user="$ADMIN_USER" \
            --admin_password="$ADMIN_PASSWORD" \
            --admin_email="$ADMIN_EMAIL" \
            --skip-email || error "wp core install failed"
    else
        warn "WordPress already installed (skipping core install)"
    fi

    # Settings + permalinks (raw WordPress policy: keep bundled default themes)
    /usr/local/bin/wpcli --allow-root --path="$WP_PATH" rewrite structure '/%postname%/' --hard || true
    [[ -n "$DOMAIN" ]] && /usr/local/bin/wpcli --allow-root --path="$WP_PATH" option update siteurl "$SITE_URL" || true
    [[ -n "$DOMAIN" ]] && /usr/local/bin/wpcli --allow-root --path="$WP_PATH" option update home "$SITE_URL" || true

    # .htaccess AFTER rewrite --hard (which regenerates it)
    default_htaccess

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
    info "Site:       $SITE_URL"
    info "Admin URL:  $SITE_URL/wp-admin/"
    info "Credentials: $CREDENTIALS_FILE (0600)"
    info "Log:        $LOG_FILE"
    warn "Re-run with --force to wipe and reinstall."
}

# Write hardened .htaccess (permalinks rewrite + security)
default_htaccess() {
    cat > "$WP_PATH/.htaccess" <<'EOF'
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

# Only run when executed directly (source-safe for bats/tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
