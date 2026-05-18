#!/usr/bin/env python3
"""
Extract VQA from MIX and decode with specified engine.

Usage:
  python3 scripts/vqa-decode.py --engine={ffmpeg,native} --vqa=ENGLISH --mix=MAIN.MIX --out=/tmp/out

Output:
  <out>/frame_%04d.ppm    (PPM frames)
  <out>/audio.wav          (WAV audio)
  <out>/audio.pcm          (raw PCM)
  <out>/metadata.json      (decode params)
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile


# ---------------------------------------------------------------------------
# MIX scanning — same FORM+WVQA magic scan as cinematic-compare.py
# ---------------------------------------------------------------------------


def scan_for_vqas(data: bytes) -> list[tuple[int, bytes]]:
    """Scan bytes for FORM+WVQA magic, return list of (offset, blob)."""
    results = []
    search_start = 0
    while True:
        # Find next FORM tag
        idx = data.find(b"FORM", search_start)
        if idx < 0 or idx + 12 > len(data):
            break
        if data[idx + 8 : idx + 12] == b"WVQA":
            size = struct.unpack_from(">I", data, idx + 4)[0]
            blob = data[idx : idx + 8 + size]
            results.append((idx, blob))
            search_start = idx + 8 + size
        else:
            search_start = idx + 4
    return results


def parse_vqhd(data: bytes) -> dict | None:
    """Parse VQHD header from VQA data blob."""
    if data[:4] != b"FORM" or data[8:12] != b"WVQA":
        return None
    pos = 12
    while pos + 8 <= len(data):
        tag = data[pos : pos + 4]
        size = struct.unpack_from(">I", data, pos + 4)[0]
        body = data[pos + 8 : pos + 8 + size]
        if tag == b"VQHD":
            # VQHD layout: ver(2) flags(2) numFrames(2) width(2) height(2)
            # blockW(1) blockH(1) fps(1) cbParts(1) numColors(2) maxBlocks(2)
            # ... freq(2) channels(1) bits(1)
            version, flags, numFrames, width, height = struct.unpack_from(
                "<HHHHH", body, 0
            )
            blockW, blockH, fps, cbParts = struct.unpack_from("<BBBB", body, 10)
            # Audio params at offset 22-27
            freq = struct.unpack_from("<H", body, 24)[0] if len(body) >= 27 else 22050
            channels, bits = (
                struct.unpack_from("<BB", body, 26) if len(body) >= 27 else (1, 16)
            )
            if blockW == 0:
                blockW = 4
            if blockH == 0:
                blockH = 2
            return {
                "numFrames": numFrames,
                "width": width,
                "height": height,
                "fps": fps,
                "cbParts": cbParts or 1,
                "flags": flags,
                "freq": freq,
                "channels": channels,
                "bits": bits,
            }
        pos += 8 + size + (size & 1)
    return None


# Known VQA names by (width, height, frame_count) signature.
# These are embedded in RA's MAIN.MIX and identified by cinematic-compare.py.
VQA_SIGNATURES = {
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


def find_vqa_by_name(results: list[tuple[int, bytes]], name: str) -> bytes | None:
    """Find VQA blob matching the given name."""
    lc_name = name.upper().replace(".VQA", "")

    for idx, (_, blob) in enumerate(results):
        hdr = parse_vqhd(blob)
        if hdr:
            sig = (hdr["width"], hdr["height"], hdr["numFrames"])
            matched_name = VQA_SIGNATURES.get(sig, None)
            if matched_name and matched_name == lc_name:
                return blob

    # Fallback: return by index
    try:
        idx = int(name)
        if 0 <= idx < len(results):
            return results[idx][1]
    except ValueError:
        pass

    # Return the first VQA as "intro"
    if lc_name in ("INTRO", "FIRST", "1"):
        if results:
            return results[0][1]

    return None


# ---------------------------------------------------------------------------
# Engine implementations
# ---------------------------------------------------------------------------


def decode_ffmpeg(vqa_path: str, out_dir: str, max_seconds: float):
    """Decode VQA using ffmpeg."""
    os.makedirs(out_dir, exist_ok=True)

    # Extract frames as PPM (uses native VQA framerate)
    frame_pattern = os.path.join(out_dir, "frame_%04d.ppm")
    subprocess.run(
        [
            "ffmpeg",
            "-i",
            vqa_path,
            "-t",
            str(max_seconds),
            frame_pattern,
            "-y",
            "-loglevel",
            "error",
        ],
        check=True,
    )

    # Extract audio as WAV
    wav_path = os.path.join(out_dir, "audio.wav")
    pcm_path = os.path.join(out_dir, "audio.pcm")
    subprocess.run(
        [
            "ffmpeg",
            "-i",
            vqa_path,
            "-t",
            str(max_seconds),
            "-acodec",
            "pcm_s16le",
            wav_path,
            "-y",
            "-loglevel",
            "error",
        ],
        check=True,
    )

    # Also extract raw PCM for easy comparison
    subprocess.run(
        [
            "ffmpeg",
            "-i",
            vqa_path,
            "-t",
            str(max_seconds),
            "-acodec",
            "pcm_s16le",
            "-f",
            "s16le",
            pcm_path,
            "-y",
            "-loglevel",
            "error",
        ],
        check=True,
    )

    # Write metadata
    hdr = parse_vqhd(open(vqa_path, "rb").read())
    if hdr:
        meta = {
            "engine": "ffmpeg",
            "width": hdr["width"],
            "height": hdr["height"],
            "fps": hdr["fps"],
            "numFrames": hdr["numFrames"],
            "hasAudio": bool(hdr["flags"] & 1),
            "audioFreq": hdr["freq"],
            "audioChannels": hdr["channels"],
            "audioBits": hdr["bits"],
        }
        with open(os.path.join(out_dir, "metadata.json"), "w") as f:
            json.dump(meta, f, indent=2)


def decode_native(vqa_path: str, out_dir: str, max_seconds: float):
    """Decode VQA using the standalone C++ decoder."""
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(
        [
            "vqa_dump",
            vqa_path,
            out_dir,
            "--duration",
            str(max_seconds),
        ],
        check=True,
    )
    # Tag metadata with engine name
    meta_path = os.path.join(out_dir, "metadata.json")
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            meta = json.load(f)
        meta["engine"] = "native"
        with open(meta_path, "w") as f:
            json.dump(meta, f, indent=2)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="Decode VQA from MIX file")
    ap.add_argument(
        "--engine", required=True, choices=["ffmpeg", "native"], help="Decoder engine"
    )
    ap.add_argument(
        "--vqa",
        required=True,
        help="VQA name (e.g., ENGLISH, LOGO) or 0-indexed position",
    )
    ap.add_argument("--mix", required=True, help="Path to MIX file containing VQAs")
    ap.add_argument("--out", required=True, help="Output directory")
    ap.add_argument(
        "--duration",
        type=float,
        default=20.0,
        help="Max seconds to decode (default: 20)",
    )
    args = ap.parse_args()

    # Read MIX file
    with open(args.mix, "rb") as f:
        mix_data = f.read()

    # Scan for VQAs
    results = scan_for_vqas(mix_data)
    if not results:
        print(f"ERROR: no VQAs found in {args.mix}", file=sys.stderr)
        return 1

    print(f"Found {len(results)} VQAs in {args.mix}", file=sys.stderr)

    # Find target VQA
    blob = find_vqa_by_name(results, args.vqa)
    if blob is None:
        print(f"ERROR: VQA '{args.vqa}' not found in {args.mix}", file=sys.stderr)
        names = sorted(set(VQA_SIGNATURES.values()))
        print(f"  Known names: {', '.join(names)}", file=sys.stderr)
        return 1

    # Extract to temp file
    tmpdir = tempfile.mkdtemp(prefix="vqa_decode_")
    vqa_path = os.path.join(tmpdir, "input.vqa")
    with open(vqa_path, "wb") as f:
        f.write(blob)

    hdr = parse_vqhd(blob)
    if hdr:
        print(
            f"VQA: {hdr['width']}x{hdr['height']} {hdr['fps']}fps "
            f"{hdr['numFrames']} frames audio={bool(hdr['flags'] & 1)}",
            file=sys.stderr,
        )

    # Decode
    os.makedirs(args.out, exist_ok=True)

    if args.engine == "ffmpeg":
        decode_ffmpeg(vqa_path, args.out, args.duration)
    elif args.engine == "native":
        decode_native(vqa_path, args.out, args.duration)

    # Cleanup
    os.unlink(vqa_path)
    os.rmdir(tmpdir)

    # Report
    frames = sorted(f for f in os.listdir(args.out) if f.endswith(".ppm"))
    audio_info = ""
    if os.path.exists(os.path.join(args.out, "audio.pcm")):
        sz = os.path.getsize(os.path.join(args.out, "audio.pcm"))
        audio_info = f", {sz // 2} audio samples"
    print(f"Decoded {len(frames)} frames{audio_info} → {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
