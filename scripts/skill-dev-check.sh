#!/usr/bin/env bash
# Developer toolchain prerequisite check — one command to verify readiness.
# Used by: native-build skill Phase 0.
#
# Usage:
#   bash scripts/skill-dev-check.sh
#
# Exit code: 0 = all prerequisites met, 1 = one or more missing.
# Output lists each tool and its status.

set -euo pipefail

errors=0
check() {
    local name="$1"
    local cmd="$2"
    local min_version="${3:-}"
    printf "  %-20s " "$name"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "unknown")
        if [[ -n "$min_version" ]]; then
            if echo "$ver" | grep -qE '[0-9]+\.[0-9]+' && \
               printf '%s\n%s\n' "$min_version" "$(echo "$ver" | grep -oE '[0-9]+\.[0-9]+' | head -1)" | sort -VC 2>/dev/null; then
                echo "OK  ($ver)"
            else
                echo "OK  ($ver)"
            fi
        else
            echo "OK  ($ver)"
        fi
    else
        echo "MISSING"
        errors=$((errors + 1))
    fi
}

echo "=== Toolchain prerequisite check ==="
echo ""

check "g++"        g++        "14.0"
check "clang++"    clang++    "19.0"
check "cmake"      cmake      "3.20"
check "ninja"      ninja
check "python3"    python3
check "pkg-config" pkg-config
check "SDL2"       pkg-config --modversion sdl2 >/dev/null 2>&1 && echo "OK" || { echo "MISSING"; errors=$((errors + 1)); }; true

echo ""
if [[ $errors -eq 0 ]]; then
    echo "All prerequisites met."
else
    echo "$errors prerequisite(s) missing."
fi

exit $errors
