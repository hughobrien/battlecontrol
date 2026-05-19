# Wine Headless Rendering: A Field Guide

*How to get a 1996 DirectDraw game (RA95.EXE) to render visible frames under
Wine + Xvfb without a physical GPU — and all the dead ends we stepped in.*

> 📖 **New to this stack?** Read
> [`wine-rendering-explainer.md`](./wine-rendering-explainer.md) first — it's a
> primer that explains every layer (DirectDraw concepts, Wine internals,
> cnc-ddraw, Xvfb, the binary patches) in plain English. This document is the
> journey log: the approaches we tried before settling on cnc-ddraw, and why
> each earlier one failed. Useful when something regresses and you're tempted
> to revisit a path we already ruled out.

---

## The Problem

RA95.EXE is a 1996 Win32 game that uses DirectDraw exclusively for rendering.
Under Wine, DirectDraw is implemented through **wined3d** — a Direct3D → OpenGL
translation layer. When wined3d cannot create an OpenGL context (no GPU, no GLX),
it falls back to a "no3d" adapter that creates surfaces with a **NULL draw_texture**.
The game's primary surface exists in system memory (Lock/Unlock work), but the
content is never copied to the visible X11 window — resulting in solid black
screenshots.

```
  Game → Lock/Unlock → sysmem surface ✓
  Game → Blit/Flip   → X11 visible window ✗  (no draw_texture → no-op)
  import -window root → all black           ✗  (640×480, 1-bit, 176 bytes)
```

The same issue affects **any headless rendering stack** where OpenGL is not
available: Xvfb, Xwayland+pixman, cage+headless, etc.

---

## Approaches Attempted

### 1. Xvfb + DDSCL patch (TIM-727)

**What:** Patch RA95.EXE's `SetCooperativeLevel` from `DDSCL_EXCLUSIVE|FULLSCREEN`
(0x11) to `DDSCL_NORMAL` (0x08) so the game requests a windowed surface.

Earlier revisions of this patch also stubbed `SetDisplayMode` to return `DD_OK`
without invoking `NtUserChangeDisplaySettings` (which Xvfb refuses). That was
needed under Wine's builtin ddraw. Once the pipeline standardised on cnc-ddraw
(approach 7), the stub became actively harmful — cnc-ddraw must receive the
`SetDisplayMode(640,480,8)` call to size its X11-backed surface; without it the
framebuffer is half-width and the palette is mangled. The current
`ra-ddscl-patch.py` therefore only changes the cooperative-level bytes.

**Result:** ❌ alone — GLX not available on Xvfb, so wined3d's no3d fallback
still produces NULL draw_textures. The DDSCL_NORMAL change is a prerequisite for
the cnc-ddraw pipeline (approach 7), not a fix on its own.

**Lesson:** A DDSCL change is necessary to get a windowed X11 surface; cnc-ddraw
provides the rest.

### 2. Xvfb + Mesa swrast DRI driver

**What:** Set `LIBGL_DRIVERS_PATH` to Mesa's DRI directory and
`MESA_LOADER_DRIVER_OVERRIDE=swrast` to provide software GL through Mesa's
software rasterizer.

**Result:** ❌ The Nixpkgs xorg-server (21.1.22) does not include the Mesa GLX
module (`libglx.so`). Without GLX on the server side, no amount of client-side
Mesa configuration helps. Xdpyinfo confirms GLX is absent.

**Lesson:** Xvfb needs a GLX extension module loaded at build time. The Nix
xorg-server is built without it.

### 3. Gamescope (Valve compositor)

**What:** Run gamescope with `--backend headless`, providing a software Vulkan
ICD (Mesa Lavapipe) so gamescope can composite.

**Result:** ❌ Lavapipe loads successfully (`selecting physical device 'llvmpipe
(LLVM 21.1.8, 256 bits)'`), but gamescope requires `VK_EXT_physical_device_drm`
for buffer sharing with Xwayland — a Vulkan extension that software
implementations (Lavapipe, SwiftShader) don't provide because there's no real
DRM device.

**Lesson:** Gamescope's buffer sharing requires a DRM-backed Vulkan device.
Software Vulkan cannot provide this.

### 4. Cage (wlroots compositor) + Xwayland

**What:** Run cage with `WLR_BACKENDS=headless`, start Xwayland inside cage as
its Wayland client, then route RA95.EXE through Xwayland's X11 display.

**Result:** ❌ Cage falls back to pixman renderer (no DRM render node). Xwayland
falls back to `sw` software rendering (no glamor). GLX is advertised by xdpyinfo
but Wine's wgl implementation cannot find a suitable pixel format — the pixman
GLX stub provides the extension name but not the depth/stencil/accum pixel format
features that wined3d requires.

**Lesson:** Software GLX stubs advertise the extension but can't support the
pixel formats wgl needs. Cage and Xwayland need a GBM-backed DRM device for
proper GL support.

### 5. Sway (wlroots compositor) + Xwayland

**What:** Same approach as cage, using the system-installed sway (a more mature
wlroots compositor) with headless backend.

**Result:** ❌ Sway ran and Xwayland provided GLX, but Wine still failed with
`Failed to find a suitable pixel format`. Same fundamental problem as cage —
no DRM render node, no proper GL.

**Lesson:** The compositor doesn't matter. Without a DRM render node, all
wlroots compositors fall back to pixman, and Xwayland's GLX stub is too limited
for wined3d.

### 6. Mesa llvmpipe (Gallium driver)

**What:** Set `GALLIUM_DRIVER=llvmpipe` and `MESA_GL_VERSION_OVERRIDE=3.3` to
force Mesa's LLVM-based software GL renderer.

**Result:** ❌ Same pixel format failure. The Mesa software GL libraries exist
but the X server's GLX extension (whether Xvfb or Xwayland) doesn't expose the
pixel format capabilities that wgl queries.

**Lesson:** Software GL rendering requires a GLX extension that supports the
full pixel format feature set. Neither Xvfb nor Xwayland's software fallback
provides this.

### 7. cnc-ddraw (native ddraw.dll replacement) ✅

**What:** Replace Wine's builtin ddraw (which depends on wined3d) with
cnc-ddraw — a MinGW-compiled Win32 DLL that intercepts DirectDraw calls and
renders directly using Windows GDI. Wine translates GDI calls to X11 via
winex11.drv, producing visible window content.

**Result:** ✅ Working screenshots under plain Xvfb, no GPU required. The
screenshot pipeline becomes:

```
  Game → DirectDraw → cnc-ddraw → GDI → Wine → XPutImage → X11 window
  import -window root → 640×480 RGB image with real content ✓
```

Screenshots are 3496 bytes for mostly-uniform frames, growing to larger sizes
as the game renders more complex content. All that's needed is:
- `DDRAW.DLL` from cnc-ddraw in the game directory (built from the flake with
  the TIM-740 `scanline_double` patch applied — see
  `tools/cnc-ddraw/tim740-scanline-double.patch`; without it every other physical
  row stays at the zero-fill background colour for RA95's VQA player output)
- A working Xvfb display
- The stub THIPX32.DLL (for Wine 11.0 wow64 compatibility)
- The `.#ra-patched-exe` (NoCD + DDSCL_NORMAL coop + cdlabel) RA95.EXE

**Lesson:** When wined3d can't work, bypass it entirely. cnc-ddraw is a complete
DirectDraw implementation that uses GDI instead of 3D, rendering correctly on
any X server — even Xvfb without a GPU. The Wine OG capture pipeline is now
standardised on cnc-ddraw; the wined3d builtin path is unsupported.

---

## Quick Start (the working approach)

```bash
# Via capture-checkpoint (recommended):
python3 scripts/capture-checkpoint.py mission allied-l1 --targets wine

# Via parity orchestrator (capture + compare):
nix run .#parity -- check allied-l1
```

This downloads the Allied CD ISO from archive.org (653 MB, cached by Nix),
extracts and patches RA95.EXE, extracts MIX data, builds cnc-ddraw, creates
a Wine prefix, starts Xvfb, and captures timed screenshots of the game menu.

---

## Key Technical Insights

### Why wined3d always needs GL

Wine's `ddraw.dll` depends on `wined3d.dll`. Even when
`DirectDrawRenderer=gdi` is set in the registry, wined3d still creates a
wined3d device and attempts to allocate draw textures. Without a GL context,
the draw texture allocation fails (`DDERR_OUTOFVIDEOMEMORY`, 0x8876086a),
resulting in a surface with `draw_texture=NULL`. The surface exists in system
memory (Lock/Unlock work) but has no GPU-side backing store to present to the
screen.

### Why GLX can't be provided in software

Modern X servers (Xorg, Xvfb, Xwayland) implement GLX as a loadable module
that delegates to the Mesa DRI driver. The DRI driver needs a DRM render node
(`/dev/dri/renderD128`) to allocate GPU buffers. Without a physical GPU, there
is no DRM render node. Mesa's software rasterizers (swrast, llvmpipe) can
provide GL contexts through EGL or GBM, but these paths still require a DRM
render node for buffer allocation.

The wlroots compositors (cage, sway) fall back to pixman software rendering
when no DRM render node is available. Pixman supports basic 2D compositing but
does not provide the GL pixel format capabilities that wined3d's wgl
initialization queries.

### Why cnc-ddraw works

cnc-ddraw is a Win32 DLL that replaces DirectDraw entirely. It:
1. Intercepts `IDirectDraw*`, `IDirectDrawSurface*`, etc.
2. Creates a Win32 window and renders into it using GDI (`BitBlt`, `StretchBlt`)
3. Wine's winex11.drv translates GDI calls directly to X11 (`XPutImage`)
4. No GL, no wined3d, no draw_texture needed

The key difference: GDI rendering goes through Wine's well-tested X11 driver
path that works on any X server, including Xvfb.

---

## Diagnostic Heuristics: Screenshot File Sizes

When investigating whether the game is rendering correctly, the PNG file size
of the captured screenshot is a surprisingly reliable diagnostic signal.

| Size | Mode | Colors | Interpretation |
|-----:|:----:|:------:|----------------|
| **176 B** | 1-bit | 1 (black) | wined3d no3d mode with NULL draw_texture.
| | | | The surface exists but is never copied to
| | | | the visible X11 window. All black. |
| **3.5 KB** | RGB | ~470 | cnc-ddraw loaded but game stuck on error
| | | | dialog ("unable to allocate primary video
| | | | buffer"). Gray window frame + orange
| | | | warning icon. |
| **4.9 KB** | RGB | ~470 | Windows dialog box with gray gradient.
| | | | Game asking "Please insert CD" or similar
| | | | blocking dialog. |
| **7.2 KB** | P | ~42 | 8-bit paletted mode active, RA dark navy
| | | | background visible. Game running but
| | | | stuck on CD check dialog. |
| **24-29 KB** | P | ~80-100 | More content: white text, gray UI
| | | | elements. Game progressing through
| | | | screens but not fully rendering. |
| **47-88 KB** | P | 117-177 | **Real game content.** Palette mode with
| | | | the full RA palette. 88KB = loading
| | | | screen, 47KB = main menu. |
| **100+ KB** | P | 256 | Full game rendering with terrain, units,
| | | | buildings. Gameplay screenshots. |

**Quick rule of thumb:** anything under 10 KB is likely a dialog or error.
Over 30 KB in paletted mode = the game is rendering real content.
Over 80 KB = full graphics rendering.

---

## Reference: Tool Versions

| Component | Version | Source |
|-----------|---------|--------|
| Wine | 10.0 | Nixpkgs (nixos-unstable) |
| RA95.EXE | Allied CD ISO (archive.org) | DDSCL+NoCD patched |
| cnc-ddraw | a0b81b1 (upstream) | Nix flake input (github:FunkyFr3sh/cnc-ddraw) |
| Xvfb | 21.1.21 | Nixpkgs (nixos-unstable) |
| Mesa | 26.1.0 | Nixpkgs (nixos-unstable) |
