# SwiftWebSetup

Production WordPress bootstrap for Ubuntu VPS.

One command installs official WordPress from [wordpress.org](https://wordpress.org), completes setup with WP-CLI, and leaves a verified live site—not a default web-server page and not an unfinished install wizard.

---

## Features

- Official WordPress core (host: `latest.tar.gz`; Docker: `wordpress:php8.3-apache`)
- MariaDB with a dedicated, least-privilege database user
- Automatic `wp core install` (host runs WP-CLI as `www-data`)
- Pretty permalinks, hardened `.htaccess`, Apache welcome page removed
- Post-install verification (homepage + `wp-login.php`; rejects “It works!”)
- Credentials written only after a successful verify (`0600` under `/root`)
- Interactive prompts or fully unattended mode
- Optional HTTPS (Let’s Encrypt), fail2ban, and unattended upgrades on the host path

---

## Requirements

| Item | Detail |
|------|--------|
| OS | Ubuntu 20.04, 22.04, or 24.04 |
| Access | Root / `sudo` |
| Network | Outbound HTTPS (apt, wordpress.org, WP-CLI; Docker Hub if using `--docker`) |

---

## Quick start

### Interactive (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/v1.0.0/install.sh \
  -o /tmp/swiftweb-install.sh
sudo bash /tmp/swiftweb-install.sh
```

You will be prompted for site title, admin user, password, email, domain, and HTTPS when a domain is set.

### Unattended

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/v1.0.0/install.sh \
  | sudo bash -s -- --unattended \
      --domain example.com \
      --ssl \
      --title "Example Site" \
      --admin admin \
      --email admin@example.com
```

### Docker

```bash
sudo bash /tmp/swiftweb-install.sh --docker --unattended --port 8080
```

---

## Deploy modes

| Mode | Entrypoint | Description |
|------|------------|-------------|
| **Host** (default) | `host-install.sh` | Native Apache, PHP, MariaDB, and WordPress on the VPS |
| **Docker** | `docker-way.sh` | WordPress + MariaDB via Compose (`--docker`) |

`web-install.sh` is a compatibility wrapper that invokes `host-install.sh`.

---

## Options

| Flag | Applies to | Description |
|------|------------|-------------|
| `--docker` | install | Use Docker instead of host install |
| `--unattended` | both | No prompts; use flags / environment variables |
| `--force` | both | Host: wipe document root and DROP/recreate DB. Docker: `compose down -v` |
| `--backup-only` | host | Snapshot web root and database to `/root/swiftweb-backups/`, then exit |
| `--domain D` | both | Public hostname (default: server IP) |
| `--ssl` | host | Obtain certificates with Certbot (requires `--domain`) |
| `--fail2ban` | host | Install and enable fail2ban |
| `--auto-updates` | host | Enable `unattended-upgrades` |
| `--title` / `--admin` / `--email` | both | Site identity |
| `--name` / `--port` | Docker | Project prefix / published HTTP port |
| `--dry-run` | both | Print planned actions without changing the system |

### Environment variables (unattended)

`SITE_TITLE`, `ADMIN_USER`, `ADMIN_PASSWORD`, `ADMIN_EMAIL`, `DOMAIN`, `FORCE`, `WP_DB_NAME`, `WP_DB_USER`, `WP_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`

Unset passwords are generated automatically (32 characters) and stored in the credentials file after a successful install.

---

## Behavior notes

**Idempotency.** Without `--force`, a completed WordPress install is left alone and the script exits successfully.

**Credentials.** Written only after verification succeeds:

| Path | Purpose |
|------|---------|
| `/root/swiftwebsetup-credentials.txt` | Host install |
| `/root/swiftwebsetup-docker-credentials.txt` | Docker install |

**Versions.** The host path always fetches current WordPress from wordpress.org. Docker defaults to `wordpress:php8.3-apache` and matching CLI images (`WP_IMAGE`, `WP_CLI_IMAGE`, `DB_IMAGE` override).

**TLS on Docker.** Certbot is not applied inside the Compose stack. Terminate TLS at a reverse proxy, or use the host installer with `--ssl`.

---

## Logs

| Path | Purpose |
|------|---------|
| `/var/log/swiftwebsetup-web-install.log` | Host installer |
| `/var/log/swiftwebsetup-docker-way.log` | Docker installer |

Command lines in logs have secrets redacted.

---

## Project layout

```
install.sh          One-command entrypoint
host-install.sh     Native VPS installer
web-install.sh      Alias → host-install.sh
docker-way.sh       Docker Compose installer
lib/common.sh       Shared helpers
tests/              bats unit tests
.github/workflows/  CI (shellcheck, shfmt, bats, e2e)
```

---

## License

MIT. See [LICENSE](LICENSE) and [CHANGELOG.md](CHANGELOG.md).
