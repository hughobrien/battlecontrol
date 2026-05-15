#!/usr/bin/env bash
# TIM-740 — Build cnc-ddraw with the scanline_double workaround for RA95.
#
# Clones FunkyFr3sh/cnc-ddraw at master, applies
# scripts/cnc-ddraw-tim740-scanline-double.patch, and builds ddraw.dll
# via the project's i686-w64-mingw32-gcc Makefile.
#
# Output:
#   $OUT_DIR/ddraw.dll  (default $OUT_DIR = /tmp/cnc-ddraw-master)
#
# Why we patch rather than ship a binary:
#   The cnc-ddraw release v7.1.0.0 (Dec 2024) renders the RA intro VQA with
#   alternate scanlines black under Wine. RA's VQA player writes only one
#   physical row per logical scanline expecting hardware to replicate the
#   row beneath. Under cnc-ddraw windowed GDI rendering, no such replication
#   happens. The patch adds a config flag `scanline_double=true` that walks
#   each (even, odd) row pair before render and fills "gap" rows by copying
#   from their high-content neighbour. Enable via:
#       [ra95]
#       scanline_double=true
set -euo pipefail

OUT_DIR="${OUT_DIR:-/tmp/cnc-ddraw-master}"
SRC_DIR="${SRC_DIR:-/tmp/cnc-ddraw-src}"
PATCH_FILE="$(cd "$(dirname "$0")" && pwd)/cnc-ddraw-tim740-scanline-double.patch"

# Upstream commit we patch against. Pinned so the diff applies cleanly.
COMMIT="a0b81b1"

command -v i686-w64-mingw32-gcc >/dev/null || {
    echo "FAIL: i686-w64-mingw32-gcc not found. Install with: apt install gcc-mingw-w64-i686" >&2
    exit 2
}
[[ -f "$PATCH_FILE" ]] || { echo "FAIL: $PATCH_FILE missing" >&2; exit 2; }

if [[ ! -d "$SRC_DIR/.git" ]]; then
    git clone --depth 100 https://github.com/FunkyFr3sh/cnc-ddraw.git "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch --depth 50 origin "$COMMIT" 2>/dev/null || true
git reset --hard "$COMMIT"
# Re-apply the patch idempotently.
if ! git apply --check "$PATCH_FILE" 2>/dev/null; then
    echo "info: patch reverse-check (already applied?)"
    git apply --check --reverse "$PATCH_FILE" || {
        echo "FAIL: patch does not apply or reverse-apply" >&2
        exit 1
    }
else
    git apply "$PATCH_FILE"
fi

make clean >/dev/null
make -j"$(nproc)"

mkdir -p "$OUT_DIR"
cp ddraw.dll "$OUT_DIR/ddraw.dll"
md5sum "$OUT_DIR/ddraw.dll"
echo "Built cnc-ddraw → $OUT_DIR/ddraw.dll"
