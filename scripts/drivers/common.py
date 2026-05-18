import subprocess, time, os, signal, pathlib, tempfile, shutil


def pick_free_display() -> str:
    """Return ':92'..':98' that isn't in use."""
    for d in range(92, 99):
        if not os.path.exists(f"/tmp/.X{d}-lock"):
            return f":{d}"
    raise RuntimeError("no free X display")


def start_xvfb(disp: str, width=1024, height=768, depth=24,
               logfile=None) -> subprocess.Popen:
    p = subprocess.Popen(
        ["Xvfb", disp, "-screen", "0", f"{width}x{height}x{depth}", "-ac"],
        stderr=logfile)
    time.sleep(1)
    return p


def start_openbox(disp: str, logfile=None) -> subprocess.Popen:
    p = subprocess.Popen(
        ["openbox"], env={**os.environ, "DISPLAY": disp},
        stderr=logfile)
    time.sleep(1)
    return p


def wait_for_window(disp: str, title: str, timeout=30) -> bool:
    """Poll xdotool until window appears or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            ["xdotool", "search", "--name", title],
            env={**os.environ, "DISPLAY": disp},
            capture_output=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return True
        time.sleep(1)
    return False


def capture_ffmpeg(disp: str, output_path: str, video_size="1024x768"):
    """Capture single frame via ffmpeg x11grab."""
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error",
         "-f", "x11grab", "-video_size", video_size,
         "-i", disp, "-frames:v", "1", "-y", output_path],
        capture_output=True, timeout=30)


def screenshot_ok(path: str) -> bool:
    """Return True if PNG is >=5KB and has >=64 unique colours."""
    sz = os.path.getsize(path)
    if sz < 5000:
        return False
    try:
        r = subprocess.run(["identify", "-format", "%k", path],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip().isdigit():
            return int(r.stdout.strip()) >= 64
    except Exception:
        pass
    return sz >= 5000


def kill_process_tree(proc: subprocess.Popen):
    """Kill a process and its children."""
    if proc is None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.kill()
    except Exception:
        pass
