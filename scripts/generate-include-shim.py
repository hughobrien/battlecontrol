#!/usr/bin/env python3
# TIM-5: Generate a case-folding include shim so the original
# Windows-cased upstream sources compile on a case-sensitive Linux
# filesystem without modifying any source file.
#
# We scan REDALERT/ and REDALERT/WIN32LIB/ for every #include "..." /
# #include <...> directive, find the matching header on disk by
# case-insensitive lookup, and create a *relative* symlink in
# build/include-shim/{redalert,win32lib}/<exact-include-spelling>.
#
# Relative symlinks keep the build tree portable (it can be moved or
# rebuilt by another user without rewriting the link targets).
#
# We deliberately do NOT touch any file under REDALERT/ or WIN32LIB/.
# When an include cannot be resolved (e.g. <windows.h>, <objbase.h>) we
# silently skip it; the Win32 stub directory (linux/win32-stubs/) is
# expected to catch those further down the include path.

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

INCLUDE_RE = re.compile(rb'^[ \t]*#[ \t]*include[ \t]*([<"])([^>"]+)[>"]', re.MULTILINE)

# Source dirs we scan for includes, mapped to the shim subdir we drop
# matching headers into. The shim subdir name is what gets added to the
# include path by CMake.
SCAN_TARGETS = [
    ("REDALERT", "redalert"),
    ("REDALERT/WIN32LIB", "win32lib"),
]

# When resolving an include, look in these dirs (relative to repo root)
# in order. First match wins. WIN32LIB is searched after REDALERT so a
# bare <foo.h> that exists in both lands on the REDALERT copy first;
# this matches how the original MSVC project laid out its include path.
RESOLVE_DIRS = [
    "REDALERT",
    "REDALERT/WIN32LIB",
]

# File extensions worth scanning. Keep this list small: we want includes,
# not generated artefacts.
SOURCE_GLOBS = ["*.cpp", "*.CPP", "*.c", "*.C", "*.h", "*.H", "*.inl", "*.INL"]


def collect_source_files(repo_root: Path) -> list[Path]:
    files: list[Path] = []
    for scan_dir, _ in SCAN_TARGETS:
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


def build_resolve_index(repo_root: Path) -> dict[str, list[Path]]:
    """Map lowercased basename -> list of real paths (case-preserving)."""
    index: dict[str, list[Path]] = {}
    for rel in RESOLVE_DIRS:
        base = repo_root / rel
        if not base.is_dir():
            continue
        for entry in base.iterdir():
            if not entry.is_file():
                continue
            key = entry.name.lower()
            index.setdefault(key, []).append(entry)
    return index


def shim_dir_for(spelling: str, repo_root: Path, shim_root: Path,
                 resolved: Path) -> Path | None:
    """Decide which shim subdir an include should live in.

    We use the resolved file's parent dir (REDALERT vs WIN32LIB) so a
    `<ddraw.h>` reference resolves into win32lib/ddraw.h while
    `"buff.h"` lands in redalert/buff.h.
    """
    parent = resolved.parent.name.upper()
    if parent == "WIN32LIB":
        return shim_root / "win32lib"
    if parent == "REDALERT":
        return shim_root / "redalert"
    return None


def make_relative_symlink(link: Path, target: Path) -> None:
    rel_target = os.path.relpath(target, start=link.parent)
    if link.is_symlink() or link.exists():
        # Replace if pointing somewhere else; otherwise leave it.
        try:
            current = os.readlink(link)
            if current == rel_target:
                return
        except OSError:
            pass
        link.unlink()
    link.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(rel_target, link)


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
        # Only remove what we own (symlinks + the two known subdirs).
        for sub in ("redalert", "win32lib"):
            sub_path = shim_root / sub
            if not sub_path.exists():
                continue
            for entry in sub_path.iterdir():
                if entry.is_symlink() or entry.is_file():
                    entry.unlink()

    sources = collect_source_files(repo_root)
    includes = collect_includes(sources)
    index = build_resolve_index(repo_root)

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

        # Prefer a candidate whose REAL directory matches the include's
        # angle-vs-quote intent? We don't know that without re-parsing,
        # so just take the first match. There are no collisions in the
        # current tree (verified by inspection).
        real_path = candidates[0]
        target_dir = shim_dir_for(basename, repo_root, shim_root, real_path)
        if target_dir is None:
            continue
        link_path = target_dir / basename
        if link_path in seen_links:
            continue
        seen_links.add(link_path)
        make_relative_symlink(link_path, real_path)
        created += 1

    # Also create lowercase aliases for every shimmed link, since some
    # source files use bare-lowercase includes (e.g. "buff.h" while disk
    # has BUFF.H). This is a no-op when the include already used the
    # exact lowercase name.
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

    if not args.quiet:
        print(f"shim: created {created} symlinks under {shim_root}")
        if skipped:
            print(f"shim: {len(skipped)} include(s) not resolved (likely "
                  f"system / Win32 — handled by stubs):")
            for s in skipped[:10]:
                print(f"  {s}")
            if len(skipped) > 10:
                print(f"  ... and {len(skipped) - 10} more")

    return 0


if __name__ == "__main__":
    sys.exit(main())
