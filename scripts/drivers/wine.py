"""Wine capture driver — capture screenshots from RA95.EXE under Wine."""

import subprocess
import os
import time
import pathlib
import tempfile
import shutil
import struct
import json
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    wait_for_window,
    capture_root,
    classify_ra_screen,
    center_mouse,
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

    def __init__(self, data_dir=None):
        wine = os.environ.get("WINE_BIN")
        if not wine:
            raise RuntimeError("WINE_BIN not set; export WINE_BIN=/abs/path/to/wine")
        self.wine = pathlib.Path(wine)
        if not self.wine.is_file():
            raise RuntimeError(f"WINE_BIN={self.wine} is not a file")

        data_dir = data_dir or os.environ.get("WINE_DATA_DIR")
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
        random_seed = os.environ.get("RA_RANDOM_SEED")
        self.random_seed = int(random_seed, 0) if random_seed else None

        self.scripts_dir = pathlib.Path(__file__).resolve().parent.parent
        self.nix = os.environ.get("NIX_BIN", "/nix/var/nix/profiles/default/bin/nix")
        self.ra_exe = self._build_ra_exe()
        self._build_sendinput()

    def _build_ra_exe(self) -> pathlib.Path:
        r = subprocess.run(
            [self.nix, "build", ".#ra-patched-exe", "--impure", "--print-out-paths"],
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

    def _build_frameprobe(self):
        """Compile the diagnostic RA frame-counter poller."""
        src = (
            self.scripts_dir / ".." / "tools" / "wine-input" / "ra-frameprobe.c"
        ).resolve()
        if not src.is_file():
            raise RuntimeError(f"ra-frameprobe.c not found at {src}")
        self._frameprobe_exe = (
            pathlib.Path.home() / ".cache" / "battlecontrol" / "ra-frameprobe.exe"
        )
        self._frameprobe_exe.parent.mkdir(parents=True, exist_ok=True)
        if (
            self._frameprobe_exe.exists()
            and src.stat().st_mtime <= self._frameprobe_exe.stat().st_mtime
        ):
            return
        r = subprocess.run(
            [
                "i686-w64-mingw32-gcc",
                "-o",
                str(self._frameprobe_exe),
                str(src),
                "-luser32",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"i686-w64-mingw32-gcc frameprobe failed (rc={r.returncode}): {r.stderr.strip()}"
            )

    def _patch_chain(
        self, exe: pathlib.Path, scenario=None, skip_vqa=True, autostart=True
    ):
        patches = [
            "ra/ra-focus-skip-patch.py",
            "ra/ra-game-in-focus-patch.py",
        ]
        if skip_vqa:
            patches.append("ra/ra-vqa-skip-patch.py")
            patches.append("ra/ra-briefing-skip-patch.py")
        if scenario:
            patches.append("ra/ra-scenario-patch.py")
        if autostart:
            patches.append("ra/ra-autostart-patch.py")
        if os.environ.get("WINE_FRAMEINFO_GUARD", "1") not in ("", "0"):
            patches.append("ra/ra-frameinfo-send-guard-patch.py")
        for name in patches:
            script = self.scripts_dir / name
            if not script.exists():
                continue
            cmd = ["python3", str(script), str(exe)]
            if name.endswith("ra-scenario-patch.py") and scenario:
                cmd.append(scenario)
            if name.endswith("ra-autostart-patch.py") and scenario:
                side = "soviet" if scenario.upper().startswith("SCU") else "allied"
                cmd.extend(["--side", side])
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                raise RuntimeError(
                    f"{script.name} failed (rc={r.returncode}): {r.stderr or r.stdout}"
                )
        self._patch_cd_label(exe, scenario)
        if self.random_seed is not None:
            subprocess.run(
                [
                    "python3",
                    str(self.scripts_dir / "ra" / "ra-random-seed-patch.py"),
                    str(exe),
                    str(self.random_seed),
                ],
                check=True,
                capture_output=True,
                timeout=30,
            )
            (exe.parent / "RA_RANDOM_SEED.txt").write_text(f"{self.random_seed}\n")

    def _patch_cd_label(self, exe: pathlib.Path, scenario=None):
        """Make Wine's blank staging volume label identify as the mission CD."""
        label_offset = 0x1BFCB7
        data = bytearray(exe.read_bytes())
        if len(data) < label_offset + 8:
            raise RuntimeError(f"{exe} too small for RA CD label patch")

        # The base flake derivation blanks CD1 for Allied captures. Soviet
        # captures need the blank Wine volume label to match CD2 instead.
        if scenario and scenario.upper().startswith("SCU"):
            data[label_offset] = ord("C")
            data[label_offset + 4] = 0
        else:
            data[label_offset] = 0
            data[label_offset + 4] = ord("C")
        exe.write_bytes(data)

    def _setup_staging(
        self, scenario=None, skip_vqa=True, autostart=True
    ) -> pathlib.Path:
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
            [self.nix, "build", ".#cnc-ddraw", "--impure", "--print-out-paths"],
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
        capture_fps = int(os.environ.get("RA_CAPTURE_FPS", "10"), 0)
        (staging / "ddraw.ini").write_text(
            "[ddraw]\nrenderer=gdi\nwindowed=true\nhook=0\n"
            f"window_state=normal\nmaxfps={capture_fps}\n\n"
            "[ra95]\nscanline_double=true\n"
        )
        (staging / "REDALERT.INI").write_text(
            "[Sound]\nCard=-1\n\n[Options]\nHardwareFills=no\n\n[Intro]\nPlayIntro=no\n"
        )
        self._patch_chain(staging / "RA95.EXE", scenario, skip_vqa, autostart)
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

    def _sendinput_seq(self, staging: pathlib.Path, disp: str, seq: str, logfile):
        r = subprocess.run(
            [str(self.wine), str(self._sendinput_exe), "seq", seq],
            cwd=str(staging),
            env={
                **os.environ,
                "DISPLAY": disp,
                "WINEPREFIX": str(self.wineprefix),
                "WINEDEBUG": "-all",
                "RA_SENDINPUT_ABS": "1",
                "WAYLAND_DISPLAY": "",
            },
            stdout=logfile,
            stderr=logfile,
            timeout=30,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ra-sendinput seq failed (rc={r.returncode})")

    def _xtest_click(self, disp: str, x: int, y: int, logfile):
        r = subprocess.run(
            ["xdotool", "mousemove", str(x), str(y), "click", "1"],
            env={**os.environ, "DISPLAY": disp},
            stdout=logfile,
            stderr=logfile,
            timeout=5,
        )
        if r.returncode != 0:
            logfile.write(f"wine-driver: xdotool click failed rc={r.returncode}\n")
            logfile.flush()

    def _find_ra_pid(self, staging: pathlib.Path, deadline: float) -> int:
        exe_name = str(staging / "RA95.EXE").encode()
        candidates = []
        while time.time() < deadline:
            for proc in pathlib.Path("/proc").iterdir():
                if not proc.name.isdigit():
                    continue
                try:
                    cmdline = (proc / "cmdline").read_bytes()
                except OSError:
                    continue
                if b"RA95" in cmdline or str(staging).encode() in cmdline:
                    candidates.append((proc.name, cmdline.replace(b"\0", b" ")[:240]))
                if b"RA95.EXE" in cmdline and (
                    exe_name in cmdline
                    or str(staging).encode() in cmdline
                    or b"D:\\RA95.EXE" in cmdline
                ):
                    return int(proc.name)
            time.sleep(0.05)
        sample = "; ".join(
            f"{pid}:{cmd.decode('latin1', 'replace')}" for pid, cmd in candidates[-8:]
        )
        raise RuntimeError(
            f"could not find RA95.EXE Linux process; candidates={sample}"
        )

    def _read_proc_dword(self, pid: int, addr: int) -> int:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as mem:
            mem.seek(addr)
            data = mem.read(4)
        if len(data) != 4:
            raise RuntimeError(f"short read from /proc/{pid}/mem at 0x{addr:08x}")
        return struct.unpack("<I", data)[0]

    def _wait_proc_frame(
        self, staging: pathlib.Path, frame: int, addr_text: str, logfile, pid_hint=None
    ) -> tuple[bool, int, str]:
        addr = int(addr_text, 0)
        try:
            pid = self._find_ra_pid(staging, time.time() + 2)
        except RuntimeError as exc:
            if pid_hint is None:
                raise
            pid = pid_hint
            logfile.write(f"wine-driver: proc-frameprobe using pid hint {pid}: {exc}\n")
            logfile.flush()
        max_polls = int(os.environ.get("RA_FRAMEPROBE_MAX_POLLS", "1200"), 0)
        relative = os.environ.get("RA_FRAMEPROBE_RELATIVE", "0") not in ("", "0")
        stable_ok_polls = int(os.environ.get("RA_FRAMEPROBE_STABLE_OK_POLLS", "0"), 0)
        accept_stable = os.environ.get("WINE_FRAMEPROBE_ACCEPT_STABLE", "0") not in (
            "",
            "0",
        )
        value = self._read_proc_dword(pid, addr)
        target = value + frame if relative else frame
        logfile.write(
            f"wine-driver: proc-frameprobe pid={pid} addr=0x{addr:08x} "
            f"value={value} target={target} relative={int(relative)}\n"
        )
        logfile.flush()
        last = value
        stable_polls = 0
        for _ in range(max_polls):
            try:
                value = self._read_proc_dword(pid, addr)
            except OSError:
                return (False, value, "read-failed")
            if value != last:
                logfile.write(
                    f"wine-driver: proc-frameprobe value={value} target={target}\n"
                )
                logfile.flush()
                last = value
                stable_polls = 0
            else:
                stable_polls += 1
            if value >= target:
                return (True, value, "target")
            if (
                accept_stable
                and stable_ok_polls > 0
                and value > 0
                and stable_polls >= stable_ok_polls
            ):
                logfile.write(
                    f"wine-driver: proc-frameprobe stable value={value}; "
                    "capturing current gameplay state\n"
                )
                logfile.flush()
                return (True, value, "stable")
            time.sleep(0.01)
        logfile.write(
            f"wine-driver: proc-frameprobe timeout last={value} target={target}\n"
        )
        logfile.flush()
        return (False, value, "timeout")

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
        menu_drive = os.environ.get("WINE_MENU_DRIVE", "0") not in ("", "0")
        staging = self._setup_staging(scenario, skip_vqa=True, autostart=not menu_drive)
        try:
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp)
            if not wait_for_window(disp, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            # Optional legacy boot-dismiss input. Autostart captures are fully
            # patched past dialogs/VQAs; unsolicited Enter/Space can race slower
            # CD2 starts and select Top Scores from the main menu.
            time.sleep(float(os.environ.get("WINE_BOOT_SETTLE", "5.0")))
            boot_dismiss_default = (
                "1"
                if not menu_drive and scenario and scenario.upper().startswith("SCG")
                else "0"
            )
            if os.environ.get("WINE_BOOT_DISMISS", boot_dismiss_default) not in (
                "",
                "0",
            ):
                self._sendinput_seq(
                    staging,
                    disp,
                    os.environ.get("WINE_BOOT_DISMISS_SEQ", "k=0x0D@300"),
                    logfile,
                )
            if menu_drive:
                side_click = (
                    "380,228" if scenario.upper().startswith("SCU") else "258,228"
                )
                self._sendinput_seq(
                    staging,
                    disp,
                    f"s=1000;c=322,183;s=500;c=322,183;s=2000;c=470,244;s=2000;c={side_click};s=5000;c=320,327",
                    logfile,
                )
            # Older captures used synthetic input to dismiss the text mission
            # briefing. The Wine executable is now patched to skip that dialog,
            # so extra input is opt-in; otherwise it can leak into gameplay or
            # score screens and corrupt frame-exact captures.
            if not menu_drive and os.environ.get("WINE_BRIEFING_DISMISS", "0") not in (
                "",
                "0",
            ):
                time.sleep(float(os.environ.get("WINE_BRIEFING_WAIT", "3.0")))
                self._sendinput_seq(
                    staging,
                    disp,
                    os.environ.get(
                        "WINE_BRIEFING_DISMISS_SEQ",
                        "k=0x0D@300;k=0x20@300;c=320,327@800;k=0x0D@300;c=320,327@800",
                    ),
                    logfile,
                )
                self._xtest_click(disp, 320, 327, logfile)
                time.sleep(1.0)
            center_mouse(disp, 640, 400)
            time.sleep(float(os.environ.get("WINE_GAMEPLAY_SETTLE", "1.0")))
            # Wait for target frame
            if os.environ.get("WINE_FRAMEPROBE", "0") not in ("", "0"):
                addr = os.environ.get("WINE_FRAME_ADDR", "0x006544c8")
                if os.environ.get("WINE_FRAMEPROBE_BACKEND", "proc") == "proc":
                    try:
                        probe_ok, actual_frame, frame_reason = self._wait_proc_frame(
                            staging, frame, addr, logfile, wine_proc.pid
                        )
                    except Exception as exc:
                        probe_ok = False
                        actual_frame = -1
                        frame_reason = "error"
                        logfile.write(f"wine-driver: proc-frameprobe error: {exc}\n")
                        logfile.flush()
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / "wine-frame.txt").write_text(
                        f"requested={frame}\nactual={actual_frame}\nreason={frame_reason}\naddr={addr}\n"
                    )
                    if not probe_ok:
                        if os.environ.get("WINE_FRAMEPROBE_STRICT", "0") not in (
                            "",
                            "0",
                        ):
                            try:
                                failure_path = (
                                    output_dir / "wine-frameprobe-failure.png"
                                )
                                capture_root(disp, failure_path)
                                screen = classify_ra_screen(str(failure_path))
                                (output_dir / "wine-screen.json").write_text(
                                    json.dumps(screen, indent=2) + "\n"
                                )
                                with open(output_dir / "wine-frame.txt", "a") as f:
                                    f.write(f"screen={screen['state']}\n")
                                logfile.write(
                                    "wine-driver: failure screen="
                                    f"{screen['state']} metrics={screen}\n"
                                )
                                logfile.flush()
                            except Exception as exc:
                                logfile.write(
                                    f"wine-driver: failure screenshot failed: {exc}\n"
                                )
                                logfile.flush()
                            raise RuntimeError("proc frameprobe failed")
                        frame_wait = float(
                            os.environ.get("WINE_FRAMEPROBE_FALLBACK_WAIT", "0")
                        )
                        logfile.write(
                            f"wine-driver: proc-frameprobe unavailable; "
                            f"falling back to {frame_wait:.2f}s timed wait\n"
                        )
                        logfile.flush()
                        time.sleep(frame_wait)
                else:
                    self._build_frameprobe()
                    frameprobe_env = {
                        **os.environ,
                        "DISPLAY": disp,
                        "WINEPREFIX": str(self.wineprefix),
                        "WINEDEBUG": "-all",
                        "WAYLAND_DISPLAY": "",
                        "RA_FRAMEPROBE_MAX_POLLS": os.environ.get(
                            "RA_FRAMEPROBE_MAX_POLLS", "1200"
                        ),
                        "RA_FRAMEPROBE_IDLE_POLLS": os.environ.get(
                            "RA_FRAMEPROBE_IDLE_POLLS", "600"
                        ),
                        "RA_FRAMEPROBE_RELATIVE": os.environ.get(
                            "RA_FRAMEPROBE_RELATIVE", "1"
                        ),
                    }
                    r = subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), str(frame), addr],
                        cwd=str(staging),
                        env=frameprobe_env,
                        stdout=logfile,
                        stderr=logfile,
                        timeout=20,
                    )
                    if r.returncode != 0:
                        logfile.write(
                            "wine-driver: frameprobe failed; retrying without input\n"
                        )
                        logfile.flush()
                        r = subprocess.run(
                            [
                                str(self.wine),
                                str(self._frameprobe_exe),
                                str(frame),
                                addr,
                            ],
                            cwd=str(staging),
                            env=frameprobe_env,
                            stdout=logfile,
                            stderr=logfile,
                            timeout=20,
                        )
                    if r.returncode != 0:
                        try:
                            capture_root(
                                disp, output_dir / "wine-frameprobe-failure.png"
                            )
                        except Exception as exc:
                            logfile.write(
                                f"wine-driver: failure screenshot failed: {exc}\n"
                            )
                            logfile.flush()
                        raise RuntimeError(f"ra-frameprobe failed (rc={r.returncode})")
                if os.environ.get("WINE_CELL_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-2"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_TEMPLATE_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-3"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_TRANS_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-4"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_PALETTE_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-5"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_SCREEN_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-6"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_SIDEBAR_SCAN", "0") not in ("", "0"):
                    subprocess.run(
                        [str(self.wine), str(self._frameprobe_exe), "-7"],
                        cwd=str(staging),
                        env={
                            **os.environ,
                            "DISPLAY": disp,
                            "WINEPREFIX": str(self.wineprefix),
                            "WINEDEBUG": "-all",
                            "WAYLAND_DISPLAY": "",
                        },
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
            else:
                min_wait = float(os.environ.get("WINE_CAPTURE_MIN_WAIT", "3.0"))
                frame_wait = max(frame / 15.0, min_wait)
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
