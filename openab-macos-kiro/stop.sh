#!/usr/bin/env bash
# stop.sh — Stop the OpenAB agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/openab.pid"

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    rm "$PID_FILE"
    echo "✅ Agent stopped (PID: $PID)"
  else
    rm "$PID_FILE"
    echo "Agent was not running (stale PID file removed)"
  fi
else
  echo "No PID file found. Agent not running?"
fi
