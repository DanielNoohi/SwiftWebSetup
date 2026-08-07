# SwiftWebSetup

Rapid deployment scripts for setting up web servers on Linux.

## Features

* Automated installation of Apache, PHP, and MySQL
* One-step WordPress deployment
* Docker-based Nginx setup
* Minimal dependencies
* Idempotent operations

## Usage

### Traditional Web Stack (`web-install.sh`)

1. Clone this repository:
   ```bash
   git clone https://github.com/DanielNoohi/SwiftWebSetup.git
   cd SwiftWebSetup
   ```

2. Run the installer:
   ```bash
   sudo bash web-install.sh
   ```

### Docker Approach (`docker-way.sh`)

1. Clone this repository:
   ```bash
   git clone https://github.com/DanielNoohi/SwiftWebSetup.git
   cd SwiftWebSetup
   ```

2. Run the Docker installer:
   ```bash
   sudo bash docker-way.sh
   ```

## Requirements

* Ubuntu Linux (tested on 20.04/22.04)
* Docker (for `docker-way.sh`)
* Internet access

## License

MIT License - See [LICENSE](LICENSE) for details.
