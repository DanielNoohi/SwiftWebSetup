# Changelog

## v1.0.0

Production-focused VPS WordPress bootstrap.

### Added
- Interactive site prompts (title, admin, email, domain, password, HTTPS offer)
- Credentials file written only after successful verification
- `host-install.sh` (canonical host path); `web-install.sh` kept as wrapper
- `--backup-only`, `--fail2ban`, `--auto-updates`
- PHP WordPress defaults (memory/upload/opcache)
- Post-install summary card
- Stronger MariaDB root auth handling (socket then password)
- ERR trap with reinstall hint

### Changed
- Dropped LAMP classroom branding (host vs Docker wording)
- Docker images default to `wordpress:php8.3-apache` + matching CLI
- Shared helpers expanded in `lib/common.sh`

### Fixed
- Apache default `index.html` shadowing WordPress
- `--force` now drops/recreates the WordPress database (host) / volumes (Docker)
- WP-CLI runs as `www-data` on host
