# Wine OG rendering — what's actually happening here

A primer for humans landing on the Wine capture pipeline. The game is from
1996; the techniques we use to run it headlessly in 2026 are stacked on top
in non-obvious ways. This doc explains every layer in plain English so you
can read the code and patches with a mental model in your head.

For the history of approaches we tried before settling on this one, see the
companion doc [`wine-headless-rendering.md`](./wine-headless-rendering.md).

---

## The 30-second picture

When you run `python3 scripts/capture-checkpoint.py mission allied-l1
--targets wine`, this is what happens end-to-end:

```
   ┌─────────────────────────────────────────────────────────────────┐
   │  RA95.EXE (1996 Win32 binary, slightly patched)                 │
   │     calls into Windows API: DirectDraw, GDI, User32, ...        │
   └──────────────────────┬──────────────────────────────────────────┘
                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  Wine — runs the Win32 binary on Linux                          │
   │     forwards most calls to its own implementations of Win32     │
   │     EXCEPT ddraw.dll, which we override (see WINEDLLOVERRIDES). │
   └──────────────────────┬──────────────────────────────────────────┘
                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  cnc-ddraw — a Win32 DLL named ddraw.dll, written in MinGW C    │
   │     implements the DirectDraw API surface that RA expects.      │
   │     Translates DDraw calls into Windows GDI calls (BitBlt etc.) │
   └──────────────────────┬──────────────────────────────────────────┘
                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  Wine's winex11.drv — converts GDI calls into X11 protocol      │
   │     XPutImage etc. against an X11 window.                       │
   └──────────────────────┬──────────────────────────────────────────┘
                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  Xvfb — X server with no display hardware. Maintains a 24bpp    │
   │     RGB framebuffer in plain RAM and accepts X11 protocol.      │
   └──────────────────────┬──────────────────────────────────────────┘
                          ▼
   ┌─────────────────────────────────────────────────────────────────┐
   │  ffmpeg x11grab (or `import`/`xwd`) — reads the Xvfb framebuffer│
   │     out via X11 and writes a PNG to disk.                       │
   └─────────────────────────────────────────────────────────────────┘
```

Every layer is a translation step. If any one of them mistranslates, the
PNG comes out wrong. The debugging section at the end of this doc maps
common failure modes onto which layer is responsible.

---

## Part 1 — How RA actually wants to draw (the 1996 part)

RA was written for Windows 95 with **DirectDraw** as its graphics API. To
read RA's source meaningfully you need a working mental model of DDraw,
because modern engines look nothing like this.

### Palette-indexed 8-bit graphics

In 1996, video cards routinely ran in **8-bit indexed colour mode**: each
pixel on screen is a single byte (0–255), and that byte is an *index* into a
**palette** of 256 RGB triples. The game owns the palette and can change it
at will: "set palette entry 47 to RGB (200, 80, 80)", and every pixel in the
framebuffer that has the byte value 47 instantly becomes that red.

This is why classic games can do effects like cycling water animations or
nightfall fades — they don't rewrite pixels, they just rotate the palette.
It also means **all of RA's sprite data and rendering code thinks in
palette indices, not in RGB**. A "snow" tile is a 64×64 block of bytes,
each byte an index into the active "snow theatre" palette.

When you're debugging colours later in this doc, remember: at the game
level, a pixel value is *meaningless without the palette*. If the palette
isn't applied correctly somewhere downstream, the same indices come out as
the wrong colours.

### DirectDraw surfaces

A **DirectDraw surface** is a rectangular block of pixel memory that the
hardware can blit (block-copy) around quickly. RA has two main surfaces:

- **Primary surface** — what's actually on screen, the visible framebuffer.
- **Back buffer** (or "hidden page") — an off-screen surface where the game
  draws the next frame. When the frame is ready, the game **flips**:
  swaps which surface the hardware shows.

This double-buffering avoids tearing. RA's render loop is roughly:

```
  clear back buffer
  draw terrain, units, UI into back buffer
  flip → back buffer becomes visible, old primary becomes new back buffer
```

### Cooperative levels

When a game opens DirectDraw it calls
`IDirectDraw::SetCooperativeLevel(hwnd, flags)`. The flags tell DirectDraw
how to share the screen with other windows:

- **`DDSCL_NORMAL`** — windowed mode. The game gets a normal window, the
  desktop is still there, you can alt-tab. The primary surface is
  effectively a region of the desktop.
- **`DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN`** — fullscreen-exclusive. The game
  owns the whole screen, takes over the video mode, and can do things like
  page-flipping at the hardware level. This is what RA asks for by default.

Retail RA wants exclusive-fullscreen. Under Wine on a headless Xvfb display,
exclusive-fullscreen routes the surface through wined3d's OpenGL path —
which doesn't work without a real GPU. We patch RA's binary to ask for
`DDSCL_NORMAL` instead, which gives us a windowed surface that ends up in
an X11 window we can grab pixels from.

### SetDisplayMode

After `SetCooperativeLevel`, RA calls
`IDirectDraw::SetDisplayMode(640, 480, 8)`: "give me a 640×480 surface in
8-bit colour." On real Windows, this also poked the video card into VGA
mode 13h-style 256-colour mode. In our pipeline it tells cnc-ddraw how big
its X11-backed surface needs to be. **This call has to actually reach
cnc-ddraw** — see [Part 3](#part-3--cnc-ddraw-a-modern-replacement-for-1996-ddraw)
for what goes wrong if you stub it.

### BitBlt

`BitBlt` ("bit block transfer") is the GDI primitive for copying a
rectangle of pixels from one surface to another, optionally with colour
conversion. cnc-ddraw uses it heavily to put DDraw surfaces onto its X11
window.

---

## Part 2 — What happens when you run RA on Linux (the Wine part)

Wine is not an emulator. It re-implements the Windows API natively on
Linux. When RA calls `CreateWindowExA` or `BitBlt`, Wine has a Linux
implementation of that function which actually creates an X11 window or
calls `XPutImage`.

### Wine's builtin DirectDraw

Wine ships its own `ddraw.dll` implementation. By default, when RA loads
DirectDraw, Wine's builtin handler takes over and routes everything to
**wined3d** — Wine's translation layer from DirectX to OpenGL. wined3d
needs a real GL context, which needs a GPU (or at minimum a GLX-capable
X server with software GL).

Under Xvfb, none of that is available. So **we tell Wine to load a
different DLL named `ddraw.dll` instead of its own**. That's what this
environment variable does:

```
WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml="
```

- `ddraw=n` — load the **n**ative ddraw.dll (the one in the game's
  directory) instead of Wine's builtin.
- `mscoree=` and `mshtml=` — empty string means "don't load this DLL at
  all." These are .NET / HTML rendering DLLs RA tries to load for unused
  features; suppressing them avoids unnecessary errors.

So when RA imports `ddraw.dll`, Wine looks in the game directory, finds
the one we placed there (a copy of cnc-ddraw), and loads that. RA has no
idea this isn't Microsoft's DirectDraw.

### winex11.drv

This is the Wine module that converts GDI calls into X11 protocol. When
cnc-ddraw calls `BitBlt`, winex11.drv ultimately calls `XPutImage` on the
X server. We don't touch this layer — but it's the bridge between
"everything inside Wine is in Win32 terms" and "everything outside Wine is
X11."

---

## Part 3 — cnc-ddraw, a modern replacement for 1996 DDraw

[cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw) is an open-source
Win32 DLL written by the retro-gaming community (specifically the C&C
modding scene — hence the name). It exports the same C interface as
Microsoft's `ddraw.dll`, so any game that loads DirectDraw can load it
instead.

Internally, cnc-ddraw is straightforward:

1. **It pretends to be DirectDraw.** It implements the `IDirectDraw`,
   `IDirectDrawSurface`, etc. COM interfaces and accepts whatever cooperative
   level / display mode / surface size the game asks for.
2. **It allocates plain memory buffers** to back each "surface."
   Lock/Unlock just hand the game a pointer to that buffer.
3. **When the game flips,** cnc-ddraw converts the 8-bit indexed primary
   surface into 32-bit RGB (using the current palette as the lookup table)
   and `BitBlt`s the result onto its window's device context.
4. **`BitBlt` is implemented by Wine via winex11.drv**, which translates
   into `XPutImage` against the X11 window — and the pixels end up in
   Xvfb's framebuffer in RAM.

So cnc-ddraw replaces the GPU-dependent path entirely with a CPU
software-rendering path that just needs an X11 window. It works on any
display, including Xvfb with no GPU.

### The cnc-ddraw config (`ddraw.ini`)

cnc-ddraw reads `ddraw.ini` from the same directory as the DLL. The settings
we use:

```ini
[ddraw]
renderer=gdi      ; software path via Windows GDI (not OpenGL/D3D11)
windowed=true     ; force windowed even if the game asks for fullscreen
hook=0            ; don't install global Win32 hooks (we don't need them)
window_state=normal
maxfps=30         ; cap framerate (helps make captures more reproducible)

[ra95]
scanline_double=true  ; see below
```

### The TIM-740 `scanline_double` patch

We carry one local patch against upstream cnc-ddraw, vendored at
[`tools/cnc-ddraw/tim740-scanline-double.patch`](../tools/cnc-ddraw/tim740-scanline-double.patch).

RA's VQA cinematic player (and some gameplay paths) writes to a
"scanline-doubled" surface: it puts pixel data on every other row,
expecting the hardware to duplicate each row underneath. Real 1996 video
cards in mode-13h-style modes do that for free. cnc-ddraw doesn't, so
without the patch every other row stays at the zero-fill background colour
and the output looks like horizontal stripes of game-content / black.

The patch adds a small step right before each frame is rendered: if an odd
row is all-zero (and the even row above it is not), copy the even row
down. This restores the "scanline doubled" effect. Without this patch
captures look striped or wrong; with it they look like a real game.

The patch is applied automatically when the `cnc-ddraw` flake input
builds (`flake.nix` passes `patches = [ ... ]` to the derivation). If
someone ever bumps the cnc-ddraw upstream rev or rebuilds the DLL through
another path, **the patch must be re-applied** — there's a comment in
`flake.nix` flagging this, and we verify the md5 of the DLL in the
capture-comparison runs.

---

## Part 4 — X11 and where pixels actually land

### Xvfb (X virtual framebuffer)

Xvfb is an X11 server with no display device backing it. We start it like:

```
Xvfb :93 -screen 0 1024x768x24 -ac
```

That gives us display `:93`, with a single virtual screen 1024×768 pixels
deep 24-bit RGB. The framebuffer is just a chunk of process memory; you
can't see it on any monitor, but any X11 client can connect to `:93`, draw
into it, and read it back.

There's also an `openbox` window manager running on `:93`. It draws window
decorations and handles things like keyboard focus events. Without a WM,
the game window appears but never receives `WM_ACTIVATEAPP(1)`, which
matters for one of the patches below.

### Capturing the framebuffer

Three tools read Xvfb's framebuffer over the X11 protocol:

| Tool | How it reads | When you'd use it |
|---|---|---|
| `ffmpeg -f x11grab` | X11 `GetImage` request | Default; supports video as well as still frames |
| `import -window root` | Same `GetImage`, via ImageMagick | Fallback when `ffmpeg` is built without `x11grab` (some Nix builds) |
| `xwd -root` | Raw X11 protocol dump | Lowest-level capture; useful for diagnosing whether the framebuffer itself is wrong |

All three are reading the *same bytes* — just packaging them differently.
If all three produce the same wrong-looking PNG, the bug is upstream in
the pipeline (cnc-ddraw, Wine, RA) and not in the capture step itself.

---

## Part 5 — The binary patches (making RA play along)

RA95.EXE was built assuming a real Windows 95 desktop with a real CD-ROM,
a real video card, real keyboard focus, and an attached user clicking menu
items. Our capture pipeline has none of those. We patch the binary to
work around each missing piece.

Patches are applied by the unified `scripts/ra/patch_ra95.py` patcher. The base
mode applies the durable Wine setup patches; mission mode applies the capture
patches for one scenario. Old standalone `ra-*-patch.py` scripts remain as
temporary compatibility shims, but new capture code should use patch ids.

| Patch id | What it does | Why we need it |
|---|---|---|
| `nocd` | NOPs the `GetDriveType` CD-ROM check at game startup | We have no physical CD in the drive |
| `ddscl-normal` | Flips `DDSCL_EXCLUSIVE\|FULLSCREEN` to `DDSCL_NORMAL` at the two `SetCooperativeLevel` call sites | Forces a windowed surface so we get an X11 window we can capture from |
| `cd-label` | Selects the effective Allied/Soviet disc label bytes | Wine's empty-volume-label match against an empty CIFS mount only succeeds if the string we're matching against is also short |
| `focus-wait-skip` | NOPs three focus wait branches | Without a real WM session, `WM_ACTIVATEAPP(1)` is never delivered, so the waits run forever |
| `vqa-skip` | Replaces the first byte of `Play_Movie` with `RET` so it returns immediately | The VQA player blocks on audio-clock sync; with no real audio device under Wine, it hangs |
| `briefing-skip` | NOPs the text briefing `Restate_Mission` call | Missions without briefing VQAs otherwise block on a dialog before gameplay capture |
| `scenario` | Replaces hardcoded scenario strings (e.g. `SCG01EA` → `SCG02EA`) | Lets us pick which mission auto-launches without going through menus |
| `autostart` | Applies the `Select_Game()` and related startup patches that skip the main-menu / difficulty / faction dialogs | Zero-click boot directly into the chosen mission |
| `random-seed` | Replaces the startup random seed with a fixed value | Keeps Wine/native/WASM gameplay state deterministic for parity captures |
| `game-in-focus` | Quarantined: old patch path for a write now known to behave as `Session.Type`, not `GameInFocus` | Must not be used for normal captures; the unified patch id requires the quarantined guard, and the old standalone script refuses to run unless `RA_ALLOW_QUARANTINED_GAME_IN_FOCUS=1` is set for historical reproduction |

The unified patcher verifies each edit site before writing, records manifests,
and marks diagnostic or quarantined patch ids behind explicit allow flags.

### Why `ra-ddscl-patch.py` *only* touches the cooperative-level bytes

Earlier revisions of `ra-ddscl-patch.py` also stubbed
`SetDisplayMode(640,480,8)` to fake-return DD_OK without calling through.
That was correct for the wined3d path (Wine forwards `SetDisplayMode` to
`NtUserChangeDisplaySettings`, which Xvfb refuses, which the game treats
as fatal). But once the pipeline standardised on cnc-ddraw, **the stub
became actively harmful**: cnc-ddraw's `SetDisplayMode` interceptor needs
to *see* the call to size its X11-backed surface. With the stub, cnc-ddraw
never learned the surface needed to be 640×480, kept it at a default
smaller size, and the game's 640×480 frame data overflowed half-width
with mangled palette interpretation.

The current patch leaves `SetDisplayMode` intact. If you ever bring back
wined3d builtin as a supported path, you'll need a separate patch script
for the SDM stub.

---

## Part 6 — Debugging by layer (symptom → suspect)

When the wine capture comes out wrong, work the stack from the bottom up.

### "All-black PNG, exactly 1024×768"

The PNG container is the right size but the pixels are all zero.

- **Most likely:** the capture fired before the game had drawn anything
  yet. Check that `wait_for_window` in `scripts/drivers/common.py`
  returned true, and that the `frame_wait` sleep is long enough.
- **Also possible:** Xvfb is up but cnc-ddraw never put anything in the
  window. Check `wine.log` (in the session dir) for cnc-ddraw load
  messages; should see `Loaded L"…\\DDRAW.dll" at … : native`.

### "Window appears but is solid colour (white/grey/black)"

Wine created the window via winex11.drv, but the game never drew into it.

- **Suspect 1:** cnc-ddraw didn't load. Check `WINEDLLOVERRIDES` contains
  `ddraw=n` and that `ddraw.dll` is in the staging directory.
- **Suspect 2:** The game crashed during init. Check `wine.log` for an
  "Application Error" or `unhandled exception`.
- **Suspect 3:** A focus wait branch wasn't patched. Check that
  `focus-wait-skip` ran in the patch manifest.

### "Window appears, half-width content, palette mangled"

This is the SDM-stub regression signature. Geometry is right vertically
but content fills only the left 320 pixels of a 640-wide window; colours
look like green/magenta noise but with recognisable shapes.

- **Diagnosis:** cnc-ddraw never received `SetDisplayMode`. Surface is
  smaller than the game expects, so the framebuffer write overflows and
  ends up reinterpreted under a wrong palette.
- **Fix:** check the bytes at file offset `0x1a4a69` in the staged
  `RA95.EXE`. Should be `ff 53 54` (the original `call [ebx+0x54]`). If
  they're `31 c0 90` (`xor eax,eax; nop`), an old version of
  `ra-ddscl-patch.py` has been re-introduced.

### "Window appears, content rendered, but every other row is black"

Horizontal stripes of game pixels and zero-fill.

- **Diagnosis:** the TIM-740 scanline_double patch isn't in the
  cnc-ddraw build.
- **Fix:** check that `nix build .#cnc-ddraw` produces a DLL whose
  md5 matches the known-good patched build, and that
  `flake.nix` references `tools/cnc-ddraw/tim740-scanline-double.patch`
  in the derivation's `patches = [ ... ]` list.

### "Wine launches but no `Red Alert` window ever appears"

- **Suspect 1:** the EXE crashed before getting to `CreateWindow`.
  Common cause: a wrong-DLL load (e.g. the un-stubbed `THIPX32.DLL`
  trying to load a 16-bit thunk DLL Wine doesn't support). Use the stub
  THIPX32 from `tools/stub-thipx`.
- **Suspect 2:** `WINEDLLOVERRIDES` is wrong — Wine loaded its builtin
  ddraw, which routed through wined3d, which couldn't get a GL context,
  which silently failed. With cnc-ddraw correctly loaded you should never
  hit this.

### "Capture works but `ffmpeg` returns `Unknown input format: 'x11grab'`"

The Nix-built `ffmpeg-headless` derivation is sometimes built without
`x11grab` support. `scripts/drivers/common.py:capture_ffmpeg` falls back
to `import -window root` automatically in that case. If the fallback also
fails, check that ImageMagick is on PATH (`which import`).

### "Wine renders correctly but the SSIM-vs-native is low"

Sometimes the rendering is correct on both sides but the comparison
flags FAIL. That's a separate problem — capture timing, game-state
divergence between Wine and native, or a real rendering difference (the
native build's radar/sidebar may look different from cnc-ddraw's). Use
the parity-comparison skill's diff PNG to see *what* differs, not just
that something does.

---

## Further reading

- [`wine-headless-rendering.md`](./wine-headless-rendering.md) — the
  journey log: every approach we tried before settling on cnc-ddraw, with
  screenshots. Useful if you're tempted to try `renderer=gdi` (built-in)
  or `gamescope` again.
- [`AGENTS.md` § "Parity Investigation Workflow"](../AGENTS.md) — the
  capture-checkpoint pipeline from a tooling perspective: what commands
  to run, where artefacts land.
- [`skills/parity-comparison/SKILL.md`](../skills/parity-comparison/SKILL.md) —
  the parity-compare workflow: golden frames, three-way SSIM, the
  parity report.
- [`skills/wine-testing/SKILL.md`](../skills/wine-testing/SKILL.md) — the
  Wine-side skill, focused on getting captures to work in the first
  place (vs comparing them).
- `tools/cnc-ddraw/tim740-scanline-double.patch` — the vendored patch
  itself, with its own comments explaining the scanline-doubling logic
  inside `render_gdi.c`.
- The cnc-ddraw upstream README at
  https://github.com/FunkyFr3sh/cnc-ddraw — full config reference.
