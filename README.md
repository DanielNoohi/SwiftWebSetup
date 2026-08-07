# SwiftWebSetup

One-command raw WordPress production bootstrap for Ubuntu — official WordPress from wordpress.org, fully installed and ready to use. No test pages, no "It works!", no install wizard left for you to click through.

## What you get

A **fully fledged WordPress website** — not a demo:

- Official WordPress core from https://wordpress.org/latest.tar.gz (raw, unmodified)
- MariaDB database + least-privilege dedicated DB user
- `wp-config.php` fully written (DB_* + fresh salts via `wp config shuffle-salts`)
- Installation **completed automatically** via WP-CLI (`wp core install`) with site title, admin user + strong password, admin email, and siteurl/home set to your server IP or domain
- Pretty permalinks working (`/%postname%/`) with Apache rewrite + `.htaccess` `AllowOverride All`
- Security hardening: UFW (SSH + HTTP/HTTPS), hardened `.htaccess` (security headers, wp-config protection, no directory listing), secure file ownership/permissions
- Root-only credentials file (`/root/swiftwebsetup-credentials.txt`, 0600)

Visiting `http://SERVER_IP` shows the WordPress front page. Done.

## One-command setup

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh -o /tmp/swiftweb-install.sh && sudo bash /tmp/swiftweb-install.sh
```

(Interactive mode needs the two-step form so the prompts can read your terminal. For fully unattended installs you can pipe directly.)

### Unattended (automation / CI)

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo SITE_TITLE="My Site" ADMIN_EMAIL="me@example.com" DOMAIN="example.com" bash -s -- --unattended
```

### Options

| Flag | Effect |
|------|--------|
| `--docker` | Deploy WordPress + MariaDB as Docker containers instead of host LAMP |
| `--unattended` | Non-interactive (all inputs from env vars) |
| `--domain DOMAIN` | Set site domain (default: server IP) |
| `--title TITLE` | WordPress site title |
| `--admin USER` | Admin username |
| `--email EMAIL` | Admin email |
| `--dry-run` | Preview changes without executing |

### Environment variables (unattended)

`SITE_TITLE`, `ADMIN_USER`, `ADMIN_PASSWORD`, `ADMIN_EMAIL`, `DOMAIN`, `WP_DB_NAME`, `WP_DB_USER`, `WP_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`. Any password not provided is auto-generated (32 chars, `/dev/urandom`-seeded via Python `secrets`) and saved to the root-only credentials file.

## What it installs (LAMP path, web-install.sh)

1. **System**: `apt update`, Apache2, PHP 8.x + extensions (mysql, curl, gd, mbstring, xml, zip, opcache, intl, imagick with graceful fallback), MariaDB server
2. **Database**: MariaDB hardened (root password set, anonymous users removed, test DB dropped — MariaDB 10.5+ compatible auth), WordPress DB + least-privilege user created
3. **WordPress**: official core downloaded, extracted to `/var/www/html` (previous content backed up, not destroyed), `wp-config.php` written via WP-CLI, salts shuffled
4. **Install**: WP-CLI `wp core install` completes the site (idempotent — skips if already installed), permalinks set, default plugins/themes cleaned
5. **Hardening**: UFW firewall, `.htaccess` with security headers + rewrite rules, `www-data` ownership, 755/644 permissions

## Docker path (docker-way.sh)

- Docker + Compose plugin installed if missing
- `mariadb:10.11` + `wordpress:latest` containers with healthchecks, named volumes, restart policy
- WP-CLI runs inside the container to complete the install (`wp core install`, permalinks, cleanup)
- Project in `/opt/<name>/` with `docker-compose.yml` + 0600 `.env`
- Credentials in `/root/swiftwebsetup-docker-credentials.txt`

## Idempotency & safety

- Re-runs are safe: existing `/var/www/html` is backed up (timestamped copy) before replacement, `wp core install` skips if already installed
- All stateful changes guarded by `set -euo pipefail` — script fails fast, never half-installs
- `run_cmd` uses proper array execution — no `eval`, no quoting/command-injection issues
- CRLF self-heal: scripts converted from Windows line endings if edited on Windows
- Dry-run mode previews every step

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Root or sudo access
- Outbound internet access (apt, wordpress.org, wp-cli)

## Logs & credentials

| Artifact | Path |
|----------|------|
| LAMP credentials (0600) | `/root/swiftwebsetup-credentials.txt` |
| Docker credentials (0600) | `/root/swiftwebsetup-docker-credentials.txt` |
| LAMP log | `/var/log/swiftwebsetup-web-install.log` |
| Docker log | `/var/log/swiftwebsetup-docker-way.log` |

Secrets go only to the 0600 credentials file and the terminal — never to the world-readable log.

## License

MIT — see [LICENSE](LICENSE).
