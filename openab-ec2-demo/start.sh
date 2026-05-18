#!/usr/bin/env bash
# start.sh — Validate config, render templates, launch agents
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source .env; set +a

# Validate required vars
MISSING=""
for var in DISCORD_BOT_TOKEN_GEMINI1 DISCORD_BOT_TOKEN_GEMINI2 \
           DISCORD_BOT_TOKEN_CLAUDE1 DISCORD_BOT_TOKEN_CLAUDE2 \
           DISCORD_CHANNEL_ID GEMINI_API_KEY ANTHROPIC_API_KEY; do
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
for agent in gemini1 gemini2 claude1 claude2; do
  envsubst < "config/${agent}.toml" > "config/.rendered/${agent}.toml"
done

# Render MCP configs (skip if Atlassian not configured)
if [ -n "${ATLASSIAN_URL:-}" ]; then
  envsubst < "config/mcp-gemini.json" > "config/.rendered/mcp-gemini.json"
  envsubst < "config/mcp-claude.json" > "config/.rendered/mcp-claude.json"
  echo "✓ Atlassian MCP configured"
else
  # Empty MCP config — no servers
  echo '{"mcpServers":{}}' > "config/.rendered/mcp-gemini.json"
  echo '{"mcpServers":{}}' > "config/.rendered/mcp-claude.json"
  echo "ℹ Atlassian not configured (optional)"
fi

# Docker command
DOCKER="docker"
if ! docker info &>/dev/null 2>&1; then DOCKER="sudo docker"; fi

$DOCKER compose up -d

echo ""
echo "✅ All 4 agents running!"
echo ""
echo "   $DOCKER compose ps        # status"
echo "   $DOCKER compose logs -f   # logs"
echo "   $DOCKER compose down      # stop"
