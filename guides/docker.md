## Docker - Guide

This guide will walk you through installing Docker Engine and docker Compose on your system. 
The instructions are for Debian-based Linux distributions (like Ubuntu).
You can find installation guides for other operating systems in the [Docker documentation](https://docs.docker.com/get-docker/).

### 1. Remove old Docker versions
```bash
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
```

### 2. Install Docker prerequisites
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
```

### 3. Add Docker GPG key & repository
```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 4. Install Docker
```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 5. Let your user run docker without sudo
```bash
sudo usermod -aG docker $USER
newgrp docker
```
