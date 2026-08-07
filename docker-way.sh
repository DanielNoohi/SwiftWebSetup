#!/usr/bin/env bash
#
# SwiftWebSetup - docker-way.sh
# Docker-based Nginx web server deployment
#
# Usage: sudo bash docker-way.sh [--dry-run] [--unattended] [--name CONTAINER_NAME] [--port PORT]
#   --dry-run      Show what would be done without executing
#   --unattended   Non-interactive mode
#   --name         Container name (default: swiftweb-nginx)
#   --port         Host port to publish (default: 80)
#
# Environment variables for unattended mode:
#   DOCKER_NAME        Container name
#   DOCKER_PORT        Host port to publish

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-docker-way.log"
DRY_RUN=false
UNATTENDED=false
DOCKER_NAME="${DOCKER_NAME:-swiftweb-nginx}"
DOCKER_PORT="${DOCKER_PORT:-80}"
DATA_DIR="/data"

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
            DOCKER_NAME="$2"
            shift 2
            ;;
        --port)
            DOCKER_PORT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo bash $SCRIPT_NAME [--dry-run] [--unattended] [--name NAME] [--port PORT]"
            echo "  --dry-run      Show what would be done without executing"
            echo "  --unattended   Non-interactive mode"
            echo "  --name NAME    Container name (default: swiftweb-nginx)"
            echo "  --port PORT    Host port to publish (default: 80)"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
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

# Check if Docker is installed
check_docker() {
    if ! command -v docker &>/dev/null; then
        error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    info "Docker version: $(docker --version)"
}

# Check if container already exists
check_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${DOCKER_NAME}$"; then
        warn "Container '${DOCKER_NAME}' already exists"
        if [[ "$UNATTENDED" == true ]]; then
            info "Unattended mode: removing existing container"
            run "docker rm -f ${DOCKER_NAME}"
        else
            read -rp "Remove existing container? (y/N) " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                run "docker rm -f ${DOCKER_NAME}"
            else
                error "Container name conflict. Use --name to specify a different name."
                exit 1
            fi
        fi
    fi
}

# Create data directory
create_data_dir() {
    info "Creating data directory at ${DATA_DIR}..."
    run "mkdir -p ${DATA_DIR}"
    run "chown -R 101:101 ${DATA_DIR}"  # nginx user in container
}

# Pull nginx image
pull_image() {
    info "Pulling nginx image..."
    run "docker pull nginx:latest"
}

# Run nginx container
run_container() {
    info "Starting nginx container '${DOCKER_NAME}' on port ${DOCKER_PORT}..."
    run "docker run --detach \\
        --name ${DOCKER_NAME} \\
        --publish ${DOCKER_PORT}:80 \\
        --volume ${DATA_DIR}:/usr/share/nginx/html \\
        --restart unless-stopped \\
        nginx:latest"
}

# Verify container is running
verify_container() {
    if [[ "$DRY_RUN" != true ]]; then
        local timeout=30
        local elapsed=0
        while ! docker ps --format '{{.Names}}' | grep -q "^${DOCKER_NAME}$"; do
            sleep 1
            ((elapsed++))
            if [[ $elapsed -ge $timeout ]]; then
                error "Container ${DOCKER_NAME} did not start within ${timeout}s"
                docker logs "${DOCKER_NAME}"
                return 1
            fi
        done
        success "Container ${DOCKER_NAME} is running"
    fi
}

# Show container info
show_info() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    success "=== Deployment Complete ==="
    info "Nginx container: ${DOCKER_NAME}"
    info "Port mapping: ${DOCKER_PORT}:80"
    info "Data directory: ${DATA_DIR}"
    info "Web server: http://${ip}:${DOCKER_PORT}"
    info ""
    info "To view logs: docker logs ${DOCKER_NAME}"
    info "To stop: docker stop ${DOCKER_NAME}"
    info "To remove: docker rm -f ${DOCKER_NAME}"
    info "=== SwiftWebSetup: Docker Way Finished ==="
}

# Main
main() {
    info "=== SwiftWebSetup: Docker Way Started ==="
    info "Log file: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE - No changes will be made"

    check_root
    check_os
    check_docker
    check_container
    create_data_dir
    pull_image
    run_container
    verify_container
    show_info
}

main "$@"