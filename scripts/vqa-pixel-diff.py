#!/usr/bin/env python3
"""
VQA reference-decoder pixel-diff harness.

Compares our Python reference decoder output against ffmpeg golden frames.
A p99 per-pixel delta > threshold indicates a codec regression.

Exit codes:
  0 = all frames within threshold (PASS)
  1 = one or more frames exceed threshold (FAIL)
  2 = no VQA data found or ffmpeg unavailable (SKIP — non-fatal in CI)

Usage:
  # Compare a single VQA file against ffmpeg:
  python3 scripts/vqa-pixel-diff.py path/to/file.vqa

  # Scan a MIX file for embedded VQAs and compare each:
  python3 scripts/vqa-pixel-diff.py path/to/MAIN.MIX

  # Run on the committed synthetic test VQA (always works, no game data):
  python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa

Options:
  --frames 0,29,59     0-indexed frame numbers (default: 0,29,59)
  --threshold 5        p99 pixel-channel delta threshold (default: 5)
  --generate-goldens   Generate ffmpeg goldens only, do not compare
  --goldens-dir DIR    Persist golden frames here (default: /tmp/vqa-goldens)
  --work-dir DIR       Work directory for temp files (default: auto-cleaned)
  --quiet              Suppress per-frame detail lines
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import shutil
import zlib
from pathlib import Path

# ---------------------------------------------------------------------------
# PNG reader
# ---------------------------------------------------------------------------

def _read_png_rgb(path: str):
    """Return (width, height, bytearray) of RGB24 pixels from a PNG."""
    with open(path, 'rb') as fh:
        data = fh.read()
    pos, width, height, idat = 8, 0, 0, b''
    while pos < len(data):
        sz = struct.unpack_from('>I', data, pos)[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + sz]
        if tag == b'IHDR':
            width, height = struct.unpack_from('>II', body, 0)
        elif tag == b'IDAT':
            idat += body
        pos += 12 + sz
    raw = zlib.decompress(idat)
    row_sz = 1 + width * 3
    pixels = bytearray()
    for y in range(height):
        pixels += raw[1 + y * row_sz:(y + 1) * row_sz]
    return width, height, pixels


# ---------------------------------------------------------------------------
# VQA extraction from MIX files
# ---------------------------------------------------------------------------

def _find_wvqa_in_file(path: str, out_dir: str) -> list:
    """Scan a file for FORM+WVQA magic and extract each VQA."""
    with open(path, 'rb') as fh:
        data = fh.read()
    extracted = []
    i = 0
    count = 0
    while i < len(data) - 12:
        if data[i:i + 4] == b'FORM' and data[i + 8:i + 12] == b'WVQA':
            size = struct.unpack_from('>I', data, i + 4)[0]
            vqa_data = data[i:i + 8 + size]
            out_path = os.path.join(out_dir, f'extracted_{count:03d}.vqa')
            with open(out_path, 'wb') as fh:
                fh.write(vqa_data)
            extracted.append(out_path)
            count += 1
            i += 8 + size
        else:
            i += 1
    return extracted


# ---------------------------------------------------------------------------
# ffmpeg golden generation
# ---------------------------------------------------------------------------

def _check_ffmpeg() -> bool:
    try:
        subprocess.run(['ffmpeg', '-version'], capture_output=True, check=True)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def _generate_ffmpeg_golden(vqa_path: str, out_dir: str, frames: list) -> dict:
    """Run ffmpeg to generate golden PNG frames at 0-indexed positions."""
    os.makedirs(out_dir, exist_ok=True)
    result = {}
    for fidx in frames:
        out_path = os.path.join(out_dir, f'golden_{fidx + 1:04d}.png')
        cmd = [
            'ffmpeg', '-y', '-loglevel', 'error',
            '-i', vqa_path,
            '-vf', f'select=eq(n\\,{fidx})',
            '-vsync', 'vfr', '-vframes', '1',
            '-pix_fmt', 'rgb24',
            out_path,
        ]
        ret = subprocess.run(cmd, capture_output=True)
        if ret.returncode == 0 and os.path.exists(out_path):
            result[fidx] = out_path
        else:
            errtxt = ret.stderr.decode(errors='replace')[:200]
            print(f'  [warn] ffmpeg failed for frame {fidx}: {errtxt}', file=sys.stderr)
    return result


# ---------------------------------------------------------------------------
# Pixel diff
# ---------------------------------------------------------------------------

def _pixel_diff(path_a: str, path_b: str) -> dict:
    """Return p99/p95/mean/max per-pixel-channel delta between two RGB PNGs."""
    wa, ha, pa = _read_png_rgb(path_a)
    wb, hb, pb = _read_png_rgb(path_b)
    if wa != wb or ha != hb:
        return {'error': f'size mismatch: {wa}x{ha} vs {wb}x{hb}'}
    n = wa * ha * 3
    diffs = sorted(abs(int(pa[i]) - int(pb[i])) for i in range(n))
    return {
        'w': wa, 'h': ha,
        'p99': diffs[min(int(n * 0.99), n - 1)],
        'p95': diffs[min(int(n * 0.95), n - 1)],
        'mean': sum(diffs) / n,
        'max': diffs[-1],
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input', help='VQA file or MIX file containing VQAs')
    ap.add_argument('--frames', default='0,29,59',
                    help='0-indexed frame numbers to compare (default: 0,29,59)')
    ap.add_argument('--threshold', type=int, default=5,
                    help='p99 pixel-channel delta threshold (default: 5)')
    ap.add_argument('--generate-goldens', action='store_true',
                    help='Generate golden frames only, do not compare')
    ap.add_argument('--goldens-dir', default=None,
                    help='Directory to persist golden frames (default: temp, deleted after)')
    ap.add_argument('--work-dir', default=None,
                    help='Work directory for temp frames (default: auto-cleaned)')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    if not os.path.exists(args.input):
        print(f'SKIP: {args.input} not found — game data missing', file=sys.stderr)
        return 2

    if not _check_ffmpeg():
        print('SKIP: ffmpeg not found in PATH', file=sys.stderr)
        return 2

    frames = [int(x) for x in args.frames.split(',')]

    auto_work = args.work_dir is None
    work_dir = args.work_dir or tempfile.mkdtemp(prefix='vqa-diff-')
    auto_goldens = args.goldens_dir is None
    goldens_root = args.goldens_dir or tempfile.mkdtemp(prefix='vqa-goldens-')

    try:
        # Resolve input to a list of VQA files
        inp = args.input
        if inp.lower().endswith('.vqa'):
            vqa_files = [inp]
        else:
            scan_dir = os.path.join(work_dir, 'scan')
            os.makedirs(scan_dir, exist_ok=True)
            if not args.quiet:
                print(f'Scanning {inp} for VQA data…')
            vqa_files = _find_wvqa_in_file(inp, scan_dir)
            if not vqa_files:
                print(f'SKIP: no WVQA data found in {inp}', file=sys.stderr)
                return 2
            if not args.quiet:
                print(f'  Found {len(vqa_files)} VQA(s)')

        all_pass = True
        results = []

        for vqa_path in vqa_files:
            vqa_stem = Path(vqa_path).stem
            golden_dir = os.path.join(goldens_root, vqa_stem)

            if args.generate_goldens:
                print(f'Generating goldens for {vqa_stem} → {golden_dir}')
                os.makedirs(golden_dir, exist_ok=True)
                gframes = _generate_ffmpeg_golden(vqa_path, golden_dir, frames)
                print(f'  {len(gframes)} frame(s) written')
                continue

            # Check for existing goldens; generate if absent
            golden_frames = {}
            for fidx in frames:
                gp = os.path.join(golden_dir, f'golden_{fidx + 1:04d}.png')
                if os.path.exists(gp):
                    golden_frames[fidx] = gp

            if not golden_frames:
                if not args.quiet:
                    print(f'Generating ffmpeg goldens for {vqa_stem}…')
                os.makedirs(golden_dir, exist_ok=True)
                golden_frames = _generate_ffmpeg_golden(vqa_path, golden_dir, frames)

            if not golden_frames:
                print(f'  SKIP: could not generate any goldens for {vqa_stem}')
                continue

            # Decode via Python reference decoder
            sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
            from vqa_decode_verify import decode_vqa
            test_dir = os.path.join(work_dir, f'ref-{vqa_stem}')
            if not args.quiet:
                print(f'Decoding {vqa_stem} (reference decoder)…')
            # Suppress decode_vqa print output in quiet mode
            if args.quiet:
                import io, contextlib
                with contextlib.redirect_stdout(io.StringIO()):
                    decode_vqa(vqa_path, test_dir, frames_to_dump=set(frames))
            else:
                decode_vqa(vqa_path, test_dir, frames_to_dump=set(frames))

            print(f'\n=== {vqa_stem} (threshold p99 ≤ {args.threshold}) ===')
            for fidx in sorted(golden_frames):
                gpath = golden_frames[fidx]
                tpath = os.path.join(test_dir, f'live_raw_{fidx + 1:03d}.png')

                if not os.path.exists(tpath):
                    print(f'  frame {fidx + 1:4d}: SKIP  (decoder did not produce output)')
                    continue

                diff = _pixel_diff(gpath, tpath)
                if 'error' in diff:
                    print(f'  frame {fidx + 1:4d}: ERROR {diff["error"]}')
                    all_pass = False
                    results.append({'vqa': vqa_stem, 'frame': fidx + 1, 'status': 'ERROR'})
                    continue

                ok = diff['p99'] <= args.threshold
                status = 'PASS' if ok else 'FAIL'
                if not ok:
                    all_pass = False

                if not args.quiet or not ok:
                    print(f'  frame {fidx + 1:4d}: {status}  '
                          f'p99={diff["p99"]:5.1f}  p95={diff["p95"]:5.1f}  '
                          f'mean={diff["mean"]:5.2f}  max={diff["max"]:3d}  '
                          f'({diff["w"]}×{diff["h"]})')
                    if not ok:
                        print(f'           golden: {gpath}')
                        print(f'           test:   {tpath}')

                results.append({
                    'vqa': vqa_stem, 'frame': fidx + 1,
                    'status': status, 'p99': diff['p99'],
                })

        # Summary
        if args.generate_goldens:
            return 0

        print(f'\n{"─" * 60}')
        n_pass = sum(1 for r in results if r['status'] == 'PASS')
        n_fail = sum(1 for r in results if r['status'] in ('FAIL', 'ERROR'))
        print(f'Results: {n_pass} PASS  {n_fail} FAIL  '
              f'(threshold p99 ≤ {args.threshold})')

        if all_pass:
            print('Overall: PASS')
            return 0
        else:
            print('Overall: FAIL')
            return 1

    finally:
        if auto_work and os.path.exists(work_dir):
            shutil.rmtree(work_dir, ignore_errors=True)
        if auto_goldens and os.path.exists(goldens_root):
            shutil.rmtree(goldens_root, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
