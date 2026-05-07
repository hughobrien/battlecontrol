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

class GraphicViewPortClass; // forward decl: same incomplete type as the header.

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

// FUNCTION.H — variadic shape-blit; engine ignores return on the NOP path.
long Buffer_Frame_To_Page(int /*x*/, int /*y*/, int /*w*/, int /*h*/,
                          void * /*Buffer*/, GraphicViewPortClass & /*view*/,
                          int /*flags*/, ...)
{
    return 0;
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

}  // extern "C"
