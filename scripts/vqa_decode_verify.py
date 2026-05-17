#!/usr/bin/env python3
# ruff: noqa: F821 (max_diff false positive inside embedded code snippet string)
"""
Python port of vqa_player.cpp's decoding logic.
Renders VQA frames to PNG and compares with ffmpeg reference.
Used to find palette/geometry bugs in the C++ player.

Usage:
  python3 vqa_decode_verify.py <vqa_file> <outdir> [--compare <ref_dir>]
"""

import struct
import os


def be32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


# ---------------------------------------------------------------------------
# LCW (Format80) decompressor — mirrors lcw_decode_safe() in vqa_player.cpp
# ---------------------------------------------------------------------------
def lcw_decode(src_bytes: bytes, dst_cap: int) -> bytearray:
    src = memoryview(src_bytes)
    sp = 0
    dst = bytearray(dst_cap)
    dp = 0

    while sp < len(src) and dp < dst_cap:
        op = src[sp]
        sp += 1

        if op == 0x80:
            break
        elif not (op & 0x80):
            # Short copy from dest: count = hi-nybble+3, offset = (lo-nybble<<8)|next
            if sp >= len(src):
                break
            count = (op >> 4) + 3
            offset = ((op & 0x0F) << 8) | src[sp]
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
            # Medium copy from source: op & 0x3f bytes literal
            count = op & 0x3F
            for _ in range(count):
                if sp >= len(src) or dp >= dst_cap:
                    break
                dst[dp] = src[sp]
                dp += 1
                sp += 1
        elif op == 0xFE:
            # Long run: 2-byte LE count, 1-byte fill
            if sp + 2 >= len(src):
                break
            count = src[sp] | (src[sp + 1] << 8)
            sp += 2
            fill = src[sp]
            sp += 1
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = fill
                dp += 1
        elif op == 0xFF:
            # Long copy from dest absolute: 2-byte LE count, 2-byte LE offset
            if sp + 3 >= len(src):
                break
            count = src[sp] | (src[sp + 1] << 8)
            sp += 2
            offset = src[sp] | (src[sp + 1] << 8)
            sp += 2
            cp = offset
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = dst[cp] if cp < dst_cap else 0
                dp += 1
                cp += 1
        else:
            # Medium copy from dest absolute: (op&0x3f)+3, 2-byte LE offset
            if sp + 1 >= len(src):
                break
            count = (op & 0x3F) + 3
            offset = src[sp] | (src[sp + 1] << 8)
            sp += 2
            cp = offset
            for _ in range(count):
                if dp >= dst_cap:
                    break
                dst[dp] = dst[cp] if cp < dst_cap else 0
                dp += 1
                cp += 1

    return dst[:dp]


# ---------------------------------------------------------------------------
# Write indexed image to PNG via zlib (palette-aware)
# ---------------------------------------------------------------------------
def write_png_rgb(
    path: str,
    pixels: bytearray,
    palette: bytearray,
    w: int,
    h: int,
    scale_palette: bool = True,
):
    """Write indexed pixel array as RGB24 PNG.

    Red Alert VQA files store 6-bit VGA palette values (0-63) in CPL0 chunks.
    scale_palette=True (default) expands 6-bit to 8-bit using the same
    formula as vqa_player.cpp: (v << 2) | (v >> 4) to fill low bits.
    Pass scale_palette=False only when the palette is already 8-bit.
    """
    import zlib

    # Build RGB24 scanlines
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter = None
        for x in range(w):
            idx = pixels[y * w + x]
            r, g, b = palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2]
            if scale_palette:
                # 6-bit VGA → 8-bit expansion (matches vqa_player.cpp Set_DD_Palette_8bit)
                r = ((r << 2) & 0xFF) | ((r >> 4) & 0x03)
                g = ((g << 2) & 0xFF) | ((g >> 4) & 0x03)
                b = ((b << 2) & 0xFF) | ((b >> 4) & 0x03)
            raw += bytes([r, g, b])

    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag: bytes, data: bytes) -> bytes:
        c = struct.pack(">I", len(data)) + tag + data
        import zlib

        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return c + struct.pack(">I", crc)

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (
        signature
        + chunk(b"IHDR", ihdr_data)
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )

    with open(path, "wb") as f:
        f.write(png)


# ---------------------------------------------------------------------------
# blit_vqa_frame — mirrors blit_vqa_frame() in vqa_player.cpp
# ---------------------------------------------------------------------------
def blit_vqa_frame(
    pixels_src: bytearray,
    vqaW: int,
    vqaH: int,
    dst: bytearray,
    dstPitch: int,
    scrW: int,
    scrH: int,
):
    """Mirrors blit_vqa_frame() in vqa_player.cpp."""
    # Clear dst
    for y in range(scrH):
        for x in range(scrW):
            dst[y * dstPitch + x] = 0

    scale = min(scrW // vqaW, scrH // vqaH)
    if scale < 1:
        scale = 1
    if scale > 2:
        scale = 2

    dstW = vqaW * scale
    dstH = vqaH * scale
    startX = (scrW - dstW) // 2
    startY = (scrH - dstH) // 2

    for sy in range(vqaH):
        for sx in range(vqaW):
            px = pixels_src[sy * vqaW + sx]
            for dy in range(scale):
                row = startY + sy * scale + dy
                if row < 0 or row >= scrH:
                    continue
                for dx in range(scale):
                    col = startX + sx * scale + dx
                    if 0 <= col < scrW:
                        dst[row * dstPitch + col] = px


# ---------------------------------------------------------------------------
# Main VQA decoder
# ---------------------------------------------------------------------------
def decode_vqa(
    vqa_path: str,
    outdir: str,
    frames_to_dump=None,
    screen_w: int = 640,
    screen_h: int = 480,
):
    """
    Decode VQA file and dump specified frame numbers to PNG.
    Uses exactly the same algorithm as vqa_player.cpp.
    """
    with open(vqa_path, "rb") as f:
        data = f.read()

    os.makedirs(outdir, exist_ok=True)

    if data[:4] != b"FORM" or data[8:12] != b"WVQA":
        print("Not a WVQA file")
        return

    pos = 12

    # --- Find VQHD ---
    hdr = None
    while pos + 8 <= len(data):
        tag = data[pos : pos + 4]
        size = be32(data, pos + 4)
        body = data[pos + 8 : pos + 8 + size]
        npos = pos + 8 + size + (size & 1)

        if tag == b"VQHD":
            # VQAHeader layout (from vqa_player.cpp struct, pack(1)):
            # offset  0: uint16 version
            # offset  2: uint16 flags
            # offset  4: uint16 numFrames
            # offset  6: uint16 width
            # offset  8: uint16 height
            # offset 10: uint8  blockW
            # offset 11: uint8  blockH
            # offset 12: uint8  fps
            # offset 13: uint8  cbParts
            # offset 14: uint16 numColors
            # offset 16: uint16 maxBlocks
            # offset 18: uint16 unknown1
            # offset 20: uint16 unknown2
            # offset 22: uint16 unknown3 (not freq)
            # offset 24: uint16 freq
            # offset 26: uint8  channels
            # offset 27: uint8  bits
            version, flags, numFrames, width, height = struct.unpack_from(
                "<HHHHH", body, 0
            )
            blockW, blockH, fps, cbParts = struct.unpack_from("<BBBB", body, 10)
            numColors, maxBlocks = struct.unpack_from("<HH", body, 14)
            # audio params at offsets 24-27
            freq = struct.unpack_from("<H", body, 24)[0]
            channels, bits = struct.unpack_from("<BB", body, 26)

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
                fps=fps,
                cbParts=cbParts,
                numColors=numColors,
                maxBlocks=maxBlocks,
                flags=flags,
                freq=freq,
                channels=channels,
                bits=bits,
            )
            print(f"VQHD: {width}x{height} fps={fps} frames={numFrames}")
            print(
                f"  blockW={blockW} blockH={blockH} cbParts={cbParts} maxBlocks={maxBlocks}"
            )
            pos = npos
            break

        pos = npos

    if hdr is None:
        print("No VQHD")
        return

    vqaW, vqaH = hdr["width"], hdr["height"]
    blockW, blockH = hdr["blockW"], hdr["blockH"]
    cbParts = hdr["cbParts"] or 1
    maxBlocks = hdr["maxBlocks"]
    numFrames = hdr["numFrames"]
    cbEntrySize = blockW * blockH

    blocksX = vqaW // blockW
    blocksY = vqaH // blockH
    numBlocks = blocksX * blocksY

    # VQA v2 codebook: 0x10000 entries total (matches vqa_player.cpp TIM-613).
    # Solid-colour convention: when hi==0xFF (blockH=4) or hi==0x0F (blockH=2),
    # cb_idx points into a pre-filled solid range — every pixel in the block
    # gets palette index lo.  Entries 0xFF00-0xFFFF and 0x0F00-0x0FFF are
    # pre-filled before the first frame so the codebook lookup is uniform.
    MAX_CB_VECTORS = 0x10000
    codebook_size = MAX_CB_VECTORS * cbEntrySize
    codebook = bytearray(codebook_size)
    # Pre-fill solid-colour entries (matches C++ vqa_player.cpp init loop)
    for ci in range(256):
        base_ff = (0xFF00 + ci) * cbEntrySize
        base_0f = (0x0F00 + ci) * cbEntrySize
        codebook[base_ff : base_ff + cbEntrySize] = bytes([ci]) * cbEntrySize
        codebook[base_0f : base_0f + cbEntrySize] = bytes([ci]) * cbEntrySize

    # ffmpeg-style CBPZ accumulation: chunks are appended raw and decompressed
    # together every cbParts frames (after rendering, so new codebook takes
    # effect on the NEXT frame).
    next_codebook_buffer = bytearray(codebook_size)
    next_cb_idx = 0
    partial_countdown = cbParts

    framebuf = bytearray(vqaW * vqaH)
    prevbuf = bytearray(vqaW * vqaH)
    palette = bytearray(768)

    # Screen buffer
    scrW, scrH = screen_w, screen_h
    screenbuf = bytearray(scrW * scrH)

    # Skip FINF
    save_pos = pos
    if pos + 8 <= len(data):
        tag = data[pos : pos + 4]
        size = be32(data, pos + 4)
        if tag == b"FINF":
            pos += 8 + size + (size & 1)
        else:
            pos = save_pos

    if frames_to_dump is None:
        frames_to_dump = set(range(min(5, numFrames)))

    frame_num = 0
    palette_set = False

    while pos + 8 <= len(data) and frame_num < numFrames:
        tag = data[pos : pos + 4]
        size = be32(data, pos + 4)
        body = data[pos + 8 : pos + 8 + size]
        pos += 8 + size + (size & 1)

        if tag in (b"SND0", b"SND1", b"SND2"):
            continue

        if tag != b"VQFR":
            continue

        # Two-pass through VQFR sub-chunks — mirrors ffmpeg:
        # Pass 1: collect chunk offsets/bodies.
        # Pass 2: apply in order: CPL0 → CBF(Z/0) → render → CBP(Z/0) swap.
        vqfr_remaining = size
        chunks = []  # (tag, body)
        fp = 0
        while fp + 8 <= vqfr_remaining:
            stag = body[fp : fp + 4]
            ssz = be32(body, fp + 4)
            sbody = body[fp + 8 : fp + 8 + ssz]
            fp += 8 + ssz + (ssz & 1)
            chunks.append((stag, ssz, sbody))

        # Apply CPL0
        for stag, ssz, sbody in chunks:
            if stag == b"CPL0":
                palette[: min(768, ssz)] = sbody[: min(768, ssz)]
                palette_set = True

        # Apply full codebook (CBF0 / CBFZ)
        for stag, ssz, sbody in chunks:
            if stag == b"CBF0":
                rd = min(ssz, codebook_size)
                codebook[:rd] = sbody[:rd]
                # Reset partial accumulator when a full codebook arrives
                next_cb_idx = 0
                partial_countdown = cbParts
            elif stag == b"CBFZ":
                decomp = lcw_decode(sbody, codebook_size)
                codebook[: len(decomp)] = decomp
                next_cb_idx = 0
                partial_countdown = cbParts

        # Render (VPTZ / VPTR / VPT0 / VPRZ) — uses current codebook
        for stag, ssz, sbody in chunks:
            if stag not in (b"VPT0", b"VPTZ", b"VPTR", b"VPRZ"):
                continue

            vpt_raw = sbody
            if stag in (b"VPTZ", b"VPRZ"):
                vpt_raw = lcw_decode(sbody, numBlocks * 2)

            if len(vpt_raw) < numBlocks * 2:
                continue

            prevbuf[:] = framebuf[:]

            for bi in range(numBlocks):
                bx = bi % blocksX
                by = bi // blocksX
                lo = vpt_raw[bi]
                hi = vpt_raw[numBlocks + bi]

                dst_base = by * blockH * vqaW + bx * blockW

                cb_idx = lo | (hi << 8)
                cb_base = cb_idx * cbEntrySize
                if cb_base + cbEntrySize <= codebook_size:
                    for fy in range(blockH):
                        src_off = dst_base + fy * vqaW
                        cb_row = cb_base + fy * blockW
                        framebuf[src_off : src_off + blockW] = codebook[
                            cb_row : cb_row + blockW
                        ]

        # Accumulate partial codebook (CBP0 / CBPZ) — AFTER rendering
        for stag, ssz, sbody in chunks:
            if stag == b"CBP0":
                # CBP0: raw uncompressed bytes — accumulate directly
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
                # CBPZ: accumulate raw compressed bytes; decompress when all parts arrive
                needed = min(ssz, codebook_size - next_cb_idx)
                next_codebook_buffer[next_cb_idx : next_cb_idx + needed] = sbody[
                    :needed
                ]
                next_cb_idx += needed
                partial_countdown -= 1
                if partial_countdown <= 0:
                    decomp = lcw_decode(
                        next_codebook_buffer[:next_cb_idx], codebook_size
                    )
                    codebook[: len(decomp)] = decomp
                    next_cb_idx = 0
                    partial_countdown = cbParts

        # Blit frame using same logic as blit_vqa_frame()
        if palette_set:
            blit_vqa_frame(framebuf, vqaW, vqaH, screenbuf, scrW, scrW, scrH)

        if frame_num in frames_to_dump:
            outpath = os.path.join(outdir, f"live_frame_{frame_num + 1:03d}.png")
            write_png_rgb(outpath, screenbuf, palette, scrW, scrH)
            print(f"  Dumped frame {frame_num + 1} → {outpath}")

            # Also dump without the blit scaling (raw VQA resolution)
            raw_path = os.path.join(outdir, f"live_raw_{frame_num + 1:03d}.png")
            write_png_rgb(raw_path, framebuf, palette, vqaW, vqaH)
            print(f"  Dumped raw frame {frame_num + 1} (no scale) → {raw_path}")

        frame_num += 1

    print(f"Decoded {frame_num}/{numFrames} frames")


# ---------------------------------------------------------------------------
# Comparison: pixel diff between two PNG files
# ---------------------------------------------------------------------------
def compare_pngs(path_a: str, path_b: str, label: str):
    import subprocess

    result = subprocess.run(
        [
            "python3",
            "-c",
            f"""
import struct, zlib

def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    # Find IHDR and IDAT
    pos = 8  # skip signature
    chunks = {{}}
    idat = b""
    while pos < len(data):
        sz = struct.unpack_from(">I", data, pos)[0]
        tag = data[pos+4:pos+8]
        body = data[pos+8:pos+8+sz]
        if tag == b"IHDR":
            w, h, bd, ct = struct.unpack_from(">IIBB", body, 0)
            chunks["IHDR"] = (w, h, bd, ct)
        elif tag == b"IDAT":
            idat += body
        pos += 12 + sz
    raw = zlib.decompress(idat)
    w, h, bd, ct = chunks["IHDR"]
    bpp = 3 if ct == 2 else 1  # RGB or palette
    pixels = []
    row_sz = 1 + w * bpp
    for y in range(h):
        pixels.append(raw[1 + y*row_sz : (y+1)*row_sz])
    return w, h, pixels, bpp

wa, ha, pa, bppa = read_png({repr(path_a)})
wb, hb, pb, bppb = read_png({repr(path_b)})

if wa != wb or ha != hb:
    print(f"  Size mismatch: {{wa}}x{{ha}} vs {{wb}}x{{hb}}")
else:
    total = wa * ha * 3
    diff = 0
    max_diff = 0
    for y in range(ha):
        for x in range(wa):
            for c in range(3):
                va = pa[y][x*3+c]
                vb = pb[y][x*3+c]
                d = abs(va - vb)
                diff += d
                if d > max_diff: max_diff = d
    print(f"  {repr({repr(path_a)})} vs {repr({repr(path_b)})}")
    print(f"  avg diff per pixel-channel: {{diff / total:.2f}}  max_diff={max_diff}")
""",
        ],
        capture_output=True,
        text=True,
    )
    print(result.stdout, result.stderr)


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("vqa", help="VQA file path")
    ap.add_argument("outdir", help="Output directory for PNGs")
    ap.add_argument(
        "--frames",
        default="0,1,29,59",
        help="0-indexed frame numbers to dump (comma-separated)",
    )
    ap.add_argument("--screenw", type=int, default=640)
    ap.add_argument("--screenh", type=int, default=480)
    args = ap.parse_args()

    frames = set(int(x) for x in args.frames.split(","))
    decode_vqa(
        args.vqa,
        args.outdir,
        frames_to_dump=frames,
        screen_w=args.screenw,
        screen_h=args.screenh,
    )
