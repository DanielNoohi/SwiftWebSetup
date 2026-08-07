#!/usr/bin/env bash

# Arguments to the web-install.sh script
ARGS=($@)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: sudo bash install.sh [options]"
            echo "  --docker        Use Docker path (default: LAMP)"
            echo "  --unattended   Non-interactive mode"
            echo "  --force        Wipe files + DB and reinstall"
            echo "  --domain D     Set site domain (default: server IP)"
            echo "  --title T      Set site title"
            echo "  --admin U      Set admin username"
            echo "  --email E      Set admin email"
            echo "  --name N       (Docker) project name (default: swiftweb)"
            echo "  --port P       (Docker) host port for WordPress"
            echo "  --dry-run     Preview changes without executing"
            echo "  -h, --help  Show this help and exit"
            exit 0
            ;;
        --docker)
            DOCKER=true
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
        --domain)
            shift
            DOMAIN="$1"
            shift 2
            ;;
        --title)
            shift
            SITE_TITLE="$1"
            shift 2
            ;;
        --admin)
            shift
            ADMIN_USER="$1"
            shift 2
            ;;
        --email)
            shift
            ADMIN_EMAIL="$1"
            shift 2
            ;;
        --name)
            shift
            PROJECT_NAME="$1"
            shift 2
            ;;
        --port)
            shift
            WORDPRESS_PORT="$1"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
    [[ $1 =~ ^- ]]; shift

# Install WordPress
if [[ $DOCKER -eq true ]]; then
    # Docker setup
    echo "Docker setup"
else
    # LAMP setup
    echo "LAMP setup"
fi