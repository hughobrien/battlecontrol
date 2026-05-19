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
    capture_ffmpeg,
    kill_process_tree,
)


class NativeCapture:
    """Capture screenshots from the native Linux RA build."""

    def __init__(self, ra_bin=None, data_dir=None):
        self.ra_bin = pathlib.Path(ra_bin) if ra_bin else self._resolve_ra_bin()
        self.data_dir = data_dir

    def _resolve_ra_bin(self) -> pathlib.Path:
        candidates = ["build/ra/redalert", "build/ra/ra", "build/redalert"]
        for c in candidates:
            p = pathlib.Path(c)
            if p.exists():
                return p.resolve()
        env_bin = os.environ.get("RA_BIN")
        if env_bin:
            return pathlib.Path(env_bin)
        raise RuntimeError("native RA binary not found; set RA_BIN or build first")

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture screenshot from native RA at given game frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = ra_proc = None
        try:
            xvfb = start_xvfb(disp, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            env = {
                **os.environ,
                "DISPLAY": disp,
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
            }
            if self.data_dir:
                env["DATA_DIR"] = self.data_dir
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)], env=env, stdout=logfile, stderr=logfile
            )
            # Probe for non-black canvas (up to 45s)
            deadline = time.time() + 45
            found = False
            while time.time() < deadline:
                probe_path = tempfile.mktemp(suffix=".png")
                capture_ffmpeg(disp, probe_path)
                if os.path.exists(probe_path):
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
            capture_ffmpeg(disp, str(cap_path))
            return cap_path
        finally:
            for p in [ra_proc, wm, xvfb]:
                kill_process_tree(p)
