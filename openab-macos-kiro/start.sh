#!/usr/bin/env bash
# start.sh — Start the OpenAB + Kiro CLI agent on macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load env
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && vim .env"
  exit 1
fi
set -a; source .env; set +a

# Validate
MISSING=""
for var in DISCORD_BOT_TOKEN DISCORD_CHANNEL_ID; do
  val="${!var:-}"
  if [ -z "$val" ] || [[ "$val" == your-* ]]; then
    MISSING="$MISSING $var"
  fi
done
if [ -n "$MISSING" ]; then
  echo "❌ Missing in .env:$MISSING"
  exit 1
fi

# Render config
envsubst < config.toml > config.rendered.toml

# Export for agent
export DISCORD_BOT_TOKEN
export GH_TOKEN="${GH_TOKEN:-}"

# Start openab in background
echo "Starting OpenAB agent (Kiro CLI)..."
nohup openab run -c "$SCRIPT_DIR/config.rendered.toml" > "$SCRIPT_DIR/openab.log" 2>&1 &
echo $! > "$SCRIPT_DIR/openab.pid"

echo ""
echo "✅ Agent running! (PID: $(cat openab.pid))"
echo ""
echo "   Logs:  tail -f $SCRIPT_DIR/openab.log"
echo "   Stop:  ./stop.sh"
echo ""
echo "→ Go to Discord and @mention your bot in channel $DISCORD_CHANNEL_ID"
