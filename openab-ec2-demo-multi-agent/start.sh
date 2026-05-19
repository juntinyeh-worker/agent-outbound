#!/usr/bin/env bash
# start.sh — Launch single-bot multi-agent setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source .env; set +a

# Validate
MISSING=""
for var in DISCORD_BOT_TOKEN DISCORD_CHANNEL_ID ROUTER_API_KEY PLANNER_API_KEY DEVELOPER_API_KEY REVIEWER_API_KEY; do
  val="${!var:-}"
  if [ -z "$val" ] || [[ "$val" == your-* ]]; then
    MISSING="$MISSING $var"
  fi
done

if [ -n "$MISSING" ]; then
  echo "❌ Missing in .env:"
  for v in $MISSING; do echo "   - $v"; done
  exit 1
fi

# Render router config
mkdir -p config/.rendered
envsubst < config/router.toml > config/.rendered/router.toml
cp config/mcp-router.json config/.rendered/mcp-router.json

# Docker command
DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then DOCKER="sudo docker"; fi

$DOCKER compose up -d

echo ""
echo "✅ Multi-agent system running!"
echo ""
echo "   Router (Discord bot) → orchestrates planner + developer + reviewer"
echo ""
echo "   $DOCKER compose ps        # status"
echo "   $DOCKER compose logs -f   # logs"
echo "   $DOCKER compose down      # stop"
echo ""
echo "→ @mention your bot in Discord — it will route to the right agent"
