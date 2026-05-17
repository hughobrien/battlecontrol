---
name: wine-testing
description: Use when running original Win32 C&C Red Alert (RA95.EXE) or Tiberian Dawn (C&C95.EXE) under Wine for baseline comparison against native/WASM ports. Trigger on symptoms like Wine prefix failures, DirectDraw rendering blank, DirectSound dialog blocking automation, xdotool timing races, screenshot capture returning blank images, or CI Wine job skipping unexpectedly.
version: 0.2.0
---

# Wine Testing Skill

> **Extension tools:** `wine_check`, `wine_capture`.  **Nix app:** `nix run .#capture-wine`.

You are running the original Win32 C&C Red Alert or Tiberian Dawn executable under Wine
for baseline comparison against the native Linux and WASM ports. The workflow captures
screenshots in a headless Xvfb environment for automated pixel-level parity validation.

---

## Phase 0 — Check prerequisites

```bash
bash scripts/skill-wine-check.sh
```

One-command gate. Exits 0 if wine, wine32, xvfb-run, xdotool, ffmpeg, and
imagemagick are all present. Exits 1 with a list of what's missing.

---

## Phase 1 — Classify the symptom

| Symptom | Lens | Go to |
|---|---|---|
| `wine32 is missing` from `wine --version` | 32-bit Wine architecture not installed | §2.1 |
| Wine prefix creation fails or hangs | Corrupt or missing 32-bit prefix | §2.1 |
| DirectSound warning dialog blocks automation | Dialog must be dismissed with xdotool | §2.2 |
| Screenshot is blank (0 bytes or 1-bit PNG) | Capture method mismatch | §2.3 |
| DirectDraw surface renders black on Xvfb | GDI renderer not configured | §2.4 |
| Game exits immediately with no output | Missing DLLs or wrong EXE path | §2.5 |
| `wine-ra.sh` / `wine-td.sh` exit 2 (SKIP) | EXE or data not found — first-time setup needed | §3 |

---

## §2.1 — Wine 32-bit setup

RA95.EXE and C&C95.EXE are 32-bit Windows executables. They require `wine32:i386`.

```bash
# On Debian/Ubuntu:
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install wine32:i386

# Verify:
wine --version 2>&1 | grep -v "wine32 is missing"
```

**Prefix creation:** The scripts create a 32-bit Wine prefix automatically on first run:
```bash
WINEPREFIX="$HOME/.wine-ra" WINEARCH=win32 WINEDEBUG=-all wineboot --init
```

**Corrupted prefix recovery:** If the game launches but screenshots are blank,
garbled, or the prefix creation hangs:

```bash
# Inspect current prefix state
WINEPREFIX="$HOME/.wine-ra" winecfg    # check DLL overrides
WINEPREFIX="$HOME/.wine-ra" wine reg query 'HKCU\Software\Wine\Direct3D'  # check renderer

# If corrupt: delete and recreate
rm -rf "$HOME/.wine-ra"
WINEPREFIX="$HOME/.wine-ra" WINEARCH=win32 WINEDEBUG=-all wineboot --init
```

**CI note:** CI runners use a fresh prefix per job (ephemeral), so corruption
is rarely an issue in CI. Local prefixes accumulate state across runs.

---

## §2.2 — DirectSound dialog dismissal

Both RA and TD show a "Warning - Unable to create Direct Sound Object" dialog on startup
when no physical audio card is present. This must be dismissed for the game to proceed.

The scripts handle this with xdotool:
```bash
# Wait for dialog to appear (~7s after launch), then dismiss
sleep 7
DISPLAY=:98 xdotool key Return
sleep 1
DISPLAY=:98 xdotool key Return   # Double-tap for safety
```

**Timing:** On slower CI runners, the dialog may appear later. If the dismiss fires
before the dialog exists, the game proceeds past the title screen without capturing
the menu screenshot. Increase the initial sleep to 9s if menu screenshot is missing.

**Audio silencing:** The scripts set `AUDIODEV=null` and `WINEDLLOVERRIDES` to suppress
ALSA/OSS audio driver errors that fill stderr. These are expected and not game failures.

---

## §2.3 — Screenshot capture method

**Red Alert (RA):** Uses `import -window root` (ImageMagick). Works because RA renders
at 640x480x24 and Wine's windowed DirectDraw path captures cleanly under Xvfb.

```bash
DISPLAY=:98 import -window root screenshots/wine-ra-menu.png
```

**Tiberian Dawn (TD):** Uses `ffmpeg x11grab`. `import -window root` produces blank
1-bit PNGs under Wine+Xvfb for DirectDraw surfaces at 8-bit colour depth.

```bash
ffmpeg -f x11grab -video_size 640x400 -i :99 -frames:v 1 screenshots/wine-td-menu.png -y
```

**Validation:** After capture, verify the file is >5KB. Screenshots under 5KB are
likely blank (only the GDI dialog frame captured, not the game surface).

---

## §2.4 — TD GDI renderer and Xvfb colour depth

TD's DirectDraw path renders black on headless Xvfb without hardware GL. The solution
is to force Wine's GDI renderer and use 8-bit colour depth.

Required registry settings (applied automatically by `wine-td.sh`):

```bash
WINEPREFIX="$HOME/.wine-td" WINEARCH=win32 wine reg add \
    'HKCU\Software\Wine\Explorer\Desktops' \
    /v Default /t REG_SZ /d "640x400" /f
WINEPREFIX="$HOME/.wine-td" WINEARCH=win32 wine reg add \
    'HKCU\Software\Wine\Direct3D' \
    /v DirectDrawRenderer /t REG_SZ /d gdi /f
```

**CONQUER.INI** must disable hardware blits:
```ini
[Options]
HardwareFills=0
VideoBackBuffer=0
AllowHardwareBlitFills=0
ScreenHeight=400
```

**Xvfb colour depth:** TD requires 8-bit (640x400x8), not 24-bit. Wrong depth causes
blank game surface.

```bash
Xvfb :99 -screen 0 640x400x8 -ac &   # TD: 8-bit
Xvfb :98 -screen 0 640x480x24 -ac &   # RA: 24-bit
```

---

## §2.5 — EXE and DLL prerequisites

**RA95.EXE** (Red Alert):
- SHA-256: see `scripts/wine-exe-hashes.json` (stored in a standalone config file)
- Source: `redalert_allied.iso` from archive.org, LBA 45220, size 2,181,632 bytes
- Required DLLs: `THIPX32.DLL`, `THIPX16.DLL` (from same ISO)

**C&C95.EXE** (Tiberian Dawn — C&C Gold Win95 port):
- Size: 1,161,216 bytes
- Required DLL: `THIPX32.DLL`

Use `scripts/wine-ra-setup.sh` and `scripts/wine-td-setup.sh` for first-time setup.
These download, verify SHA-256, and stage everything needed.

**Updating EXE hashes:** If the source ISO changes, update the hash config:
```bash
sha256sum /path/to/RA95.EXE
# Edit scripts/wine-exe-hashes.json with the new hash
```

---

## §3 — Running the comparison

### Quick run (may skip if EXE absent)

```bash
bash scripts/wine-ra.sh                          # RA
bash scripts/wine-td.sh                           # TD
```

### With explicit paths

```bash
bash scripts/wine-ra.sh /opt/redalert/RA95.EXE \
    /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 \
    e2e/screenshots
```

### CI integration

The scripts exit with:
- **0** — all screenshots captured, verified non-trivial
- **1** — FAIL (missing deps or data directory)
- **2** — SKIP (EXE not found, treat as optional gate)

Set env vars to enable downstream Playwright comparison tiers:
```bash
WINE_RA_READY=1   # Set when wine-ra.sh succeeds
WINE_TD_READY=1   # Set when wine-td.sh succeeds
```

Playwright tests skip Wine comparison tiers unless these are set.

---

## §4 — Wine input tools

For automated gameplay capture, the `tools/wine-input/` directory provides synthetic
input injectors:

- `ra-sendinput.c` — Win32 `SendInput` API for RA
- `td-sendinput.c` — Same for TD (pre-built `.exe` included)
- `ra-screenshot.c` — Screenshot capture helper
- `td-screenshot.c` — Same for TD

These are compiled as Win32 executables and injected into the Wine prefix. Use them
for campaign-level screenshot comparison beyond the title/menu state.

---

## §5 — Verification bar

| Gate | Minimum proof |
|---|---|
| **Wine installed** | `wine --version` succeeds, no "wine32 is missing" |
| **wine-ra.sh** | Title + menu screenshots >5KB each |
| **wine-td.sh** | Title + menu screenshots >5KB each (may be GDI-only) |
| **CI gate** | Script exits 0 or 2 (never 1 on data-absent runner) |

After successful capture, run Playwright parity tests:
```bash
WINE_RA_READY=1 npx playwright test e2e/tim699-ra-compare.spec.ts --grep "Tier 3"
WINE_TD_READY=1 npx playwright test e2e/tim711-td-compare.spec.ts --grep "Tier 3"
```

---

## Reference

- `scripts/wine-ra.sh` — RA Wine launcher (208 lines, documented)
- `scripts/wine-td.sh` — TD Wine launcher (191 lines, documented)
- `scripts/wine-ra-setup.sh` — First-time RA setup
- `scripts/wine-td-setup.sh` — First-time TD setup
- `tools/wine-input/` — Synthetic input injectors
- `nix build path:./tools/cnc-ddraw#cnc-ddraw  # produces result/bin/ddraw.dll` — cnc-ddraw wrapper builder
- `scripts/wine-soviet-l1.sh`, `scripts/wine-allied-l1.sh` — Campaign-specific captures
- `e2e/tim699-ra-compare.spec.ts` — RA comparison test (Tier 3 = Wine OG)
- `e2e/tim711-td-compare.spec.ts` — TD comparison test (Tier 3 = Wine OG)
