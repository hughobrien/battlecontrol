"""Wine capture driver — capture screenshots from RA95.EXE under Wine."""

import subprocess
import os
import time
import pathlib
import tempfile
import shutil
import struct
import json
import math
import sys
import signal
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    wait_for_window,
    capture_root,
    classify_ra_screen,
    screen_timeline_entry,
    write_screen_timeline,
    RA_SCREEN_IMPOSSIBLE_STATES,
    center_mouse,
    teardown_display,
)


def _user_tmpdir(prefix="wine-capture-"):
    """Return a temp dir under ~/.cache so Wine doesn't reject /tmp."""
    base = pathlib.Path.home() / ".cache" / "battlecontrol"
    base.mkdir(parents=True, exist_ok=True)
    return pathlib.Path(tempfile.mkdtemp(prefix=prefix, dir=str(base)))


def _env_flag(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default) not in ("", "0")


def _wine_z_path(path: pathlib.Path) -> str:
    """Return Wine's default Z: mapping for an absolute host path."""
    return "Z:" + str(path.resolve()).replace("/", "\\")


def _scenario_stem(scenario: str | None) -> str | None:
    if not scenario:
        return None
    stem = scenario.upper().strip()
    if stem.endswith(".INI"):
        stem = stem[:-4]
    return stem


def _scenario_side(scenario: str | None) -> str | None:
    stem = _scenario_stem(scenario)
    if not stem:
        return None
    return "soviet" if stem.startswith("SCU") else "allied"


def _cd_label_mode(scenario: str | None) -> str:
    override = os.environ.get("WINE_CD_LABEL_MODE")
    if override:
        mode = override.strip().lower()
        if mode in ("cd1", "cd2"):
            return mode
    return "cd2" if _scenario_side(scenario) == "soviet" else "cd1"


def _manifest_arg(path: pathlib.Path | str | None) -> str | None:
    if path is None:
        return None
    return str(pathlib.Path(path).resolve())


def _positive_float_env(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return value if value > 0 else default


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)), 0)
    except ValueError:
        return default
    return value if value > 0 else default


def base_patch_command(
    *,
    exe: pathlib.Path | str,
    manifest_path: pathlib.Path | str | None,
) -> list[str]:
    """Return the unified RA95 base patcher command, run from repo root."""
    command = [
        "python3",
        "scripts/ra/patch_ra95.py",
        "base",
        str(exe),
    ]
    manifest = _manifest_arg(manifest_path)
    if manifest is not None:
        command.extend(["--manifest", manifest])
    return command


def mission_patch_command(
    *,
    exe: pathlib.Path | str,
    scenario: str | None,
    manifest: pathlib.Path | str | None = None,
    manifest_path: pathlib.Path | str | None = None,
    skip_vqa: bool = True,
    autostart: bool = True,
    random_seed: int | None = None,
) -> list[str]:
    """Return the unified RA95 mission patcher command, run from repo root."""
    if manifest is not None and manifest_path is not None:
        raise ValueError("pass either manifest or manifest_path, not both")
    if not autostart:
        raise ValueError("Wine mission capture requires autostart")
    if not scenario:
        raise ValueError("Wine mission capture requires a scenario")

    command = [
        "python3",
        "scripts/ra/patch_ra95.py",
        "mission",
        str(exe),
        "--scenario",
        scenario,
    ]
    manifest_arg = _manifest_arg(
        manifest_path if manifest_path is not None else manifest
    )
    if manifest_arg is not None:
        command.extend(["--manifest", manifest_arg])
    if random_seed is None:
        command.append("--no-seed")
    else:
        command.extend(["--seed", f"0x{random_seed:x}"])
    if not skip_vqa:
        command.append("--no-vqa-skip")
    if os.environ.get("WINE_BRIEFING_SKIP_PATCH", "1") in ("", "0"):
        command.append("--no-briefing-skip")

    diagnostics = []
    if os.environ.get("WINE_FORCE_NORMAL_QUEUE", "0") not in ("", "0"):
        diagnostics.append("force-normal-queue")
    if os.environ.get("WINE_FRAMEINFO_GUARD", "0") not in ("", "0"):
        diagnostics.append("frameinfo-send-guard")
    for diagnostic in diagnostics:
        command.extend(["--diagnostic", diagnostic])
    if diagnostics:
        command.append("--allow-diagnostic")
    return command


def _timeline_strict_failure(entries: list[dict]) -> str | None:
    """Return the strict-mode failure reason for a screen timeline."""
    for entry in entries:
        if entry.get("state") in RA_SCREEN_IMPOSSIBLE_STATES:
            return entry["state"]
    previous_state = None
    for entry in entries:
        state = entry.get("state")
        if state == "main-menu" and previous_state == "main-menu":
            return "stable main-menu"
        previous_state = state
    return None


def _parse_timeline_sample_times(
    env_name: str, default: str, max_elapsed_s: float
) -> list[float]:
    """Parse and cap timeline sample offsets from an env var."""
    raw = os.environ.get(env_name, default)
    cap = max(0.0, float(max_elapsed_s))
    sample_times = set()
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            value = float(item)
        except ValueError as exc:
            raise ValueError(
                f"{env_name} must be comma-separated seconds, got {raw!r}"
            ) from exc
        if not math.isfinite(value):
            raise ValueError(
                f"{env_name} must contain finite seconds, got {item!r} in {raw!r}"
            )
        sample = max(0.0, value)
        if sample <= cap:
            sample_times.add(sample)
    if not sample_times:
        sample_times.add(0.0)
    return sorted(sample_times)


def parse_wine_state_line(line: str) -> dict[str, str]:
    """Parse a compact ra-frameprobe state line into key/value pairs."""
    values: dict[str, str] = {}
    parts = line.strip().split()
    if not parts or parts[0] != "state":
        return values
    for item in parts[1:]:
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        values[key] = value
    return values


def first_non_loading_state(entries: list[dict]) -> dict | None:
    """Return the first timeline entry that is not a loading-like state."""
    for entry in entries:
        if entry.get("state") not in ("loading", "black", "unknown"):
            return entry
    return None


def _timeline_reached_gameplay(entries: list[dict]) -> bool:
    return any(entry.get("state") == "gameplay" for entry in entries)


FRAME_COUNTER_CANDIDATES = [
    0x00642080,
    0x0066B68C,
    0x006544C8,
    0x00655D18,
    0x005EC258,
    0x0068DEA0,
    0x0069720C,
    0x0069C41C,
    0x0069C468,
    0x0069C488,
    0x005F166C,
    0x006D7344,
]

DEFAULT_WINE_FRAME_ADDR = "0x006544c8"


def _summarize_frame_candidate_samples(
    samples: dict[int, list[int]], target: int
) -> list[dict]:
    """Summarize sampled frame-counter candidate values."""
    summaries = []
    for addr, values in samples.items():
        if not values:
            continue
        changes = sum(1 for i in range(1, len(values)) if values[i] != values[i - 1])
        monotonic = all(values[i] >= values[i - 1] for i in range(1, len(values)))
        summaries.append(
            {
                "addr": f"0x{addr:08x}",
                "first": values[0],
                "last": values[-1],
                "min": min(values),
                "max": max(values),
                "changes": changes,
                "monotonic": monotonic,
                "reaches_target": values[-1] >= target,
            }
        )
    summaries.sort(
        key=lambda row: (
            not row["reaches_target"],
            -int(row["changes"]),
            -int(row["last"]),
            row["addr"],
        )
    )
    return summaries


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
        wine = os.environ.get("WINE_BIN") or shutil.which("wine")
        if not wine:
            raise RuntimeError(
                "WINE_BIN not set and `wine` is not on PATH; "
                "export WINE_BIN=/abs/path/to/wine"
            )
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

    @staticmethod
    def _patch_manifest_path(output_dir: pathlib.Path | None) -> pathlib.Path | None:
        if output_dir is None:
            return None
        return pathlib.Path(output_dir) / "wine-patches.json"

    @staticmethod
    def _write_patch_manifest(
        manifest_path: pathlib.Path | None, manifest: dict
    ) -> None:
        if manifest_path is None:
            return
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    @staticmethod
    def _new_patch_manifest_preflight(
        scenario=None, skip_vqa=True, autostart=True
    ) -> dict:
        return {
            "scenario": _scenario_stem(scenario),
            "side": _scenario_side(scenario),
            "cd_label_mode": _cd_label_mode(scenario),
            "boot_dismiss": _env_flag("WINE_BOOT_DISMISS", "0"),
            "menu_drive": _env_flag("WINE_MENU_DRIVE", "0"),
            "skip_vqa": bool(skip_vqa),
            "autostart": bool(autostart),
            "random_seed": None,
            "ra95_path": None,
            "sha256_initial": None,
            "patches": [],
            "status": "preparing",
        }

    def _patch_chain(
        self,
        exe: pathlib.Path,
        scenario=None,
        skip_vqa=True,
        autostart=True,
        manifest: dict | None = None,
        manifest_path: pathlib.Path | None = None,
    ):
        del manifest
        if scenario is None:
            command = base_patch_command(exe=exe, manifest_path=manifest_path)
        else:
            command = mission_patch_command(
                exe=exe,
                scenario=scenario,
                manifest_path=manifest_path,
                skip_vqa=skip_vqa,
                autostart=autostart,
                random_seed=self.random_seed,
            )
        r = subprocess.run(
            command,
            cwd=self.scripts_dir.parent,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if r.returncode != 0:
            raise RuntimeError(
                "patch_ra95.py mission failed "
                f"(rc={r.returncode})\nSTDOUT:\n{r.stdout}\nSTDERR:\n{r.stderr}"
            )
        if scenario is not None and self.random_seed is not None:
            (exe.parent / "RA_RANDOM_SEED.txt").write_text(f"{self.random_seed}\n")

    def _setup_staging(
        self,
        scenario=None,
        skip_vqa=True,
        autostart=True,
        output_dir: pathlib.Path | None = None,
    ) -> pathlib.Path:
        staging = _user_tmpdir()
        manifest_path = self._patch_manifest_path(output_dir)
        manifest = self._new_patch_manifest_preflight(scenario, skip_vqa, autostart)
        try:
            self._write_patch_manifest(manifest_path, manifest)
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
            exe = staging / "RA95.EXE"
            self._patch_chain(
                exe,
                scenario,
                skip_vqa,
                autostart,
                manifest=manifest,
                manifest_path=manifest_path,
            )
            return staging
        except Exception as exc:
            try:
                manifest["status"] = "failed"
                manifest["error"] = str(exc)
                self._write_patch_manifest(manifest_path, manifest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            raise

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

    def _launch(
        self,
        staging: pathlib.Path,
        logfile,
        disp: str,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.Popen:
        try:
            pathlib.Path("/tmp/wine-audio.raw").unlink()
        except FileNotFoundError:
            pass
        env = {
            **os.environ,
            "DISPLAY": disp,
            "WINEPREFIX": str(self.wineprefix),
            "WINEDLLOVERRIDES": "ddraw=n;mscoree=;mshtml=",
            "WINEDEBUG": "-all",
            "AUDIODEV": "null",
            "WAYLAND_DISPLAY": "",
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.Popen(
            [str(self.wine), str(staging / "RA95.EXE")],
            cwd=str(staging),
            start_new_session=True,
            env=env,
            stdout=logfile,
            stderr=logfile,
        )

    def _wait_for_cncddraw_capture(
        self,
        path: pathlib.Path,
        wine_proc: subprocess.Popen,
        timeout_s: float,
        logfile,
    ) -> pathlib.Path:
        deadline = time.monotonic() + timeout_s
        last_size = -1
        stable_since = None
        while time.monotonic() < deadline:
            if path.exists():
                size = path.stat().st_size
                if size > 0 and size == last_size:
                    if stable_since is None:
                        stable_since = time.monotonic()
                    elif time.monotonic() - stable_since >= 0.2:
                        return path
                else:
                    stable_since = None
                    last_size = size
            if wine_proc.poll() is not None:
                break
            time.sleep(0.05)
        logfile.write(
            "wine-driver: cnc-ddraw capture did not arrive "
            f"path={path} timeout={timeout_s:.1f}s proc_rc={wine_proc.poll()}\n"
        )
        logfile.flush()
        raise RuntimeError("cnc-ddraw capture did not arrive")

    def _wait_for_cncddraw_sequence(
        self,
        sequence_dir: pathlib.Path,
        start_frame: int,
        count: int,
        clock: str,
        wine_proc: subprocess.Popen,
        timeout_s: float,
        logfile,
    ) -> list[pathlib.Path]:
        expected = []
        if clock == "render":
            expected = [
                sequence_dir / f"frame_{frame:06d}.png"
                for frame in range(start_frame, start_frame + count)
            ]
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if clock == "ra":
                present = sorted(
                    path
                    for path in sequence_dir.glob("frame_*.png")
                    if path.stat().st_size > 0
                )
            else:
                present = [
                    path
                    for path in expected
                    if path.exists() and path.stat().st_size > 0
                ]
            if len(present) >= count:
                time.sleep(0.2)
                if clock == "ra":
                    stable = sorted(
                        path
                        for path in sequence_dir.glob("frame_*.png")
                        if path.stat().st_size > 0
                    )
                    if len(stable) >= count:
                        return stable[:count]
                elif all(
                    path.exists() and path.stat().st_size > 0 for path in expected
                ):
                    return expected
            if wine_proc.poll() is not None:
                break
            time.sleep(0.05)
        missing = []
        if expected:
            missing = [
                path.name
                for path in expected
                if not path.exists() or path.stat().st_size == 0
            ]
        logfile.write(
            "wine-driver: cnc-ddraw sequence did not complete "
            f"dir={sequence_dir} start={start_frame} count={count} clock={clock} "
            f"missing={missing[:8]} timeout={timeout_s:.1f}s proc_rc={wine_proc.poll()}\n"
        )
        logfile.flush()
        raise RuntimeError("cnc-ddraw sequence did not complete")

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

    def _frameprobe_env(self, disp: str) -> dict:
        return {
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
            "RA_FRAMEPROBE_RELATIVE": os.environ.get("RA_FRAMEPROBE_RELATIVE", "1"),
        }

    def _write_unknown_state(
        self, output_dir: pathlib.Path, reason: str, logfile=None
    ) -> dict[str, str]:
        output_dir.mkdir(parents=True, exist_ok=True)
        line = self._fallback_state_line(reason)
        (output_dir / "wine-state.txt").write_text(line + "\n")
        if hasattr(logfile, "write"):
            logfile.write(f"wine-driver: state probe unavailable: {reason}\n")
            logfile.flush()
        return parse_wine_state_line(line)

    @staticmethod
    def _fallback_state_line(reason: str) -> str:
        return (
            "state scenario=unknown frame=unknown player_wins=unknown "
            "player_loses=unknown session=unknown PlayerWins=unknown "
            "PlayerLoses=unknown Session.Type=unknown player=unknown defeated=unknown "
            f"error={reason.replace(' ', '_')}"
        )

    def _write_state_probe_fallback(
        self,
        output_dir: pathlib.Path,
        reason: str,
        raw_output: str,
        logfile=None,
    ) -> dict[str, str]:
        if raw_output:
            (output_dir / "wine-state-raw.txt").write_text(raw_output)
            if not raw_output.endswith("\n"):
                raw_output += "\n"
        fallback = self._fallback_state_line(reason)
        if raw_output:
            (output_dir / "wine-state.txt").write_text(raw_output + fallback + "\n")
        else:
            (output_dir / "wine-state.txt").write_text(fallback + "\n")
        if hasattr(logfile, "write"):
            logfile.write(f"wine-driver: state probe unavailable: {reason}\n")
            logfile.flush()
        return parse_wine_state_line(fallback)

    @staticmethod
    def _timeout_output(exc: subprocess.TimeoutExpired) -> str:
        def decode(value):
            if value is None:
                return ""
            if isinstance(value, bytes):
                return value.decode("utf-8", "replace")
            return str(value)

        stdout = decode(exc.stdout)
        stderr = decode(exc.stderr)
        parts = []
        if stdout:
            parts.append(stdout)
        if stderr:
            parts.append(stderr)
        return "".join(parts)

    def _run_state_probe(
        self,
        staging: pathlib.Path,
        disp: str,
        output_dir: pathlib.Path,
        logfile=None,
        timeout: float = 20.0,
    ) -> dict[str, str]:
        """Run ra-frameprobe --state and write wine-state.txt."""
        output_dir.mkdir(parents=True, exist_ok=True)
        try:
            self._build_frameprobe()
        except Exception as exc:
            return self._write_unknown_state(output_dir, str(exc), logfile)

        addr = os.environ.get("WINE_FRAME_ADDR", DEFAULT_WINE_FRAME_ADDR)
        try:
            r = subprocess.run(
                [str(self.wine), str(self._frameprobe_exe), "--state", addr],
                cwd=str(staging),
                env=self._frameprobe_env(disp),
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            return self._write_state_probe_fallback(
                output_dir, "state_probe_timeout", self._timeout_output(exc), logfile
            )

        combined = (r.stdout or "") + (r.stderr or "")
        (output_dir / "wine-state.txt").write_text(combined)
        if combined:
            (output_dir / "wine-state-raw.txt").write_text(combined)
        if hasattr(logfile, "write"):
            logfile.write("wine-driver: state probe output:\n")
            logfile.write(combined)
            if r.returncode != 0:
                logfile.write(f"wine-driver: state probe rc={r.returncode}\n")
            logfile.flush()

        for line in combined.splitlines():
            parsed = parse_wine_state_line(line)
            if parsed:
                return parsed
        return self._write_state_probe_fallback(
            output_dir,
            f"state_probe_no_state_line_rc_{r.returncode}",
            combined,
            logfile,
        )

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

    def _scan_proc_dword(
        self,
        pid: int,
        value: int,
        logfile,
        max_matches: int = 64,
        min_addr: int = 0,
        max_addr: int = 0,
    ) -> int:
        needle = struct.pack("<I", value)
        found = 0
        with (
            open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="replace") as maps,
            open(f"/proc/{pid}/mem", "rb", buffering=0) as mem,
        ):
            for line in maps:
                parts = line.split()
                if len(parts) < 2 or "r" not in parts[1]:
                    continue
                start_s, end_s = parts[0].split("-", 1)
                start = int(start_s, 16)
                end = int(end_s, 16)
                if max_addr and start >= max_addr:
                    continue
                if min_addr and end <= min_addr:
                    continue
                start = max(start, min_addr)
                end = min(end, max_addr) if max_addr else end
                if end <= start:
                    continue
                try:
                    mem.seek(start)
                    data = mem.read(end - start)
                except OSError:
                    continue
                offset = data.find(needle)
                while offset >= 0:
                    addr = start + offset
                    chunk_start = max(0, offset - 16)
                    chunk_end = min(len(data), offset + 20)
                    logfile.write(
                        "wine-driver: proc-dwordscan match "
                        f"addr=0x{addr:08x} value=0x{value:08x} "
                        f"bytes={data[chunk_start:chunk_end].hex()}\n"
                    )
                    found += 1
                    if found >= max_matches:
                        logfile.write(
                            f"wine-driver: proc-dwordscan value=0x{value:08x} "
                            f"found={found} capped=1\n"
                        )
                        logfile.flush()
                        return found
                    offset = data.find(needle, offset + 1)
        logfile.write(
            f"wine-driver: proc-dwordscan value=0x{value:08x} found={found} capped=0\n"
        )
        logfile.flush()
        return found

    def _scan_proc_cells(
        self,
        pid: int,
        cells: list[int],
        logfile,
        max_candidates: int = 4,
        min_addr: int = 0,
        max_addr: int = 0,
    ) -> int:
        found = 0
        wanted = sorted(set(c for c in cells if c >= 0))
        if not wanted:
            return 0
        max_cell = max(wanted)
        max_region_bytes = int(
            os.environ.get("WINE_PROC_CELL_SCAN_MAX_REGION", str(64 * 1024 * 1024)),
            0,
        )
        with (
            open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="replace") as maps,
            open(f"/proc/{pid}/mem", "rb", buffering=0) as mem,
        ):
            for line in maps:
                parts = line.split()
                if len(parts) < 2 or "r" not in parts[1]:
                    continue
                start_s, end_s = parts[0].split("-", 1)
                start = int(start_s, 16)
                end = int(end_s, 16)
                if max_addr and start >= max_addr:
                    continue
                if min_addr and end <= min_addr:
                    continue
                start = max(start, min_addr)
                end = min(end, max_addr) if max_addr else end
                if end <= start or end - start > max_region_bytes:
                    continue
                try:
                    mem.seek(start)
                    data = mem.read(end - start)
                except OSError:
                    continue
                if len(data) < 128 * 24:
                    continue
                for off in range(0, len(data) - (127 * 24 + 2), 2):
                    if data[off : off + 2] != b"\x00\x00":
                        continue
                    for stride in range(24, 194, 2):
                        if off + max_cell * stride + 64 > len(data):
                            continue
                        if off + 127 * stride + 2 > len(data):
                            continue
                        ok = True
                        for sample in range(1, 128):
                            cell_id = struct.unpack_from(
                                "<H", data, off + sample * stride
                            )[0]
                            if cell_id != sample:
                                ok = False
                                break
                        if not ok:
                            continue
                        base = start + off
                        logfile.write(
                            "wine-driver: proc-cellscan candidate "
                            f"base=0x{base:08x} stride={stride} cells={','.join(str(c) for c in wanted)}\n"
                        )
                        for cell in wanted:
                            cell_off = off + cell * stride
                            raw = data[cell_off : cell_off + 80]
                            cell_id = (
                                struct.unpack_from("<H", raw, 0)[0]
                                if len(raw) >= 2
                                else -1
                            )
                            flags16 = (
                                struct.unpack_from("<H", raw, 2)[0]
                                if len(raw) >= 4
                                else 0
                            )
                            flags32 = (
                                struct.unpack_from("<I", raw, 4)[0]
                                if len(raw) >= 8
                                else 0
                            )
                            overlay20 = (
                                struct.unpack_from("<H", raw, 20)[0]
                                if len(raw) >= 22
                                else 0
                            )
                            overlay22 = raw[22] if len(raw) >= 23 else 0
                            inf_type = raw[27] if len(raw) >= 28 else 0
                            logfile.write(
                                "wine-driver: proc-cellscan cell "
                                f"cell={cell} addr=0x{start + cell_off:08x} "
                                f"id={cell_id} flags16=0x{flags16:04x} "
                                f"flags32=0x{flags32:08x} overlay20={overlay20} "
                                f"overlay22={overlay22} inf_type={inf_type} "
                                f"bytes={raw.hex()}\n"
                            )
                        found += 1
                        if found >= max_candidates:
                            logfile.write(
                                f"wine-driver: proc-cellscan found={found} capped=1\n"
                            )
                            logfile.flush()
                            return found
        logfile.write(f"wine-driver: proc-cellscan found={found} capped=0\n")
        logfile.flush()
        return found

    def _wait_proc_frame(
        self,
        staging: pathlib.Path,
        frame: int,
        addr_text: str,
        logfile,
        pid_hint=None,
        candidate_path: pathlib.Path | None = None,
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
        poll_interval = _positive_float_env("RA_FRAMEPROBE_POLL_INTERVAL", 0.01)
        configured_max_polls = _positive_int_env("RA_FRAMEPROBE_MAX_POLLS", 1200)
        relative = os.environ.get("RA_FRAMEPROBE_RELATIVE", "0") not in ("", "0")
        stable_ok_polls = int(os.environ.get("RA_FRAMEPROBE_STABLE_OK_POLLS", "0"), 0)
        accept_stable = os.environ.get("WINE_FRAMEPROBE_ACCEPT_STABLE", "0") not in (
            "",
            "0",
        )
        value = self._read_proc_dword(pid, addr)
        target = value + frame if relative else frame
        fps = _positive_float_env("RA_CAPTURE_FPS", 10.0)
        expected_delta = max(0, target - value)
        budget_seconds = (expected_delta / fps) + 20.0
        target_polls = max(1, math.ceil(budget_seconds / poll_interval))
        max_polls = max(configured_max_polls, target_polls)
        logfile.write(
            f"wine-driver: proc-frameprobe pid={pid} addr=0x{addr:08x} "
            f"value={value} target={target} relative={int(relative)} "
            f"poll_interval={poll_interval:.3f}s max_polls={max_polls} "
            f"configured_max_polls={configured_max_polls} fps={fps:.1f}\n"
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
                wait_scan_value = os.environ.get("WINE_PROC_DWORD_SCAN_VALUE", "")
                wait_cell_scan = os.environ.get("WINE_PROC_CELL_SCAN", "")
                if wait_scan_value or wait_cell_scan:
                    should_stop = os.environ.get(
                        "WINE_PROC_DWORD_SCAN_STOP", "1"
                    ) not in ("", "0")
                    if should_stop:
                        try:
                            os.kill(pid, signal.SIGSTOP)
                        except OSError as exc:
                            logfile.write(
                                f"wine-driver: proc-dwordscan SIGSTOP failed: {exc}\n"
                            )
                    try:
                        if wait_scan_value:
                            self._scan_proc_dword(
                                pid,
                                int(wait_scan_value, 0),
                                logfile,
                                int(
                                    os.environ.get("WINE_PROC_DWORD_SCAN_MAX", "64"), 0
                                ),
                                int(
                                    os.environ.get(
                                        "WINE_PROC_DWORD_SCAN_MIN_ADDR", "0"
                                    ),
                                    0,
                                ),
                                int(
                                    os.environ.get(
                                        "WINE_PROC_DWORD_SCAN_MAX_ADDR", "0"
                                    ),
                                    0,
                                ),
                            )
                        if wait_cell_scan:
                            cells = [
                                int(part.strip(), 0)
                                for part in wait_cell_scan.split(",")
                                if part.strip()
                            ]
                            self._scan_proc_cells(
                                pid,
                                cells,
                                logfile,
                                int(os.environ.get("WINE_PROC_CELL_SCAN_MAX", "4"), 0),
                                int(
                                    os.environ.get("WINE_PROC_CELL_SCAN_MIN_ADDR", "0"),
                                    0,
                                ),
                                int(
                                    os.environ.get("WINE_PROC_CELL_SCAN_MAX_ADDR", "0"),
                                    0,
                                ),
                            )
                    finally:
                        if should_stop:
                            try:
                                os.kill(pid, signal.SIGCONT)
                            except OSError as exc:
                                logfile.write(
                                    f"wine-driver: proc-dwordscan SIGCONT failed: {exc}\n"
                                )
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
            time.sleep(poll_interval)
        logfile.write(
            f"wine-driver: proc-frameprobe timeout last={value} target={target}\n"
        )
        logfile.flush()
        if candidate_path is not None:
            self._write_proc_frame_candidate_scan(pid, target, candidate_path, logfile)
        return (False, value, "timeout")

    def _write_proc_frame_candidate_scan(
        self, pid: int, target: int, path: pathlib.Path, logfile
    ) -> None:
        polls = int(os.environ.get("WINE_FRAMEPROBE_SCAN_POLLS", "60"), 0)
        interval = float(os.environ.get("WINE_FRAMEPROBE_SCAN_INTERVAL", "0.02"))
        polls = max(1, polls)
        interval = max(0.0, interval)
        samples = {addr: [] for addr in FRAME_COUNTER_CANDIDATES}
        for _ in range(polls):
            for addr in FRAME_COUNTER_CANDIDATES:
                try:
                    samples[addr].append(self._read_proc_dword(pid, addr))
                except OSError:
                    continue
            if interval:
                time.sleep(interval)
        report = {
            "model": "ra-frame-candidates-v1",
            "pid": pid,
            "target": target,
            "polls": polls,
            "interval": interval,
            "candidates": _summarize_frame_candidate_samples(samples, target),
        }
        path.write_text(json.dumps(report, indent=2) + "\n")
        logfile.write(f"wine-driver: frame candidate scan={path}\n")
        for row in report["candidates"][:5]:
            logfile.write(
                "wine-driver: frame candidate "
                f"{row['addr']} first={row['first']} last={row['last']} "
                f"changes={row['changes']} reaches={int(row['reaches_target'])}\n"
            )
        logfile.flush()

    def _note_failure_patch_manifest(
        self, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        manifest_path = self._patch_manifest_path(output_dir)
        assert manifest_path is not None
        if manifest_path.exists():
            message = (
                f"wine-driver: failure artifacts in {output_dir}; "
                f"patch manifest: {manifest_path}"
            )
        else:
            message = (
                f"wine-driver: failure artifacts in {output_dir}; "
                f"patch manifest was not created: {manifest_path}"
            )
        print(message, file=sys.stderr)
        if hasattr(logfile, "write"):
            logfile.write(message + "\n")
            logfile.flush()
        return manifest_path

    def _raise_with_patch_manifest(
        self, exc: Exception, output_dir: pathlib.Path, logfile=None
    ):
        manifest_path = self._note_failure_patch_manifest(output_dir, logfile)
        text = str(exc)
        if "wine-patches.json" in text:
            raise
        if manifest_path.exists():
            raise RuntimeError(f"{text}; patch manifest: {manifest_path}") from exc
        raise RuntimeError(
            f"{text}; patch manifest was not created: {manifest_path}"
        ) from exc

    def _cleanup(self, disp, staging, wine_proc, xvfb, wm):
        teardown_display(disp, wine_proc, wm, xvfb)
        self._destroy_wineprefix()
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)

    def _capture_screen_timeline(
        self,
        disp: str,
        output_dir: pathlib.Path,
        logfile,
        max_elapsed_s: float,
        metadata: dict,
        stop_on_first_non_loading: bool = False,
    ) -> tuple[list[dict], pathlib.Path]:
        """Capture a short mission-entry screen-state timeline."""
        output_dir.mkdir(parents=True, exist_ok=True)
        timeline_path = output_dir / "wine-screen-timeline.json"
        sample_times = _parse_timeline_sample_times(
            "WINE_SCREEN_TIMELINE_SECONDS", "0,2,5", max_elapsed_s
        )
        continue_after_gameplay = os.environ.get(
            "WINE_SCREEN_TIMELINE_AFTER_GAMEPLAY", "0"
        ) not in ("", "0")

        entries = []
        start = time.monotonic()
        for index, sample_time in enumerate(sample_times):
            delay = start + sample_time - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            screenshot = output_dir / f"wine-screen-{index:02d}.png"
            try:
                capture_root(disp, str(screenshot))
                screen = classify_ra_screen(str(screenshot))
                entry = screen_timeline_entry(
                    time.monotonic() - start, screenshot, screen
                )
                entries.append(entry)
                logfile.write(
                    "wine-driver: screen timeline "
                    f"t={entry['t']:.3f}s state={entry['state']} "
                    f"metrics={entry['metrics']}\n"
                )
                logfile.flush()
                write_screen_timeline(timeline_path, entries, metadata)
                if stop_on_first_non_loading and entry["state"] not in (
                    "loading",
                    "black",
                    "unknown",
                ):
                    break
                if entry["state"] == "gameplay" and not continue_after_gameplay:
                    break
            except Exception as exc:
                entries.append(
                    {
                        "t": round(time.monotonic() - start, 3),
                        "state": "unknown",
                        "path": screenshot.name,
                        "error": str(exc),
                    }
                )
                write_screen_timeline(timeline_path, entries, metadata)
                logfile.write(f"wine-driver: screen timeline capture failed: {exc}\n")
                logfile.flush()
                break
        return entries, timeline_path

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a mission at the given game frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = staging = session_clamp = None
        menu_drive = os.environ.get("WINE_MENU_DRIVE", "0") not in ("", "0")
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            cncddraw_capture = _env_flag("WINE_CNCDDRAW_CAPTURE")
            cncddraw_capture_path = output_dir / "wine-cncddraw.png"
            cncddraw_sequence_dir = output_dir / "wine-sequence"
            cncddraw_capture_flip = os.environ.get(
                "WINE_CNCDDRAW_CAPTURE_FLIP", str(frame)
            )
            cncddraw_capture_count = int(
                os.environ.get("WINE_CNCDDRAW_CAPTURE_COUNT", "1"), 0
            )
            wine_extra_env = {}
            if cncddraw_capture:
                wine_extra_env = {
                    "BC_CAPTURE_FLIP": cncddraw_capture_flip,
                    "BC_CAPTURE_START": os.environ.get(
                        "WINE_CNCDDRAW_CAPTURE_START", cncddraw_capture_flip
                    ),
                    "BC_CAPTURE_RA_START": os.environ.get(
                        "WINE_CNCDDRAW_CAPTURE_RA_START", ""
                    ),
                    "BC_CAPTURE_COUNT": str(cncddraw_capture_count),
                    "BC_CAPTURE_FILE": _wine_z_path(cncddraw_capture_path),
                    "BC_CAPTURE_DIR": _wine_z_path(cncddraw_sequence_dir),
                    "BC_CAPTURE_HALT": os.environ.get(
                        "WINE_CNCDDRAW_CAPTURE_HALT", "1"
                    ),
                    "BC_CAPTURE_RA_FRAME_ADDR": os.environ.get(
                        "WINE_FRAME_ADDR", DEFAULT_WINE_FRAME_ADDR
                    ),
                    "BC_CAPTURE_LOG_CANDIDATES": os.environ.get(
                        "WINE_CNCDDRAW_CAPTURE_LOG_CANDIDATES",
                        os.environ.get("WINE_CAPTURE_LOG_CANDIDATES", ""),
                    ),
                }
            staging = self._setup_staging(
                scenario,
                skip_vqa=True,
                autostart=not menu_drive,
                output_dir=output_dir,
            )
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp, wine_extra_env)
            if os.environ.get("WINE_FORCE_SESSION_NORMAL", "0") not in ("", "0"):
                self._build_frameprobe()
                clamp_ms = os.environ.get("WINE_FORCE_SESSION_NORMAL_MS", "12000")
                session_clamp = subprocess.Popen(
                    [
                        str(self.wine),
                        str(self._frameprobe_exe),
                        "--session-normal",
                        clamp_ms,
                    ],
                    cwd=str(staging),
                    env=self._frameprobe_env(disp),
                    stdout=logfile,
                    stderr=logfile,
                )
            if not wait_for_window(disp, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            boot_settle = float(os.environ.get("WINE_BOOT_SETTLE", "5.0"))
            use_frameprobe = os.environ.get("WINE_FRAMEPROBE", "1") not in (
                "",
                "0",
            )
            strict_frameprobe = use_frameprobe and os.environ.get(
                "WINE_FRAMEPROBE_STRICT", "1"
            ) not in ("", "0")
            timeline_entries = []
            timeline_path = output_dir / "wine-screen-timeline.json"
            timeline_metadata = {
                "scenario": f"{scenario}.INI",
                "frame": frame,
                "strict_frameprobe": strict_frameprobe,
                "menu_drive": menu_drive,
            }
            if not menu_drive:
                timeline_entries, timeline_path = self._capture_screen_timeline(
                    disp,
                    output_dir,
                    logfile,
                    boot_settle,
                    {**timeline_metadata, "phase": "boot-settle"},
                )
            if strict_frameprobe and timeline_entries:
                reason = _timeline_strict_failure(timeline_entries)
                if reason:
                    self._run_state_probe(staging, disp, output_dir, logfile)
                    raise RuntimeError(
                        f"Wine mission entry reached {reason}; timeline={timeline_path}"
                    )
            # Optional legacy boot-dismiss input. Autostart captures are fully
            # patched past dialogs/VQAs; unsolicited Enter/Space can race slower
            # CD2 starts and select Top Scores from the main menu.
            elapsed = timeline_entries[-1]["t"] if timeline_entries else 0.0
            settle_after_gameplay = os.environ.get(
                "WINE_SETTLE_AFTER_GAMEPLAY", "0"
            ) not in ("", "0")
            if elapsed < boot_settle and (
                settle_after_gameplay
                or not _timeline_reached_gameplay(timeline_entries)
            ):
                time.sleep(boot_settle - elapsed)
            boot_dismiss_default = "0"
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
                timeline_entries, timeline_path = self._capture_screen_timeline(
                    disp,
                    output_dir,
                    logfile,
                    float(os.environ.get("WINE_MENU_DRIVE_TIMELINE_SETTLE", "5.0")),
                    {**timeline_metadata, "phase": "post-menu-drive"},
                )
                if strict_frameprobe:
                    reason = _timeline_strict_failure(timeline_entries)
                    if reason:
                        self._run_state_probe(staging, disp, output_dir, logfile)
                        raise RuntimeError(
                            "Wine mission entry reached "
                            f"{reason}; timeline={timeline_path}"
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
            if session_clamp is not None and session_clamp.poll() not in (None, 0):
                raise RuntimeError(
                    f"session-normal clamp failed rc={session_clamp.returncode}"
                )
            center_mouse(disp, 640, 400)
            time.sleep(float(os.environ.get("WINE_GAMEPLAY_SETTLE", "0.0")))
            if cncddraw_capture:
                timeout_s = float(os.environ.get("WINE_CNCDDRAW_CAPTURE_TIMEOUT", "60"))
                wait_scan = os.environ.get("WINE_DWORD_WAIT_SCAN_VALUE", "")
                wait_wordpair = os.environ.get("WINE_WORDPAIR_WAIT_SCAN", "")
                wait_coords = os.environ.get("WINE_COORD_WAIT_SCAN", "")
                wait_scan_proc = None
                if wait_scan or wait_wordpair or wait_coords:
                    self._build_frameprobe()
                    wait_scan_frame = os.environ.get(
                        "WINE_DWORD_WAIT_SCAN_FRAME",
                        os.environ.get(
                            "WINE_CNCDDRAW_CAPTURE_RA_START",
                            os.environ.get(
                                "WINE_CNCDDRAW_CAPTURE_START", cncddraw_capture_flip
                            ),
                        ),
                    )
                    if wait_coords:
                        coord_range = [item.strip() for item in wait_coords.split(",")]
                        if len(coord_range) != 4 or any(
                            not item for item in coord_range
                        ):
                            raise ValueError(
                                "WINE_COORD_WAIT_SCAN must be '<xmin>,<xmax>,<ymin>,<ymax>'"
                            )
                        command = [
                            str(self.wine),
                            str(self._frameprobe_exe),
                            "--wait-scan-coords",
                            str(wait_scan_frame),
                            *coord_range,
                            os.environ.get("WINE_DWORD_SCAN_MAX", "128"),
                            os.environ.get("WINE_COORD_SCAN_MIN_ADDR", "0"),
                            os.environ.get("WINE_COORD_SCAN_MAX_ADDR", "0"),
                        ]
                    elif wait_wordpair:
                        pair = [item.strip() for item in wait_wordpair.split(",")]
                        if len(pair) != 2 or not pair[0] or not pair[1]:
                            raise ValueError(
                                "WINE_WORDPAIR_WAIT_SCAN must be '<word-a>,<word-b>'"
                            )
                        command = [
                            str(self.wine),
                            str(self._frameprobe_exe),
                            "--wait-scan-wordpair",
                            str(wait_scan_frame),
                            pair[0],
                            pair[1],
                            os.environ.get("WINE_WORDPAIR_SCAN_WINDOW", "96"),
                            os.environ.get("WINE_DWORD_SCAN_MAX", "128"),
                        ]
                    else:
                        command = [
                            str(self.wine),
                            str(self._frameprobe_exe),
                            "--wait-scan-dword",
                            str(wait_scan_frame),
                            wait_scan,
                            os.environ.get("WINE_DWORD_SCAN_MAX", "128"),
                        ]
                    wait_scan_proc = subprocess.Popen(
                        command,
                        cwd=str(staging),
                        env=self._frameprobe_env(disp),
                        stdout=logfile,
                        stderr=logfile,
                    )
                if cncddraw_capture_count > 1:
                    sequence_start = int(
                        os.environ.get(
                            "WINE_CNCDDRAW_CAPTURE_RA_START",
                            os.environ.get(
                                "WINE_CNCDDRAW_CAPTURE_START", cncddraw_capture_flip
                            ),
                        ),
                        0,
                    )
                    sequence_paths = self._wait_for_cncddraw_sequence(
                        cncddraw_sequence_dir,
                        sequence_start,
                        cncddraw_capture_count,
                        "ra"
                        if os.environ.get("WINE_CNCDDRAW_CAPTURE_RA_START")
                        else "render",
                        wine_proc,
                        timeout_s,
                        logfile,
                    )
                    (output_dir / "wine-frame.txt").write_text(
                        "requested={requested}\nactual={actual}\n"
                        "reason=cnc-ddraw-sequence\naddr=none\n"
                        "bc_capture_start={start}\n"
                        "bc_capture_count={count}\n".format(
                            requested=frame,
                            actual=sequence_start,
                            start=sequence_start,
                            count=cncddraw_capture_count,
                        )
                    )
                    return sequence_paths[0]
                cap_path = self._wait_for_cncddraw_capture(
                    cncddraw_capture_path, wine_proc, timeout_s, logfile
                )
                if wait_scan_proc is not None:
                    try:
                        wait_scan_proc.wait(
                            timeout=float(
                                os.environ.get("WINE_DWORD_SCAN_TIMEOUT", "45")
                            )
                        )
                    except subprocess.TimeoutExpired:
                        wait_scan_proc.terminate()
                        wait_scan_proc.wait(timeout=5)
                scan_value = os.environ.get("WINE_DWORD_SCAN_AFTER_CAPTURE")
                if scan_value:
                    self._build_frameprobe()
                    scan_max = os.environ.get("WINE_DWORD_SCAN_MAX", "128")
                    for value in scan_value.split(","):
                        value = value.strip()
                        if not value:
                            continue
                        subprocess.run(
                            [
                                str(self.wine),
                                str(self._frameprobe_exe),
                                "--scan-dword",
                                value,
                                scan_max,
                            ],
                            cwd=str(staging),
                            env=self._frameprobe_env(disp),
                            stdout=logfile,
                            stderr=logfile,
                            timeout=float(
                                os.environ.get("WINE_DWORD_SCAN_TIMEOUT", "45")
                            ),
                        )
                if os.environ.get("WINE_STATE_AFTER_CAPTURE_FRAME", "0") not in (
                    "",
                    "0",
                ):
                    self._run_state_probe(staging, disp, output_dir, logfile)
                (output_dir / "wine-frame.txt").write_text(
                    "requested={requested}\nactual={flip}\n"
                    "reason=cnc-ddraw-flip\naddr=none\n"
                    "bc_capture_flip={flip}\n".format(
                        requested=frame,
                        flip=cncddraw_capture_flip,
                    )
                )
                return cap_path
            if os.environ.get("WINE_COUNTER_SCAN", "0") not in ("", "0"):
                self._build_frameprobe()
                subprocess.run(
                    [str(self.wine), str(self._frameprobe_exe), "-9"],
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
            # Wait for target frame
            if use_frameprobe:
                if session_clamp is not None:
                    try:
                        session_clamp.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        session_clamp.terminate()
                        session_clamp.wait(timeout=5)
                        raise RuntimeError("session-normal clamp timeout")
                    if session_clamp.returncode != 0:
                        raise RuntimeError(
                            f"session-normal clamp failed rc={session_clamp.returncode}"
                        )
                addr = os.environ.get("WINE_FRAME_ADDR", DEFAULT_WINE_FRAME_ADDR)
                if os.environ.get("WINE_FRAMEPROBE_BACKEND", "proc") == "proc":
                    try:
                        probe_ok, actual_frame, frame_reason = self._wait_proc_frame(
                            staging,
                            frame,
                            addr,
                            logfile,
                            wine_proc.pid,
                            output_dir / "wine-frame-candidates.json",
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
                        if os.environ.get("WINE_FRAMEPROBE_STRICT", "1") not in (
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
                            self._run_state_probe(staging, disp, output_dir, logfile)
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
                    frameprobe_env = self._frameprobe_env(disp)
                    frameprobe_rc = 1
                    frameprobe_failure = "unknown"
                    try:
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
                        frameprobe_rc = r.returncode
                        frameprobe_failure = f"rc={r.returncode}"
                    except subprocess.TimeoutExpired:
                        frameprobe_failure = "timeout"
                        logfile.write("wine-driver: frameprobe timed out\n")
                        logfile.flush()
                    if frameprobe_rc != 0:
                        logfile.write(
                            "wine-driver: frameprobe failed; retrying without input\n"
                        )
                        logfile.flush()
                        try:
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
                            frameprobe_rc = r.returncode
                            frameprobe_failure = f"rc={r.returncode}"
                        except subprocess.TimeoutExpired:
                            frameprobe_rc = 1
                            frameprobe_failure = "timeout"
                            logfile.write("wine-driver: frameprobe retry timed out\n")
                            logfile.flush()
                    if frameprobe_rc != 0:
                        try:
                            capture_root(
                                disp, output_dir / "wine-frameprobe-failure.png"
                            )
                        except Exception as exc:
                            logfile.write(
                                f"wine-driver: failure screenshot failed: {exc}\n"
                            )
                            logfile.flush()
                        self._run_state_probe(staging, disp, output_dir, logfile)
                        raise RuntimeError(
                            f"ra-frameprobe failed ({frameprobe_failure})"
                        )
                if os.environ.get("WINE_CELL_SCAN", "0") not in ("", "0"):
                    self._build_frameprobe()
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
                if os.environ.get("WINE_COORD_SCAN_AFTER_FRAME", "0") not in (
                    "",
                    "0",
                ):
                    wait_coords = os.environ.get("WINE_COORD_WAIT_SCAN", "")
                    if not wait_coords:
                        raise ValueError(
                            "WINE_COORD_SCAN_AFTER_FRAME requires WINE_COORD_WAIT_SCAN='<xmin>,<xmax>,<ymin>,<ymax>'"
                        )
                    coord_range = [item.strip() for item in wait_coords.split(",")]
                    if len(coord_range) != 4 or any(not item for item in coord_range):
                        raise ValueError(
                            "WINE_COORD_WAIT_SCAN must be '<xmin>,<xmax>,<ymin>,<ymax>'"
                        )
                    self._build_frameprobe()
                    scan_frame = (
                        actual_frame if actual_frame and actual_frame > 0 else frame
                    )
                    subprocess.run(
                        [
                            str(self.wine),
                            str(self._frameprobe_exe),
                            "--wait-scan-coords",
                            str(scan_frame),
                            *coord_range,
                            os.environ.get("WINE_DWORD_SCAN_MAX", "128"),
                            os.environ.get("WINE_COORD_SCAN_MIN_ADDR", "0"),
                            os.environ.get("WINE_COORD_SCAN_MAX_ADDR", "0"),
                        ],
                        cwd=str(staging),
                        env=self._frameprobe_env(disp),
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_DWORD_SCAN_AFTER_FRAME", "0") not in (
                    "",
                    "0",
                ):
                    wait_scan = os.environ.get("WINE_DWORD_WAIT_SCAN_VALUE", "")
                    if not wait_scan:
                        raise ValueError(
                            "WINE_DWORD_SCAN_AFTER_FRAME requires WINE_DWORD_WAIT_SCAN_VALUE"
                        )
                    self._build_frameprobe()
                    scan_frame = (
                        actual_frame if actual_frame and actual_frame > 0 else frame
                    )
                    subprocess.run(
                        [
                            str(self.wine),
                            str(self._frameprobe_exe),
                            "--wait-scan-dword",
                            str(scan_frame),
                            wait_scan,
                            os.environ.get("WINE_DWORD_SCAN_MAX", "128"),
                        ],
                        cwd=str(staging),
                        env=self._frameprobe_env(disp),
                        stdout=logfile,
                        stderr=logfile,
                        timeout=45,
                    )
                if os.environ.get("WINE_TEMPLATE_SCAN", "0") not in ("", "0"):
                    self._build_frameprobe()
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
                    self._build_frameprobe()
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
                    self._build_frameprobe()
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
                    self._build_frameprobe()
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
                    self._build_frameprobe()
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
            if os.environ.get("WINE_STATE_AFTER_CAPTURE_FRAME", "0") not in ("", "0"):
                self._run_state_probe(staging, disp, output_dir, logfile)
            return cap_path
        except Exception as exc:
            self._raise_with_patch_manifest(exc, output_dir, logfile)
        finally:
            if session_clamp is not None and session_clamp.poll() is None:
                session_clamp.terminate()
                try:
                    session_clamp.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    session_clamp.kill()
                    session_clamp.wait(timeout=5)
            self._cleanup(disp, staging, wine_proc, xvfb, wm)

    def capture_mission_sequence(
        self,
        scenario: str,
        start_frame: int,
        count: int,
        output_dir: pathlib.Path,
        clock: str = "ra",
        logfile=None,
    ) -> pathlib.Path:
        """Capture a deterministic cnc-ddraw render-frame sequence from Wine."""
        if count <= 0:
            raise ValueError("count must be positive")
        if clock not in ("ra", "render"):
            raise ValueError("clock must be 'ra' or 'render'")
        keys = [
            "WINE_CNCDDRAW_CAPTURE",
            "WINE_CNCDDRAW_CAPTURE_START",
            "WINE_CNCDDRAW_CAPTURE_RA_START",
            "WINE_CNCDDRAW_CAPTURE_FLIP",
            "WINE_CNCDDRAW_CAPTURE_COUNT",
            "WINE_CNCDDRAW_CAPTURE_HALT",
        ]
        old_env = {key: os.environ.get(key) for key in keys}
        try:
            os.environ["WINE_CNCDDRAW_CAPTURE"] = "1"
            os.environ["WINE_CNCDDRAW_CAPTURE_START"] = str(start_frame)
            os.environ["WINE_CNCDDRAW_CAPTURE_FLIP"] = str(start_frame)
            os.environ["WINE_CNCDDRAW_CAPTURE_COUNT"] = str(count)
            if clock == "ra":
                os.environ["WINE_CNCDDRAW_CAPTURE_RA_START"] = str(start_frame)
            else:
                os.environ.pop("WINE_CNCDDRAW_CAPTURE_RA_START", None)
            os.environ.setdefault("WINE_CNCDDRAW_CAPTURE_HALT", "1")
            self.capture_mission(scenario, start_frame, output_dir, logfile)
            return output_dir / "wine-sequence"
        finally:
            for key, value in old_env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def capture_mission_state(
        self, scenario: str, output_dir: pathlib.Path, logfile=None
    ) -> dict[str, str]:
        """Launch a Wine mission and dump state without taking a final capture."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = staging = None
        menu_drive = os.environ.get("WINE_MENU_DRIVE", "0") not in ("", "0")
        try:
            staging = self._setup_staging(
                scenario,
                skip_vqa=True,
                autostart=not menu_drive,
                output_dir=output_dir,
            )
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            self._create_wineprefix(staging)
            wine_proc = self._launch(staging, logfile, disp)
            if not wait_for_window(disp, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            timeline_metadata = {
                "scenario": f"{scenario}.INI",
                "state_only": True,
                "menu_drive": menu_drive,
            }
            old_samples = os.environ.get("WINE_SCREEN_TIMELINE_SECONDS")
            os.environ["WINE_SCREEN_TIMELINE_SECONDS"] = os.environ.get(
                "WINE_STATE_TIMELINE_SECONDS", "0,1,2,5,10,15"
            )
            try:
                timeline_entries, timeline_path = self._capture_screen_timeline(
                    disp,
                    output_dir,
                    logfile,
                    float(os.environ.get("WINE_STATE_WAIT", "15.0")),
                    timeline_metadata,
                    stop_on_first_non_loading=True,
                )
            finally:
                if old_samples is None:
                    os.environ.pop("WINE_SCREEN_TIMELINE_SECONDS", None)
                else:
                    os.environ["WINE_SCREEN_TIMELINE_SECONDS"] = old_samples
            if not first_non_loading_state(timeline_entries):
                self._run_state_probe(staging, disp, output_dir, logfile)
                raise RuntimeError(
                    "Wine state-only did not observe non-loading state; "
                    f"timeline={timeline_path}"
                )
            return self._run_state_probe(staging, disp, output_dir, logfile)
        except Exception as exc:
            self._raise_with_patch_manifest(exc, output_dir, logfile)
        finally:
            self._cleanup(disp, staging, wine_proc, xvfb, wm)

    def capture_vqa(
        self, vqa_stem: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        """Capture a screenshot from a VQA at the given frame."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = staging = None
        try:
            staging = self._setup_staging(None, skip_vqa=False, output_dir=output_dir)
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
        except Exception as exc:
            self._raise_with_patch_manifest(exc, output_dir, logfile)
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
        xvfb = wm = wine_proc = staging = None
        try:
            staging = self._setup_staging(
                scenario=None, skip_vqa=True, output_dir=output_dir
            )
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
        except Exception as exc:
            self._raise_with_patch_manifest(exc, output_dir, logfile)
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
