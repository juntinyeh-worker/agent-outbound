#!/usr/bin/env bash
# start.sh — Validate config, render templates, launch agents
# Usage:
#   ./start.sh                  # Scenario A: 2x Gemini + 2x Claude (default)
#   ./start.sh gemini3          # Scenario B: 3x Gemini
#   ./start.sh claude2          # Scenario C: 2x Claude
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SCENARIO="${1:-default}"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source .env; set +a

# Determine which compose file and agents to render
case "$SCENARIO" in
  gemini3)
    COMPOSE_FILE="docker-compose.gemini3.yml"
    AGENTS="gemini1 gemini2 gemini3"
    REQUIRED_VARS="DISCORD_BOT_TOKEN_GEMINI1 DISCORD_BOT_TOKEN_GEMINI2 DISCORD_BOT_TOKEN_GEMINI3 DISCORD_CHANNEL_ID GEMINI_API_KEY"
    ;;
  claude2)
    COMPOSE_FILE="docker-compose.claude2.yml"
    AGENTS="claude1 claude2"
    REQUIRED_VARS="DISCORD_BOT_TOKEN_CLAUDE1 DISCORD_BOT_TOKEN_CLAUDE2 DISCORD_CHANNEL_ID ANTHROPIC_API_KEY"
    ;;
  *)
    COMPOSE_FILE="docker-compose.yml"
    AGENTS="gemini1 gemini2 claude1 claude2"
    REQUIRED_VARS="DISCORD_BOT_TOKEN_GEMINI1 DISCORD_BOT_TOKEN_GEMINI2 DISCORD_BOT_TOKEN_CLAUDE1 DISCORD_BOT_TOKEN_CLAUDE2 DISCORD_CHANNEL_ID GEMINI_API_KEY ANTHROPIC_API_KEY"
    ;;
esac

# Validate required vars
MISSING=""
for var in $REQUIRED_VARS; do
  val="${!var:-}"
  if [ -z "$val" ] || [[ "$val" == your-* ]]; then
    MISSING="$MISSING $var"
  fi
done

if [ -n "$MISSING" ]; then
  echo "❌ Missing or placeholder values in .env:"
  for v in $MISSING; do echo "   - $v"; done
  exit 1
fi

# Render agent configs
mkdir -p config/.rendered
for agent in $AGENTS; do
  envsubst < "config/${agent}.toml" > "config/.rendered/${agent}.toml"
done

# Docker command
DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then DOCKER="sudo docker"; fi

$DOCKER compose -f "$COMPOSE_FILE" up -d

echo ""
echo "✅ Agents running! (scenario: $SCENARIO)"
echo ""
echo "   $DOCKER compose -f $COMPOSE_FILE ps        # status"
echo "   $DOCKER compose -f $COMPOSE_FILE logs -f   # logs"
echo "   $DOCKER compose -f $COMPOSE_FILE down      # stop"
