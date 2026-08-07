#!/usr/bin/env bash
#
# SwiftWebSetup - install.sh
# One-command WordPress production bootstrap entrypoint
#
# Usage (unattended/pipe-safe):
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --unattended
#
# Interactive (recommended: download first so read prompts work):
#   curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh -o /tmp/swiftweb-install.sh
#   sudo bash /tmp/swiftweb-install.sh
#
# Options:
#   --docker        Use Docker-based deployment (default: host LAMP)
#   --unattended    Non-interactive (inputs from env vars)
#   --force         Wipe existing install and reinstall
#   --domain D      Site domain (default: server IP)
#   --title T       WordPress site title
#   --admin U       Admin username
#   --email E       Admin email
#   --name N        (docker) project/container prefix
#   --port P        (docker) host port for WordPress
#   --dry-run       Preview changes without executing
#   -h, --help      Show help

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

export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
info()    { echo -e "${BLUE}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }
error()   { echo -e "${RED}$*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}"; }

REPO_URL="https://github.com/DanielNoohi/SwiftWebSetup"
RAW_URL="https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main"
REPO_DIR="/tmp/SwiftWebSetup"

# Modes
DEPLOY_MODE="lamp"
UNATTENDED=false
DRY_RUN=false
FORCE=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""
PROJECT_NAME=""
WORDPRESS_PORT=""

show_help() {
    cat <<EOF
SwiftWebSetup - One-Command WordPress Production Bootstrap

USAGE (pipe-safe, unattended):
    curl -fsSL $RAW_URL/install.sh | sudo bash -s -- --unattended [OPTS]

INTERACTIVE (recommended so prompts work):
    curl -fsSL $RAW_URL/install.sh -o /tmp/swiftweb-install.sh
    sudo bash /tmp/swiftweb-install.sh [OPTS]

OPTIONS:
    --docker          Docker deployment (default: host LAMP)
    --unattended      Non-interactive (inputs from env vars)
    --force           Wipe existing install and reinstall
    --domain D        Site domain (default: server IP)
    --title T         WordPress site title
    --admin U         Admin username
    --email E         Admin email
    --name N          (docker) project/container prefix
    --port P          (docker) host port for WordPress
    --dry-run         Preview changes without executing
    -h, --help        Show this help

ENV VARS (unattended):
    SITE_TITLE ADMIN_USER ADMIN_PASSWORD ADMIN_EMAIL DOMAIN FORCE
    WP_DB_NAME WP_DB_USER WP_DB_PASSWORD MYSQL_ROOT_PASSWORD
    PROJECT_NAME WORDPRESS_PORT

EXAMPLES:
    # interactive host LAMP
    sudo bash /tmp/swiftweb-install.sh

    # unattended with domain
    curl -fsSL $RAW_URL/install.sh | sudo SITE_TITLE="My Site" ADMIN_EMAIL="me@example.com" DOMAIN="example.com" bash -s -- --unattended

    # docker path on port 8080
    curl -fsSL $RAW_URL/install.sh | sudo bash -s -- --docker --port 8080 --unattended

    # dry-run preview
    curl -fsSL $RAW_URL/install.sh | sudo bash -s -- --dry-run
EOF
}

# ── Arg parsing (source-safe guard for bats) ─────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)      DEPLOY_MODE="docker"; shift ;;
        --unattended)  UNATTENDED=true; shift ;;
        --force)       FORCE=true; shift ;;
        --domain)      DOMAIN="$2"; shift 2 ;;
        --title)       SITE_TITLE="$2"; shift 2 ;;
        --admin)       ADMIN_USER="$2"; shift 2 ;;
        --email)       ADMIN_EMAIL="$2"; shift 2 ;;
        --name)        PROJECT_NAME="$2"; shift 2 ;;
        --port)        WORDPRESS_PORT="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     show_help; exit 0 ;;
        *) error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done
fi

check_root() {
    [[ $EUID -eq 0 ]] || { error "Please run as root (sudo)."; exit 1; }
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

fetch_scripts() {
    info "Fetching SwiftWebSetup scripts..."
    if [[ -d "$REPO_DIR/.git" ]]; then
        # Refresh existing checkout
        if (cd "$REPO_DIR" && git rev-parse --git-dir >/dev/null 2>&1); then
            (cd "$REPO_DIR" && git fetch --depth 1 origin && git reset --hard origin/main) || true
        else
            warn "$REPO_DIR exists but is not a git checkout — replacing"
            rm -rf "$REPO_DIR"
        fi
    fi
    if [[ ! -d "$REPO_DIR/.git" ]]; then
        if ! git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
            warn "git clone failed — falling back to direct script download"
            mkdir -p "$REPO_DIR"
            for f in web-install.sh docker-way.sh; do
                curl -fsSL "$RAW_URL/$f" -o "$REPO_DIR/$f" || { error "Failed to fetch $f"; exit 1; }
            done
        fi
    fi
    chmod +x "$REPO_DIR"/*.sh 2>/dev/null || true
}

main() {
    check_root
    check_os

    # Export everything so child scripts pick it up (env beats flags if both)
    export DOMAIN SITE_TITLE ADMIN_USER ADMIN_EMAIL FORCE UNATTENDED DRY_RUN
    export PROJECT_NAME WORDPRESS_PORT

    fetch_scripts

    local inner=()
    [[ "$UNATTENDED" == true ]] && inner+=(--unattended)
    [[ "$DRY_RUN" == true ]] && inner+=(--dry-run)
    [[ "$FORCE" == true ]] && inner+=(--force)
    [[ -n "$DOMAIN" ]] && inner+=(--domain "$DOMAIN")
    [[ -n "$SITE_TITLE" ]] && inner+=(--title "$SITE_TITLE")
    [[ -n "$ADMIN_USER" ]] && inner+=(--admin "$ADMIN_USER")
    [[ -n "$ADMIN_EMAIL" ]] && inner+=(--email "$ADMIN_EMAIL")

    info "Starting ${DEPLOY_MODE^^} deployment..."

    if [[ "$DEPLOY_MODE" == "docker" ]]; then
        [[ -n "$PROJECT_NAME" ]] && inner+=(--name "$PROJECT_NAME")
        [[ -n "$WORDPRESS_PORT" ]] && inner+=(--port "$WORDPRESS_PORT")
        (cd "$REPO_DIR" && bash docker-way.sh "${inner[@]}")
    else
        (cd "$REPO_DIR" && bash web-install.sh "${inner[@]}")
    fi

    success "Deployment complete!"
    info "Credentials: /root/swiftwebsetup-credentials.txt or /root/swiftwebsetup-docker-credentials.txt (0600)"
}

# Only run when executed directly (source-safe for bats/tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
