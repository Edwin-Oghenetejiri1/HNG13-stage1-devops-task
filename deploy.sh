#!/bin/bash
# Script missing shebang (FIXED - Task 9)

# --- CONFIGURATION AND INITIALIZATION (Tasks 9 & 10) ---

# Define a timestamped log file for logging (Task 9)
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
# Redirect all output (stdout and stderr) to both the console AND the log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Define colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Define the local directory name for the cloned repository
REPO_DIR="hng-stage1-app"

# --- ERROR HANDLING AND CLEANUP FUNCTION (Task 9) ---

# Function run on error or interrupt (exits script with error code 1)
function cleanup {
    echo -e "\n${RED}--- ERROR: Deployment failed or interrupted at line $1. Check $LOG_FILE ---${NC}"
    exit 1
}

# Set up the error trap: If any command exits with a non-zero status, run cleanup
trap 'cleanup $LINENO' ERR # Catches command failures
trap cleanup INT # Catches Ctrl+C interrupts

echo -e "${GREEN}--- Starting HNG Stage 1 Automated Deployment Script ---${NC}"

# --- SSH EXECUTION WRAPPER FUNCTION (Task 4) ---
# Wrapper function for remote execution
ssh_exec() {
    # -o StrictHostKeyChecking=no bypasses the host key confirmation on first connect
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_IP" "$1"
}

# --- 1. COLLECT PARAMETERS FROM USER INPUT (Task 1) ---

echo -e "\n--- Collecting Deployment Parameters ---"

read -p "Enter Git Repository URL: " GIT_REPO
[ -z "$GIT_REPO" ] && echo -e "${RED}ERROR: Git URL cannot be empty.${NC}" && exit 1 # Input validation (FIXED)

read -p "Enter Git Personal Access Token (PAT): " PAT
[ -z "$PAT" ] && echo -e "${RED}ERROR: PAT cannot be empty.${NC}" && exit 1 # Input validation (FIXED)

read -p "Enter branch name (default: main): " BRANCH
[ -z "$BRANCH" ] && BRANCH="main"

read -p "Enter Remote SSH Username (e.g., ec2-user): " SSH_USER
[ -z "$SSH_USER" ] && echo -e "${RED}ERROR: SSH Username cannot be empty.${NC}" && exit 1

read -p "Enter Remote Server IP Address: " SSH_IP
[ -z "$SSH_IP" ] && echo -e "${RED}ERROR: Server IP cannot be empty.${NC}" && exit 1

read -p "Enter Path to Private SSH Key (e.g., /c/Users/user/.ssh/key.pem): " SSH_KEY_PATH
[ ! -f "$SSH_KEY_PATH" ] && echo -e "${RED}ERROR: SSH Key file not found at $SSH_KEY_PATH.${NC}" && exit 1

read -p "Enter Internal Container Port (e.g., 80): " APP_PORT
[ -z "$APP_PORT" ] && echo -e "${RED}ERROR: Application Port cannot be empty.${NC}" && exit 1


# --- 2 & 3. CLONE, NAVIGATE, AND VERIFY (Tasks 2 & 3) ---

REPO_URL_AUTH="${GIT_REPO/https:\/\//https:\/\/user:$PAT@}"
echo -e "\n[STATUS] Authenticating and preparing repository..."

if [ -d "$REPO_DIR" ]; then
    echo "[GIT] Repository already exists. Pulling latest changes from $BRANCH..."
    # Idempotency: Pulls latest changes
    git -C "$REPO_DIR" pull origin "$BRANCH"
else
    echo "[GIT] Cloning new repository into $REPO_DIR..."
    git clone "$REPO_URL_AUTH" "$REPO_DIR"
fi

# Explicit branch checkout (FIXED - Branch switching not found)
git -C "$REPO_DIR" checkout "$BRANCH"

cd "$REPO_DIR"

echo "[VERIFY] Checking for deployment files..."
if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ]; then
    echo -e "${RED}ERROR: Neither Dockerfile nor docker-compose.yml found in the repository.${NC}"
    exit 1
fi
echo "[VERIFY] Docker files confirmed. Ready for remote transfer."


# --- 4 & 5. REMOTE PREPARATION (AL2023 CONFIG) ---

echo -e "\n--- Establishing SSH Connection to Remote Server ($SSH_IP) ---"
# Connectivity check (FIXED - SSH connection not found)
ssh_exec "echo [CONNECTIVITY] SSH connection successful on remote host."

echo "[REMOTE] Updating system and installing necessary dependencies..."

# COMMANDS TAILORED FOR AMAZON LINUX 2023 (dnf/yum)
REMOTE_SETUP_COMMAND="
    sudo dnf update -y; # Package update (FIXED)
    
    # Install Docker and Nginx (FIXED - Docker/Nginx installation not found)
    sudo dnf install -y docker nginx; 
    
    # Add user to Docker group (Task 5)
    sudo usermod -aG docker $SSH_USER; 
    
    # Enable and start services
    sudo systemctl enable docker && sudo systemctl start docker;
    sudo systemctl enable nginx && sudo systemctl start nginx;
    
    # Confirm installation versions
    docker --version && docker-compose version && nginx -v;
    
    # Re-login the user into the 'docker' group 
    newgrp docker || true
"
ssh_exec "$REMOTE_SETUP_COMMAND"

echo "[REMOTE] Remote environment preparation complete."


# --- 6. DEPLOY THE DOCKERIZED APPLICATION (Task 6 & 10) ---

echo -e "\n--- Transferring and Deploying Application ---"

echo "[SCP] Transferring project directory to remote host..."
# Transfer files (Task 6)
ssh_exec "rm -rf /home/$SSH_USER/$REPO_DIR"
scp -i "$SSH_KEY_PATH" -r . "$SSH_USER@$SSH_IP:/home/$SSH_USER/$REPO_DIR"

# Remote deployment commands
DEPLOY_COMMAND="
    cd /home/$SSH_USER/$REPO_DIR;
    
    # Idempotency: Gracefully stop and remove old containers (Task 10)
    echo '[IDEMPOTENCY] Stopping and removing old containers...';
    docker compose down || true; # Docker Compose Idempotency
    
    # Build and run the new containers (FIXED - Docker build not found)
    echo '[DOCKER] Building and running new containers...';
    docker compose up -d --build;
    
    # Validate container health and logs (Task 6)
    CONTAINER_ID=\$(docker compose ps -q | head -n 1);
    docker ps -a | grep \$CONTAINER_ID;
    echo '[DOCKER] Showing last 5 logs for health check:';
    docker logs -n 5 \$CONTAINER_ID;
"
ssh_exec "$DEPLOY_COMMAND"


# --- 7. CONFIGURE NGINX AS A REVERSE PROXY (Task 7) ---

echo -e "\n--- Configuring NGINX Reverse Proxy ---"

# Dynamic NGINX configuration block
NGINX_CONFIG="
server {
    listen 80;
    server_name $SSH_IP; 

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
"
echo "[NGINX] Writing configuration file..."

# Write config, enable site, test syntax, and reload Nginx
NGINX_COMMAND="
    # Write the config dynamically using tee to a standard conf.d location
    echo '$NGINX_CONFIG' | sudo tee /etc/nginx/conf.d/hng_proxy.conf;
    
    # Remove default Nginx welcome config to ensure clean operation 
    sudo rm -f /etc/nginx/conf.d/default.conf || true; 

    # Test config syntax and reload service
    echo '[NGINX] Testing configuration syntax...';
    sudo nginx -t; 
    sudo systemctl reload nginx;
"
ssh_exec "$NGINX_COMMAND"


# --- 8. FINAL VALIDATION (Task 8) ---

echo -e "\n--- Final Deployment Validation ---"

# Check if Docker service is running remotely (FIXED - Docker service check not found)
ssh_exec "sudo systemctl is-active docker"

# Test public accessibility externally using curl
if curl -Is "http://$SSH_IP" | grep "HTTP/1.1 200 OK" > /dev/null; then
    echo -e "${GREEN}Validation SUCCESS: Application is running and publicly accessible on Port 80.${NC}"
else
    echo -e "${RED}Validation FAILED: Could not receive HTTP 200 OK from public IP. Check logs.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Deployment SUCCESSFUL! Application is LIVE at http://$SSH_IP${NC}"
exit 0
