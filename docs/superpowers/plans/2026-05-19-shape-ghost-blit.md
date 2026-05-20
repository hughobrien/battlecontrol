# SHAPE_GHOST Blit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native Linux RA + TD must apply the `SHAPE_GHOST` ghost-table blend in `Buffer_Frame_To_Page`, fixing four user-observed regressions in mission-allied-l1 frame 50: green unit shadows, staggered fog-of-war edge, green tile outlines in the lower-right radar, and the green halo around terrain features.

**Architecture:** Companion to the `SHAPE_FADING` remap fix at `127edc2`. Extends `linux/win32-stubs/blit-helpers.h` to also pop and apply the ghost-table pointer that the varargs decoder currently discards. The ghost table is 256 + N×256 bytes (`IsTranslucent[src_pixel]` + N translucent LUTs); per-pixel logic: if `IsTranslucent[src]==0xFF` write opaque, else blend through `Translucent[IsTranslucent[src] * 256 + dst]`. Fade-via-remap is applied AFTER the ghost decision (matches `Single_Line_Ghost_Fading` in `REDALERT/KEYFBUFF.ASM:2132-2166`). Both stub callers pass `ba.ghost` through to `blit_row` — no per-stub logic divergence.

**Tech Stack:** Same as the prior fix — C++14, no new deps. Verification via `scripts/capture-checkpoint.py mission allied-l1 --frame 50` and visual inspection of `native.png`.

**Reference (the ASM ground truth):**
- `REDALERT/KEYFBUFF.ASM:1294-1305` — ghost-table varargs pop
- `REDALERT/KEYFBUFF.ASM:1834-1857` — `Single_Line_Ghost` inner loop (the pixel-substitution rule)
- `REDALERT/KEYFBUFF.ASM:2132-2166` — `Single_Line_Ghost_Fading` (ghost then fade)
- `REDALERT/DISPLAY.CPP:2488` — concrete unit-shadow call site (`ShadowTrans`)
- `REDALERT/TECHNO.CPP:4575` — concrete GHOST+FADING combined call (`shadow` + `remap`)

**Out of scope (leave TODO):**
- `SHAPE_PREDATOR` warp
- `fade_count > 1` distinct semantics (the current cap-at-63 loop is already in place)

---

## File Structure

- **Modify:** `linux/win32-stubs/blit-helpers.h` — add `ghost` to `BlitArgs`, pop it in `decode_shape_blit_args`, extend `blit_row` signature + body with the ghost branch.
- **Modify:** `linux/win32-stubs/wwlib-asm-stub.cpp` — pass `ba.ghost` to `blit_row`.
- **Modify:** `linux/td-win32-stubs.cpp` — pass `ba.ghost` to `blit_row`.

---

## Task 1: Extend BlitArgs + decode helper to capture the ghost pointer

**Files:**
- Modify: `linux/win32-stubs/blit-helpers.h`

- [ ] **Step 1: Add `ghost` field to `BlitArgs`**

Replace the existing struct with:

```cpp
struct BlitArgs {
    const unsigned char *remap;       // 256-byte LUT, NULL if SHAPE_FADING not set
    int                  fade_count;
    const unsigned char *ghost;       // 256 + N*256 bytes, NULL if SHAPE_GHOST not set
};
```

- [ ] **Step 2: Pop ghost in `decode_shape_blit_args`**

Replace the existing function with:

```cpp
inline BlitArgs decode_shape_blit_args(int flags, va_list args)
{
    BlitArgs out{ nullptr, 0, nullptr };
    if (flags & BFTP_SHAPE_GHOST) {
        out.ghost = static_cast<const unsigned char *>(va_arg(args, void *));
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
```

(Only behaviour change: stores ghost instead of discarding it. Order matches `KEYFBUFF.ASM:1294-1411`.)

---

## Task 2: Extend `blit_row` to apply the ghost table

**Files:**
- Modify: `linux/win32-stubs/blit-helpers.h`

- [ ] **Step 1: Update the function header comment**

Replace:

```cpp
// Blit one row of `dw` bytes from `src` to `dst`.
//   trans       — true means skip colour-0 (transparent palette index)
//   remap       — optional 256-byte LUT; if non-null, each src pixel is
//                 substituted via remap[p] (fade_count times)
//   fade_count  — number of LUT applications; clamp to >= 0
```

With:

```cpp
// Blit one row of `dw` bytes from `src` to `dst`.
//   trans       — true means skip colour-0 (transparent palette index)
//   remap       — optional 256-byte LUT (house remap or fade table); if
//                 non-null, the post-ghost pixel is substituted via
//                 remap[p] (fade_count times)
//   fade_count  — number of remap applications; clamp to [0, 63]
//   ghost       — optional ghost/translucency table (256 + N*256 bytes).
//                 First 256 bytes: IsTranslucent[src_pixel] — 0xFF means
//                 opaque, any other value selects a translucent LUT.
//                 Following N*256 bytes: blend tables indexed by dst pixel.
//                 Matches REDALERT/KEYFBUFF.ASM:1834-1857.
```

- [ ] **Step 2: Replace the function signature and body**

Replace the entire `blit_row` function with:

```cpp
inline void blit_row(unsigned char       *dst,
                     const unsigned char *src,
                     int                  dw,
                     bool                 trans,
                     const unsigned char *remap,
                     int                  fade_count,
                     const unsigned char *ghost)
{
    // Cap fade_count defensively — original ASM masks with 0x3f.
    if (fade_count < 0) fade_count = 0;
    if (fade_count > 63) fade_count = 63;
    const bool do_remap = (remap != nullptr) && (fade_count > 0);
    const bool do_ghost = (ghost != nullptr);

    // Fast path: no ghost, no remap — preserves the cheap memcpy/skip-0 case.
    if (!do_ghost && !do_remap) {
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

    const unsigned char *ghost_is_trans = ghost;             // [0..255]
    const unsigned char *ghost_blend    = ghost ? ghost + 256 : nullptr;

    for (int col = 0; col < dw; col++) {
        unsigned char src_p = src[col];
        if (trans && src_p == 0) continue;

        unsigned char p;
        if (do_ghost) {
            unsigned char shadow_idx = ghost_is_trans[src_p];
            if (shadow_idx == 0xFF) {
                p = src_p;                                   // opaque
            } else {
                // Translucent[shadow_idx * 256 + dst_pixel]
                p = ghost_blend[(static_cast<int>(shadow_idx) << 8) + dst[col]];
            }
        } else {
            p = src_p;
        }

        if (do_remap) {
            for (int i = 0; i < fade_count; i++) p = remap[p];
        }

        dst[col] = p;
    }
}
```

Key points:
- Ghost decision happens FIRST per pixel, then fade — matches the ASM order.
- Ghost branch with `shadow_idx == 0xFF` writes the opaque src pixel (which can then still be remapped). This is the path for non-shadow pixels in a unit sprite drawn with both `SHAPE_FADING` and `SHAPE_GHOST` (e.g. `TECHNO.CPP:4575`).
- Ghost-only callers (e.g. `DISPLAY.CPP:2488` shadow draw) have `remap == nullptr` → no fade is applied to the blended output.
- The `do_remap` branch is unchanged from the prior implementation, just nested inside the per-pixel loop now.

- [ ] **Step 3: Verify the header still parses standalone**

```bash
clang++ -Wno-unused-command-line-argument -std=c++14 -fsyntax-only -x c++ linux/win32-stubs/blit-helpers.h
```

Expected: exit 0, no output.

---

## Task 3: Pass `ba.ghost` to `blit_row` in the RA stub

**Files:**
- Modify: `linux/win32-stubs/wwlib-asm-stub.cpp`

- [ ] **Step 1: Update the `blit_row` call in the row loop**

Find the call (currently at the bottom of `Buffer_Frame_To_Page`):

```cpp
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count);
```

Replace with:

```cpp
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count, ba.ghost);
```

Nothing else in the file changes.

---

## Task 4: Pass `ba.ghost` to `blit_row` in the TD stub

**Files:**
- Modify: `linux/td-win32-stubs.cpp`

- [ ] **Step 1: Update the `blit_row` call**

Same single-argument addition as Task 3 — find:

```cpp
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count);
```

Replace with:

```cpp
        blit_row(drow, srow, dw, trans, ba.remap, ba.fade_count, ba.ghost);
```

Nothing else changes.

---

## Task 5: Build RA + TD

**Files:** none.

- [ ] **Step 1: Build both targets**

```bash
bash scripts/build-native.sh
```

Expected: configures + builds both `ra` and `td`, validates ELF 64-bit, exits 0.

If compilation fails on `blit_row` — almost certainly a mismatched argument count between the helper signature and one of the call sites. Re-check Tasks 3 and 4.

---

## Task 6: Re-capture mission-allied-l1 and visually verify

**Files:** none.

- [ ] **Step 1: Run the capture**

```bash
python3 scripts/capture-checkpoint.py mission allied-l1 --frame 50 --targets wine,native
```

- [ ] **Step 2: Locate the new session dir + Read both PNGs**

```bash
ls -t /tmp/battlecontrol/ | head -1
```

Read `/tmp/battlecontrol/<session>/native.png` and `wine.png`.

- [ ] **Step 3: Visual checklist**

In native.png, confirm vs the prior-commit baseline (commit `127edc2`, session `2026-05-20T00-50-14`):
- **Unit shadows:** dark grey/black underneath each infantry/vehicle, NOT green.
- **Fog of war edge:** smooth gradient at the shroud boundary (not chunky / not green).
- **Lower-right radar tiles:** no green square outlines hanging off the edge of the visible area.
- **Allied units:** still blue.
- **Soviet conscript:** still red.

- [ ] **Step 4: Confirm SSIM**

```bash
cat /tmp/battlecontrol/<session>/report.json
```

Expected: SSIM jumps from the previous 0.3554 baseline. Ghost path fixes a significant chunk of the residual diff (shadows, shroud, tile outlines are all shroud/ghost rendering). Aim is >0.5; smaller gain still acceptable since camera position drift between captures contributes too.

If shadows are still green: the ghost branch isn't being entered. Verify with a temporary `fprintf(stderr, "ghost=%p\n", ghost)` in `blit_row` to confirm callers pass a non-null pointer.

---

## Task 7: Commit

**Files:** none.

- [ ] **Step 1: Stage and commit**

```bash
git add linux/win32-stubs/blit-helpers.h \
        linux/win32-stubs/wwlib-asm-stub.cpp \
        linux/td-win32-stubs.cpp \
        docs/superpowers/plans/2026-05-19-shape-ghost-blit.md
git commit -m "$(cat <<'EOF'
feat(linux): apply SHAPE_GHOST translucency table in Buffer_Frame_To_Page

Pops the ghost_table varargs slot (previously discarded) and applies
the IsTranslucent[src] / Translucent[shadow_idx*256 + dst] blend per
KEYFBUFF.ASM:1834-1857. Ghost decision precedes fade-via-remap to
match Single_Line_Ghost_Fading at KEYFBUFF.ASM:2132-2166.

Fixes four user-observed regressions in mission-allied-l1 frame 50:
unit shadows rendering green, staggered fog-of-war edge, green tile
outlines in the lower-right radar, and the green halo around terrain
features — all four are SHAPE_GHOST callers (unit shadow, shroud,
sidebar radar overlay).

Shared helper lives at linux/win32-stubs/blit-helpers.h; both RA and
TD stubs just pass `ba.ghost` through. SHAPE_PREDATOR remains TODO.

Plan: docs/superpowers/plans/2026-05-19-shape-ghost-blit.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Replace the SSIM in the commit body with the actual value from Task 6 Step 4 if it helps anchor the diff size.

---

## Self-review checklist

- [x] Ghost table format is documented inline (the 256 + N*256 layout) in the helper comment.
- [x] Pixel-substitution rule with `0xFF` opaque sentinel is explicit.
- [x] Interaction with `SHAPE_FADING` is correct: ghost first, then fade — matches `Single_Line_Ghost_Fading`.
- [x] Fast path (`!do_ghost && !do_remap`) preserves the cheap memcpy + skip-0 case so non-ghost non-remap blits don't regress.
- [x] Both stub callers updated symmetrically; helper centralises the logic.
- [x] No new files; no CMake change.
- [x] Out-of-scope items reiterated (PREDATOR, fade_count semantics beyond clamp).
