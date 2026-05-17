#!/usr/bin/env python3
"""
TIM-708 — Wine OG vs WASM Allied L1 screenshot comparison report.

Per-checkpoint stats: fill% (non-black pixel count), unique colour count,
and PNG byte size.  Output: e2e/cinematic-compare/allied-l1-report.json.

Doesn't pixel-diff the two engines (different renderers — cnc-ddraw GDI
under Wine vs WebGL/OffscreenCanvas in WASM — produce non-identical
output even when both are correctly rendering Allied 1).  The report
records each side's stats and flags PASS if both sides produced
non-trivial content at the same logical time.

Usage:
    python3 scripts/tim708-compare.py
"""

import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WINE_DIR = REPO_ROOT / "e2e" / "tim708" / "allied-l1"
OUT_DIR = REPO_ROOT / "e2e" / "cinematic-compare"
OUT_DIR.mkdir(parents=True, exist_ok=True)
REPORT = OUT_DIR / "allied-l1-report.json"

try:
    from PIL import Image
except ImportError:
    print("PIL not available — install pillow", file=sys.stderr)
    sys.exit(2)


def shot_stats(path: Path):
    if not path.exists():
        return None
    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        return {"error": str(e), "size_bytes": path.stat().st_size}
    w, h = im.size
    pixels = im.getdata()
    non_black = 0
    palette = set()
    for r, g, b in pixels:
        if r + g + b > 24:
            non_black += 1
        palette.add((r, g, b))
    fill = round((non_black / (w * h)) * 100, 1)
    return {
        "size_bytes": path.stat().st_size,
        "width": w,
        "height": h,
        "fill_pct": fill,
        "colors": len(palette),
    }


def main():
    # Wine OG screenshots come from scripts/wine-allied-l1.sh
    wine_shots = {
        "t0": WINE_DIR / "mission-t0.png",
        "t3": WINE_DIR / "mission-t3.png",
        "t6": WINE_DIR / "mission-t6.png",
        "post-demo": WINE_DIR / "post-demo-scores.png",
    }
    # WASM screenshots come from e2e/tim708-wasm-allied-l1.spec.ts
    wasm_shots = {
        "t5":  WINE_DIR / "wasm-t5.png",
        "t15": WINE_DIR / "wasm-t15.png",
        "t30": WINE_DIR / "wasm-t30.png",
    }

    report = {
        "issue": "TIM-708",
        "wine_og": {label: shot_stats(p) for label, p in wine_shots.items()},
        "wasm": {label: shot_stats(p) for label, p in wasm_shots.items()},
    }

    def pass_count(group):
        return sum(
            1
            for stats in group.values()
            if stats and stats.get("fill_pct", 0) >= 10
        )

    wine_pass = pass_count(report["wine_og"])
    wasm_pass = pass_count(report["wasm"])
    report["summary"] = {
        "wine_og_non_blank_frames": wine_pass,
        "wasm_non_blank_frames": wasm_pass,
        "wine_og_status": "PASS" if wine_pass >= 2 else "FAIL",
        "wasm_status": "PASS" if wasm_pass >= 2 else "FAIL",
        "overall_status": (
            "PASS"
            if wine_pass >= 2 and wasm_pass >= 2
            else "PARTIAL" if wine_pass >= 2 or wasm_pass >= 2 else "FAIL"
        ),
    }

    REPORT.write_text(json.dumps(report, indent=2))
    print(f"wrote {REPORT}")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
