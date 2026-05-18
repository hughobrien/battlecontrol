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
echo "=== clang-tidy ==="
cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
find REDALERT TIBERIANDAWN -type f \
  \! -path '*/WIN32LIB/*' \
  \( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
  -print0 | xargs -0 -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 \
  | tee /tmp/clang-tidy-report.txt
echo "$(grep -c 'warning:\|error:' /tmp/clang-tidy-report.txt 2>/dev/null || echo 0) clang-tidy finding(s)"

echo ""
echo "=== cppcheck ==="
cppcheck --enable=warning,performance,portability,information \
  --suppress=missingIncludeSystem \
  --suppress=unmatchedSuppression \
  --inline-suppr --error-exitcode=0 \
  -j "$(nproc)" --quiet \
  -I REDALERT -I REDALERT/WIN32LIB \
  -I TIBERIANDAWN -I TIBERIANDAWN/WIN32LIB \
  -I linux/win32-stubs \
  REDALERT TIBERIANDAWN 2>&1 | tee /tmp/cppcheck-report.txt
echo "$(grep -c 'error:\|warning:' /tmp/cppcheck-report.txt 2>/dev/null || echo 0) cppcheck finding(s)"

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
