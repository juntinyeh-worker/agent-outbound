#!/usr/bin/env bash
# install.sh — One-line installer for OpenAB agent demo on a fresh EC2
# Usage: curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo"
INSTALL_DIR="$HOME/openab-demo"

echo "════════════════════════════════════════════════════════════"
echo " OpenAB Agent Demo — One-Line Installer"
echo "════════════════════════════════════════════════════════════"

###############################################################################
# Detect OS
###############################################################################
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
else
  OS_ID="unknown"
fi
echo "==> Detected OS: $OS_ID"

###############################################################################
# Step 1: Install Docker + git
###############################################################################
echo "==> [1/5] Installing Docker..."
if command -v docker &>/dev/null; then
  echo "    Docker already installed ✓"
else
  case "$OS_ID" in
    amzn)
      sudo dnf install -y docker git
      sudo systemctl enable --now docker
      ;;
    ubuntu|debian)
      sudo apt-get update
      sudo apt-get install -y ca-certificates curl git
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://download.docker.com/linux/$OS_ID/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      sudo systemctl enable --now docker
      ;;
    *)
      echo "ERROR: Unsupported OS ($OS_ID). Install Docker manually then re-run."
      exit 1
      ;;
  esac
fi

if ! groups | grep -q docker; then
  sudo usermod -aG docker "$USER"
fi

###############################################################################
# Step 2: Docker Compose
###############################################################################
echo "==> [2/5] Checking Docker Compose..."
if docker compose version &>/dev/null 2>&1 || sudo docker compose version &>/dev/null 2>&1; then
  echo "    Docker Compose available ✓"
else
  COMPOSE_VERSION="v2.29.2"
  ARCH=$(uname -m)
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

# envsubst
if ! command -v envsubst &>/dev/null; then
  case "$OS_ID" in
    amzn) sudo dnf install -y gettext ;;
    ubuntu|debian) sudo apt-get install -y gettext-base ;;
  esac
fi

###############################################################################
# Step 3: Build agent images from source
###############################################################################
echo "==> [3/5] Building agent images (takes a few minutes on first run)..."
OPENAB_SRC="$HOME/.openab-src"
if [ ! -d "$OPENAB_SRC" ]; then
  git clone --depth 1 https://github.com/openabdev/openab.git "$OPENAB_SRC"
fi

DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then DOCKER="sudo docker"; fi

if ! $DOCKER image inspect openab-gemini:latest &>/dev/null 2>&1; then
  echo "    Building openab-gemini..."
  $DOCKER build -f "$OPENAB_SRC/Dockerfile.gemini" -t openab-gemini:latest "$OPENAB_SRC"
fi

if ! $DOCKER image inspect openab-claude:latest &>/dev/null 2>&1; then
  echo "    Building openab-claude..."
  $DOCKER build -f "$OPENAB_SRC/Dockerfile.claude" -t openab-claude:latest "$OPENAB_SRC"
fi
echo "    Images ready ✓"

###############################################################################
# Step 4: Download project files
###############################################################################
echo "==> [4/5] Downloading configuration..."
mkdir -p "$INSTALL_DIR/config"
cd "$INSTALL_DIR"

for f in docker-compose.yml docker-compose.gemini3.yml docker-compose.claude2.yml \
         .env.example start.sh \
         config/gemini1.toml config/gemini2.toml config/gemini3.toml \
         config/claude1.toml config/claude2.toml; do
  curl -fsSL "$REPO_URL/$f" -o "$f"
done
chmod +x start.sh

###############################################################################
# Step 5: Setup swap (4GB)
###############################################################################
echo "==> [5/5] Setting up swap..."
if [ ! -f /swapfile ]; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  echo "    4GB swap enabled ✓"
else
  echo "    Swap already configured ✓"
fi

###############################################################################
# Done
###############################################################################
if [ ! -f "$INSTALL_DIR/.env" ]; then
  cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅  Installation complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Next steps:"
echo ""
echo "   cd $INSTALL_DIR"
echo "   vim .env                    # fill in bot tokens + API keys"
echo ""
echo " Then pick a scenario:"
echo "   ./start.sh                  # 2x Gemini + 2x Claude"
echo "   ./start.sh gemini3          # 3x Gemini"
echo "   ./start.sh claude2          # 2x Claude"
echo ""
