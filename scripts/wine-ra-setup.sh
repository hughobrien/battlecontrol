#!/usr/bin/env bash
# TIM-699 — One-shot setup: install wine32 + download RA95.EXE from archive.org.
#
# Fetches RA95.EXE and its required DLLs from the Allied CD ISO hosted at
# archive.org.  Uses HTTP range requests so only the relevant sectors are
# downloaded (~2.2 MB), not the full 653 MB ISO.
#
# Source: "Command & Conquer: Red Alert (ISO)" at archive.org
#   https://archive.org/details/cnc-red-alert
#   Allied CD ISO: redalert_allied.iso (653,725,696 bytes)
#
# Legal status: EA released Command & Conquer games as freeware in 2008.
# The original Red Alert is freely distributable.
#
# Usage:
#   bash scripts/wine-ra-setup.sh
#
# After this runs, verify with:
#   bash scripts/wine-ra.sh

set -euo pipefail

ISO_URL="https://archive.org/download/cnc-red-alert/redalert_allied.iso"
OUT_DIR="/opt/redalert"

echo "=== TIM-699 Wine + RA95.EXE setup ==="
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

# ─── 2. RA95.EXE ─────────────────────────────────────────────────────────────

echo "=== Step 2: Download RA95.EXE from archive.org ISO ==="
sudo mkdir -p "$OUT_DIR"
sudo chmod 777 "$OUT_DIR"

RA95_SHA="a95e2ac85c4cc3aaacb7795e3c07b8aec7c3e10efe679766fb2ee15b12aa2d55"

if [[ -f "$OUT_DIR/RA95.EXE" ]]; then
    actual=$(sha256sum "$OUT_DIR/RA95.EXE" | awk '{print $1}')
    if [[ "$actual" == "$RA95_SHA" ]]; then
        echo "  RA95.EXE already present and checksum matches, skipping."
    else
        echo "  RA95.EXE present but checksum mismatch — re-downloading."
        rm -f "$OUT_DIR/RA95.EXE"
    fi
fi

if [[ ! -f "$OUT_DIR/RA95.EXE" ]]; then
    echo "  Downloading RA95.EXE (2.1 MB) from ISO via HTTP range..."
    # RA95.EXE is at LBA 45220, size 2,181,632 bytes in the INSTALL/ directory.
    START=$((45220 * 2048))
    END=$((START + 2181632 - 1))
    curl -L -r "${START}-${END}" "$ISO_URL" -o "$OUT_DIR/RA95.EXE" --progress-bar
    actual=$(sha256sum "$OUT_DIR/RA95.EXE" | awk '{print $1}')
    if [[ "$actual" != "$RA95_SHA" ]]; then
        echo "  ERROR: SHA-256 mismatch!  Got: $actual"
        exit 1
    fi
    echo "  RA95.EXE downloaded and verified (sha256=$RA95_SHA)"
fi

# ─── 3. Required DLLs ────────────────────────────────────────────────────────

echo ""
echo "=== Step 3: Download required DLLs ==="

# THIPX32.DLL — IPX network thunk layer, LBA 58881, size 25902
if [[ ! -f "$OUT_DIR/THIPX32.DLL" ]]; then
    echo "  Downloading THIPX32.DLL..."
    START=$((58881 * 2048))
    curl -L -r "${START}-$((START + 25901))" "$ISO_URL" -o "$OUT_DIR/THIPX32.DLL" --progress-bar
fi
echo "  THIPX32.DLL: $(ls -lh "$OUT_DIR/THIPX32.DLL" | awk '{print $5}')"

# THIPX16.DLL — 16-bit IPX thunk, LBA 58878, size 4192
if [[ ! -f "$OUT_DIR/THIPX16.DLL" ]]; then
    echo "  Downloading THIPX16.DLL..."
    START=$((58878 * 2048))
    curl -L -r "${START}-$((START + 4191))" "$ISO_URL" -o "$OUT_DIR/THIPX16.DLL" --progress-bar
fi
echo "  THIPX16.DLL: $(ls -lh "$OUT_DIR/THIPX16.DLL" | awk '{print $5}')"

# ─── 4. Summary ──────────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo "  wine: $(wine --version)"
echo "  RA95.EXE: $OUT_DIR/RA95.EXE ($(ls -lh "$OUT_DIR/RA95.EXE" | awk '{print $5}'))"
echo "  THIPX32.DLL: $OUT_DIR/THIPX32.DLL"
echo "  THIPX16.DLL: $OUT_DIR/THIPX16.DLL"
echo ""
echo "  Run: bash scripts/wine-ra.sh"
echo "  Expected: game launches, shows RA menu background (#283870 dark navy)."
