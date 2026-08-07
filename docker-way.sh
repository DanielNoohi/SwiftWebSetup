#!/usr/bin/env bash
#
# SwiftWebSetup - docker-way.sh
# Docker-based WordPress deployment: wordpress + mariadb via Docker Compose
# (WordPress install completed via the wordpress:cli image, not the install wizard)
#
# Usage: sudo bash docker-way.sh [--dry-run] [--unattended] [--force] [--name NAME] [--port PORT] [--domain D] [--title T] [--admin U] [--email E]
#   --dry-run      Show what would be done without executing
#   --unattended   Non-interactive mode
#   --force        Recreate project (wipe volumes) and reinstall
#   --name NAME    Project/container prefix (default: swiftweb)
#   --port PORT    Host port to publish WordPress (default: 80)
#   --domain D     Site domain (default: server IP)
#   --title T      Site title
#   --admin U      Admin username
#   --email E      Admin email
#
# Environment variables (unattended):
#   PROJECT_NAME WORDPRESS_PORT DOMAIN SITE_TITLE ADMIN_USER ADMIN_PASSWORD ADMIN_EMAIL
#   MYSQL_ROOT_PASSWORD WP_DB_PASSWORD WP_DB_NAME WP_DB_USER

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
export RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/swiftwebsetup-docker-way.log"
CREDENTIALS_FILE="/root/swiftwebsetup-docker-credentials.txt"
DRY_RUN=false
UNATTENDED=false
FORCE=false
DOMAIN=""
SITE_TITLE=""
ADMIN_USER=""
ADMIN_EMAIL=""
PROJECT_NAME="${PROJECT_NAME:-swiftweb}"
WORDPRESS_PORT="${WORDPRESS_PORT:-80}"
COMPOSE_DIR="/opt/${PROJECT_NAME}"

# ── Logging (secrets NEVER to LOG_FILE) ───────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}
info()    { log "INFO"    "${BLUE}$*${NC}"; }
warn()    { log "WARN"    "${YELLOW}$*${NC}"; }
error()   { log "ERROR"   "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

credential() { echo "$*" >> "$CREDENTIALS_FILE"; }

log_cmd() {
    local line="$1"
    line=${line//"$WP_DB_PASSWORD"/"********"}
    line=${line//"$ADMIN_PASSWORD"/"********"}
    line=${line//"$MYSQL_ROOT_PASSWORD"/"********"}
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CMD] ${line}" >> "$LOG_FILE" 2>/dev/null || true
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    log_cmd "$*"
    "$@" || { error "Command failed: $*"; return 1; }
}

# ── Arg parsing (error() defined above; source-safe guard for bats) ──
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --unattended) UNATTENDED=true; shift ;;
        --force)      FORCE=true; shift ;;
        --name)       PROJECT_NAME="$2"; COMPOSE_DIR="/opt/${PROJECT_NAME}"; shift 2 ;;
        --port)       WORDPRESS_PORT="$2"; shift 2 ;;
        --domain)     DOMAIN="$2"; shift 2 ;;
        --title)      SITE_TITLE="$2"; shift 2 ;;
        --admin)      ADMIN_USER="$2"; shift 2 ;;
        --email)      ADMIN_EMAIL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo bash $SCRIPT_NAME [opts]"
            echo "  --dry-run      preview (no changes)"
            echo "  --unattended   non-interactive (env vars)"
            echo "  --force        recreate project (wipe volumes) and reinstall"
            echo "  --name NAME    project prefix (default: swiftweb)"
            echo "  --port PORT    host port for WordPress (default: 80)"
            echo "  --domain D     site domain (default: server IP)"
            echo "  --title T      site title"
            echo "  --admin U      admin username"
            echo "  --email E      admin email"
            exit 0 ;;
        *) error "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
fi

# ── Guards ────────────────────────────────────────────────────────────
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

# Cryptographically strong password (python3 secrets; urandom fallback)
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

ask_password() {
    if [[ "$UNATTENDED" == true ]] || [[ -n "${ADMIN_PASSWORD:-}" ]]; then
        [[ -z "${ADMIN_PASSWORD:-}" ]] && ADMIN_PASSWORD=$(gen_password)
        return
    fi
    local entered=""
    read -s -r -p "Admin password (Enter to auto-generate): " entered; echo
    if [[ -n "$entered" ]]; then
        ADMIN_PASSWORD="$entered"
    else
        ADMIN_PASSWORD=$(gen_password)
    fi
}

server_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

get_site_url() {
    if [[ -n "$DOMAIN" ]]; then
        printf 'http://%s' "$DOMAIN"
    else
        local ip; ip=$(server_ip)
        if [[ "$WORDPRESS_PORT" == "80" ]]; then
            printf 'http://%s' "$ip"
        else
            printf 'http://%s:%s' "$ip" "$WORDPRESS_PORT"
        fi
    fi
}

# ── Docker install (no fragile pipes; files on disk first) ────────────
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        info "Docker + Compose plugin already installed"
        return 0
    fi
    info "Installing Docker..."
    run_cmd apt-get update
    run_cmd apt-get install -y ca-certificates curl gnupg
    run_cmd install -d -m 0755 /etc/apt/keyrings
    local keyring="/etc/apt/keyrings/docker.gpg"
    local list="/etc/apt/sources.list.d/docker.list"
    if [[ ! -f "$keyring" ]]; then
        run_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker-gpg
        run_cmd gpg --dearmor -o "$keyring" /tmp/docker-gpg
        run_cmd chmod a+r "$keyring"
    fi
    if [[ ! -f "$list" ]]; then
        run_cmd bash -c "echo 'deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable' > $list"
    fi
    run_cmd apt-get update
    run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    run_cmd systemctl enable --now docker
    success "Docker installed"
}

# ── Compose project (prints ONLY the directory on stdout) ────────────
create_compose_file() {
    local dir="$COMPOSE_DIR"
    info "Creating project directory $dir" >&2
    run_cmd mkdir -p "$dir"

    cat > "$dir/docker-compose.yml" <<EOF
services:
  db:
    image: mariadb:10.11
    container_name: ${PROJECT_NAME}-db
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: \${WP_DB_NAME}
      MARIADB_USER: \${WP_DB_USER}
      MARIADB_PASSWORD: \${WP_DB_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - ${PROJECT_NAME}_net
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 12

  wordpress:
    image: wordpress:6.7-php8.3-apache
    container_name: ${PROJECT_NAME}-wordpress
    restart: unless-stopped
    ports:
      - "${WORDPRESS_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: \${WP_DB_NAME}
      WORDPRESS_DB_USER: \${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WP_DB_PASSWORD}
    volumes:
      - wp_data:/var/www/html
    networks:
      - ${PROJECT_NAME}_net
    depends_on:
      db:
        condition: service_healthy

  # WP-CLI runner: wordpress:latest image has NO wp binary; this one does.
  # Shares the same wp_data volume so it operates on the same files.
  wpcli:
    image: wordpress:cli-php8.3
    container_name: ${PROJECT_NAME}-wpcli
    restart: "no"
    user: "33:33"
    volumes:
      - wp_data:/var/www/html
    networks:
      - ${PROJECT_NAME}_net
    depends_on:
      - db
    entrypoint: ["/bin/sh", "-c", "sleep infinity"]

volumes:
  db_data:
  wp_data:

networks:
  ${PROJECT_NAME}_net:
EOF

    cat > "$dir/.env" <<EOF
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
WP_DB_NAME=$WP_DB_NAME
WP_DB_USER=$WP_DB_USER
WP_DB_PASSWORD=$WP_DB_PASSWORD
EOF
    run_cmd chmod 600 "$dir/.env"

    printf '%s\n' "$dir"  # the ONLY stdout
}

# ── WordPress completion via wpcli service ────────────────────────────
complete_wp_install() {
    local dir="$1" url="$2"
    local dc=(docker compose -f "$dir/docker-compose.yml")

    info "Waiting for WordPress to be ready..."
    local t=120 i=0
    # Readiness: wp CLI responds (wp core version works even before install)
    while (( i < t )); do
        if "${dc[@]}" exec -T wpcli wp core version --path=/var/www/html --allow-root >/dev/null 2>&1; then
            break
        fi
        sleep 2; ((i+=2))
    done
    if (( i >= t )); then
        error "wpcli container did not become ready in time"
        "${dc[@]}" logs wpcli 2>/dev/null | tail -20 || true
        return 1
    fi

    # If already installed (previous run, no --force), leave it.
    if "${dc[@]}" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
        warn "WordPress already installed — leaving site intact (use --force to reinstall)"
        return 0
    fi

    info "Running wp core install via wpcli service..."
    "${dc[@]}" exec -T wpcli wp core install \
        --path=/var/www/html \
        --url="$url" \
        --title="$SITE_TITLE" \
        --admin_user="$ADMIN_USER" \
        --admin_password="$ADMIN_PASSWORD" \
        --admin_email="$ADMIN_EMAIL" \
        --skip-email --allow-root || { error "wp core install failed"; return 1; }

    "${dc[@]}" exec -T wpcli wp rewrite structure '/%postname%/' --path=/var/www/html --hard --allow-root || true
    [[ -n "$DOMAIN" ]] && "${dc[@]}" exec -T wpcli wp option update siteurl "$url" --path=/var/www/html --allow-root || true
    [[ -n "$DOMAIN" ]] && "${dc[@]}" exec -T wpcli wp option update home "$url" --path=/var/www/html --allow-root || true
    "${dc[@]}" exec -T wpcli wp plugin delete akismet --path=/var/www/html --allow-root || true
    # raw WordPress policy: keep bundled default themes
    return 0
}

verify_site() {
    local url="$1" dir="$2"
    local dc=(docker compose -f "$dir/docker-compose.yml")
    info "Verifying site at $url ..."
    if ! "${dc[@]}" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
        error "VERIFICATION FAILED: wp core is-installed reports NOT installed"
        return 1
    fi
    local body
    body=$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)
    if [[ "$body" =~ wp-content || "$body" =~ wp-includes || "$body" =~ wp-json ]]; then
        success "Verified: $url serves a WordPress site"
        return 0
    fi
    error "VERIFICATION FAILED: $url did not return a WordPress page"
    return 1
}

configure_firewall() {
    info "Configuring UFW (SSH first, then WordPress port)..."
    run_cmd ufw allow OpenSSH
    run_cmd ufw allow "$WORDPRESS_PORT/tcp"
    run_cmd ufw --force enable
    run_cmd ufw status
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
    info "=== SwiftWebSetup: Docker WordPress ==="
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN: nothing will be changed"

    check_root
    check_os

    DOMAIN="${DOMAIN:-${SITE_URL_DOMAIN:-}}"
    SITE_TITLE="${SITE_TITLE:-${WP_SITE_TITLE:-My WordPress Site}}"
    ADMIN_USER="${ADMIN_USER:-${WP_ADMIN_USER:-admin}}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-${WP_ADMIN_EMAIL:-admin@example.com}}"
    WP_DB_NAME="${WP_DB_NAME:-wordpress}"
    WP_DB_USER="${WP_DB_USER:-wp_user}"
    WP_DB_PASSWORD="${WP_DB_PASSWORD:-$(gen_password)}"
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_password)}"
    ask_password

    SITE_URL="$(get_site_url)"

    run_cmd touch "$CREDENTIALS_FILE"
    run_cmd chmod 600 "$CREDENTIALS_FILE"
    credential "# SwiftWebSetup Docker credentials - $(date)"
    credential "Site URL:  $SITE_URL"
    credential "Admin user: $ADMIN_USER"
    credential "Admin pass: $ADMIN_PASSWORD"
    credential "Admin email: $ADMIN_EMAIL"
    credential "DB: db=$WP_DB_NAME user=$WP_DB_USER pass=$WP_DB_PASSWORD"
    credential "MariaDB root: $MYSQL_ROOT_PASSWORD"

    install_docker

    local dir
    dir=$(create_compose_file)   # stdout = path only
    info "Compose project at $dir"

    # Existing project: back off unless --force
    if [[ -d "$dir" ]] && [[ -f "$dir/docker-compose.yml" ]] && [[ "$FORCE" != true ]]; then
        if docker compose -f "$dir/docker-compose.yml" ps --status running >/dev/null 2>&1 \
           && docker compose -f "$dir/docker-compose.yml" exec -T wpcli wp core is-installed --path=/var/www/html --allow-root >/dev/null 2>&1; then
            warn "WordPress already deployed at $dir."
            warn "Re-run with --force to recreate containers/volumes and reinstall."
            exit 0
        fi
    fi

    if [[ "$FORCE" == true ]]; then
        warn "Force mode: removing existing project containers + volumes..."
        run_cmd docker compose -f "$dir/docker-compose.yml" down -v 2>/dev/null || true
    fi

    info "Starting containers (db + wordpress + wpcli)..."
    run_cmd docker compose -f "$dir/docker-compose.yml" up -d

    complete_wp_install "$dir" "$SITE_URL"
    configure_firewall
    verify_site "$SITE_URL" "$dir"

    success "=== DONE ==="
    info "Site:       $SITE_URL"
    info "Admin URL:  $SITE_URL/wp-admin/"
    info "Project:    $dir"
    info "Credentials: $CREDENTIALS_FILE (0600)"
    info "Log:        $LOG_FILE"
    info "Manage:     docker compose -f $dir/docker-compose.yml up -d|down|logs -f"
    warn "Re-run with --force to recreate and reinstall."
}

# Only run when executed directly (source-safe for bats/tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
