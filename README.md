# SwiftWebSetup

Rapid deployment scripts for setting up web servers on Linux.

## Features

* **web-install.sh** - Automated LAMP stack with WordPress
  * Apache2 + PHP 8.x + MariaDB
  * WordPress latest with secure configuration
  * Idempotent, safe for re-runs
  * Dry-run and unattended modes
  * Secure password generation and logging

* **docker-way.sh** - Docker-based Nginx deployment
  * Latest nginx container
  * Persistent volume at `/data`
  * Auto-restart on failure
  * Configurable container name and port
  * Dry-run and unattended modes

## Quick Start

### Traditional LAMP + WordPress

```bash
git clone https://github.com/DanielNoohi/SwiftWebSetup.git
cd SwiftWebSetup
sudo bash web-install.sh
```

**Unattended (for automation):**
```bash
MYSQL_ROOT_PASSWORD="your-root-pw" WP_DB_PASSWORD="your-wp-pw" \
sudo bash web-install.sh --unattended
```

**Dry-run (preview changes):**
```bash
sudo bash web-install.sh --dry-run
```

### Docker Nginx

```bash
git clone https://github.com/DanielNoohi/SwiftWebSetup.git
cd SwiftWebSetup
sudo bash docker-way.sh
```

**Custom container name and port:**
```bash
sudo bash docker-way.sh --name my-site --port 8080
```

**Unattended:**
```bash
sudo bash docker-way.sh --unattended --name my-site --port 8080
```

**Dry-run:**
```bash
sudo bash docker-way.sh --dry-run
```

## Requirements

* Ubuntu Linux (tested on 20.04, 22.04, 24.04)
* Root/sudo access
* Internet access for package downloads
* Docker (for `docker-way.sh` only)

## Script Details

### web-install.sh

Installs and configures:
- Apache2 with rewrite module
- PHP 8.x with common extensions (MySQL, cURL, GD, MBString, XML, Zip, OPcache)
- MariaDB 10.x (MySQL-compatible)
- WordPress latest from wordpress.org
- UFW firewall (SSH + HTTP/HTTPS)
- Secure file permissions (www-data:www-data, 755/644)

Creates:
- WordPress database and dedicated user
- wp-config.php with generated salts
- Apache virtual host with AllowOverride All
- Log file at `/var/log/swiftwebsetup-web-install.log`

**Outputs credentials** to console and log file on first run.

### docker-way.sh

Deploys:
- nginx:latest container
- Volume mount: `/data` → `/usr/share/nginx/html`
- Port mapping: host port → container port 80
- Restart policy: `unless-stopped`

Creates:
- Data directory at `/data` with correct ownership
- Log file at `/var/log/swiftwebsetup-docker-way.log`

## Security Notes

* Passwords are generated using `/dev/urandom` (32 chars, alphanumeric + symbols)
* MariaDB root user is secured (no anonymous users, no test database, localhost-only root)
* WordPress salts fetched from WordPress.org API
* File permissions follow least-privilege principle
* UFW allows only SSH and HTTP/HTTPS by default

## Logs

Both scripts write detailed logs to:
- `/var/log/swiftwebsetup-web-install.log`
- `/var/log/swiftwebsetup-docker-way.log`

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

Daniel Noohi - https://github.com/DanielNoohi