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

# Install Apache2 and its dependencies
sudo apt install -y apache2 php libapache2-mod-php php-mysql php-cli php-common php-curl php-gd php-json php-mbstring php-xml php-zip

# Install MySQL
sudo apt-get install mysql-server -y

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

# Define variables for the database name, username, and password
DB_NAME='wordpress'
DB_USER='daniel'
DB_PASSWORD='password'

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
