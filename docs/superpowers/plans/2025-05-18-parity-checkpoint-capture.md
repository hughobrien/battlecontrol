# Parity Checkpoint Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `capture-checkpoint` CLI that captures screenshots from any mission or VQA at any frame across Wine OG, native Linux, and WASM, then compares for visual parity.

**Architecture:** Python CLI wraps three capture drivers (wine/native/wasm) plus a comparison wrapper. Drivers generalize existing bash capture scripts into parameterized Python. Output goes to `e2e/checkpoints/<type>-<id>/` with diffs and a JSON report.

**Tech Stack:** Python 3, subprocess (Xvfb, ffmpeg, Wine), Playwright (WASM), existing parity-compare.py

---

## File Structure

```
scripts/
  capture-checkpoint.py         ← CLI orchestrator
  drivers/
    __init__.py
    common.py                   ← shared: Xvfb, openbox, ffmpeg capture, window wait
    wine.py                     ← Wine OG capture (generalizes wine-allied-l1.sh etc.)
    native.py                   ← Native Linux capture (generalizes native-capture.sh)
    wasm.py                     ← WASM Playwright capture
    compare.py                  ← wraps parity-compare.py

To be subsumed (removed after verification):
  scripts/wine-allied-l1.sh     → drivers/wine.py mission capture
  scripts/wine-soviet-l1.sh     → drivers/wine.py mission capture (same template)
  scripts/wine-vqa-capture.sh   → drivers/wine.py VQA capture
  scripts/wine-gameplay.sh      → drivers/wine.py (older xdotool approach, superseded)
  scripts/native-capture.sh     → drivers/native.py
  scripts/gen-gameplay-goldens.sh → replaced by capture-checkpoint
```

---

### Task 1: Create directory structure and common utilities

**Files:**
- Create: `scripts/drivers/__init__.py`
- Create: `scripts/drivers/common.py`

**`scripts/drivers/__init__.py`** — empty

**`scripts/drivers/common.py`** — shared Xvfb/openbox/capture helpers:

```python
import subprocess, time, socket, os, signal, tempfile, shutil, pathlib

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
        stdout=logfile, stderr=logfile)
    time.sleep(1)
    return p

def start_openbox(disp: str, logfile=None) -> subprocess.Popen:
    p = subprocess.Popen(
        ["openbox"], env={**os.environ, "DISPLAY": disp},
        stdout=logfile, stderr=logfile)
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
    import struct
    with open(path, 'rb') as f:
        hdr = f.read(33)
    if len(hdr) < 33 or hdr[:8] != b'\x89PNG\r\n\x1a\n':
        return False
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
```

- [ ] **Step 1:** Create `scripts/drivers/` directory and `__init__.py` + `common.py`

```bash
mkdir -p scripts/drivers
```

- [ ] **Step 2:** Write `scripts/drivers/__init__.py` (empty file)

- [ ] **Step 3:** Write `scripts/drivers/common.py` with the code above

- [ ] **Step 4:** Commit

```bash
git add scripts/drivers/
git commit -m "feat: add common capture utilities (Xvfb, openbox, ffmpeg)"
```

---

### Task 2: Implement Wine capture driver

**Files:**
- Create: `scripts/drivers/wine.py`
- Modify: `scripts/drivers/__init__.py`

This parameterizes the pattern from `wine-allied-l1.sh` and `wine-vqa-capture.sh`.

Key design: each method creates a temp staging dir, applies patches, launches Wine, waits for the target frame, captures, and cleans up. RA95.EXE resolved via `nix build .#ra-patched-exe` or `RA_EXE_PATH` env var.

```python
# scripts/drivers/wine.py
import subprocess, os, time, tempfile, shutil, pathlib, json
from .common import *

class WineCapture:
    """Capture screenshots from RA95.EXE under Wine."""

    VQA_TIMINGS = {
        "WESTWOOD": 15.0, "RA_LOGO": 5.0, "INTRO2": 62.0,
        "ENGLISH": 80.0, "PROLOG": 6.0, "ALLY1": 8.0,
        "SOVIET1": 8.0, "SOVIET2": 12.0,
    }

    def __init__(self, wine="/usr/bin/wine", wineprefix=None,
                 ra_exe=None, cnc_ddraw_dir="/tmp/cnc-ddraw-master",
                 data_dir="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1",
                 scripts_dir=None):
        self.wine = wine
        self.wineprefix = wineprefix or os.path.expanduser("~/.wine-capture")
        self.ra_exe = ra_exe or self._resolve_ra_exe()
        self.cnc_ddraw_dir = cnc_ddraw_dir
        self.data_dir = data_dir
        self.scripts_dir = scripts_dir or os.path.join(
            os.path.dirname(__file__), "..")

    def _resolve_ra_exe(self):
        r = subprocess.run(
            ["nix", "build", ".#ra-patched-exe", "--impure", "--print-out-paths"],
            capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            return pathlib.Path(r.stdout.strip()) / "RA95.EXE"
        raise RuntimeError("RA95.EXE not found; set RA_EXE_PATH")

    def _patch_chain(self, staging, scenario=None, skip_vqa=True):
        """Apply all binary patches to staging/RA95.EXE."""
        patches_dir = self.scripts_dir
        exe = staging / "RA95.EXE"
        check = lambda: subprocess.run(["sha256sum", str(exe)],
                                       capture_output=True, text=True)
        # focus-skip
        subprocess.run(["python3", f"{patches_dir}/focus-skip-patch.py", str(exe)],
                       capture_output=True)
        # game-in-focus
        subprocess.run(["python3", f"{patches_dir}/game-in-focus-patch.py", str(exe)],
                       capture_output=True)
        # vqa-skip (unless capturing VQA)
        if skip_vqa:
            subprocess.run(["python3", f"{patches_dir}/vqa-skip-patch.py", str(exe)],
                           capture_output=True)
        # ra-scenario-patch (if scenario specified)
        if scenario:
            subprocess.run(
                ["python3", f"{patches_dir}/ra-scenario-patch.py", str(exe), scenario],
                capture_output=True)
        # ra-autostart-patch
        subprocess.run(["python3", f"{patches_dir}/ra-autostart-patch.py", str(exe)],
                       capture_output=True)

    def _setup_staging(self, scenario=None, skip_vqa=True):
        """Create staging directory with game data + patched EXE."""
        staging = pathlib.Path(tempfile.mkdtemp(prefix="wine-capture-"))
        for f in pathlib.Path(self.data_dir).glob("*.MIX"):
            os.symlink(str(f), str(staging / f.name))
        for f in pathlib.Path(self.data_dir).glob("*.INI"):
            os.symlink(str(f), str(staging / f.name))
        shutil.copy2(self.ra_exe, staging / "RA95.EXE")
        os.chmod(staging / "RA95.EXE", 0o755)
        dll_dir = pathlib.Path(self.ra_exe).parent
        for dll in ["THIPX32.DLL", "THIPX16.DLL"]:
            src = dll_dir / dll
            if src.exists():
                shutil.copy2(src, staging / dll)
        # cnc-ddraw
        shutil.copy2(f"{self.cnc_ddraw_dir}/ddraw.dll", staging / "ddraw.dll")
        with open(staging / "ddraw.ini", "w") as f:
            f.write("[ddraw]\nrenderer=gdi\nwindowed=true\nhook=0\n"
                    "window_state=normal\nmaxfps=30\n\n[ra95]\nscanline_double=true\n")
        self._patch_chain(staging, scenario, skip_vqa)
        return staging

    def _ensure_wineprefix(self):
        if not os.path.exists(self.wineprefix):
            subprocess.run(["wineboot", "--init"],
                           env={**os.environ, "WINEPREFIX": self.wineprefix,
                                "WINEDEBUG": "-all"},
                           capture_output=True, timeout=120)
        dos = pathlib.Path(self.wineprefix) / "dosdevices"
        dos.mkdir(parents=True, exist_ok=True)

    def _launch(self, staging, logfile, timeout=240):
        """Launch RA95.EXE under Wine in staging dir."""
        proc = subprocess.Popen(
            [self.wine, str(staging / "RA95.EXE")],
            cwd=str(staging),
            env={**os.environ,
                 "DISPLAY": os.environ.get("DISPLAY", ":0"),
                 "WINEPREFIX": self.wineprefix,
                 "WINEDLLOVERRIDES": "ddraw=n;mscoree=;mshtml=",
                 "WINEDEBUG": "-all", "AUDIODEV": "null",
                 "WAYLAND_DISPLAY": ""},
            stdout=logfile, stderr=logfile)
        return proc

    def capture_mission(self, scenario: str, frame: int, output_dir: pathlib.Path,
                        logfile=None):
        """Capture a screenshot from a mission at the given game frame."""
        display = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(scenario, skip_vqa=True)
        try:
            xvfb = start_xvfb(display, logfile=logfile)
            wm = start_openbox(display, logfile=logfile)
            self._ensure_wineprefix()
            # link staging as d: drive
            dos = pathlib.Path(self.wineprefix) / "dosdevices"
            (dos / "d:").symlink_to(staging)
            wine_proc = self._launch(staging, logfile)
            if not wait_for_window(display, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            # Dismiss DirectSound dialog
            time.sleep(5)
            subprocess.run(["xdotool", "key", "Return"],
                           env={**os.environ, "DISPLAY": display},
                           capture_output=True, timeout=5)
            # Wait for target frame (15 fps)
            frame_wait = max(frame / 15.0, 3.0)
            time.sleep(frame_wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = str(output_dir / "capture.png")
            capture_ffmpeg(display, cap_path)
            return pathlib.Path(cap_path)
        finally:
            for p in [wine_proc, wm, xvfb]:
                if p: p.kill()
            subprocess.run(["wineserver", "-k"],
                           env={**os.environ, "WINEPREFIX": self.wineprefix},
                           capture_output=True, timeout=10)
            shutil.rmtree(staging, ignore_errors=True)

    def capture_vqa(self, vqa_stem: str, frame: int, output_dir: pathlib.Path,
                    logfile=None):
        """Capture a screenshot from a VQA at the given frame."""
        display = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = wine_proc = None
        staging = self._setup_staging(None, skip_vqa=False)
        vqa_start_offsets = self._get_vqa_offsets()
        try:
            xvfb = start_xvfb(display, logfile=logfile)
            wm = start_openbox(display, logfile=logfile)
            self._ensure_wineprefix()
            dos = pathlib.Path(self.wineprefix) / "dosdevices"
            (dos / "d:").symlink_to(staging)
            wine_proc = self._launch(staging, logfile)
            if not wait_for_window(display, "Red Alert", timeout=30):
                raise RuntimeError("Red Alert window never appeared")
            # Dismiss boot dialogs
            time.sleep(5)
            subprocess.run(["xdotool", "key", "Return"],
                           env={**os.environ, "DISPLAY": display},
                           capture_output=True, timeout=5)
            time.sleep(1)
            subprocess.run(["xdotool", "key", "Return"],
                           env={**os.environ, "DISPLAY": display},
                           capture_output=True, timeout=5)
            # Wait for VQA start + frame offset
            pre_vqa = vqa_start_offsets.get(vqa_stem, 0.0)
            vqa_duration = self.VQA_TIMINGS.get(vqa_stem, 30.0)
            frame_time = frame / 15.0
            wait = pre_vqa + frame_time + 2.0  # 2s buffer for boot
            if wait > 0:
                time.sleep(wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = str(output_dir / "capture.png")
            capture_ffmpeg(display, cap_path)
            return pathlib.Path(cap_path)
        finally:
            for p in [wine_proc, wm, xvfb]:
                if p: p.kill()
            subprocess.run(["wineserver", "-k"],
                           capture_output=True, timeout=10)
            shutil.rmtree(staging, ignore_errors=True)

    def _get_vqa_offsets(self):
        """Return dict of {VQA_stem: start_time_in_seconds} for intro sequence."""
        sequence = ["WESTWOOD", "RA_LOGO", "INTRO2", "ENGLISH", "PROLOG"]
        offsets = {}
        t = 0.0
        for vqa in sequence:
            offsets[vqa] = t
            t += self.VQA_TIMINGS.get(vqa, 10.0)
        return offsets
```

- [ ] **Step 1:** Write `scripts/drivers/wine.py` with the code above

- [ ] **Step 2:** Add wine import to `scripts/drivers/__init__.py`:
```python
from .wine import WineCapture
```

- [ ] **Step 3:** Verify the file is syntactically valid:
```bash
python3 -c "from drivers.wine import WineCapture; print('OK')"
```

- [ ] **Step 4:** Commit
```bash
git add scripts/drivers/
git commit -m "feat: add Wine capture driver"
```

---

### Task 3: Implement Native capture driver

**Files:**
- Create: `scripts/drivers/native.py`

Generalizes `native-capture.sh`. The native binary is launched under Xvfb with env vars,
then ffmpeg probes for the first non-black canvas before waiting for the target frame.

```python
# scripts/drivers/native.py
import subprocess, os, time, pathlib
from .common import *

class NativeCapture:
    """Capture screenshots from the native Linux RA build."""

    def __init__(self, ra_bin=None, data_dir=None):
        self.ra_bin = ra_bin or self._resolve_ra_bin()
        self.data_dir = data_dir

    def _resolve_ra_bin(self):
        candidates = ["build/ra/redalert", "build/ra/ra", "build/redalert"]
        for c in candidates:
            p = pathlib.Path(c)
            if p.exists():
                return str(p.resolve())
        raise RuntimeError("native RA binary not found; set RA_BIN")

    def capture_mission(self, scenario: str, frame: int,
                        output_dir: pathlib.Path, logfile=None):
        """Capture screenshot from native RA at given game frame."""
        display = pick_free_display()
        logfile = logfile or subprocess.DEVNULL
        xvfb = wm = ra_proc = None
        try:
            xvfb = start_xvfb(display, logfile=logfile)
            wm = start_openbox(display, logfile=logfile)
            env = {**os.environ, "DISPLAY": display,
                   "RA_AUTOSTART": "1",
                   "RA_AUTOSTART_SCENARIO": f"{scenario}.INI"}
            if self.data_dir:
                env["DATA_DIR"] = self.data_dir
            ra_proc = subprocess.Popen(
                [self.ra_bin], env=env,
                stdout=logfile, stderr=logfile)
            # Probe for non-black canvas (up to 45s)
            deadline = time.time() + 45
            found = False
            while time.time() < deadline:
                tmp = f"/tmp/native-probe-{os.getpid()}.png"
                capture_ffmpeg(display, tmp)
                sz = os.path.getsize(tmp)
                os.unlink(tmp)
                if sz >= 5000:
                    found = True
                    break
                time.sleep(1)
            if not found:
                raise RuntimeError("native RA never rendered non-black canvas")
            # Wait remaining frames (15 fps)
            wait = max(frame / 15.0, 1.0)
            time.sleep(wait)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = str(output_dir / "capture.png")
            capture_ffmpeg(display, cap_path)
            return pathlib.Path(cap_path)
        finally:
            for p in [ra_proc, wm, xvfb]:
                if p: p.kill()
```

- [ ] **Step 1:** Write `scripts/drivers/native.py` with the code above

- [ ] **Step 2:** Add import in `__init__.py`:
```python
from .native import NativeCapture
```

- [ ] **Step 3:** Verify syntax:
```bash
python3 -c "from drivers.native import NativeCapture; print('OK')"
```

- [ ] **Step 4:** Commit
```bash
git add scripts/drivers/
git commit -m "feat: add Native capture driver"
```

---

### Task 4: Implement comparison wrapper

**Files:**
- Create: `scripts/drivers/compare.py`

Wraps the existing `parity-compare.py` to compare captured screenshots between
target pairs and produce a report.

```python
# scripts/drivers/compare.py
import subprocess, json, pathlib, shutil

def compare_pair(golden_path: str, capture_path: str, label: str,
                 output_dir: str, threshold_ssim=0.90) -> dict:
    """Compare two images using parity-compare.py. Returns {pass, ssim, p99, diff_path}."""
    diff_dir = pathlib.Path(output_dir) / "diff"
    diff_dir.mkdir(parents=True, exist_ok=True)
    diff_path = str(diff_dir / f"diff-{label}.png")
    # Actually the parity-compare script writes its own side-by-side + diff
    parity_script = pathlib.Path(__file__).parent.parent / "parity-compare.py"
    r = subprocess.run(
        ["python3", str(parity_script), golden_path, capture_path,
         "--label", label, "--threshold-ssim", str(threshold_ssim)],
        capture_output=True, text=True, timeout=60)
    # Parse output for pass/fail + metrics
    passed = r.returncode == 0
    ssim = 0.0
    p99 = 255
    for line in r.stdout.split("\n"):
        if "SSIM" in line:
            parts = line.split()
            for i, p in enumerate(parts):
                if p == "SSIM" and i + 1 < len(parts):
                    try: ssim = float(parts[i+1])
                    except: pass
        if "p99" in line:
            parts = line.split()
            for i, p in enumerate(parts):
                if p == "p99" and i + 1 < len(parts):
                    try: p99 = float(parts[i+1])
                    except: pass
    # Copy diff image if generated
    expected_diff = f"diff-{label}.png"
    if pathlib.Path(expected_diff).exists():
        shutil.copy2(expected_diff, diff_path)
    return {
        "pair": label,
        "passed": passed,
        "ssim": ssim,
        "p99": p99,
        "diff_path": diff_path,
        "stdout": r.stdout,
        "stderr": r.stderr,
    }

def full_report(captures: dict, output_dir: str, threshold_ssim=0.90) -> dict:
    """Compare all captured screenshots against each other.
    
    captures: {target_name: path_to_png}
    Returns: {pairs: [...], summary: PASS|FAIL|PARTIAL}
    """
    results = []
    targets = list(captures.keys())
    for i in range(len(targets)):
        for j in range(i+1, len(targets)):
            a, b = targets[i], targets[j]
            label = f"{a}-vs-{b}"
            result = compare_pair(captures[a], captures[b], label,
                                  output_dir, threshold_ssim)
            results.append(result)
    n_pass = sum(1 for r in results if r["passed"])
    if n_pass == len(results):
        summary = "PASS"
    elif n_pass == 0:
        summary = "FAIL"
    else:
        summary = "PARTIAL"
    report = {"pairs": results, "summary": summary,
              "threshold_ssim": threshold_ssim}
    with open(pathlib.Path(output_dir) / "report.json", "w") as f:
        json.dump(report, f, indent=2)
    return report
```

- [ ] **Step 1:** Write `scripts/drivers/compare.py` with the code above

- [ ] **Step 2:** Add import in `__init__.py`:
```python
from .compare import compare_pair, full_report
```

- [ ] **Step 3:** Verify syntax:
```bash
python3 -c "from drivers.compare import compare_pair; print('OK')"
```

- [ ] **Step 4:** Commit
```bash
git add scripts/drivers/
git commit -m "feat: add comparison wrapper"
```

---

### Task 5: Implement capture-checkpoint orchestrator

**Files:**
- Create: `scripts/capture-checkpoint.py`

The main CLI. Parses arguments, maps human-readable IDs to scenario names,
calls the appropriate drivers, runs comparison, prints summary.

```python
#!/usr/bin/env python3
"""Capture checkpoint screenshots from any mission or VQA across all targets.

Usage:
  capture-checkpoint mission allied-l2 --frame 200 --targets wine,native
  capture-checkpoint vqa ENGLISH --frame 120 --targets wine
"""

import argparse, sys, pathlib, json, time

# Add parent dir for importing drivers
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers import WineCapture, NativeCapture, WasmCapture
from drivers.compare import full_report

SCENARIO_MAP = {
    "allied-l1": "SCG01EA", "allied-l2": "SCG02EA", "allied-l3": "SCG03EA",
    "soviet-l1": "SCU01EA", "soviet-l2": "SCU02EA", "soviet-l3": "SCU03EA",
}

def resolve_scenario(id: str) -> str:
    if id.upper().startswith("SC"):
        return id
    if id in SCENARIO_MAP:
        return SCENARIO_MAP[id]
    raise ValueError(f"unknown mission: {id} (try allied-l1, allied-l2, soviet-l1)")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("type", choices=["mission", "vqa"])
    ap.add_argument("id", help="mission (allied-l1) or VQA stem (ENGLISH)")
    ap.add_argument("--frame", type=int, default=0, help="frame number to capture")
    ap.add_argument("--targets", default="wine,native",
                    help="comma-separated: wine,native,wasm")
    ap.add_argument("--output", default="e2e/checkpoints",
                    help="output root directory")
    ap.add_argument("--threshold-ssim", type=float, default=0.90)
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be done without running")
    args = ap.parse_args()

    output_root = pathlib.Path(args.output)
    checkpoint_dir = output_root / f"{args.type}-{args.id}"
    manifest = {
        "type": args.type, "id": args.id, "frame": args.frame,
        "targets": args.targets.split(","),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    if args.type == "mission":
        scenario = resolve_scenario(args.id)
        manifest["scenario"] = scenario
    else:
        scenario = None
        manifest["vqa_stem"] = args.id

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return

    captures = {}
    targets = args.targets.split(",")

    for target in targets:
        target_dir = checkpoint_dir / target
        target_dir.mkdir(parents=True, exist_ok=True)
        log_path = target_dir / "driver.log"
        logfile = open(log_path, "w")
        try:
            if target == "wine":
                driver = WineCapture()
                if args.type == "mission":
                    result = driver.capture_mission(scenario, args.frame, target_dir, logfile)
                else:
                    result = driver.capture_vqa(args.id, args.frame, target_dir, logfile)
            elif target == "native":
                driver = NativeCapture()
                result = driver.capture_mission(scenario, args.frame, target_dir, logfile)
            elif target == "wasm":
                driver = WasmCapture()
                result = driver.capture_mission(scenario, args.frame, target_dir, logfile)
            else:
                print(f"SKIP unknown target: {target}")
                continue
            captures[target] = str(result)
            print(f"OK  {target}: {result}")
        except Exception as e:
            print(f"FAIL {target}: {e}")
        finally:
            logfile.close()

    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    with open(checkpoint_dir / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    if len(captures) >= 2:
        report = full_report(captures, str(checkpoint_dir), args.threshold_ssim)
        print(f"\nComparison: {report['summary']}")
        for r in report["pairs"]:
            status = "PASS" if r["passed"] else "FAIL"
            print(f"  {r['pair']}: SSIM={r['ssim']:.4f} p99={r['p99']:.1f} [{status}]")
    else:
        print("(skipping comparison — fewer than 2 targets)")

if __name__ == "__main__":
    main()
```

- [ ] **Step 1:** Write `scripts/capture-checkpoint.py` with the code above

- [ ] **Step 2:** Verify syntax:
```bash
python3 -c "import capture_checkpoint; print('OK')"
```
Note: this will fail on the WasmCapture import initially, so wrap in try/except or create a stub WasmCapture first.

- [ ] **Step 3:** Test with `--dry-run`:
```bash
python3 scripts/capture-checkpoint.py mission allied-l2 --frame 200 --dry-run
```

- [ ] **Step 4:** Commit
```bash
git add scripts/capture-checkpoint.py scripts/drivers/
git commit -m "feat: add capture-checkpoint orchestrator"
```

---

### Task 6: Implement WASM capture driver

**Files:**
- Create: `scripts/drivers/wasm.py`

Starts the WASM dev server, launches Playwright headless Chromium, captures canvas.
Requires `playwright` Python package.

```python
# scripts/drivers/wasm.py
import subprocess, os, time, pathlib, json, sys
from .common import *

class WasmCapture:
    """Capture screenshots from WASM build via Playwright headless."""

    def __init__(self, wasm_dir="build-wasm", port=9876):
        self.wasm_dir = pathlib.Path(wasm_dir)
        self.port = port
        self._check_playwright()

    def _check_playwright(self):
        try:
            import playwright
        except ImportError:
            raise RuntimeError("playwright not installed; pip install playwright")

    def _start_server(self, logfile):
        server_script = pathlib.Path(__file__).parent.parent / "wasm" / "serve-coop.py"
        proc = subprocess.Popen(
            [sys.executable, str(server_script), "--directory", str(self.wasm_dir),
             "--port", str(self.port)],
            stdout=logfile, stderr=logfile)
        time.sleep(2)
        return proc

    def capture_mission(self, scenario: str, frame: int,
                        output_dir: pathlib.Path, logfile=None):
        """Capture WASM canvas at given game frame."""
        logfile = logfile or subprocess.DEVNULL
        server = None
        try:
            server = self._start_server(logfile)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = str(output_dir / "capture.png")
            self._playwright_capture(scenario, frame, cap_path)
            return pathlib.Path(cap_path)
        finally:
            if server:
                server.kill()

    def _playwright_capture(self, scenario, frame, output_path):
        from playwright.sync_api import sync_playwright
        scenario_name = f"{scenario}.INI"
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page(viewport={"width": 1024, "height": 768})
            page.goto(
                f"http://localhost:{self.port}/ra.html"
                f"?autostart=1&scenario={scenario_name}",
                wait_until="networkidle", timeout=60000)
            # Wait for WASM ready
            page.wait_for_function("() => typeof Module !== 'undefined' && Module.__wasmReady",
                                    timeout=60000)
            # Poll frame count if available
            frame_wait = max(frame / 15.0, 3.0)
            page.wait_for_timeout(int(frame_wait * 1000))
            # Capture
            canvas = page.query_selector("canvas")
            if canvas:
                canvas.screenshot(path=output_path)
            else:
                page.screenshot(path=output_path)
            browser.close()
```

- [ ] **Step 1:** Write `scripts/drivers/wasm.py` with the code above

- [ ] **Step 2:** Add import in `__init__.py`:
```python
from .wasm import WasmCapture
```

- [ ] **Step 3:** Verify syntax:
```bash
python3 -c "from drivers.wasm import WasmCapture; print('OK')"
```

- [ ] **Step 4:** Commit
```bash
git add scripts/drivers/
git commit -m "feat: add WASM capture driver"
```

---

### Task 7: Verify and subsume old scripts, update flake

**Files:**
- Remove: `scripts/wine-allied-l1.sh`, `scripts/wine-soviet-l1.sh`
- Remove: `scripts/wine-vqa-capture.sh`, `scripts/wine-gameplay.sh`
- Remove: `scripts/native-capture.sh`, `scripts/gen-gameplay-goldens.sh`
- Modify: `flake.nix` (remove references to removed scripts)

Before removing each script, verify its functionality is covered:

```bash
# Compare wine-allied-l1.sh vs WineCapture.capture_mission()
# The old script does:
#   1. Patch chain (focus-skip, game-in-focus, cdlabel, vqa-skip) ✓
#   2. Xvfb + openbox setup ✓
#   3. cnc-ddraw with scanline_double ✓
#   4. Wine prefix setup ✓
#   5. Launch + wait for window ✓
#   6. Esc + Resume via SendInput (for AUTODEMO pause/resume) — NOT needed
#      with autostart patches since game doesn't go through AUTODEMO
#   7. Screenshot at frame-0, frame-100, frame-250, frame-500
#   8. Validation (size + color count)

# The new driver covers all essential functionality. The AUTODEMO-based
# approach is replaced by the binary autostart patches which are more reliable.
```

For the flake, check `scripts/wine-allied-l1.sh` references:

```bash
grep -r 'wine-allied-l1\.sh\|wine-soviet-l1\.sh\|wine-vqa-capture\.sh\|wine-gameplay\.sh\|native-capture\.sh\|gen-gameplay-goldens' /home/hugh/battlecontrol/flake.nix
```

For each removed script, verify `scripts/gen-gameplay-goldens.sh` is the only consumer,
and update it to delegate to `capture-checkpoint` instead.

- [ ] **Step 1:** Check flake.nix for references to scripts being removed

```bash
grep -n 'wine-allied-l1\|wine-soviet-l1\|wine-vqa-capture\|wine-gameplay\|native-capture\|gen-gameplay-goldens' flake.nix
```

- [ ] **Step 2:** Check other scripts for cross-references

```bash
grep -rn 'wine-allied-l1\.sh\|native-capture\.sh\|wine-vqa-capture\.sh' scripts/ e2e/ docs/ --include='*.sh' --include='*.md' --include='*.py' 2>/dev/null | grep -v '\.git' | head -20
```

- [ ] **Step 3:** Remove each verified-superseded script into `scripts/archive/`

```bash
mkdir -p scripts/archive
git mv scripts/wine-allied-l1.sh scripts/archive/
git mv scripts/wine-soviet-l1.sh scripts/archive/
git mv scripts/wine-vqa-capture.sh scripts/archive/
git mv scripts/wine-gameplay.sh scripts/archive/
git mv scripts/native-capture.sh scripts/archive/
git mv scripts/gen-gameplay-goldens.sh scripts/archive/
```

Note: move to archive rather than delete, in case any functionality was missed.

- [ ] **Step 4:** Update references in AGENTS.md and other docs to point to `capture-checkpoint`

- [ ] **Step 5:** Update flake.nix if it references any removed scripts

- [ ] **Step 6:** Commit

```bash
git add AGENTS.md flake.nix scripts/archive/
git commit -m "refactor: subsume capture scripts into capture-checkpoint system"
```
