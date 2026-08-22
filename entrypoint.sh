#!/bin/sh
# opencode-tools entrypoint: runs `opencode serve` (HTTP API).
#
# If invoked with an opencode subcommand (e.g. `serve --hostname 0.0.0.0`),
# it execs that single process instead.
#
# The serve port is configurable via OPENCODE_SERVE_PORT (default: 8080).

set -eu

# If a subcommand was passed, behave like the upstream ENTRYPOINT (["opencode"]).
if [ $# -gt 0 ]; then
  exec opencode "$@"
fi

SERVE_PORT="${OPENCODE_SERVE_PORT:-8080}"
SERVE_HOST="${OPENCODE_SERVE_HOST:-0.0.0.0}"

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
  echo "Warning: OPENCODE_SERVER_PASSWORD is not set; opencode serve is unsecured." >&2
fi

# Headless HTTP server (UI + session API)
opencode serve --hostname "$SERVE_HOST" --port "$SERVE_PORT" &
SERVE_PID=$!

echo "entrypoint: opencode serve on ${SERVE_HOST}:${SERVE_PORT} (pid ${SERVE_PID})" >&2

# Forward signals to the child.
trap 'kill "$SERVE_PID" 2>/dev/null || true' INT TERM

# Exit as soon as EITHER child dies, so k8s restarts the container.
while :; do
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "entrypoint: opencode serve exited (pid ${SERVE_PID})" >&2
    exit 1
  fi
  sleep 2
done
