# Wine Capture Driver Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `drivers/wine.py` to cover title/menu capture (matching `wine-ra.sh`), then add `title`/`menu` capture types to `capture-checkpoint.py`.

**Architecture:** Three independent changes to `wine.py` (ephemeral prefix, registry config + REDALERT.INI, new `capture_boot` method) plus one dispatch change in `capture-checkpoint.py`. Old `wine-ra.sh` kept for testing until verified.

**Tech Stack:** Python, Wine, Xvfb, xdotool, ffmpeg

---

### Task 1: Ephemeral Wine prefix in `drivers/wine.py`

**Files:**
- Modify: `scripts/drivers/wine.py`

- [ ] **Step 1: Change `_ensure_wineprefix` to use `tempfile.mkdtemp`**

Replace the persistent `~/.wine-checkpoint` prefix with an ephemeral temp directory. The prefix path is stored as `self.wineprefix` which is set in `__init__`. Rather than changing `__init__` (which takes `wineprefix` as a param), change `_ensure_wineprefix` to create a temp prefix when none was explicitly provided.

Current code (lines 68-70):
```python
self.wineprefix = pathlib.Path(
    wineprefix or os.path.expanduser("~/.wine-checkpoint")
)
```

Change to defer tempdir creation to `_ensure_wineprefix`:
```python
self.wineprefix = pathlib.Path(wineprefix) if wineprefix else None
```

In `_ensure_wineprefix`, add tempdir creation when `self.wineprefix` is None:
```python
def _ensure_wineprefix(self, staging: pathlib.Path):
    if self.wineprefix is None:
        self.wineprefix = pathlib.Path(tempfile.mkdtemp(prefix="wine-capture-"))
    if not self.wineprefix.exists():
        self.wineprefix.mkdir(parents=True)
        subprocess.run(...)  # existing wineboot --init call
    # ... rest of existing method
```

Also update `_cleanup` to remove the temp prefix when it was auto-created:
```python
if self.wineprefix and self.wineprefix.name.startswith("wine-capture-"):
    shutil.rmtree(self.wineprefix, ignore_errors=True)
```

- [ ] **Step 2: Verify the change doesn't break existing callers**

```bash
grep -rn "WineCapture" scripts/ --include="*.py"
```

Expected: only `capture-checkpoint.py` and `drivers/wine.py` itself. No other code constructs WineCapture with a custom wineprefix, so the default behavior change is safe.

- [ ] **Step 3: Commit**

```bash
git add scripts/drivers/wine.py
git commit -m "refactor: make Wine prefix ephemeral (tempdir instead of ~/.wine-checkpoint)"
```

---

### Task 2: Wine registry config + REDALERT.INI

**Files:**
- Modify: `scripts/drivers/wine.py`

- [ ] **Step 1: Add Wine registry config to `_ensure_wineprefix`**

Add reg key writes after `wineboot --init` in `_ensure_wineprefix`. These set the GDI renderer and virtual desktop, matching `wine-ra.sh`:

Current code after `wineboot --init` (line ~158-166):
```python
subprocess.run(
    [str(self.wine), "wineboot", "--init"],
    env={**os.environ, "WINEPREFIX": str(self.wineprefix), "WINEDEBUG": "-all"},
    capture_output=True,
    timeout=120,
)
```

Append after the `wineboot` block:
```python
# Configure GDI renderer + virtual desktop for headless Xvfb capture
subprocess.run(
    [str(self.wine), "reg", "add", r"HKCU\Software\Wine\Explorer\Desktops",
     "/v", "Default", "/t", "REG_SZ", "/d", "640x480", "/f"],
    env={**os.environ, "WINEPREFIX": str(self.wineprefix), "WINEDEBUG": "-all"},
    capture_output=True, timeout=30,
)
subprocess.run(
    [str(self.wine), "reg", "add", r"HKCU\Software\Wine\Direct3D",
     "/v", "DirectDrawRenderer", "/t", "REG_SZ", "/d", "gdi", "/f"],
    env={**os.environ, "WINEPREFIX": str(self.wineprefix), "WINEDEBUG": "-all"},
    capture_output=True, timeout=30,
)
```

- [ ] **Step 2: Write REDALERT.INI in `_setup_staging`**

Add REDALERT.INI writing after the ddraw.ini block (after line ~152 in the current file):

```python
(staging / "REDALERT.INI").write_text(
    "[Sound]\nCard=-1\n\n"
    "[Options]\nHardwareFills=no\n\n"
    "[Intro]\nPlayIntro=no\n"
)
```

- [ ] **Step 3: Commit**

```bash
git add scripts/drivers/wine.py
git commit -m "feat: add GDI renderer config and REDALERT.INI to Wine driver"
```

---

### Task 3: `capture_boot(mode)` method in `WineCapture`

**Files:**
- Modify: `scripts/drivers/wine.py`

- [ ] **Step 1: Add `capture_boot` method after `capture_vqa`**

Insert the new method before `_get_vqa_offsets` (the internal helper at the end of the class):

```python
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
        raise ValueError(f"unknown boot mode: {mode} (choose from {list(delays.keys())})")
    delay = delays[mode]
    disp = pick_free_display()
    logfile = logfile or subprocess.DEVNULL
    xvfb = wm = wine_proc = None
    staging = self._setup_staging(scenario=None, skip_vqa=True)
    try:
        xvfb = start_xvfb(disp, 640, 480, logfile=logfile)
        wm = start_openbox(disp, logfile=logfile)
        self._ensure_wineprefix(staging)
        wine_proc = self._launch(staging, logfile)
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
        # RA95 renders at 640x480
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-loglevel", "error",
                "-f", "x11grab", "-video_size", "640x480",
                "-i", disp, "-frames:v", "1", "-y", str(cap_path),
            ],
            capture_output=True,
            timeout=30,
        )
        return cap_path
    finally:
        self._cleanup(staging, wine_proc, xvfb, wm)
```

Note: This uses inline ffmpeg with 640x480 (not `capture_ffmpeg` from common.py which defaults to 1024x768). This avoids changing the shared helper's signature.

- [ ] **Step 2: Commit**

```bash
git add scripts/drivers/wine.py
git commit -m "feat: add capture_boot() method for title/menu screenshots"
```

---

### Task 4: Add title/menu types to `capture-checkpoint.py`

**Files:**
- Modify: `scripts/capture-checkpoint.py`

- [ ] **Step 1: Add `title`/`menu` to argparse choices**

Change the `type` argument from:
```python
ap.add_argument("type", choices=["mission", "vqa"], help="capture type")
```
To:
```python
ap.add_argument("type", choices=["mission", "vqa", "title", "menu"], help="capture type")
```

- [ ] **Step 2: Add dispatch logic before the existing mission/vqa branches**

After the `--targets` parsing and driver construction, add:
```python
if args.type in ("title", "menu"):
    driver = WineCapture(
        data_dir=args.data,
        wine=args.wine,
    )
    path = driver.capture_boot(args.type, output_dir)
    print(f"Captured {args.type}: {path}")
    return
```

This goes before the existing `if args.type == "mission"` / `elif args.type == "vqa"` branches, so it returns early for boot modes.

- [ ] **Step 3: Commit**

```bash
git add scripts/capture-checkpoint.py
git commit -m "feat: add title/menu capture types to capture-checkpoint.py"
```

---

### Task 5: Verify parity with `wine-ra.sh`

- [ ] **Step 1: Run old baseline**

```bash
bash scripts/ra/wine-ra.sh
```

Expected: produces `e2e/screenshots/wine-ra-title.png` and `e2e/screenshots/wine-ra-menu.png`.

- [ ] **Step 2: Run new capture**

```bash
python3 scripts/capture-checkpoint.py title --targets wine
python3 scripts/capture-checkpoint.py menu --targets wine
```

Expected: produces `title.png` and `menu.png` in the output directory.

- [ ] **Step 3: Visually compare outputs**

Check that both sets of screenshots show the same content (title screen / main menu) with comparable timing. The exact pixel output may differ slightly (ffmpeg x11grab vs ImageMagick import) but the game state should be equivalent.

---

### Task 6: Remove `wine-ra.sh` and update docs

- [ ] **Step 1: Remove `wine-ra.sh`**

```bash
git rm scripts/ra/wine-ra.sh
```

- [ ] **Step 2: Update documentation references**

Remove `wine-ra.sh` entries from:
- `scripts.md` — capture section (line 56) and alphabetical index (line 194)
- `AGENTS.md` — line 459 (`wine-ra.sh` / `wine-td.sh` table entry)
- `AGENT-FLOW.md` — line 87 (`wine-ra-setup.sh` reference in item 6)

- [ ] **Step 3: Commit**

```bash
git add scripts/ra/wine-ra.sh scripts.md AGENTS.md AGENT-FLOW.md
git commit -m "chore: remove wine-ra.sh (superseded by capture-checkpoint.py)"
```
