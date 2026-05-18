# shellcheck shell=bash
# _gating.sh — diff-gating helper.
# Source this script to determine which targets are affected by current changes.
#
# Usage: source scripts/_gating.sh [--all] [--base REF]
#
# Sets these variables (true/false):
#   GATE_RA_NATIVE  GATE_TD_NATIVE  GATE_RA_WASM  GATE_TD_WASM
#
# Default base: origin/master. Falls back to HEAD~1.

# shellcheck disable=SC2034
GATE_RA_NATIVE=false
# shellcheck disable=SC2034
GATE_TD_NATIVE=false
# shellcheck disable=SC2034
GATE_RA_WASM=false
# shellcheck disable=SC2034
GATE_TD_WASM=false

_parse_gating_args() {
	local base="origin/master"

	while [ $# -gt 0 ]; do
		case "$1" in
		--all)
			GATE_RA_NATIVE=true
			GATE_TD_NATIVE=true
			GATE_RA_WASM=true
			GATE_TD_WASM=true
			return
			;;
		--base)
			shift
			base="${1:-origin/master}"
			;;
		esac
		shift
	done

	if ! git rev-parse --verify "$base" &>/dev/null; then
		base="HEAD~1"
	fi

	local changed
	changed=$(git diff --name-only "$base" 2>/dev/null || true)

	if [ -z "$changed" ]; then
		# No changes — default to all (safe)
		GATE_RA_NATIVE=true
		GATE_TD_NATIVE=true
		GATE_RA_WASM=true
		GATE_TD_WASM=true
		return
	fi

	if echo "$changed" | grep -qE '^(REDALERT/|linux/win32-stubs/|CMakeLists\.txt|CMakePresets\.json)'; then
		GATE_RA_NATIVE=true
		GATE_RA_WASM=true
	fi
	if echo "$changed" | grep -qE '^(TIBERIANDAWN/|linux/win32-stubs/|CMakeLists\.txt|CMakePresets\.json)'; then
		GATE_TD_NATIVE=true
		GATE_TD_WASM=true
	fi
	if echo "$changed" | grep -qE '^wasm/'; then
		GATE_RA_WASM=true
		GATE_TD_WASM=true
	fi

	# If nothing matched C++ paths, leave all false (lint-only change)
}

_parse_gating_args "$@"
