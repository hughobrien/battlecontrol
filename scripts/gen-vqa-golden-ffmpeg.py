#!/usr/bin/env python3
"""
TIM-919 — Generate VQA golden frames using ffmpeg as reference.

Usage:
  python3 scripts/gen-vqa-golden-ffmpeg.py <vqa_file> <outdir> [--frames N]
"""

import json
import os
import struct
import subprocess
import sys

FFMPEG = (
    "/nix/store/lng0hlv2fklamfc0hc8bify15xn6z8hy-ffmpeg-headless-8.0.1-bin/bin/ffmpeg"
)


def parse_vqhd(path):
    with open(path, "rb") as f:
        data = f.read(1024)
    if data[:4] != b"FORM" or data[8:12] != b"WVQA":
        return None
    pos = 12
    while pos + 8 <= len(data):
        tag = data[pos : pos + 4]
        sz = struct.unpack_from(">I", data, pos + 4)[0]
        body = data[pos + 8 : pos + 8 + sz]
        if tag == b"VQHD":
            numFrames = struct.unpack_from("<H", body, 4)[0]
            width = struct.unpack_from("<H", body, 6)[0]
            height = struct.unpack_from("<H", body, 8)[0]
            fps = struct.unpack_from("<B", body, 12)[0]
            return dict(numFrames=numFrames, width=width, height=height, fps=fps)
        pos += 8 + sz + (sz & 1)
    return None


def compute_indices(total, n):
    if n <= 1:
        return [0]
    if n >= total:
        return list(range(total))
    idxs = [round(i * (total - 1) / (n - 1)) for i in range(n)]
    return sorted(set(idxs))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    vqa_path = sys.argv[1]
    outdir = sys.argv[2]
    num = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    hdr = parse_vqhd(vqa_path)
    if hdr is None:
        print(f"ERROR: not a VQA: {vqa_path}", file=sys.stderr)
        sys.exit(2)

    indices = compute_indices(hdr["numFrames"], num)
    os.makedirs(outdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(vqa_path))[0]

    print(f"{stem}: {hdr['numFrames']} frames, indices={indices}")

    extracted = []
    for i, frame_idx in enumerate(indices):
        out_path = os.path.join(outdir, f"frame_{i + 1:04d}.png")
        cmd = [
            FFMPEG,
            "-y",
            "-loglevel",
            "error",
            "-i",
            vqa_path,
            "-vf",
            f"select=eq(n\\,{frame_idx})",
            "-vsync",
            "vfr",
            "-vframes",
            "1",
            "-pix_fmt",
            "rgb24",
            out_path,
        ]
        result = subprocess.run(cmd, capture_output=True, timeout=60)
        if result.returncode != 0 or not os.path.exists(out_path):
            print(f"  frame {frame_idx}: ffmpeg FAILED", file=sys.stderr)
            continue
        extracted.append(
            {"index": i, "frame_num": frame_idx + 1, "path": f"frame_{i + 1:04d}.png"}
        )

    manifest = {
        "file": os.path.basename(vqa_path),
        "total_frames": hdr["numFrames"],
        "width": hdr["width"],
        "height": hdr["height"],
        "fps": hdr["fps"],
        "engine": "ffmpeg",
        "extracted": extracted,
    }
    manifest_path = os.path.join(outdir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"  → {len(extracted)} golden frames in {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
