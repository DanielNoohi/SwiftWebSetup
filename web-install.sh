#!/usr/bin/env bash
#
# SwiftWebSetup - web-install.sh
# Rapid web server deployment: Apache + PHP + MySQL/MariaDB + WordPress
#
# Usage: sudo bash web-install.sh [--dry-run] [--unattended]
#   --dry-run      Show what would be done without executing
#   --unattended   Non-interactive mode (requires env vars for passwords)
#
# Environment variables for unattended mode:
#   MYSQL_ROOT_PASSWORD    MySQL root password (auto-generated if not set)
#   WP_DB_PASSWORD         WordPress database password (auto-generated if not set)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-web-install.log"
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
            exit 0
            ;;
    esac
done

# Logging functions
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Dry-run wrapper
run() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $*"
    else
        eval "$@"
    fi
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

# Generate secure random password
gen_password() {
    tr -dc 'A-Za-z0-9!@#%^&*()_+' </dev/urandom | head -c 32
}

# Backup existing config
backup_config() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        run "cp \"$file\" \"$backup\""
        info "Backed up $file to $backup"
    fi
}

# Wait for service to be active
wait_for_service() {
    local service="$1"
    local timeout="${2:-30}"
    local elapsed=0
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
    run "ufw --force enable"
    run "ufw allow ssh"
    run "ufw allow 'Apache Full'"
    run "ufw status"
}

# Main installation
main() {
    info "=== SwiftWebSetup: Web Install Started ==="
    info "Log file: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE - No changes will be made"

    check_root
    check_os

    # Generate passwords if not provided
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password)}"
    WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password)}"
    WP_DB_NAME="${WP_DB_NAME:-wordpress}"
    WP_DB_USER="${WP_DB_USER:-wp_user}"

    if [[ "$UNATTENDED" != true ]] && [[ "$DRY_RUN" != true ]]; then
        info "MySQL root password: $MYSQL_ROOT_PASSWORD"
        info "WordPress DB password: $WP_DB_PASSWORD"
        warn "SAVE THESE PASSWORDS - They will not be shown again!"
    fi

    # Update package lists
    info "Updating package lists..."
    run "apt update"

    # Install core packages
    info "Installing Apache, PHP, and dependencies..."
    run "apt install -y apache2 php libapache2-mod-php php-mysql php-cli php-common \
        php-curl php-gd php-json php-mbstring php-xml php-zip php-opcache"

    # Install system utilities
    info "Installing system utilities..."
    run "apt install -y curl wget unzip vim ufw ca-certificates gnupg2"

    # Enable and start Apache
    info "Enabling Apache service..."
    run "systemctl enable apache2"
    run "systemctl start apache2"
    [[ "$DRY_RUN" != true ]] && wait_for_service apache2

    # Install MySQL/MariaDB
    info "Installing MariaDB server..."
    export DEBIAN_FRONTEND=noninteractive
    run "apt install -y mariadb-server"

    # Secure MariaDB installation
    info "Securing MariaDB installation..."
    if [[ "$DRY_RUN" != true ]]; then
        mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_ROOT_PASSWORD}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    else
        run "mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('<password>'); FLUSH PRIVILEGES;\""
    fi

    # Create WordPress database and user
    info "Creating WordPress database and user..."
    if [[ "$DRY_RUN" != true ]]; then
        mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    else
        run "mysql -u root -p'<root_password>' -e \"CREATE DATABASE ${WP_DB_NAME}; CREATE USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '<wp_password>'; GRANT ALL ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'localhost'; FLUSH PRIVILEGES;\""
    fi

    # Download and install WordPress
    info "Downloading WordPress..."
    run "cd /tmp && wget -q https://wordpress.org/latest.tar.gz -O latest.tar.gz"
    run "tar -xzf /tmp/latest.tar.gz -C /tmp"

    # Backup existing web root (idempotent)
    if [[ -d /var/www/html ]]; then
        backup_config "/var/www/html"
        run "rm -rf /var/www/html"
    fi
    run "mkdir -p /var/www/html"

    info "Installing WordPress files..."
    run "mv /tmp/wordpress/* /var/www/html/"

    # Configure WordPress
    info "Configuring WordPress..."
    backup_config "/var/www/html/wp-config-sample.php"
    run "cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php"

    if [[ "$DRY_RUN" != true ]]; then
        sed -i "s/database_name_here/${WP_DB_NAME}/" /var/www/html/wp-config.php
        sed -i "s/username_here/${WP_DB_USER}/" /var/www/html/wp-config.php
        sed -i "s/password_here/${WP_DB_PASSWORD}/" /var/www/html/wp-config.php
        sed -i "s/localhost/localhost/" /var/www/html/wp-config.php

        # Generate WordPress salts
        SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
        sed -i "/AUTH_KEY/d;/SECURE_AUTH_KEY/d;/LOGGED_IN_KEY/d;/NONCE_KEY/d;/AUTH_SALT/d;/SECURE_AUTH_SALT/d;/LOGGED_IN_SALT/d;/NONCE_SALT/d" /var/www/html/wp-config.php
        sed -i "/@-/a ${SALTS}" /var/www/html/wp-config.php
    else
        run "sed -i 's/database_name_here/${WP_DB_NAME}/; s/username_here/${WP_DB_USER}/; s/password_here/<wp_password>/' /var/www/html/wp-config.php"
    fi

    # Set permissions
    info "Setting file permissions..."
    run "chown -R www-data:www-data /var/www/html/"
    run "find /var/www/html -type d -exec chmod 755 {} \\;"
    run "find /var/www/html -type f -exec chmod 644 {} \\;"

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

    run "a2enmod rewrite"
    run "systemctl reload apache2"
    [[ "$DRY_RUN" != true ]] && wait_for_service apache2

    # Configure firewall
    configure_firewall

    # Final summary
    success "=== Installation Complete ==="
    info "Web server: http://$(hostname -I | awk '{print $1}')"
    info "WordPress: http://$(hostname -I | awk '{print $1}')/wp-admin/install.php"
    info ""
    info "Database credentials:"
    info "  Database: ${WP_DB_NAME}"
    info "  User: ${WP_DB_USER}"
    info "  Password: ${WP_DB_PASSWORD}"
    info "  MySQL root password: ${MYSQL_ROOT_PASSWORD}"
    info ""
    warn "IMPORTANT: Save the above credentials! They are also logged to ${LOG_FILE}"
    info "=== SwiftWebSetup: Web Install Finished ==="
}

# Run main
main "$@"