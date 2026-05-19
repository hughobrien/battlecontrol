import subprocess
import time
import os
import signal


def pick_free_display() -> str:
    """Return ':92'..':98' that isn't in use."""
    for d in range(92, 99):
        if not os.path.exists(f"/tmp/.X{d}-lock"):
            return f":{d}"
    raise RuntimeError("no free X display")


def start_xvfb(
    disp: str, width: int, height: int, depth: int = 24, logfile=None
) -> subprocess.Popen:
    p = subprocess.Popen(
        ["Xvfb", disp, "-screen", "0", f"{width}x{height}x{depth}", "-ac"],
        stderr=logfile,
    )
    time.sleep(1)
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


def sweep_state(verbose: bool = False) -> tuple[int, int]:
    """Remove leftover per-run capture state. Returns (dirs, locks) counts.

    Always safe to call at the end of a run: only nukes per-session
    artefacts (wine-prefix-*, wine-capture-*) and our X display range's
    lockfiles/sockets. The persistent build cache (ra-sendinput.exe) and
    other users' state are untouched.
    """
    import glob
    import shutil

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

    return dirs_removed, locks_removed


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
