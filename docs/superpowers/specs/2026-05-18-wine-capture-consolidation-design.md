# Wine Capture Driver Consolidation

Upgrade `drivers/wine.py` to cover all RA95 Wine capture scenarios currently handled by `wine-ra.sh`, and add `title`/`menu` capture types to `capture-checkpoint.py`.

## Motivation

`wine-ra.sh` (standalone bash, ~250 lines) handles Wine prefix setup, GDI registry config, REDALERT.INI, and title/menu screenshot capture. `drivers/wine.py` (Python, ~286 lines) handles mission and VQA frame capture but lacks these capabilities. Consolidating into the Python driver eliminates the duplication and makes the full Wine capture surface available through a single CLI.

## Scope

Existing files only — no new capabilities beyond what `wine-ra.sh` provides. The behavioral contract of `mission` and `vqa` capture types does not change.

## Changes to `drivers/wine.py`

### Ephemeral prefix

`_ensure_wineprefix` currently uses `~/.wine-checkpoint` (persistent). Change to `tempfile.mkdtemp(prefix="wine-capture-")` so each run gets a fresh prefix. The cleanup already handles prefix removal via `shutil.rmtree`.

### Wine registry + game config

In `_setup_staging` or a new `_configure_wine` method, add:
- `HKCU\Software\Wine\Explorer\Desktops` → `Default=640x480`
- `HKCU\Software\Wine\Direct3D` → `DirectDrawRenderer=gdi`
- Write `REDALERT.INI` with `[Sound] Card=-1`, `[Options] HardwareFills=no`, `[Intro] PlayIntro=no`

These are the gaps identified between `wine.py` and `wine-ra.sh`.

### `capture_boot(mode)` method

New method on `WineCapture`:

```python
def capture_boot(self, mode: str, output_dir: pathlib.Path, logfile=None) -> pathlib.Path:
    """Capture title or menu screenshot from a vanilla RA95 boot.
    
    Args:
        mode: "title" (10s delay) or "menu" (22s delay)
        output_dir: where to save the PNG
        
    Returns:
        Path to captured screenshot
    """
    delays = {"title": 10.0, "menu": 22.0}
    delay = delays[mode]
    disp = pick_free_display()
    logfile = logfile or subprocess.DEVNULL
    xvfb = wm = wine_proc = None
    staging = self._setup_staging(scenario=None, skip_vqa=True)
    try:
        xvfb = start_xvfb(disp, logfile=logfile)
        wm = start_openbox(disp, logfile=logfile)
        self._ensure_wineprefix(staging)
        wine_proc = self._launch(staging, logfile)
        # Dismiss DirectSound dialog
        time.sleep(5)
        subprocess.run(
            ["xdotool", "key", "Return"],
            env={**os.environ, "DISPLAY": disp},
            capture_output=True,
            timeout=5,
        )
        time.sleep(delay - 5)
        output_dir.mkdir(parents=True, exist_ok=True)
        cap_path = output_dir / f"{mode}.png"
        capture_ffmpeg(disp, str(cap_path))
        return cap_path
    finally:
        self._cleanup(staging, wine_proc, xvfb, wm)
```

**Note on screen geometry:** Xvfb and ffmpeg capture must use 640×480 (RA95's native resolution), not the 1024×768 default in `common.py`. The existing `start_xvfb(disp, 640, 480)` call in capture_mission already handles this; `capture_boot` must do the same, and ffmpeg must use `-video_size 640x480`.

Key differences from `capture_mission`:
- No scenario patching (`scenario=None` → skips ra-scenario-patch.py and ra-autostart-patch.py)
- Fixed delay based on mode (not frame-based)
- No `wait_for_window` (title appears reliably after dialog dismiss)

## Changes to `capture-checkpoint.py`

Add two new capture type options to the argument parser:

```
capture-checkpoint title [--targets TARGETS] [--out DIR]
capture-checkpoint menu  [--targets TARGETS] [--out DIR]
```

Dispatch internally:

```python
if args.type == "title":
    driver = WineCapture(...)
    path = driver.capture_boot("title", output_dir)
elif args.type == "menu":
    driver = WineCapture(...)
    path = driver.capture_boot("menu", output_dir)
```

The `mission` and `vqa` paths remain unchanged.

## Testing

Keep `wine-ra.sh` on disk throughout. Compare outputs:

```bash
# Old baseline
bash scripts/ra/wine-ra.sh

# New
python3 scripts/capture-checkpoint.py title --targets wine
python3 scripts/capture-checkpoint.py menu --targets wine
```

Screenshots should be visually equivalent (same content, similar timing). Once verified, remove `wine-ra.sh`.

## Files

| File | Change |
|------|--------|
| `scripts/drivers/wine.py` | Add ephemeral prefix, registry config, REDALERT.INI, `capture_boot()` |
| `scripts/capture-checkpoint.py` | Add `title`/`menu` capture types |
| `scripts/ra/wine-ra.sh` | Keep during testing, remove after verification |
| `scripts.md` | Remove `wine-ra.sh` references after removal |
| `AGENTS.md`, `AGENT-FLOW.md` | Remove `wine-ra.sh` references after removal |
