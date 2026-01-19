#!/bin/bash
set -e

# Hardened Setup Script
# Installs: Docker, Minikube, Kubectl, Ansible, Terraform, Go
# Handles: Root vs User context, Docker Group membership

LOCK_FILE=".installed.lock"
MIN_RAM_MB=8192
MIN_CPU=4

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Ensure we are running as root for installs
if [ "$EUID" -ne 0 ]; then 
    error "Please run as root (sudo ./scripts/setup_host.sh)"
fi

# Determine the Real User (who called sudo)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

log "Running setup for user: $REAL_USER (Home: $REAL_HOME)"

# 1. Pre-flight Checks (Hardware)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
if [ "$TOTAL_RAM_MB" -lt "$MIN_RAM_MB" ]; then
    error "Insufficient RAM. Detected ${TOTAL_RAM_MB}MB, required ${MIN_RAM_MB}MB."
fi

TOTAL_CPU=$(nproc)
if [ "$TOTAL_CPU" -lt "$MIN_CPU" ]; then
    error "Insufficient CPU. Detected ${TOTAL_CPU} cores, required ${MIN_CPU} cores."
fi

# Track installations (in the repo dir, owned by real user)
touch "$LOCK_FILE"
chown "$REAL_USER:$REAL_USER" "$LOCK_FILE"

mark_installed() {
    if ! grep -q "$1" "$LOCK_FILE"; then
        echo "$1" >> "$LOCK_FILE"
    fi
}

# 2. System Updates & Installs
log "Updating system..."
apt-get update -y > /dev/null
apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release > /dev/null

# 3. Docker
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y > /dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
    mark_installed "docker"
fi

# Add user to docker group
if ! groups "$REAL_USER" | grep -q "docker"; then
    log "Adding $REAL_USER to docker group..."
    usermod -aG docker "$REAL_USER"
    # Create a marker so lifecycle script knows we need to reload groups
    touch .group_updated
fi

# 4. Minikube
if ! command -v minikube &> /dev/null; then
    log "Installing Minikube..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 > /dev/null
    install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    mark_installed "minikube"
fi

# 5. Kubectl
if ! command -v kubectl &> /dev/null; then
    log "Installing Kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" > /dev/null
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    mark_installed "kubectl"
fi

# 6. Ansible
if ! command -v ansible &> /dev/null; then
    log "Installing Ansible..."
    apt-add-repository -y ppa:ansible/ansible > /dev/null
    apt-get update -y > /dev/null
    apt-get install -y ansible > /dev/null
    mark_installed "ansible"
fi

# 7. Terraform
if ! command -v terraform &> /dev/null; then
    log "Installing Terraform..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg --yes
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update -y > /dev/null
    apt-get install -y terraform > /dev/null
    mark_installed "terraform"
fi

# 8. Go
if ! command -v go &> /dev/null; then
    log "Installing Go..."
    # Clean previous install to avoid corruption
    rm -rf /usr/local/go
    
    wget https://go.dev/dl/go1.22.5.linux-amd64.tar.gz > /dev/null
    tar -C /usr/local -xzf go1.22.5.linux-amd64.tar.gz
    rm go1.22.5.linux-amd64.tar.gz
    # Add to path for this session so we can use it, and persist for user
    echo 'export PATH=$PATH:/usr/local/go/bin' >> "$REAL_HOME/.profile"
    mark_installed "go"
fi

# 9. Start Minikube (AS USER, NOT ROOT)
log "Starting Minikube (as $REAL_USER)..."
export PATH=$PATH:/usr/local/go/bin

# We run minikube start as the real user.
# IMPORTANT: This might fail if the user doesn't have docker permissions in the *current* session yet.
# However, sg (execute in group) can solve this if we invoke it correctly.
# But sg requires a password if not root. We are root. We can use su.
# su - $REAL_USER -c "sg docker -c 'minikube start ...'"

# 8.5 Firewall (UFW or IPTables)
log "Configuring Firewall..."
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    log "UFW is active. Adding rules..."
    ufw allow 22/tcp
    ufw allow 3000/tcp
    ufw allow 3001/tcp
else
    log "UFW is inactive/missing. Using raw iptables..."
    # Insert allow rule at the HEAD of the INPUT chain to bypass other drops
    # Check if rule exists first to be idempotent
    if ! iptables -C INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 3000 -j ACCEPT
    fi
    if ! iptables -C INPUT -p tcp --dport 3001 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 3001 -j ACCEPT
    fi
    log "Ports 3000/3001 checked/opened via iptables."
fi

# But first, let's fix the JWT generation (it's files, easy)
if [ ! -f jwt.hex ]; then
    openssl rand -hex 32 | tr -d "\n" > jwt.hex
    chown "$REAL_USER:$REAL_USER" jwt.hex
fi

# Start Minikube logic is deferred to lifecycle or run here with careful handling.
# Let's try to run it here, but correctly dropping privs and ensuring docker group access.
# invoking 'sg' as root for a user is tricky.
# Simpler approach: We ensured Docker is installed. We let the lifecycle script (running as user) start Minikube.
# BUT lifecycle script calls us first.
# So we return, and let lifecycle script handle the logic of "reloading groups".

log "System setup complete. Handing back to lifecycle script."
