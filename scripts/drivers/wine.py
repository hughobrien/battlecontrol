"""Wine capture driver — capture screenshots from RA95.EXE under Wine."""

import subprocess
import os
import time
import pathlib
import tempfile
import shutil
from .common import (
    kill_process_tree,
    pick_free_display,
    start_xvfb,
    start_openbox,
    wait_for_window,
    capture_ffmpeg,
)


class WineCapture:
    """Capture screenshots from RA95.EXE under Wine.

    Generalized parameterization of wine-allied-l1.sh / wine-vqa-capture.sh.

    Notes from the retired wine-cnc-capture.sh (kept for reference):

      REDALERT.INI — the game's default config matters for headless capture.
      The retired script wrote:
        [Sound] Card=-1
        [Options] HardwareFills=no
        [Intro] PlayIntro=no
      PlayIntro=no skips the intro logo sequence automatically.

      ddraw.ini — cnc-ddraw config. The retired script additionally set:
        fake_mode=640x400x8   — forces a specific resolution in GDI mode
        no_compat_warning=true — suppresses the ddraw compat dialog
      If capture produces wrong-sized or blank frames, try adding these.

      TIMED=1 mode — the retired script had an alternative capture mode
      that took screenshots every 5 seconds for 30 seconds (for investigating
      game state transitions). The current driver captures a single frame.

      ImageMagick alternative — the retired script used `import -window root`
      instead of ffmpeg x11grab for screenshots. If ffmpeg capture produces
      blank frames, `import` is a viable fallback.
    """

    VQA_TIMINGS = {
        "WESTWOOD": 15.0,
        "RA_LOGO": 5.0,
        "INTRO2": 62.0,
        "ENGLISH": 80.0,
        "PROLOG": 6.0,
        "ALLY1": 8.0,
        "SOVIET1": 8.0,
        "SOVIET2": 12.0,
    }

    def __init__(
        self,
        wine="/usr/bin/wine",
        wineprefix=None,
        ra_exe=None,
        cnc_ddraw_dir="/tmp/cnc-ddraw-master",
        data_dir="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1",
        scripts_dir=None,
    ):
        self.wine = pathlib.Path(wine)
        self.wineprefix = pathlib.Path(wineprefix) if wineprefix else None
        self.ra_exe = pathlib.Path(ra_exe) if ra_exe else self._resolve_ra_exe()
        self.cnc_ddraw_dir = pathlib.Path(cnc_ddraw_dir)
        self.data_dir = pathlib.Path(data_dir)
        if scripts_dir:
            self.scripts_dir = pathlib.Path(scripts_dir)
        else:
            self.scripts_dir = pathlib.Path(__file__).resolve().parent.parent
        self._ensure_build_inputs()

    def _resolve_ra_exe(self) -> pathlib.Path:
        r = subprocess.run(
            ["nix", "build", ".#ra-patched-exe", "--impure", "--print-out-paths"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if r.returncode != 0:
            # Fallback: check RA_EXE_PATH env var
            env_path = os.environ.get("RA_EXE_PATH")
            if env_path:
                return pathlib.Path(env_path)
            raise RuntimeError("RA95.EXE not found via nix. Set RA_EXE_PATH env var.")
        return pathlib.Path(r.stdout.strip())

    def _ensure_build_inputs(self):
        """Compile ra-sendinput.exe if needed."""
        src = self.scripts_dir / ".." / "tools" / "wine-input" / "ra-sendinput.c"
        self._sendinput_exe = pathlib.Path(tempfile.gettempdir()) / "ra-sendinput.exe"
        if not self._sendinput_exe.exists() or (
            src.exists() and src.stat().st_mtime > self._sendinput_exe.stat().st_mtime
        ):
            subprocess.run(
                [
                    "i686-w64-mingw32-gcc",
                    "-o",
                    str(self._sendinput_exe),
                    str(src),
                    "-luser32",
                ],
                capture_output=True,
                timeout=60,
            )

    def _patch_chain(self, exe: pathlib.Path, scenario=None, skip_vqa=True):
        patches = [
            "ra/ra-focus-skip-patch.py",
            "ra/ra-game-in-focus-patch.py",
        ]
        if skip_vqa:
            patches.append("ra/ra-vqa-skip-patch.py")
        if scenario:
            patches.append("ra-scenario-patch.py")
        patches.append("ra-autostart-patch.py")
        for name in patches:
            script = self.scripts_dir / name
            if not script.exists():
                continue
            cmd = ["python3", str(script), str(exe)]
            if name == "ra-scenario-patch.py" and scenario:
                cmd.append(scenario)
            subprocess.run(cmd, capture_output=True, timeout=30)

    def _setup_staging(self, scenario=None, skip_vqa=True) -> pathlib.Path:
        staging = pathlib.Path(tempfile.mkdtemp(prefix="wine-capture-"))
        for f in self.data_dir.glob("*.MIX"):
            (staging / f.name).symlink_to(f)
        for f in self.data_dir.glob("*.INI"):
            (staging / f.name).symlink_to(f)
        shutil.copy2(self.ra_exe, staging / "RA95.EXE")
        (staging / "RA95.EXE").chmod(0o755)
        dll_dir = self.ra_exe.parent
        for dll in ["THIPX32.DLL", "THIPX16.DLL"]:
            src = dll_dir / dll
            if src.exists():
                shutil.copy2(src, staging / dll)
        # cnc-ddraw
        shutil.copy2(self.cnc_ddraw_dir / "ddraw.dll", staging / "ddraw.dll")
        (staging / "ddraw.ini").write_text(
            "[ddraw]\nrenderer=gdi\nwindowed=true\nhook=0\n"
            "window_state=normal\nmaxfps=30\n\n"
            "[ra95]\nscanline_double=true\n"
        )
        (staging / "REDALERT.INI").write_text(
            "[Sound]\nCard=-1\n\n"
            "[Options]\nHardwareFills=no\n\n"
            "[Intro]\nPlayIntro=no\n"
        )
        self._patch_chain(staging / "RA95.EXE", scenario, skip_vqa)
        return staging

    def _ensure_wineprefix(self, staging: pathlib.Path):
        if self.wineprefix is None:
            self.wineprefix = pathlib.Path(tempfile.mkdtemp(prefix="wine-capture-"))
        if not self.wineprefix.exists():
            subprocess.run(
                [str(self.wine), "wineboot", "--init"],
                env={
                    **os.environ,
                    "WINEPREFIX": str(self.wineprefix),
                    "WINEDEBUG": "-all",
                },
                capture_output=True,
                timeout=120,
            )
            # Configure GDI renderer + virtual desktop for headless Xvfb capture
            subprocess.run(
                [str(self.wine), "reg", "add",
                 r"HKCU\Software\Wine\Explorer\Desktops",
                 "/v", "Default", "/t", "REG_SZ", "/d", "640x480", "/f"],
                env={**os.environ, "WINEPREFIX": str(self.wineprefix),
                     "WINEDEBUG": "-all"},
                capture_output=True, timeout=30,
            )
            subprocess.run(
                [str(self.wine), "reg", "add",
                 r"HKCU\Software\Wine\Direct3D",
                 "/v", "DirectDrawRenderer", "/t", "REG_SZ", "/d", "gdi", "/f"],
                env={**os.environ, "WINEPREFIX": str(self.wineprefix),
                     "WINEDEBUG": "-all"},
                capture_output=True, timeout=30,
            )
        dos = self.wineprefix / "dosdevices"
        dos.mkdir(parents=True, exist_ok=True)
        d_link = dos / "d:"
        if d_link.exists() or d_link.is_symlink():
            d_link.unlink()
        d_link.symlink_to(staging)

    def _launch(self, staging: pathlib.Path, logfile) -> subprocess.Popen:
        return subprocess.Popen(
            [str(self.wine), str(staging / "RA95.EXE")],
            cwd=str(staging),
            env={
                **os.environ,
                "WINEPREFIX": str(self.wineprefix),
                "WINEDLLOVERRIDES": "ddraw=n;mscoree=;mshtml=",
                "WINEDEBUG": "-all",
                "AUDIODEV": "null",
                "WAYLAND_DISPLAY": "",
            },
            stdout=logfile,
            stderr=logfile,
        )

    def _cleanup(self, staging, wine_proc, xvfb, wm):
        for p in [wine_proc, wm, xvfb]:
            kill_process_tree(p)
        subprocess.run(
            ["wineserver", "-k"],
            env={**os.environ, "WINEPREFIX": str(self.wineprefix)},
            capture_output=True,
            timeout=10,
        )
        shutil.rmtree(staging, ignore_errors=True)
        if self.wineprefix and self.wineprefix.name.startswith("wine-capture-"):
            shutil.rmtree(self.wineprefix, ignore_errors=True)

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a mission at the given game frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(scenario, skip_vqa=True)
        try:
            xvfb = start_xvfb(disp, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._ensure_wineprefix(staging)
            wine_proc = self._launch(staging, logfile)
            if not wait_for_window(disp, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            # Dismiss DirectSound dialog, skip VQAs
            time.sleep(5)
            subprocess.run(
                ["xdotool", "key", "Return"],
                env={**os.environ, "DISPLAY": disp},
                capture_output=True,
                timeout=5,
            )
            # Wait for target frame
            frame_wait = max(frame / 15.0, 3.0)
            time.sleep(frame_wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = output_dir / "capture.png"
            capture_ffmpeg(disp, str(cap_path))
            return cap_path
        finally:
            self._cleanup(staging, wine_proc, xvfb, wm)

    def capture_vqa(
        self, vqa_stem: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a VQA at the given frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(None, skip_vqa=False)
        try:
            xvfb = start_xvfb(disp, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._ensure_wineprefix(staging)
            wine_proc = self._launch(staging, logfile)
            if not wait_for_window(disp, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            # Dismiss boot dialogs
            time.sleep(5)
            subprocess.run(
                ["xdotool", "key", "Return"],
                env={**os.environ, "DISPLAY": disp},
                capture_output=True,
                timeout=5,
            )
            time.sleep(1)
            subprocess.run(
                ["xdotool", "key", "Return"],
                env={**os.environ, "DISPLAY": disp},
                capture_output=True,
                timeout=5,
            )
            # Wait for VQA start + frame offset
            pre_vqa = self._get_vqa_offsets().get(vqa_stem, 0.0)
            frame_time = frame / 15.0
            wait = pre_vqa + frame_time + 2.0
            if wait > 0:
                time.sleep(wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = output_dir / "capture.png"
            capture_ffmpeg(disp, str(cap_path))
            return cap_path
        finally:
            self._cleanup(staging, wine_proc, xvfb, wm)

    def _get_vqa_offsets(self) -> dict:
        sequence = ["WESTWOOD", "RA_LOGO", "INTRO2", "ENGLISH", "PROLOG"]
        offsets = {}
        t = 0.0
        for vqa in sequence:
            offsets[vqa] = t
            t += self.VQA_TIMINGS.get(vqa, 10.0)
        return offsets
