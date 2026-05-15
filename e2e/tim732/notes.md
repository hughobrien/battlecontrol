# TIM-732 — cnc-ddraw + Wine deep-dive findings (2026-05-15)

Follow-up to **TIM-708 / PR #135**. Drove every hypothesis from
`e2e/tim708/notes.md` (when that PR merges) plus several more, under both
Wine 11.8 and Wine 10.0. Captures + traces preserved at `/tmp/tim732/` for
the next agent.

Reproducer: `scripts/wine-ra-cnc-ddraw-diag.sh` (this PR).

## TL;DR

1. **Wine 11.8 + cnc-ddraw 7.5.0 + Xvfb is a regression.** RA95.EXE
   produces only a bare 640×400 *white* GDI rectangle (no title bar, no
   decorations, no content). See `wine11-cnc-ddraw-white-rect.png`.
2. **Wine 10.0 + cnc-ddraw 7.5.0 + Xvfb is materially better.** A proper
   openbox-decorated "Red Alert" 640×400 window appears, with the RA icon
   and a *black* primary surface. See `wine10-cnc-ddraw-black-surface.png`.
   But RA still never paints title/menu content into it — even after 35 s
   and many SendInput pokes.
3. The real blocker is **NOT** any of the four hypotheses in
   `e2e/tim708/notes.md` (dsound, THIPX, predecessor patches, missing
   debug log).
4. The real blocker is that RA never receives `WM_ACTIVATEAPP(TRUE)` under
   either Wine version with Xvfb+openbox, so `GameInFocus` stays `FALSE`
   throughout. `focus-skip-patch.py` only NOPs three sites in `CONQUER.CPP`;
   RA's render path has many more `if (!GameInFocus)`-guarded branches
   (`CONQUER.CPP:2579`, the title-screen pump, VQA dispatch, etc.) that
   silently skip drawing.

## What was tested

All commands replicable from `scripts/wine-ra-cnc-ddraw-diag.sh` (this PR)
and `/tmp/tim732/diag*.sh` (kept locally, not committed).

| Test | EXE variant | DLL overrides | Wine | Result |
|---|---|---|---|---|
| Baseline | `sdm_orig` (NoCD only) | `ddraw=n` | 11.8 | White window, 0 visible DDraw calls, main thread RtlWaitOnAddress spin |
| Sync trace | `sdm_orig` | `ddraw=n` | 11.8 | Main thread (`00e4`) RtlWaitOnAddress + NtSetTimer loop after `CoInitialize` |
| Focus-skip | `focus_orig` + patch | `ddraw=n` | 11.8 | Same white-window. Patch applied (SHA `08f89ab8…`) |
| `dsound=` | `focus_orig` + patch | `ddraw=n;dsound=` | 11.8 | Refused — RA statically imports `dsound.dll` (`c0000135`) |
| `thipx32=` | `focus_orig` + patch | `ddraw=n;thipx32=;thipx16=` | 11.8 | Refused — same static-import reason |
| TIM-727 DDSCL EXE | `RA95.EXE` (NoCD+DDSCL) | `ddraw=n` | 11.8 | Same white-window |
| `renderer=auto` | `focus_orig` + patch | `ddraw=n` | 11.8 | cnc-ddraw window absent (OpenGL fails under Xvfb) |
| `hook=0` | `focus_orig` + patch | `ddraw=n` | 11.8 | Same white-window |
| Wine builtin DDraw | `focus_orig` + patch | `ddraw=b` | 11.8 | **178 DDraw API calls captured**, full init OK; X11 window present but x11grab-invisible (TIM-708 finding #1) |
| **Wine 10.0** | `focus_orig` + patch | `ddraw=n` | 10.0 | **"Red Alert" titled window appears, black DDraw surface, 41 DSound buffers (vs 5 under 11.8)** |
| Wine 10 + 35 s + 5 SendInput pokes | `focus_orig` + patch | `ddraw=n` | 10.0 | Identical black surface through all 7 captures, no input response |

## Key trace observations

Under Wine 11.8 + cnc-ddraw (sync trace shows the main thread):

```
00e4:trace:win:set_window_text 0x2005e, L"Red Alert"   <-- main window created
00e4:trace:win:WIN_CreateWindowEx L"OleMainThreadWndClass"  <-- CoInitialize ran
00e4:trace:seh:dispatch_exception code=c0000005 ... addr=00000309 cs=0287
  ^-- 16-bit thunk fault from krnl386.exe16, swallowed by vectored handler chain
00e4:trace:sync:NtSetTimer (0xe4, 0x7956f0b8, ...)     <-- WINMM timer set up in cnc-ddraw range
00e4:trace:sync:NtWaitForSingleObject handle 0xe4, timeout 0.-660000
  ^-- main thread parked here for the rest of the run
```

Address `0x7956f0b8` falls inside the cnc-ddraw DLL mapping
(`79510000-7858c000`), confirming **RA does reach `DirectDrawCreate`** —
cnc-ddraw has already installed its WINMM frame-pacing timer. The
`+ddraw` / `+relay` channels don't show the call because the
RA→cnc-ddraw path is native→native and bypasses Wine's trace shims.

Under Wine 10.0 the same setup additionally produces:

```
0024:trace:dsound:PrimaryBufferImpl_Play (00C063E0,0,0,DSBPLAY_LOOPING)
... 41 CreateSoundBuffer calls vs 5 on Wine 11.8 ...
```

so RA progresses through *much* more of the audio init pool under Wine 10
than Wine 11. The Wine 11 regression appears to be in either
`winex11.drv`'s GDI compositing for unmanaged top-level windows (RA's main
window has `WS_POPUP | WS_EX_TOPMOST` per `WINSTUB.CPP:466`), or in the
audio device enumeration path that gates RA's secondary-buffer allocation.

## Why `focus-skip-patch.py` is not enough

`scripts/focus-skip-patch.py` (landing in PR #135) NOPs three `while
(!GameInFocus)` sites in `CONQUER.CPP` (file offsets `0x154005`,
`0x15f2f1`, `0x15f583`). The source shows seven other branches that read
`GameInFocus`:

- `CONQUER.CPP:2579` — `if (SpecialDialog == SDLG_NONE && GameInFocus)` —
  the **render branch in the main game loop**. With `GameInFocus=FALSE`,
  `Map.Input` / `Map.Render` are skipped every frame. **This is almost
  certainly why the surface stays black** even when cnc-ddraw and the
  audio engine are running.
- `CONQUER.CPP:3586`, `CONQUER.CPP:4261` — VQA / multi-player gameplay
  GameInFocus guards.
- `INIT.CPP:3501` — `do { Keyboard->Check(); } while (!GameInFocus);` —
  `#if (0)` in our GPL source, but likely live in the 1996 EXE.
- `NETDLG.CPP:6326`, `:7120` — netplay dialogs.
- `WINSTUB.CPP:121`/`:132` — `Check_For_Focus_Loss` dispatch.

A *thorough* focus-bypass needs to **flip `GameInFocus` to `TRUE` at
startup and keep it pinned**, not just NOP three loops. Either:

- (a) Flip the initial value in `.data` (`GLOBALS.CPP:206` equivalent in
  the 1996 build — find the `mov dword ptr [GameInFocus], 0` initialiser
  and patch to `1`).
- (b) NOP every `cmp/test [GameInFocus], 0` site reachable from the
  title/menu/render path (brittle).
- (c) Patch `Windows_Procedure`'s `WM_ACTIVATEAPP` handler to ignore the
  wParam and always assign `GameInFocus = TRUE`.

Option (a) is cleanest. The next pass should disassemble RA95.EXE,
locate the `GameInFocus` symbol via its initial assignment to 0, and
patch that initial value.

## Why Wine 11.8 wined3d isn't the answer either

TIM-708 finding #1 already established that Wine builtin DDraw renders to
an X11 surface that `ffmpeg x11grab` / `xwd -root` / `import -window root`
all return as pure black. That hasn't changed in Wine 11.8 — confirmed
the 178-DDraw-call run (`/tmp/tim732/builtin/`) produces a 1497-byte PNG
(blank). cnc-ddraw fixes the capture problem; only RA's GameInFocus
guards block the render content.

## Recommended next step

This rabbit hole has chased four layers. The productive paths from here
are:

1. **Open TIM-733 (or similar): "Pin `GameInFocus = TRUE` in RA95.EXE".**
   Concrete patch with a clear acceptance test (non-black frame under
   Wine 10 + cnc-ddraw + Xvfb without any SendInput needed). Use
   `scripts/wine-ra-cnc-ddraw-diag.sh` as the regression check.
2. **Pin the harness to Wine 10.0.** Wine 10 is materially better at the
   audio init path and at producing an X11-capturable cnc-ddraw window.
   The Debian `wine` package (10.0~repack-6) is what's installed at
   `/usr/bin/wine`. Document the Wine 11.x regression as a separate
   issue and avoid Wine 11 for the OG comparison harness until the
   underlying regression in `winex11.drv` is identified.
3. **Skip cnc-ddraw if forced onto Wine 11.x.** The cage + Xwayland +
   winex11 path from TIM-719 / PR #129 still works for menu screens —
   fall back to that for the comparison harness if Wine 11 is mandatory.

## Reproducer

```bash
# One-time: create a Wine 10 32-bit prefix
WINEPREFIX=$HOME/.wine-tim732-w10 WINEARCH=win32 WINEDEBUG=-all \
    /usr/bin/wine wineboot --init

# Re-runnable: stage + run with timed captures
WINE=/usr/bin/wine \
    WINEPREFIX=$HOME/.wine-tim732-w10 \
    RUN_SECONDS=20 \
    ARTIFACT=/tmp/tim732/run \
    bash scripts/wine-ra-cnc-ddraw-diag.sh
```

Expected output on a working Wine 10 setup:

```
display=:91
  t5.png: 5912 bytes
  t10.png: 5912 bytes
  t15.png: 5912 bytes
  t20.png: 5912 bytes

t20 size: 5912 bytes
RESULT: 'Red Alert' titled window with black DDraw surface (Wine 10 expected pattern).
```

A successful GameInFocus-pin patch (the next step) should turn t10/t15/t20
into much larger PNGs as RA's title screen / palette fade actually
renders into the surface.
