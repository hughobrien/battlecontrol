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
  --label LABEL          label for the comparison (default: "comparison")
  --threshold-ssim FLOAT minimum SSIM to pass (default: 0.90)
  --diff-out PATH        write amplified abs-diff PNG to this path
  --json                 output only the JSON result line (no human-readable prefix)

Exit codes:
  0 = PASS  (SSIM >= threshold)
  1 = FAIL  (SSIM < threshold, or load/size error)
  2 = SKIP  (file not found, or numpy/PIL unavailable)

Notes:
  - If images differ in size, the larger is center-cropped to match the smaller.
    This handles Wine screenshots (800x600 virtual desktop) vs WASM canvas (640x480).
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
    ap.add_argument('--label',          default='comparison')
    ap.add_argument('--threshold-ssim', type=float, default=0.90)
    ap.add_argument('--diff-out',       default=None)
    ap.add_argument('--json',           action='store_true')
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
            print(f'[{st}] {args.label}: ssim={ss:.4f} threshold={args.threshold_ssim} '
                  f'p99={p} fill_a={fa}% fill_b={fb}% size_a={sa} size_b={sb}')
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

    # Center-crop the larger image to the smaller's dimensions
    if (wa, ha) != (wb, hb):
        if wa * ha >= wb * hb:
            img_a = _center_crop(img_a, wb, hb)
            wa, ha = wb, hb
        else:
            img_b = _center_crop(img_b, wa, ha)
            wb, hb = wa, ha

    arr_a = np.array(img_a, dtype=np.uint8)
    arr_b = np.array(img_b, dtype=np.uint8)

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
        'size_a':         f'{wa}x{ha}',
        'size_b':         f'{wb}x{hb}',
    }

    if args.diff_out:
        _write_diff(arr_a, arr_b, args.diff_out)
        result['diff_out'] = args.diff_out

    emit(result)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
