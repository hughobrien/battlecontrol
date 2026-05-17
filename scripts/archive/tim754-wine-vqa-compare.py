#!/usr/bin/env python3
"""TIM-754 — Wine OG cinematic re-verification after TIM-740 scanline fix.

Quantifies the rendering improvement from TIM-740's `scanline_double=true`
cnc-ddraw workaround by computing SSIM between pre-fix (interlaced) and
post-fix (scanline-doubled) Wine OG intro VQA captures.

Inputs:
  /tmp/tim740/verify/A_control/t{8,10,12,14}.png       (pre-fix, interlaced)
  /tmp/tim740/verify/B_scanline_double/t{8,10,12,14}.png (post-fix)

For each timestamp we crop the game window region from the 800x600 Xvfb
capture and compute:
  - SSIM(pre, post)               how different the two renders are
  - PNG file size ratio (post/pre) interlace artefact removes compressibility

Decoder parity is already proven independently by cinematic-compare.py
(TIM-705 Part A): 8/8 VQAs in MAIN.MIX decode bit-exact to ffmpeg
(p99=0, SSIM=1.0000). TIM-740's fix is in the Wine + cnc-ddraw render
substrate, not the decode pipeline, so the Part A scores are unchanged.

Outputs:
  docs/tim740/post-fix-reference/ssim-report.json
  docs/tim740/post-fix-reference/wine-og-{pre,post}-fix-t{8,10,12,14}.png
"""

import json
import os
import struct
import zlib
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY_DIR = '/tmp/tim740/verify'
OUT_DIR = REPO_ROOT / 'docs' / 'tim740' / 'post-fix-reference'

WIN_X0, WIN_X1 = 80, 720   # 640 cols
WIN_Y0, WIN_Y1 = 100, 500  # 400 rows


def read_png_rgb(path):
    d = open(path, 'rb').read()
    pos = 8
    w = h = 0
    idat = b''
    ctype = 2
    while pos < len(d):
        sz = struct.unpack_from('>I', d, pos)[0]
        tag = d[pos+4:pos+8]
        body = d[pos+8:pos+8+sz]
        if tag == b'IHDR':
            w, h = struct.unpack_from('>II', body, 0)
            ctype = body[9]
        elif tag == b'IDAT':
            idat += body
        pos += 12 + sz
    raw = zlib.decompress(idat)
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    row_sz = 1 + w * bpp
    pixels = bytearray(w * h * bpp)
    prev = bytes(w * bpp)
    for y in range(h):
        filt = raw[y*row_sz]
        line = bytearray(raw[y*row_sz+1:(y+1)*row_sz])
        if filt == 1:
            for x in range(bpp, w*bpp):
                line[x] = (line[x] + line[x-bpp]) & 0xFF
        elif filt == 2:
            for x in range(w*bpp):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif filt == 3:
            for x in range(w*bpp):
                a = line[x-bpp] if x >= bpp else 0
                line[x] = (line[x] + (a + prev[x]) // 2) & 0xFF
        elif filt == 4:
            for x in range(w*bpp):
                a = line[x-bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
        pixels[y*w*bpp:(y+1)*w*bpp] = line
        prev = bytes(line)
    if bpp == 1:
        gray = np.frombuffer(bytes(pixels), dtype=np.uint8).reshape(h, w)
        return np.stack([gray, gray, gray], axis=-1)
    return np.frombuffer(bytes(pixels), dtype=np.uint8).reshape(h, w, 3).copy()


def write_png_rgb(path, arr):
    h, w, _ = arr.shape
    pixels = arr.astype(np.uint8).tobytes()
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pixels[y*w*3:(y+1)*w*3]
    comp = zlib.compress(bytes(raw), 6)

    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', crc)
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', comp) +
           chunk(b'IEND', b''))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(png)


def crop_window(arr):
    return arr[WIN_Y0:WIN_Y1, WIN_X0:WIN_X1].copy()


def ssim_global(a, b):
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    mu_a, mu_b = a.mean(), b.mean()
    sig_a = a.std(); sig_b = b.std()
    cov = ((a - mu_a) * (b - mu_b)).mean()
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2
    return (2 * mu_a * mu_b + C1) * (2 * cov + C2) / \
           ((mu_a * mu_a + mu_b * mu_b + C1) * (sig_a * sig_a + sig_b * sig_b + C2))


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print('Reading verify captures...')

    rows = []
    for ts in ('t8', 't10', 't12', 't14'):
        pre_path = Path(VERIFY_DIR) / 'A_control' / f'{ts}.png'
        post_path = Path(VERIFY_DIR) / 'B_scanline_double' / f'{ts}.png'
        if not (pre_path.exists() and post_path.exists()):
            print(f'  {ts}: MISSING')
            continue

        pre_full = read_png_rgb(str(pre_path))
        post_full = read_png_rgb(str(post_path))
        pre = crop_window(pre_full)
        post = crop_window(post_full)

        s_pp = float(ssim_global(pre, post))
        pre_sz = pre_path.stat().st_size
        post_sz = post_path.stat().st_size

        # Per-row brightness analysis — how many "gap" rows (sum < 10% of
        # adjacent row sum) exist. Pre-fix should have ~155 gap rows
        # (every other row in the 311 content-row band), post-fix should
        # be near zero.
        def count_gap_rows(arr):
            # gray = mean across RGB
            gray = arr.astype(np.float64).mean(axis=2)
            row_sum = gray.sum(axis=1)  # one number per row
            gaps = 0
            for y in range(1, len(row_sum) - 1):
                neighbour_max = max(row_sum[y-1], row_sum[y+1])
                if neighbour_max > 100 and row_sum[y] < 0.1 * neighbour_max:
                    gaps += 1
            return gaps

        pre_gaps = count_gap_rows(pre)
        post_gaps = count_gap_rows(post)

        rows.append({
            'timestamp':       ts,
            'ssim_pre_vs_post': round(s_pp, 4),
            'pre_png_bytes':    pre_sz,
            'post_png_bytes':   post_sz,
            'png_size_ratio':   round(post_sz / pre_sz, 2) if pre_sz else 0,
            'pre_gap_rows':     pre_gaps,
            'post_gap_rows':    post_gaps,
        })

        write_png_rgb(str(OUT_DIR / f'wine-og-pre-fix-{ts}.png'), pre)
        write_png_rgb(str(OUT_DIR / f'wine-og-post-fix-{ts}.png'), post)

    print()
    print('=== Pre-fix vs Post-fix SSIM (Wine OG live captures) ===')
    fmt = '{:<6}  {:>15}  {:>10}  {:>11}  {:>11}  {:>10}  {:>10}'
    print(fmt.format('ts', 'ssim_pre_v_post', 'png_ratio',
                     'pre_bytes', 'post_bytes', 'pre_gaps', 'post_gaps'))
    for r in rows:
        print(fmt.format(r['timestamp'],
                         f'{r["ssim_pre_vs_post"]:.4f}',
                         f'{r["png_size_ratio"]:.2f}x',
                         r['pre_png_bytes'], r['post_png_bytes'],
                         r['pre_gap_rows'], r['post_gap_rows']))

    report = {
        'methodology': (
            'Direct SSIM and structural-artefact comparison of the cropped '
            'game window region (640x400) from Wine OG Xvfb captures, with '
            'and without the cnc-ddraw scanline_double=true workaround.'
        ),
        'pre_fix_dll':  'cnc-ddraw master a0b81b1, scanline_double NOT set',
        'post_fix_dll': 'cnc-ddraw master a0b81b1 + scripts/cnc-ddraw-tim740-scanline-double.patch, scanline_double=true',
        'capture_source': '/tmp/tim740/verify/{A_control,B_scanline_double}/t{8,10,12,14}.png',
        'comparisons': rows,
        'cinematic_compare_parity': {
            'spec': 'TIM-705 Part A — scripts/cinematic-compare.py',
            'methodology': 'Python decoder vs ffmpeg libavcodec on MAIN.MIX VQA blobs',
            'rerun_date': '2026-05-15',
            'result_pre_tim740':  '8/8 PASS, p99=0, SSIM=1.0000',
            'result_post_tim740': '8/8 PASS, p99=0, SSIM=1.0000',
            'note': (
                'TIM-740 is a Wine + cnc-ddraw render-substrate workaround; '
                'it does not touch the VQA decoder. The decoder-vs-ffmpeg '
                'parity spec is therefore unchanged by the fix.'
            ),
        },
    }
    with open(OUT_DIR / 'ssim-report.json', 'w') as fh:
        json.dump(report, fh, indent=2)
    print(f'\nReport: {OUT_DIR / "ssim-report.json"}')


if __name__ == '__main__':
    main()
