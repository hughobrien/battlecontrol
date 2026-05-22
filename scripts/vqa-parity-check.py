#!/usr/bin/env python3
"""
TIM-919 — Generate VQA golden frames via ffmpeg (RA95 reference proxy)
and compare against our native decoder.

Usage:
  python3 scripts/vqa-parity-check.py <vqa_file> <outdir> [--frames N]
"""

import json
import os
import struct
import subprocess
import sys
import zlib

FFMPEG = "/nix/store/lng0hlv2fklamfc0hc8bify15xn6z8hy-ffmpeg-headless-8.0.1-bin/bin/ffmpeg"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def compute_frame_indices(total_frames, num_extract):
    if num_extract <= 1:
        return [0]
    if num_extract >= total_frames:
        return list(range(total_frames))
    indices = []
    for i in range(num_extract):
        idx = round(i * (total_frames - 1) / (num_extract - 1))
        if idx not in indices:
            indices.append(idx)
    while len(indices) < num_extract:
        for i in range(1, total_frames - 1):
            if i not in indices:
                indices.append(i)
                if len(indices) >= num_extract:
                    break
        break
    return sorted(indices)


def ffmpeg_decode_frame(vqa_path, frame_idx, out_path):
    cmd = [
        FFMPEG, "-y", "-loglevel", "error",
        "-i", vqa_path,
        "-vf", f"select=eq(n\\,{frame_idx})",
        "-vsync", "vfr", "-vframes", "1",
        "-pix_fmt", "rgb24", out_path,
    ]
    ret = subprocess.run(cmd, capture_output=True, timeout=60)
    return ret.returncode == 0 and os.path.exists(out_path) and os.path.getsize(out_path) > 0


def read_png_rgb(path):
    with open(path, "rb") as f:
        data = f.read()
    pos = 8
    w = h = 0
    idat = b""
    while pos < len(data):
        sz = struct.unpack_from(">I", data, pos)[0]
        tag = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + sz]
        if tag == b"IHDR":
            w, h = struct.unpack_from(">II", body, 0)
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
        pos += 12 + sz
    raw = zlib.decompress(idat)
    bpp = 3
    row_sz = 1 + w * bpp
    pixels = bytearray()
    prev_row = bytearray(w * bpp)
    for y in range(h):
        filt = raw[y * row_sz]
        row = bytearray(raw[y * row_sz + 1 : (y + 1) * row_sz])
        if filt == 1:
            for i in range(bpp, len(row)):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif filt == 2:
            for i in range(len(row)):
                row[i] = (row[i] + prev_row[i]) & 0xFF
        elif filt == 3:
            for i in range(len(row)):
                left = row[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                row[i] = (row[i] + ((left + up) // 2)) & 0xFF
        elif filt == 4:
            for i in range(len(row)):
                left = row[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                ul = prev_row[i - bpp] if i >= bpp else 0
                p = left + up - ul
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - ul)
                pr = left if pa <= pb and pa <= pc else (up if pb <= pc else ul)
                row[i] = (row[i] + pr) & 0xFF
        pixels += row
        prev_row = row[:]
    return w, h, pixels


def pixeldiff(path_a, path_b):
    wa, ha, pa = read_png_rgb(path_a)
    wb, hb, pb = read_png_rgb(path_b)
    if wa != wb or ha != hb:
        return None, f"size mismatch: {wa}x{ha} vs {wb}x{hb}"
    n = wa * ha * 3
    diffs = sorted(abs(int(pa[i]) - int(pb[i])) for i in range(n))
    result = {
        "p99": diffs[min(int(n * 0.99), n - 1)],
        "p95": diffs[min(int(n * 0.95), n - 1)],
        "mean": round(sum(diffs) / n, 2),
        "max": diffs[-1],
        "w": wa, "h": ha,
    }
    return result, None


def native_decode_frame(vqa_data, target_frame):
    sys.path.insert(0, SCRIPT_DIR)
    from vqa_decode_verify import decode_vqa as _dec, lcw_decode, be32

    if vqa_data[:4] != b"FORM" or vqa_data[8:12] != b"WVQA":
        return None

    pos = 12
    hdr = {}
    while pos + 8 <= len(vqa_data):
        tag = vqa_data[pos : pos + 4]
        size = be32(vqa_data, pos + 4)
        if tag == b"VQHD":
            body = vqa_data[pos + 8 : pos + 8 + size]
            ver, flags, numFrames, width, height = struct.unpack_from("<HHHHH", body, 0)
            blockW, blockH, fps, cbParts = struct.unpack_from("<BBBB", body, 10)
            numColors, maxBlocks = struct.unpack_from("<HH", body, 14)
            if blockW == 0:
                blockW = 4
            if blockH == 0:
                blockH = 2
            if maxBlocks == 0:
                maxBlocks = 512
            hdr = dict(numFrames=numFrames, width=width, height=height,
                       blockW=blockW, blockH=blockH, cbParts=cbParts or 1,
                       maxBlocks=maxBlocks)
            pos += 8 + size + (size & 1)
            break
        pos += 8 + size + (size & 1)

    if not hdr:
        return None

    vqaW, vqaH = hdr["width"], hdr["height"]
    blockW, blockH = hdr["blockW"], hdr["blockH"]
    cbParts = hdr["cbParts"]
    maxBlocks = hdr["maxBlocks"]
    numFrames = hdr["numFrames"]
    cbEntrySize = blockW * blockH
    codebook_size = 0x10000 * cbEntrySize
    codebook = bytearray(codebook_size)
    for ci in range(256):
        codebook[(0xFF00 + ci) * cbEntrySize : (0xFF00 + ci + 1) * cbEntrySize] = bytes([ci]) * cbEntrySize
        codebook[(0x0F00 + ci) * cbEntrySize : (0x0F00 + ci + 1) * cbEntrySize] = bytes([ci]) * cbEntrySize
    next_codebook_buffer = bytearray(codebook_size)
    next_cb_idx = 0
    partial_countdown = cbParts
    blocksX = vqaW // blockW
    blocksY = vqaH // blockH
    numBlocks = blocksX * blocksY
    palette = bytearray(768)
    framebuf = bytearray(vqaW * vqaH)
    prevbuf = bytearray(vqaW * vqaH)

    if pos + 8 <= len(vqa_data) and vqa_data[pos : pos + 4] == b"FINF":
        sz = be32(vqa_data, pos + 4)
        pos += 8 + sz + (sz & 1)

    frame_num = 0
    AUDIO = {b"SND0", b"SND1", b"SND2"}

    while pos + 8 <= len(vqa_data) and frame_num < numFrames:
        tag = vqa_data[pos : pos + 4]
        size = be32(vqa_data, pos + 4)
        if tag in AUDIO:
            pos += 8 + size + (size & 1)
            continue
        body = vqa_data[pos + 8 : pos + 8 + size]
        pos += 8 + size + (size & 1)
        if tag != b"VQFR":
            continue

        chunks = []
        fp = 0
        while fp + 8 <= size:
            stag = body[fp : fp + 4]
            ssz = be32(body, fp + 4)
            sbody = body[fp + 8 : fp + 8 + ssz]
            fp += 8 + ssz + (ssz & 1)
            chunks.append((stag, ssz, sbody))

        for stag, ssz, sbody in chunks:
            if stag == b"CPL0":
                palette[: min(768, ssz)] = sbody[: min(768, ssz)]

        for stag, ssz, sbody in chunks:
            if stag == b"CBF0":
                rd = min(ssz, codebook_size)
                codebook[:rd] = sbody[:rd]
                next_cb_idx = 0
                partial_countdown = cbParts
            elif stag == b"CBFZ":
                decomp = lcw_decode(sbody, codebook_size)
                codebook[: len(decomp)] = decomp
                next_cb_idx = 0
                partial_countdown = cbParts

        for stag, ssz, sbody in chunks:
            if stag not in (b"VPT0", b"VPTZ", b"VPTR", b"VPRZ"):
                continue
            vpt_raw = sbody
            if stag in (b"VPTZ", b"VPRZ"):
                vpt_raw = lcw_decode(sbody, numBlocks * 2)
            if len(vpt_raw) < numBlocks * 2:
                continue
            prevbuf[:] = framebuf
            for bi in range(numBlocks):
                bx = bi % blocksX
                by = bi // blocksX
                lo = vpt_raw[bi]
                hi = vpt_raw[numBlocks + bi]
                cb_idx = lo | (hi << 8)
                cb_base = cb_idx * cbEntrySize
                dst_base = by * blockH * vqaW + bx * blockW
                if cb_base + cbEntrySize <= codebook_size:
                    for fy in range(blockH):
                        src_off = dst_base + fy * vqaW
                        cb_row = cb_base + fy * blockW
                        framebuf[src_off : src_off + blockW] = codebook[cb_row : cb_row + blockW]

        for stag, ssz, sbody in chunks:
            if stag == b"CBP0":
                needed = min(ssz, codebook_size - next_cb_idx)
                next_codebook_buffer[next_cb_idx : next_cb_idx + needed] = sbody[:needed]
                next_cb_idx += needed
                partial_countdown -= 1
                if partial_countdown <= 0:
                    codebook[:next_cb_idx] = next_codebook_buffer[:next_cb_idx]
                    next_cb_idx = 0
                    partial_countdown = cbParts
            elif stag == b"CBPZ":
                needed = min(ssz, codebook_size - next_cb_idx)
                next_codebook_buffer[next_cb_idx : next_cb_idx + needed] = sbody[:needed]
                next_cb_idx += needed
                partial_countdown -= 1
                if partial_countdown <= 0:
                    decomp = lcw_decode(next_codebook_buffer[:next_cb_idx], codebook_size)
                    codebook[: len(decomp)] = decomp
                    next_cb_idx = 0
                    partial_countdown = cbParts

        if frame_num == target_frame:
            rgb = bytearray(vqaW * vqaH * 3)
            for i in range(vqaW * vqaH):
                pidx = framebuf[i] * 3
                r = palette[pidx]
                r = ((r << 2) & 0xFF) | ((r >> 4) & 0x03)
                g = palette[pidx + 1]
                g = ((g << 2) & 0xFF) | ((g >> 4) & 0x03)
                b = palette[pidx + 2]
                b = ((b << 2) & 0xFF) | ((b >> 4) & 0x03)
                rgb[i * 3] = r
                rgb[i * 3 + 1] = g
                rgb[i * 3 + 2] = b
            return vqaW, vqaH, rgb

        frame_num += 1

    return None


def write_rgb_png(path, pixels, w, h):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pixels[y * w * 3 : (y + 1) * w * 3]
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", compressed)
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def parse_vqhd_fast(path):
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


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    vqa_path = sys.argv[1]
    outdir = sys.argv[2]
    num_frames = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    hdr = parse_vqhd_fast(vqa_path)
    if hdr is None:
        print(f"ERROR: not a VQA: {vqa_path}", file=sys.stderr)
        sys.exit(2)

    total = hdr["numFrames"]
    indices = compute_frame_indices(total, num_frames)
    os.makedirs(outdir, exist_ok=True)

    stem = os.path.splitext(os.path.basename(vqa_path))[0]
    print(f"{stem}: {total} frames, indices: {indices}")

    with open(vqa_path, "rb") as f:
        vqa_data = f.read()

    results = []
    for i, frame_idx in enumerate(indices):
        # ffmpeg reference
        ref_path = os.path.join(outdir, f"ref_{i + 1:04d}.png")
        ok = ffmpeg_decode_frame(vqa_path, frame_idx, ref_path)
        if not ok:
            results.append({"frame": frame_idx, "error": "ffmpeg decode failed"})
            print(f"  frame {frame_idx}: ffmpeg FAIL")
            continue

        # native decoder
        native_result = native_decode_frame(vqa_data, frame_idx)
        if native_result is None:
            results.append({"frame": frame_idx, "error": "native decode failed"})
            print(f"  frame {frame_idx}: native FAIL")
            continue

        nw, nh, npx = native_result
        nat_path = os.path.join(outdir, f"nat_{i + 1:04d}.png")
        write_rgb_png(nat_path, npx, nw, nh)

        diff, err = pixeldiff(nat_path, ref_path)
        if err:
            results.append({"frame": frame_idx, "error": err})
            print(f"  frame {frame_idx}: diff FAIL - {err}")
            continue

        results.append({
            "frame": frame_idx,
            "p99": diff["p99"],
            "p95": diff["p95"],
            "mean": diff["mean"],
            "max": diff["max"],
            "pass": diff["p99"] <= 8,
        })
        status = "PASS" if diff["p99"] <= 8 else "FAIL"
        print(f"  frame {frame_idx}: p99={diff['p99']} p95={diff['p95']} mean={diff['mean']} max={diff['max']} [{status}]")

    manifest = {
        "file": os.path.basename(vqa_path),
        "total_frames": total,
        "num_golden": len(indices),
        "results": results,
        "all_pass": all(r.get("pass", False) for r in results),
    }
    manifest_path = os.path.join(outdir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    failed = [r for r in results if not r.get("pass", False)]
    passed = [r for r in results if r.get("pass", False)]
    print(f"\n{stem}: {len(passed)}/{len(results)} pass, {len(failed)} fail")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
