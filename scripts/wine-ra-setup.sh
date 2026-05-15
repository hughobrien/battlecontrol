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

# ─── 2b. Apply NoCD patch ────────────────────────────────────────────────────
# TIM-720: Wine's GetDriveType returns DRIVE_REMOTE (4) for symlinked/network
# directories instead of DRIVE_CDROM (5), triggering the "insert CD" dialog.
# Patch: NOP the jne at 0x1a54a1 that branches to the CD error dialog.
echo ""
echo "=== Step 2b: Apply NoCD patch to RA95.EXE ==="
NOCD_TARGETS=("$OUT_DIR/RA95.EXE")
[[ -f "$OUT_DIR/game/RA95.EXE" ]] && NOCD_TARGETS+=("$OUT_DIR/game/RA95.EXE")
if python3 scripts/nocd-patch.py "${NOCD_TARGETS[@]}"; then
    echo "  NoCD patch OK"
else
    echo "  WARN: NoCD patch failed — game may show 'Please insert CD' dialog"
fi

# ─── 2c. Apply DDSCL patch ───────────────────────────────────────────────────
# TIM-727: RA95.EXE calls IDirectDraw::SetCooperativeLevel with
# DDSCL_EXCLUSIVE|DDSCL_FULLSCREEN.  On Wine, that path renders the primary
# surface through wined3d/llvmpipe — never composited into the X11 window tree
# — so X11 capture tools (ffmpeg x11grab, import, scrot) return blank frames.
# Patching the flag to DDSCL_NORMAL makes Wine render DDraw via XPutImage in a
# windowed surface that X11 capture can grab.  Unblocks TIM-708 (gameplay
# screenshot capture under Xvfb + cage).
echo ""
echo "=== Step 2c: Apply DDSCL patch to RA95.EXE ==="
if python3 scripts/ddscl-patch.py "${NOCD_TARGETS[@]}"; then
    echo "  DDSCL patch OK — RA will use windowed DirectDraw under Wine"
else
    echo "  WARN: DDSCL patch failed — X11 screenshot capture will return black frames"
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

# ─── 4. Original game data MIXes (optional, ~480 MB) ────────────────────────
#
# Fetches MAIN.MIX (454 MB) and REDALERT.MIX (25 MB) directly from the
# archive.org ISO viewer.  These are the unmodified 1996 Allied CD assets
# (verified bit-identical to /CnCRemastered/CD1's MAIN.MIX/REDALERT.MIX).
# Set RA_FETCH_DATA=1 to fetch them.
#
# Background: TIM-709 board note 2026-05-15 — confirmed Remastered Collection's
# CD1 dir contains the original 1996 files unchanged for MAIN.MIX and
# REDALERT.MIX. Other files there (EXPAND.MIX, HIRES1.MIX, LORES1.MIX,
# REDALERT.INI) are post-1996 expansion/patch content the Allied CD lacked.

if [[ "${RA_FETCH_DATA:-0}" == "1" ]]; then
    echo ""
    echo "=== Step 4: Download original game data (~480 MB) ==="
    DATA_DIR="$OUT_DIR/data-og"
    mkdir -p "$DATA_DIR"

    MAIN_SHA="99104379472bbcfb70c7e378de18d5aa86918bd4"
    REDALERT_SHA="0e58f4b54f44f6cd29fecf8cf379d33cf2d4caef"

    if [[ ! -f "$DATA_DIR/MAIN.MIX" ]] || \
       ! sha1sum "$DATA_DIR/MAIN.MIX" 2>/dev/null | grep -q "^$MAIN_SHA "; then
        echo "  Downloading MAIN.MIX (~454 MB)..."
        curl -sL "https://archive.org/download/cnc-red-alert/redalert_allied.iso/MAIN.MIX" \
            -o "$DATA_DIR/MAIN.MIX" --progress-bar
        actual=$(sha1sum "$DATA_DIR/MAIN.MIX" | awk '{print $1}')
        if [[ "$actual" != "$MAIN_SHA" ]]; then
            echo "  ERROR: MAIN.MIX SHA-1 mismatch: $actual"; exit 1
        fi
        echo "  MAIN.MIX verified (sha1=$MAIN_SHA)"
    else
        echo "  MAIN.MIX already present and verified."
    fi

    if [[ ! -f "$DATA_DIR/REDALERT.MIX" ]] || \
       ! sha1sum "$DATA_DIR/REDALERT.MIX" 2>/dev/null | grep -q "^$REDALERT_SHA "; then
        echo "  Downloading REDALERT.MIX (~25 MB)..."
        curl -sL "https://archive.org/download/cnc-red-alert/redalert_allied.iso/INSTALL%2FREDALERT.MIX" \
            -o "$DATA_DIR/REDALERT.MIX" --progress-bar
        actual=$(sha1sum "$DATA_DIR/REDALERT.MIX" | awk '{print $1}')
        if [[ "$actual" != "$REDALERT_SHA" ]]; then
            echo "  ERROR: REDALERT.MIX SHA-1 mismatch: $actual"; exit 1
        fi
        echo "  REDALERT.MIX verified (sha1=$REDALERT_SHA)"
    else
        echo "  REDALERT.MIX already present and verified."
    fi

    echo "  Original MIXes available at: $DATA_DIR"
    echo "  Note: 1996 Allied CD does NOT include EXPAND/HIRES1/LORES1.MIX or"
    echo "  REDALERT.INI — those are post-1996 expansion/patch content."
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "=== Setup complete ==="
echo "  wine: $(wine --version)"
echo "  RA95.EXE: $OUT_DIR/RA95.EXE ($(ls -lh "$OUT_DIR/RA95.EXE" | awk '{print $5}'))"
echo "  THIPX32.DLL: $OUT_DIR/THIPX32.DLL"
echo "  THIPX16.DLL: $OUT_DIR/THIPX16.DLL"
if [[ -f "$OUT_DIR/data-og/MAIN.MIX" ]]; then
    echo "  Original MIXes: $OUT_DIR/data-og/"
fi
echo ""
echo "  Run: bash scripts/wine-ra.sh"
echo "  Expected: game launches, shows RA menu background (#283870 dark navy)."
