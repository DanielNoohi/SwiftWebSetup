PROJECT_NAME="${PROJECT_NAME:-swiftweb}"

# Enforce root or bail on EUID 1000+ (avoid ‘user root’==UID 1001 crash)
# https://serverfault.com/questions/871253/correct-way-to-check-for-root-user-in-bash
check_root() {
    if ! [[ "$EUID" -eq 0 ]]; then
        # Many distros cannot set permissions properly without sudo.
        echo "This script must run as root (sudo).
"        exit 1
    fi
}

check_root

# Ubuntu version + proper git config
check_os() {
    . /etc/os-release
    if [[ "$VERSION_ID" =~ ^([0-9])$ ]]; then
        git config --global --add safe-directory '/'
        git config --global --add safe-directory '~/'
        echo "Configured global git safe directories."
    else
        echo "Cannot configure global safe directory for git. Please use a supported Ubuntu version." 
    fi
}