#!/usr/bin/env bash
#
# SwiftWebSetup - docker-way.sh
# Docker-based WordPress deployment (WordPress + MariaDB via Docker Compose)
#
# Usage: sudo bash docker-way.sh [--dry-run] [--unattended] [--name PROJECT_NAME] [--port PORT]
#   --dry-run      Show what would be done without executing
#   --unattended   Non-interactive mode
#   --name         Project/container prefix (default: swiftweb)
#   --port         Host port to publish WordPress (default: 80)
#
# Environment variables for unattended mode:
#   PROJECT_NAME        Container/project prefix
#   WORDPRESS_PORT      Host port for WordPress
#   MYSQL_ROOT_PASSWORD MySQL root password (auto-generated if not set)
#   WP_DB_PASSWORD      WordPress database password (auto-generated if not set)
#   SITE_TITLE          WordPress site title
#   ADMIN_USER          WordPress admin username
#   ADMIN_PASSWORD      WordPress admin password
#   ADMIN_EMAIL         WordPress admin email

set -euo pipefail

# Self-heal CRLF line endings (Windows-edited scripts)
if file "$0" | grep -q "CRLF"; then
    echo "[*] Converting script line endings from CRLF to LF..."
    tmpfix=$(mktemp)
    tr -d '\r' < "$0" > "$tmpfix"
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
LOG_FILE="/var/log/swiftwebsetup-docker-way.log"
CREDENTIALS_FILE="/root/swiftwebsetup-docker-credentials.txt"
DRY_RUN=false
UNATTENDED=false
PROJECT_NAME="${PROJECT_NAME:-swiftweb}"
WORDPRESS_PORT="${WORDPRESS_PORT:-80}"

# Function definitions first
log_to_file() {
    local level="$1" msg="$2" timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1" msg="$2"
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

run_cmd() {
    [[ "$DRY_RUN" == true ]] && info "[DRY-RUN] Would execute: $*" && return 0
    log_to_file "CMD" "$*"
    "$@" || {
        error "Command failed: $*"
        return 1
    }
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --unattended)
            UNATTENDED=true
            shift
            ;;
        --name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --port)
            WORDPRESS_PORT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo bash $SCRIPT_NAME [--dry-run] [--unattended] [--name NAME] [--port PORT]"
            echo "  --dry-run      Show what would be done without executing"
            echo "  --unattended   Non-interactive mode"
            echo "  --name NAME    Project/container prefix (default: swiftweb)"
            echo "  --port PORT    Host port to publish WordPress (default: 80)"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

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
    # Shell/SQL-safe charset: no $, backtick, backslash, quote, or space
    pass=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!@#%^*_-+=~'
print(''.join(secrets.choice(alphabet) for _ in range($len)))
")
    printf '%s' "$pass"
}

# Install Docker if not present
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        info "Docker and Docker Compose already installed"
        return 0
    fi
    
    info "Installing Docker..."
    run_cmd apt update
    run_cmd apt install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    run_cmd install -m 0755 -d /etc/apt/keyrings
    run_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_cmd chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | run_cmd tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    run_cmd apt update
    run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    run_cmd systemctl enable docker
    run_cmd systemctl start docker
    
    success "Docker installed successfully"
}

# Create docker-compose.yml
create_compose_file() {
    local compose_dir="/opt/${PROJECT_NAME}"
    
    info "Creating project directory at ${compose_dir}..."
    run_cmd mkdir -p "${compose_dir}"
    
    info "Creating docker-compose.yml..."
    cat > "${compose_dir}/docker-compose.yml" << EOF
version: '3.8'

services:
  db:
    image: mariadb:10.11
    container_name: ${PROJECT_NAME}-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${WP_DB_NAME}
      MYSQL_USER: \${WP_DB_USER}
      MYSQL_PASSWORD: \${WP_DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - ${PROJECT_NAME}_network
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  wordpress:
    image: wordpress:latest
    container_name: ${PROJECT_NAME}-wordpress
    restart: unless-stopped
    ports:
      - "${WORDPRESS_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: \${WP_DB_NAME}
      WORDPRESS_DB_USER: \${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WP_DB_PASSWORD}
      WORDPRESS_TABLE_PREFIX: wp_
      WORDPRESS_DEBUG: 0
    volumes:
      - wp_data:/var/www/html
    networks:
      - ${PROJECT_NAME}_network
    depends_on:
      db:
        condition: service_healthy

volumes:
  db_data:
    driver: local
  wp_data:
    driver: local

networks:
  ${PROJECT_NAME}_network:
    driver: bridge
EOF

    # Create .env file for docker-compose
    cat > "${compose_dir}/.env" << EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
WP_DB_NAME=${WP_DB_NAME}
WP_DB_USER=${WP_DB_USER}
WP_DB_PASSWORD=${WP_DB_PASSWORD}
EOF

    run_cmd chmod 600 "${compose_dir}/.env"
    echo "${compose_dir}"
}

# Complete WordPress installation via WP-CLI in container
complete_wp_install() {
    local compose_dir="$1" site_url="$2"

    info "Waiting for WordPress container to be ready..."
    local timeout=120 elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp core version --path=/var/www/html --allow-root >/dev/null 2>&1; then
            success "WordPress container is ready"
            break
        fi
        sleep 2
        ((elapsed+=2))
    done

    if [[ $elapsed -ge $timeout ]]; then
        error "WordPress container did not become ready in time"
        docker compose -f "${compose_dir}/docker-compose.yml" logs wordpress
        return 1
    fi

    if docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
        warn "WordPress already installed, skipping core install"
    else
        info "Running WordPress core installation via WP-CLI..."
        run_cmd docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp core install \
            --path=/var/www/html \
            --url="${site_url}" \
            --title="${SITE_TITLE}" \
            --admin_user="${ADMIN_USER}" \
            --admin_password="${ADMIN_PASSWORD}" \
            --admin_email="${ADMIN_EMAIL}" \
            --skip-email --allow-root
    fi

    # Configure WordPress settings
    run_cmd docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp rewrite structure '/%postname%/' --path=/var/www/html --hard --allow-root
    run_cmd docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp option update timezone_string "UTC" --path=/var/www/html --allow-root
    run_cmd docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp plugin delete akismet hello --path=/var/www/html --allow-root || true
    run_cmd docker compose -f "${compose_dir}/docker-compose.yml" exec -T wordpress wp theme delete twentytwentythree twentytwentyfour --path=/var/www/html --allow-root || true

    success "WordPress installation completed in Docker"
}

# Main
main() {
    info "=== SwiftWebSetup: Docker WordPress Started ==="
    info "Log file: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE - No changes will be made"
    
    check_root
    check_os

    # Create credentials file with restrictive permissions
    run_cmd touch "${CREDENTIALS_FILE}"
    run_cmd chmod 600 "${CREDENTIALS_FILE}"
    echo "# SwiftWebSetup Docker Credentials - $(date)" > "${CREDENTIALS_FILE}"
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
        [[ -z "${ADMIN_PASSWORD:-}" ]] && ADMIN_PASSWORD=$(gen_password); read -s -p "Admin password [random generated]: " dummy; echo
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

    # Install Docker
    install_docker

    # Create docker-compose setup
    local compose_dir
    compose_dir=$(create_compose_file)

    # Start containers
    info "Starting WordPress + MariaDB containers..."
    run_cmd docker compose -f "${compose_dir}/docker-compose.yml" up -d

    # Wait for database to be healthy
    info "Waiting for database to be ready..."
    local timeout=120 elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if docker compose -f "${compose_dir}/docker-compose.yml" exec -T db mariadb-admin ping -h localhost >/dev/null 2>&1; then
            success "Database is ready"
            break
        fi
        sleep 2
        ((elapsed+=2))
    done

    if [[ $elapsed -ge $timeout ]]; then
        error "Database did not become ready in time"
        docker compose -f "${compose_dir}/docker-compose.yml" logs db
        exit 1
    fi

    # Complete WordPress installation
    local site_url
    if [[ -n "$DOMAIN" ]]; then
        site_url="http://${DOMAIN}"
    else
        site_url="http://$(hostname -I | awk '{print $1}'):${WORDPRESS_PORT}"
    fi
    
    complete_wp_install "${compose_dir}" "${site_url}"

    # Final summary
    success "=== Docker WordPress Deployment Complete ==="
    info "Site URL: ${site_url}"
    info "Admin URL: ${site_url}/wp-admin/"
    info "Project directory: ${compose_dir}"
    info ""
    credential "=== Quick Access ==="
    credential "Frontend: ${site_url}"
    credential "Admin: ${site_url}/wp-admin/"
    credential "Username: ${ADMIN_USER}"
    credential "Password: ${ADMIN_PASSWORD}"
    credential ""
    credential "=== Docker Management ==="
    credential "Start: docker compose -f ${compose_dir}/docker-compose.yml up -d"
    credential "Stop: docker compose -f ${compose_dir}/docker-compose.yml down"
    credential "Logs: docker compose -f ${compose_dir}/docker-compose.yml logs -f"
    credential ""
    warn "IMPORTANT: Credentials saved to ${CREDENTIALS_FILE}"
    warn "Log file: ${LOG_FILE}"
    info "=== SwiftWebSetup: Docker WordPress Finished ==="
}

main "$@"
