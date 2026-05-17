#!/usr/bin/env bash
# start.sh — Render configs and launch all 4 agents
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load and validate .env
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source .env; set +a

MISSING=""
for var in DISCORD_BOT_TOKEN_KIRO DISCORD_BOT_TOKEN_CLAUDE DISCORD_BOT_TOKEN_GEMINI DISCORD_BOT_TOKEN_CODEX \
           DISCORD_CHANNEL_ID KIRO_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
  val="${!var:-}"
  if [ -z "$val" ] || [[ "$val" == your-* ]]; then
    MISSING="$MISSING $var"
  fi
done

if [ -n "$MISSING" ]; then
  echo "❌ Missing or placeholder values in .env:"
  for v in $MISSING; do echo "   - $v"; done
  echo "Edit .env and re-run."
  exit 1
fi

# Render config templates
mkdir -p config/.rendered
for agent in kiro claude gemini codex; do
  envsubst < "config/${agent}.toml" > "config/.rendered/${agent}.toml"
done

# Determine docker command (handle fresh installs where group hasn't taken effect)
DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

# Launch
$DOCKER compose up -d --pull always

echo ""
echo "✅ All 4 agents running!"
echo ""
echo "   $DOCKER compose ps        # status"
echo "   $DOCKER compose logs -f   # logs"
echo "   $DOCKER compose down      # stop"
echo ""
echo "→ Go to Discord and @mention your bots in channel $DISCORD_CHANNEL_ID"
