#!/usr/bin/env bash
# install.sh — One-line installer for OpenAB 4-agent demo on a fresh EC2
# Usage: curl -fsSL https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo/install.sh | bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/juntinyeh-worker/agent-outbound/main/openab-ec2-demo"
INSTALL_DIR="$HOME/openab-demo"

echo "════════════════════════════════════════════════════════════"
echo " OpenAB 4-Agent Demo — One-Line Installer"
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
# Step 1: Install Docker
###############################################################################
echo "==> [1/5] Installing Docker..."
if command -v docker &>/dev/null; then
  echo "    Docker already installed ✓"
else
  case "$OS_ID" in
    amzn)
      sudo dnf install -y docker
      sudo systemctl enable --now docker
      ;;
    ubuntu|debian)
      sudo apt-get update
      sudo apt-get install -y ca-certificates curl
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
# Step 2: Install Docker Compose
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
  echo "    Docker Compose installed ✓"
fi

###############################################################################
# Step 3: Install envsubst
###############################################################################
if ! command -v envsubst &>/dev/null; then
  case "$OS_ID" in
    amzn) sudo dnf install -y gettext ;;
    ubuntu|debian) sudo apt-get install -y gettext-base ;;
  esac
fi

###############################################################################
# Step 4: Download project files
###############################################################################
echo "==> [3/5] Downloading configuration..."
mkdir -p "$INSTALL_DIR/config"
cd "$INSTALL_DIR"

for f in docker-compose.yml .env.example config/kiro.toml config/claude.toml config/gemini.toml config/codex.toml; do
  curl -fsSL "$REPO_URL/$f" -o "$f"
done

###############################################################################
# Step 5: Interactive configuration
###############################################################################
echo "==> [4/5] Configuration..."
if [ ! -f .env ]; then
  cp .env.example .env
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅  Installation complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Next steps:"
echo ""
echo "   cd $INSTALL_DIR"
echo "   vim .env              # Fill in your API keys and bot tokens"
echo "   ./start.sh            # Launch all 4 agents"
echo ""
echo " Required in .env:"
echo "   - 4 Discord bot tokens (one per agent)"
echo "   - Discord channel ID"
echo "   - API keys: Kiro, Anthropic, Gemini, OpenAI"
echo ""

# Download start script
curl -fsSL "$REPO_URL/start.sh" -o start.sh
chmod +x start.sh
