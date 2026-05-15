#!/usr/bin/env bash
# TIM-711 — One-shot setup: install wine32 + extract C&C95.EXE from GDI95.iso.
#
# C&C95.EXE is inside SETUP.Z (InstallShield v3 Z archive) on the GDI disc ISO.
# The ISO is hosted at archive.org as part of the EA 2007 freeware release.
#
# Source: "Official C&C Tiberian Sun (+ C&C 95, + RA)" at archive.org
#   https://archive.org/details/official-cn-ctiberian-sun_202510
#   GDI95.iso (608,987,136 bytes) — EA 2007 freeware C&C Tiberian Dawn GDI disc
#
# Legal status: EA released C&C Tiberian Dawn as freeware in 2007.
#
# ─── C&C95.EXE extraction notes ─────────────────────────────────────────────
# The disc installer (SETUP.EXE) is a 16-bit Windows 3.x NE executable; Wine
# 10.x cannot run it (exit 144 = STATUS_NOT_SUPPORTED, no WOW16 on Linux).
# We extract directly from SETUP.Z using the IS v3 Z format instead:
#
#   • SETUP.Z is at ISO LBA 18086, size 23,501,276 bytes.
#   • C&C95.EXE directory entry at SETUP.Z offset 0x16695d3:
#       name_len=9, archive_offset=0x9BAF86, block_count=766, last_fill=199.
#   • IS v3 Z block format: 2-byte LE compressed-data length + LZ payload.
#     Flag byte (LSB-first): bit=1 literal, bit=0 back-ref (12-bit window,
#     count = (b2 & 0xF) + 3).  Ring buffer: 4096 bytes, zero-initialized.
#   • Uncompressed size: 765 × 1536 + 199 = 1,175,239 bytes.
#
# Usage:
#   bash scripts/wine-td-setup.sh
#
# After this runs, verify with:
#   bash scripts/wine-td.sh

set -euo pipefail

ISO_URL="https://archive.org/download/official-cn-ctiberian-sun_202510/GDI95.iso"
OUT_DIR="/opt/tiberiandawn"
WORK_DIR="$(mktemp -d /tmp/td-setup-XXXXXX)"
trap "rm -rf $WORK_DIR" EXIT

echo "=== TIM-711 Wine + C&C95.EXE setup ==="
echo ""

# ─── 1. wine32 ───────────────────────────────────────────────────────────────

echo "=== Step 1: Install wine32 (32-bit support) ==="
if wine --version 2>&1 | grep -q "wine32 is missing"; then
    echo "  Installing wine32:i386..."
    sudo dpkg --add-architecture i386
    sudo apt-get update -qq
    sudo apt-get install -y wine32:i386
    echo "  wine32 installed."
else
    echo "  wine32 already available: $(wine --version)"
fi
echo ""

# ─── 2. Output directory ─────────────────────────────────────────────────────

echo "=== Step 2: Prepare output directory ==="
sudo mkdir -p "$OUT_DIR"
sudo chmod 777 "$OUT_DIR"
echo "  Output: $OUT_DIR"
echo ""

# ─── 3. Fetch SETUP.Z from ISO via HTTP range ────────────────────────────────

echo "=== Step 3: Download SETUP.Z from GDI95.iso ==="
SETUP_Z="$WORK_DIR/SETUP.Z"

if [[ ! -f "$SETUP_Z" ]]; then
    SETUP_Z_START=$(( 18086 * 2048 ))
    SETUP_Z_END=$(( SETUP_Z_START + 23501276 - 1 ))
    echo "  Downloading SETUP.Z (22.4 MB) via HTTP range request..."
    curl -L -r "${SETUP_Z_START}-${SETUP_Z_END}" "$ISO_URL" \
        -o "$SETUP_Z" --progress-bar
    echo "  Size: $(ls -lh "$SETUP_Z" | awk '{print $5}')"
else
    echo "  SETUP.Z already present."
fi
echo ""

# ─── 4. Extract C&C95.EXE using inline IS v3 Z decompressor ─────────────────

echo "=== Step 4: Extract C&C95.EXE from SETUP.Z ==="
CC95="$OUT_DIR/C&C95.EXE"

python3 - "$SETUP_Z" "$CC95" << 'PYEOF'
import sys, hashlib

setup_z_path = sys.argv[1]
out_path     = sys.argv[2]

# C&C95.EXE directory entry (verified from SETUP.Z at offset 0x16695d3):
#   1 byte  name_len = 9
#   9 bytes name     = "C&C95.EXE"
#   16 bytes null pad (total name field = 26 bytes)
#   4 bytes f1 = 766  (number of IS-LZ blocks)
#   4 bytes f2 = 199  (bytes used in last block)
#   3 bytes archive_offset = 0x9BAF86 (LE)
ARCHIVE_OFFSET    = 0x9BAF86
NUM_BLOCKS        = 766
LAST_BLOCK_FILL   = 199
BLOCK_DECOMP_SIZE = 1536

print(f"  Reading {setup_z_path} ...", flush=True)
with open(setup_z_path, 'rb') as f:
    data = bytearray(f.read())

def islz_decomp(data, start, out_size):
    """Decompress one IS v3 Z LZ block.

    Block format: 2-byte LE compressed-data length, then payload.
    Flag byte (LSB-first): bit=1 literal, bit=0 back-reference.
    Back-ref encoding: offset = b1|(b2>>4)<<8, count = (b2&0xF)+3.
    Ring buffer: 4096 bytes, zero-initialised, wrap with & 0xFFF.
    Returns (decompressed_bytes, next_block_start).
    """
    comp_len = data[start] | (data[start + 1] << 8)
    end = start + 2 + comp_len
    pos = start + 2
    out = bytearray()
    ring = bytearray(4096)
    rp = 0
    while len(out) < out_size and pos < end:
        if pos >= len(data):
            break
        flags = data[pos]; pos += 1
        for bit in range(8):
            if len(out) >= out_size or pos >= end:
                break
            if flags & (1 << bit):
                b = data[pos]; pos += 1
                out.append(b); ring[rp & 0xFFF] = b; rp += 1
            else:
                b1 = data[pos]; pos += 1
                b2 = data[pos]; pos += 1
                ov  = b1 | ((b2 >> 4) << 8)
                cnt = (b2 & 0xF) + 3
                src = (rp - ov - 1) & 0xFFF
                for j in range(cnt):
                    if len(out) >= out_size:
                        break
                    b = ring[(src + j) & 0xFFF]
                    out.append(b); ring[rp & 0xFFF] = b; rp += 1
    return bytes(out), end

print(f"  Extracting {NUM_BLOCKS} IS-LZ blocks from 0x{ARCHIVE_OFFSET:x} ...", flush=True)
pos = ARCHIVE_OFFSET
result = bytearray()
for i in range(NUM_BLOCKS):
    sz = LAST_BLOCK_FILL if i == NUM_BLOCKS - 1 else BLOCK_DECOMP_SIZE
    blk, pos = islz_decomp(data, pos, sz)
    result += blk

total = len(result)
print(f"  Extracted {total:,} bytes")
if result[:2] != b'MZ':
    print(f"  WARN: first bytes {result[:2].hex()} != 4d5a (MZ) — extraction may need tuning")

sha = hashlib.sha256(result).hexdigest()
print(f"  SHA-256: {sha}")

with open(out_path, 'wb') as f:
    f.write(result)
print(f"  Written: {out_path}")
PYEOF

echo ""

# ─── 5. Verify ───────────────────────────────────────────────────────────────

echo "=== Step 5: Verify C&C95.EXE ==="
if [[ -f "$CC95" ]]; then
    actual=$(sha256sum "$CC95" | awk '{print $1}')
    sz=$(stat -c%s "$CC95")
    echo "  Path:   $CC95"
    echo "  Size:   $sz bytes"
    echo "  SHA256: $actual"
    if [[ $sz -gt 500000 ]]; then
        echo "  OK: C&C95.EXE extracted"
        echo "  Update C&C95_EXE_SHA256 in scripts/td-data-verify.py with:"
        echo "  $actual"
    else
        echo "  WARN: unexpected size — IS-LZ block parameters may need adjustment."
        echo "  Expected ~1,175,239 bytes. Check ARCHIVE_OFFSET/NUM_BLOCKS/LAST_BLOCK_FILL."
    fi
else
    echo "  ERROR: C&C95.EXE not written"
    exit 1
fi

echo ""
echo "=== Setup complete ==="
echo "  wine: $(wine --version)"
echo "  C&C95.EXE: $CC95"
echo ""
echo "  Run: bash scripts/wine-td.sh"
echo "  Expected: game launches, shows C&C Tiberian Dawn title screen."
