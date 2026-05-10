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

long Buffer_Print(void * /*thisptr*/, const char * /*str*/, int /*x*/, int /*y*/, int /*fcolor*/, int /*bcolor*/)
{
    return 0;
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
    int stride = vw + dest.Get_XAdd(); // row stride of the underlying buffer

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
