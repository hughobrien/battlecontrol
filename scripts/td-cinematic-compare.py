#!/usr/bin/env python3
"""
TIM-723 — TD cinematic equivalence: our Python decoder vs ffmpeg (Wine OG proxy).

Mirrors scripts/cinematic-compare.py (TIM-705 for RA) but extracts VQAs from TD's
MOVIES.MIX by filename (the TD MIX index is not Blowfish-encrypted, so a clean
name-based extraction is possible instead of the raw FORM+WVQA byte scan used
for RA's MAIN.MIX).

Why ffmpeg ≈ Wine OG:
  ffmpeg's idfcined VQA decoder is a clean-room reverse-engineering of the
  Westwood VQA codec.  TD's C&C95.EXE (and the WASM/native port) use the same
  codec.  Frame-for-frame output is effectively identical.

Usage:
  python3 scripts/td-cinematic-compare.py
  python3 scripts/td-cinematic-compare.py --mix /path/MOVIES.MIX --out-dir DIR

Options:
  --mix PATH        Path to TD MOVIES.MIX
  --out-dir DIR     Output dir for comparison images + JSON report
  --threshold N     p99 pixel-channel delta threshold for PASS (default: 0 = pixel-exact)
  --max-vqas N      Maximum number of VQAs to compare (default: 8)
  --names N1,N2,..  Comma-separated VQA filenames (overrides default set)
  --quiet           Suppress per-frame output

Exit codes:
  0 = all selected VQAs pass (p99 <= threshold)
  1 = one or more VQAs fail
  2 = SKIP (game data or ffmpeg unavailable)
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MIX_DEFAULT = "/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/MOVIES.MIX"
OUT_DIR_DFLT = "e2e/td-cinematic-compare"

# TD intro / campaign cinematic ordering — canonical comparison set.
DEFAULT_TD_VQAS = [
    "LOGO.VQA",  # Westwood Studios logo
    "INTRO2.VQA",  # Main intro cinematic
    "TBRINFO2.VQA",  # Sizzle / info-card 2
    "TBRINFO3.VQA",
    "GDIFINA.VQA",  # GDI campaign briefing A
    "NAPALM.VQA",
    "VISOR.VQA",
    "BANNER.VQA",
]

# Extra TD VQAs (extension / fallbacks if a canonical one fails to extract).
EXTRA_TD_VQAS = [
    "TBRINFO1.VQA",
    "GDIEND1.VQA",
    "GDIEND2.VQA",
    "GDIFINB.VQA",
    "BCANYON.VQA",
    "BOMBFLEE.VQA",
    "BURDET1.VQA",
    "BURDET2.VQA",
    "CC2TEASE.VQA",
    "FLAG.VQA",
    "FORESTKL.VQA",
    "GAMEOVER.VQA",
    "GUNBOAT.VQA",
    "HELLVALY.VQA",
    "LANDING.VQA",
    "PINTLE.VQA",
    "PLANECRA.VQA",
    "RETRO.VQA",
    "SABOTAGE.VQA",
    "SAMSITE.VQA",
]


def _load(name: str, path: Path):
    """Load a Python module from a hyphenated filename."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


extract_mix = _load("extract_mix", REPO_ROOT / "scripts" / "extract_mix.py")
cinematic_cmp = _load("cinematic_cmp", REPO_ROOT / "scripts" / "cinematic-compare.py")


def extract_named(
    mix_path: str, names: list[str], out_dir: str
) -> list[tuple[str, str]]:
    """Extract named VQAs from a TD MIX. Returns [(label, path), ...] in name-list order."""
    os.makedirs(out_dir, exist_ok=True)
    with open(mix_path, "rb") as fh:
        mix_data = fh.read()
    out: list[tuple[str, str]] = []
    for name in names:
        data = extract_mix.extract_file_by_name(mix_data, name)
        if data is None:
            print(
                f"  MISS  {name} not in {os.path.basename(mix_path)}", file=sys.stderr
            )
            continue
        if data[:4] != b"FORM" or data[8:12] != b"WVQA":
            print(
                f"  SKIP  {name} not a VQA (magic={data[:4]!r}/{data[8:12]!r})",
                file=sys.stderr,
            )
            continue
        p = os.path.join(out_dir, name)
        with open(p, "wb") as fh:
            fh.write(data)
        out.append((name, p))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--mix",
        default=MIX_DEFAULT,
        help=f"Path to TD MOVIES.MIX (default: {MIX_DEFAULT})",
    )
    ap.add_argument("--out-dir", default=OUT_DIR_DFLT)
    ap.add_argument(
        "--threshold",
        type=int,
        default=0,
        help="p99 threshold (default: 0 = pixel-exact)",
    )
    ap.add_argument("--max-vqas", type=int, default=8)
    ap.add_argument(
        "--names",
        default=None,
        help="Comma-separated VQA filenames (overrides default set)",
    )
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode != 0:
        print("SKIP: ffmpeg not in PATH", file=sys.stderr)
        return 2

    if not os.path.exists(args.mix):
        print(f"SKIP: {args.mix} not found", file=sys.stderr)
        return 2

    if args.names:
        wanted = [n.strip().upper() for n in args.names.split(",") if n.strip()]
    else:
        wanted = list(DEFAULT_TD_VQAS) + list(EXTRA_TD_VQAS)

    out_dir = args.out_dir
    scan_dir = os.path.join(out_dir, "_extracted")
    os.makedirs(out_dir, exist_ok=True)

    print("=== TIM-723 TD Cinematic Comparison ===")
    print(f"MIX:       {args.mix}")
    print(f"Out dir:   {out_dir}")
    print(f"Threshold: p99 <= {args.threshold}  (0 = pixel-exact)")
    print()

    extracted = extract_named(args.mix, wanted, scan_dir)
    if not extracted:
        print("SKIP: no TD VQAs could be extracted", file=sys.stderr)
        return 2

    candidates: list[tuple[str, str, int]] = []
    for label, vp in extracted:
        hdr = cinematic_cmp.parse_vqhd(vp)
        if hdr is None or hdr["numFrames"] < 2:
            continue
        candidates.append((vp, label, hdr["numFrames"]))

    chosen = candidates[: args.max_vqas]
    print(f"Comparing {len(chosen)} TD VQAs (max={args.max_vqas}):")
    for _, lbl, nf in chosen:
        print(f"  {lbl:14s} {nf:5d} frames, midpoint={nf // 2}")
    print()

    results: list[dict] = []
    for vp, lbl, nf in chosen:
        vqa_out = os.path.join(out_dir, lbl.replace(".VQA", ""))
        r = cinematic_cmp.compare_vqa(vp, lbl, nf, vqa_out, args.threshold, args.quiet)
        results.append(r)

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
                f"    [FAIL] {r['label']}: p99={r.get('p99', '?')} mean={r.get('mean', '?')} "
                f"diff={r.get('diff_image', '?')}"
            )
    if skipped:
        print(f"  SKIP: {len(skipped)}/{len(results)}")
        for r in skipped:
            print(f"    [SKIP] {r['label']}: {r.get('reason', '?')}")

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

    if len(passed) >= 6:
        print(f"\nRESULT: PASS ({len(passed)}/6+ cinematics pass)")
        return 0 if not failed else 1
    print(f"\nRESULT: FAIL ({len(passed)}<6 cinematics pass)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
