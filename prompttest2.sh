#!/usr/bin/env bash
# deploy.sh — Stage 1 scaffold: collect inputs, clone/pull repo, validate Docker files
# POSIX-friendly; keep simple. Run: ./deploy.sh
set -u  # treat unset vars as error
set -o errexit || true  # try to exit on error; some shells don't support
IFS=$'\n\t'

# --- helpers ---
timestamp() {
  date +"%Y%m%d_%H%M%S"
}

LOG_FILE="deploy_$(timestamp).log"

log() {
  printf "%s %s\n" "$(date --rfc-3339=seconds 2>/dev/null || date)" "$1" | tee -a "$LOG_FILE"
}

err_exit() {
  code="${1:-1}"
  msg="${2:-"Unknown error"}"
  log "ERROR: $msg (exit $code)"
  exit "$code"
}

cleanup_on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "Script exited with non-zero status: $rc"
  else
    log "Script completed successfully."
  fi
}
trap cleanup_on_exit EXIT

# --- input prompts & validation ---
prompt() {
  msg="$1"
  def="${2:-}"
  printf "%s" "$msg"
  if [ -n "$def" ]; then
    printf " [default: %s]" "$def"
  fi
  printf ": "
  read ans
  if [ -z "$ans" ]; then
    ans="$def"
  fi
  printf "%s" "$ans"
}

#Begin propmt process
#echo "== Starting deploy.sh (stage 1) =="

read -p "Enter Git repository HTTPS URL: " REPO_URL
if [ -z "$REPO_URL" ]; then
  echo "Repository URL is required."
  exit 2
fi

read -p "Enter your PAT: " PAT
if [ -z "$PAT" ]; then
  echo "PAT is required."
  exit 3
fi

read -p "Enter your branch name: " BRANCH_NAME
BRANCH_NAME=${BRANCH_NAME:-main}

echo "Enter your remote server SSH details "

read -p "Enter Server Username: " SERVER_USERNAME
if [ -z "$SERVER_USERNAME" ]; then
  echo "SERVER_USERNAME is required."
  exit 4
fi
read -p "Enter Server IP address: " SERVER_IPADDRESS
if [ -z "$SERVER_IPADDRESS" ]; then
  echo "SERVER_IPADDRESS is required."
  exit 5
fi
read -p "Enter Server SSH Key Path: " SERVER_SSHKEYPATH
if [ -z "$SERVER_SSHKEYPATH" ]; then
  echo "SERVER_SSHKEYPATH is required."
  exit 6
fi

read -p "Enter the Application Port: " APP_PORT
APP_PORT=${APP_PORT:-8000}

case "$APP_PORT" in
  ''|*[!0-9]*) echo "Invalid port: $APP_PORT"; exit 6 ;;
esac



# --- repo clone/pull ---
log "== Stage 2: Clone or Update Repository =="

# Create a directory to hold the repo
WORK_DIR="C:\Users\User\Documents\devops-task\deployment_repo"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Extract repo name from URL
REPO_NAME=$(basename -s .git "$REPO_URL")

if [ -d "$REPO_NAME/.git" ]; then
  log "Repository already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git pull origin "$BRANCH_NAME" || err_exit 8 "Failed to pull latest changes"
else
  log "Cloning repository..."
  # Use PAT for authentication
  AUTH_URL=$(echo "$REPO_URL" | sed "s#https://#https://$PAT@#")
  git clone --branch "$BRANCH_NAME" "$AUTH_URL" "$REPO_NAME" || err_exit 9 "Failed to clone repository"
  cd "$REPO_NAME"
fi

# Confirm branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH_NAME" ]; then
  log "Switching to branch: $BRANCH_NAME"
  git checkout "$BRANCH_NAME" || err_exit 10 "Failed to switch branch"
fi

log " Repository ready at $(pwd)"


# --- Navigate Docker Setup ---
log "== Stage 3: Verify Docker Setup =="

# Ensure we're in the right directory
if [ ! -d "$WORK_DIR" ]; then
  err_exit 11 "Repository directory not found."
fi

cd "$WORK_DIR" || err_exit 12 "Failed to navigate into repository directory."

# Check for Dockerfile or docker-compose.yml
if [ -f "C:\Users\User\Documents\devops_task\hng13-stage0-devops\Dockerfile" ]; then
  log " Dockerfile found."
elif [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
  log " docker-compose file found."
else
  err_exit 13 "No Dockerfile or docker-compose.yml found in the repository."
fi

log "Repository and Docker setup verified successfully!"



#---SSH into the Remote Server---
log "Stage 4 remote server connectivity"


#CHECK FOR CONNECTIVITY
if  ssh -i "$SERVER_SSHKEYPATH" -o StrictHostKeyChecking=no -o BatchMode=yes "$SERVER_USERNAME@$SERVER_IPADDRESS" "echo 'SSH connection successful!'" 2>/dev/null; then
  log "SSH connection verified successfully."
else
  err_exit 20 "Unable to connect to remote server via SSH. Check IP, username, or key path."
fi

# REMOTE COMMAND Example
if ssh -i "$SERVER_SSHKEYPATH" "$SERVER_USERNAME@$SERVER_IPADDRESS" "command -v docker >/dev/null 2>&1"; then
    echo "Docker is installed"
else
    echo "Docker not found"
fi
# --- Prepare Remote Environment ---
log "== Stage 5: Prepare Remote Environment =="

if ssh -i "$SERVER_SSHKEYPATH" -o StrictHostKeyChecking=no "$SERVER_USERNAME@$SERVER_IPADDRESS" 'bash -s' <<'REMOTE_CMDS'
  set -e
  echo "Updating system packages..."
  sudo apt-get update -y && sudo apt-get upgrade -y

  echo "Installing Docker if missing..."
  if ! command -v docker &>/dev/null; then
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  echo "Installing Docker Compose if missing..."
  if ! command -v docker-compose &>/dev/null; then
    sudo apt-get install -y docker-compose
  fi

  echo "Installing Nginx if missing..."
  if ! command -v nginx &>/dev/null; then
    sudo apt-get install -y nginx
  fi

  echo "Adding user to Docker group..."
  sudo usermod -aG docker $USER

  echo "Enabling and starting services..."
  sudo systemctl enable docker || true
  sudo systemctl start docker || true
  sudo systemctl enable nginx || true
  sudo systemctl start nginx || true

  echo "Confirming installations..."
  docker --version || echo "Docker not found"
  docker-compose --version || echo "Docker Compose not found"
  nginx -v || echo "Nginx not found"

REMOTE_CMDS
then
  log "Remote environment setup completed successfully."
else
  err_exit 30 "Failed to prepare remote environment."
fi


log "== Stage 6: Deploy Dockerized Application =="

# Variables
REMOTE_PATH="/home/$SERVER_USERNAME/app"
LOCAL_PATH="/c/Users/User/Documents/devops_task/hng13-stage0-devops"

# Transfer project files via scp
log "Transferring project files to remote server..."
scp -i "$SERVER_SSHKEYPATH" -r "$LOCAL_PATH" "$SERVER_USERNAME@$SERVER_IPADDRESS:$REMOTE_PATH" || err_exit 30 "File transfer failed."

# SSH into remote server and deploy
ssh -i "$SERVER_SSHKEYPATH" "$SERVER_USERNAME@$SERVER_IPADDRESS" <<'REMOTE_CMDS'
  set -e
  echo "== Starting Docker deployment on remote server =="

  cd ~/app || { echo "App directory not found"; exit 31; }

  # Build and run containers
  if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose..."
    sudo docker-compose down || true
    sudo docker-compose up -d --build
  elif [ -f "Dockerfile" ]; then
    echo "Using Dockerfile..."
    APP_NAME=$(basename "$PWD")
    sudo docker build -t "$APP_NAME" .
    sudo docker run -d -p 8000:8000 "$APP_NAME"
  else
    echo " No Dockerfile or docker-compose.yml found"
    exit 32
  fi

  # Validate container health
  echo "Checking running containers..."
  sudo docker ps

  echo "Checking logs..."
  sudo docker logs $(sudo docker ps -q | head -n 1) | tail -n 10 || echo "No logs available."

  echo "== Deployment complete =="
REMOTE_CMDS

# Validate from local machine

log "Checking application accessibility..."
curl -s --max-time 5 "http://$SERVER_IPADDRESS:$APP_PORT" >/dev/null && \
  log " App accessible" || log " App not accessible"

# log "Checking application accessibility..."
# if curl -s "http://$SERVER_IPADDRESS:$APP_PORT" >/dev/null; then
#   log "Application is accessible at http://$SERVER_IPADDRESS:$APP_PORT"
# else
#   log " Could not confirm application accessibility. Check container logs on the remote server."
# fi















#echo "ssh -i "$SERVER_SSHKEYPATH" -o StrictHostKeyChecking=no -o BatchMode=yes "$SERVER_USERNAME@$SERVER_IPADDRESS""
# echo "DEBUG: WORK_DIR=$WORK_DIR"
# echo "DEBUG: REPO_NAME=$REPO_NAME"
# echo "DEBUG: Full path: $WORK_DIR/$REPO_NAME"

# ls -la

#echo "DEBUG: SSH command uses key='$SERVER_SSHKEYPATH',ip='$SERVER_IPADDRESS', servername='$SERVER_USERNAME'"

# echo "DEBUG: Checking if directory exists at: $WORK_DIR"
# ls -la "$WORK_DIR" || echo "DEBUG: $WORK_DIR not found"

