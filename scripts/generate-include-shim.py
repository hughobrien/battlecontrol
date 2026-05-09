#!/usr/bin/env python3
# TIM-5: Generate a case-folding include shim so the original
# Windows-cased upstream sources compile on a case-sensitive Linux
# filesystem without modifying any source file.
#
# We scan source directories for every #include "..." / #include <...>
# directive, find the matching header on disk by case-insensitive lookup,
# and create a *relative* symlink in build/include-shim/<subdir>/<exact-include-spelling>.
#
# Relative symlinks keep the build tree portable (it can be moved or
# rebuilt by another user without rewriting the link targets).
#
# We deliberately do NOT touch any file under the source directories.
# When an include cannot be resolved (e.g. <windows.h>, <objbase.h>) we
# silently skip it; the Win32 stub directory (linux/win32-stubs/) is
# expected to catch those further down the include path.
#
# TIM-337: Extended to support Tiberian Dawn alongside Red Alert.
# Each game has its own scan/resolve/shim config to prevent cross-game
# header collisions (FUNCTION.H, DEFINES.H, etc. differ between games).

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

INCLUDE_RE = re.compile(rb'^[ \t]*#[ \t]*include[ \t]*([<"])([^>"]+)[>"]', re.MULTILINE)

# Per-game configuration: each entry is processed independently so that
# game-specific headers (e.g. TIBERIANDAWN/FUNCTION.H vs REDALERT/FUNCTION.H)
# never contaminate each other's shim subdirectory.
GAME_CONFIGS = [
    {
        "name": "redalert",
        # (source_dir, shim_subdir) — sources are scanned, shim links go into subdir.
        "scan_targets": [
            ("REDALERT", "redalert"),
            ("REDALERT/WIN32LIB", "win32lib"),
        ],
        # Dirs searched (in order) when resolving an include basename.
        "resolve_dirs": ["REDALERT", "REDALERT/WIN32LIB"],
        # Maps resolved file's parent dir name (upper) → shim subdir.
        "shim_map": {"REDALERT": "redalert", "WIN32LIB": "win32lib"},
    },
    {
        "name": "tiberiandawn",
        "scan_targets": [
            ("TIBERIANDAWN", "tiberiandawn"),
            ("TIBERIANDAWN/WIN32LIB", "td-win32lib"),
        ],
        "resolve_dirs": ["TIBERIANDAWN", "TIBERIANDAWN/WIN32LIB"],
        "shim_map": {"TIBERIANDAWN": "tiberiandawn", "WIN32LIB": "td-win32lib"},
    },
]

# File extensions worth scanning.
SOURCE_GLOBS = ["*.cpp", "*.CPP", "*.c", "*.C", "*.h", "*.H", "*.inl", "*.INL"]


def collect_source_files(repo_root: Path, scan_targets: list[tuple[str, str]]) -> list[Path]:
    files: list[Path] = []
    for scan_dir, _ in scan_targets:
        base = repo_root / scan_dir
        if not base.is_dir():
            continue
        for pattern in SOURCE_GLOBS:
            files.extend(base.glob(pattern))
    return files


def collect_includes(source_files: list[Path]) -> set[str]:
    seen: set[str] = set()
    for src in source_files:
        try:
            data = src.read_bytes()
        except OSError:
            continue
        for match in INCLUDE_RE.finditer(data):
            spelling = match.group(2).decode("latin-1", errors="replace")
            seen.add(spelling)
    return seen


def build_resolve_index(repo_root: Path, resolve_dirs: list[str]) -> dict[str, list[Path]]:
    """Map lowercased basename -> list of real paths (case-preserving)."""
    index: dict[str, list[Path]] = {}
    for rel in resolve_dirs:
        base = repo_root / rel
        if not base.is_dir():
            continue
        for entry in base.iterdir():
            if not entry.is_file():
                continue
            key = entry.name.lower()
            index.setdefault(key, []).append(entry)
    return index


def shim_dir_for(resolved: Path, shim_root: Path, shim_map: dict[str, str]) -> Path | None:
    """Return the shim subdir for a resolved header path, using the game's shim_map.

    The map key is the resolved file's parent directory name (uppercased).
    For REDALERT/ → "redalert", WIN32LIB/ under RA → "win32lib",
    TIBERIANDAWN/ → "tiberiandawn", WIN32LIB/ under TD → "td-win32lib".
    """
    parent_name = resolved.parent.name.upper()
    subdir = shim_map.get(parent_name)
    if subdir is None:
        return None
    return shim_root / subdir


def make_relative_symlink(link: Path, target: Path) -> None:
    rel_target = os.path.relpath(target, start=link.parent)
    if link.is_symlink() or link.exists():
        try:
            current = os.readlink(link)
            if current == rel_target:
                return
        except OSError:
            pass
        link.unlink()
    link.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(rel_target, link)


def process_game(repo_root: Path, shim_root: Path, config: dict, quiet: bool) -> int:
    """Run shim generation for one game config. Returns count of links created."""
    scan_targets = config["scan_targets"]
    resolve_dirs = config["resolve_dirs"]
    shim_map = config["shim_map"]
    game_name = config["name"]

    sources = collect_source_files(repo_root, scan_targets)
    if not sources:
        if not quiet:
            print(f"shim[{game_name}]: no source files found, skipping")
        return 0

    includes = collect_includes(sources)
    index = build_resolve_index(repo_root, resolve_dirs)

    created = 0
    skipped: list[str] = []
    seen_links: set[Path] = set()

    for spelling in sorted(includes):
        # Skip backslash-style includes and absolute paths; these were
        # broken even on Windows and aren't worth shimming.
        if "\\" in spelling or spelling.startswith("/"):
            skipped.append(spelling)
            continue
        # We only shim the basename; nested paths aren't used by the
        # upstream layout for headers we ship.
        basename = os.path.basename(spelling)
        if not basename:
            continue
        candidates = index.get(basename.lower())
        if not candidates:
            # Likely a system or Win32 header — let the stubs/system
            # include path handle it.
            skipped.append(spelling)
            continue

        # For RA: prefer WIN32LIB copy of audio.h (Westwood audio surface).
        # REDALERT/AUDIO.H is dead-code; REDALERT/WIN32LIB/AUDIO.H carries
        # Play_Sample, SFX_Type, Sample_Type consumed by the only include site
        # (REDALERT/WIN32LIB/WWLIB32.H:51).
        real_path = candidates[0]
        if game_name == "redalert" and basename.lower() == "audio.h" and len(candidates) > 1:
            for c in candidates:
                if c.parent.name.upper() == "WIN32LIB":
                    real_path = c
                    break

        target_dir = shim_dir_for(real_path, shim_root, shim_map)
        if target_dir is None:
            continue
        link_path = target_dir / basename
        if link_path in seen_links:
            continue
        seen_links.add(link_path)
        make_relative_symlink(link_path, real_path)
        created += 1

    # Lowercase aliases for every shimmed link (some sources use lowercase includes
    # while the on-disk name is uppercase, e.g. "buff.h" vs BUFF.H).
    for link in list(seen_links):
        lower = link.parent / link.name.lower()
        if lower == link or lower in seen_links:
            continue
        try:
            target = (link.parent / os.readlink(link)).resolve()
        except OSError:
            continue
        make_relative_symlink(lower, target)
        seen_links.add(lower)
        created += 1

    if not quiet:
        print(f"shim[{game_name}]: created {created} symlinks under {shim_root}")
        if skipped:
            print(f"shim[{game_name}]: {len(skipped)} include(s) not resolved (likely "
                  f"system / Win32 — handled by stubs):")
            for s in skipped[:10]:
                print(f"  {s}")
            if len(skipped) > 10:
                print(f"  ... and {len(skipped) - 10} more")

    return created


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True, type=Path)
    ap.add_argument("--shim-root", required=True, type=Path,
                    help="Output dir, e.g. build/include-shim")
    ap.add_argument("--clean", action="store_true",
                    help="Remove the shim root before regenerating")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    repo_root: Path = args.repo_root.resolve()
    shim_root: Path = args.shim_root.resolve()

    if args.clean and shim_root.exists():
        all_subdirs = set()
        for cfg in GAME_CONFIGS:
            for _, subdir in cfg["scan_targets"]:
                all_subdirs.add(subdir)
        for sub in all_subdirs:
            sub_path = shim_root / sub
            if not sub_path.exists():
                continue
            for entry in sub_path.iterdir():
                if entry.is_symlink() or entry.is_file():
                    entry.unlink()

    total = 0
    for config in GAME_CONFIGS:
        total += process_game(repo_root, shim_root, config, args.quiet)

    if not args.quiet:
        print(f"shim: total {total} symlinks created/updated across all games")

    return 0


if __name__ == "__main__":
    sys.exit(main())
