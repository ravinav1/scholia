#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${OPENCODE_PORT:-4096}"
PASSWORD="${OPENCODE_SERVER_PASSWORD:-}"

# Allowed browser origins. Add more here if you host the site elsewhere.
CORS_ORIGINS=(
  "http://localhost:8000"
  "https://folk.ntnu.no"
  "https://heaps0rt.github.io"
)

if [ -f "$SCRIPT_DIR/.opencode-env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.opencode-env"
fi
[ -n "${OPENCODE_PORT:-}" ] && PORT="$OPENCODE_PORT"
[ -n "${OPENCODE_PASSWORD:-}" ] && PASSWORD="$OPENCODE_PASSWORD"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "Invalid opencode port: $PORT" >&2
  exit 2
fi

OPENCODE="${OPENCODE_BIN:-}"
[ -x "$OPENCODE" ] || OPENCODE="$(command -v opencode 2>/dev/null || true)"
for candidate in "$HOME/.local/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode "$HOME/bin/opencode"; do
  [ -x "$OPENCODE" ] && break
  [ -x "$candidate" ] && OPENCODE="$candidate"
done
[ -x "$OPENCODE" ] || { echo "opencode was not found. Install it and re-run the launcher installer." >&2; exit 127; }

HEALTH_URL="http://127.0.0.1:${PORT}/global/health"
if curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1; then
  exit 0
fi
LISTENER="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$LISTENER" ]; then
  echo "Port $PORT is already used by process $LISTENER; refusing to stop it." >&2
  exit 1
fi

# Build CORS flags.
CORS_ARGS=()
for origin in "${CORS_ORIGINS[@]}"; do
  CORS_ARGS+=(--cors "$origin")
done

ARGS=(serve --port "$PORT" "${CORS_ARGS[@]}")

if [ -n "$PASSWORD" ]; then
  export OPENCODE_SERVER_PASSWORD="$PASSWORD"
fi

LOG_FILE="${TMPDIR:-/tmp}/scholia-opencode.log"
nohup "$OPENCODE" "${ARGS[@]}" >"$LOG_FILE" 2>&1 &
disown || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS --max-time 1 "$HEALTH_URL" >/dev/null 2>&1 && exit 0
  sleep 0.5
done

echo "opencode has not become ready. See $LOG_FILE" >&2
exit 1
