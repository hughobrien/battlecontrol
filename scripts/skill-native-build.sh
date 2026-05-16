#!/usr/bin/env bash
# Single-command native Linux build: configure + build RA + build TD.
# Used by: native-build, ci-cd skills.
#
# Usage:
#   bash scripts/skill-native-build.sh              # both targets
#   bash scripts/skill-native-build.sh ra           # RA only
#   bash scripts/skill-native-build.sh td           # TD only
#   CXX=clang++ bash scripts/skill-native-build.sh  # use clang
#
# Exit code: 0 if all builds pass, 1 if any fails.

set -euo pipefail

TARGET="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "=== Configuring native Linux build ==="
if [[ -n "${CXX:-}" ]]; then
    cmake --preset linux-native -DCMAKE_CXX_COMPILER="$CXX"
else
    cmake --preset linux-native
fi

if [[ "$TARGET" == "all" || "$TARGET" == "ra" ]]; then
    echo "=== Building RA ==="
    cmake --build build --target ra --parallel
fi

if [[ "$TARGET" == "all" || "$TARGET" == "td" ]]; then
    echo "=== Building TD ==="
    cmake --build build --target td --parallel
fi

echo "=== Build complete ==="
echo "RA binary: $(find build -name ra -type f 2>/dev/null | head -1 || echo 'not found in build/')"
echo "TD binary: $(find build -name td -type f 2>/dev/null | head -1 || echo 'not found in build/')"
