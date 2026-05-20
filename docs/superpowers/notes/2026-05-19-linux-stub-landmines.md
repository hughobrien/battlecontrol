# Linux stub landmines — 2026-05-19 survey

Sources surveyed: `linux/win32-stubs/wwlib-asm-stub.cpp`,
`linux/win32-stubs/blit-helpers.h`, `linux/td-win32-stubs.cpp`,
plus targeted reads of callers in `REDALERT/` and `TIBERIANDAWN/`.

---

## Confirmed parity bugs (visible in capture or game behaviour)

- ### SHAPE_GHOST translucency — `linux/win32-stubs/blit-helpers.h:48`, `wwlib-asm-stub.cpp:234`

  **Symptom (user-reported):** Unit shadows render as solid-coloured blobs
  instead of semi-transparent darkening — observed as green-bordered outlines,
  "green shadows", staggered/banded fog-of-war shading, and green tile outlines
  in the lower-right area of mission-allied-l1.  All four complaints are
  consistent with a single root cause.

  **Cause:** `SHAPE_GHOST` (bit `0x1000`) is explicitly listed as "Ignored
  (cosmetic, future pass)" in the comment above `Buffer_Frame_To_Page`.
  `decode_shape_blit_args` pops the `ghost_table` pointer from the vararg
  stream (so cursor positioning stays correct for subsequent args) but never
  uses it.  The original KEYFBUFF.ASM ghost path did a 2D translucency lookup:
  for each destination pixel, `ghostdata[dest_pixel]` produced the blended
  output colour.  Without this, non-transparent shape pixels are stamped
  opaque with whatever palette index they carry — which for `SHADOW.SHP` and
  `ShadowTrans` produces whatever colour occupies that index in the current
  palette (reportedly a shade of green in the temperate set).

  **Affected callers (both RA and TD):**
  - `DISPLAY.CPP` — `CC_Draw_Shape(ShadowShapes, shadow, …, SHAPE_GHOST, NULL, ShadowTrans)` — unit ground shadows.
  - `TECHNO.CPP` — `SHAPE_CENTER|SHAPE_WIN_REL|SHAPE_FADING|SHAPE_GHOST` — all units/buildings with house-colour remap + shadow simultaneously.
  - `TERRAIN.CPP` — `flags|SHAPE_WIN_REL|SHAPE_GHOST` — terrain objects.
  - `CELL.CPP` — `SHAPE_CENTER|SHAPE_WIN_REL|SHAPE_GHOST` — overlays.
  - `ANIM.CPP`, `BULLET.CPP`, `AIRCRAFT.CPP` — various effect sprites.
  - `SIDEBAR.CPP` — construction-yard clock animation.

  **Fix sketch:** Implement a ghosting pass in `blit_row`: for each pixel,
  if ghost_table is non-null and `SHAPE_GHOST` is set, write
  `ghost_table[256 + dest_pixel]` for opaque shape pixels and
  `ghost_table[dest_pixel]` for transparent ones (matching KEYFBUFF.ASM
  semantics). Requires `blit_row` to receive a `dst` read pointer as well.

  **Priority:** high — directly responsible for the green shadow / staggered
  fog / green tile outline bugs already observed in capture.


- ### SHAPE_PREDATOR warp — `linux/win32-stubs/blit-helpers.h:55`, `wwlib-asm-stub.cpp:234`

  **Symptom:** Stealth units (Nod Recon Bike cloaked, RA submarines, ion-storm
  vortex) are drawn opaque or with SHAPE_FADING only, instead of the
  wavy/distorted "predator" effect. Also aircraft drawn with
  `SHAPE_PREDATOR|SHAPE_FADING` miss the warp.

  **Cause:** `pred_offset` is popped from varargs and discarded.  The original
  ASM used it to horizontally jitter rows on alternating frames, producing the
  shimmer.

  **Affected callers:** `TECHNO.CPP:3440–3506` (RA + TD), `AIRCRAFT.CPP:404–437`,
  `BULLET.CPP:549`, `VORTEX.CPP:959–971`.

  **Fix sketch:** After the main blit, do a second pass that shifts alternating
  rows by ±`pred_offset` pixels, sourcing from adjacent destination columns
  (wrapping at viewport boundary). Pure C++, no ASM required.

  **Priority:** medium — cosmetic, but noticeably wrong for cloaked units.

---

## Likely-latent (no visible bug yet, but stub omits real behaviour)

- ### `Build_Fading_Table` returning nullptr — `linux/td-win32-stubs.cpp:1261`

  **Behaviour omitted:** Fills a 256-byte LUT mapping each palette index to the
  nearest colour in the direction of a target hue at a given fraction.  Used to
  build `FadingGreen`, `FadingYellow`, `FadingRed`, and `FadingBrighten` tables
  in `TIBERIANDAWN/DISPLAY.CPP:455–538`.

  **Why no bug shows up (usually):**
  1. `FadingGreen`, `FadingYellow`, `FadingRed` are only applied when
     `Debug_Passable` is set (`CELL.CPP:957–968`), a debug-only flag.
  2. `FadingBrighten` is passed to `_IconStage.Scale()` in `RADAR.CPP:556,648`
     — but `Buffer_To_Page` (used to populate `_IconStage`) is itself a null
     stub (`td-win32-stubs.cpp:1110`), so the minimap icons that would be
     brightened are already wrong/blank.
  3. `Conquer_Build_Fading_Table` (the variant for `FadingShade`, `FadingLight`,
     `SpecialGhost[256..]`) is **real** C++ in `TIBERIANDAWN/JSHELL.CPP:409` —
     those tables are correctly populated.

  **Risk:** Enabling `Debug_Passable` produces all-black passability overlays.
  Minimap brightening is masked by the `Buffer_To_Page` stub; fixing that stub
  will immediately expose broken `FadingBrighten`.

- ### `Uncompress_Data` returning 0 — `linux/td-win32-stubs.cpp:1242`

  **Behaviour omitted:** LZW decompressor used by `JSHELL.CPP:264` to
  decompress font/shape blocks loaded from mix files.

  **Why no bug shows up:** `JSHELL.CPP:264` (`Load_Font`) is called during
  startup; if `Uncompress_Data` returns 0, the font load fails silently —
  but the TD Linux port uses its own font-rendering path (`TIM-464`) that
  bypasses this code path.

  **Risk:** Any code path that uses raw Westwood LZW-compressed data outside
  the TD font system (e.g. loading a `.SHP` that was LZW-not-LCW compressed)
  will silently produce empty output.

- ### `Extract_Shape` returning nullptr — `linux/td-win32-stubs.cpp:1244`

  **Behaviour omitted:** Indexes into a shape block to return a pointer to
  frame N.  Used for mouse cursors in `INIT.CPP:255` and `MOUSE.CPP:116–225`.

  **Why no bug shows up:** The TD Linux port uses SDL cursor handling; the
  `Set_Mouse_Cursor` calls that consume the `Extract_Shape` result appear to
  be dormant (the SDL path overrides them).

  **Risk:** If `Set_Mouse_Cursor` is ever re-wired to the software renderer
  path, cursors will display nothing (null pointer dereference risk).

- ### `Open_Animation` / `Animate_Frame` / `Close_Animation` — `linux/td-win32-stubs.cpp:1288–1291`

  **Behaviour omitted:** WSA animation playback (`.WSA` files).  Used by
  `INTRO.CPP:139`, `MAPSEL.CPP:280–640` (campaign map selection globe),
  `SCORE.CPP:641–725` (mission debrief animations).

  **Why no bug shows up:** The game routes cinematic VQA playback through
  `Play_Movie_Linux` (implemented at TIM-682).  WSA is a separate format
  used for in-engine looping animations (campaign globe, score screen). The
  score screen and campaign map screen currently show static/blank where the
  animation would be.

  **Risk:** This is a visible deficiency — campaign globe and score screen
  animations are silently absent.  Not a crash risk but a clear regression
  vs Wine.

- ### `Get_Icon_Set_Map` returning nullptr — `linux/td-win32-stubs.cpp:1260`

  **Behaviour omitted:** Returns a pointer to the icon-to-template mapping
  table embedded in an icon set, used to validate which tiles are passable.

  **Why no bug shows up:**
  - `MAP.CPP:695,784` guard on `if (rawmap)` — returns early if null.
  - `MAP.CPP:1178` is inside `#if (0)` (dead code).

  **Risk:** Passability validation for templates is silently skipped.  This
  could cause units to navigate through impassable terrain cells that happen
  to lack a proper icon-set map.  Needs investigation when pathfinding
  discrepancies are observed.

- ### `Build_Fading_Table` (TD) also affects `JSHELL.CPP:374` — `linux/td-win32-stubs.cpp:1261`

  **Behaviour omitted:** `JSHELL.CPP:374` calls `Build_Fading_Table` to build
  per-colour fade tables for the font-colouring system (health bars, sidebar
  text in various colours).

  **Why no bug shows up:** `Conquer_Build_Fading_Table` at line 428 covers
  the fading steps actually used in-game; the `Build_Fading_Table` call at
  line 374 is for a different (non-Conquer) colour-matching step that is
  apparently not exercised in the current test scenarios.

  **Risk:** Sidebar or HUD colour-ramp effects may be wrong when exercised.

- ### `LCW_Uncompress` returning 0 — `linux/td-win32-stubs.cpp:1193`

  **Behaviour omitted:** LCW (RLE) decompressor used by `KEYFRAME.CPP` (shape
  frame decoding) and `WIN32LIB/WSA.CPP` (WSA animation frames).

  **Why no bug shows up:** `KEYFRAME.CPP:422–425` contains an explicit
  comment: "Apply_XOR_Delta is a no-op stub on Linux; replace with
  LCW_Uncompress directly."  The LCW path IS called for keyframe shapes —
  but the shapes still render, suggesting the uncompressed data is stored
  inline for the subset of shapes actually used, or the `BigShapeBuffer`
  path bypasses LCW.  This needs a closer look.

  **Risk:** If any shape is LCW-compressed (not raw), it will render as
  blank. Silently wrong, no crash.

- ### `Buffer_To_Buffer` / `Buffer_Print` returning 0 — `linux/td-win32-stubs.cpp:1198–1199`

  **Behaviour omitted:** Viewport-to-viewport blit and in-buffer text print.

  **Why no bug shows up:** Active draw paths use `Buffer_Frame_To_Page`
  (implemented) and SDL blits.  `Buffer_Print` appears dormant in the
  current gameplay path.

  **Risk:** Any code path that routes text through `Buffer_Print` will
  silently drop it.

- ### `winsock.h` — async hostname resolution — `linux/win32-stubs/winsock.h:532–536`

  **Behaviour omitted:** `WSAAsyncGetHostByName` / `WSAAsyncGetHostByAddr`
  stubs do not fire the `WM_HOSTBYNAME` / `WM_HOSTBYADDRESS` callbacks that
  `TCPIP.CPP` polls for.

  **Why no bug shows up:** Multiplayer is entirely dormant in the current
  Linux runnable subset (no WinsockInterfaceClass active sessions).

  **Risk:** When multiplayer is revisited, connect-by-hostname will silently
  hang or time out. Needs a real `getaddrinfo()`-driven resolver wired to
  SDL_USEREVENT.

---

## Intentional no-ops (verified safe)

- ### `LCW_Comp` returning 0 — `linux/win32-stubs/wwlib-asm-stub.cpp:289–291`

  **Reason no-op is correct:** The comment documents this precisely: "Returning
  0 (no bytes written) keeps callers from emitting a corrupt stream into a real
  file; in practice these call sites are guarded by code paths that won't fire
  under the current runnable subset." Save-game writing is not exercised.

- ### `Processor` returning 0 — `linux/win32-stubs/wwlib-asm-stub.cpp:294–300`

  **Reason no-op is correct:** `INIT.CPP` gates `Benchmark` allocation on
  `Processor() >= 2`.  Returning 0 keeps `Benches` NULL so `BStart`/`BEnd`
  remain no-ops. No Benchmark objects are ever allocated. Intentional.

- ### `IconCacheClass` no-ops — `linux/td-win32-stubs.cpp:1302–1326`

  **Reason no-op is correct:** The icon cache was a DirectDraw surface cache
  for Windows hardware acceleration.  The Linux port uses SDL software rendering;
  `IconCacheAllowed = FALSE` prevents the cache paths from being entered.
  `Draw_It` would only be called on a cached icon; since `Cache_It` always
  returns FALSE, no icon is ever cached.

- ### `SurfaceMonitorClass` no-ops — `linux/td-win32-stubs.cpp:1333–1339`

  **Reason no-op is correct:** DirectDraw surface loss/restore was a Windows
  98-era concern. The Linux SDL2 renderer never loses surfaces.

- ### `Apply_XOR_Delta` no-op — `linux/td-win32-stubs.cpp:1194`

  **Reason no-op is correct:** `KEYFRAME.CPP:422–425` documents this
  explicitly: XOR delta frames are re-routed to `LCW_Uncompress` on Linux
  (the shape pipeline stores full frames in `BigShapeBuffer` slots rather than
  applying XOR deltas on top of a prior frame). The no-op is load-bearing here
  only as a fallback — if any frame actually reaches `Apply_XOR_Delta` without
  being intercepted, it silently corrupts that shape slot. See the LCW_Uncompress
  latent risk above.

- ### `Empty-placeholder` headers (dos.h, oleidl.h, ole2.h, etc.) — `linux/win32-stubs/*.h`

  **Reason no-op is correct:** These headers exist only so `#include` resolves.
  No symbols from them are actually referenced at link time (confirmed by
  TIM-840 audit). Verified safe.

---

## Road tiles don't line up — investigation note

The user-observed "road tiles don't line up" bug does **not** obviously
map to any of the above stubs.  `Buffer_Draw_Stamp` and
`Buffer_Draw_Stamp_Clip` are real implementations (since TIM-419), including
an LP64-safe `IControl_Disk` struct.  The clip-coordinate comment in
`td-win32-stubs.cpp:1185–1188` is a potential concern:

```
// WindowList WINDOWX/WINDOWWIDTH in 8-pixel units; WINDOWY/WINDOWHEIGHT in pixels.
int clip_x0 = min_x << 3;
int clip_x1 = (min_x + max_x) << 3;
```

If the caller passes pixel-unit coordinates rather than 8-pixel-unit columns,
the clip window will be 8× wider than intended, which would produce misaligned
or over-blitted icons.  The calling convention for `Buffer_Draw_Stamp_Clip`
needs to be traced from `CELL.CPP` through `GraphicViewPortClass::Draw_Stamp`
to verify the unit assumption.  This is the most plausible stub-adjacent cause
of road tile misalignment and should be the first investigation target.

Alternatively, the misalignment may be a template-type / cell-coordinate offset
bug unrelated to stubs — needs a dedicated capture diff against Wine.
