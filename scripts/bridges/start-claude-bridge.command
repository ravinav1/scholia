#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${CLAUDE_BRIDGE_PORT:-8787}"

if [ -f "$SCRIPT_DIR/.claude-bridge-env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.claude-bridge-env"
fi
PORT="${BRIDGE_PORT:-$PORT}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "Invalid Claude bridge port: $PORT" >&2
  exit 2
fi

NODE="${BRIDGE_NODE:-}"
[ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [ -x "$NODE" ] && break
  [ -x "$candidate" ] && NODE="$candidate"
done
[ -x "$NODE" ] || { echo "Node.js was not found. Re-run the bridge installer." >&2; exit 127; }

CLAUDE="${BRIDGE_CLAUDE:-}"
[ -x "$CLAUDE" ] || CLAUDE="$(command -v claude 2>/dev/null || true)"
for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -x "$CLAUDE" ] && break
  [ -x "$candidate" ] && CLAUDE="$candidate"
done
[ -x "$CLAUDE" ] || { echo "Claude Code was not found. Install it and re-run the bridge installer." >&2; exit 127; }

HEALTH_URL="http://127.0.0.1:${PORT}/health"
if curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
  exit 0
fi
LISTENER="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$LISTENER" ]; then
  echo "Port $PORT is already used by process $LISTENER; refusing to stop it." >&2
  exit 1
fi

LOG_FILE="${TMPDIR:-/tmp}/scholia-claude-bridge.log"
nohup "$NODE" "$SCRIPT_DIR/claude-code-bridge.mjs" --port "$PORT" --claude "$CLAUDE" >"$LOG_FILE" 2>&1 &
disown || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1 && exit 0
  sleep 0.5
done

echo "The Claude bridge has not become ready. See $LOG_FILE" >&2
exit 1
