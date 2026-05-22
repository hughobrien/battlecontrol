#!/usr/bin/env python3
"""
TIM-919 — Full RA VQA cinematic inventory from MAIN.MIX.

Scans MAIN.MIX (and optional EXPAND/EXPAND2) for all embedded VQA blobs,
de-duplicates by VQHD signature, maps to known cinematic names, and
outputs a JSON inventory.

Usage:
  python3 scripts/ra-vqa-inventory.py [--mix MAIN.MIX] [--out inventory.json] [--all-mixes]
"""

import argparse
import json
import os
import struct
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

KNOWN_SIGNATURES = {
    (320, 200, 2): "LOGO",
    (320, 200, 1456): "ENGLISH",
    (320, 156, 90): "PROLOG",
    (320, 156, 150): "AFTRMATH",
    (320, 156, 160): "ALLIES1",
    (320, 156, 170): "ALLIES2",
    (320, 156, 180): "SOVS1",
    (320, 156, 148): "ANTS",
    (320, 156, 183): "NUKESTOK",
    (320, 156, 117): "FLARE",
}


def scan_vqa_blobs(data: bytes) -> list[tuple[int, int, bytes]]:
    """Return list of (offset, chunk_size, blob) for each FORM+WVQA found."""
    results = []
    i = 0
    while i < len(data) - 12:
        if data[i : i + 4] == b"FORM" and data[i + 8 : i + 12] == b"WVQA":
            size = struct.unpack_from(">I", data, i + 4)[0]
            blob = data[i : i + 8 + size]
            results.append((i, size, blob))
            i += 8 + size
        else:
            i += 1
    return results


def parse_vqhd(blob: bytes) -> dict | None:
    """Parse VQHD header from VQA blob."""
    if blob[:4] != b"FORM" or blob[8:12] != b"WVQA":
        return None
    pos = 12
    while pos + 8 <= len(blob):
        tag = blob[pos : pos + 4]
        sz = struct.unpack_from(">I", blob, pos + 4)[0]
        body = blob[pos + 8 : pos + 8 + sz]
        if tag == b"VQHD":
            version, flags, numFrames, width, height = struct.unpack_from(
                "<HHHHH", body, 0
            )
            blockW, blockH, fps, cbParts = struct.unpack_from("<BBBB", body, 10)
            if blockW == 0:
                blockW = 4
            if blockH == 0:
                blockH = 2
            freq = struct.unpack_from("<H", body, 24)[0] if len(body) >= 27 else 22050
            channels, bits = (
                struct.unpack_from("<BB", body, 26) if len(body) >= 27 else (1, 16)
            )
            return {
                "version": version,
                "flags": flags,
                "numFrames": numFrames,
                "width": width,
                "height": height,
                "fps": fps,
                "blockW": blockW,
                "blockH": blockH,
                "cbParts": cbParts or 1,
                "freq": freq,
                "channels": channels,
                "bits": bits,
            }
        pos += 8 + sz + (sz & 1)
    return None


def signature_key(hdr: dict) -> tuple:
    return (hdr["width"], hdr["height"], hdr["numFrames"])


def name_vqa(hdr: dict) -> str:
    sig = signature_key(hdr)
    return KNOWN_SIGNATURES.get(sig, f"VQA_{hdr['width']}x{hdr['height']}_{hdr['numFrames']}f")


def de_duplicate(blobs):
    """De-duplicate VQA blobs: keep first occurrence of each (w,h,frames) signature."""
    seen = {}
    unique = []
    for offset, raw_size, blob in blobs:
        hdr = parse_vqhd(blob)
        if hdr is None:
            continue
        sig = signature_key(hdr)
        if sig not in seen:
            seen[sig] = True
            unique.append((offset, raw_size, blob, hdr))
    return unique


def main():
    ap = argparse.ArgumentParser(description="RA VQA cinematic inventory")
    ap.add_argument(
        "--mix",
        default="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX",
        help="Path to MAIN.MIX",
    )
    ap.add_argument("--out", default=None, help="Output JSON file")
    ap.add_argument(
        "--all-mixes",
        action="store_true",
        help="Scan all MIX files in CD1 directory",
    )
    ap.add_argument("--extract-dir", default=None, help="Extract unique VQAs to directory")
    args = ap.parse_args()

    mix_files = [args.mix]
    if args.all_mixes:
        cd1_dir = os.path.dirname(args.mix)
        for f in sorted(os.listdir(cd1_dir)):
            fp = os.path.join(cd1_dir, f)
            if f.endswith(".MIX") and os.path.isfile(fp) and fp != args.mix:
                mix_files.append(fp)

    all_blobs = []
    for mix_path in mix_files:
        if not os.path.exists(mix_path):
            print(f"SKIP: {mix_path} not found", file=sys.stderr)
            continue
        fname = os.path.basename(mix_path)
        with open(mix_path, "rb") as f:
            data = f.read()
        blobs = scan_vqa_blobs(data)
        print(f"{fname}: {len(blobs)} VQA blobs ({len(data):,} bytes)", file=sys.stderr)
        all_blobs.extend(blobs)

    print(f"Total raw blobs: {len(all_blobs)}", file=sys.stderr)

    unique = de_duplicate(all_blobs)
    print(f"Unique VQAs (de-duplicated): {len(unique)}\n", file=sys.stderr)

    inventory = []
    for idx, (offset, raw_size, blob, hdr) in enumerate(unique):
        name = name_vqa(hdr)
        has_audio = bool(hdr["flags"] & 1)
        duration_s = hdr["numFrames"] / hdr["fps"] if hdr["fps"] > 0 else 0
        entry = {
            "index": idx,
            "name": name,
            "width": hdr["width"],
            "height": hdr["height"],
            "fps": hdr["fps"],
            "numFrames": hdr["numFrames"],
            "duration_s": round(duration_s, 1),
            "hasAudio": has_audio,
            "audioFreq": hdr.get("freq", 22050) if has_audio else 0,
            "audioChannels": hdr.get("channels", 1) if has_audio else 0,
            "audioBits": hdr.get("bits", 16) if has_audio else 0,
            "rawSize": raw_size,
            "blockW": hdr["blockW"],
            "blockH": hdr["blockH"],
            "cbParts": hdr["cbParts"],
        }
        inventory.append(entry)
        audio_str = ""
        if has_audio:
            audio_str = f" audio={hdr['freq']}Hz {hdr['channels']}ch {hdr['bits']}bit"
        print(
            f"  [{idx:2d}] {name:30s} {hdr['width']}x{hdr['height']}  "
            f"{hdr['fps']:2d}fps  {hdr['numFrames']:5d}frames  {duration_s:6.1f}s{audio_str}",
            file=sys.stderr,
        )

    known_count = sum(1 for e in inventory if not e["name"].startswith("VQA_"))
    print(f"\nKnown cinematics: {known_count}/{len(inventory)}", file=sys.stderr)

    if args.extract_dir:
        os.makedirs(args.extract_dir, exist_ok=True)
        for idx, (_, _, blob, hdr) in enumerate(unique):
            name = name_vqa(hdr)
            out_path = os.path.join(args.extract_dir, f"{name}.vqa")
            with open(out_path, "wb") as f:
                f.write(blob)
        print(f"Extracted {len(unique)} VQAs to {args.extract_dir}", file=sys.stderr)

    if args.out:
        with open(args.out, "w") as f:
            json.dump(
                {"source": args.mix, "total": len(inventory), "cinematics": inventory},
                f,
                indent=2,
            )
        print(f"Inventory written to {args.out}", file=sys.stderr)
    else:
        print(json.dumps(inventory, indent=2))


if __name__ == "__main__":
    main()
