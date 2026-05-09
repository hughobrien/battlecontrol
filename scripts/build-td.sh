#!/usr/bin/env bash
# TIM-337 pass-96: build the `td` CMake target.
# Equivalent to `just build-td` when there is no justfile.
#
# Usage: bash scripts/build-td.sh
# Exits 0 on link success, non-zero if configure/compile fails.
# Compile errors in TIBERIANDAWN/ are expected during early passes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/cmake-td"

mkdir -p "$BUILD_DIR"

echo "=== CMake configure ==="
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Debug 2>&1

echo ""
echo "=== Building target: td ==="
cmake --build "$BUILD_DIR" --target td -- -j"$(nproc)" 2>&1
