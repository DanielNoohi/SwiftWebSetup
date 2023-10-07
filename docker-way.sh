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
