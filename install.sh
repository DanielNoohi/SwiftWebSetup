#!/usr/bin/env bash
#
# SwiftWebSetup - install.sh
# One-command WordPress production bootstrap entrypoint
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --docker
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --unattended --domain example.com
#
# Options:
#   --docker        Use Docker-based deployment (default: traditional LAMP)
#   --unattended    Non-interactive mode (requires env vars)
#   --domain DOMAIN Set site domain (default: server IP)
#   --title TITLE   WordPress site title (default: "My WordPress Site")
#   --admin USER    Admin username (default: "admin")
#   --email EMAIL   Admin email (default: admin@domain)
#   --dry-run       Preview changes without executing
#   -h, --help      Show this help

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
REPO_URL="https://github.com/DanielNoohi/SwiftWebSetup"
RAW_URL="https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main"
DEPLOY_MODE="lamp"  # lamp or docker
UNATTENDED=false
DRY_RUN=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""

# Function definitions
info() { echo -e "${BLUE}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
error() { echo -e "${RED}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }

show_help() {
    cat << EOF
SwiftWebSetup - One-Command WordPress Production Bootstrap

USAGE:
    curl -fsSL ${RAW_URL}/install.sh | sudo bash [OPTIONS]

OPTIONS:
    --docker            Use Docker-based deployment (WordPress + MariaDB containers)
    --unattended        Non-interactive mode (requires environment variables)
    --domain DOMAIN     Set site domain (e.g., example.com)
    --title TITLE       WordPress site title
    --admin USER        Admin username
    --email EMAIL       Admin email
    --dry-run           Preview changes without executing
    -h, --help          Show this help

ENVIRONMENT VARIABLES (for --unattended):
    SITE_TITLE          WordPress site title
    ADMIN_USER          WordPress admin username
    ADMIN_PASSWORD      WordPress admin password (auto-generated if not set)
    ADMIN_EMAIL         WordPress admin email
    WP_DB_PASSWORD      WordPress database password (auto-generated if not set)
    MYSQL_ROOT_PASSWORD MySQL root password (auto-generated if not set)
    DOMAIN              Site domain (optional)

DEPLOYMENT METHODS:
    Traditional (LAMP): Apache + PHP + MariaDB + WordPress on host
    Docker:             WordPress + MariaDB containers via Docker Compose

EXAMPLES:
    # Interactive traditional deployment
    curl -fsSL ${RAW_URL}/install.sh | sudo bash

    # Interactive Docker deployment
    curl -fsSL ${RAW_URL}/install.sh | sudo bash -s -- --docker

    # Unattended traditional
    curl -fsSL ${RAW_URL}/install.sh | sudo SITE_TITLE="My Site" ADMIN_EMAIL="me@example.com" DOMAIN="example.com" bash -s -- --unattended

    # Dry-run to preview
    curl -fsSL ${RAW_URL}/install.sh | sudo bash -s -- --dry-run

REQUIREMENTS:
    - Ubuntu 20.04/22.04/24.04
    - Root/sudo access
    - Internet connectivity

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --docker)
            DEPLOY_MODE="docker"
            shift
            ;;
        --unattended)
            UNATTENDED=true
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
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

# Export variables for downstream scripts
export DOMAIN SITE_TITLE ADMIN_USER ADMIN_EMAIL UNATTENDED DRY_RUN

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

# Check OS
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

# Install dependencies
info "Installing base dependencies (curl, git, ca-certificates)..."
apt update -qq
apt install -y -qq curl ca-certificates git >/dev/null 2>&1

# Clone or update repository
REPO_DIR="/tmp/SwiftWebSetup"
info "Fetching SwiftWebSetup scripts..."
run_cmd() { "$@" || { error "Command failed: $*"; exit 1; }; }
if [[ -d "$REPO_DIR/.git" ]]; then
    run_cmd cd "$REPO_DIR"
    run_cmd git fetch origin
    run_cmd git reset --hard origin/main
else
    run_cmd git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

# Run the appropriate installer
cd "$REPO_DIR"
chmod +x web-install.sh docker-way.sh

# Forward flags to inner installer
INNER_ARGS=()
[[ "$UNATTENDED" == true ]] && INNER_ARGS+=(--unattended)
[[ "$DRY_RUN" == true ]] && INNER_ARGS+=(--dry-run)

info "Starting ${DEPLOY_MODE^^} deployment..."

if [[ "$DEPLOY_MODE" == "docker" ]]; then
    export PROJECT_NAME="${PROJECT_NAME:-swiftweb}"
    export WORDPRESS_PORT="${WORDPRESS_PORT:-80}"
    run_cmd bash docker-way.sh "${INNER_ARGS[@]}"
else
    run_cmd bash web-install.sh "${INNER_ARGS[@]}"
fi

success "Deployment complete!"
info "See credentials in /root/swiftwebsetup-credentials.txt (LAMP) or /root/swiftwebsetup-docker-credentials.txt (Docker)"
