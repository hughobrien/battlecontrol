#!/usr/bin/env python3
"""Sweep leftover capture state from a SIGKILLed or crashed run.

What this removes:
  - ~/.cache/battlecontrol/wine-prefix-*    (per-run wineprefix dirs)
  - ~/.cache/battlecontrol/wine-capture-*   (per-run staging dirs)
  - /tmp/.X{92..98}-lock                    (Xvfb lockfiles in our display range)
  - /tmp/.X11-unix/X{92..98}                (matching X11 unix sockets)

What it does NOT touch:
  - ~/.cache/battlecontrol/ra-sendinput.exe (build cache, reusable)
  - /run/user/$UID/wine/server-*            (wineserver IPC dirs — tiny, harmless)
  - Live processes (Xvfb, wineserver, RA95.EXE) — caller's responsibility
"""

import os
import pathlib
import shutil
import sys

CACHE = pathlib.Path.home() / ".cache" / "battlecontrol"
PATTERNS = ("wine-prefix-*", "wine-capture-*")
DISPLAY_RANGE = range(92, 99)


def main() -> int:
    removed_dirs: list[pathlib.Path] = []
    for pat in PATTERNS:
        for p in CACHE.glob(pat):
            shutil.rmtree(p)
            removed_dirs.append(p)
            print(f"removed dir: {p}")

    removed_locks: list[str] = []
    for n in DISPLAY_RANGE:
        for path in (f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                continue
            removed_locks.append(path)
            print(f"removed lock: {path}")

    print(
        f"\nSwept {len(removed_dirs)} cache dir(s) and "
        f"{len(removed_locks)} X lock/socket(s)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
