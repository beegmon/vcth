#!/bin/bash
set -e

# Hardened Cleanup Script
# ONLY uninstalls tools tracked in .installed.lock

LOCK_FILE=".installed.lock"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[CLEANUP]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

if [ ! -f "$LOCK_FILE" ]; then
    warn "No lock file ($LOCK_FILE) found. Assuming nothing to clean up or manual cleanup required."
    exit 0
fi

log "Reading lock file to determine cleanup actions..."
INSTALLED_TOOLS=$(cat "$LOCK_FILE")

# Helper to check if tool was installed by us
was_installed() {
    echo "$INSTALLED_TOOLS" | grep -q "$1"
}

# 1. Clean up K8s Resources (Artifacts only)
log "Cleaning up Kubernetes artifacts..."
rm -f jwt.hex

# 2b. Clean up Simulation Container (Explicitly)
# Even if we didn't install Docker, we might have started this container.
if command -v docker &> /dev/null; then
    if docker ps -a --format '{{.Names}}' | grep -q "^simulated-bare-metal-server$"; then
        log "Removing simulation container..."
        docker rm -f simulated-bare-metal-server || true
    fi
fi

log "Removed jwt.hex"

# 4. Uninstall Tools (ONLY if in lock file)

if was_installed "minikube"; then
    log "Uninstalling Minikube..."
    sudo rm -f /usr/local/bin/minikube
    rm -rf ~/.minikube
    log "Minikube uninstalled."
fi

if was_installed "kubectl"; then
    log "Uninstalling Kubectl..."
    sudo rm -f /usr/local/bin/kubectl
    log "Kubectl uninstalled."
fi

if was_installed "terraform"; then
    log "Uninstalling Terraform..."
    sudo apt-get remove -y terraform
    rm -rf ~/.terraform.d
    log "Terraform uninstalled."
fi

if was_installed "ansible"; then
    log "Uninstalling Ansible..."
    sudo apt-get remove -y ansible
    sudo apt-add-repository --remove -y ppa:ansible/ansible
    log "Ansible uninstalled."
fi

if was_installed "docker"; then
    log "Uninstalling Docker..."
    sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.gpg
    log "Docker uninstalled."
fi

if was_installed "go"; then
    log "Uninstalling Go..."
    sudo rm -rf /usr/local/go
    # Note: we don't edit ~/.profile here to avoid messing up user config too much, 
    # but strictly speaking we should. 
    # For safety, we'll leave the PATH export as it's harmless without the dir.
    log "Go uninstalled (binaries removed)."
fi

# 5. Remove Lock File
rm "$LOCK_FILE"
log "Cleanup Complete. Lock file removed."
