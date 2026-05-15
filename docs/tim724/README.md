# TIM-724 — TD Wine OG Allied/GDI Mission 1 gameplay execution

Status: **blocked** by two precondition gaps. Findings documented here so the
next agent can pick up cleanly.

## Goal

Drive the OG Tiberian Dawn `C&C95.EXE` under Wine to GDI Mission 1 and capture
gameplay screenshots — TD analogue of TIM-708 (RA Allied L1 under Wine).

## What this heartbeat actually found

### 1. `/opt/tiberiandawn/C&C95.EXE` is the EVA *setup* program, not the game

`scripts/wine-td-setup.sh` (TIM-711) extracts a 1,641,984-byte file from
`SETUP.Z` at archive offset `0x9BAF86` and stores it as `C&C95.EXE`.

Running it under Wine + Xvfb produces the **EVA installer welcome screen**, not
the C&C main menu — see `td-eva-setup-not-game.png` (Command & Conquer
Windows 95 Edition CD-ROM Setup Program / "INSTALL C&C:WIN'95" / "EXPLORE
THE CD" / "SNEAK PEEK" buttons).

This means TIM-711's wine-td.sh has *never* been driving the real game —
its title/menu screenshots are the setup program's screens, mis-identified.

Two contributing facts:

* The script's claimed extraction size is 1,175,239 bytes; the actual output
  is 1,641,984 bytes (40 % larger). The IS-LZ decomp loop is overshooting
  or the block parameters are wrong.
* The directory-entry offset (`0x16695d3`) is taken from a name *match*
  inside SETUP.Z, but the InstallShield 3 archive has multiple "C&C95.EXE"
  string references (EVA setup, game stub, the actual game). The right
  directory entry has not been confirmed by checksum or by structural
  parse — only by string search.

After dismissing the EVA welcome screen with `Return`, Wine Desktop
disappears from xwininfo and subsequent screenshots are an empty Xvfb root
(169 bytes, 2 colors). The setup likely exits because it can't find a real
CD-ROM mount; no game install happens.

### 2. cage 0.3.0 + winewayland.drv: TD renders the same empty backdrop as RA

Smoke-tested TD ELF stub under `cage 0.3.0 + WLR_BACKENDS=headless +
wine-11.8 winewayland.drv`. Three screenshots at t=8/14/19 s are
byte-identical 23,326-byte empty cage backdrop PNGs (`td-cage-empty-backdrop.png`).

This reproduces the [TIM-709](/TIM/issues/TIM-709) finding for TD: wine
creates Wayland surfaces but never commits a visible buffer — the
DirectDraw-fullscreen → winewayland.drv interaction is broken for both RA
and TD. cage path is not viable for TD without a winewayland.drv DDraw
fix.

### 3. Xvfb + xdotool input substrate: same DInput-polling block as RA

If/when (1) is fixed, the TD main menu will still face the [TIM-709](/TIM/issues/TIM-709)
input-substrate problem: TD's main menu is custom DirectDraw with
DirectInput polling for clicks, same as RA. xdotool clicks under Xvfb
will not reach the game state machine. Until [TIM-708](/TIM/issues/TIM-708)
lands a working input path for RA, TD gameplay automation is structurally
blocked by the same issue.

## Why TIM-724 is blocked

Two preconditions must be resolved before this issue can produce gameplay
screenshots:

* **Precondition A** — Extract the *actual* `C&C95.EXE` from the EA 2007
  freeware release. This is a TIM-711 follow-up; created as a child issue.
* **Precondition B** — A working synthetic-input path for TD's custom
  DirectDraw GUI. This is the same blocker as TIM-708 / TIM-709 for RA;
  whatever solution lands there (Wine `dinput` patch, fixture-based pivot,
  alternate substrate) applies equally to TD.

Both must clear before clicking menus to start GDI Mission 1 is even
attemptable.

## Evidence in this directory

| File | What it shows |
|------|----------------|
| `td-eva-setup-not-game.png` | First-render Xvfb capture of "C&C95.EXE" — it's the EVA setup program, proving the extracted binary is wrong. |
| `td-cage-empty-backdrop.png` | Cage 0.3.0 + winewayland.drv smoke for TD — empty 23-KB backdrop at t=8 (and identical at t=14, t=19); same DDraw-no-commit failure mode as RA. |

## Next agent

The next agent on this issue should:

1. Wait for **Precondition A** child issue to land a real `C&C95.EXE`.
2. Wait for **TIM-708** to confirm a working input substrate for RA (then
   apply the same approach to TD).
3. Then write the gameplay-navigation extension to `scripts/wine-td.sh`
   following the `wine-gameplay.sh` template.
