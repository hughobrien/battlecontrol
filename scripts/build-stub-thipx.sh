#!/usr/bin/env bash
# Build the stub THIPX32.DLL for Wine 11.0 wow64 compatibility.
#
# The original THIPX32.DLL uses 16-bit thunking to load THIPX16.DLL
# (a 16-bit NE format DLL). Wine 11.0 (wow64) does NOT support this
# thunking, causing RA95.EXE / C&C95.EXE to abort at startup.
#
# This stub provides the same exports as the original but returns
# sensible defaults without loading THIPX16.DLL.
#
# Usage:
#   bash scripts/build-stub-thipx.sh                # build
#   bash scripts/build-stub-thipx.sh <exe-path>     # build + check THIPX32 import in exe
#   bash scripts/build-stub-thipx.sh --help         # show usage

set -euo pipefail

STUB_DIR="$(cd "$(dirname "$0")/../tools/stub-thipx" && pwd)"
OUT="$STUB_DIR/thipx32.dll"

echo "=== Building stub THIPX32.DLL ==="

if ! command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
	echo "FAIL: i686-w64-mingw32-gcc not found."
	echo "  Run from nix develop shell."
	exit 1
fi

i686-w64-mingw32-gcc -shared -Os -s -o "$OUT" \
	"$STUB_DIR/stub.c" "$STUB_DIR/thipx32.def" -Wl,--kill-at

echo "  Built: $OUT ($(stat -c%s "$OUT") bytes)"

echo ""
echo "=== Export verification ==="
i686-w64-mingw32-objdump -p "$OUT" | grep -A 30 "Ordinal/Name" | head -25

echo ""
# Optional: check an existing RA95.EXE for THIPX32 import (pass path as arg)
if [[ -n "${1:-}" ]] && [[ -f "$1" ]]; then
	echo "=== RA95.EXE import check: $1 ==="
	i686-w64-mingw32-objdump -p "$1" 2>/dev/null | grep -A 20 "thipx32" || echo "  No THIPX32 import found"
elif [[ "${1:-}" == "--help" ]]; then
	echo "Usage: $0 [exe-path]"
	echo "  Builds stub THIPX32.DLL to tools/stub-thipx/thipx32.dll"
	echo "  Optionally pass a path to an EXE to verify THIPX32 import."
	exit 0
fi

echo ""
echo "  Stub built at: $OUT"
echo "  Copy this to your Wine game staging dir, e.g.:"
echo "    cp $OUT <stage-dir>/THIPX32.DLL"

echo ""
echo "=== Build complete ==="
