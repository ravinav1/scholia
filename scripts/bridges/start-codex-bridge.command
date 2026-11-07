#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8789
NODE=""
CODEX=""

if [ -f "$SCRIPT_DIR/.codex-bridge-env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.codex-bridge-env"
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "Invalid Codex bridge port: $PORT" >&2
  exit 2
fi

[ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [ -x "$NODE" ] && break
  [ -x "$candidate" ] && NODE="$candidate"
done
[ -x "$NODE" ] || { echo "Node.js was not found. Re-run the bridge installer." >&2; exit 127; }

[ -x "$CODEX" ] || CODEX="$(command -v codex 2>/dev/null || true)"
for candidate in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
  [ -x "$CODEX" ] && break
  [ -x "$candidate" ] && CODEX="$candidate"
done
[ -x "$CODEX" ] || { echo "Codex was not found. Install it and re-run the bridge installer." >&2; exit 127; }

HEALTH_URL="http://127.0.0.1:${PORT}/health"
if curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
  exit 0
fi
LISTENER="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$LISTENER" ]; then
  echo "Port $PORT is already used by process $LISTENER; refusing to stop it." >&2
  exit 1
fi

LOG_FILE="${TMPDIR:-/tmp}/scholia-codex-bridge.log"
nohup "$NODE" "$SCRIPT_DIR/codex-bridge.mjs" --port "$PORT" --codex "$CODEX" >"$LOG_FILE" 2>&1 &
disown || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1 && exit 0
  sleep 0.5
done

echo "The Codex bridge has not become ready. See $LOG_FILE" >&2
exit 1
