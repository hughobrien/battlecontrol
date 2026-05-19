#!/usr/bin/env bash
# test-runner.sh — single backend for all {game}-{platform}-test apps.
#
# Usage: bash scripts/test-runner.sh <game> <platform> [--full]
#
#   game:     ra | td
#   platform: native | wasm
#   --full:   run full regression tier (default: CI tier = boot tests only)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GAME="${1:-}"
PLATFORM="${2:-}"
shift 2 || true
FULL=false
for arg in "$@"; do
	case "$arg" in --full) FULL=true ;; esac
done

if [ -z "$GAME" ] || [ -z "$PLATFORM" ]; then
	echo "Usage: test-runner.sh <ra|td> <native|wasm> [--full]" >&2
	exit 1
fi

# ── WASM helpers ──────────────────────────────────────────────────────────

require_file() { [ -f "$1" ] || {
	echo "[test-runner] missing $1" >&2
	return 1
}; }

start_servers() {
	PIDS=()
	python3 wasm/serve-coop.py 8080 &
	PIDS+=($!)
	if ! pgrep -f "Xvfb :99" >/dev/null; then
		Xvfb :99 -screen 0 1280x1024x24 -ac &
		PIDS+=($!)
	fi
	if [ "$FULL" = true ] && [ "$GAME" = "ra" ] && [ -d "${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}" ]; then
		python3 wasm/serve-assets.py "$RA_ASSETS" 9090 &
		PIDS+=($!)
	fi
	if [ "$FULL" = true ] && [ "$GAME" = "td" ] && [ -d "${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}" ]; then
		python3 wasm/serve-assets.py "$TD_ASSETS" 9091 &
		PIDS+=($!)
	fi
	sleep 3
}

# shellcheck disable=SC2317,SC2329
cleanup_servers() {
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
}

run_playwright() {
	local spec="$1"
	echo "---- $spec ----"
	playwright test "$spec" --reporter=list || FAIL=$((FAIL + 1))
}

# ── Native helpers ────────────────────────────────────────────────────────

run_script() {
	local script="$1"
	echo "---- $script ----"
	bash "$script" || {
		rc=$?
		[ "$rc" -eq 77 ] || FAIL=$((FAIL + 1))
	}
}

# ── Dispatch ──────────────────────────────────────────────────────────────

FAIL=0

case "$GAME-$PLATFORM" in
ra-wasm)
	require_file build-wasm/ra.html || exit 1
	trap cleanup_servers EXIT
	start_servers
	run_playwright e2e/regression/T1-ra-wasm-boot.spec.ts
	run_playwright e2e/regression/T11-ra-wasm-m2-boot.spec.ts
	if [ "$FULL" = true ]; then
		run_playwright e2e/regression/T3-ra-wasm-menu.spec.ts
		run_playwright e2e/regression/T4-ra-wasm-vqa.spec.ts
		run_playwright e2e/regression/T5-ra-wasm-menu-click.spec.ts
		run_playwright e2e/regression/T8-ra-audio-pitch.spec.ts
		run_playwright e2e/regression/T9-ra-wasm-mission-start.spec.ts
		run_playwright e2e/regression/T10-ra-wasm-post-game-menu.spec.ts
		run_playwright e2e/regression/T10-ra-menu-bleed.spec.ts
	fi
	;;
td-wasm)
	require_file build-wasm/td.html || exit 1
	trap cleanup_servers EXIT
	start_servers
	run_playwright e2e/regression/T2-td-wasm-boot.spec.ts
	run_playwright e2e/regression/T12-td-wasm-m2-boot.spec.ts
	if [ "$FULL" = true ]; then
		run_playwright e2e/regression/T3-td-wasm-menu.spec.ts
		run_playwright e2e/regression/T6-td-wasm-mission-start.spec.ts
		run_playwright e2e/regression/T7-td-audio-pitch.spec.ts
	fi
	;;
ra-native)
	run_script scripts/first-run-pass-94.sh
	if [ "$FULL" = true ]; then
		run_script scripts/regression/T6-ra-native-smoke.sh
		run_script scripts/regression/T11-ra-native-m2-smoke.sh
	fi
	;;
td-native)
	run_script scripts/run-td-cheat.sh
	if [ "$FULL" = true ]; then
		run_script scripts/regression/T5-td-native-menu.sh
		run_script scripts/regression/T12-td-native-m2-smoke.sh
	fi
	;;
*)
	echo "Unknown game/platform: $GAME-$PLATFORM" >&2
	exit 1
	;;
esac

echo "==== $GAME $PLATFORM: $FAIL failures ===="
exit "$FAIL"
