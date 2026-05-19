#!/usr/bin/env bash
# Lint — all static analysis and format checks.
# Usage: bash scripts/lint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0

echo "=== LP64 hazard audit ==="
python3 scripts/lint-lp64.py --errors-only || FAIL=1

echo ""
echo "=== Python (ruff check + format) ==="
ruff check scripts/ e2e/ wasm/ 2>&1 || FAIL=1
ruff format --check --diff scripts/ e2e/ wasm/ 2>&1 || FAIL=1

echo ""
echo "=== YAML (yamllint) ==="
yamllint .github/workflows/ 2>&1 || FAIL=1

echo ""
echo "=== Shell (shellcheck + shfmt) ==="
find scripts/ -name '*.sh' -exec shellcheck {} + 2>&1 || FAIL=1
find scripts/ -name '*.sh' -exec shfmt -d {} + 2>&1 || FAIL=1

echo ""
echo "=== Nix (nixfmt) ==="
find . -name '*.nix' -not -path './build/*' -exec nixfmt --check {} + 2>&1 || FAIL=1

echo ""
echo "=== /opt path audit ==="
HITS=$(rg -n '/opt/(redalert|tiberiandawn)' scripts/ | grep -v 'lint.sh' || true)
if [[ -n "$HITS" ]]; then
	echo "FAIL: scripts/ still contains /opt/redalert or /opt/tiberiandawn"
	echo "$HITS"
	FAIL=1
else
	echo "  OK: no /opt paths in scripts/"
fi

if [ "$FAIL" -ne 0 ]; then
	echo ""
	echo "✗ Lint failed"
	exit 1
fi
echo ""
echo "✓ Lint passed"
