"""Wine capture driver — capture screenshots from RA95.EXE under Wine."""

import subprocess
import os
import time
import pathlib
import tempfile
import shutil
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    wait_for_window,
    capture_root,
    teardown_display,
)


def _user_tmpdir(prefix="wine-capture-"):
    """Return a temp dir under ~/.cache so Wine doesn't reject /tmp."""
    base = pathlib.Path.home() / ".cache" / "battlecontrol"
    base.mkdir(parents=True, exist_ok=True)
    return pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=str(base)))


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

    def __init__(self):
        wine = os.environ.get("WINE_BIN")
        if not wine:
            raise RuntimeError("WINE_BIN not set; export WINE_BIN=/abs/path/to/wine")
        self.wine = pathlib.Path(wine)
        if not self.wine.is_file():
            raise RuntimeError(f"WINE_BIN={self.wine} is not a file")

        data_dir = os.environ.get("WINE_DATA_DIR")
        if not data_dir:
            raise RuntimeError(
                "WINE_DATA_DIR not set; export WINE_DATA_DIR=/abs/path/to/CD1"
            )
        self.data_dir = pathlib.Path(data_dir)
        if not self.data_dir.is_dir():
            raise RuntimeError(f"WINE_DATA_DIR={self.data_dir} is not a directory")
        if not list(self.data_dir.glob("*.MIX")):
            raise RuntimeError(f"WINE_DATA_DIR={self.data_dir} contains no *.MIX files")

        # wineprefix is per-run ephemeral — created in capture_*, destroyed in
        # _cleanup. Never reused across runs, no inherited state.
        self.wineprefix: pathlib.Path | None = None

        self.scripts_dir = pathlib.Path(__file__).resolve().parent.parent
        self.ra_exe = self._build_ra_exe()
        self._build_sendinput()

    def _build_ra_exe(self) -> pathlib.Path:
        r = subprocess.run(
            ["nix", "build", ".#ra-patched-exe", "--impure", "--print-out-paths"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"nix build .#ra-patched-exe failed (rc={r.returncode}): "
                f"{r.stderr.strip()}"
            )
        return pathlib.Path(r.stdout.strip())

    def _build_sendinput(self):
        """Compile ra-sendinput.exe. Hard-fails if mingw missing or compile errors."""
        src = (
            self.scripts_dir / ".." / "tools" / "wine-input" / "ra-sendinput.c"
        ).resolve()
        if not src.is_file():
            raise RuntimeError(f"ra-sendinput.c not found at {src}")
        self._sendinput_exe = (
            pathlib.Path.home() / ".cache" / "battlecontrol" / "ra-sendinput.exe"
        )
        self._sendinput_exe.parent.mkdir(parents=True, exist_ok=True)
        if (
            self._sendinput_exe.exists()
            and src.stat().st_mtime <= self._sendinput_exe.stat().st_mtime
        ):
            return
        r = subprocess.run(
            [
                "i686-w64-mingw32-gcc",
                "-o",
                str(self._sendinput_exe),
                str(src),
                "-luser32",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"i686-w64-mingw32-gcc failed (rc={r.returncode}): {r.stderr.strip()}"
            )

    def _patch_chain(self, exe: pathlib.Path, scenario=None, skip_vqa=True):
        patches = [
            "ra/ra-focus-skip-patch.py",
            "ra/ra-game-in-focus-patch.py",
        ]
        if skip_vqa:
            patches.append("ra/ra-vqa-skip-patch.py")
        if scenario:
            patches.append("ra/ra-scenario-patch.py")
        patches.append("ra/ra-autostart-patch.py")
        for name in patches:
            script = self.scripts_dir / name
            if not script.exists():
                continue
            cmd = ["python3", str(script), str(exe)]
            if name == "ra-scenario-patch.py" and scenario:
                cmd.append(scenario)
            subprocess.run(cmd, capture_output=True, timeout=30)

    def _setup_staging(self, scenario=None, skip_vqa=True) -> pathlib.Path:
        staging = _user_tmpdir()
        for f in self.data_dir.glob("*.MIX"):
            (staging / f.name).symlink_to(f)
        for f in self.data_dir.glob("*.INI"):
            (staging / f.name).symlink_to(f)
        # Unlink existing INI symlinks so we can write fresh configs
        for ini in list(staging.glob("*.INI")):
            ini.unlink()
        shutil.copy2(self.ra_exe, staging / "RA95.EXE")
        (staging / "RA95.EXE").chmod(0o755)
        # Use stub THIPX32.DLL (no 16-bit thunk dependency)
        stub_src = self.scripts_dir / ".." / "tools" / "stub-thipx" / "thipx32.dll"
        if stub_src.exists():
            shutil.copy2(stub_src.resolve(), staging / "THIPX32.DLL")
        # cnc-ddraw — the canonical Wine DirectDraw path. Built from the flake
        # input (with the TIM-740 scanline_double patch applied) — nothing
        # else in the pipeline works correctly under Xvfb.
        #
        # Don't switch to DDrawCompat (narzoul/DDrawCompat):
        #   1. README says Wine is explicitly unsupported.
        #   2. It wraps the real ddraw.dll, so under Wine it adds Wine's
        #      DirectDraw impl as an extra variable in OG-vs-native parity.
        #   3. No `windowed=true` equivalent — it would hit Xvfb's
        #      no-exclusive-mode-set crash that we already observed when
        #      flipping cnc-ddraw's `windowed=false` (see commit history).
        # cnc-ddraw `renderer=gdi` bypasses DirectDraw entirely and is the
        # CnCNet-community canonical shim for RA95/C&C95 specifically.
        ddraw_r = subprocess.run(
            ["nix", "build", ".#cnc-ddraw", "--impure", "--print-out-paths"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if ddraw_r.returncode != 0:
            raise RuntimeError(
                "nix build .#cnc-ddraw failed; Wine capture requires the "
                "patched cnc-ddraw DLL.\n" + ddraw_r.stderr
            )
        ddraw_src = pathlib.Path(ddraw_r.stdout.strip()) / "bin" / "ddraw.dll"
        shutil.copy2(ddraw_src, staging / "ddraw.dll")
        (staging / "ddraw.ini").write_text(
            "[ddraw]\nrenderer=gdi\nwindowed=true\nhook=0\n"
            "window_state=normal\nmaxfps=30\n\n"
            "[ra95]\nscanline_double=true\n"
        )
        (staging / "REDALERT.INI").write_text(
            "[Sound]\nCard=-1\n\n[Options]\nHardwareFills=no\n\n[Intro]\nPlayIntro=no\n"
        )
        self._patch_chain(staging / "RA95.EXE", scenario, skip_vqa)
        return staging

    def _create_wineprefix(self, staging: pathlib.Path):
        """Create a fresh wineprefix from scratch and configure it.

        Per-run ephemeral: no reuse, no inherited state. Caller must call
        _destroy_wineprefix in `finally`.
        """
        if self.wineprefix is not None:
            raise RuntimeError(
                f"wineprefix already set to {self.wineprefix}; "
                "_destroy_wineprefix must run before another _create_wineprefix"
            )
        self.wineprefix = _user_tmpdir("wine-prefix-")
        wenv = {
            **os.environ,
            "WINEPREFIX": str(self.wineprefix),
            "WINEDEBUG": "-all",
        }
        r = subprocess.run(
            [str(self.wine), "wineboot", "--init"],
            env=wenv,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"wineboot --init failed (rc={r.returncode}): {r.stderr.strip()}"
            )
        for key, value, data in [
            (r"HKCU\Software\Wine\Explorer\Desktops", "Default", "640x480"),
            (r"HKCU\Software\Wine\Direct3D", "DirectDrawRenderer", "gdi"),
        ]:
            r = subprocess.run(
                [
                    str(self.wine),
                    "reg",
                    "add",
                    key,
                    "/v",
                    value,
                    "/t",
                    "REG_SZ",
                    "/d",
                    data,
                    "/f",
                ],
                env=wenv,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if r.returncode != 0:
                raise RuntimeError(
                    f"wine reg add {key}\\{value}={data} failed "
                    f"(rc={r.returncode}): {r.stderr.strip()}"
                )
        dos = self.wineprefix / "dosdevices"
        dos.mkdir(parents=True, exist_ok=True)
        (dos / "d:").symlink_to(staging)

    def _destroy_wineprefix(self):
        if self.wineprefix is None:
            return
        subprocess.run(
            ["wineserver", "-k"],
            env={**os.environ, "WINEPREFIX": str(self.wineprefix)},
            capture_output=True,
            timeout=10,
        )
        shutil.rmtree(self.wineprefix, ignore_errors=False)
        self.wineprefix = None

    def _launch(self, staging: pathlib.Path, logfile, disp: str) -> subprocess.Popen:
        return subprocess.Popen(
            [str(self.wine), str(staging / "RA95.EXE")],
            cwd=str(staging),
            start_new_session=True,
            env={
                **os.environ,
                "DISPLAY": disp,
                "WINEPREFIX": str(self.wineprefix),
                "WINEDLLOVERRIDES": "ddraw=n;mscoree=;mshtml=",
                "WINEDEBUG": "-all",
                "AUDIODEV": "null",
                "WAYLAND_DISPLAY": "",
            },
            stdout=logfile,
            stderr=logfile,
        )

    def _cleanup(self, disp, staging, wine_proc, xvfb, wm):
        teardown_display(disp, wine_proc, wm, xvfb)
        self._destroy_wineprefix()
        shutil.rmtree(staging, ignore_errors=True)

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a mission at the given game frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(scenario, skip_vqa=True)
        try:
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp)
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
            capture_root(disp, str(cap_path))
            return cap_path
        finally:
            self._cleanup(disp, staging, wine_proc, xvfb, wm)

    def capture_vqa(
        self, vqa_stem: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a VQA at the given frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(None, skip_vqa=False)
        try:
            # VQA cinematics render at 640x480 (the title/intro mode)
            xvfb = start_xvfb(disp, 640, 480, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp)
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
            capture_root(disp, str(cap_path))
            return cap_path
        finally:
            self._cleanup(disp, staging, wine_proc, xvfb, wm)

    def capture_boot(
        self, mode: str, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture title or menu screenshot from a vanilla RA95 boot.

        Args:
            mode: "title" (10s delay) or "menu" (22s delay)
            output_dir: where to save the PNG

        Returns:
            Path to captured screenshot
        """
        delays = {"title": 10.0, "menu": 22.0}
        if mode not in delays:
            raise ValueError(
                f"unknown boot mode: {mode} (choose from {list(delays.keys())})"
            )
        delay = delays[mode]
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(scenario=None, skip_vqa=True)
        try:
            xvfb = start_xvfb(disp, 640, 480, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp)
            # Dismiss DirectSound warning dialog
            time.sleep(5)
            subprocess.run(
                ["xdotool", "key", "Return"],
                env={**os.environ, "DISPLAY": disp},
                capture_output=True,
                timeout=5,
            )
            # Wait remaining time to reach target capture point
            time.sleep(delay - 5)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = output_dir / f"{mode}.png"
            capture_root(disp, str(cap_path))
            return cap_path
        finally:
            self._cleanup(disp, staging, wine_proc, xvfb, wm)

    def _get_vqa_offsets(self) -> dict:
        sequence = ["WESTWOOD", "RA_LOGO", "INTRO2", "ENGLISH", "PROLOG"]
        offsets = {}
        t = 0.0
        for vqa in sequence:
            offsets[vqa] = t
            t += self.VQA_TIMINGS.get(vqa, 10.0)
        return offsets
