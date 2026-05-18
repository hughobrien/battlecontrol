#!/usr/bin/env bash
# TIM-711 — C&C95.EXE setup: resolve from Nix store or explicit path.
#
# C&C95.EXE is the Win95 C&C Tiberian Dawn game binary.  Unlike RA, there
# is currently no Nix derivation that automatically patches the TD EXE.
# This script resolves from an explicit path and prints usage instructions.
#
# For download instructions, see the "Manual download" comment block below.
#
# Usage:
#   bash scripts/wine-td-setup.sh [EXE_PATH]
#
#   EXE_PATH  path to C&C95.EXE  (required — no Nix auto-resolve for TD yet)
#
# After setup, verify with:
#   bash scripts/wine-td.sh

set -euo pipefail

CC95_EXE_PATH="${1:-}"
if [[ -z "$CC95_EXE_PATH" ]]; then
  echo "=== C&C95.EXE resolution ==="
  echo ""
  echo "ERROR: No C&C95.EXE path provided."
  echo ""
  echo "  Usage: bash scripts/wine-td-setup.sh <path-to-C&C95.EXE>"
  echo ""
  echo "  C&C95.EXE must be extracted from the C&C Gold ZIP."
  echo "  See the manual download instructions below."
  exit 1
fi

if [[ ! -f "$CC95_EXE_PATH" ]]; then
  echo "ERROR: File not found: $CC95_EXE_PATH"
  exit 1
fi

EXE_SHA=$(sha256sum "$CC95_EXE_PATH" | awk '{print $1}')
EXE_SIZE=$(stat -c%s "$CC95_EXE_PATH")

echo "=== C&C95.EXE resolved ==="
echo "  Path:   $CC95_EXE_PATH"
echo "  Size:   $EXE_SIZE bytes"
echo "  SHA256: $EXE_SHA"
echo ""
echo "  To use with wine-td.sh:"
echo "    bash scripts/wine-td.sh \"$CC95_EXE_PATH\""
echo ""
echo "  If DDSCL patch is needed:"
echo "    python3 scripts/td-ddmode-patch.py \"$CC95_EXE_PATH\""
echo ""
echo "=== Setup complete ==="

# ---------------------------------------------------------------------------
#  Manual download instructions (for non-Nix users)
#
#  C&C95.EXE is available from the "Command & Conquer Gold - Complete Edition"
#  ZIP at archive.org:
#
#    ZIP_URL="https://archive.org/download/command-aand-conquer-gold/Command%20%26%20Conquer%20Gold.zip"
#    mkdir -p /tmp/td-setup && cd /tmp/td-setup
#
#    # C&C95.EXE is stored inside the ZIP at "Command & Conquer/C&C95.EXE"
#    # deflate-compressed.  Extract via HTTP range + Python zlib:
#    curl -L -r "105-518999" "$ZIP_URL" -o cc95-compressed.bin
#    python3 -c "
#    import zlib, sys
#    with open('cc95-compressed.bin', 'rb') as f:
#        data = zlib.decompress(f.read(), -15)
#    with open('C&C95.EXE', 'wb') as f:
#        f.write(data)
#    "
#    rm cc95-compressed.bin
#
#    # Expected SHA-256: f606bee19de599daa5ccbc9586d61ee48b8f01f42a4f943196fe30d92a124d30
#
#    # Apply DDSCL patch (required for Wine+Xvfb):
#    python3 scripts/td-ddmode-patch.py "C&C95.EXE"
#
#    # Run:
#    bash scripts/wine-td.sh /tmp/td-setup/C&C95.EXE
# ---------------------------------------------------------------------------
