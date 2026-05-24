#!/usr/bin/env python3
"""Reclaim local space used by parity/debugging workflows.

This intentionally only removes generated state owned by this repository:
capture sessions, ephemeral Wine prefixes, local build directories, cache
directories, and Nix GC roots/symlinks created by local builds.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
from collections.abc import Iterable


REPO = pathlib.Path(__file__).resolve().parents[1]
TMP_CAPTURE_ROOT = pathlib.Path("/tmp/battlecontrol")
BUILD_PATHS = (
    "build",
    "build-wasm",
    "build-mingw32",
    "cmake-build-debug",
    "cmake-build-release",
)
CACHE_PATHS = (
    ".pytest_cache",
    ".ruff_cache",
)


def human_size(size: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def path_size(path: pathlib.Path) -> int:
    if path.is_symlink():
        return 0
    if path.is_file():
        try:
            return path.stat().st_size
        except FileNotFoundError:
            return 0
    total = 0
    if path.is_dir():
        for root, dirs, files in os.walk(path, onerror=lambda _err: None):
            root_path = pathlib.Path(root)
            for name in files:
                item = root_path / name
                if item.is_symlink():
                    continue
                try:
                    total += item.stat().st_size
                except FileNotFoundError:
                    pass
            for name in dirs:
                item = root_path / name
                if item.is_symlink():
                    try:
                        total += item.lstat().st_size
                    except FileNotFoundError:
                        pass
    return total


def remove_path(path: pathlib.Path, dry_run: bool, label: str) -> int:
    if not path.exists() and not path.is_symlink():
        return 0
    size = path_size(path)
    action = "would remove" if dry_run else "removed"
    print(f"{action}: {label}: {path} ({human_size(size)})")
    if dry_run:
        return size
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    return size


def cleanup_capture_sessions(root: pathlib.Path, keep: int, dry_run: bool) -> int:
    if not root.exists():
        return 0
    entries = [p for p in root.iterdir() if p.is_dir()]
    entries.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    stale = entries[max(keep, 0) :]
    reclaimed = 0
    for path in stale:
        reclaimed += remove_path(path, dry_run, "old capture session")
    return reclaimed


def cleanup_repo_paths(paths: Iterable[str], dry_run: bool, label: str) -> int:
    reclaimed = 0
    for rel in paths:
        path = REPO / rel
        if not path.exists() and not path.is_symlink():
            continue
        reclaimed += remove_path(path, dry_run, label)
    return reclaimed


def cleanup_result_symlinks(dry_run: bool) -> int:
    reclaimed = 0
    for path in sorted(REPO.glob("result*")):
        if path.name == "results":
            continue
        if path.is_symlink():
            reclaimed += remove_path(path, dry_run, "nix result symlink")
    return reclaimed


def cleanup_python_caches(dry_run: bool) -> int:
    reclaimed = cleanup_repo_paths(CACHE_PATHS, dry_run, "repo cache")
    for path in sorted(REPO.rglob("__pycache__")):
        parts = set(path.parts)
        if ".git" in parts or "node_modules" in parts:
            continue
        reclaimed += remove_path(path, dry_run, "python cache")
    return reclaimed


def cleanup_wine_state(dry_run: bool) -> int:
    sys.path.insert(0, str(REPO / "scripts"))
    from drivers.common import (  # pylint: disable=import-outside-toplevel
        _CACHE_DIR,
        _SWEEP_PATTERNS,
        sweep_state,
    )

    if not dry_run:
        dirs, locks, procs, files = sweep_state(verbose=True)
        print(
            f"swept capture state: {dirs} wine dir(s), {locks} X lock/socket(s), "
            f"{files} file(s), {procs} process(es)"
        )
        return 0

    reclaimed = 0
    cache_root = pathlib.Path(_CACHE_DIR)
    for pattern in _SWEEP_PATTERNS:
        for path in sorted(cache_root.glob(pattern)):
            reclaimed += remove_path(path, dry_run, "stale wine state")
    for display in range(92, 99):
        for path in (
            pathlib.Path(f"/tmp/.X{display}-lock"),
            pathlib.Path(f"/tmp/.X11-unix/X{display}"),
        ):
            reclaimed += remove_path(path, dry_run, "stale X state")
    reclaimed += remove_path(pathlib.Path("/tmp/wine-audio.raw"), dry_run, "wine audio")
    return reclaimed


def run_nix_gc(dry_run: bool) -> None:
    nix_gc = shutil.which("nix-collect-garbage")
    if not nix_gc:
        print("skip: nix-collect-garbage is not on PATH")
        return
    if dry_run:
        print(f"would run: {nix_gc}")
        return
    print("running: nix-collect-garbage")
    subprocess.run([nix_gc], check=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clean generated Battlecontrol capture/build/debug state."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would be removed without deleting anything",
    )
    parser.add_argument(
        "--keep-sessions",
        type=int,
        default=5,
        help="number of newest /tmp/battlecontrol session directories to keep",
    )
    parser.add_argument(
        "--capture-root",
        type=pathlib.Path,
        default=TMP_CAPTURE_ROOT,
        help="capture session root to prune",
    )
    parser.add_argument(
        "--keep-builds",
        action="store_true",
        help="do not remove local CMake/WASM build output directories",
    )
    parser.add_argument(
        "--no-nix-gc",
        action="store_true",
        help="skip nix-collect-garbage",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.keep_sessions < 0:
        print("--keep-sessions must be non-negative", file=sys.stderr)
        return 2

    print(f"repo: {REPO}")
    print(f"capture root: {args.capture_root}")
    if args.dry_run:
        print("mode: dry run")

    reclaimed = 0
    reclaimed += cleanup_wine_state(args.dry_run)
    reclaimed += cleanup_capture_sessions(
        args.capture_root, args.keep_sessions, args.dry_run
    )
    reclaimed += cleanup_python_caches(args.dry_run)
    reclaimed += cleanup_result_symlinks(args.dry_run)
    if not args.keep_builds:
        reclaimed += cleanup_repo_paths(BUILD_PATHS, args.dry_run, "build output")

    print(f"tracked cleanup total: {human_size(reclaimed)}")
    if args.no_nix_gc:
        print("skip: nix-collect-garbage (--no-nix-gc)")
    else:
        run_nix_gc(args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
