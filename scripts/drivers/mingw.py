"""MinGW/Wine capture probe for the ported Win32 RA executable."""

import json
import os
import pathlib
import re
import shutil
import subprocess
import time

from .common import (
    capture_root,
    center_mouse,
    pick_free_display,
    start_xvfb,
    start_openbox,
    teardown_display,
)
from .native import _convert_valid_internal_bmp, capture_timeout_seconds


MIX_METADATA_PATTERNS = (
    re.compile(
        r"\[MIX\] ctor: (?P<file>[^ ]+) fileheader done, count=(?P<count>-?\d+) size=(?P<size>-?\d+)"
    ),
    re.compile(
        r"\[MIX\] ctor: (?P<file>[^ ]+) Count=(?P<count>-?\d+) DataSize=(?P<size>-?\d+)"
    ),
)


def _repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def _nix_eval_raw(expr: str) -> str | None:
    flake = _repo_root() / "flake.nix"
    try:
        if "<<<<<<<" in flake.read_text(errors="replace"):
            return None
    except OSError:
        pass
    nix = (
        os.environ.get("NIX_BIN")
        or shutil.which("nix")
        or "/nix/var/nix/profiles/default/bin/nix"
    )
    if not pathlib.Path(nix).exists():
        return None
    try:
        result = subprocess.run(
            [nix, "eval", "--impure", "--raw", "--expr", expr],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=_repo_root(),
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def _flake_pkg_expr(attribute: str) -> str:
    return (
        "let flake = builtins.getFlake (toString ./.); "
        "pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux; "
        f"in {attribute}"
    )


def _resolve_runtime_env() -> dict[str, str]:
    env = dict(os.environ)
    defaults = {
        "MINGW_SDL2_DEV": _flake_pkg_expr("pkgs.pkgsCross.mingw32.SDL2.dev.outPath"),
        "MINGW_SDL3_BIN": _flake_pkg_expr(
            "(pkgs.lib.getBin pkgs.pkgsCross.mingw32.sdl3).outPath"
        ),
        "MINGW_MCFGTHREAD": _flake_pkg_expr(
            "pkgs.pkgsCross.mingw32.windows.mcfgthreads.outPath"
        ),
        "MINGW_GCC_LIB": _flake_pkg_expr(
            "pkgs.pkgsCross.mingw32.buildPackages.gcc.cc.lib.outPath"
        ),
    }
    for key, expr in defaults.items():
        if env.get(key):
            continue
        value = _nix_eval_raw(expr)
        if value:
            env[key] = value
    fallback_dlls = {
        "MINGW_SDL2_DEV": "*/bin/SDL2.dll",
        "MINGW_SDL3_BIN": "*/bin/SDL3.dll",
        "MINGW_MCFGTHREAD": "*/bin/libmcfgthread-2.dll",
        "MINGW_GCC_LIB": "*/i686-w64-mingw32/lib/libstdc++-6.dll",
    }
    for key, pattern in fallback_dlls.items():
        if env.get(key):
            continue
        candidates = sorted(pathlib.Path("/nix/store").glob(pattern))
        for dll_path in candidates:
            path_text = str(dll_path)
            if "i686-w64-mingw32" not in path_text and "mingw32" not in path_text:
                continue
            if key == "MINGW_GCC_LIB":
                # .../store/pkg/i686-w64-mingw32/lib/libstdc++-6.dll -> store pkg
                env[key] = str(dll_path.parents[2])
            else:
                # .../store/pkg/bin/SDL*.dll -> store pkg
                env[key] = str(dll_path.parents[1])
            break
    return env


def _read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def classify_mingw_failure(
    stderr_text: str, screenshot_state: str | None = None
) -> dict:
    """Classify the known MinGW/Wine probe states from logs and optional screenshot."""
    metadata = []
    for pattern in MIX_METADATA_PATTERNS:
        for match in pattern.finditer(stderr_text):
            metadata.append(
                {
                    "file": match.group("file"),
                    "count": int(match.group("count")),
                    "size": int(match.group("size")),
                }
            )

    bad_mix = [
        row
        for row in metadata
        if row["count"] < 0
        or row["count"] > 4096
        or row["size"] < 0
        or row["size"] > 1024 * 1024 * 1024
    ]
    if (
        "Failed loading SDL3 library" in stderr_text
        or screenshot_state == "sdl3-dialog"
    ):
        status = "sdl3-runtime-missing"
        detail = "Win32 SDL2 compatibility layer could not load SDL3.dll"
    elif bad_mix:
        status = "mix-metadata-failure"
        first = bad_mix[0]
        detail = (
            f"{first['file']} has implausible MIX metadata "
            f"count={first['count']} size={first['size']}"
        )
    elif "std::bad_alloc" in stderr_text:
        status = "bad-alloc"
        detail = "process terminated with std::bad_alloc"
    elif "[RA] Bootstrap: Init_Bootstrap_Mixfiles done" in stderr_text:
        status = "bootstrap-mix-ok"
        detail = "bootstrap MIX loading completed"
    elif "[RA] STARTUP:" in stderr_text:
        status = "startup-before-bootstrap"
        detail = "process reached RA startup but not bootstrap completion"
    else:
        status = "unknown"
        detail = "no recognized MinGW probe signature"

    return {
        "status": status,
        "detail": detail,
        "screenshot_state": screenshot_state,
        "mix_metadata": metadata[-12:],
        "bad_mix_metadata": bad_mix,
    }


class MingwCapture:
    """Run the ported Win32 RA executable under Wine and classify early failures."""

    def __init__(self, data_dir=None, ra_exe=None):
        self.repo = _repo_root()
        self.data_dir = pathlib.Path(
            data_dir
            or os.environ.get("DATA_DIR")
            or os.environ.get("RA_ASSETS")
            or "/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1"
        )
        self.ra_exe = pathlib.Path(
            ra_exe
            or os.environ.get("RA_MINGW_EXE")
            or self.repo / "build-mingw32" / "ra.exe"
        )
        if not self.ra_exe.is_file():
            raise RuntimeError(
                f"missing MinGW RA executable: {self.ra_exe}; "
                "build with `cmake --preset mingw32 && cmake --build build-mingw32 --target ra`"
            )
        if not (self.data_dir / "REDALERT.MIX").is_file():
            raise RuntimeError(f"MinGW DATA_DIR={self.data_dir} has no REDALERT.MIX")

    def capture_mission(
        self, scenario: str, frame: int, output_dir: pathlib.Path, logfile=None
    ) -> pathlib.Path:
        output_dir.mkdir(parents=True, exist_ok=True)
        logfile = logfile or subprocess.DEVNULL
        disp = pick_free_display()
        xvfb = wm = proc = None
        env = _resolve_runtime_env()
        run_dir = output_dir / "mingw-run"
        stderr_path = output_dir / "mingw-stderr.log"
        stdout_path = output_dir / "mingw-stdout.log"
        ready_path = output_dir / "mingw-ready.txt"
        bmp_path = output_dir / "mingw-capture.bmp"
        cap_path = output_dir / "capture.png"
        screenshot = output_dir / "mingw-root.png"
        for path in (ready_path, bmp_path, cap_path, screenshot):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        try:
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            env.update(
                {
                    "DISPLAY": disp,
                    "DATA_DIR": str(self.data_dir),
                    "WINEDEBUG": "-all",
                    "WAYLAND_DISPLAY": "",
                    "RA_MINGW_RUN_DIR": str(run_dir),
                    "RA_MINGW_EXE": str(self.ra_exe),
                    "RA_AUTOSTART": "1",
                    "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
                    "RA_CAPTURE_FPS": os.environ.get("RA_CAPTURE_FPS", "10"),
                    "RA_CAPTURE_FRAME": str(max(frame, 1)),
                    "RA_CAPTURE_READY_FILE": str(ready_path),
                    "RA_CAPTURE_BMP_FILE": str(bmp_path),
                }
            )
            if os.environ.get("RA_CAPTURE_STATE_DUMP", "0") not in ("", "0"):
                env["RA_CAPTURE_STATE_FILE"] = str(output_dir / "mingw-state-dump.txt")
            if os.environ.get("BC_CAPTURE_MOUSE_X") and os.environ.get(
                "BC_CAPTURE_MOUSE_Y"
            ):
                env["RA_CAPTURE_MOUSE_X"] = os.environ["BC_CAPTURE_MOUSE_X"]
                env["RA_CAPTURE_MOUSE_Y"] = os.environ["BC_CAPTURE_MOUSE_Y"]
            frame_capture = {
                "requested_frame": max(frame, 1),
                "ready_file": str(ready_path),
                "bmp": str(bmp_path),
                "png": str(cap_path),
                "status": "pending",
            }
            with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
                proc = subprocess.Popen(
                    [str(self.repo / "scripts" / "run-mingw-ra.sh")],
                    cwd=str(self.repo),
                    env=env,
                    stdout=stdout,
                    stderr=stderr,
                )
                center_mouse(disp, 640, 400)
                fps = int(env["RA_CAPTURE_FPS"])
                # MinGW-under-Wine often runs below the requested throttle rate;
                # high requested FPS values should not shrink the capture budget.
                budget_fps = min(max(fps, 1), 10)
                timeout_s = max(
                    capture_timeout_seconds(max(frame, 1), budget_fps),
                    float(os.environ.get("MINGW_PROBE_SECONDS", "12")),
                )
                if hasattr(logfile, "write"):
                    logfile.write(
                        "mingw-driver: waiting for frame trap "
                        f"frame={max(frame, 1)} requested_fps={fps} "
                        f"budget_fps={budget_fps} timeout={timeout_s:.1f}s\n"
                    )
                    logfile.flush()
                deadline = time.time() + max(
                    timeout_s,
                    1,
                )
                while time.time() < deadline:
                    if ready_path.exists():
                        break
                    if proc.poll() is not None:
                        break
                    time.sleep(0.05)
                if ready_path.exists():
                    ok, reason = _convert_valid_internal_bmp(
                        bmp_path, cap_path, min_unique_colours=16
                    )
                    frame_capture["status"] = "ok" if ok else "invalid-bmp"
                    frame_capture["detail"] = reason
                else:
                    frame_capture["status"] = "missing-ready"
                    if proc.poll() is not None:
                        frame_capture["detail"] = (
                            f"process exited before frame trap rc={proc.returncode}"
                        )
                    else:
                        frame_capture["detail"] = "timed out before frame trap"

                if frame_capture["status"] != "ok":
                    try:
                        capture_root(disp, str(screenshot))
                    except Exception as exc:
                        if hasattr(logfile, "write"):
                            logfile.write(f"mingw-driver: screenshot failed: {exc}\n")
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)

            screenshot_state = None
            state_image = cap_path if cap_path.exists() else screenshot
            if state_image.exists():
                screenshot_state = self._classify_screenshot(state_image)
            classification = classify_mingw_failure(
                _read_text(stderr_path), screenshot_state
            )
            classification.update(
                {
                    "stdout": str(stdout_path),
                    "stderr": str(stderr_path),
                    "screenshot": str(screenshot) if screenshot.exists() else None,
                    "frame_capture": frame_capture,
                    "process_returncode": proc.returncode if proc else None,
                }
            )
            (output_dir / "mingw-state.json").write_text(
                json.dumps(classification, indent=2) + "\n"
            )
            (output_dir / "mingw-state.txt").write_text(
                f"status={classification['status']}\n"
                f"detail={classification['detail']}\n"
            )
            if classification["status"] != "bootstrap-mix-ok":
                raise RuntimeError(
                    f"MinGW probe classified as {classification['status']}: "
                    f"{classification['detail']}"
                )
            if frame_capture["status"] == "ok" and cap_path.exists():
                return cap_path
            if screenshot.exists():
                return screenshot
            raise RuntimeError("MinGW probe reached bootstrap but produced no capture")
        finally:
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            teardown_display(disp, proc, wm, xvfb)

    @staticmethod
    def _classify_screenshot(path: pathlib.Path) -> str:
        try:
            from PIL import Image

            with Image.open(path).convert("RGB") as image:
                pixels = list(image.getdata())
        except Exception:
            return "unreadable"
        total = len(pixels) or 1
        nonblack = sum(pixel != (0, 0, 0) for pixel in pixels) / total
        # The SDL3 runtime dialog is a small pale box on a black root window.
        if 0.01 < nonblack < 0.05:
            return "dialog-or-small-window"
        if nonblack <= 0.001:
            return "black"
        return "nonblack"
