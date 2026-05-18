#!/usr/bin/env bash
# TIM-699 — One-shot RA setup: resolve RA95.EXE + DLLs from Nix store.
#
# The Nix flake provides ra-patched-exe (NoCD + DDSCL + cdlabel patches
# already applied).  This script resolves the Nix store paths and prints
# them for use with wine-ra.sh.
#
# For non-Nix users, see the "Manual download" comment block below.
#
# Usage:
#   bash scripts/wine-ra-setup.sh
#
# After this runs, verify with:
#   bash scripts/wine-ra.sh
#
# Prerequisites:
#   nix develop shell (provides nix command and Wine)

set -euo pipefail

echo "=== RA95.EXE + DLL resolution via Nix store ==="
echo ""

# Resolve ra-patched-exe from Nix store
RA_EXE=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || {
  echo "ERROR: Could not resolve ra-patched-exe from Nix store."
  echo "  Run this script from inside 'nix develop'."
  exit 1
}

# Resolve DLLs (optional — wine-ra.sh uses the stub at tools/stub-thipx/)
RA_THIPX32=$(nix build .#ra-thipx32-dll --impure --print-out-paths 2>/dev/null) || RA_THIPX32=""
RA_THIPX16=$(nix build .#ra-thipx16-dll --impure --print-out-paths 2>/dev/null) || RA_THIPX16=""

echo "  RA95.EXE:     $RA_EXE ($(stat -c%s "$RA_EXE") bytes)"
echo "  THIPX32.DLL:  ${RA_THIPX32:-"(not resolved — stub used instead)"}"
echo "  THIPX16.DLL:  ${RA_THIPX16:-"(not resolved — stub used instead)"}"
echo ""
echo "  The Nix derivation applies NoCD + DDSCL patches automatically."
echo "  No additional patching needed."
echo ""
echo "  To use with wine-ra.sh (no args):"
echo "    bash scripts/wine-ra.sh"
echo "  Or with explicit path:"
echo "    bash scripts/wine-ra.sh \"$RA_EXE\""
echo ""
echo "=== Setup complete ==="

# ---------------------------------------------------------------------------
#  Manual download instructions (for non-Nix users)
#
#  To download RA95.EXE + DLLs from the Allied CD ISO at archive.org
#  without Nix:
#
#    ISO_URL="https://archive.org/download/cnc-red-alert/redalert_allied.iso"
#    mkdir -p /tmp/ra-setup && cd /tmp/ra-setup
#
#    # RA95.EXE (LBA 45220, 2,181,632 bytes):
#    START=$((45220 * 2048))
#    END=$((START + 2181632 - 1))
#    curl -L -r "${START}-${END}" "$ISO_URL" -o RA95.EXE
#
#    # THIPX32.DLL (LBA 58881, 25,902 bytes):
#    START=$((58881 * 2048))
#    curl -L -r "${START}-$((START + 25901))" "$ISO_URL" -o THIPX32.DLL
#
#    # THIPX16.DLL (LBA 58878, 4,192 bytes):
#    START=$((58878 * 2048))
#    curl -L -r "${START}-$((START + 4191))" "$ISO_URL" -o THIPX16.DLL
#
#    # Apply patches (requires Python):
#    python3 scripts/nocd-patch.py RA95.EXE
#    python3 scripts/ddscl-patch.py RA95.EXE
#
#    # Run:
#    bash scripts/wine-ra.sh /tmp/ra-setup/RA95.EXE
# ---------------------------------------------------------------------------
