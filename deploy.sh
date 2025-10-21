# --- 1. COLLECT PARAMETERS FROM USER INPUT (Task 1) ---

echo -e "\n--- Collecting Deployment Parameters ---"

read -p "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO
[ -z "$GIT_REPO" ] && echo -e "${RED}ERROR: Git URL cannot be empty.${NC}" && exit 1

read -p "Enter Git Personal Access Token (PAT): " PAT
[ -z "$PAT" ] && echo -e "${RED}ERROR: PAT cannot be empty.${NC}" && exit 1

read -p "Enter branch name (default: main): " BRANCH
[ -z "$BRANCH" ] && BRANCH="main"

read -p "Enter Remote SSH Username (e.g., ubuntu, ec2-user): " SSH_USER
[ -z "$SSH_USER" ] && echo -e "${RED}ERROR: SSH Username cannot be empty.${NC}" && exit 1

read -p "Enter Remote Server IP Address: " SSH_IP
[ -z "$SSH_IP" ] && echo -e "${RED}ERROR: Server IP cannot be empty.${NC}" && exit 1

read -p "Enter Path to Private SSH Key (e.g., /home/user/.ssh/key.pem): " SSH_KEY_PATH
[ ! -f "$SSH_KEY_PATH" ] && echo -e "${RED}ERROR: SSH Key file not found at $SSH_KEY_PATH.${NC}" && exit 1

read -p "Enter Internal Container Port (e.g., 8080): " APP_PORT
[ -z "$APP_PORT" ] && echo -e "${RED}ERROR: Application Port cannot be empty.${NC}" && exit 1

# --- 2. CLONE/PULL REPOSITORY (Task 2 & 10) ---

REPO_URL_AUTH="${GIT_REPO/https:\/\//https:\/\/user:$PAT@}"
echo -e "\n[STATUS] Authenticating and preparing repository..."

if [ -d "$REPO_DIR" ]; then
    echo "[GIT] Repository already exists. Pulling latest changes from $BRANCH..."
    # If the directory exists, pull latest changes for Idempotency
    git -C "$REPO_DIR" pull origin "$BRANCH"
else
    # FIX: Create the directory first and then clone into it
    echo "[GIT] Creating local directory: $REPO_DIR..."
    mkdir -p "$REPO_DIR"
    
    echo "[GIT] Cloning new repository into $REPO_DIR..."
    git clone "$REPO_URL_AUTH" "$REPO_DIR"
fi

# --- 3. NAVIGATE AND VERIFY FILES (Task 3) ---

cd "$REPO_DIR"

echo "[VERIFY] Checking for deployment files..."
# Verify that either a Dockerfile OR docker-compose.yml exists
if [ ! -f Dockerfile ] && [ ! -f docker-compose.yml ]; then
    echo -e "${RED}ERROR: Neither Dockerfile nor docker-compose.yml found in the repository.${NC}"
    exit 1
fi
echo "[VERIFY] Docker files confirmed. Ready for remote deployment."

# --- 4. SSH CONNECTIVITY AND 5. REMOTE PREPARATION (Tasks 4 & 5) ---

echo -e "\n--- Establishing SSH Connection to Remote Server ($SSH_IP) ---"
# Perform connectivity check
ssh_exec "echo [CONNECTIVITY] SSH connection successful on remote host."

echo "[REMOTE] Updating system and installing necessary dependencies..."

# COMMANDS TAILORED FOR AMAZON LINUX 2023 (dnf/yum)
REMOTE_SETUP_COMMAND="
    # Update system packages using dnf (or yum)
    sudo dnf update -y;
    
    # Install Docker and Nginx (Docker Compose is included in Docker on AL2023)
    sudo dnf install -y docker nginx;
    
    # Add user to Docker group (Task 5)
    sudo usermod -aG docker $SSH_USER; 
    
    # Enable and start services
    sudo systemctl enable docker && sudo systemctl start docker;
    sudo systemctl enable nginx && sudo systemctl start nginx;
    
    # Confirm installation versions
    docker --version && docker-compose version && nginx -v;
    
    # Re-login the user into the 'docker' group (optional but safer)
    newgrp docker || true
"
# Execute all preparation commands remotely
ssh_exec "$REMOTE_SETUP_COMMAND"

echo "[REMOTE] Remote environment preparation complete."

# --- 6. DEPLOY THE DOCKERIZED APPLICATION (Task 6 & 10) ---

echo -e "\n--- Transferring and Deploying Application ---"

# Transfer project files using scp (Task 6)
echo "[SCP] Transferring project directory to remote host..."
# First, ensure the remote directory is clean/non-existent before transfer
# This ensures idempotency and a fresh deployment
ssh_exec "rm -rf /home/$SSH_USER/$REPO_DIR"
scp -i "$SSH_KEY_PATH" -r . "$SSH_USER@$SSH_IP:/home/$SSH_USER/$REPO_DIR"

# Remote deployment commands
DEPLOY_COMMAND="
    echo '[DEPLOY] Navigating to /home/$SSH_USER/$REPO_DIR';
    cd /home/$SSH_USER/$REPO_DIR;
    
    # Idempotency: Gracefully stop and remove old running containers (Task 10)
    echo '[IDEMPOTENCY] Stopping and removing old containers...';
    # '|| true' ensures the script doesn't stop if no containers are running
    docker-compose down || true;
    
    # Build and run the new containers in detached mode
    echo '[DOCKER] Building and running new containers...';
    docker-compose up -d --build;
    
    # Validate container health and logs (Task 6)
    CONTAINER_ID=\$(docker-compose ps -q | head -n 1);
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
        # Forward public Port 80 traffic to the container's internal port
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
"
echo "[NGINX] Writing configuration file..."

# Write config, remove default config, enable site, test syntax, and reload Nginx
NGINX_COMMAND="
    # Write the config dynamically using tee (requires sudo)
    echo '$NGINX_CONFIG' | sudo tee /etc/nginx/conf.d/hng_proxy.conf;
    
    # Remove the default Nginx configuration file if it exists 
    sudo rm -f /etc/nginx/nginx.conf.d/default.conf || true; 

    # Test config syntax (Task 7)
    echo '[NGINX] Testing configuration syntax...';
    sudo nginx -t; 
    
    # Reload Nginx service (Task 7)
    sudo systemctl reload nginx;
"
ssh_exec "$NGINX_COMMAND"


# --- 8. FINAL VALIDATION (Task 8) ---

echo -e "\n--- Final Deployment Validation ---"

# Test public accessibility externally using curl
if curl -Is "http://$SSH_IP" | grep "HTTP/1.1 200 OK" > /dev/null; then
    echo -e "${GREEN}Validation SUCCESS: Application is running and publicly accessible on Port 80.${NC}"
else
    echo -e "${RED}Validation FAILED: Could not receive HTTP 200 OK from public IP. Check logs.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Deployment SUCCESSFUL! Application is LIVE at http://$SSH_IP${NC}"
exit 0
