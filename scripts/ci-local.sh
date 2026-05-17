#!/usr/bin/env bash
# Local CI — run the full CI pipeline locally, skipping unavailable gates.
# Used by: agents wanting a single-command verification before pushing.
#
# Usage:
#   bash scripts/ci-local.sh                # all available gates
#   bash scripts/ci-local.sh --wasm-only    # WASM build + smoke only
#   bash scripts/ci-local.sh --native-only  # native build + lint only
#
# Exit code: 0 = all available gates pass, 1 = one or more failed.
#
# Gates (auto-skip if deps missing):
#   G1: Native build (ra + td)           requires: clang++, cmake, ninja, SDL2
#   G2: LP64 audit                       requires: python3
#   G3: WASM build + validate            requires: emcmake
#   G4: WASM smoke (T1+T2)              requires: emcmake, node, chromium, Xvfb
#   G5: VQA pixel-diff (synthetic)       requires: python3, ffmpeg
#   G6: Include shim check               requires: python3

# Auto-wrap in nix develop if not already inside it.
# shell scripts are read fresh every time, so this works even if the
# pi extension TypeScript hasn't been reloaded.
if [[ -z "${IN_NIX_SHELL:-}" ]] && command -v nix &>/dev/null; then
	exec nix develop --command bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-all}"
FAILED_GATES=()
SKIPPED_GATES=()
PASSED_GATES=()

# — helpers —
gate_pass() {
	PASSED_GATES+=("$1")
	echo "  PASS: $1"
}
gate_skip() {
	SKIPPED_GATES+=("$1 ($2)")
	echo "  SKIP: $1 — $2"
}
gate_fail() {
	FAILED_GATES+=("$1")
	echo "  FAIL: $1"
}

have() { command -v "$1" &>/dev/null; }

# — check what's available —
check_native() { have clang++ && have cmake && have ninja && have pkg-config && pkg-config --exists sdl2 2>/dev/null; }
check_wasm() { have emcmake; }

check_ffmpeg() { have ffmpeg; }
check_python() { have python3; }

echo "=== CI-Local ==="
echo ""

# ======================================================================
# G1: Native build
# ======================================================================
if [[ "$MODE" != "--wasm-only" ]] && check_native; then
	echo "--- G1: Native build (ra + td) ---"
	if bash scripts/skill-native-build.sh; then
		gate_pass "G1: native build"
	else
		gate_fail "G1: native build"
	fi
elif [[ "$MODE" == "--wasm-only" ]]; then
	gate_skip "G1: native build" "wasm-only mode"
else
	gate_skip "G1: native build" "missing toolchain (clang++/cmake/ninja/SDL2)"
fi

# ======================================================================
# G2: LP64 audit
# ======================================================================
if [[ "$MODE" != "--wasm-only" ]] && check_python; then
	echo ""
	echo "--- G2: LP64 audit ---"
	if python3 scripts/lint-lp64.py --errors-only; then
		gate_pass "G2: LP64 audit"
	else
		gate_fail "G2: LP64 audit"
	fi
elif [[ "$MODE" == "--wasm-only" ]]; then
	gate_skip "G2: LP64 audit" "wasm-only mode"
else
	gate_skip "G2: LP64 audit" "python3 not found"
fi

# ======================================================================
# G3: WASM build + validate
# ======================================================================
if [[ "$MODE" != "--native-only" ]] && check_wasm; then
	echo ""
	echo "--- G3: WASM build ---"
	if bash scripts/skill-ci-wasm-smoke.sh; then
		gate_pass "G3: WASM build + validate + smoke"
	else
		gate_fail "G3: WASM build + smoke"
	fi
elif [[ "$MODE" == "--native-only" ]]; then
	gate_skip "G3: WASM build" "native-only mode"
else
	gate_skip "G3: WASM build" "emcmake not found (install Emscripten)"
fi

# ======================================================================
# G5: VQA pixel-diff (synthetic, no game data needed)
# ======================================================================
if check_python && check_ffmpeg; then
	echo ""
	echo "--- G5: VQA pixel-diff (synthetic) ---"
	if [[ -f e2e/goldens/vqa/test.vqa ]]; then
		if python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2 --threshold 5; then
			gate_pass "G5: VQA pixel-diff"
		else
			gate_fail "G5: VQA pixel-diff"
		fi
	else
		gate_skip "G5: VQA pixel-diff" "test.vqa not found (run gen_test_vqa.py)"
	fi
elif ! check_ffmpeg; then
	gate_skip "G5: VQA pixel-diff" "ffmpeg not installed"
fi

# ======================================================================
# Summary
# ======================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: ${#PASSED_GATES[@]}"
echo "  SKIP: ${#SKIPPED_GATES[@]}"
echo "  FAIL: ${#FAILED_GATES[@]}"
echo ""

if [[ ${#FAILED_GATES[@]} -gt 0 ]]; then
	echo "Failed gates:"
	for g in "${FAILED_GATES[@]}"; do echo "  - $g"; done
	echo ""
	exit 1
fi

echo "All available gates passed."
exit 0
