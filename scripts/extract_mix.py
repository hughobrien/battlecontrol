#!/usr/bin/env python3
"""
Westwood MIX file extractor.
Supports classic (no-flag) and extended (digest/encrypted-flag) headers.
Does NOT support RSA-encrypted indices (those need the public key).

Usage:
  python3 extract_mix.py <mix_file> [pattern]

  pattern: optional glob-style filename pattern (matched against known names
           from --list, or brute-force CRC scan if names are unknown).

  --list    : list all entry CRCs, offsets, sizes
  --extract <name> : extract file with given name

The CRC used as key is Westwood's Calculate_CRC of the uppercased filename.
"""

import struct
import sys
import os
import ctypes

# ---------------------------------------------------------------------------
# Westwood CRC (mirrors CRC.H / CRC.CPP)
# ---------------------------------------------------------------------------


def _rotl32(v: int, n: int) -> int:
    v &= 0xFFFFFFFF
    return ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF


def westwood_crc(data: bytes) -> int:
    """Return 32-bit Westwood CRC of data (signed int32 interpretation)."""
    crc = 0
    idx = 0
    staging = bytearray(4)

    for byte in data:
        staging[idx] = byte
        idx += 1
        if idx == 4:
            chunk = struct.unpack("<I", staging)[0]
            crc = (_rotl32(crc, 1) + chunk) & 0xFFFFFFFF
            idx = 0
            staging = bytearray(4)

    # Final partial chunk (staging buffer not full)
    if idx > 0:
        chunk = struct.unpack("<I", bytes(staging))[0]
        crc = (_rotl32(crc, 1) + chunk) & 0xFFFFFFFF

    # Return as signed int32
    return ctypes.c_int32(crc).value


def mix_key(filename: str) -> int:
    """MIX file lookup key for a filename."""
    return westwood_crc(filename.upper().encode("ascii"))


# ---------------------------------------------------------------------------
# MIX parsing
# ---------------------------------------------------------------------------


def parse_mix(data: bytes):
    """
    Parse a MIX file (raw bytes).
    Returns (entries, data_start) where entries = list of (crc, offset, size).
    data_start is the byte offset in `data` where the body begins.
    Returns None on failure.
    """
    if len(data) < 6:
        return None, 0

    # Detect format: if first 2 bytes == 0 → extended header
    first = struct.unpack_from("<H", data, 0)[0]

    if first == 0:
        # Extended: [uint16 flags][uint16 flags2] then FileHeader
        flags = struct.unpack_from("<H", data, 2)[0]
        is_encrypted = bool(flags & 0x02)
        if is_encrypted:
            print(
                "[MIX] File has RSA-encrypted index — cannot extract without key.",
                file=sys.stderr,
            )
            return None, 0
        offset = 4  # past the 4-byte alternate header
        count, size = struct.unpack_from("<hI", data, offset)
        offset += 6  # FileHeader: short count + int size (packed)
    else:
        # Classic: first 6 bytes ARE the FileHeader
        count, size = struct.unpack_from("<hI", data, 0)
        offset = 6

    if count < 0 or count > 100000:
        return None, 0

    # Index: count * 12 bytes (int CRC, int offset, int size)
    index_size = count * 12
    if offset + index_size > len(data):
        return None, 0

    entries = []
    for i in range(count):
        crc, off, sz = struct.unpack_from("<iII", data, offset + i * 12)
        entries.append((crc, off, sz))

    data_start = offset + index_size
    return entries, data_start


def extract_file_by_name(mix_data: bytes, filename: str) -> bytes | None:
    """Extract a single file from a MIX by filename."""
    key = mix_key(filename)
    entries, data_start = parse_mix(mix_data)
    if entries is None:
        return None
    for crc, off, sz in entries:
        if crc == key:
            start = data_start + off
            return mix_data[start : start + sz]
    return None


def extract_file_by_crc(mix_data: bytes, crc: int) -> bytes | None:
    """Extract a single file from a MIX by CRC key."""
    entries, data_start = parse_mix(mix_data)
    if entries is None:
        return None
    for ecrc, off, sz in entries:
        if ecrc == crc:
            start = data_start + off
            return mix_data[start : start + sz]
    return None


def list_mix(mix_data: bytes):
    """Print all entries in a MIX."""
    entries, data_start = parse_mix(mix_data)
    if entries is None:
        print("Failed to parse MIX.")
        return
    print(f"{'CRC':>12}  {'Offset':>10}  {'Size':>10}")
    for crc, off, sz in entries:
        print(f"{crc:12d}  {off:10d}  {sz:10d}  (crc=0x{crc & 0xFFFFFFFF:08x})")


# ---------------------------------------------------------------------------
# Known filename scanning (try common VQA names against CRC table)
# ---------------------------------------------------------------------------

COMMON_RA_NAMES = [
    "ENGLISH.VQA",
    "TITLE.PCX",
    "HIRES.MIX",
    "LORES.MIX",
    "LORES1.MIX",
    "HIRES1.MIX",
    "LOCAL.MIX",
    "REDALERT.MIX",
    "MAIN.MIX",
    "EXPAND.MIX",
    "EXPAND2.MIX",
    "SPEECH.MIX",
    "SCORES.MIX",
    "ALLIES1.VQA",
    "ALLIES2.VQA",
    "SOVIET1.VQA",
    "INTRO.VQA",
    "INGAME.MIX",
    "TRANSIT.MIX",
    "GENERAL.MIX",
    "ALLY1.VQA",
    "ALLY2.VQA",
    "SOV1.VQA",
    "SOV2.VQA",
    "ALLYMTN.VQA",
    "MTNRULES.VQA",
    "BKGROUND.PCX",
    "CONQUER.MIX",
    "MOVIES01.MIX",
    "MOVIES02.MIX",
    "MOVIES03.MIX",
]


def scan_known_names(mix_data: bytes):
    entries, data_start = parse_mix(mix_data)
    if entries is None:
        return {}
    crc_to_name = {}
    for name in COMMON_RA_NAMES:
        k = mix_key(name)
        for crc, off, sz in entries:
            if crc == k:
                crc_to_name[crc] = name
    return crc_to_name


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    import argparse

    ap = argparse.ArgumentParser(description="Westwood MIX extractor")
    ap.add_argument("mix", help="MIX file path")
    ap.add_argument("--list", action="store_true", help="List entries")
    ap.add_argument("--extract", metavar="NAME", help="Extract file with this name")
    ap.add_argument(
        "--extract-all-known",
        action="store_true",
        help="Extract all files matching known RA names",
    )
    ap.add_argument("--outdir", default=".", help="Output directory (default: .)")
    args = ap.parse_args()

    with open(args.mix, "rb") as f:
        mix_data = f.read()

    if args.list:
        names = scan_known_names(mix_data)
        entries, data_start = parse_mix(mix_data)
        if entries is None:
            print("Failed to parse.")
            return
        print(f"  {'CRC':>12}  {'Offset':>10}  {'Size':>10}  Name")
        for crc, off, sz in entries:
            name = names.get(crc, "?")
            print(f"  {crc:12d}  {off:10d}  {sz:10d}  {name}")
        return

    if args.extract:
        name = args.extract
        data = extract_file_by_name(mix_data, name)
        if data is None:
            print(f"'{name}' not found in {args.mix}")
            sys.exit(1)
        outpath = os.path.join(args.outdir, name)
        os.makedirs(args.outdir, exist_ok=True)
        with open(outpath, "wb") as f:
            f.write(data)
        print(f"Extracted {name} ({len(data)} bytes) → {outpath}")
        return

    if args.extract_all_known:
        os.makedirs(args.outdir, exist_ok=True)
        names = scan_known_names(mix_data)
        entries, data_start = parse_mix(mix_data)
        for crc, off, sz in entries:
            name = names.get(crc)
            if name:
                data = mix_data[data_start + off : data_start + off + sz]
                outpath = os.path.join(args.outdir, name)
                with open(outpath, "wb") as f:
                    f.write(data)
                print(f"  {name} ({sz} bytes)")
        return

    # Default: list with known names
    names = scan_known_names(mix_data)
    entries, data_start = parse_mix(mix_data)
    if entries:
        print(f"{args.mix}: {len(entries)} entries")
        for crc, off, sz in entries:
            name = names.get(crc, "?")
            if name != "?":
                print(f"  0x{crc & 0xFFFFFFFF:08x}  sz={sz:7d}  {name}")


if __name__ == "__main__":
    main()
