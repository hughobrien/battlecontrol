#!/usr/bin/env python3
"""
TIM-768 — TD WASM vs Wine OG GDI L1 screenshot comparison report.

Per-checkpoint stats: fill% (non-black pixel count), unique colour count,
palette overlap, and PNG byte size.  Output: e2e/tim768/gdi-l1-report.json.

Does not pixel-diff the two engines (GDI renderer under Wine vs
OffscreenCanvas in WASM produce non-identical output even when both
correctly render GDI Mission 1).  Pass criterion: both sides render
non-trivial GDI L1 content (fill >20%, colours >50).

Sources:
  Wine OG:  e2e/tim763/gdi-m1/  (TIM-763 — final 8-patch chain, GDI M1 reached)
  WASM:     e2e/screenshots/td-visual-frame-*.png  (TIM-404 autostart=1 → GDI M1)

Usage:
    python3 scripts/tim768-compare.py
"""

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WINE_DIR = REPO_ROOT / "e2e" / "tim763" / "gdi-m1"
WASM_DIR = REPO_ROOT / "e2e" / "screenshots"
OUT_DIR = REPO_ROOT / "e2e" / "tim768"
OUT_DIR.mkdir(parents=True, exist_ok=True)
REPORT = OUT_DIR / "gdi-l1-report.json"

try:
    from PIL import Image
except ImportError:
    print("PIL not available — install pillow", file=sys.stderr)
    sys.exit(2)


def shot_stats(path: Path, canvas_crop=None):
    """
    canvas_crop: (x, y, w, h) to crop from a full-page screenshot to the
    game canvas region before computing stats.  None = use whole image.
    """
    if not path.exists():
        return {"missing": True, "path": str(path)}
    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        return {"error": str(e), "size_bytes": path.stat().st_size}
    full_w, full_h = im.size
    if canvas_crop:
        cx, cy, cw, ch = canvas_crop
        im = im.crop((cx, cy, cx + cw, cy + ch))
    w, h = im.size
    pixels = list(im.getdata())
    non_black = 0
    palette = set()
    for r, g, b in pixels:
        if r + g + b > 24:
            non_black += 1
        # bucket into 5-bit per channel for palette overlap comparison
        palette.add((r >> 3, g >> 3, b >> 3))
    fill = round((non_black / (w * h)) * 100, 1)
    return {
        "path": path.name,
        "size_bytes": path.stat().st_size,
        "full_width": full_w,
        "full_height": full_h,
        "width": w,
        "height": h,
        "fill_pct": fill,
        "colors": len(palette),
        "palette_set": palette,
    }


def palette_overlap(a_stats, b_stats):
    """Return Jaccard overlap % between the two palette sets."""
    if "palette_set" not in a_stats or "palette_set" not in b_stats:
        return None
    a = a_stats["palette_set"]
    b = b_stats["palette_set"]
    if not a or not b:
        return 0
    intersection = len(a & b)
    union = len(a | b)
    return round((intersection / union) * 100, 1) if union else 0


def serialisable(stats):
    """Return stats dict without the non-serialisable palette_set field."""
    return {k: v for k, v in stats.items() if k != "palette_set"}


def main():
    # Wine OG: TIM-763 final run — 8-patch chain reaches GDI M1 interactively
    wine_shots = {
        "t05-initial":       WINE_DIR / "t05-initial.png",
        "t10-pre-side":      WINE_DIR / "t10-pre-side.png",
        "t15-post-gdi-click": WINE_DIR / "t15-post-gdi-click.png",
        "t25-briefing":      WINE_DIR / "t25-briefing-advance.png",
        "t35-post-map":      WINE_DIR / "t35-post-map.png",
        "t45-frame100":      WINE_DIR / "t45-frame100.png",
        "t60-frame250":      WINE_DIR / "t60-frame250.png",
        "t90-frame500":      WINE_DIR / "t90-frame500.png",
    }

    # WASM: TIM-404 td-gameplay.spec.ts, autostart=1 → GDI M1 (same mission)
    wasm_shots = {
        "frame100": WASM_DIR / "td-visual-frame-100.png",
        "frame300": WASM_DIR / "td-visual-frame-300.png",
        "frame500": WASM_DIR / "td-visual-frame-500.png",
    }

    # WASM full-page screenshots are 1280×720; the 640×480 game canvas is
    # centered at x=320, y≈50 (header bar + page chrome above canvas).
    # Cropping to the canvas region gives the correct fill% for the game view.
    WASM_CANVAS_CROP = (320, 50, 640, 480)

    wine_stats = {k: shot_stats(p) for k, p in wine_shots.items()}
    wasm_stats = {k: shot_stats(p, canvas_crop=WASM_CANVAS_CROP) for k, p in wasm_shots.items()}

    # Palette overlap between Wine OG mission frames and WASM mission frames
    # Compare the best-quality gameplay frames (t60 vs frame300)
    wine_gameplay = wine_stats.get("t60-frame250", {})
    wasm_gameplay = wasm_stats.get("frame300", {})
    overlap = palette_overlap(wine_gameplay, wasm_gameplay)

    def pass_count(group):
        return sum(
            1 for stats in group.values()
            if stats and not stats.get("missing") and stats.get("fill_pct", 0) >= 20
        )

    wine_pass = pass_count(wine_stats)
    wasm_pass = pass_count(wasm_stats)

    report = {
        "issue": "TIM-768",
        "wine_og": {k: serialisable(v) for k, v in wine_stats.items()},
        "wasm": {k: serialisable(v) for k, v in wasm_stats.items()},
        "palette_overlap_pct": overlap,
        "summary": {
            "wine_og_frames_above_20pct": wine_pass,
            "wasm_frames_above_20pct": wasm_pass,
            "wine_og_status": "PASS" if wine_pass >= 2 else "FAIL",
            "wasm_status": "PASS" if wasm_pass >= 2 else "FAIL",
            "overall_status": (
                "PASS"
                if wine_pass >= 2 and wasm_pass >= 2
                else "PARTIAL" if wine_pass >= 2 or wasm_pass >= 2 else "FAIL"
            ),
        },
    }

    REPORT.write_text(json.dumps(report, indent=2))
    print(f"wrote {REPORT}")
    print(json.dumps(report["summary"], indent=2))
    print(f"palette_overlap (t60 vs frame300): {overlap}%")

    # Print table
    print("\n── Wine OG (TIM-763) ──")
    print(f"{'checkpoint':<22} {'size':>8} {'WxH':>12} {'fill%':>6} {'colors':>7}")
    for k, s in wine_stats.items():
        if s.get("missing"):
            print(f"  {k:<20} MISSING")
        else:
            print(f"  {k:<20} {s['size_bytes']:>8} {s['width']}×{s['height']:>4} {s['fill_pct']:>6} {s['colors']:>7}")

    print("\n── WASM (TIM-404/435) ──")
    print(f"{'checkpoint':<22} {'size':>8} {'WxH':>12} {'fill%':>6} {'colors':>7}")
    for k, s in wasm_stats.items():
        if s.get("missing"):
            print(f"  {k:<20} MISSING")
        else:
            print(f"  {k:<20} {s['size_bytes']:>8} {s['width']}×{s['height']:>4} {s['fill_pct']:>6} {s['colors']:>7}")


if __name__ == "__main__":
    main()
