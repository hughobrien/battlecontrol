"""Native capture driver — capture screenshots from native Linux RA build."""

import subprocess
import os
import time
import pathlib
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    capture_root,
    center_mouse,
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
            output_dir.mkdir(parents=True, exist_ok=True)
            ready_path = output_dir / "native-ready.txt"
            bmp_path = output_dir / "capture.bmp"
            try:
                ready_path.unlink()
            except FileNotFoundError:
                pass
            try:
                bmp_path.unlink()
            except FileNotFoundError:
                pass
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            env = {
                **os.environ,
                "DISPLAY": disp,
                "SDL_AUDIODRIVER": "dummy",
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
                "RA_CAPTURE_FPS": os.environ.get("RA_CAPTURE_FPS", "10"),
                "RA_CAPTURE_FRAME": str(max(frame, 1)),
                "RA_CAPTURE_READY_FILE": str(ready_path),
                "RA_CAPTURE_BMP_FILE": str(bmp_path),
            }
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)],
                env=env,
                cwd=str(self.data_dir),
                stdout=logfile,
                stderr=logfile,
            )
            center_mouse(disp, 640, 400)
            # Wait for the in-game frame trap instead of wall-clock guessing.
            deadline = time.time() + 45
            while time.time() < deadline:
                if ready_path.exists():
                    break
                if ra_proc.poll() is not None:
                    raise RuntimeError(
                        f"native RA exited before frame trap (rc={ra_proc.returncode})"
                    )
                time.sleep(0.05)
            else:
                raise RuntimeError("native RA never reached requested capture frame")
            cap_path = output_dir / "capture.png"
            capture_root(disp, str(cap_path))
            return cap_path
        finally:
            teardown_display(disp, ra_proc, wm, xvfb)
