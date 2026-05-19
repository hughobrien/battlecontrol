---
name: wine-testing
description: Use when running original Win32 C&C Red Alert (RA95.EXE) or Tiberian Dawn (C&C95.EXE) under Wine for baseline comparison against native/WASM ports. Trigger on symptoms like Wine prefix failures, DirectDraw rendering blank, DirectSound dialog blocking automation, xdotool timing races, screenshot capture returning blank images, or CI Wine job skipping unexpectedly.
version: 0.3.0
---

# Wine Testing Skill

> **Extension tools:** `wine_check`, `wine_capture`.  **Script:** `bash scripts/wine-cnc-capture.sh`.

You are running the original Win32 C&C Red Alert or Tiberian Dawn executable under Wine
for baseline comparison against the native Linux and WASM ports. The workflow captures
screenshots in a headless Xvfb environment for automated pixel-level parity validation.

---

## Phase 0 — Check prerequisites

```bash
bash scripts/wine-check.sh
```

One-command gate. Exits 0 if wine, wine32, xvfb-run, xdotool, ffmpeg, and
imagemagick are all present. Exits 1 with a list of what's missing.

---

## Phase 1 — Classify the symptom

| Symptom | Lens | Go to |
|---|---|---|
| `wine32 is missing` from `wine --version` | 32-bit Wine architecture not installed | §2.1 |
| `WINEARCH=win32` rejected (wow64) | Wine 11.0+ wow64 doesn't support WINEARCH | §2.1 |
| Wine prefix creation fails or hangs | Corrupt prefix or wow64 compatibility | §2.1 |
| DirectSound warning dialog blocks automation | Dialog must be dismissed with xdotool | §2.2 |
| Screenshot is blank (0 bytes or 1-bit PNG) | Capture method mismatch or GDI not configured | §2.3 |
| Game renders dialog but blank after dismiss | GDI renderer not configured | §2.4 |
| DirectDraw surface renders black on Xvfb | GDI renderer not configured or wrong color depth | §2.4 |
| Game exits immediately with `THIPX16.DLL` error | 16-bit thunking unsupported in wow64 | §2.5 |
| Title screen shows but menu crashes (video buffer) | No GL context on Xvfb — title only | §2.4 |
| Screenshot is 176 B (1-bit, all black) | wined3d no3d mode — NULL draw_texture | §2.6 |
| Screenshot is ~3.5 KB RGB with small gray area | cnc-ddraw loaded, game stuck on error dialog | §2.6 |
| Screenshot is ~5 KB RGB with gray dialog | Game showing "Insert CD" or blocking dialog | §2.6 |
| Screenshot is ~7 KB paletted with navy blue | Game close — CD label comparison failing | §2.6 |
| Screenshot is 47-88 KB paletted, 117-177 colors | **Real game content** — rendering correctly! | §2.6 |
| `wine-ra.sh` / `wine-td.sh` exit 2 (SKIP) | EXE or data not found — first-time setup needed | §3 |

---

## §2.1 — Wine setup (wow64 or classic)

RA95.EXE and C&C95.EXE are 32-bit Windows executables. Wine 11.0+ (wow64 from Nix)
runs them without additional architecture setup. Classic Debian/Ubuntu Wine needs
`wine32:i386`.

**Wine 11.0+ wow64** (Nix — in `nix develop` shell):
- No `WINEARCH=win32` needed — wow64 handles both architectures natively.
- **Do not use `WINEARCH=win32`** — it will fail with `not supported in wow64 mode`.
- Prefix creation: `WINEPREFIX="$HOME/.wine-ra" WINEDEBUG=-all wineboot --init`

**Prefix recovery:**

```bash
# Inspect current prefix state
WINEPREFIX="$HOME/.wine-ra" wine reg query 'HKCU\Software\Wine\Direct3D'  # check renderer
WINEPREFIX="$HOME/.wine-ra" wine reg query 'HKCU\Software\Wine\Explorer\Desktops'  # check desktop

# If corrupt or wrong wine version: delete and recreate
rm -rf "$HOME/.wine-ra"
WINEPREFIX="$HOME/.wine-ra" WINEDEBUG=-all wineboot --init
```

**CI note:** CI runners use a fresh prefix per job (ephemeral). Local prefixes
accumulate state across runs. If switching between wow64 and classic Wine, delete
the old prefix first.

---

## §2.2 — DirectSound dialog dismissal

Both RA and TD show a "Warning - Unable to create Direct Sound Object" dialog on startup
when no physical audio card is present. This must be dismissed for the game to proceed.

The scripts handle this with xdotool:
```bash
# Wait for dialog to appear (~7s after launch), then dismiss ONCE
sleep 7
DISPLAY=:98 xdotool key Return
```

**Single dismiss only.** A second Return press can accidentally close the game
window (observed under Wine 11.0 wow64 — the game exits on the second keypress).

**Timing:** On slower CI runners, the dialog may appear later. Increase the
initial sleep to 9s if the dialog hasn't appeared yet.

**Audio silencing:** The scripts set `AUDIODEV=null` and `WINEDLLOVERRIDES` to suppress
ALSA/OSS audio driver errors that fill stderr. These are expected and not game failures.

---

## §2.3 — Screenshot capture method

**Red Alert (RA):** Uses `import -window root` (ImageMagick). RA renders at 640x480x24
with the GDI renderer.

```bash
DISPLAY=:98 import -window root screenshots/wine-ra-menu.png
```

**Tiberian Dawn (TD):** Uses `ffmpeg x11grab`. `import -window root` produces blank
1-bit PNGs under Wine+Xvfb for DirectDraw surfaces at 8-bit colour depth.

```bash
ffmpeg -f x11grab -video_size 640x400 -i :99 -frames:v 1 screenshots/wine-td-menu.png -y
```

**Validation — file-size heuristics:**

Use the PNG file size of the captured screenshot as a quick diagnostic:

| Size | Mode | Colors | Meaning |
|-----:|:----:|:------:|---------|
| **176 B** | 1-bit | 1 (black) | wined3d no3d: NULL draw_texture, all black |
| **~3.5 KB** | RGB | ~470 | cnc-ddraw loaded, game stuck on error dialog |
| **~5 KB** | RGB | ~470 | Windows dialog ("Insert CD" etc.) |
| **~7 KB** | P | ~42 | 8-bit paletted active, CD label mismatch |
| **~24-29 KB** | P | ~100 | More content, game progressing |
| **47-88 KB** | P | 117-177 | **Real game content!** Loading/menu |
| **100+ KB** | P | 256 | Full rendering with terrain/units |

**Quick rule:** under 10 KB → dialog/error. Over 30 KB + paletted → real content.
Over 80 KB → full graphics.

The title screen under the GDI renderer is ~4266 bytes (TrueColor 8-bit sRGB).
Screenshots under 1000 bytes are blank (only the GDI dialog frame captured).

---

## §2.4 — GDI renderer and Xvfb colour depth

Both RA and TD need the GDI renderer forced under Xvfb (no GPU, no GL context):

**RA (Red Alert):**
```bash
WINEPREFIX="$HOME/.wine-ra" wine reg add \
    'HKCU\Software\Wine\Explorer\Desktops' \
    /v Default /t REG_SZ /d "640x480" /f
WINEPREFIX="$HOME/.wine-ra" wine reg add \
    'HKCU\Software\Wine\Direct3D' \
    /v DirectDrawRenderer /t REG_SZ /d gdi /f
```

**TD (Tiberian Dawn):**
```bash
WINEPREFIX="$HOME/.wine-td" wine reg add \
    'HKCU\Software\Wine\Explorer\Desktops' \
    /v Default /t REG_SZ /d "640x400" /f
WINEPREFIX="$HOME/.wine-td" wine reg add \
    'HKCU\Software\Wine\Direct3D' \
    /v DirectDrawRenderer /t REG_SZ /d gdi /f
```

**CONQUER.INI** (TD only) must disable hardware blits:
```ini
[Options]
HardwareFills=0
VideoBackBuffer=0
AllowHardwareBlitFills=0
ScreenHeight=400
```

**REDALERT.INI** (RA) must NOT be a symlink — write it locally with `PlayIntro=no`:
```ini
[Sound]
Card=0
Port=3F8h
IRQ=4
DMA=-1
[Options]
HardwareFills=no
[Intro]
PlayIntro=no
```

**Xvfb colour depth:**
```bash
Xvfb :99 -screen 0 640x400x8 -ac &   # TD: 8-bit (required for GDI renderer)
Xvfb :98 -screen 0 640x480x24 -ac &   # RA: 24-bit
```

**Title→Menu limitation:** Without a GL context, wined3d's no3d fallback cannot
create draw textures. The game's primary surface exists in system memory but content
is never copied to the X11 window — resulting in black screenshots.

**Workaround: cnc-ddraw.** Replace Wine's builtin ddraw with cnc-ddraw — a Win32
DLL that intercepts DirectDraw calls and renders via GDI. This bypasses wined3d
entirely and works on any X server, including Xvfb.

```bash
# Build cnc-ddraw from upstream
nix build .#cnc-ddraw

# Use in game directory
cp result/bin/ddraw.dll <game_dir>/DDRAW.DLL
# Create ddraw.ini:
cat ><game_dir>/ddraw.ini <<'EOF'
[ddraw]
fullscreen=false
windowed=true
no_compat_warning=true
fake_mode=640x400x8
EOF
```

Then launch with:
```bash
WINEDLLOVERRIDES="ddraw=n" wine RA95.EXE
```

**Required patches for the EXE** (apply in order):
1. `scripts/nocd-patch.py` — NOP the GetDriveType CD check
2. `scripts/ddscl-patch.py` — SetCooperativeLevel(DDSCL_NORMAL) + stub SetDisplayMode
3. `printf '\x00' \| dd of=RA95.EXE bs=1 seek=$((0x1BFCB7)) conv=notrunc` — Zero the "CD1" volume label string (Wine doesn't return ISO volume labels on directory mounts)

With cnc-ddraw + all three patches, the game renders menu screens correctly:
~88 KB (loading) → ~47 KB (menu), 8-bit paletted, 177 unique colors.

---

## §2.5 — EXE, DLL, and THIPX32 stub prerequisites

**RA95.EXE** (Red Alert):
- SHA-256 (original): `a95e2ac85c4cc3aaacb7795e3c07b8aec7c3e10efe679766fb2ee15b12aa2d55`
- SHA-256 (patched, cnc-ddraw): `c9e9be012953c2cd0db68f30861dbe29f9709332c832bf8483998200315a1af7`
- Source: `redalert_allied.iso` from archive.org, LBA 45220, size 2,181,632 bytes
- The patched EXE renders a better title screen (4266 vs 1507 bytes, more colors)

**C&C95.EXE** (Tiberian Dawn — C&C Gold Win95 port):
- Size: 1,161,216 bytes

**THIPX32.DLL — Stub requirement for Wine 11.0 wow64:**
The original `THIPX32.DLL` uses 16-bit thunking to load `THIPX16.DLL` (a 16-bit NE format
DLL). Wine 11.0 (wow64) does NOT support this thunking. The DLL initialization fails with:
```
0044:err:thunk:_loadthunk (THIPX16.DLL, Thipx_ThunkData16, THIPX32.DLL): Unable to load 'THIPX16.DLL', error 2
0044:err:module:loader_init "thipx32.dll" failed to initialize, aborting
```

A **stub THIPX32.DLL** is provided at `tools/stub-thipx/thipx32.dll`. It exports all
functions that RA95.EXE imports (by name) but returns sensible defaults. No actual
networking functionality is provided, which is fine for title/menu screenshots.

Build from source:
```bash
cd tools/stub-thipx
i686-w64-mingw32-gcc -shared -o thipx32.dll stub.c thipx32.def
```

**Exports provided:**
`_IPX_Broadcast_Packet95`, `_IPX_Close_Socket95`, `_IPX_Get_Connection_Number95`,
`_IPX_Get_Local_Target95`, `_IPX_Initialise`, `_IPX_Open_Socket95`,
`_IPX_Send_Packet95`, `_IPX_Shut_Down95`, `_IPX_Start_Listening95`,
`_IPX_Get_Outstanding_Buffer95`, `_IPX_Get_Version`, and `_Thipx_ThunkData32`.


---

## §2.6 — cnc-ddraw: bypassing wined3d for headless rendering

When wined3d's no3d mode produces NULL draw_textures (black screenshots), the
solution is cnc-ddraw — a Win32 DLL that replaces DirectDraw entirely and renders
via GDI. This works on any X server, including Xvfb without a GPU.

**Build:**
```bash
nix build .#cnc-ddraw --impure
```

**Staging directory:**
```bash
STAGE=$(mktemp -p /tmp -d)
cp /mnt/redalert/MAIN.MIX "$STAGE/"          # Game data from mounted ISO
cp /mnt/redalert/INSTALL/REDALERT.MIX "$STAGE/"
cat >"$STAGE/REDALERT.INI" <<'EOF'
[Sound]
Card=-1
Port=-1
IRQ=-1
DMA=-1
[Options]
HardwareFills=no
[Intro]
PlayIntro=no
EOF

cat >"$STAGE/ddraw.ini" <<'EOF'
[ddraw]
fullscreen=false
windowed=true
no_compat_warning=true
fake_mode=640x400x8
EOF

# Resolve from Nix store (NoCD+DDSCL+cdlabel patches pre-applied)
RA_EXE=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null)
cp "$RA_EXE" "$STAGE/RA95.EXE"
cp tools/stub-thipx/thipx32.dll "$STAGE/THIPX32.DLL"
cp "$(nix build .#cnc-ddraw --impure --print-out-paths)/bin/ddraw.dll" "$STAGE/DDRAW.DLL"
```

**Launch:**
```bash
cd "$STAGE"
DISPLAY=:96 WINEPREFIX=$HOME/.wine-ra \
    WINEDLLOVERRIDES="ddraw=n" \
    timeout 30 wine RA95.EXE
```

**EXE patches required** (applied in order):
1. `scripts/nocd-patch.py` — NOP the GetDriveType CD check
2. `scripts/ddscl-patch.py` — SetCooperativeLevel(DDSCL_NORMAL) + stub SetDisplayMode
3. Manual: zero byte at 0x1BFCB7 in RA95.EXE — cdlabel workaround

**Screenshot diagnostics (file-size heuristics):**
- **176 B** — wined3d no3d: blank black image
- **~3.5 KB** — cnc-ddraw loaded, error dialog
- **~5 KB** — Windows dialog ("Insert CD")
- **~7 KB** — paletted mode active, CD label mismatch
- **24-29 KB** — game progressing, more content
- **47-88 KB** — **real game content!** (117-177 colors, palette mode)
- **100+ KB** — full rendering with terrain/units

---

## §3 — Running the comparison

### Quick run (may skip if EXE absent)

```bash
bash scripts/wine-ra.sh                          # RA
bash scripts/wine-td.sh                           # TD
```

### With explicit paths

```bash
bash scripts/wine-ra.sh \
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

## §5 — Binary auto-launch patches (skip menus, any difficulty)

For campaign/mission testing beyond title/menu, RA95.EXE can be patched to skip all
interactive menus and boot directly into any Allied mission at Normal difficulty.

### Full patch chain (apply in order)

```bash
python3 scripts/nocd-patch.py RA95.EXE
python3 scripts/ddscl-patch.py RA95.EXE
printf '\x00' | dd of=RA95.EXE bs=1 seek=$((0x1BFCB7)) conv=notrunc  # cdlabel
python3 scripts/focus-skip-patch.py RA95.EXE
python3 scripts/game-in-focus-patch.py RA95.EXE
python3 scripts/vqa-skip-patch.py RA95.EXE
python3 scripts/ra-scenario-patch.py RA95.EXE SCG02EA    # target mission
python3 scripts/ra-autostart-patch.py RA95.EXE            # auto-boot → Normal diff
```

### What each autostart patch does

`scripts/ra-autostart-patch.py` modifies four sites in `Select_Game()`:

| Patch | Assembly change | Effect |
|-------|----------------|--------|
| Selection | `esi=4` → `esi=1` | Forces `SEL_START_NEW_GAME`, skips Main_Menu |
| Difficulty | NOP `je Fetch_Difficulty` | Always sets DIFF_NORMAL, no dialog |
| Faction | `jne` → `jmp Choose_Side` | Skips faction dialog (Choose_Side plays a movie, already NOPed by vqa-skip) |
| Allies/Soviets | NOP `jne` flag check | Always picks SCG01EA.INI (patched to target by ra-scenario-patch) |

### Mission names

| Name | Target |
|------|--------|
| Allied L1 | `SCG01EA.INI` |
| Allied L2 | `SCG02EA.INI` |
| Allied L3 | `SCG03EA.INI` |
| Soviet L1 | `SCU01EA.INI` |

The scenario INI data lives inside `MAIN.MIX`. Difficulty is encoded in gameplay
handicap values (set to Normal by the patches), not in the scenario filename.

### Native/WASM equivalent

For the port builds, use environment variables (already implemented in INIT.CPP):

```bash
RA_AUTOSTART=1 RA_AUTOSTART_SCENARIO=SCG02EA.INI ./build/ra/redalert
```

Difficulty defaults to Normal. An `RA_AUTOSTART_DIFFICULTY` env var is the next step.

---

## §6 — Verification bar

| Gate | Minimum proof |
|---|---|
| **Wine installed** | `wine --version` succeeds, no "wine32 is missing" (may be irrelevant for wow64) |
| **wine-ra.sh** | Title screenshot >1000 bytes (TrueColor 8-bit sRGB, ~4266 bytes typical) |
| **wine-td.sh** | Title + menu screenshots >1000 bytes each (may be GDI-only) |
| **cnc-ddraw + patches** | Screenshot 47-88 KB, 8-bit paletted, 117-177 colors = game rendering |
| **CI gate** | Script exits 0 or 2 (never 1 on data-absent runner) |

After successful capture, run Playwright parity tests:
```bash
WINE_RA_READY=1 playwright test e2e/tim699-ra-compare.spec.ts --grep "Tier 3"
WINE_TD_READY=1 playwright test e2e/tim711-td-compare.spec.ts --grep "Tier 3"
```

---

## Reference

- `scripts/wine-ra.sh` — RA Wine launcher (~220 lines, documented)
- `scripts/wine-td.sh` — TD Wine launcher (~200 lines, documented)
- `scripts/wine-ra-setup.sh` — First-time RA setup
- `scripts/wine-td-setup.sh` — First-time TD setup
- `tools/stub-thipx/` — Stub THIPX32.DLL (source + .def + prebuilt binary)
- `tools/wine-input/` — Synthetic input injectors (ra-sendinput.exe etc.)
- `nix build .#cnc-ddraw` — cnc-ddraw upstream build (from Nix flake input)
- `docs/wine-headless-rendering.md` — Full field guide: all approaches tried
- `scripts/wine-soviet-l1.sh`, `scripts/wine-allied-l1.sh` — Campaign-specific captures
- `scripts/wine-vqa-capture.sh` — VQA cinematic capture under Wine
- `scripts/wine-gameplay.sh` — Generic gameplay capture under Wine
- `scripts/ra-autostart-patch.py` — Binary patch: skip menus, force Normal difficulty
- `scripts/ra-scenario-patch.py` — Replace mission name in RA95.EXE (e.g. SCG01EA→SCG02EA)
- `e2e/tim699-ra-compare.spec.ts` — RA comparison test (Tier 3 = Wine OG)
- `e2e/tim711-td-compare.spec.ts` — TD comparison test (Tier 3 = Wine OG)
