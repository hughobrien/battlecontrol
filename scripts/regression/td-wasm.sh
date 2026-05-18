#!/usr/bin/env bash
# TD WASM regression — T2, T12 (ci); +T3-td, T6, T7 (full)
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${REGRESSION_TIER:-ci}"
cd "$REPO_ROOT" || exit 1

require_file() { [ -f "$1" ] || {
	echo "[td-wasm] missing $1"
	return 1
}; }
require_file build-wasm/td.html || exit 1

PIDS=()
# shellcheck disable=SC2329 # used via trap
cleanup() { for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

python3 wasm/serve-coop.py 8080 &
PIDS+=($!)
if ! pgrep -f "Xvfb :99" >/dev/null; then
	Xvfb :99 -screen 0 1280x1024x24 -ac &
	PIDS+=($!)
fi

if [ "$TIER" = "full" ] && [ -d "${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}" ]; then
	python3 wasm/serve-assets.py "$TD_ASSETS" 9091 &
	PIDS+=($!)
fi

sleep 3

FAIL=0
run() {
	local spec="$1"
	echo "---- $spec ----"
	playwright test "$spec" --reporter=list || FAIL=$((FAIL + 1))
}

run e2e/regression/T2-td-wasm-boot.spec.ts
run e2e/regression/T12-td-wasm-m2-boot.spec.ts

if [ "$TIER" = "full" ]; then
	run e2e/regression/T3-td-wasm-menu.spec.ts
	run e2e/regression/T6-td-wasm-mission-start.spec.ts
	run e2e/regression/T7-td-audio-pitch.spec.ts
fi

echo "==== TD WASM regression: $FAIL failures ===="
exit "$FAIL"
