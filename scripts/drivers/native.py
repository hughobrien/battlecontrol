"""Native capture driver — capture screenshots from native Linux RA build."""

import subprocess
import os
import shutil
import sys
import time
import pathlib
import tempfile
from .common import (
    pick_free_display,
    start_xvfb,
    start_openbox,
    capture_root,
    center_mouse,
    teardown_display,
    check_tmp_free_space,
)


EXPECTED_CAPTURE_SIZE = (640, 400)
MIN_CAPTURE_UNIQUE_COLOURS = 64
MIN_CAPTURE_LUMINANCE_SPREAD = 32
MIN_CAPTURE_MAX_LUMINANCE = 96
MIN_CAPTURE_RGB_SPREAD = 32
MIN_CAPTURE_NONBLACK_FRACTION = 0.05


def capture_timeout_seconds(frame: int, fps: int) -> int:
    """Return enough time for startup plus the requested internal frame."""
    if fps <= 0:
        fps = 10
    effective_fps = max(fps / 2.0, 1.0)
    return max(45, int(frame / effective_fps) + 30)


def default_ra_bin() -> str:
    for candidate in ("build/ra/redalert", "build/ra"):
        if pathlib.Path(candidate).is_file():
            return candidate
    return "build/ra/redalert"


def _warn(message: str, logfile=None) -> None:
    text = f"WARNING native capture: {message}"
    print(f"  {text}", file=sys.stderr)
    if hasattr(logfile, "write"):
        try:
            logfile.write(text + "\n")
            logfile.flush()
        except Exception:
            pass


def _validate_capture_image(
    path: pathlib.Path,
    expected_size: tuple[int, int] = EXPECTED_CAPTURE_SIZE,
    min_unique_colours: int = MIN_CAPTURE_UNIQUE_COLOURS,
) -> tuple[bool, str]:
    """Validate dimensions and pixel range for a captured frame."""
    if not path.exists():
        return False, f"{path.name} does not exist"
    if path.stat().st_size == 0:
        return False, f"{path.name} is empty"

    try:
        from PIL import Image

        with Image.open(path) as image:
            if image.size != expected_size:
                return (
                    False,
                    f"{path.name} has dimensions {image.size[0]}x{image.size[1]}, "
                    f"expected {expected_size[0]}x{expected_size[1]}",
                )
            rgb_image = image.convert("RGB")
            colours = rgb_image.getcolors(maxcolors=min_unique_colours)
            pixels = list(rgb_image.getdata())
    except Exception as exc:
        return False, f"could not inspect {path.name}: {exc}"

    if colours is not None and len(colours) < min_unique_colours:
        return (
            False,
            f"{path.name} has only {len(colours)} unique colours; "
            f"expected at least {min_unique_colours}",
        )
    total_pixels = len(pixels)
    if total_pixels == 0:
        return False, f"{path.name} has no pixels"
    red_values = [pixel[0] for pixel in pixels]
    green_values = [pixel[1] for pixel in pixels]
    blue_values = [pixel[2] for pixel in pixels]
    luminance_values = [
        (pixel[0] * 299 + pixel[1] * 587 + pixel[2] * 114) // 1000 for pixel in pixels
    ]
    rgb_spread = max(
        max(red_values) - min(red_values),
        max(green_values) - min(green_values),
        max(blue_values) - min(blue_values),
    )
    luminance_spread = max(luminance_values) - min(luminance_values)
    max_luminance = max(luminance_values)
    nonblack_fraction = (
        sum(1 for pixel in pixels if pixel[0] >= 12 or pixel[1] >= 12 or pixel[2] >= 12)
        / total_pixels
    )
    if max_luminance < MIN_CAPTURE_MAX_LUMINANCE:
        return (
            False,
            f"{path.name} maximum luminance is too low ({max_luminance}); "
            f"expected at least {MIN_CAPTURE_MAX_LUMINANCE}",
        )
    if rgb_spread < MIN_CAPTURE_RGB_SPREAD:
        return (
            False,
            f"{path.name} RGB range is too low ({rgb_spread}); "
            f"expected at least {MIN_CAPTURE_RGB_SPREAD}",
        )
    if luminance_spread < MIN_CAPTURE_LUMINANCE_SPREAD:
        return (
            False,
            f"{path.name} luminance range is too low ({luminance_spread}); "
            f"expected at least {MIN_CAPTURE_LUMINANCE_SPREAD}",
        )
    if nonblack_fraction < MIN_CAPTURE_NONBLACK_FRACTION:
        return (
            False,
            f"{path.name} non-black fraction is too low "
            f"({nonblack_fraction:.3f}); expected at least "
            f"{MIN_CAPTURE_NONBLACK_FRACTION:.3f}",
        )
    return True, "ok"


def _bmp_is_candidate(path: pathlib.Path) -> tuple[bool, str]:
    if not path.exists():
        return False, f"{path.name} does not exist"
    size = path.stat().st_size
    if size == 0:
        return False, f"{path.name} is empty"
    try:
        magic = path.read_bytes()[:2]
    except OSError as exc:
        return False, f"could not read {path.name}: {exc}"
    if magic != b"BM":
        return False, f"{path.name} does not have BMP magic"
    return True, "ok"


def _convert_valid_internal_bmp(
    bmp_path: pathlib.Path,
    png_path: pathlib.Path,
    min_unique_colours: int = MIN_CAPTURE_UNIQUE_COLOURS,
) -> tuple[bool, str]:
    """Convert the internal BMP frame trap to PNG and validate the PNG."""
    ok, reason = _bmp_is_candidate(bmp_path)
    if not ok:
        return False, reason
    if not shutil.which("convert"):
        return False, "ImageMagick `convert` is unavailable"

    check_tmp_free_space("/tmp")
    try:
        png_path.unlink()
    except FileNotFoundError:
        pass
    result = subprocess.run(
        ["convert", str(bmp_path), str(png_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        detail = f": {stderr}" if stderr else ""
        return False, f"`convert capture.bmp capture.png` failed{detail}"

    return _validate_capture_image(png_path, min_unique_colours=min_unique_colours)


def stage_data_dir(
    data_dir: pathlib.Path,
    parent_dir: pathlib.Path,
    base_data_dir: pathlib.Path | None = None,
) -> pathlib.Path:
    """Create a writable run directory containing links to the RA data files."""
    staged = pathlib.Path(tempfile.mkdtemp(prefix="native-data-", dir=str(parent_dir)))

    def link_entries(source_dir: pathlib.Path, overwrite: bool) -> None:
        for source in source_dir.iterdir():
            target = staged / source.name
            if source.is_dir():
                continue
            if target.exists() or target.is_symlink():
                if not overwrite:
                    continue
                target.unlink()
            target.symlink_to(source)

    if base_data_dir is not None and base_data_dir.is_dir():
        link_entries(base_data_dir, overwrite=False)
    link_entries(data_dir, overwrite=True)

    if not (staged / "REDALERT.INI").exists():
        (staged / "REDALERT.INI").write_text(
            "[Sound]\nCard=-1\n[Options]\nHardwareFills=no\n[Intro]\nPlayIntro=no\n"
        )
    return staged


class NativeCapture:
    """Capture screenshots from the native Linux RA build."""

    def __init__(self, ra_bin=None, data_dir=None):
        ra_bin = ra_bin or os.environ.get("RA_BIN") or default_ra_bin()
        if not ra_bin:
            raise RuntimeError("RA_BIN not set; export RA_BIN=/abs/path/to/ra")
        self.ra_bin = pathlib.Path(ra_bin).resolve()
        if not self.ra_bin.is_file():
            raise RuntimeError(
                f"RA_BIN/default native binary {self.ra_bin} is not a file; "
                "build RA or export RA_BIN=/abs/path/to/redalert"
            )

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
        staged_data_dir = None
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            base_data_dir = os.environ.get("RA_ASSETS")
            staged_data_dir = stage_data_dir(
                self.data_dir,
                output_dir,
                pathlib.Path(base_data_dir) if base_data_dir else None,
            )
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
                cwd=str(staged_data_dir),
                stdout=logfile,
                stderr=logfile,
            )
            center_mouse(disp, 640, 400)
            # Wait for the in-game frame trap instead of wall-clock guessing.
            fps = int(env["RA_CAPTURE_FPS"])
            deadline = time.time() + capture_timeout_seconds(max(frame, 1), fps)
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
            ok, reason = _convert_valid_internal_bmp(bmp_path, cap_path)
            if not ok:
                _warn(
                    f"internal BMP unavailable or invalid ({reason}); "
                    "falling back to `import -window root`",
                    logfile=logfile,
                )
                capture_root(disp, str(cap_path))
                valid_root, root_reason = _validate_capture_image(cap_path)
                if not valid_root:
                    raise RuntimeError(f"native root capture invalid: {root_reason}")
            return cap_path
        finally:
            teardown_display(disp, ra_proc, wm, xvfb)
            if staged_data_dir is not None:
                shutil.rmtree(staged_data_dir, ignore_errors=True)

    def capture_mission_sequence(
        self,
        scenario: str,
        start: int,
        count: int,
        output_dir: pathlib.Path,
        logfile=None,
    ) -> pathlib.Path:
        """Capture a run of native RA gameplay frames from one process."""
        disp = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = ra_proc = None
        staged_data_dir = None
        try:
            output_dir.mkdir(parents=True, exist_ok=True)
            sequence_dir = output_dir / "native-sequence"
            sequence_dir.mkdir(parents=True, exist_ok=True)
            bmp_dir = output_dir / "native-bmp-sequence"
            if bmp_dir.exists():
                shutil.rmtree(bmp_dir)
            bmp_dir.mkdir(parents=True)
            ready_path = output_dir / "native-sequence-ready.txt"
            try:
                ready_path.unlink()
            except FileNotFoundError:
                pass

            base_data_dir = os.environ.get("RA_ASSETS")
            staged_data_dir = stage_data_dir(
                self.data_dir,
                output_dir,
                pathlib.Path(base_data_dir) if base_data_dir else None,
            )
            xvfb = start_xvfb(disp, 640, 400, logfile=logfile)
            wm = start_openbox(disp, logfile=logfile)
            env = {
                **os.environ,
                "DISPLAY": disp,
                "SDL_AUDIODRIVER": "dummy",
                "RA_AUTOSTART": "1",
                "RA_AUTOSTART_SCENARIO": f"{scenario}.INI",
                "RA_CAPTURE_FPS": os.environ.get("RA_CAPTURE_FPS", "60"),
                "RA_CAPTURE_SEQUENCE_DIR": str(bmp_dir),
                "RA_CAPTURE_SEQUENCE_START": str(max(start, 1)),
                "RA_CAPTURE_SEQUENCE_COUNT": str(max(count, 1)),
                "RA_CAPTURE_SEQUENCE_READY_FILE": str(ready_path),
            }
            ra_proc = subprocess.Popen(
                [str(self.ra_bin)],
                env=env,
                cwd=str(staged_data_dir),
                stdout=logfile,
                stderr=logfile,
            )
            center_mouse(disp, 640, 400)
            fps = int(env["RA_CAPTURE_FPS"])
            final_frame = max(start, 1) + max(count, 1) - 1
            deadline = time.time() + capture_timeout_seconds(final_frame, fps)
            while time.time() < deadline:
                if ready_path.exists():
                    break
                if ra_proc.poll() is not None:
                    raise RuntimeError(
                        f"native RA exited before sequence trap (rc={ra_proc.returncode})"
                    )
                time.sleep(0.05)
            else:
                raise RuntimeError(
                    "native RA never completed requested capture sequence"
                )

            for frame_id in range(max(start, 1), max(start, 1) + max(count, 1)):
                bmp_path = bmp_dir / f"frame_{frame_id:06d}.bmp"
                png_path = sequence_dir / f"frame_{frame_id:06d}.png"
                ok, reason = _convert_valid_internal_bmp(bmp_path, png_path)
                if not ok:
                    raise RuntimeError(
                        f"native sequence frame {frame_id} invalid: {reason}"
                    )
            return sequence_dir
        finally:
            teardown_display(disp, ra_proc, wm, xvfb)
            if staged_data_dir is not None:
                shutil.rmtree(staged_data_dir, ignore_errors=True)
