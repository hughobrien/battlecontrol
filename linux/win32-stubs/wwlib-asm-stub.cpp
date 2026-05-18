// TIM-146 wwlib-asm body stubs.
//
// The original WW assembly modules (TXTPRNT.ASM, MMX.ASM, CPUID.ASM,
// LCWCOMP.ASM, TOBUFF.ASM, KEYFBUFF.ASM) are x86 real-mode/32-bit
// only — they will not assemble on x86_64 Linux without a full port.
// These C bodies satisfy the link-time references with NOP semantics
// so we can keep advancing past the link milestone toward a runnable
// binary. Real implementations (or SDL2/portable replacements) are
// deliberately out of scope for this pass; downstream issues will
// rebuild each subsystem behind the same prototypes.
//
// Every prototype here is declared `extern "C"` in the engine headers
// (DRAWBUFF.H wraps the Buffer_* family; FUNCTION.H wraps
// Buffer_Frame_To_Page; LCW.H wraps LCW_Comp; GETCPU.CPP wraps the
// MMX/CPU symbols). Mirror the same linkage so the link sees
// unmangled names. __cdecl is empty on Linux.

#include <cstring>
#include "GBUFFER.H"
#include "FONT.H"

// Shape-buffer globals defined extern "C" in 2KEYFRAM.CPP.
extern "C" char *BigShapeBufferStart;
extern "C" char *TheaterShapeBufferStart;
extern "C" BOOL  UseBigShapeBuffer;

namespace {
// Matches the tShapeHeaderType typedef in 2KEYFRAM.CPP.
struct ShapeHdr {
    unsigned draw_flags;
    char    *shape_data;   // offset into BigShapeBuffer / TheaterShapeBuffer
    int      shape_buffer; // 1 = theater buffer, 0 = big shape buffer
};
} // namespace

// ColorXlat: 256-byte font colour translation table (matches TXTPRNT.ASM).
// Layout: [0..15] identity; [n*16] = n for n in 1..15; all other entries 0.
// Buffer_Print overwrites [0]=bcolor, [1]=fcolor, [16]=fcolor before rendering.
extern "C" unsigned char ColorXlat[256] = {
    // [0..15] direct nibble values
    0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
    0x08,0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,
    // [16..31]  high-nibble-1 entry at [16]=0x01, rest 0
    0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [32..47]  high-nibble-2 entry
    0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [48..63]
    0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [64..79]
    0x04,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [80..95]
    0x05,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [96..111]
    0x06,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [112..127]
    0x07,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [128..143]
    0x08,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [144..159]
    0x09,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [160..175]
    0x0A,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [176..191]
    0x0B,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [192..207]
    0x0C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [208..223]
    0x0D,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [224..239]
    0x0E,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // [240..255]  high-nibble-15 at [240]=0x0F
    0x0F,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
};

extern "C" {

// ---- MMX.ASM / CPUID.ASM data symbols. -------------------------------
// CPUType is consumed as a single byte (cpu family); VendorID is
// consumed as a 16-byte string buffer via
// `strncpy(vendor_id, &VendorID, len)` in GETCPU.CPP. The decls in
// GETCPU.CPP / STATS.CPP read `extern char` — the linker resolves by
// symbol name regardless of the declared element-vs-array shape.
char CPUType = 0;
char VendorID[16] = "GenericLinuxx86";  // 15 chars + NUL.

// GETCPU.CPP defines `#define bool int` before declaring this prototype.
int Detect_MMX_Availability(void)
{
    return 0;  // no MMX path; portable C drawing fallback only.
}

// ---- DRAWBUFF.H Buffer_* family. -------------------------------------
long Buffer_To_Buffer(void * /*thisptr*/, int /*x*/, int /*y*/, int /*w*/, int /*h*/, void * /*buff*/, long /*size*/)
{
    return 0;
}

// Real Buffer_Print: portable C++ port of REDALERT/TXTPRNT.ASM.
//
// Font binary layout (FONT.H constants):
//   offset 4 (FONTINFOBLOCK)  : uint16 → info block; info[4]=max_height, info[5]=max_width
//   offset 6 (FONTOFFSETBLOCK): uint16 → offset block; uint16 array[256], value is
//                                offset from FontPtr to glyph data for char c
//   offset 8 (FONTWIDTHBLOCK) : uint16 → width block; uint8 array[256] pixel widths
//   offset 10 (FONTDATABLOCK) : uint16 → data block start (glyph data follows)
//   offset 12 (FONTHEIGHTBLOCK): uint16 → height block; per-char pairs:
//                                 [c*2+0]=top_blank, [c*2+1]=char_height
//
// Glyph pixels: nibble-packed, 2 pixels per byte.
//   byte b → pixel1 = b & 0x0F (low nibble), pixel2 = b & 0xF0 (high nibble, unshifted)
// ColorXlat translation (mirroring xlat semantics in ASM):
//   translated = ColorXlat[pixel_value]  where high-nibble pixel uses value = b&0xF0
//   translated == 0 → transparent (skip pixel)
long Buffer_Print(void *thisptr, const char *str, int x, int y, int fcolor, int bcolor)
{
    if (!str || !FontPtr) return 0;

    GraphicViewPortClass *vp = static_cast<GraphicViewPortClass*>(thisptr);
    int vp_w    = vp->Get_Width();
    int vp_h    = vp->Get_Height();
    int stride  = vp_w + vp->Get_XAdd() + vp->Get_Pitch();
    unsigned char *buf = static_cast<unsigned char*>(static_cast<void*>(
                         reinterpret_cast<char*>(vp->Get_Offset())));

    const char *fp = static_cast<const char*>(FontPtr);

    const unsigned short *off_blk  = reinterpret_cast<const unsigned short*>(
        fp + *reinterpret_cast<const unsigned short*>(fp + FONTOFFSETBLOCK));
    const unsigned char  *wid_blk  = reinterpret_cast<const unsigned char*>(
        fp + *reinterpret_cast<const unsigned short*>(fp + FONTWIDTHBLOCK));
    const unsigned char  *hgt_blk  = reinterpret_cast<const unsigned char*>(
        fp + *reinterpret_cast<const unsigned short*>(fp + FONTHEIGHTBLOCK));
    const unsigned char  *info_blk = reinterpret_cast<const unsigned char*>(
        fp + *reinterpret_cast<const unsigned short*>(fp + FONTINFOBLOCK));

    int max_height = static_cast<int>(info_blk[FONTINFOMAXHEIGHT]);

    // Build per-call color translation (matches TXTPRNT.ASM ColorXlat setup).
    unsigned char xlat[256];
    memcpy(xlat, ColorXlat, 256);
    xlat[0]  = static_cast<unsigned char>(bcolor);
    xlat[1]  = static_cast<unsigned char>(fcolor);
    xlat[16] = static_cast<unsigned char>(fcolor);

    int orig_x = x;

    // Overflow check: if the first character row falls outside the viewport, bail.
    if (y + max_height > vp_h) return 0;

    for (; *str; ++str) {
        unsigned char c = static_cast<unsigned char>(*str);

        // Line feed (LF=10 → x=0; CR=13 → x=orig_x)
        if (c == 10 || c == 13) {
            y += max_height + FontYSpacing;
            if (y + max_height > vp_h) break;
            x = (c == 10) ? 0 : orig_x;
            continue;
        }

        int cw = static_cast<int>(wid_blk[c]);

        // Auto-wrap: force line feed if character would exceed viewport width.
        if (x + cw + FontXSpacing > vp_w) {
            y += max_height + FontYSpacing;
            if (y + max_height > vp_h) break;
            x = orig_x;
        }

        int top_blank   = static_cast<int>(hgt_blk[c * 2]);
        int char_height = static_cast<int>(hgt_blk[c * 2 + 1]);
        int bot_blank   = max_height - top_blank - char_height;

        // Glyph data offset is from FontPtr (not from data block).
        const unsigned char *glyph = reinterpret_cast<const unsigned char*>(
            fp + static_cast<unsigned int>(off_blk[c]));

        unsigned char *dst = buf + y * stride + x;

        // --- top blank rows ---
        {
            unsigned char bc = xlat[0];
            for (int row = 0; row < top_blank; row++, dst += stride)
                if (bc) memset(dst, bc, (size_t)cw);
        }

        // --- character data rows (nibble-packed pixels) ---
        for (int row = 0; row < char_height; row++, dst += stride) {
            int col = 0;
            for (int b = 0; col < cw; b++) {
                unsigned char byte = glyph[b];
                // Low nibble → first pixel
                if (col < cw) {
                    unsigned char color = xlat[byte & 0x0Fu];
                    if (color) dst[col] = color;
                    col++;
                }
                // High nibble (unshifted, 0x?0) → second pixel
                if (col < cw) {
                    unsigned char color = xlat[byte & 0xF0u];
                    if (color) dst[col] = color;
                    col++;
                }
            }
            glyph += ((cw + 1) / 2);  // advance one row (ceiling(cw/2) bytes)
        }

        // --- bottom blank rows ---
        {
            unsigned char bc = xlat[0];
            for (int row = 0; row < bot_blank; row++, dst += stride)
                if (bc) memset(dst, bc, (size_t)cw);
        }

        x += cw + FontXSpacing;
    }

    // Return address of next draw position (matches TXTPRNT.ASM return convention).
    return reinterpret_cast<long>(buf + y * stride + x);
}

void *Get_Font_Palette_Ptr(void)
{
    return ColorXlat;
}

// FUNCTION.H — shape blit from BigShapeBuffer into a GraphicViewPort.
// Replaces the original x86 KEYFBUFF.ASM routine with portable C++.
// Supports: SHAPE_TRANS (0x0040) skip colour-0 pixels, SHAPE_CENTER (0x0020).
// Other flags (fading, predator, ghost, remap) are left for a future pass.
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
        // shape_data holds the byte offset; adding (long)base converts to absolute ptr.
        pixels = (const unsigned char*)(hdr->shape_data + (long)base);
    } else {
        pixels = (const unsigned char*)src;
    }
    if (!pixels) return 0;

    if (flags & 0x0020) { x -= w / 2; y -= h / 2; } // SHAPE_CENTER

    int vw     = dest.Get_Width();
    int vh     = dest.Get_Height();
    int stride = vw + dest.Get_XAdd() + dest.Get_Pitch(); // row stride of the underlying buffer (includes Pitch for surface alignment)

    // Clip source rect against viewport bounds.
    int sx0 = 0, sy0 = 0, dw = w, dh = h;
    if (x < 0)        { sx0 = -x;      dw += x;      x = 0; }
    if (y < 0)        { sy0 = -y;      dh += y;      y = 0; }
    if (x + dw > vw)  { dw = vw - x; }
    if (y + dh > vh)  { dh = vh - y; }
    if (dw <= 0 || dh <= 0) return 0;

    unsigned char *dst_base = (unsigned char*)dest.Get_Offset();
    const bool trans = (flags & 0x0040) != 0; // SHAPE_TRANS: skip colour-0

    for (int row = 0; row < dh; row++) {
        const unsigned char *srow = pixels + (sy0 + row) * w + sx0;
        unsigned char       *drow = dst_base + (y + row) * stride + x;
        if (trans) {
            for (int col = 0; col < dw; col++)
                if (srow[col]) drow[col] = srow[col];
        } else {
            memcpy(drow, srow, dw);
        }
    }
    return 1;
}

// LCW.H — LCW (RLE-style) compressor used by save-game writers and
// shape pipelines. Returning 0 (no bytes written) keeps callers from
// emitting a corrupt stream into a real file; in practice these call
// sites are guarded by code paths that won't fire under the current
// runnable subset.
int LCW_Comp(void const * /*source*/, void * /*dest*/, int /*length*/)
{
    return 0;
}

// WIN32LIB/MISC.H — CPU family detector. Returns 0=286, 1=386, 2=486,
// 3=Pentium, etc. CHEAT_KEYS code in INIT.CPP gates Benchmark allocation
// on Processor() >= 2. We return 0 so Benches stays NULL and BStart/BEnd
// remain no-ops; no Benchmark objects are ever allocated.
unsigned short Processor(void)
{
    return 0;
}

}  // extern "C"
