import subprocess
import time
import os
import signal
from pathlib import Path


def pick_free_display() -> str:
    """Return ':92'..':98' that isn't in use."""
    for d in range(92, 99):
        disp = f":{d}"
        if os.path.exists(f"/tmp/.X{d}-lock") or os.path.exists(f"/tmp/.X11-unix/X{d}"):
            continue
        r = subprocess.run(
            ["xdpyinfo", "-display", disp],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
        if r.returncode != 0:
            return disp
    raise RuntimeError("no free X display")


def start_xvfb(
    disp: str, width: int, height: int, depth: int = 24, logfile=None
) -> subprocess.Popen:
    p = subprocess.Popen(
        ["Xvfb", disp, "-screen", "0", f"{width}x{height}x{depth}", "-ac"],
        stderr=logfile,
    )
    time.sleep(1)
    if p.poll() is not None:
        raise RuntimeError(f"Xvfb failed to start on {disp} (rc={p.returncode})")
    return p


def start_openbox(disp: str, logfile=None) -> subprocess.Popen:
    p = subprocess.Popen(
        ["openbox"], env={**os.environ, "DISPLAY": disp}, stderr=logfile
    )
    time.sleep(1)
    return p


def wait_for_window(disp: str, title: str, timeout=30) -> bool:
    """Poll xdotool until window appears or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            ["xdotool", "search", "--name", title],
            env={**os.environ, "DISPLAY": disp},
            capture_output=True,
            timeout=5,
        )
        if r.returncode == 0 and r.stdout.strip():
            return True
        time.sleep(1)
    return False


def center_mouse(disp: str, width: int, height: int):
    """Move the X pointer away from scroll edges before timed captures."""
    subprocess.run(
        ["xdotool", "mousemove", str(width // 2), str(height // 2)],
        env={**os.environ, "DISPLAY": disp},
        capture_output=True,
        timeout=5,
    )


def capture_root(disp: str, output_path: str):
    """Capture the X root window via ImageMagick `import`. Hard-fails on error.

    The output PNG dimensions match the X screen size — no video_size param
    needed. Use ImageMagick rather than ffmpeg x11grab because the headless
    ffmpeg build on this system lacks xcb/xlib support.
    """
    r = subprocess.run(
        ["import", "-window", "root", output_path],
        env={**os.environ, "DISPLAY": disp},
        capture_output=True,
        text=True,
        timeout=30,
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"`import -window root` failed (rc={r.returncode}): {r.stderr.strip()}"
        )
    if not os.path.exists(output_path) or os.path.getsize(output_path) == 0:
        raise RuntimeError(f"import produced no output at {output_path}")


def screenshot_ok(path: str) -> bool:
    """Return True if PNG is >=5KB and has >=64 unique colours."""
    sz = os.path.getsize(path)
    if sz < 5000:
        return False
    try:
        r = subprocess.run(
            ["identify", "-format", "%k", path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip().isdigit():
            return int(r.stdout.strip()) >= 64
    except Exception:
        pass
    return sz >= 5000


def tactical_nonblack_fraction(path: str) -> float:
    """Return non-black fraction in the RA tactical viewport.

    The top UI/sidebar can be populated while the gameplay viewport is still
    black during mission entry.  Parity captures should not accept that as a
    valid gameplay frame.
    """
    from PIL import Image

    im = Image.open(path).convert("RGB")
    crop = im.crop((0, 16, 480, 400))
    pixels = crop.getdata()
    total = 0
    nonblack = 0
    for pixel in pixels:
        total += 1
        if pixel != (0, 0, 0):
            nonblack += 1
    return nonblack / total if total else 0.0


def _pixel_fraction(im, box, predicate) -> float:
    crop = im.crop(box)
    pixels = list(crop.getdata())
    if not pixels:
        return 0.0
    return sum(1 for pixel in pixels if predicate(pixel)) / len(pixels)


def classify_ra_screen(path: str) -> dict:
    """Classify common RA capture failure screens with cheap pixel heuristics."""
    from PIL import Image

    im = Image.open(path).convert("RGB")
    width, height = im.size

    def is_green(pixel):
        red, green, blue = pixel
        return green > 100 and red < 90 and blue < 90

    def is_red(pixel):
        red, green, blue = pixel
        return red > 90 and green < 60 and blue < 60

    def is_gray(pixel):
        red, green, blue = pixel
        return abs(red - green) < 18 and abs(red - blue) < 18 and red > 80

    def is_black(pixel):
        red, green, blue = pixel
        return red < 12 and green < 12 and blue < 12

    tactical_fill = tactical_nonblack_fraction(path)
    top_green = _pixel_fraction(im, (235, 20, min(width, 405), 45), is_green)
    center_red = _pixel_fraction(im, (200, 170, min(width, 445), 315), is_red)
    dialog_gray = _pixel_fraction(im, (185, 135, min(width, 455), 295), is_gray)
    overall_black = _pixel_fraction(im, (0, 0, width, height), is_black)

    if top_green > 0.015 and overall_black > 0.70:
        state = "top-scores"
    elif dialog_gray > 0.08 and center_red > 0.05:
        state = "modal-dialog"
    elif center_red > 0.10:
        state = "main-menu"
    elif tactical_fill < 0.05:
        state = "blank"
    elif tactical_fill < 0.20:
        state = "not-gameplay"
    else:
        state = "gameplay"

    return {
        "state": state,
        "tactical_nonblack": round(tactical_fill, 6),
        "top_green": round(top_green, 6),
        "center_red": round(center_red, 6),
        "dialog_gray": round(dialog_gray, 6),
        "overall_black": round(overall_black, 6),
    }


def kill_process_tree(proc: subprocess.Popen):
    """Kill a process and its children."""
    if proc is None:
        return
    pid = proc.pid
    # Kill children first
    try:
        import subprocess as _sp

        _sp.run(["pkill", "-P", str(pid)], capture_output=True, timeout=5)
    except Exception:
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        proc.kill()
    except Exception:
        pass


_CACHE_DIR = os.path.expanduser("~/.cache/battlecontrol")
_SWEEP_PATTERNS = ("wine-prefix-*", "wine-capture-*")
_SWEEP_DISPLAY_RANGE = range(92, 99)
_WINE_AUDIO_CAPTURE = Path("/tmp/wine-audio.raw")


def _read_proc_environ(pid: int) -> dict[str, str]:
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return {}
    env = {}
    for item in raw.split(b"\0"):
        if b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        env[key.decode("latin1", "replace")] = value.decode("latin1", "replace")
    return env


def _kill_capture_orphans(verbose: bool = False) -> int:
    killed = 0
    displays = {f":{n}" for n in _SWEEP_DISPLAY_RANGE}
    for proc_dir in Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        pid = int(proc_dir.name)
        try:
            cmdline = proc_dir.joinpath("cmdline").read_bytes().replace(b"\0", b" ")
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        cmd = cmdline.decode("latin1", "replace")
        should_kill = False
        if any(f"Xvfb {display}" in cmd for display in displays):
            should_kill = True
        elif "openbox" in cmd:
            display = _read_proc_environ(pid).get("DISPLAY")
            should_kill = display in displays
        if not should_kill:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
            killed += 1
            if verbose:
                print(f"killed capture process: pid={pid} cmd={cmd.strip()}")
        except (ProcessLookupError, PermissionError, OSError):
            pass
    return killed


def sweep_state(verbose: bool = False) -> tuple[int, int, int]:
    """Remove leftover per-run capture state. Returns (dirs, locks, procs).

    Always safe to call at the end of a run: only nukes per-session
    artefacts (wine-prefix-*, wine-capture-*) and our X display range's
    lockfiles/sockets. The persistent build cache (ra-sendinput.exe) and
    other users' state are untouched.
    """
    import glob
    import shutil

    procs_killed = _kill_capture_orphans(verbose=verbose)

    try:
        _WINE_AUDIO_CAPTURE.unlink()
        if verbose:
            print(f"removed file: {_WINE_AUDIO_CAPTURE}")
    except FileNotFoundError:
        pass

    dirs_removed = 0
    for pat in _SWEEP_PATTERNS:
        for p in glob.glob(os.path.join(_CACHE_DIR, pat)):
            shutil.rmtree(p)
            if verbose:
                print(f"removed dir: {p}")
            dirs_removed += 1

    locks_removed = 0
    for n in _SWEEP_DISPLAY_RANGE:
        for path in (f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                continue
            if verbose:
                print(f"removed lock: {path}")
            locks_removed += 1

    return dirs_removed, locks_removed, procs_killed


def teardown_display(disp: str, *procs: subprocess.Popen):
    """Kill the given procs and remove X lockfile + socket for `disp`.

    Xvfb under SIGKILL does not clean up /tmp/.X{N}-lock or
    /tmp/.X11-unix/X{N}. Without explicit removal, the slot stays
    "occupied" from pick_free_display's perspective and accumulates
    across runs. Every capture session must call this in a finally
    block — no X display is allowed to outlive the script.
    """
    for p in procs:
        kill_process_tree(p)
    if not disp.startswith(":"):
        raise ValueError(f"expected display like ':92', got {disp!r}")
    n = disp[1:]
    if not n.isdigit():
        raise ValueError(f"expected numeric display, got {disp!r}")
    for path in (f"/tmp/.X{n}-lock", f"/tmp/.X11-unix/X{n}"):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
