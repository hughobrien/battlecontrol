#!/usr/bin/env bash
# Full E2E test runner: starts Xvfb + WASM server, runs Playwright test, cleans up.
# Used by: e2e-testing, ci-cd skills.
#
# Usage:
#   bash scripts/skill-run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
#   bash scripts/skill-run-e2e.sh e2e/tim710-wasm-parity.spec.ts --grep "Tier 1"
#   bash scripts/skill-run-e2e.sh e2e/regression/T2-td-wasm-boot.spec.ts
#
# All arguments after the spec file are forwarded to playwright test.
#
# Exit code: Playwright exit code (0 = all pass).

set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <playwright-test-file> [additional args...]" >&2
	echo "Example: $0 e2e/regression/T1-ra-wasm-boot.spec.ts" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Start Xvfb
# shellcheck disable=SC1091
source "$SCRIPT_DIR/skill-xvfb-ensure.sh" :99 1280x1024x24

# Start WASM server
# shellcheck disable=SC1091
source "$SCRIPT_DIR/skill-wasm-serve.sh" 8080

# Run Playwright test
echo "[e2e] Running: playwright test $*"
DISPLAY="$XVFB_DISPLAY" playwright test "$@"
PW_EXIT=$?

# Xvfb and server are killed by EXIT traps set in the sourced scripts

exit $PW_EXIT
