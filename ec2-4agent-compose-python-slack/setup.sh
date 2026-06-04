#!/usr/bin/env bash
# setup.sh — One-stop setup for OpenAB 4-agent demo on a fresh EC2 (Amazon Linux 2023 / Ubuntu)
# Supports PLATFORM=discord or PLATFORM=slack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "════════════════════════════════════════════════════════════"
echo " OpenAB 4-Agent Demo — EC2 Setup (Python + Discord/Slack)"
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
  echo "    Added $USER to docker group (re-login or use 'newgrp docker')"
fi

###############################################################################
# Step 2: Install Docker Compose plugin (if not bundled)
###############################################################################
echo "==> [2/5] Checking Docker Compose..."
if docker compose version &>/dev/null; then
  echo "    Docker Compose available ✓"
else
  COMPOSE_VERSION="v2.29.2"
  ARCH=$(uname -m)
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

if ! command -v envsubst &>/dev/null; then
  case "$OS_ID" in
    amzn) sudo dnf install -y gettext ;;
    ubuntu|debian) sudo apt-get install -y gettext-base ;;
  esac
fi

###############################################################################
# Step 3: Validate .env
###############################################################################
echo "==> [3/5] Checking configuration..."
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" 2>/dev/null || true
  echo "    ⚠️  Created .env from template — edit it, then re-run."
  exit 1
fi

set -a; source "$SCRIPT_DIR/.env"; set +a

PLATFORM="${PLATFORM:-discord}"
echo "    Platform: $PLATFORM"

MISSING=""
if [ "$PLATFORM" = "discord" ]; then
  for var in DISCORD_BOT_TOKEN_KIRO DISCORD_BOT_TOKEN_CLAUDE DISCORD_BOT_TOKEN_GEMINI DISCORD_BOT_TOKEN_CODEX \
             DISCORD_CHANNEL_ID KIRO_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
    val="${!var:-}"
    if [ -z "$val" ] || [[ "$val" == your-* ]]; then MISSING="$MISSING $var"; fi
  done
elif [ "$PLATFORM" = "slack" ]; then
  for var in SLACK_BOT_TOKEN_KIRO SLACK_BOT_TOKEN_CLAUDE SLACK_BOT_TOKEN_GEMINI SLACK_BOT_TOKEN_CODEX \
             SLACK_APP_TOKEN_KIRO SLACK_APP_TOKEN_CLAUDE SLACK_APP_TOKEN_GEMINI SLACK_APP_TOKEN_CODEX \
             SLACK_CHANNEL_ID KIRO_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
    val="${!var:-}"
    if [ -z "$val" ] || [[ "$val" == your-* ]] || [[ "$val" == xoxb-* && "$val" == "xoxb-your"* ]]; then MISSING="$MISSING $var"; fi
  done
else
  echo "    ❌ PLATFORM must be 'discord' or 'slack'"; exit 1
fi

if [ -n "$MISSING" ]; then
  echo "    ❌ Missing or placeholder values in .env:"
  for v in $MISSING; do echo "       - $v"; done
  echo "    Edit .env and re-run."
  exit 1
fi
echo "    Configuration valid ✓"

###############################################################################
# Step 4: Generate platform-specific config blocks and render templates
###############################################################################
echo "==> [4/5] Building custom images (Python runtime)..."

# Generate platform blocks per agent
generate_platform_block() {
  local agent_upper="$1"
  if [ "$PLATFORM" = "discord" ]; then
    local token_var="DISCORD_BOT_TOKEN_${agent_upper}"
    cat <<EOF
[discord]
bot_token = "${!token_var}"
allow_all_channels = false
allowed_channels = ["${DISCORD_CHANNEL_ID}"]
allow_bot_messages = "mentions"
trusted_bot_ids = []
EOF
  else
    local bot_token_var="SLACK_BOT_TOKEN_${agent_upper}"
    local app_token_var="SLACK_APP_TOKEN_${agent_upper}"
    cat <<EOF
[slack]
bot_token = "${!bot_token_var}"
app_token = "${!app_token_var}"
allow_all_channels = false
allowed_channels = ["${SLACK_CHANNEL_ID}"]
allow_bot_messages = "mentions"
EOF
  fi
}

# Export platform blocks for envsubst
export PLATFORM_BLOCK_KIRO="$(generate_platform_block KIRO)"
export PLATFORM_BLOCK_CLAUDE="$(generate_platform_block CLAUDE)"
export PLATFORM_BLOCK_GEMINI="$(generate_platform_block GEMINI)"
export PLATFORM_BLOCK_CODEX="$(generate_platform_block CODEX)"

mkdir -p "$SCRIPT_DIR/config/.rendered"
for agent in kiro claude gemini codex; do
  envsubst < "$SCRIPT_DIR/config/${agent}.toml" > "$SCRIPT_DIR/config/.rendered/${agent}.toml"
done

cd "$SCRIPT_DIR"
docker compose build

###############################################################################
# Step 5: Launch
###############################################################################
echo "==> [5/5] Starting 4 agents..."
docker compose up -d

###############################################################################
# Done
###############################################################################
echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅  All 4 agents are running ($PLATFORM mode, Python enabled)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Status:   docker compose ps"
echo " Logs:     docker compose logs -f agent-gemini"
echo " Stop:     docker compose down"
echo ""
echo " Python:   docker exec openab-gemini python --version"
echo " Install:  docker exec -u root openab-gemini apt-get install -y <pkg>"
echo ""
if [ "$PLATFORM" = "discord" ]; then
  echo " → @mention your bots in Discord channel $DISCORD_CHANNEL_ID"
else
  echo " → @mention your bots in Slack channel $SLACK_CHANNEL_ID"
fi
echo ""
