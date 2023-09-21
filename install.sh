#!/bin/bash

# Update and upgrade Ubuntu
    sudo apt update
    sudo apt -y upgrade
    sudo apt -y dist-upgrade
    sudo apt -y autoremove

    sleep 0.5
    
    # Again :D
    sudo apt -y autoclean
    sudo apt -y clean
    sudo apt update
    sudo apt -y upgrade
    sudo apt -y dist-upgrade
    sudo apt -y autoremove



# Install Apache2 and its dependencies
sudo apt install -y apache2 php libapache2-mod-php php-mysql php-cli php-common php-curl php-gd php-json php-mbstring php-xml php-zip

sleep 1

# Install MySQL
#sudo apt-get install mysql-server -y

# Enable Apache2 service
sudo systemctl enable apache2

# Start Apache2 service
sudo systemctl start apache2

# Download and extract WordPress
wget https://wordpress.org/latest.tar.gz
tar -xzvf latest.tar.gz

# Stop Apache service
sudo systemctl stop apache2

# Backup default Apache website
sudo mv /var/www/html /var/www/html_backup

# Create a new directory for the WordPress installation
sudo mkdir /var/www/html

# Move WordPress files to web root
#sudo mv ./wordpress/* /var/www/html/

sleep 0.5

# Define the source and destination folders
SRC_FOLDER='./wordpress/*'
DEST_FOLDER='/var/www/html/'

# Move all files and folders in the source folder to the destination folder
sudo mv -f $SRC_FOLDER/* $DEST_FOLDER

cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

# Change ownership of web root to www-data
sudo chown -R www-data:www-data /var/www/html/
sudo chmod -R 755 /var/www/html/

#sudo mysql
# ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password by 'password';

# Secure the installation of MySQL
 sudo mysql_secure_installation

# Create a new MySQL user for WordPress
#  sudo mysql -u root -p
#  CREATE DATABASE wordpress;
#  CREATE USER 'daniel'@'localhost' IDENTIFIED BY 'password';
#  GRANT ALL PRIVILEGES ON *.* TO 'daniel'@'localhost';
#  FLUSH PRIVILEGES;
#  exit;

# Create a new MySQL database for WordPress
#sudo mysql -u root -p
#CREATE DATABASE wordpress;
#exit;

sleep 0.5

# Define variables for the database name, username, and password
DB_NAME=''
DB_USER=''
DB_PASSWORD=''

# Prompt the user for input
read -p "Enter the WordPress database name: " DB_NAME
read -p "Enter the database username: " DB_USER
#read -s -p "Enter the database password: " DB_PASSWORD
echo  # Add a newline after the password input for better formatting

# Check if the user provided values
if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
    echo "Error: Please provide values for all required fields."
    exit 1
fi

sleep 0.5

# Prompt the user to enter the database password twice
while true; do
    read -s -p "Enter the database password: " DB_PASSWORD
    echo
    read -s -p "Confirm the database password: " DB_PASSWORD_CONFIRM
    echo

    # Check if the passwords match
    if [ "$DB_PASSWORD" = "$DB_PASSWORD_CONFIRM" ]; then
        break
    else
        echo "Error: Passwords do not match. Please try again."
    fi
done

# You can use these variables in further configuration or installation steps.
echo "Database name: $DB_NAME"
echo "Database username: $DB_USER"
# For security reasons, we won't display the password.


# Define the path to the wp-config.php file
WP_CONFIG_PATH='/var/www/html/wp-config.php'

# Replace the database name, username, and password in the wp-config.php file
#sed -i "s/'DB_NAME', '.*'/'DB_NAME', '$DB_NAME'/" $WP_CONFIG_PATH
#sed -i "s/'DB_USER', '.*'/'DB_USER', '$DB_USER'/" $WP_CONFIG_PATH
#sed -i "s/'DB_PASSWORD', '.*'/'DB_PASSWORD', '$DB_PASSWORD'/" $WP_CONFIG_PATH


# Start Apache2 service
sudo systemctl start apache2


# Check if Apache2 is running
if systemctl is-active --quiet apache2; then
    echo "Apache2 is running."
else
    echo "Apache2 is not running."
fi

# Check if MySQL is running
if systemctl is-active --quiet mysql; then
    echo "MySQL is running."
else
    echo "MySQL is not running."
fi

sleep 0.5

# Enable the Uncomplicated Firewall (UFW)
sudo ufw enable

# Allow SSH (port 22) for remote access
sudo ufw allow 22/tcp comment 'Allow SSH Access'
# Allow HTTP (port 80) for web traffic
sudo ufw allow 80/tcp comment 'Allow HTTP Access'
# Allow HTTPS (port 443) for secure web traffic
sudo ufw allow 443/tcp comment 'Allow HTTPS Access'

# Display the list of rules to confirm the configuration
sudo ufw status

sleep 0.5

# Check if the system needs to reboot
if [ -f /var/run/reboot-required ]; then
    echo "The system needs to reboot."
    # Ask for confirmation to reboot
    read -p "Do you want to reboot now? (y/n) " choice
    case "$choice" in 
        y|Y ) echo "Rebooting now..."; sudo reboot;;
        n|N ) echo "Reboot cancelled.";;
        * ) echo "Invalid input.";;
    esac
else
    echo "The system does not need to reboot."
fi
