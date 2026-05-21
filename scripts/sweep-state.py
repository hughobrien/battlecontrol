#!/usr/bin/env python3
"""Sweep leftover capture state. Manual CLI wrapper around drivers.common.sweep_state.

Use this manually after a SIGKILLed or crashed run that didn't reach its cleanup,
or call it from batch tooling before long matrix/strip capture runs.

Removed: ~/.cache/battlecontrol/wine-prefix-*, wine-capture-*,
         /tmp/.X{92..98}-lock, /tmp/.X11-unix/X{92..98},
         /tmp/wine-audio.raw,
         orphan Xvfb/openbox processes on displays :92..:98
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers.common import sweep_state


def main() -> int:
    dirs, locks, procs, files = sweep_state(verbose=True)
    print(
        f"\nSwept {dirs} cache dir(s), {locks} X lock/socket(s), {files} file(s), "
        f"and {procs} process(es)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
