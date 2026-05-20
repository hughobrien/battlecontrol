#!/usr/bin/env bash
# Single-command native Linux build: configure + build RA + build TD.
# Used by: native-build, ci-cd skills.
#
# Usage:
#   bash scripts/build-native.sh              # both targets
#   bash scripts/build-native.sh ra           # RA only
#   bash scripts/build-native.sh td           # TD only
#
# Compiler is pinned to clang via CMakePresets.json (linux-native preset).
# Exit code: 0 if all builds pass, 1 if any fails.

set -euo pipefail

TARGET="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "=== Configuring native Linux build ==="
cmake --preset linux-native

if [[ "$TARGET" == "all" || "$TARGET" == "ra" ]]; then
	echo "=== Building RA ==="
	cmake --build build --target ra --parallel
fi

if [[ "$TARGET" == "all" || "$TARGET" == "td" ]]; then
	echo "=== Building TD ==="
	cmake --build build --target td --parallel
fi

# Validate ELF 64-bit for all built targets
echo ""
echo "=== Validating binaries ==="
for bin in ra td; do
	if [[ -f "build/$bin" ]]; then
		if file "build/$bin" 2>/dev/null | grep -q "ELF 64-bit"; then
			echo "$bin: $(stat -c%s "build/$bin") bytes, ELF 64-bit ✓"
		else
			echo "ERROR: $bin: not ELF 64-bit" >&2
			exit 1
		fi
	fi
done
echo "=== Build complete ==="
