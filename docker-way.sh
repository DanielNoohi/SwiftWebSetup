#!/bin/bash

# Automated Ubuntu Docker Setup Script
wget "https://raw.githubusercontent.com/DanielNoohi/ubuntu-server-docker-setup/main/docker-install.sh" -O docker-install.sh && chmod +x docker-install.sh && bash docker-install.sh

# Ask the user for the domain name
read -p "Enter your docker container name: " DOCKER_NAME

docker run \
  --detach \
  --name $DOCKER_NAME \
  --publish 80:80 \
  --volume /data:/usr/share/nginx/html \
  nginx


# Check if the system needs to reboot
if [ -f /var/run/reboot-required ]; then
    echo "The system needs to reboot."
    
    # Ask for confirmation to reboot
    while true; do
        read -p "Do you want to reboot now? (y/n) " choice
        case "$choice" in 
            y|Y ) 
                echo "Rebooting now..."
                sudo reboot
                ;;
            n|N ) 
                echo "Reboot cancelled."
                break
                ;;
            * ) 
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
else
    echo "The system does not need to reboot."
fi
