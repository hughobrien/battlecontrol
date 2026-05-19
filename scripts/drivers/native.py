"""Native capture driver — capture screenshots from native Linux RA build."""

import subprocess
import os
import time
import pathlib
import tempfile
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    capture_root,
    teardown_display,
)


class NativeCapture:
    """Capture screenshots from the native Linux RA build."""

    def __init__(self, ra_bin=None, data_dir=None):
        ra_bin = ra_bin or os.environ.get("RA_BIN")
        if not ra_bin:
            raise RuntimeError("RA_BIN not set; export RA_BIN=/abs/path/to/ra")
        self.ra_bin = pathlib.Path(ra_bin)
        if not self.ra_bin.is_file():
            raise RuntimeError(f"RA_BIN={self.ra_bin} is not a file")

        data_dir = data_dir or os.environ.get("DATA_DIR")
        if not data_dir:
            raise RuntimeError("DATA_DIR not set; export DATA_DIR=/abs/path/to/ra-data")
        self.data_dir = pathlib.Path(data_dir)
        if not (self.data_dir / "REDALERT.MIX").is_file():
            raise RuntimeError(f"DATA_DIR={self.data_dir} has no REDALERT.MIX")

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture screenshot from native RA at given game frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = ra_proc = None
        try:
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            env = {
                **os.environ,
                "DISPLAY": disp,
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
            }
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)],
                env=env,
                cwd=str(self.data_dir),
                stdout=logfile,
                stderr=logfile,
            )
            # Probe for non-black canvas (up to 45s)
            deadline = time.time() + 45
            found = False
            while time.time() < deadline:
                probe_path = tempfile.mktemp(suffix=".png")
                capture_root(disp, probe_path)
                sz = os.path.getsize(probe_path)
                os.unlink(probe_path)
                if sz >= 5000:
                    found = True
                    break
                time.sleep(1)
            if not found:
                raise RuntimeError("native RA never rendered non-black canvas")
            # Wait remaining frames
            wait = max(frame / 15.0, 1.0)
            time.sleep(wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = output_dir / "capture.png"
            capture_root(disp, str(cap_path))
            return cap_path
        finally:
            teardown_display(disp, ra_proc, wm, xvfb)
