#!/usr/bin/env python3
"""Sweep leftover capture state. Manual CLI wrapper around drivers.common.sweep_state.

capture-checkpoint.py already invokes sweep_state() in its finally block, so
under normal operation you never need to run this manually. Use it after a
SIGKILLed or crashed run that didn't reach its cleanup.

Removed: ~/.cache/battlecontrol/wine-prefix-*, wine-capture-*,
         /tmp/.X{92..98}-lock, /tmp/.X11-unix/X{92..98}
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers.common import sweep_state


def main() -> int:
    dirs, locks = sweep_state(verbose=True)
    print(f"\nSwept {dirs} cache dir(s) and {locks} X lock/socket(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
