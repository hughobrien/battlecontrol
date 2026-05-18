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
#   bash scripts/build-stub-thipx.sh          # build + verify
#   bash scripts/build-stub-thipx.sh install  # build + deploy to game dirs

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
echo "=== RA95.EXE import check ==="
RA_EXE="/opt/redalert/game/RA95.EXE.orig"
if [[ -f "$RA_EXE" ]]; then
	i686-w64-mingw32-objdump -p "$RA_EXE" 2>/dev/null | grep -A 20 "thipx32"
fi

# Optional install
if [[ "${1:-}" == "install" ]]; then
	echo ""
	echo "=== Installing to game directories ==="
	install -m 644 "$OUT" /opt/redalert/game/THIPX32.DLL 2>/dev/null || true
	echo "  /opt/redalert/game/THIPX32.DLL"
	echo "Done."
fi

echo ""
echo "=== Build complete ==="
