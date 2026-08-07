#!/usr/bin/env bash
#
# SwiftWebSetup - web-install.sh
# One-command WordPress production bootstrap: Apache + PHP + MariaDB + WordPress (fully installed)
#
# Usage: sudo bash web-install.sh [--dry-run] [--unattended]
#   --dry-run      Show what would be done without executing
#   --unattended   Non-interactive mode
#
# Environment variables for unattended mode:
#   SITE_TITLE           WordPress site title (default: "My WordPress Site")
#   ADMIN_USER           WordPress admin username (default: "admin")
#   ADMIN_PASSWORD       WordPress admin password (auto-generated if not set)
#   ADMIN_EMAIL          WordPress admin email (default: "admin@example.com")
#   WP_DB_PASSWORD       WordPress database password (auto-generated if not set)
#   MYSQL_ROOT_PASSWORD  MySQL root password (auto-generated if not set)

set -euo pipefail

# Self-heal CRLF line endings (Windows-edited scripts)
if file "$0" | grep -q "CRLF"; then
    echo "[*] Converting script line endings from CRLF to LF..."
    tmpfix=$(mktemp)
    tr -d '
' < "$0" > "$tmpfix"
    chmod +x "$tmpfix"
    exec bash "$tmpfix" "$@"
    exit
fi

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-web-install.log"
CREDENTIALS_FILE="/root/swiftwebsetup-credentials.txt"
DRY_RUN=false
UNATTENDED=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --unattended)
            UNATTENDED=true
            ;;
        -h|--help)
            echo "Usage: sudo bash $SCRIPT_NAME [--dry-run] [--unattended]"
            echo "  --dry-run      Show what would be done without executing"
            echo "  --unattended   Non-interactive mode"
            echo ""
            echo "Environment variables for unattended mode:"
            echo "  SITE_TITLE          WordPress site title"
            echo "  ADMIN_USER          WordPress admin username"
            echo "  ADMIN_PASSWORD      WordPress admin password"
            echo "  ADMIN_EMAIL         WordPress admin email"
            echo "  WP_DB_PASSWORD      WordPress database password"
            echo "  MYSQL_ROOT_PASSWORD MySQL root password"
            exit 0
            ;;
    esac
done

# Logging functions
log_to_file() {
    local level="$1" msg="$2" timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}"
    log_to_file "$level" "$msg"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

credential() {
    local msg="$*"
    echo "$msg" >> "${CREDENTIALS_FILE}"
    echo "$msg"
}

# Safe execution (no eval, proper array handling)
run_cmd() {
    [[ "$DRY_RUN" == true ]] && info "[DRY-RUN] Would execute: $*" && return 0
    log_to_file "CMD" "$*"
    "$@" || {
        error "Command failed: $*"
        return 1
    }
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check OS compatibility
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^(20\.04|22\.04|24\.04)$ ]]; then
        warn "This script is tested on Ubuntu 20.04/22.04/24.04. Current: $PRETTY_NAME"
        if [[ "$UNATTENDED" != true ]]; then
            read -rp "Continue anyway? (y/N) " choice
            [[ "$choice" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
    info "OS: $PRETTY_NAME"
}

# Generate cryptographically strong password (python3, pipefail-safe)
gen_password() {
    local len="${1:-32}" pass
    command -v python3 &>/dev/null || { echo "python3 is required for password generation"; return 1; }
    # Shell/SQL-safe charset: no $, backtick, backslash, quote, double-quote, or space
    pass=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!@#%^*_-+=<>~'
print(''.join(secrets.choice(alphabet) for _ in range($len)))
")
    printf '%s' "$pass"
}

# Backup existing config
backup_config() {
    local item="$1"
    if [[ -e "$item" ]]; then
        local backup="${item}.backup.$(date +%Y%m%d_%H%M%S)"
        run_cmd cp -a "$item" "$backup"
        info "Backed up $item to $backup"
    fi
}

# Wait for service to be active
wait_for_service() {
    local service="$1" timeout="${2:-30}" elapsed=0
    while ! systemctl is-active --quiet "$service"; do
        sleep 1
        ((elapsed++))
        if [[ $elapsed -ge $timeout ]]; then
            error "Service $service did not start within ${timeout}s"
            return 1
        fi
    done
    success "Service $service is active"
}

# Configure UFW firewall
configure_firewall() {
    info "Configuring UFW firewall..."
    run_cmd ufw --force enable
    run_cmd ufw allow ssh
    run_cmd ufw allow 'Apache Full'
    run_cmd ufw status
}

# Create default .htaccess for WordPress
create_htaccess() {
    local htaccess_file="/var/www/html/.htaccess"
    
    info "Creating default .htaccess for permalinks..."
    cat > "$htaccess_file" << 'EOF'
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# Security headers
<IfModule mod_headers.c>
  Header set X-Content-Type-Options "nosniff"
  Header set X-Frame-Options "SAMEORIGIN"
  Header set X-XSS-Protection "1; mode=block"
</IfModule>

# Protect wp-config.php
<Files wp-config.php>
  Require all denied
</Files>

# Disable directory browsing
Options -Indexes
EOF

    run_cmd chown www-data:www-data "$htaccess_file"
    run_cmd chmod 644 "$htaccess_file"
}

# Main installation
main() {
    info "=== SwiftWebSetup: WordPress Bootstrap Started ==="
    info "Log file: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE - No changes will be made"
    
    check_root
    check_os

    # Create credentials file with restrictive permissions
    run_cmd touch "${CREDENTIALS_FILE}"
    run_cmd chmod 600 "${CREDENTIALS_FILE}"
    echo "# SwiftWebSetup Credentials - $(date)" > "${CREDENTIALS_FILE}"
    echo "# KEEP THIS FILE SECURE" >> "${CREDENTIALS_FILE}"

    # Generate passwords if not provided
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password)}"
    WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password)}"
    WP_DB_NAME="${WP_DB_NAME:-wordpress}"
    WP_DB_USER="${WP_DB_USER:-wp_user}"

    # Get site configuration
    if [[ "$UNATTENDED" == true ]]; then
        SITE_TITLE="${SITE_TITLE:-My WordPress Site}"
        ADMIN_USER="${ADMIN_USER:-admin}"
        ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_password)}"
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
        DOMAIN="${DOMAIN:-}"
    else
        [[ -z "${SITE_TITLE:-}" ]] && read -p "Site title [My WordPress Site]: " SITE_TITLE; SITE_TITLE=${SITE_TITLE:-My WordPress Site}
        [[ -z "${ADMIN_USER:-}" ]] && read -p "Admin username [admin]: " ADMIN_USER; ADMIN_USER=${ADMIN_USER:-admin}
        # Allow empty (=> auto-generate) or explicit typed password
        if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
            local entered=""
            read -s -r -p "Admin password (Enter to auto-generate): " entered; echo
            if [[ -n "$entered" ]]; then
                ADMIN_PASSWORD="$entered"
            else
                ADMIN_PASSWORD=$(gen_password)
            fi
        fi
        [[ -z "${ADMIN_EMAIL:-}" ]] && read -p "Admin email [admin@$(hostname -f | cut -d' ' -f1)]: " ADMIN_EMAIL; ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$(hostname -f | cut -d' ' -f1)}
        [[ -z "${DOMAIN:-}" ]] && read -p "Domain (leave empty for IP-based): " DOMAIN
        DOMAIN=${DOMAIN:-}
    fi

    # Log credentials
    credential ""
    credential "=== Database Credentials ==="
    credential "MySQL root password: ${MYSQL_ROOT_PASSWORD}"
    credential "WordPress database: ${WP_DB_NAME}"
    credential "WordPress database user: ${WP_DB_USER}"
    credential "WordPress database password: ${WP_DB_PASSWORD}"
    credential ""
    credential "=== WordPress Admin Credentials ==="
    credential "Site title: ${SITE_TITLE}"
    credential "Admin username: ${ADMIN_USER}"
    credential "Admin password: ${ADMIN_PASSWORD}"
    credential "Admin email: ${ADMIN_EMAIL}"
    credential "Domain: ${DOMAIN:-http://$(hostname -I | awk '{print $1}')}"
    credential ""

    # Update package lists
    info "Updating package lists..."
    run_cmd apt update

    # Install core packages (php-json is built into PHP 8+ core, not a package)
    info "Installing Apache, PHP, and dependencies..."
    run_cmd apt install -y apache2 php libapache2-mod-php php-mysql php-cli php-common \
        php-curl php-gd php-mbstring php-xml php-zip php-opcache php-intl php-imagick || {
            # Graceful fallback: retry without imagick/intl if unavailable
            warn "Some PHP extensions unavailable, retrying with core set..."
            run_cmd apt install -y apache2 php libapache2-mod-php php-mysql php-cli php-common \
                php-curl php-gd php-mbstring php-xml php-zip php-opcache
        }

    # Install system utilities
    info "Installing system utilities..."
    run_cmd apt install -y curl wget unzip vim ufw ca-certificates gnupg2

    # Enable and start Apache
    info "Enabling Apache service..."
    run_cmd systemctl enable apache2
    run_cmd systemctl start apache2
    [[ "$DRY_RUN" != true ]] && wait_for_service apache2

    # Install MariaDB
    info "Installing MariaDB server..."
    export DEBIAN_FRONTEND=noninteractive
    run_cmd apt install -y mariadb-server
    run_cmd systemctl enable mariadb
    run_cmd systemctl start mariadb
    [[ "$DRY_RUN" != true ]] && wait_for_service mariadb

    # Secure MariaDB installation (MariaDB 10.5+ compatible auth)
    info "Securing MariaDB installation..."
    if [[ "$DRY_RUN" != true ]]; then
        mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASSWORD}'); FLUSH PRIVILEGES;"
        mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<'SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL
    fi

    # Create WordPress database and user
    info "Creating WordPress database and user..."
    if [[ "$DRY_RUN" != true ]]; then
        mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    fi

    # Download and install WordPress
    info "Downloading WordPress..."
    local temp_dir; temp_dir=$(run_cmd mktemp -d)
    run_cmd wget -q -O "${temp_dir}/latest.tar.gz" "https://wordpress.org/latest.tar.gz"
    run_cmd tar -xzf "${temp_dir}/latest.tar.gz" -C "${temp_dir}"

    # Backup existing web root (idempotent — cp -a preserves dirs)
    if [[ -d /var/www/html ]] && [[ "$DRY_RUN" != true ]]; then
        backup_config "/var/www/html"
        run_cmd rm -rf /var/www/html
    fi
    run_cmd mkdir -p /var/www/html

    info "Installing WordPress files..."
    run_cmd mv "${temp_dir}/wordpress/"* /var/www/html/
    run_cmd rm -rf "${temp_dir}"

    # Install WP-CLI (needed before writing config)
    info "Installing WP-CLI..."
    run_cmd wget -q -O /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    run_cmd chmod +x /usr/local/bin/wp
    run_cmd wp --version --allow-root >/dev/null 2>&1 || true

    # Configure WordPress via WP-CLI (handles quoting/escaping correctly)
    info "Configuring WordPress..."
    backup_config "/var/www/html/wp-config-sample.php"
    run_cmd cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

    if [[ "$DRY_RUN" != true ]]; then
        local wp_path="/var/www/html"
        run_cmd wp config set DB_NAME "$WP_DB_NAME" --path="$wp_path" --allow-root --skip-check
        run_cmd wp config set DB_USER "$WP_DB_USER" --path="$wp_path" --allow-root --skip-check
        run_cmd wp config set DB_PASSWORD "$WP_DB_PASSWORD" --path="$wp_path" --allow-root --skip-check
        run_cmd wp config set DB_HOST "localhost" --path="$wp_path" --allow-root --skip-check
        # Generate real salts (WordPress's own robust method)
        run_cmd wp config shuffle-salts --path="$wp_path" --allow-root
    fi

    # Set permissions
    info "Setting file permissions..."
    run_cmd chown -R www-data:www-data /var/www/html/
    run_cmd find /var/www/html -type d -exec chmod 755 {} \;
    run_cmd find /var/www/html -type f -exec chmod 644 {} \;

    # Configure Apache virtual host
    info "Configuring Apache virtual host..."
    backup_config "/etc/apache2/sites-available/000-default.conf"
    cat > /etc/apache2/sites-available/000-default.conf <<'APACHE_CONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHE_CONF

    run_cmd a2enmod rewrite headers
    run_cmd systemctl reload apache2
    [[ "$DRY_RUN" != true ]] && wait_for_service apache2

    # Complete WordPress installation via WP-CLI (idempotent)
    info "Completing WordPress installation..."
    if [[ "$DRY_RUN" != true ]]; then
        local site_url
        if [[ -n "$DOMAIN" ]]; then
            site_url="http://${DOMAIN}"
        else
            site_url="http://$(hostname -I | awk '{print $1}')"
        fi

        local wp_path="/var/www/html"
        if wp core is-installed --path="${wp_path}" --allow-root 2>/dev/null; then
            warn "WordPress already installed — skipping core install"
        else
            wp core install \
                --path="${wp_path}" \
                --url="$site_url" \
                --title="$SITE_TITLE" \
                --admin_user="$ADMIN_USER" \
                --admin_password="$ADMIN_PASSWORD" \
                --admin_email="$ADMIN_EMAIL" \
                --skip-email
        fi
    fi

    # Configure WordPress settings
    info "Configuring WordPress settings..."
    if [[ "$DRY_RUN" != true ]]; then
        # Set pretty permalinks
        wp rewrite structure '/%postname%/' --path="/var/www/html" --hard
        # Update siteurl and home if domain provided
        if [[ -n "$DOMAIN" ]]; then
            wp option update siteurl "http://${DOMAIN}" --path="/var/www/html"
            wp option update home "http://${DOMAIN}" --path="/var/www/html"
        fi
        # Set timezone
        wp option update timezone_string "UTC" --path="/var/www/html"
        # Delete default plugins (akismet, hello dolly)
        wp plugin delete akismet hello --path="/var/www/html" || true
        # Delete default WordPress theme
        wp theme delete twentytwentythree twentytwentyfour --path="/var/www/html" || true
    fi

    # Create .htaccess AFTER wp rewrite --hard (which would overwrite it)
    create_htaccess

    # Configure firewall
    configure_firewall

    # Final summary
    local site_url
    if [[ -n "$DOMAIN" ]]; then
        site_url="http://${DOMAIN}"
    else
        site_url="http://$(hostname -I | awk '{print $1}')"
    fi

    success "=== WordPress Installation Complete ==="
    info "Site URL: ${site_url}"
    info "Admin URL: ${site_url}/wp-admin/"
    info ""
    credential "=== Quick Access ==="
    credential "Frontend: ${site_url}"
    credential "Admin: ${site_url}/wp-admin/"
    credential "Username: ${ADMIN_USER}"
    credential "Password: ${ADMIN_PASSWORD}"
    credential ""
    warn "IMPORTANT: Credentials saved to ${CREDENTIALS_FILE}"
    warn "Log file: ${LOG_FILE}"
    info "=== SwiftWebSetup: WordPress Bootstrap Finished ==="
}

main "$@"
