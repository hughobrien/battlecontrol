#!/usr/bin/env bash
# TIM-711 — One-shot setup: extract C&C95.EXE + THIPX32.DLL
#           from archive.org, then apply Wine-compatibility patch.
#
# C&C95.EXE is the Win95 C&C Tiberian Dawn game binary.  It is extracted from
# the "Command & Conquer Gold - Complete Edition (Repack for Modern PCs)" ZIP
# at archive.org.  The file is stored inside the ZIP at:
#   "Command & Conquer/C&C95.EXE"
#   ZIP local-file-header offset: 48 bytes
#   Compressed (deflate) data offset: 105 bytes
#   Compressed size: 518,994 bytes
#   Uncompressed size: 1,161,216 bytes
#   SHA-256 (uncompressed): f606bee19de599daa5ccbc9586d61ee48b8f01f42a4f943196fe30d92a124d30
#
# THIPX32.DLL is also in the same ZIP at:
#   Compressed data offset: 674,675,836 bytes
#   Compressed size: 22,573 bytes
#   Uncompressed size: 44,032 bytes
#   SHA-256 (uncompressed): 0e405776fb8a44c920d81d82a0d137335bf1b36749f84b56f0be4dc04408a042
#
# Source: "Command & Conquer Gold - Complete Edition (Repack for Modern PCs)"
#   https://archive.org/details/command-aand-conquer-gold
#   "Command & Conquer Gold.zip" (688,113,895 bytes)
#
# Legal status: EA released C&C Tiberian Dawn as freeware in 2007.
#
# Wine compatibility patch:
#   C&C95.EXE calls SetCooperativeLevel with DDSCL_EXCLUSIVE|DDSCL_FULLSCREEN
#   (0x11).  On Wine+Xvfb, fullscreen exclusive mode fails surface creation.
#   Patch at 0x000bc6af: 0x11 -> 0x08 (DDSCL_NORMAL) so the game runs in
#   windowed mode under Wine.
#   Patch offset: 0x000bc6af  Original: 0x11  Patched: 0x08
#   SHA-256 of original: f606bee19de599daa5ccbc9586d61ee48b8f01f42a4f943196fe30d92a124d30
#   SHA-256 of patched:  (computed and displayed during setup)
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#   bash scripts/wine-td-setup.sh
#
# After this runs, verify with:
#   bash scripts/wine-td.sh

set -euo pipefail

ZIP_URL="https://archive.org/download/command-aand-conquer-gold/Command%20%26%20Conquer%20Gold.zip"
OUT_DIR="/opt/tiberiandawn"

# C&C95.EXE stored inside the ZIP at "Command & Conquer/C&C95.EXE"
# ZIP local header at offset 48, compressed data starts at offset 105
# (header=30 + name=27 + extra=0 = 57 bytes after header sig,
#  but local_offset=48 so data_at = 48 + 30 + 27 = 105)
CC95_ZIP_DATA_OFFSET=105
CC95_ZIP_COMP_SIZE=518994
CC95_ZIP_END=$((CC95_ZIP_DATA_OFFSET + CC95_ZIP_COMP_SIZE - 1))
# shellcheck disable=SC2034
CC95_UNCOMPRESSED_SIZE=1161216
CC95_SHA256="f606bee19de599daa5ccbc9586d61ee48b8f01f42a4f943196fe30d92a124d30"

# THIPX32.DLL — required by C&C95.EXE for IPX networking
THIPX_ZIP_DATA_OFFSET=674675836
THIPX_ZIP_COMP_SIZE=22573
THIPX_ZIP_END=$((THIPX_ZIP_DATA_OFFSET + THIPX_ZIP_COMP_SIZE - 1))
# shellcheck disable=SC2034
THIPX_UNCOMPRESSED_SIZE=44032
THIPX_SHA256="0e405776fb8a44c920d81d82a0d137335bf1b36749f84b56f0be4dc04408a042"

# Wine-compatibility patch: DDSCL_EXCLUSIVE|FULLSCREEN -> DDSCL_NORMAL
# Allows C&C95 to run in windowed mode under Wine+Xvfb.
CC95_DDSCL_PATCH_OFFSET=0xbc6af # byte position of 0x11 in SetCooperativeLevel call
CC95_DDSCL_ORIG=0x11            # DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN
CC95_DDSCL_PATCHED=0x08         # DDSCL_NORMAL

echo "=== TIM-711 C&C95.EXE + THIPX32.DLL setup ==="
echo ""

# ─── 1. Output directory ─────────────────────────────────────────────────────

echo "=== Step 1: Prepare output directory ==="
sudo mkdir -p "$OUT_DIR"
sudo chmod 777 "$OUT_DIR"
echo "  Output: $OUT_DIR"
echo ""

# ─── 3. Extract C&C95.EXE from ZIP via HTTP range + Python zlib ──────────────

echo "=== Step 2: Download and decompress C&C95.EXE from archive.org ==="
CC95="$OUT_DIR/C&C95.EXE"

if [[ -f "$CC95" ]]; then
	existing_sha=$(sha256sum "$CC95" | awk '{print $1}')
	if [[ "$existing_sha" == "$CC95_SHA256" ]]; then
		echo "  C&C95.EXE already present and verified (sha256 matches original)."
		SKIP_CC95_DOWNLOAD=1
	else
		echo "  Existing C&C95.EXE has wrong sha256, re-downloading..."
		SKIP_CC95_DOWNLOAD=0
	fi
else
	SKIP_CC95_DOWNLOAD=0
fi

if [[ "${SKIP_CC95_DOWNLOAD:-0}" == "0" ]]; then
	echo "  Downloading compressed C&C95.EXE (519 KB) from archive.org ZIP..."
	echo "  ZIP byte range: ${CC95_ZIP_DATA_OFFSET}-${CC95_ZIP_END}"

	TMP_COMP=$(mktemp /tmp/cc95-compressed-XXXXXX.bin)
	trap 'rm -f "$TMP_COMP"' EXIT

	curl -L -r "${CC95_ZIP_DATA_OFFSET}-${CC95_ZIP_END}" "$ZIP_URL" \
		-o "$TMP_COMP" --progress-bar

	actual_comp=$(stat -c%s "$TMP_COMP")
	echo "  Downloaded: $actual_comp bytes (expected $CC95_ZIP_COMP_SIZE)"
	if [[ "$actual_comp" != "$CC95_ZIP_COMP_SIZE" ]]; then
		echo "  FAIL: compressed size mismatch"
		exit 1
	fi

	echo "  Decompressing (raw deflate via Python zlib)..."
	python3 - "$TMP_COMP" "$CC95" <<'PYEOF'
import sys, zlib

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    compressed = f.read()
decompressed = zlib.decompress(compressed, -15)  # raw deflate, wbits=-15
with open(dst, 'wb') as f:
    f.write(decompressed)
print(f"  Decompressed: {len(decompressed):,} bytes")
PYEOF

	# Verify SHA256
	actual_sha=$(sha256sum "$CC95" | awk '{print $1}')
	if [[ "$actual_sha" != "$CC95_SHA256" ]]; then
		echo "  FAIL: C&C95.EXE sha256 mismatch!"
		echo "    expected $CC95_SHA256"
		echo "    actual   $actual_sha"
		exit 1
	fi
	echo "  OK: sha256 matches reference — C&C95.EXE verified"
fi
echo ""

# ─── 4. Extract THIPX32.DLL from the same ZIP ────────────────────────────────

echo "=== Step 3: Download and decompress THIPX32.DLL from archive.org ==="
THIPX="$OUT_DIR/THIPX32.DLL"

if [[ -f "$THIPX" ]]; then
	thipx_sha=$(sha256sum "$THIPX" | awk '{print $1}')
	if [[ "$thipx_sha" == "$THIPX_SHA256" ]]; then
		echo "  THIPX32.DLL already present and verified."
		SKIP_THIPX_DOWNLOAD=1
	else
		echo "  Existing THIPX32.DLL wrong sha256, re-downloading..."
		SKIP_THIPX_DOWNLOAD=0
	fi
else
	SKIP_THIPX_DOWNLOAD=0
fi

if [[ "${SKIP_THIPX_DOWNLOAD:-0}" == "0" ]]; then
	echo "  Downloading compressed THIPX32.DLL (22 KB) from archive.org ZIP..."
	echo "  ZIP byte range: ${THIPX_ZIP_DATA_OFFSET}-${THIPX_ZIP_END}"

	TMP_THIPX=$(mktemp /tmp/thipx-compressed-XXXXXX.bin)
	trap 'rm -f "$TMP_COMP" "$TMP_THIPX"' EXIT

	curl -L -r "${THIPX_ZIP_DATA_OFFSET}-${THIPX_ZIP_END}" "$ZIP_URL" \
		-o "$TMP_THIPX" --progress-bar

	actual_thipx=$(stat -c%s "$TMP_THIPX")
	echo "  Downloaded: $actual_thipx bytes (expected $THIPX_ZIP_COMP_SIZE)"
	if [[ "$actual_thipx" != "$THIPX_ZIP_COMP_SIZE" ]]; then
		echo "  FAIL: THIPX32.DLL compressed size mismatch"
		exit 1
	fi

	python3 - "$TMP_THIPX" "$THIPX" <<'PYEOF'
import sys, zlib

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    compressed = f.read()
decompressed = zlib.decompress(compressed, -15)
with open(dst, 'wb') as f:
    f.write(decompressed)
print(f"  Decompressed: {len(decompressed):,} bytes")
PYEOF

	thipx_actual_sha=$(sha256sum "$THIPX" | awk '{print $1}')
	if [[ "$thipx_actual_sha" != "$THIPX_SHA256" ]]; then
		echo "  FAIL: THIPX32.DLL sha256 mismatch!"
		exit 1
	fi
	echo "  OK: sha256 matches reference — THIPX32.DLL verified"
fi
echo ""

# ─── 5. Apply Wine-compatibility DDSCL patch to C&C95.EXE ───────────────────

echo "=== Step 4: Apply Wine-compatibility patch to C&C95.EXE ==="
echo "  Patch: offset 0x${CC95_DDSCL_PATCH_OFFSET##0x}bc6af:"
echo "         SetCooperativeLevel flags 0x11 (DDSCL_EXCLUSIVE|FULLSCREEN)"
echo "         -> 0x08 (DDSCL_NORMAL, windowed)"
echo "  This allows C&C95.EXE to run under Wine+Xvfb without crashing."

python3 - "$CC95" "${CC95_DDSCL_PATCH_OFFSET}" "${CC95_DDSCL_ORIG}" "${CC95_DDSCL_PATCHED}" "$CC95_SHA256" <<'PYEOF'
import sys, hashlib, shutil

path = sys.argv[1]
patch_offset = int(sys.argv[2], 16)
orig_byte = int(sys.argv[3], 16)
patched_byte = int(sys.argv[4], 16)
original_sha256 = sys.argv[5]

with open(path, 'rb') as f:
    data = bytearray(f.read())

cur_sha = hashlib.sha256(bytes(data)).hexdigest()
cur_byte = data[patch_offset]

if cur_byte == patched_byte:
    print(f"  Already patched (byte at 0x{patch_offset:06x} is 0x{patched_byte:02x})")
    sys.exit(0)

if cur_byte != orig_byte:
    print(f"  WARN: unexpected byte at 0x{patch_offset:06x}: 0x{cur_byte:02x} (expected 0x{orig_byte:02x})")
    print(f"  Skipping patch — may be a different C&C95.EXE build")
    sys.exit(0)

if cur_sha != original_sha256:
    print(f"  WARN: SHA-256 does not match reference — skipping patch")
    sys.exit(0)

# Backup original (unpatched)
backup = path + ".ddscl_orig"
shutil.copy2(path, backup)
print(f"  Backup: {backup}")

# Apply patch
data[patch_offset] = patched_byte
with open(path, 'wb') as f:
    f.write(data)

patched_sha = hashlib.sha256(bytes(data)).hexdigest()
print(f"  Patched 0x{patch_offset:06x}: 0x{orig_byte:02x} -> 0x{patched_byte:02x}")
print(f"  Patched SHA-256: {patched_sha}")
print(f"  OK: C&C95.EXE patched for Wine windowed mode")
PYEOF
echo ""

# ─── 6. Summary ──────────────────────────────────────────────────────────────

echo "=== Setup complete ==="
echo "  wine: $(wine --version)"
echo "  C&C95.EXE: $CC95 ($(stat -c%s "$CC95") bytes)"
echo "  THIPX32.DLL: $THIPX ($(stat -c%s "$THIPX") bytes)"
echo ""
echo "  Run: bash scripts/wine-td.sh"
echo "  Expected: game launches, shows DirectSound warning dialog (~8s),"
echo "            dialog is dismissed automatically, game window appears."
