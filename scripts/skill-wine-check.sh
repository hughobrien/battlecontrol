#!/usr/bin/env bash
# Wine toolchain prerequisite check — one command to verify Wine testing readiness.
# Used by: wine-testing skill Phase 0.
#
# Usage:
#   bash scripts/skill-wine-check.sh
#
# Exit code: 0 = all prerequisites met, 1 = one or more missing.

set -euo pipefail

errors=0

check_cmd() {
    local name="$1"
    local cmd="$2"
    printf "  %-20s " "$name"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
        echo "OK  ($ver)"
    else
        echo "MISSING"
        errors=$((errors + 1))
    fi
}

echo "=== Wine prerequisite check ==="
echo ""

check_cmd "wine" wine

# Check wine32 support
if command -v wine >/dev/null 2>&1; then
    printf "  %-20s " "wine32"
    if wine --version 2>&1 | grep -q "wine32 is missing"; then
        echo "MISSING (run: sudo apt-get install wine32:i386)"
        errors=$((errors + 1))
    else
        echo "OK"
    fi
fi

check_cmd "xvfb-run" xvfb-run
check_cmd "xdotool"   xdotool
check_cmd "ffmpeg"    ffmpeg
check_cmd "import"    import

echo ""
if [[ $errors -eq 0 ]]; then
    echo "All prerequisites met."
else
    echo "$errors prerequisite(s) missing."
fi

exit $errors
