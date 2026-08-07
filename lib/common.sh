#!/usr/bin/env bash
# SwiftWebSetup - Shared Library

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" >&2
}

info()    { log "INFO"    "${BLUE}$*${NC}"; }
warn()    { log "WARN"    "${YELLOW}$*${NC}"; }
error()   { log "ERROR"   "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Credentials (append only to 0600 file)
credential() {
    local file="$1"; shift
    local msg="$*"
    echo "$msg" >> "$file"
}

# Safe run (logs scrubbed)
run_cmd() {
    local scrubbed="$*"
    # Scrub passwords from logs
    scrubbed=$(echo "$scrubbed" | sed -E 's/--admin_password=[^ ]+/--admin_password=******** /g; s/--admin-password=[^ ]+/--admin-password=******** /g; s/PASSWORD\("[^"]+"\)/PASSWORD("********")/g; s/IDENTIFIED BY "[^"]+"/IDENTIFIED BY "********"/g; s/IDENTIFIED BY '\''[^'\'']+'\''/IDENTIFIED BY '\''********'\''/g')
    
    log "CMD" "$scrubbed"
    "$@" || { error "Command failed: $scrubbed"; return 1; }
}

check_root() {
    [[ $EUID -eq 0 ]] || { error "Please run as root (sudo)."; exit 1; }
}

check_os() {
    [[ -f /etc/os-release ]] || { error "Cannot determine OS"; exit 1; }
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || ! [[ "$VERSION_ID" =~ ^(20\.04|22\.04|24\.04)$ ]]; then
        warn "Untested on $PRETTY_NAME. Current support: Ubuntu 20.04/22.04/24.04."
        [[ "${UNATTENDED:-false}" == true ]] || { read -rp "Continue anyway? (y/N) " ch; [[ "$ch" =~ ^[Yy]$ ]] || exit 1; }
    fi
}

ensure_python() {
    command -v python3 &>/dev/null || { info "Installing python3 for secure password gen..."; apt-get update -qq && apt-get install -y python3; }
}

gen_password() {
    local len="${1:-32}"
    if command -v python3 &>/dev/null; then
        python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits + '!@#%^*_-+=<>~') for _ in range($len)))"
    else
        tr -dc 'A-Za-z0-9!@#%^*_-+=<>~' </dev/urandom | head -c "$len"
    fi
}

server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' | cut -d' ' -f1
}

get_site_url() {
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "http://${DOMAIN}"
    else
        echo "http://$(server_ip)"
    fi
}
