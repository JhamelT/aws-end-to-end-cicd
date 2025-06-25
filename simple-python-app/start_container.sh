#!/bin/bash
set -e

# Pull the Docker Image from Docker Hub - Copy Docker Pull Command 
docker pull jhamelthorne/myapp

# Run the Docker image as container
docker run -d -p 5000:5000 jhamelthorne/myapp
