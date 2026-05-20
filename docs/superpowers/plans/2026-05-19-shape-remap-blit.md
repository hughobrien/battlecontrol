# Linux Shape Remap Blit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native Linux builds (RA + TD) must render unit sprites with the correct house remap colours (blue Allied, red Soviet) instead of unremapped yellow base sprites — matching the wine OG output.

**Architecture:** The Linux blitter stubs at `linux/win32-stubs/wwlib-asm-stub.cpp` (RA) and `linux/td-win32-stubs.cpp` (TD) reimplement the original `KEYFBUFF.ASM` `Buffer_Frame_To_Page` in portable C++, but currently drop the variadic remap / fade / ghost / predator arguments. CC_Draw_Shape passes a 256-byte LUT (the unit's house-colour remap) via varargs when `SHAPE_FADING` is set; without LUT application, unit sprites blit in their raw palette and read as yellow.

Fix: parse the varargs in the documented `GHOST → FADING(table+count) → PREDATOR(offset)` order (per `REDALERT/KEYFBUFF.ASM:1294-1411`), apply the fade/remap LUT to each source pixel when `SHAPE_FADING` is set, leave `SHAPE_GHOST`/`SHAPE_PREDATOR` as explicit-no-op (with a one-line comment) since they're cosmetic and out of scope. Factor the row-blit helper into a shared header so RA and TD share one implementation.

**Tech Stack:** C++14 (matches surrounding stub code), `<cstdarg>`, no new deps. Build via existing `cmake --preset linux-native`. Verification via existing `scripts/capture-checkpoint.py` capture pipeline + SSIM comparison from `scripts/parity-compare.py`.

**Out of scope (explicit TODO, do not implement here):**
- SHAPE_GHOST translucency blending (cosmetic — shadows, ghosting)
- SHAPE_PREDATOR warp effect (cosmetic — stealth tank distortion)
- fade_count > 1 (used by special darken effects; nearly all unit blits pass count=1)
- Any change to `CC_Draw_Shape` itself or its callers

**Testing strategy:** No unit-test infra exists for `Buffer_Frame_To_Page` (it requires `GraphicViewPortClass` + the shape buffer pipeline). Primary verification is end-to-end via the capture pipeline: re-run `scripts/capture-checkpoint.py mission allied-l1 --frame 50` and confirm (a) SSIM jumps significantly above the current 0.2056 baseline and (b) visual inspection of `native.png` shows blue Allied units / red Soviet conscript matching `wine.png`.

---

## File Structure

- **Create:** `linux/win32-stubs/blit-helpers.h` — shared inline helpers (`decode_shape_blit_args`, `blit_row`). Both stubs include this.
- **Modify:** `linux/win32-stubs/wwlib-asm-stub.cpp:227-277` — replace the body of `Buffer_Frame_To_Page` with a call to the shared helpers.
- **Modify:** `linux/td-win32-stubs.cpp:1200-1224` — same change in the TD copy.
- **Modify:** `CMakeLists.txt` *(only if needed — check first)* — verify `blit-helpers.h` is picked up by the existing include path; both stubs already live under `linux/win32-stubs/` / `linux/` so an include should resolve without CMake changes.

---

## Task 1: Add shared blit-helpers header

**Files:**
- Create: `linux/win32-stubs/blit-helpers.h`

The header provides two inline functions used by both RA and TD `Buffer_Frame_To_Page` implementations.

- [ ] **Step 1: Create the header file**

Write this exact content to `linux/win32-stubs/blit-helpers.h`:

```cpp
// linux/win32-stubs/blit-helpers.h
//
// Portable replacements for the variadic-argument decoding and row blit
// originally done by REDALERT/KEYFBUFF.ASM. Shared between the RA and TD
// Linux win32 stubs so both builds apply unit house-colour remap correctly.
//
// Varargs order per KEYFBUFF.ASM:1294-1411:
//   if (flags & SHAPE_GHOST)    pop void*  ghost_table
//   if (flags & SHAPE_FADING)   pop void*  fade_table  (often == house remap LUT)
//                               pop int    fade_count  (LUT applications, usually 1)
//   if (flags & SHAPE_PREDATOR) pop int    pred_offset
//
// Only SHAPE_FADING is honoured in this pass. Ghost/Predator args are popped
// for correct vararg cursor positioning but their effects are not implemented.

#ifndef LINUX_WIN32_STUBS_BLIT_HELPERS_H
#define LINUX_WIN32_STUBS_BLIT_HELPERS_H

#include <cstdarg>
#include <cstring>

// Match the flag bits from REDALERT/WIN32LIB/SHAPE.H so we don't depend on
// that header being in the include path of the stub TU. Underlying type
// matches ShapeFlags_Type (unsigned short) from SHAPE.H.
enum : unsigned short {
    BFTP_SHAPE_CENTER   = 0x0020,
    // Bit 0x40 is overloaded: SHAPE.H:76 names it SHAPE_BOTTOM (Y-anchor),
    // CONQUER.CPP:141 redefines it as SHAPE_TRANS (skip colour-0). The
    // blitter only ever sees the SHAPE_TRANS meaning — Y-anchor is resolved
    // upstream in CC_Draw_Shape before this function is called.
    BFTP_SHAPE_TRANS    = 0x0040,
    BFTP_SHAPE_FADING   = 0x0100,
    BFTP_SHAPE_PREDATOR = 0x0200,
    BFTP_SHAPE_GHOST    = 0x1000,
};

struct BlitArgs {
    const unsigned char *remap;   // 256-byte LUT, NULL if SHAPE_FADING not set
    int                  fade_count;
};

// Pop the variadic args declared after `flags`. Caller already did va_start.
// Caller is responsible for va_end.
inline BlitArgs decode_shape_blit_args(int flags, va_list args)
{
    BlitArgs out{ nullptr, 0 };
    if (flags & BFTP_SHAPE_GHOST) {
        (void)va_arg(args, void *);  // ghost_table — unhandled this pass
    }
    if (flags & BFTP_SHAPE_FADING) {
        out.remap      = static_cast<const unsigned char *>(va_arg(args, void *));
        out.fade_count = va_arg(args, int);
    }
    if (flags & BFTP_SHAPE_PREDATOR) {
        (void)va_arg(args, int);     // pred_offset — unhandled this pass
    }
    return out;
}

// Blit one row of `dw` bytes from `src` to `dst`.
//   trans       — true means skip colour-0 (transparent palette index)
//   remap       — optional 256-byte LUT; if non-null, each src pixel is
//                 substituted via remap[p] (fade_count times)
//   fade_count  — number of LUT applications; clamp to >= 0
inline void blit_row(unsigned char       *dst,
                     const unsigned char *src,
                     int                  dw,
                     bool                 trans,
                     const unsigned char *remap,
                     int                  fade_count)
{
    if (remap == nullptr || fade_count <= 0) {
        if (trans) {
            for (int col = 0; col < dw; col++) {
                unsigned char p = src[col];
                if (p) dst[col] = p;
            }
        } else {
            std::memcpy(dst, src, static_cast<size_t>(dw));
        }
        return;
    }

    // Cap fade_count defensively — original ASM masks with 0x3f.
    if (fade_count > 63) fade_count = 63;

    for (int col = 0; col < dw; col++) {
        unsigned char p = src[col];
        if (trans && p == 0) continue;
        for (int i = 0; i < fade_count; i++) p = remap[p];
        dst[col] = p;
    }
}

#endif  // LINUX_WIN32_STUBS_BLIT_HELPERS_H
```

- [ ] **Step 2: Verify the header compiles standalone**

The header is `inline`-only and has no `.cpp`. Confirm it parses cleanly with the project compiler:

```bash
clang++ -std=c++14 -fsyntax-only -x c++ linux/win32-stubs/blit-helpers.h
```

Expected: no output (success). If the project uses `g++`, substitute accordingly.

---

## Task 2: Wire RA stub to use the helpers

**Files:**
- Modify: `linux/win32-stubs/wwlib-asm-stub.cpp` (function body at lines 231-277, plus a new `#include` near the existing includes at top)

- [ ] **Step 1: Add the helper include**

At the top of `linux/win32-stubs/wwlib-asm-stub.cpp`, alongside the existing `#include` lines (look near line 1-20 of the file — it currently includes `<cstring>` or similar), add:

```cpp
#include "blit-helpers.h"
```

(Both files are in `linux/win32-stubs/`, so a relative include works without CMake changes.)

- [ ] **Step 2: Replace the function body**

Replace the existing function body (current lines 227-277, starting at the `// FUNCTION.H — shape blit from BigShapeBuffer ...` comment block and ending at the closing `}` of `Buffer_Frame_To_Page`) with:

```cpp
// FUNCTION.H — shape blit from BigShapeBuffer into a GraphicViewPort.
// Replaces the original x86 KEYFBUFF.ASM routine with portable C++.
// Honoured flags:
//   SHAPE_CENTER (0x0020) — anchor at shape centre.
//   SHAPE_TRANS  (0x0040) — skip colour-0 pixels.
//   SHAPE_FADING (0x0100) — apply 256-byte LUT (house remap or fade table).
// Ignored (cosmetic, future pass):
//   SHAPE_GHOST  (0x1000) — translucency blending.
//   SHAPE_PREDATOR (0x0200) — warping/stealth effect.
// Vararg order matches KEYFBUFF.ASM:1294-1411 (decoded in blit-helpers.h).
long Buffer_Frame_To_Page(int x, int y, int w, int h,
                          void *src, GraphicViewPortClass &dest,
                          int flags, ...)
{
    if (!src || w <= 0 || h <= 0) return 0;

    const unsigned char *pixels;
    if (UseBigShapeBuffer) {
        ShapeHdr *hdr = (ShapeHdr*)src;
        const char *base = hdr->shape_buffer ? TheaterShapeBufferStart : BigShapeBufferStart;
        if (!base) return 0;
        pixels = (const unsigned char*)(hdr->shape_data + (long)base);
    } else {
        pixels = (const unsigned char*)src;
    }
    if (!pixels) return 0;

    if (flags & BFTP_SHAPE_CENTER) { x -= w / 2; y -= h / 2; }

    int vw     = dest.Get_Width();
    int vh     = dest.Get_Height();
    int stride = vw + dest.Get_XAdd() + dest.Get_Pitch();

    int sx0 = 0, sy0 = 0, dw = w, dh = h;
    if (x < 0)        { sx0 = -x;    dw += x;    x = 0; }
    if (y < 0)        { sy0 = -y;    dh += y;    y = 0; }
    if (x + dw > vw)  { dw = vw - x; }
    if (y + dh > vh)  { dh = vh - y; }
    if (dw <= 0 || dh <= 0) return 0;

    va_list args;
    va_start(args, flags);
    BlitArgs ba = decode_shape_blit_args(flags, args);
    va_end(args);

    unsigned char *dst_base = (unsigned char*)dest.Get_Offset();
    const bool trans = (flags & BFTP_SHAPE_TRANS) != 0;

    for (int row = 0; row < dh; row++) {
        const unsigned char *srow = pixels   + static_cast<ptrdiff_t>(sy0 + row) * w      + sx0;
        unsigned char       *drow = dst_base + static_cast<ptrdiff_t>(y   + row) * stride + x;
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count);
    }
    return 1;
}
```

Note: the existing `0x0020` / `0x0040` magic-numbers are replaced by `BFTP_SHAPE_CENTER` / `BFTP_SHAPE_TRANS` from the helper header. The `static_cast<ptrdiff_t>` on the multiplied operand prevents `bugprone-implicit-widening-of-multiplication-result` — the surrounding pre-existing stub code has the same pattern but is out of scope. Leave all other code in the file (Buffer_Print, LCW_Comp, Processor) untouched.

---

## Task 3: Build RA and verify it compiles

**Files:** none (build-only)

- [ ] **Step 1: Build the RA target**

```bash
bash scripts/build-native.sh ra
```

Expected: configure step prints "Configuring native Linux build", build step prints "Building RA", then ninja completes with "[N/N] ..." and no errors. The script's "Validating binaries" section should report ELF 64-bit.

- [ ] **Step 2: If the build fails, do not proceed**

Common failure modes and remediation:
- *Missing `va_list` / `va_start`*: ensure `<cstdarg>` is included via `blit-helpers.h` (it is — confirm the include line was added at Task 2 Step 1).
- *Unknown identifier `BFTP_SHAPE_*`*: the `#include "blit-helpers.h"` line is missing from `wwlib-asm-stub.cpp`. Re-do Task 2 Step 1.
- *Header not found*: confirm the relative path. Both files live in `linux/win32-stubs/`; the include should be `#include "blit-helpers.h"` not `#include <blit-helpers.h>`.

Fix the underlying issue, rebuild, then continue.

---

## Task 4: Re-capture mission-allied-l1 and visually verify RA

**Files:** none (capture-and-compare)

- [ ] **Step 1: Trigger a fresh capture run for both wine and native**

```bash
python3 scripts/capture-checkpoint.py mission allied-l1 --frame 50 --targets wine,native
```

Expected: the script prints `OK wine: /tmp/battlecontrol/<ts>-mission-allied-l1/wine.png (... bytes)` and the equivalent line for native, then a comparison line with an SSIM number, then `HTTP server started at http://localhost:1234/` (or "already running").

- [ ] **Step 2: Locate the new session dir**

```bash
ls -t /tmp/battlecontrol/ | head -1
```

Expected: prints a directory name like `2026-05-19T<HH-MM-SS>-mission-allied-l1`. Record this path as `$SESSION`.

- [ ] **Step 3: Read native.png and confirm units are blue**

Open `/tmp/battlecontrol/$SESSION/native.png`. Visual checklist:
- The three infantry near the top of the visible map area render in **blue** (not yellow).
- The two armoured vehicles (APCs) render in **blue** (not yellow/green).
- The single conscript at the bottom of the map renders in **red** (Soviet — unchanged from previous yellow because the bug affected all houses equally, but red should now be visibly red, not yellow-with-red-tint).

If units are still yellow: the helper is wired but the vararg pop order is wrong. Re-check Task 1 Step 1 against `REDALERT/KEYFBUFF.ASM:1294-1411`.

- [ ] **Step 4: Confirm SSIM has jumped**

```bash
cat /tmp/battlecontrol/$SESSION/report.json
```

Expected: `"ssim"` value substantially higher than the previous 0.2056 baseline. A correctly remapped unit blit should push SSIM into the 0.6+ range at minimum (remaining diff comes from other unfixed cosmetic effects, font edges, etc.). If SSIM did not increase, the LUT path is not being hit — instrument with a temporary `fprintf(stderr, ...)` in `blit_row` to confirm `remap != nullptr` for unit draws.

- [ ] **Step 5: Do NOT commit yet** — TD changes ship in the same commit.

---

## Task 5: Wire TD stub to use the helpers

**Files:**
- Modify: `linux/td-win32-stubs.cpp:1200-1224`

- [ ] **Step 1: Add the helper include**

At the top of `linux/td-win32-stubs.cpp`, alongside the existing includes (look near the top — there's already `<cstring>` somewhere), add:

```cpp
#include "win32-stubs/blit-helpers.h"
```

Note the path prefix `win32-stubs/` — this file is one directory level above `blit-helpers.h`, in `linux/` not `linux/win32-stubs/`. Verify by running:

```bash
ls linux/td-win32-stubs.cpp linux/win32-stubs/blit-helpers.h
```

Both must print without error.

- [ ] **Step 2: Replace the TD function body**

Replace the existing `Buffer_Frame_To_Page` body in `linux/td-win32-stubs.cpp` (currently lines 1200-1224, starting at the `// FUNCTION.H declares Buffer_Frame_To_Page in extern "C".` comment) with:

```cpp
// FUNCTION.H declares Buffer_Frame_To_Page in extern "C".
// Linux port — see linux/win32-stubs/blit-helpers.h for the vararg
// decoding and row-blit helpers shared with the RA stub.
long Buffer_Frame_To_Page(int x, int y, int w, int h,
                          void *src, GraphicViewPortClass &dest, int flags, ...)
{
    if (!src || w <= 0 || h <= 0) return 0;
    const unsigned char *pixels = (const unsigned char*)src;
    if (flags & BFTP_SHAPE_CENTER) { x -= w / 2; y -= h / 2; }
    int vw = dest.Get_Width(), vh = dest.Get_Height();
    int stride = vw + dest.Get_XAdd() + dest.Get_Pitch();
    int sx0 = 0, sy0 = 0, dw = w, dh = h;
    if (x < 0)       { sx0 = -x;    dw += x;    x = 0; }
    if (y < 0)       { sy0 = -y;    dh += y;    y = 0; }
    if (x + dw > vw) { dw = vw - x; }
    if (y + dh > vh) { dh = vh - y; }
    if (dw <= 0 || dh <= 0) return 0;

    va_list args;
    va_start(args, flags);
    BlitArgs ba = decode_shape_blit_args(flags, args);
    va_end(args);

    auto *dst_base = (unsigned char*)dest.Get_Offset();
    const bool trans = (flags & BFTP_SHAPE_TRANS) != 0;
    for (int row = 0; row < dh; row++) {
        const unsigned char *srow = pixels + (sy0 + row) * w + sx0;
        unsigned char       *drow = dst_base + (y + row) * stride + x;
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count);
    }
    return 1;
}
```

Leave everything else in the file (Buffer_To_Buffer, Buffer_Print, the Uncompress_Data block, etc.) untouched.

---

## Task 6: Build TD and verify it compiles

**Files:** none (build-only)

- [ ] **Step 1: Build the TD target**

```bash
bash scripts/build-native.sh td
```

Expected: same pattern as RA — configure / build / validate. No errors.

- [ ] **Step 2: If failure, see Task 3 Step 2 troubleshooting**

The same failure modes apply. In particular, double-check the include path differs (`win32-stubs/blit-helpers.h` from `linux/td-win32-stubs.cpp`, not `blit-helpers.h`).

---

## Task 7: Optional — verify TD via capture

**Files:** none

- [ ] **Step 1: Check whether a comparable TD scenario capture exists**

```bash
python3 scripts/capture-checkpoint.py --help 2>&1 | grep -iE "td|tib|gdi"
```

If TD scenarios are supported in the capture pipeline, run an equivalent capture (e.g. GDI mission 1) and confirm units render in the correct house colour. If not supported, skip this task — RA verification is sufficient since both stubs share the same helper.

---

## Task 8: Commit

**Files:** none

- [ ] **Step 1: Stage and commit**

```bash
git add linux/win32-stubs/blit-helpers.h linux/win32-stubs/wwlib-asm-stub.cpp linux/td-win32-stubs.cpp
git commit -m "$(cat <<'EOF'
feat(linux): apply SHAPE_FADING remap LUT in Buffer_Frame_To_Page

The Linux win32 stubs that replace KEYFBUFF.ASM previously dropped the
variadic remap/fade arguments, so unit sprites blitted with their raw
yellow palette instead of the house-colour band. Decode varargs per
the original ASM order (GHOST → FADING table+count → PREDATOR offset)
and apply the 256-byte LUT to each source pixel when SHAPE_FADING is
set. SHAPE_GHOST and SHAPE_PREDATOR remain no-ops (cosmetic, deferred).

Shared the row-blit helper between RA and TD stubs via a new
linux/win32-stubs/blit-helpers.h.

Verified by re-running scripts/capture-checkpoint.py on mission
allied-l1 frame 50: Allied infantry/APCs now render blue and the
Soviet conscript renders red, matching wine. SSIM versus wine
reference jumped from 0.2056 to <NEW VALUE>.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Replace `<NEW VALUE>` with the actual SSIM from Task 4 Step 4 before committing.

- [ ] **Step 2: Verify the commit landed**

```bash
git log --oneline -1
git status
```

Expected: commit subject visible, working tree clean for the three changed files.

---

## Task 9: Catalogue remaining "future pass" landmines

**Files:**
- Create: `docs/superpowers/notes/2026-05-19-linux-stub-landmines.md`

The remap bug was a single instance of a broader pattern: the Linux port pulled in stubs whose comments admit "for a future pass" / "TODO" / "unhandled" / "nop" but were never revisited. Catalogue the rest so we know what other parity bugs are still latent.

- [ ] **Step 1: Grep current sources for landmine markers**

Run these from repo root and collect output:

```bash
grep -nE "future pass|TODO|FIXME|XXX|unhandled|no-op|nop stub|stub returns|left for|deferred|placeholder|HACK" \
    linux/ -r --include='*.cpp' --include='*.h'
```

```bash
grep -nE "future pass|TODO|FIXME|unhandled|left for" \
    REDALERT/DLLInterface.cpp REDALERT/CONQUER.CPP 2>/dev/null | head -40
```

- [ ] **Step 2: Mine git log for stub-introducing commits**

```bash
git log --oneline --all -- linux/ | head -60
```

Look for commit subjects like "TIM-NNN: stubs", "pass-N", "first cut", "skeleton". For the top 5-10 such commits, run:

```bash
git show --stat <hash>
```

to see what they introduced. Note any whose subject or body says "leave for later", "future", "minimal", etc.

- [ ] **Step 3: Cross-reference each landmine against wine-path equivalence**

For each TODO / "future pass" / nop stub found, classify by likely visible effect:

- **Cosmetic** (low priority): tints, shadows, animations that don't change game logic. e.g. `SHAPE_GHOST` (translucency), `SHAPE_PREDATOR` (stealth warp).
- **Functional** (high priority): things the engine queries and reacts to. e.g. `Processor() = 0` short-circuits benchmark allocation — currently intentional, but verify no other call site cares. `LCW_Comp` returning 0 — flagged as guarded but worth confirming the guard holds.
- **Suspicious silent-success** (highest priority): stubs that return 1/0/TRUE without doing anything, where a caller might rely on the side effect. e.g. `Animate_Frame` returning FALSE silently.

- [ ] **Step 4: Write the report**

Save to `docs/superpowers/notes/2026-05-19-linux-stub-landmines.md` with this structure:

```markdown
# Linux stub landmines — 2026-05-19 survey

Sources surveyed: `linux/win32-stubs/*.cpp`, `linux/win32-stubs/*.h`,
`linux/td-win32-stubs.cpp`, plus any other `linux/*.cpp` files.

## Confirmed parity bugs (visible in capture or game behaviour)

- ### <stub name> — <file>:<line>
  **Symptom:** <what the user observes vs wine>
  **Cause:** <one sentence>
  **Fix sketch:** <1-2 lines, or "see KEYFBUFF.ASM:NNN">
  **Priority:** high / medium / low

## Likely-latent (no visible bug yet, but stub omits real behaviour)

- ### <stub name> — <file>:<line>
  **Behaviour omitted:** <what the original does>
  **Why no bug shows up:** <which code path skips it, or which guard holds>
  **Risk:** <what changes would unmask it>

## Intentional no-ops (verified safe)

- ### <stub name> — <file>:<line>
  **Reason no-op is correct:** <quote the existing comment or document the call-site guard>
```

At minimum, the report should cover:
- `SHAPE_GHOST` translucency (out-of-scope here)
- `SHAPE_PREDATOR` warp (out-of-scope here)
- `LCW_Comp` returning 0 (`wwlib-asm-stub.cpp:284-287`)
- `Processor` returning 0 (`wwlib-asm-stub.cpp:293-296`)
- The `td-win32-stubs.cpp` "Uncompress_Data", "Extract_Shape", "Open_Animation", "IconCache" no-ops at lines 1232-1313
- Anything else the greps surface

Do NOT propose fixes inline — this is a survey, not an implementation. Each entry's "Fix sketch" is one or two lines, no code.

- [ ] **Step 5: Commit the report**

```bash
git add docs/superpowers/notes/2026-05-19-linux-stub-landmines.md
git commit -m "docs: catalogue Linux stub landmines surfaced during remap fix

Survey of \"future pass\" / TODO / nop-stub markers in linux/ stubs,
classified by likely impact (parity bug / latent / verified safe).
Companion to the SHAPE_FADING remap fix; provides the backlog for
follow-on parity work.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Self-review checklist (skip if executing — this is for the plan author)

- [x] Every code step shows complete code, no placeholders.
- [x] File paths are exact, including the include-path asymmetry between RA stub (sibling) and TD stub (parent dir).
- [x] Each task has a "what to do if this fails" hint (Tasks 3, 4, 6).
- [x] Verification is realistic given no unit-test infra — captures + SSIM are the existing measurement vehicle.
- [x] Out-of-scope items (GHOST, PREDATOR, fade_count loops) are listed at the top and reiterated in code comments, so the executor doesn't expand scope.
- [x] The fade_count clamp (0x3f) matches `REDALERT/KEYFBUFF.ASM:1386` — preserved in the helper.
