#!/usr/bin/env bash
# RA WASM regression — T1, T11 (ci); +T3-ra, T4, T5, T8, T9, T10 (full)
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIER="${REGRESSION_TIER:-ci}"
cd "$REPO_ROOT" || exit 1

require_file() { [ -f "$1" ] || {
	echo "[ra-wasm] missing $1"
	return 1
}; }
require_file build-wasm/ra.html || exit 1

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

if [ "$TIER" = "full" ] && [ -d "${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}" ]; then
	python3 wasm/serve-assets.py "$RA_ASSETS" 9090 &
	PIDS+=($!)
fi

sleep 3

FAIL=0
run() {
	local spec="$1"
	echo "---- $spec ----"
	playwright test "$spec" --reporter=list || FAIL=$((FAIL + 1))
}

run e2e/regression/T1-ra-wasm-boot.spec.ts
run e2e/regression/T11-ra-wasm-m2-boot.spec.ts

if [ "$TIER" = "full" ]; then
	run e2e/regression/T3-ra-wasm-menu.spec.ts
	run e2e/regression/T4-ra-wasm-vqa.spec.ts
	run e2e/regression/T5-ra-wasm-menu-click.spec.ts
	run e2e/regression/T8-ra-audio-pitch.spec.ts
	run e2e/regression/T9-ra-wasm-mission-start.spec.ts
	run e2e/regression/T10-ra-wasm-post-game-menu.spec.ts
	run e2e/regression/T10-ra-menu-bleed.spec.ts
fi

echo "==== RA WASM regression: $FAIL failures ===="
exit "$FAIL"
