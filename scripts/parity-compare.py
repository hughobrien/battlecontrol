#!/usr/bin/env python3
"""
Screenshot parity comparison — SSIM + fill% + p99 pixel diff.

Compares two PNG screenshots and reports structural similarity and pixel diff
metrics.  Used by TIM-710 to validate WASM vs Wine OG visual parity.

Usage:
  python3 scripts/parity-compare.py <path-a> <path-b> [options]

  path-a     Reference PNG (e.g. Wine OG screenshot)
  path-b     Test PNG (e.g. WASM canvas screenshot)

Options:
  --label LABEL            label for the comparison (default: "comparison")
  --threshold-ssim FLOAT   minimum SSIM to pass (default: 0.90)
  --diff-out PATH          write amplified abs-diff PNG to this path
  --json                   output only the JSON result line (no human-readable prefix)
  --crop-bottom N          remove N rows from bottom of both images before comparing
                           (use to mask known-different regions like command bar)
  --no-align               disable content-based alignment (old center-crop behavior)

Exit codes:
  0 = PASS  (SSIM >= threshold)
  1 = FAIL  (SSIM < threshold, or load/size error)
  2 = SKIP  (file not found, or numpy/PIL unavailable)

Notes:
  - If images differ in size, content-based auto-registration is used instead of
    naive center-cropping.  This handles window decoration offsets (e.g. openbox
    title bar in Wine Xvfb captures) that would produce translation-misaligned
    SSIM.
  - SSIM is computed on grayscale luminance (BT.601 Y = 0.299R + 0.587G + 0.114B).
  - Global (image-level) SSIM is used rather than windowed SSIM; sufficient for
    full-frame structural comparisons.
"""

import argparse
import json
import os
import sys


def _load_deps():
    try:
        import numpy as np
        from PIL import Image
        return np, Image
    except ImportError as e:
        return None, None


def _compute_ssim(luma_a, luma_b):
    """Global SSIM between two float64 luminance arrays (Wang et al. 2004)."""
    import numpy as np
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2
    mu_a = luma_a.mean()
    mu_b = luma_b.mean()
    sigma_a2 = ((luma_a - mu_a) ** 2).mean()
    sigma_b2 = ((luma_b - mu_b) ** 2).mean()
    sigma_ab = float(np.mean((luma_a - mu_a) * (luma_b - mu_b)))
    num = (2.0 * mu_a * mu_b + C1) * (2.0 * sigma_ab + C2)
    den = (mu_a ** 2 + mu_b ** 2 + C1) * (sigma_a2 + sigma_b2 + C2)
    return float(num / den) if den != 0.0 else 0.0


def _fill_pct(arr):
    """Percentage of pixels where any RGB channel > 15 (non-black)."""
    import numpy as np
    return round(float(np.any(arr > 15, axis=2).mean() * 100), 1)


def _p99_diff(arr_a, arr_b):
    """99th percentile absolute per-channel pixel difference."""
    import numpy as np
    d = np.abs(arr_a.astype(np.int32) - arr_b.astype(np.int32)).flatten()
    return int(np.percentile(d, 99))


def _center_crop(img, target_w, target_h):
    """Center-crop a PIL Image to (target_w, target_h)."""
    w, h = img.size
    x = (w - target_w) // 2
    y = (h - target_h) // 2
    return img.crop((x, y, x + target_w, y + target_h))


def _content_bbox(arr, threshold=15):
    """
    Find bounding box of content (pixels with any channel > threshold).
    Returns (x1, y1, x2, y2) or None if entirely black.
    """
    import numpy as np
    mask = np.any(arr > threshold, axis=2)
    if not mask.any():
        return None
    rows = np.any(mask, axis=1)
    cols = np.any(mask, axis=0)
    y1 = int(np.argmax(rows))
    y2 = int(len(rows) - 1 - np.argmax(rows[::-1]))
    x1 = int(np.argmax(cols))
    x2 = int(len(cols) - 1 - np.argmax(cols[::-1]))
    return (x1, y1, x2, y2)


def _register_images(arr_a, arr_b, threshold=15):
    """
    Register two images by detecting content bounding boxes and finding
    the optimal translation via cross-correlation on luminance.

    Returns (cropped_a, cropped_b, offset_y, offset_x) where both arrays
    are the same size (the intersection of the content-aligned regions).
    Applies the detected translation so that the content in b is shifted
    to align with the content in a.
    """
    import numpy as np

    def to_luma(arr):
        r = arr[:, :, 0].astype(np.float64)
        g = arr[:, :, 1].astype(np.float64)
        b = arr[:, :, 2].astype(np.float64)
        return 0.299 * r + 0.587 * g + 0.114 * b

    # First: find content bounding boxes
    bbox_a = _content_bbox(arr_a, threshold)
    bbox_b = _content_bbox(arr_b, threshold)

    # If either is all-black, fall back to center crop
    if bbox_a is None or bbox_b is None:
        h = min(arr_a.shape[0], arr_b.shape[0])
        w = min(arr_a.shape[1], arr_b.shape[1])
        return arr_a[:h, :w], arr_b[:h, :w], 0, 0

    # Crop both to content bounding box
    x1a, y1a, x2a, y2a = bbox_a
    x1b, y1b, x2b, y2b = bbox_b
    crop_a = arr_a[y1a:y2a+1, x1a:x2a+1]
    crop_b = arr_b[y1b:y2b+1, x1b:x2b+1]

    # Compute luminance for cross-correlation
    luma_a = to_luma(crop_a)
    luma_b = to_luma(crop_b)

    ha, wa = luma_a.shape
    hb, wb = luma_b.shape

    # Normalise both for illumination-invariant correlation
    def _norm(x):
        mu = x.mean()
        sigma = x.std()
        if sigma < 1e-6:
            return np.zeros_like(x)
        return (x - mu) / sigma

    norm_a = _norm(luma_a)
    norm_b = _norm(luma_b)

    # FFT-based cross-correlation to find translation
    pad_h = max(ha, hb)
    pad_w = max(wa, wb)
    fft_a = np.fft.rfft2(norm_a, s=(pad_h * 2, pad_w * 2))
    fft_b = np.fft.rfft2(norm_b, s=(pad_h * 2, pad_w * 2))
    corr = np.fft.irfft2(fft_a * np.conj(fft_b))
    peak = np.unravel_index(np.argmax(corr), corr.shape)
    # peak gives the shift of b relative to a
    dy = peak[0] if peak[0] < pad_h else peak[0] - 2 * pad_h
    dx = peak[1] if peak[1] < pad_w else peak[1] - 2 * pad_w

    # Clip to valid range
    dy = int(np.clip(dy, -hb + 1, ha - 1))
    dx = int(np.clip(dx, -wb + 1, wa - 1))

    # Apply translation to align b onto a: compute the intersection
    if dy >= 0:
        y_start_a, y_end_a = dy, min(ha, hb + dy)
        y_start_b, y_end_b = 0, min(hb, ha - dy)
    else:
        y_start_a, y_end_a = 0, min(ha, hb + dy)
        y_start_b, y_end_b = -dy, min(hb, ha - dy)

    if dx >= 0:
        x_start_a, x_end_a = dx, min(wa, wb + dx)
        x_start_b, x_end_b = 0, min(wb, wa - dx)
    else:
        x_start_a, x_end_a = 0, min(wa, wb + dx)
        x_start_b, x_end_b = -dx, min(wb, wa - dx)

    oh = min(y_end_a - y_start_a, y_end_b - y_start_b)
    ow = min(x_end_a - x_start_a, x_end_b - x_start_b)
    if oh < 1 or ow < 1:
        oh = min(ha, hb)
        ow = min(wa, wb)
        return crop_a[:oh, :ow], crop_b[:oh, :ow], 0, 0

    aligned_a = crop_a[y_start_a:y_start_a + oh, x_start_a:x_start_a + ow]
    aligned_b = crop_b[y_start_b:y_start_b + oh, x_start_b:x_start_b + ow]
    return aligned_a, aligned_b, dy, dx


def _write_diff(arr_a, arr_b, out_path):
    """Write an amplified absolute-difference PNG (x8) to out_path."""
    import numpy as np
    from PIL import Image
    diff = np.abs(arr_a.astype(np.int32) - arr_b.astype(np.int32)).astype(np.uint8)
    amplified = np.clip(diff * 8, 0, 255).astype(np.uint8)
    Image.fromarray(amplified).save(out_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('path_a', help='Reference PNG (Wine OG)')
    ap.add_argument('path_b', help='Test PNG (WASM)')
    ap.add_argument('--label',            default='comparison')
    ap.add_argument('--threshold-ssim',   type=float, default=0.90)
    ap.add_argument('--diff-out',         default=None)
    ap.add_argument('--json',             action='store_true')
    ap.add_argument('--crop-bottom',      type=int, default=0,
                    help='remove N rows from bottom of both images before comparing')
    ap.add_argument('--no-align',         action='store_true',
                    help='disable content-based alignment (old center-crop behavior)')
    ap.add_argument('--print-bbox',       action='store_true',
                    help='print detected content bounding boxes and exit (no SSIM)')
    args = ap.parse_args()

    def emit(result):
        if not args.json:
            st = result.get('status', '?')
            ss = result.get('ssim', 0)
            p  = result.get('p99_diff', '?')
            fa = result.get('fill_a', '?')
            fb = result.get('fill_b', '?')
            err = result.get('error', '')
            sa = result.get('size_a', '?')
            sb = result.get('size_b', '?')
            of = result.get('offset', '?')
            print(f'[{st}] {args.label}: ssim={ss:.4f} threshold={args.threshold_ssim} '
                  f'p99={p} fill_a={fa}% fill_b={fb}% size_a={sa} size_b={sb}'
                  + (f' offset=({of})' if of != '?' else ''))
            if err:
                print(f'  error: {err}')
        print(json.dumps(result))

    for p in [args.path_a, args.path_b]:
        if not os.path.exists(p):
            emit({'status': 'SKIP', 'error': f'file not found: {p}',
                  'ssim': 0, 'p99_diff': None, 'fill_a': None, 'fill_b': None,
                  'label': args.label, 'threshold_ssim': args.threshold_ssim})
            return 2

    np, Image = _load_deps()
    if np is None:
        emit({'status': 'SKIP', 'error': 'numpy or Pillow not available',
              'ssim': 0, 'p99_diff': None, 'fill_a': None, 'fill_b': None,
              'label': args.label, 'threshold_ssim': args.threshold_ssim})
        return 2

    img_a = Image.open(args.path_a).convert('RGB')
    img_b = Image.open(args.path_b).convert('RGB')
    wa, ha = img_a.size
    wb, hb = img_b.size

    arr_a = np.array(img_a, dtype=np.uint8)
    arr_b = np.array(img_b, dtype=np.uint8)

    # --print-bbox: just show detected content boxes and exit
    if args.print_bbox:
        bbox_a = _content_bbox(arr_a)
        bbox_b = _content_bbox(arr_b)
        result = {
            'label':  args.label,
            'bbox_a': {'x1': bbox_a[0], 'y1': bbox_a[1], 'x2': bbox_a[2], 'y2': bbox_a[3]} if bbox_a else None,
            'bbox_b': {'x1': bbox_b[0], 'y1': bbox_b[1], 'x2': bbox_b[2], 'y2': bbox_b[3]} if bbox_b else None,
            'size_a': f'{wa}x{ha}',
            'size_b': f'{wb}x{hb}',
        }
        print(json.dumps(result))
        return 0

    # Register images: either content-based alignment or legacy center-crop
    offset_y = 0
    offset_x = 0
    if (wa, ha) != (wb, hb) and not args.no_align:
        arr_a, arr_b, offset_y, offset_x = _register_images(arr_a, arr_b)
    elif (wa, ha) != (wb, hb):
        # Legacy center-crop path
        if wa * ha >= wb * hb:
            pil_a = Image.fromarray(arr_a)
            pil_a = _center_crop(pil_a, wb, hb)
            arr_a = np.array(pil_a, dtype=np.uint8)
        else:
            pil_b = Image.fromarray(arr_b)
            pil_b = _center_crop(pil_b, wa, ha)
            arr_b = np.array(pil_b, dtype=np.uint8)

    # Optionally crop bottom N rows from both (mask known-different regions)
    if args.crop_bottom > 0 and args.crop_bottom < min(arr_a.shape[0], arr_b.shape[0]):
        arr_a = arr_a[:arr_a.shape[0] - args.crop_bottom, :, :]
        arr_b = arr_b[:arr_b.shape[0] - args.crop_bottom, :, :]

    # Grayscale luminance (BT.601)
    def to_luma(a):
        r, g, b = a[:, :, 0].astype(np.float64), a[:, :, 1].astype(np.float64), a[:, :, 2].astype(np.float64)
        return 0.299 * r + 0.587 * g + 0.114 * b

    ssim   = _compute_ssim(to_luma(arr_a), to_luma(arr_b))
    p99    = _p99_diff(arr_a, arr_b)
    fill_a = _fill_pct(arr_a)
    fill_b = _fill_pct(arr_b)
    passed = ssim >= args.threshold_ssim

    result = {
        'label':          args.label,
        'status':         'PASS' if passed else 'FAIL',
        'ssim':           round(ssim, 4),
        'threshold_ssim': args.threshold_ssim,
        'p99_diff':       p99,
        'fill_a':         fill_a,
        'fill_b':         fill_b,
        'size_a':         f'{arr_a.shape[1]}x{arr_a.shape[0]}',
        'size_b':         f'{arr_b.shape[1]}x{arr_b.shape[0]}',
        'offset':         f'{offset_y},{offset_x}',
    }

    if args.diff_out:
        _write_diff(arr_a, arr_b, args.diff_out)
        result['diff_out'] = args.diff_out

    emit(result)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
