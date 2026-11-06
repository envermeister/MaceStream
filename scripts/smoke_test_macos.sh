#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_PATH=${1:-"$ROOT_DIR/.build/DerivedData/Build/Products/Release/MaceStream.app"}
EXECUTABLE="$APP_PATH/Contents/MacOS/MaceStream"
CACHE_DIR="$ROOT_DIR/.cache"
LOG_PATH="$CACHE_DIR/macos-smoke.log"

if [ ! -x "$EXECUTABLE" ]; then
  printf 'Build the app first: %s\n' "$EXECUTABLE" >&2
  exit 1
fi
if pgrep -x MaceStream >/dev/null 2>&1; then
  printf 'To avoid interfering with a running MaceStream session, quit the app first.\n' >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
"$EXECUTABLE" >"$LOG_PATH" 2>&1 &
APP_PID=$!
cleanup() {
  CHILDREN=$(pgrep -P "$APP_PID" 2>/dev/null || true)
  if [ -n "$CHILDREN" ]; then
    kill $CHILDREN 2>/dev/null || true
  fi
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  rm -f "${TMPDIR:-/tmp}/macestream-$(id -u)-$APP_PID.sock" 2>/dev/null || true
}
trap cleanup EXIT

for attempt in {1..90}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    printf 'The app exited. Log: %s\n' "$LOG_PATH" >&2
    exit 1
  fi
  PORT=$(lsof -nP -a -p "$APP_PID" -iTCP -sTCP:LISTEN 2>/dev/null | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' | head -1 || true)
  if [ -n "$PORT" ]; then
    RESPONSE=$(curl -fsS --max-time 1 "http://127.0.0.1:$PORT/webui/api/service?method=get_version" 2>/dev/null || true)
    if printf '%s' "$RESPONSE" | grep -q '"version"'; then
      printf 'AceStream engine API verified (127.0.0.1:%s): %s\n' "$PORT" "$RESPONSE"
      exit 0
    fi
  fi
  sleep 1
done
printf 'The engine was not ready within 90 seconds. Log: %s\n' "$LOG_PATH" >&2
exit 1
