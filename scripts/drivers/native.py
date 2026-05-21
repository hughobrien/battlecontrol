"""Native capture driver — capture screenshots from native Linux RA build."""

import subprocess
import os
import shutil
import sys
import time
import pathlib
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
    bmp_path: pathlib.Path, png_path: pathlib.Path
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

    return _validate_capture_image(png_path)


class NativeCapture:
    """Capture screenshots from the native Linux RA build."""

    def __init__(self, ra_bin=None, data_dir=None):
        ra_bin = ra_bin or os.environ.get("RA_BIN") or "build/ra/redalert"
        if not ra_bin:
            raise RuntimeError("RA_BIN not set; export RA_BIN=/abs/path/to/ra")
        self.ra_bin = pathlib.Path(ra_bin)
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
