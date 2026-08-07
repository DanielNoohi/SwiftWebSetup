# SwiftWebSetup

One-command **production WordPress** bootstrap for an Ubuntu VPS — official WordPress from wordpress.org, fully installed and ready to use. Not a demo, not a classroom stack, not an install wizard left for you to finish.

## What you get

A **fully fledged WordPress website** on your server:

- Official WordPress core from https://wordpress.org/latest.tar.gz (raw, unmodified, bundled default themes kept)
- MariaDB database + least-privilege dedicated DB user
- `wp-config.php` fully written (DB_* + real salts via `wp config shuffle-salts`)
- Installation **completed automatically** via WP-CLI as **www-data** (`wp core install`)
- Pretty permalinks (`/%postname%/`) with Apache rewrite + hardened `.htaccess`
- Apache default `index.html` removed; `DirectoryIndex` prefers `index.php`
- Post-install **verification**: `wp core is-installed` + homepage must be WordPress + `wp-login.php` 200; default test pages fail the script
- Security: UFW (OpenSSH allowed **before** enable), credentials file `0600`, secrets scrubbed from logs
- Shared helpers in `lib/common.sh`

Visiting `http://SERVER_IP` shows the WordPress front page. Done.

## Two ways to deploy (same outcome)

| Mode | Script | When to use |
|------|--------|-------------|
| **Host (default)** | `web-install.sh` | Native install on the VPS: Apache + PHP + MariaDB + WordPress |
| **Docker** (`--docker`) | `docker-way.sh` | Same WordPress site in containers |

## One-command setup

**Unattended / pipe-safe (automation, CI):**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --unattended
```

**Interactive (recommended — download first so prompts can read your terminal; `curl | bash` steals stdin):**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh -o /tmp/swiftweb-install.sh
sudo bash /tmp/swiftweb-install.sh
```

## Options

| Flag | Effect |
|------|--------|
| `--docker` | Deploy with Docker (default: native host install on the VPS) |
| `--unattended` | Non-interactive (all inputs from env vars) |
| `--force` | **Host:** wipe web root (timestamped backup) **and DROP/recreate** the WordPress DB, then reinstall. **Docker:** `docker compose down -v` (wipe volumes) and reinstall |
| `--domain D` | Set site domain (default: server IP) |
| `--title T` | WordPress site title |
| `--admin U` | Admin username |
| `--email E` | Admin email |
| `--name N` | (docker) project/container prefix (default: `swiftweb`) |
| `--port P` | (docker) published port for WordPress (default: `80`) |
| `--dry-run` | Preview changes without executing |
| `--ssl` | (host) Enable HTTPS via certbot (requires `--domain`) |

### Environment variables (unattended)

`SITE_TITLE`, `ADMIN_USER`, `ADMIN_PASSWORD`, `ADMIN_EMAIL`, `DOMAIN`, `FORCE`, `WP_DB_NAME`, `WP_DB_USER`, `WP_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`. Any password not provided is auto-generated (32 chars, Python `secrets`, `/dev/urandom` fallback) and saved only to the root-only credentials file.

## Re-runs are safe (idempotent)

- Without `--force`, if WordPress is already installed the script **backs off and exits 0** — it does not wipe a live site.
- `--force` performs a **full** reinstall: files + database (host) or compose volumes (Docker).

## What the host path installs (`web-install.sh`)

1. Apache2, PHP 8.x + extensions, MariaDB, python3, WP-CLI  
2. MariaDB hardened (`IDENTIFIED BY`), WP DB + user; on `--force` the WP database is dropped and recreated  
3. Official core downloaded (gzip integrity check), placed in `/var/www/html`, Apache welcome indexes removed  
4. `wp core install` as `www-data`, permalinks, `.htaccess` after rewrite  
5. UFW + verification  

## Docker path (`docker-way.sh`)

- Installs Docker/Compose if missing (GPG written to disk — no fragile pipes)
- Images: `wordpress:php8.3-apache` + matching `wordpress:cli-php8.3` + `mariadb:10.11` (override with `WP_IMAGE` / `WP_CLI_IMAGE` / `DB_IMAGE`)
- WP-CLI runs in the `wpcli` service on the shared `wp_data` volume
- `--force` runs `docker compose down -v` then recreates and reinstalls
- UFW: OpenSSH + published port before enable; same HTTP verification as the host path

## Raw WordPress policy

- Bundled default themes (`twentytwenty*`) are **kept**
- Only the `akismet` plugin is removed; Hello Dolly stays unless you remove it

## CI / tests

`.github/workflows/ci.yml`:

- **shellcheck** on Ubuntu 20.04/22.04/24.04 (`install.sh`, `web-install.sh`, `docker-way.sh`, `lib/common.sh`)
- **shfmt** diff check
- **bats** unit tests — CRLF heal, passwords, redaction, URL helpers, default-index clearing, source-safety
- **e2e-host** / **e2e-docker** — real unattended installs asserting a WordPress homepage (not a test page)

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 VPS
- Root or sudo
- Outbound internet (apt, wordpress.org, WP-CLI, Docker Hub for `--docker`)

## Logs & credentials

| Artifact | Path |
|----------|------|
| Host credentials (0600) | `/root/swiftwebsetup-credentials.txt` |
| Docker credentials (0600) | `/root/swiftwebsetup-docker-credentials.txt` |
| Host log | `/var/log/swiftwebsetup-web-install.log` |
| Docker log | `/var/log/swiftwebsetup-docker-way.log` |

Secrets go only to the 0600 credentials file — not the world-readable log.

## License

MIT — see [LICENSE](LICENSE).
