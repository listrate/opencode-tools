#!/bin/sh
# opencode-tools entrypoint: runs `opencode serve` (HTTP API) AND exposes
# `opencode acp` (Agent Client Protocol) over TCP simultaneously.
#
# `opencode acp` is a stdio-only process (ACP spec has no TCP transport), so
# socat bridges each TCP connection to a fresh `opencode acp` child. Clients
# (e.g. the Matrix chat-bridge) connect to the ACP port and speak newline-
# delimited JSON-RPC, exactly as if they had spawned the process themselves —
# but they get THIS image's tooling (kubectl, kubelogin, MCP servers, ...).
#
# Backwards compatible: if invoked with an opencode subcommand (e.g.
# `serve --hostname 0.0.0.0`), it execs that single process instead.
#
# Ports are configurable via env (defaults: OPENCODE_SERVE_PORT=8080,
# OPENCODE_ACP_PORT=19099).

set -eu

# If a subcommand was passed, behave like the upstream ENTRYPOINT (["opencode"]).
if [ $# -gt 0 ]; then
  exec opencode "$@"
fi

SERVE_PORT="${OPENCODE_SERVE_PORT:-8080}"
ACP_PORT="${OPENCODE_ACP_PORT:-19099}"
SERVE_HOST="${OPENCODE_SERVE_HOST:-0.0.0.0}"
ACP_HOST="${OPENCODE_ACP_HOST:-0.0.0.0}"

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
  echo "Warning: OPENCODE_SERVER_PASSWORD is not set; opencode serve is unsecured." >&2
fi

# 1) headless HTTP server (UI + session API)
opencode serve --hostname "$SERVE_HOST" --port "$SERVE_PORT" &
SERVE_PID=$!

# 2) ACP over TCP: each inbound connection forks a dedicated `opencode acp`.
#    stderr stays on the container log (socat forks inherit our stderr); the
#    ACP JSON-RPC flows cleanly over stdout/stdin through the socket.
socat "TCP-LISTEN:${ACP_PORT},reuseaddr,fork" \
  EXEC:"opencode acp --hostname 127.0.0.1" &
ACP_PID=$!

echo "entrypoint: opencode serve on ${SERVE_HOST}:${SERVE_PORT} (pid ${SERVE_PID}), ACP listener on ${ACP_HOST}:${ACP_PORT} (pid ${ACP_PID})" >&2

# Forward signals to both children.
trap 'kill "$SERVE_PID" "$ACP_PID" 2>/dev/null || true' INT TERM

# Exit as soon as EITHER child dies, so k8s restarts the container.
while :; do
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "entrypoint: opencode serve exited (pid ${SERVE_PID})" >&2
    kill "$ACP_PID" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$ACP_PID" 2>/dev/null; then
    echo "entrypoint: ACP listener exited (pid ${ACP_PID})" >&2
    kill "$SERVE_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 2
done
