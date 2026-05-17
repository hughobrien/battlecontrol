#!/usr/bin/env bash
# TIM-623 — regression suite runner.
#
# Runs the regression test-points defined in e2e/regression/README.md.
# Tiers:
#   REGRESSION_TIER=ci    — T1 + T2 only (asset-free, hermetic, CI default).
#   REGRESSION_TIER=full  — all tests (T3+ need licensed CnC Remastered MIX
#                          files in /CnCRemastered/Data/CNCDATA/{RED_ALERT,
#                          TIBERIAN_DAWN}/CD1).
#
# Default tier: ci. Override with `REGRESSION_TIER=full bash scripts/regression-suite.sh`.
#
# Servers managed by this script (started + torn down):
#   serve-coop.py    on :8080  — build-wasm/ (T1–T4)
#   serve-assets.py  on :9090  — RA CD1/    (T3-ra, T4, T5)
#   serve-assets.py  on :9091  — TD CD1/    (T3-td)  TIM-696
#
# Hard timeout per Playwright test: enforced by `test.setTimeout(60_000)`.
# Hard timeout per shell test: enforced by `timeout` inside each script.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${REGRESSION_TIER:-ci}"
RA_ASSETS="${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
TD_ASSETS="${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"

cd "$REPO_ROOT" || exit 1

PIDS=()
# shellcheck disable=SC2329 # used via trap
cleanup() {
	for p in "${PIDS[@]}"; do
		kill -9 "$p" 2>/dev/null || true
	done
}
trap cleanup EXIT

start_server() {
	local label="$1" cmd="$2"
	echo "[regression] starting $label …"
	bash -c "$cmd" &
	PIDS+=($!)
}

require_file() {
	[ -f "$1" ] || {
		echo "[regression] missing $1"
		return 1
	}
}

# ── Prep ─────────────────────────────────────────────────────────────────────
require_file build-wasm/ra.html || {
	echo "[regression] FAIL: build-wasm/ra.html missing. Run: emcmake cmake --preset wasm && cmake --build build-wasm --target ra"
	exit 1
}
require_file build-wasm/td.html || {
	echo "[regression] FAIL: build-wasm/td.html missing. Run: cmake --build build-wasm --target td"
	exit 1
}

start_server "serve-coop.py :8080" "python3 wasm/serve-coop.py 8080"

# Xvfb for Playwright (its config sets DISPLAY=:99).
if ! pgrep -f "Xvfb :99" >/dev/null; then
	Xvfb :99 -screen 0 1280x1024x24 -ac &
	PIDS+=($!)
fi

if [ "$TIER" = "full" ]; then
	if [ -d "$RA_ASSETS" ]; then
		start_server "serve-assets.py :9090" "python3 wasm/serve-assets.py '$RA_ASSETS' 9090"
	else
		echo "[regression] WARN: RA assets dir $RA_ASSETS missing — T3-ra, T4, T5 will fail to load assets"
	fi
	# TIM-696: TD asset server for T3-td-wasm-menu
	if [ -d "$TD_ASSETS" ]; then
		start_server "serve-assets.py :9091" "python3 wasm/serve-assets.py '$TD_ASSETS' 9091"
	else
		echo "[regression] WARN: TD assets dir $TD_ASSETS missing — T3-td will fail to load assets"
	fi
fi

sleep 3 # let servers bind their ports

# ── CI tier: T1 + T2 ────────────────────────────────────────────────────────
echo ""
echo "==== Tier: $TIER ===="
FAIL=0

run_playwright() {
	local spec="$1"
	echo ""
	echo "---- $spec ----"
	if ! playwright test "$spec" --reporter=list; then
		FAIL=$((FAIL + 1))
	fi
}

run_shell() {
	local script="$1"
	echo ""
	echo "---- $script ----"
	if bash "$script"; then
		:
	else
		rc=$?
		if [ "$rc" -eq 77 ]; then
			echo "[regression] $script SKIPPED (rc=77)"
		else
			FAIL=$((FAIL + 1))
		fi
	fi
}

run_playwright e2e/regression/T1-ra-wasm-boot.spec.ts
run_playwright e2e/regression/T2-td-wasm-boot.spec.ts
run_playwright e2e/regression/T11-ra-wasm-m2-boot.spec.ts
run_playwright e2e/regression/T12-td-wasm-m2-boot.spec.ts

if [ "$TIER" = "full" ]; then
	run_playwright e2e/regression/T3-ra-wasm-menu.spec.ts
	run_playwright e2e/regression/T3-td-wasm-menu.spec.ts # TIM-696
	run_playwright e2e/regression/T4-ra-wasm-vqa.spec.ts
	run_playwright e2e/regression/T5-ra-wasm-menu-click.spec.ts
	run_shell scripts/regression/T5-td-native-menu.sh
	run_shell scripts/regression/T6-ra-native-smoke.sh
	run_shell scripts/regression/T11-ra-native-m2-smoke.sh
	run_shell scripts/regression/T12-td-native-m2-smoke.sh
fi

echo ""
echo "==== Regression suite finished: $FAIL failures ===="
exit "$FAIL"
