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
