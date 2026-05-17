#!/usr/bin/env bash
# Start the WASM dev server with COOP/COEP headers and register auto-cleanup.
# Used by: e2e-testing, ci-cd, parity-comparison skills.
#
# Usage:
#   source scripts/skill-wasm-serve.sh           # serve-coop.py on :8080
#   source scripts/skill-wasm-serve.sh 8081      # custom port
#
# After sourcing, WASM_SERVER_PID and WASM_SERVER_PORT are exported.
# The script sets an EXIT trap to kill the server automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WASM_SERVER_PORT="${1:-8080}"
WASM_SERVER_PID=""

# Kill any existing server on this port
if command -v ss >/dev/null 2>&1; then
    _old_pid=$(ss -tlnp "sport = :${WASM_SERVER_PORT}" 2>/dev/null | grep -oP 'pid=\K\d+' | head -1 || true)
elif command -v lsof >/dev/null 2>&1; then
    _old_pid=$(lsof -ti ":${WASM_SERVER_PORT}" 2>/dev/null || true)
else
    _old_pid=""
fi
if [[ -n "$_old_pid" ]]; then
    echo "[serve] Killing old server on :${WASM_SERVER_PORT} (pid=$_old_pid)"
    kill "$_old_pid" 2>/dev/null || true
    sleep 0.5
fi

echo "[serve] Starting serve-coop.py on :${WASM_SERVER_PORT}..."
python3 "$REPO_ROOT/wasm/serve-coop.py" &
WASM_SERVER_PID=$!

# Wait for server to be ready
for _ in $(seq 1 10); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${WASM_SERVER_PORT}/" 2>/dev/null | grep -q '200\|304'; then
        echo "[serve] Ready (pid=$WASM_SERVER_PID)"
        break
    fi
    sleep 0.3
done

# Register cleanup trap
_old_trap=$(trap -p EXIT 2>/dev/null | sed "s/trap -- '//;s/' EXIT//" || true)
if [[ -n "$_old_trap" ]]; then
    # shellcheck disable=SC2064
    trap "$_old_trap; kill \$WASM_SERVER_PID 2>/dev/null || true" EXIT
else
    trap 'kill "$WASM_SERVER_PID" 2>/dev/null || true' EXIT
fi

export WASM_SERVER_PID WASM_SERVER_PORT
