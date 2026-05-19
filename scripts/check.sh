#!/usr/bin/env bash
# Check — heavyweight static analysis (clang-tidy + cppcheck).
# Run on-demand (not in pre-commit hook).
# Usage: bash scripts/check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== clang-tidy ==="
cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
find REDALERT TIBERIANDAWN -type f \
	\! -path '*/WIN32LIB/*' \
	\( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
	-print0 | xargs -0 -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 |
	tee /tmp/clang-tidy-report.txt || true
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
echo "✓ Check complete"
