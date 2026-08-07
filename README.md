# SwiftWebSetup

One-command raw WordPress production bootstrap for Ubuntu — official WordPress from wordpress.org, **fully installed and ready to use**. No test pages, no "It works!", no install wizard left for you to click through.

## What you get

A **fully fledged WordPress website** — not a demo:

- Official WordPress core from https://wordpress.org/latest.tar.gz (raw, unmodified, bundled default themes kept)
- MariaDB database + least-privilege dedicated DB user
- `wp-config.php` fully written (DB_* + real salts via `wp config shuffle-salts`)
- Installation **completed automatically** via WP-CLI (`wp core install`) with site title, admin user + strong password, admin email, and siteurl/home set to your server IP or domain
- Pretty permalinks working (`/%postname%/`) with Apache rewrite + `.htaccess` `AllowOverride All`
- Post-install **verification**: script asserts `wp core is-installed` and that the homepage actually serves WordPress (fails loudly if it sees a test page)
- Security hardening: UFW (SSH + HTTP/HTTPS), hardened `.htaccess` (security headers, wp-config protection, no directory listing), secure file ownership/permissions
- Root-only credentials file (`/root/swiftwebsetup-credentials.txt`, 0600) — **secrets never go to the world-readable log**

Visiting `http://SERVER_IP` shows the WordPress front page. Done.

## One-command setup

**Unattended / pipe-safe (automation, CI):**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh | sudo bash -s -- --unattended
```

**Interactive (recommended — download first so the prompts can read your terminal; `curl | bash` steals stdin):**

```bash
curl -fsSL https://raw.githubusercontent.com/DanielNoohi/SwiftWebSetup/main/install.sh -o /tmp/swiftweb-install.sh
sudo bash /tmp/swiftweb-install.sh
```

## Options

| Flag | Effect |
|------|--------|
| `--docker` | Deploy WordPress + MariaDB as Docker containers (host LAMP by default) |
| `--unattended` | Non-interactive mode (all inputs from env vars) |
| `--force` | Wipe existing WordPress files/DB and reinstall |
| `--domain D` | Set site domain (default: server IP) |
| `--title T` | WordPress site title |
| `--admin U` | Admin username |
| `--email E` | Admin email |
| `--name N` | (docker) project/container prefix (default: swiftweb) |
| `--port P` | (docker) host port for WordPress (default: 80) |
| `--dry-run` | Preview changes without executing |
| `--ssl` | Enable HTTPS via certbot (requires `--domain`) |

### Environment variables (unattended)

`SITE_TITLE`, `ADMIN_USER`, `ADMIN_PASSWORD`, `ADMIN_EMAIL`, `DOMAIN`, `FORCE`, `WP_DB_NAME`, `WP_DB_USER`, `WP_DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`. Any password not provided is auto-generated (32 chars, Python `secrets`-seeded, shell/SQL-safe charset, `/dev/urandom` fallback) and saved only to the root-only credentials file.

## Re-runs are safe (idempotent)

- If WordPress is already installed and you run **without** `--force`, the script backs off and exits 0 — it does **not** wipe a live site.
- `--force` clears all web root files/DB (timestamped backup first) and reinstalls.
- `wp core install` skips automatically when WP is already installed.

## What it installs (LAMP path, web-install.sh)

1. **System**: `apt update`, Apache2, PHP 8.x + extensions (mysql, curl, gd, mbstring, xml, zip, opcache), MariaDB, python3 (for password gen)
2. **Database**: MariaDB hardened (root password set with modern `IDENTIFIED BY`, anonymous users removed, test DB dropped), WordPress DB + least-privilege user
3. **WordPress**: official core downloaded with gzip integrity check, extracted to `/var/www/html`, `wp-config.php` written via WP-CLI, salts shuffled
4. **Install**: `wp core install` completes the site (idempotent), permalinks set via `wp rewrite --hard`, `.htaccess` hardened *after* rewrite so it survives
5. **Hardening**: UFW (SSH + HTTP/HTTPS), security headers, `www-data` ownership, 755/644 permissions
6. **Verify**: `wp core is-installed` + homepage must contain `wp-content`/`wp-includes` — otherwise the script fails

## Docker path (docker-way.sh)

- Docker + Compose plugin installed if missing (GPG key written to file first — no fragile pipes)
- `mariadb:10.11` + `wordpress:6.7-php8.3-apache` + **`wordpress:cli-php8.3`** service (the `wordpress` image has no `wp` binary; the cli image shares the `wp_data` volume and runs the install)
- Healthchecks, named volumes, restart policy, `restart: "no"` helper
- WP-CLI runs inside the `wpcli` container: `wp core install`, permalinks, cleanup — same verification as LAMP path
- Project in `/opt/<name>/` with `docker-compose.yml` + 0600 `.env`; credentials in `/root/swiftwebsetup-docker-credentials.txt`
- UFW: OpenSSH + the published WordPress port before enable
- Verify WordPress homepage + `wp-login.php` as in LAMP path

## Raw WordPress policy

- Bundled default themes (`twentytwenty*`) are **kept** — stock WordPress behavior.
- Only the `akismet` plugin is removed (optional spam plugin that needs a subscription); `hello` dolly stays unless removed manually.

## CI / tests

`.github/workflows/ci.yml`:
- **shellcheck** across Ubuntu 20.04/22.04/24.04 containers (fails on any finding)
- **shfmt** diff check
- **bats** unit tests (`tests/`) — CRLF self-heal integrity, password generation, secret redaction, URL resolution, source-safety
- **e2e-lamp**: real unattended `web-install.sh` on a fresh Ubuntu runner, then asserts a WordPress homepage + `wp-login.php` 200 + creds file 0600
- **e2e-docker**: real unattended `docker-way.sh --port 8080`, then asserts a WordPress page served from containers (not an nginx welcome page)

If a tool, install, or network call fails and blocks the real path, say so directly and try an alternative (different package manager, different approach, ask the user). NEVER substitute plausible-looking fabricated output (made-up data, invented file contents, synthesised API responses) for results you couldn't actually produce. Reporting a blocker honestly is always better than inventing a result.
If a tool or install fails and you suspect external causes (e.g., upstream service unavailable), verify this with a small diagnostic before re-attempting the main task. For network calls, use tools like `curl`/`ping` to test connectivity first.
hen the user references something from a past conversation or you suspect relevant cross-session context exists, use `session_search` to recall it before asking them to repeat themselves. After completing a complex task (5+ tool calls), offer to save as a skill. If a skill you loaded was missing steps, had wrong commands, or needed pitfalls you discovered, update it before finishing. When you finish a task, summarize your findings in a human-readable format — include any findings, output, or hints that might help the user in the future.