// linux/win32-stubs/blit-helpers.h
//
// Portable replacements for the variadic-argument decoding and row blit
// originally done by REDALERT/KEYFBUFF.ASM. Shared between the RA and TD
// Linux win32 stubs so both builds apply unit house-colour remap correctly.
//
// Varargs order per KEYFBUFF.ASM:1294-1459:
//   if (flags & SHAPE_GHOST)    pop void*  ghost_table
//   if (flags & SHAPE_FADING)   pop void*  fade_table  (often == house remap LUT)
//                               pop int    fade_count  (LUT applications, usually 1)
//   if (flags & SHAPE_PREDATOR) pop int    pred_offset
//   if (flags & SHAPE_PARTIAL)  pop int    partial_pred
//
// These helpers intentionally mirror the original x86 scanline state machine.

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
    BFTP_SHAPE_PARTIAL  = 0x4000,
};

struct BlitArgs {
    const unsigned char *remap;       // 256-byte LUT, NULL if SHAPE_FADING not set
    int                  fade_count;
    const unsigned char *ghost;       // 256 + N*256 bytes, NULL if SHAPE_GHOST not set
    bool                 predator;
    bool                 predator_negative;
    int                  predator_offset;
    int                  predator_partial_step;
    int                  predator_partial_count;
};

// Pop the variadic args declared after `flags`. Caller already did va_start.
// Caller is responsible for va_end.
inline BlitArgs decode_shape_blit_args(int flags, va_list args)
{
    BlitArgs out{ nullptr, 0, nullptr, false, false, 0, 0x100, 0 };
    if (flags & BFTP_SHAPE_GHOST) {
        out.ghost = static_cast<const unsigned char *>(va_arg(args, void *));
    }
    if (flags & BFTP_SHAPE_FADING) {
        out.remap      = static_cast<const unsigned char *>(va_arg(args, void *));
        out.fade_count = va_arg(args, int);
    }
    if (flags & BFTP_SHAPE_PREDATOR) {
        int pred_offset = va_arg(args, int);
        int table_offset = pred_offset << 1;
        out.predator = true;
        if (table_offset < 0) {
            out.predator_negative = true;
            table_offset = -table_offset;
        }
        out.predator_offset = table_offset & 0x0e;
    }
    if (flags & BFTP_SHAPE_PARTIAL) {
        out.predator_partial_step = va_arg(args, int) & 0xff;
    }
    return out;
}

inline bool predator_pixel_selected(BlitArgs &args)
{
    int count = args.predator_partial_count + args.predator_partial_step;
    if ((count & 0xff00) == 0) {
        args.predator_partial_count = count;
        return false;
    }

    args.predator_partial_count = count & ~0xff00;
    return true;
}

inline unsigned char predator_sample(unsigned char       *dst,
                                     BlitArgs            &args,
                                     int                  stride,
                                     const unsigned char *surface_begin,
                                     const unsigned char *surface_end)
{
    static const int positive_offsets[8] = { 1, 3, 2, 5, 2, 3, 4, 1 };
    static const int negative_offsets[8] = { -1, -3, -2, -5, -2, -4, -3, -1 };

    const int table_index = (args.predator_offset & 0x0e) >> 1;
    args.predator_offset = (args.predator_offset + 2) & 0x0e;

    int sample_offset = positive_offsets[table_index];
    if (args.predator_negative) {
        sample_offset = stride + negative_offsets[table_index];
    }

    const unsigned char *sample = dst + sample_offset;
    if (sample < surface_begin || sample >= surface_end) {
        return *dst;
    }
    return *sample;
}

// Blit one row of `dw` bytes from `src` to `dst`.
//   trans       — true means skip colour-0 (transparent palette index)
//   args        — decoded KEYFBUFF.ASM draw state. Predator state mutates
//                 across rows to match the original scanline routines.
//   stride      — destination row stride used by negative predator offsets
//   surface_*   — destination bounds, used only to keep predator sampling safe
//   remap       — optional 256-byte LUT (house remap or fade table)
//   ghost       — optional ghost/translucency table (256 + N*256 bytes).
//                 First 256 bytes: IsTranslucent[src_pixel] — 0xFF means
//                 opaque, any other value selects a translucent LUT.
//                 Following N*256 bytes: blend tables indexed by dst pixel.
//                 Matches REDALERT/KEYFBUFF.ASM:1834-1857.
inline void blit_row(unsigned char       *dst,
                     const unsigned char *src,
                     int                  dw,
                     bool                 trans,
                     BlitArgs            &args,
                     int                  stride,
                     const unsigned char *surface_begin,
                     const unsigned char *surface_end)
{
    // Cap fade_count defensively — original ASM masks with 0x3f.
    int fade_count = args.fade_count;
    if (fade_count < 0)  fade_count = 0;
    if (fade_count > 63) fade_count = 63;
    const unsigned char *remap = args.remap;
    const unsigned char *ghost = args.ghost;
    const bool do_remap = (remap != nullptr) && (fade_count > 0);
    const bool do_ghost = (ghost != nullptr);
    const bool do_predator = args.predator;

    // Fast path: no ghost, no remap — preserves the cheap memcpy/skip-0 case.
    if (!do_predator && !do_ghost && !do_remap) {
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

        unsigned char p = src_p;
        bool drew_predator_pixel = false;
        if (do_predator && predator_pixel_selected(args)) {
            p = predator_sample(dst + col, args, stride, surface_begin, surface_end);
            drew_predator_pixel = true;
        } else if (do_predator && !do_ghost && !do_remap) {
            continue;
        }

        if (do_ghost) {
            unsigned char shadow_idx = ghost_is_trans[p];
            if (shadow_idx == 0xFF) {
                // Opaque: keep the source pixel, or the predator sample.
            } else {
                // Translucent[shadow_idx * 256 + dst_pixel]
                p = ghost_blend[(static_cast<int>(shadow_idx) << 8) + dst[col]];
            }
        }

        if (do_remap) {
            for (int i = 0; i < fade_count; i++) p = remap[p];
        }

        if (drew_predator_pixel || do_ghost || do_remap) dst[col] = p;
    }
}

#endif  // LINUX_WIN32_STUBS_BLIT_HELPERS_H
