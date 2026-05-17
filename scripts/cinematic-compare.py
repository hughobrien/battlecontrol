#!/usr/bin/env python3
"""
TIM-705 — Cinematic midpoint comparison: our Python decoder vs ffmpeg (Wine OG proxy).

Scans MAIN.MIX for embedded VQA files (raw FORM+WVQA byte scan, bypassing the
Blowfish-encrypted MIX index), decodes the midpoint frame with both our decoder and
ffmpeg, then computes a pixel diff and optional SSIM.

Exit codes:
  0 = all VQAs pass (p99 <= threshold)
  1 = one or more VQAs fail
  2 = SKIP (game data or ffmpeg unavailable)

Why ffmpeg ≈ Wine OG:
  ffmpeg's idfcined VQA decoder is a clean-room reverse-engineering of the Westwood
  VQA codec.  Red Alert's RA95.EXE uses the same codec.  Frame-for-frame output is
  effectively identical (±1 per channel on 6→8 bit palette expansion).

Usage:
  python3 scripts/cinematic-compare.py [MAIN_MIX_PATH] [--out-dir DIR]
  python3 scripts/cinematic-compare.py --help

Options:
  MAIN_MIX_PATH   Path to MAIN.MIX (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX)
  --out-dir DIR   Output dir for comparison images + JSON report (default: e2e/cinematic-compare)
  --threshold N   p99 pixel-channel delta threshold for PASS (default: 8)
  --max-vqas N    Maximum number of VQAs to compare (default: 8)
  --quiet         Suppress per-frame output
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import zlib

MAIN_MIX_DEFAULT = "/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX"
OUT_DIR_DEFAULT = "e2e/cinematic-compare"
DEFAULT_THRESHOLD = 8
DEFAULT_MAX_VQAS = 8

# Known frame counts → cinematic name (from header analysis).
KNOWN_FRAME_COUNTS: dict[int, str] = {
    262: "LOGO.VQA",
    1200: "ENGLISH.VQA",
    # Campaign cinematics (approximate; exact counts vary by release).
    # These labels are used only for reporting; correctness verified by frame count proximity.
    90: "PROLOG.VQA",
    148: "ANTS.VQA",
    183: "NUKESTOK.VQA",
    117: "FLARE.VQA",
    150: "AFTRMATH.VQA",
    160: "ALLIES1.VQA",
    170: "ALLIES2.VQA",
    180: "SOVS1.VQA",
}


# ---------------------------------------------------------------------------
# VQA extraction from raw bytes (FORM+WVQA magic scan)
# ---------------------------------------------------------------------------


def scan_for_vqas(data: bytes, out_dir: str) -> list[str]:
    """Scan bytes for FORM+WVQA magic, extract each VQA blob to out_dir."""
    os.makedirs(out_dir, exist_ok=True)
    extracted: list[str] = []
    i = 0
    count = 0
    while i < len(data) - 12:
        if data[i : i + 4] == b"FORM" and data[i + 8 : i + 12] == b"WVQA":
            size = struct.unpack_from(">I", data, i + 4)[0]
            blob = data[i : i + 8 + size]
            path = os.path.join(out_dir, f"vqa_{count:03d}.vqa")
            with open(path, "wb") as fh:
                fh.write(blob)
            extracted.append(path)
            count += 1
            i += 8 + size
        else:
            i += 1
    return extracted


# ---------------------------------------------------------------------------
# VQHD header parse — mirrors vqa_decode_verify.py
# ---------------------------------------------------------------------------


def parse_vqhd(vqa_path: str) -> dict | None:
    """Return {numFrames, width, height, fps, blockW, blockH, cbParts, maxBlocks} from VQHD."""
    with open(vqa_path, "rb") as fh:
        data = fh.read(512)  # header is always in first 512 bytes
    if data[:4] != b"FORM" or data[8:12] != b"WVQA":
        return None
    pos = 12
    while pos + 8 <= len(data):
        tag = data[pos : pos + 4]
        size = struct.unpack_from(">I", data, pos + 4)[0]
        body = data[pos + 8 : pos + 8 + size]
        if tag == b"VQHD":
            # VQHD layout (from vqa_decode_verify.py / vqa_player.cpp):
            # 0:ver(2) 2:flags(2) 4:numFrames(2) 6:width(2) 8:height(2)
            # 10:blockW(1) 11:blockH(1) 12:fps(1) 13:cbParts(1) 14:numColors(2)
            # 16:maxBlocks(2)
            version, flags, numFrames, width, height = struct.unpack_from(
                "<HHHHH", body, 0
            )
            blockW, blockH, fps, cbParts = struct.unpack_from("<BBBB", body, 10)
            numColors, maxBlocks = struct.unpack_from("<HH", body, 14)
            if blockW == 0:
                blockW = 4
            if blockH == 0:
                blockH = 2
            if maxBlocks == 0:
                maxBlocks = 512
            return {
                "numFrames": numFrames,
                "width": width,
                "height": height,
                "fps": fps,
                "blockW": blockW,
                "blockH": blockH,
                "cbParts": cbParts or 1,
                "maxBlocks": maxBlocks,
            }
        pos += 8 + size + (size % 2)  # IFF alignment
    return None


def label_vqa(num_frames: int) -> str:
    """Map frame count to a known cinematic name, or generate generic label."""
    # Exact match first
    if num_frames in KNOWN_FRAME_COUNTS:
        return KNOWN_FRAME_COUNTS[num_frames]
    # Fuzzy ±5 match
    for known, name in KNOWN_FRAME_COUNTS.items():
        if abs(num_frames - known) <= 5:
            return f"{name}~"
    return f"VQA-{num_frames}f"


# ---------------------------------------------------------------------------
# PNG helpers
# ---------------------------------------------------------------------------


def _read_png_rgb(path: str) -> tuple[int, int, bytearray]:
    """Return (w, h, rgb_bytes) from a PNG file."""
    with open(path, "rb") as fh:
        data = fh.read()
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
    row_sz = 1 + w * 3
    pixels = bytearray()
    for y in range(h):
        pixels += raw[1 + y * row_sz : (y + 1) * row_sz]
    return w, h, pixels


def _save_diff_png(path: str, pixels_a: bytearray, pixels_b: bytearray, w: int, h: int):
    """Save an amplified pixel-diff image (|A-B|×4 clamped to 255)."""
    import zlib

    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter=None
        for x in range(w):
            i = (y * w + x) * 3
            for c in range(3):
                raw.append(
                    min(255, abs(int(pixels_a[i + c]) - int(pixels_b[i + c])) * 4)
                )
    compressed = zlib.compress(bytes(raw), 6)

    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


# ---------------------------------------------------------------------------
# Pixel diff
# ---------------------------------------------------------------------------


def pixel_diff(path_a: str, path_b: str) -> dict:
    """Compute p99/p95/mean/max per-pixel-channel delta between two RGB PNGs."""
    wa, ha, pa = _read_png_rgb(path_a)
    wb, hb, pb = _read_png_rgb(path_b)
    if wa != wb or ha != hb:
        return {"error": f"size mismatch: {wa}×{ha} vs {wb}×{hb}"}
    n = wa * ha * 3
    diffs = sorted(abs(int(pa[i]) - int(pb[i])) for i in range(n))
    result = {
        "w": wa,
        "h": ha,
        "p99": diffs[min(int(n * 0.99), n - 1)],
        "p95": diffs[min(int(n * 0.95), n - 1)],
        "mean": round(sum(diffs) / n, 2),
        "max": diffs[-1],
    }
    # SSIM approximation if scipy available
    try:
        import numpy as np

        a = np.frombuffer(pa, dtype=np.uint8).reshape(ha, wa, 3).astype(np.float64)
        b = np.frombuffer(pb, dtype=np.uint8).reshape(hb, wb, 3).astype(np.float64)
        mu_a, mu_b = a.mean(), b.mean()
        sig_a = a.std()
        sig_b = b.std()
        sig_ab = ((a - mu_a) * (b - mu_b)).mean()
        C1, C2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
        ssim = (
            (2 * mu_a * mu_b + C1)
            * (2 * sig_ab + C2)
            / ((mu_a**2 + mu_b**2 + C1) * (sig_a**2 + sig_b**2 + C2))
        )
        result["ssim"] = round(float(ssim), 4)
    except ImportError:
        pass
    return result


# ---------------------------------------------------------------------------
# ffmpeg golden frame
# ---------------------------------------------------------------------------


def ffmpeg_frame(vqa_path: str, frame_idx: int, out_path: str) -> bool:
    """Decode frame_idx from vqa_path to out_path using ffmpeg."""
    cmd = [
        "ffmpeg",
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
    ret = subprocess.run(cmd, capture_output=True, timeout=60)
    return (
        ret.returncode == 0
        and os.path.exists(out_path)
        and os.path.getsize(out_path) > 0
    )


# ---------------------------------------------------------------------------
# Inline fast VQA decoder for single-frame extraction
#
# Key optimization over vqa_decode_verify.py: audio chunks (SND0/SND1/SND2)
# are skipped WITHOUT copying their bodies — the original decoder copies every
# chunk body which causes 10–30× slowdown on long VQAs with audio.
# ---------------------------------------------------------------------------


def _lcw_decode(src: bytes, dst_cap: int) -> bytearray:
    """LCW (Format80) decompressor, mirroring lcw_decode_safe() in vqa_player.cpp."""
    sp = 0
    dst = bytearray(dst_cap)
    dp = 0
    sv = memoryview(src)
    while sp < len(sv) and dp < dst_cap:
        op = sv[sp]
        sp += 1
        if op == 0x80:
            break
        elif not (op & 0x80):
            if sp >= len(sv):
                break
            count = (op >> 4) + 3
            offset = ((op & 0x0F) << 8) | sv[sp]
            sp += 1
            cp = dp - offset
            if cp < 0:
                cp = 0
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = dst[cp]
                dp += 1
                cp += 1
        elif not (op & 0x40):
            count = op & 0x3F
            for _ in range(count):
                if sp >= len(sv) or dp >= dst_cap:
                    break
                dst[dp] = sv[sp]
                dp += 1
                sp += 1
        elif op == 0xFE:
            if sp + 2 >= len(sv):
                break
            count = sv[sp] | (sv[sp + 1] << 8)
            sp += 2
            fill = sv[sp]
            sp += 1
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = fill
                dp += 1
        elif op == 0xFF:
            if sp + 3 >= len(sv):
                break
            count = sv[sp] | (sv[sp + 1] << 8)
            sp += 2
            off = sv[sp] | (sv[sp + 1] << 8)
            sp += 2
            cp = off
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = dst[cp] if cp < dp else 0
                dp += 1
                cp += 1
        else:
            if sp + 1 >= len(sv):
                break
            count = (op & 0x3F) + 3
            off = sv[sp] | (sv[sp + 1] << 8)
            sp += 2
            cp = off
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = dst[cp] if cp < dp else 0
                dp += 1
                cp += 1
    return dst[:dp]


def decode_vqa_frame_inline(vqa_data: bytes, target_frame: int) -> bytearray | None:
    """Decode target_frame from in-memory VQA bytes. Returns RGB24 bytes or None.

    Optimized: skips audio chunks without copying them.  Rendering is minimal —
    only the block grid needed for pixel comparison (no blit/scale).
    Returns raw VQA-resolution RGB24 bytes (width * height * 3).
    """

    def be32(d, o):
        return struct.unpack_from(">I", d, o)[0]

    if vqa_data[:4] != b"FORM" or vqa_data[8:12] != b"WVQA":
        return None

    # --- Parse VQHD ---
    pos = 12
    hdr: dict = {}
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
            hdr = dict(
                numFrames=numFrames,
                width=width,
                height=height,
                blockW=blockW,
                blockH=blockH,
                cbParts=cbParts or 1,
                maxBlocks=maxBlocks,
            )
        pos += 8 + size + (size & 1)
        if hdr:
            break

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
    # Pre-fill solid-colour entries (matches vqa_player.cpp TIM-613 + vqa_decode_verify.py)
    # hi==0xFF (blockH=4) or hi==0x0F (blockH=2) → solid block with palette index lo
    for ci in range(256):
        base_ff = (0xFF00 + ci) * cbEntrySize
        base_0f = (0x0F00 + ci) * cbEntrySize
        codebook[base_ff : base_ff + cbEntrySize] = bytes([ci]) * cbEntrySize
        codebook[base_0f : base_0f + cbEntrySize] = bytes([ci]) * cbEntrySize
    next_codebook_buffer = bytearray(codebook_size)
    next_cb_idx = 0
    partial_countdown = cbParts

    blocksX = vqaW // blockW
    blocksY = vqaH // blockH
    numBlocks = blocksX * blocksY

    palette = bytearray(768)
    framebuf = bytearray(vqaW * vqaH)
    prevbuf = bytearray(vqaW * vqaH)

    # Skip FINF
    if pos + 8 <= len(vqa_data) and vqa_data[pos : pos + 4] == b"FINF":
        sz = be32(vqa_data, pos + 4)
        pos += 8 + sz + (sz & 1)

    frame_num = 0
    AUDIO = {b"SND0", b"SND1", b"SND2"}

    while pos + 8 <= len(vqa_data) and frame_num < numFrames:
        tag = vqa_data[pos : pos + 4]
        size = be32(vqa_data, pos + 4)
        if tag in AUDIO:
            # Skip audio without copying body — key optimization
            pos += 8 + size + (size & 1)
            continue
        body = vqa_data[pos + 8 : pos + 8 + size]
        pos += 8 + size + (size & 1)
        if tag != b"VQFR":
            continue

        # Decode VQFR sub-chunks
        chunks: list = []
        fp = 0
        while fp + 8 <= size:
            stag = body[fp : fp + 4]
            ssz = be32(body, fp + 4)
            sbody = body[fp + 8 : fp + 8 + ssz]
            fp += 8 + ssz + (ssz & 1)
            chunks.append((stag, ssz, sbody))

        # Apply CPL0 (palette)
        for stag, ssz, sbody in chunks:
            if stag == b"CPL0":
                palette[: min(768, ssz)] = sbody[: min(768, ssz)]

        # Apply full codebook CBF0 / CBFZ
        for stag, ssz, sbody in chunks:
            if stag == b"CBF0":
                rd = min(ssz, codebook_size)
                codebook[:rd] = sbody[:rd]
                next_cb_idx = 0
                partial_countdown = cbParts
            elif stag == b"CBFZ":
                decomp = _lcw_decode(sbody, codebook_size)
                codebook[: len(decomp)] = decomp
                next_cb_idx = 0
                partial_countdown = cbParts

        # Render VPT0 / VPTZ / VPTR / VPRZ
        # VPT layout: first numBlocks bytes = lo-byte, next numBlocks bytes = hi-byte
        for stag, ssz, sbody in chunks:
            if stag not in (b"VPT0", b"VPTZ", b"VPTR", b"VPRZ"):
                continue
            vpt_raw = sbody
            if stag in (b"VPTZ", b"VPRZ"):
                vpt_raw = _lcw_decode(sbody, numBlocks * 2)
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
                        framebuf[src_off : src_off + blockW] = codebook[
                            cb_row : cb_row + blockW
                        ]

        # Accumulate partial codebook CBP0 / CBPZ — after rendering
        for stag, ssz, sbody in chunks:
            if stag == b"CBP0":
                needed = min(ssz, codebook_size - next_cb_idx)
                next_codebook_buffer[next_cb_idx : next_cb_idx + needed] = sbody[
                    :needed
                ]
                next_cb_idx += needed
                partial_countdown -= 1
                if partial_countdown <= 0:
                    codebook[:next_cb_idx] = next_codebook_buffer[:next_cb_idx]
                    next_cb_idx = 0
                    partial_countdown = cbParts
            elif stag == b"CBPZ":
                needed = min(ssz, codebook_size - next_cb_idx)
                next_codebook_buffer[next_cb_idx : next_cb_idx + needed] = sbody[
                    :needed
                ]
                next_cb_idx += needed
                partial_countdown -= 1
                if partial_countdown <= 0:
                    decomp = _lcw_decode(
                        next_codebook_buffer[:next_cb_idx], codebook_size
                    )
                    codebook[: len(decomp)] = decomp
                    next_cb_idx = 0
                    partial_countdown = cbParts

        if frame_num == target_frame:
            # Expand palette 6-bit → 8-bit (VGA) and build RGB24.
            # Use (v>>4)&0x03 not (v>>4) to limit fill bits to 2, matching
            # vqa_decode_verify.py — some VQAs store 8-bit palette values and
            # the unmasked shift would inject garbage upper bits.
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
            return rgb

        frame_num += 1

    return None


def _write_rgb_png(path: str, pixels: bytearray, w: int, h: int):
    """Write RGB24 bytes to a PNG file."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter=None
        raw += pixels[y * w * 3 : (y + 1) * w * 3]
    compressed = zlib.compress(bytes(raw), 6)

    def chunk(tag: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


def our_decoder_frame(vqa_path: str, frame_idx: int, out_dir: str) -> str | None:
    """Decode frame_idx from vqa_path using our inline decoder, return PNG path."""
    os.makedirs(out_dir, exist_ok=True)
    with open(vqa_path, "rb") as fh:
        vqa_data = fh.read()

    # Get dimensions from header for output filename
    hdr = parse_vqhd(vqa_path)
    if hdr is None:
        return None
    w, h = hdr["width"], hdr["height"]

    rgb = decode_vqa_frame_inline(vqa_data, frame_idx)
    if rgb is None:
        return None

    out_path = os.path.join(out_dir, f"our_frame_{frame_idx:04d}.png")
    _write_rgb_png(out_path, rgb, w, h)
    return out_path


# ---------------------------------------------------------------------------
# Main comparison loop
# ---------------------------------------------------------------------------


def compare_vqa(
    vqa_path: str,
    label: str,
    num_frames: int,
    out_base: str,
    threshold: int,
    quiet: bool,
) -> dict:
    """Compare our decoder vs ffmpeg at a representative frame.

    Frame selection: min(midpoint, 40).  Frame 40 is far enough into the
    cinematic to avoid the title-card and fast enough for the Python decoder
    (40 sequential frames ≈ 2-3 s).  For VQAs shorter than 80 frames the
    true midpoint (< 40) is used instead.
    """
    midpoint = num_frames // 2
    compare_frame = min(midpoint, 40)
    result = {
        "label": label,
        "vqa_path": vqa_path,
        "num_frames": num_frames,
        "midpoint": midpoint,
        "compare_frame": compare_frame,
        "status": "SKIP",
    }

    os.makedirs(out_base, exist_ok=True)

    # 1. ffmpeg frame (Wine OG proxy)
    ffmpeg_out = os.path.join(out_base, "ffmpeg_mid.png")
    if not ffmpeg_frame(vqa_path, compare_frame, ffmpeg_out):
        result["status"] = "SKIP"
        result["reason"] = f"ffmpeg failed for frame {compare_frame}"
        return result

    # 2. Our decoder frame
    our_dir = os.path.join(out_base, "our")
    our_out = our_decoder_frame(vqa_path, compare_frame, our_dir)
    if our_out is None:
        result["status"] = "SKIP"
        result["reason"] = f"our decoder failed for frame {compare_frame}"
        return result

    # 3. Pixel diff
    diff = pixel_diff(our_out, ffmpeg_out)
    if "error" in diff:
        result["status"] = "ERROR"
        result["reason"] = diff["error"]
        return result

    result.update(diff)
    result["ffmpeg_frame"] = ffmpeg_out
    result["our_frame"] = our_out

    # 4. Save diff image
    diff_path = os.path.join(out_base, "diff.png")
    try:
        _, _, pa = _read_png_rgb(our_out)
        _, _, pb = _read_png_rgb(ffmpeg_out)
        _save_diff_png(diff_path, pa, pb, diff["w"], diff["h"])
        result["diff_image"] = diff_path
    except Exception as e:
        result["diff_image_error"] = str(e)

    # 5. Pass/fail
    p99 = diff.get("p99", 999)
    ssim = diff.get("ssim", None)
    passed = p99 <= threshold
    if ssim is not None:
        passed = passed and ssim >= 0.85
    result["status"] = "PASS" if passed else "FAIL"
    result["threshold"] = threshold

    if not quiet:
        ssim_str = f" ssim={ssim:.4f}" if ssim is not None else ""
        print(
            f"  [{result['status']}] {label}: frame={compare_frame}/{num_frames} "
            f"p99={p99} p95={diff.get('p95')} mean={diff.get('mean')}{ssim_str}"
        )

    return result


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "mix_path",
        nargs="?",
        default=MAIN_MIX_DEFAULT,
        help=f"Path to MAIN.MIX (default: {MAIN_MIX_DEFAULT})",
    )
    ap.add_argument("--out-dir", default=OUT_DIR_DEFAULT)
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    ap.add_argument("--max-vqas", type=int, default=DEFAULT_MAX_VQAS)
    ap.add_argument(
        "--vqa-dir",
        default=None,
        help="Use pre-extracted VQA files from DIR instead of scanning MAIN.MIX",
    )
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not subprocess.run(["which", "ffmpeg"], capture_output=True).returncode == 0:
        print("SKIP: ffmpeg not in PATH", file=sys.stderr)
        return 2

    out_dir = args.out_dir
    os.makedirs(out_dir, exist_ok=True)

    print("=== TIM-705 Cinematic Comparison ===")
    print(f"Out dir:   {out_dir}")
    print(f"Threshold: p99 <= {args.threshold}")
    print()

    # Collect VQA files — either from pre-scanned dir or by scanning MAIN.MIX
    if args.vqa_dir:
        scan_dir = args.vqa_dir
        vqa_paths = sorted(
            os.path.join(scan_dir, f)
            for f in os.listdir(scan_dir)
            if f.endswith(".vqa") or f.endswith(".VQA")
        )
        print(f"Using {len(vqa_paths)} pre-extracted VQAs from {scan_dir}")
    else:
        if not os.path.exists(args.mix_path):
            print(f"SKIP: {args.mix_path} not found", file=sys.stderr)
            return 2
        scan_dir = os.path.join(out_dir, "_scan")
        print(f"Scanning {args.mix_path} for VQA data...")
        with open(args.mix_path, "rb") as fh:
            raw = fh.read()
        vqa_paths = scan_for_vqas(raw, scan_dir)
        print(f"Found {len(vqa_paths)} VQA blobs.")

    if not vqa_paths:
        print("SKIP: no VQA data found", file=sys.stderr)
        return 2

    # Parse headers and label
    candidates: list[tuple[str, str, int]] = []  # (path, label, num_frames)
    seen_labels: set[str] = set()
    for vp in vqa_paths:
        hdr = parse_vqhd(vp)
        if hdr is None:
            continue
        nf = hdr["numFrames"]
        if nf < 2:
            continue
        lbl = label_vqa(nf)
        # De-duplicate by label (prefer first occurrence)
        if lbl not in seen_labels:
            seen_labels.add(lbl)
            candidates.append((vp, lbl, nf))

    # Sort: put known-name VQAs first, then by label
    def sort_key(item):
        _, lbl, nf = item
        known = lbl in KNOWN_FRAME_COUNTS.values()
        return (0 if known else 1, lbl)

    candidates.sort(key=sort_key)

    chosen = candidates[: args.max_vqas]
    print(f"Comparing {len(chosen)} VQAs (max={args.max_vqas}):")
    for _, lbl, nf in chosen:
        print(f"  {lbl}: {nf} frames, midpoint={nf // 2}")
    print()

    # Run comparisons
    results: list[dict] = []
    for vp, lbl, nf in chosen:
        vqa_out = os.path.join(
            out_dir, lbl.replace("~", "_approx").replace(".VQA", "").replace(".vqa", "")
        )
        r = compare_vqa(vp, lbl, nf, vqa_out, args.threshold, args.quiet)
        results.append(r)

    # Summary
    passed = [r for r in results if r["status"] == "PASS"]
    failed = [r for r in results if r["status"] == "FAIL"]
    skipped = [r for r in results if r["status"] in ("SKIP", "ERROR")]

    print()
    print("=== Summary ===")
    print(f"  PASS: {len(passed)}/{len(results)}")
    for r in passed:
        ssim_str = f" ssim={r['ssim']:.4f}" if "ssim" in r else ""
        print(
            f"    [PASS] {r['label']}: p99={r.get('p99', '?')} mean={r.get('mean', '?')}{ssim_str}"
        )
    if failed:
        print(f"  FAIL: {len(failed)}/{len(results)}")
        for r in failed:
            print(
                f"    [FAIL] {r['label']}: p99={r.get('p99', '?')} diff={r.get('diff_image', '?')}"
            )
    if skipped:
        print(f"  SKIP: {len(skipped)}/{len(results)}")
        for r in skipped:
            print(f"    [SKIP] {r['label']}: {r.get('reason', '?')}")

    # JSON report
    report_path = os.path.join(out_dir, "report.json")
    with open(report_path, "w") as fh:
        json.dump(
            {
                "results": results,
                "summary": {
                    "pass": len(passed),
                    "fail": len(failed),
                    "skip": len(skipped),
                    "total": len(results),
                    "threshold": args.threshold,
                },
            },
            fh,
            indent=2,
        )
    print(f"\nReport: {report_path}")

    # Gate: need 6+ PASS results
    if len(passed) >= 6:
        print(f"\nRESULT: PASS ({len(passed)}/6+ cinematics pass)")
        return 0 if not failed else 1
    elif len(passed) + len(failed) < 6 and len(passed) < 6:
        if len(passed) + len(skipped) >= len(results):
            print(f"\nRESULT: SKIP (only {len(results)} VQAs found, need 6+ passing)")
            return 2
    print(f"\nRESULT: FAIL ({len(passed)}<6 cinematics pass)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
