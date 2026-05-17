#!/usr/bin/env python3
"""
Generate golden reference frames from VQA files for parity comparison.

Decodes a VQA file and saves 4 evenly-spaced frames as PNGs in the golden
directory.  These are the ground truth for the three-way comparison:
ra95/wine, battlecontrol/xwindows, battlecontrol/wasm.

The decoder matches vqa_player.cpp and is already validated against ffmpeg
via vqa-pixel-diff.py (ci.yml gate).

Usage:
  python3 scripts/gen-vqa-golden.py <vqa_file> <outdir> [--frames N]

  python3 scripts/gen-vqa-golden.py \
      /data/RED_ALERT/CD1/MAIN.MIX/ENGLISH.VQA \
      e2e/goldens/vqa/ENGLISH
      --frames 4

Output:
  e2e/goldens/vqa/ENGLISH/
    frame_0001.png    first frame
    frame_00NN.png    evenly-spaced frames
    manifest.json     { "file": "ENGLISH.VQA", "total_frames": NN, "extracted": [...] }
"""

import sys
import os
import json
import struct

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from vqa_decode_verify import decode_vqa


def compute_frame_indices(total_frames, num_extract):
    if num_extract <= 1:
        return [0]
    if num_extract >= total_frames:
        return list(range(total_frames))
    step = (total_frames - 1) / (num_extract - 1)
    indices = []
    for i in range(num_extract):
        idx = round(i * step)
        if idx >= total_frames:
            idx = total_frames - 1
        if idx not in indices:
            indices.append(idx)
    if len(indices) < num_extract:
        need = num_extract - len(indices)
        for i in range(1, total_frames - 1):
            if i not in indices:
                indices.append(i)
                need -= 1
                if need == 0:
                    break
        indices.sort()
    return indices


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    vqa_path = sys.argv[1]
    outdir = sys.argv[2]
    num_frames = 4
    if len(sys.argv) > 3:
        num_frames = int(sys.argv[3])

    if not os.path.isfile(vqa_path):
        print(f"ERROR: {vqa_path} not found", file=sys.stderr)
        sys.exit(2)

    os.makedirs(outdir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(vqa_path))[0]

    # Read VQHD header to get total frame count
    with open(vqa_path, 'rb') as f:
        data = f.read()

    if data[:4] != b'FORM' or data[8:12] != b'WVQA':
        print(f"ERROR: {vqa_path} is not a WVQA file", file=sys.stderr)
        sys.exit(2)

    pos = 12
    total_frames = 0
    while pos + 8 <= len(data):
        tag = data[pos:pos+4]
        chunk_size = struct.unpack_from('>I', data, pos+4)[0]
        body = data[pos+8:pos+8+chunk_size]
        npos = pos + 8 + chunk_size + (chunk_size & 1)
        if tag == b'VQHD':
            total_frames = struct.unpack_from('<H', body, 4)[0]
            break
        pos = npos

    if total_frames == 0:
        print(f"ERROR: could not determine frame count for {vqa_path}", file=sys.stderr)
        sys.exit(2)

    indices = compute_frame_indices(total_frames, num_frames)
    actual_num = min(num_frames, total_frames)

    print(f"{stem}.VQA: {total_frames} total frames, extracting {actual_num}: {indices}")

    frames_to_dump = set(indices)
    decode_vqa(vqa_path, outdir, frames_to_dump=frames_to_dump)

    # Rename frames to canonical names
    extracted = []
    for i, idx in enumerate(indices):
        src = os.path.join(outdir, f"live_frame_{idx+1:03d}.png")
        dst = os.path.join(outdir, f"frame_{i+1:04d}.png")
        if os.path.isfile(src):
            os.rename(src, dst)
            extracted.append({"index": i, "frame_num": idx + 1, "path": dst})

    # Rename raw frames too
    for i, idx in enumerate(indices):
        src = os.path.join(outdir, f"live_raw_{idx+1:03d}.png")
        dst = os.path.join(outdir, f"raw_{i+1:04d}.png")
        if os.path.isfile(src):
            os.rename(src, dst)

    # Clean up stray live_* files
    for f in os.listdir(outdir):
        if f.startswith("live_frame_") or f.startswith("live_raw_"):
            os.remove(os.path.join(outdir, f))

    manifest = {
        "file": os.path.basename(vqa_path),
        "total_frames": total_frames,
        "extracted": extracted,
    }
    manifest_path = os.path.join(outdir, "manifest.json")
    with open(manifest_path, 'w') as mf:
        json.dump(manifest, mf, indent=2)
    print(f"  manifest -> {manifest_path}")

    print(f"Done: {len(extracted)} golden frames written to {outdir}")


if __name__ == '__main__':
    main()
