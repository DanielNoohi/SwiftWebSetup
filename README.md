# SwiftWebSetup

One-command **production WordPress** bootstrap for an Ubuntu VPS — official WordPress from wordpress.org, fully installed and ready to use.

## What you get

A live WordPress site on your server:

- Official core from wordpress.org (`latest.tar.gz` on host; `wordpress:php8.3-apache` on Docker)
- MariaDB + least-privilege DB user; `wp-config.php` + salts via WP-CLI
- Completed install as **www-data** (host) or `wordpress:cli` (Docker)
- Pretty permalinks, hardened `.htaccess`, Apache welcome page removed
- Verification rejects default “It works!” pages
- Credentials written **only after** a successful verify (`0600`)
- Interactive prompts for title / admin / email / domain / HTTPS (or fully `--unattended`)

## Deploy modes

| Mode | Script | Notes |
|------|--------|--------|
| **Host (default)** | `host-install.sh` | Native Apache + PHP + MariaDB + WordPress |
| **Docker** | `docker-way.sh` | Same outcome in containers (`--docker`) |

`web-install.sh` remains a thin alias for `host-install.sh`.

## One-command setup

**Interactive (recommended):**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh -o /tmp/swiftweb-install.sh
sudo bash /tmp/swiftweb-install.sh
```

**Unattended:**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh \
  | sudo bash -s -- --unattended --domain example.com --ssl --title "My Site" --email you@example.com
```

Pinned release (after tags exist):

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/v1.0.0/install.sh -o /tmp/swiftweb-install.sh
sudo bash /tmp/swiftweb-install.sh --unattended
```

## Options

| Flag | Effect |
|------|--------|
| `--docker` | Docker deploy (default: host) |
| `--unattended` | No prompts |
| `--force` | Host: wipe files + DROP/recreate DB. Docker: `down -v` |
| `--backup-only` | Host: snapshot web root + DB under `/root/swiftweb-backups/`, exit |
| `--domain D` | Site domain |
| `--ssl` | Host: certbot HTTPS (needs domain; interactive also offers this) |
| `--fail2ban` | Host: install fail2ban |
| `--auto-updates` | Host: unattended-upgrades |
| `--title` / `--admin` / `--email` | Site identity |
| `--name` / `--port` | Docker project / published port |
| `--dry-run` | Preview |

## Version notes

- **Host** always pulls current `https://wordpress.org/latest.tar.gz`.
- **Docker** defaults to `wordpress:php8.3-apache` + matching CLI (override with `WP_IMAGE`, `WP_CLI_IMAGE`, `DB_IMAGE`).

## Requirements

Ubuntu 20.04 / 22.04 / 24.04 VPS, root/sudo, outbound internet.

## Credentials & logs

| | Path |
|--|------|
| Host creds | `/root/swiftwebsetup-credentials.txt` |
| Docker creds | `/root/swiftwebsetup-docker-credentials.txt` |
| Host log | `/var/log/swiftwebsetup-web-install.log` |
| Docker log | `/var/log/swiftwebsetup-docker-way.log` |

## License

MIT — see [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for releases.
