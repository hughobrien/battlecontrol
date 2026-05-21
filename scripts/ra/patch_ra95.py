#!/usr/bin/env python3
"""Unified RA95.EXE binary patcher."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ra.ra95_patches import (  # noqa: E402
    DEFAULT_RANDOM_SEED,
    PatchError,
    apply_mode,
    mode_patch_ids,
    patch_registry,
)


def _int_auto(value: str) -> int:
    return int(value, 0)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    base = subparsers.add_parser("base", help="apply base RA95 Wine patches")
    base.add_argument("exe_path", metavar="RA95.EXE")
    base.add_argument("--manifest", metavar="PATH")

    mission = subparsers.add_parser("mission", help="apply default Wine mission capture patches")
    mission.add_argument("exe_path", metavar="RA95.EXE")
    mission.add_argument("--scenario", required=True)
    mission.add_argument("--side", choices=("allied", "soviet"))
    mission.add_argument("--seed", default=None)
    mission.add_argument("--no-seed", action="store_true")
    mission.add_argument("--no-vqa-skip", action="store_true")
    mission.add_argument("--no-briefing-skip", action="store_true")
    mission.add_argument("--diagnostic", action="append", default=[], metavar="ID")
    mission.add_argument("--allow-diagnostic", action="store_true")
    mission.add_argument("--allow-quarantined", action="store_true")
    mission.add_argument("--manifest", metavar="PATH")

    apply = subparsers.add_parser("apply", help="apply explicit patch ids")
    apply.add_argument("exe_path", metavar="RA95.EXE")
    apply.add_argument(
        "--patch",
        action="append",
        required=True,
        choices=sorted(patch_registry()),
        metavar="ID",
    )
    apply.add_argument("--scenario")
    apply.add_argument("--side", choices=("allied", "soviet"))
    apply.add_argument("--seed")
    apply.add_argument("--allow-diagnostic", action="store_true")
    apply.add_argument("--allow-quarantined", action="store_true")
    apply.add_argument("--manifest", metavar="PATH")

    return parser


def _print_summary(exe_path: str, result) -> None:
    changed = len(result.changed_ranges)
    print(
        f"{exe_path}: patched "
        f"{result.input_sha256[:12]} -> {result.output_sha256[:12]} "
        f"({changed} changed range{'s' if changed != 1 else ''})"
    )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.mode == "base":
            result = apply_mode("base", args.exe_path, manifest_path=args.manifest)
        elif args.mode == "mission":
            seed = None if args.no_seed else DEFAULT_RANDOM_SEED
            if seed is not None and args.seed is not None:
                seed = _int_auto(args.seed)
            patches = None
            if args.diagnostic:
                patches = mode_patch_ids(
                    "mission",
                    scenario=args.scenario,
                    seed=seed,
                    skip_vqa=not args.no_vqa_skip,
                    skip_briefing=not args.no_briefing_skip,
                )
                patches.extend(args.diagnostic)
            result = apply_mode(
                "mission",
                args.exe_path,
                scenario=args.scenario,
                side=args.side,
                seed=seed,
                patches=patches,
                skip_vqa=not args.no_vqa_skip,
                skip_briefing=not args.no_briefing_skip,
                allow_diagnostic=args.allow_diagnostic,
                allow_quarantined=args.allow_quarantined,
                manifest_path=args.manifest,
            )
        elif args.mode == "apply":
            result = apply_mode(
                "apply",
                args.exe_path,
                scenario=args.scenario,
                side=args.side,
                seed=_int_auto(args.seed) if args.seed is not None else None,
                patches=args.patch,
                allow_diagnostic=args.allow_diagnostic,
                allow_quarantined=args.allow_quarantined,
                manifest_path=args.manifest,
            )
        else:
            raise AssertionError(args.mode)
    except (PatchError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    _print_summary(args.exe_path, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
