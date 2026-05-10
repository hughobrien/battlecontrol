// TIM-6: MSVC / Watcom compatibility shim.
//
// Force-included on non-MSVC builds (see scripts/first-compile-pass3.sh
// and CMakeLists.txt). Keeps the upstream sources untouched for the
// MSVC keyword and CRT-extension cases identified by TIM-4 pass 2:
//
//   * empty calling-convention macros (__cdecl / __stdcall / __fastcall)
//     and Win16-era pointer attributes (FAR / NEAR / PASCAL / HUGE) so
//     the parser advances past Win32 prototypes;
//   * a #define for __int64 (mapped to long long) so that the
//     'unsigned __int64' / 'signed __int64' forms used in fixed-point
//     math (FIXED.H) and the GlyphX DLL interface (DLLInterface.h)
//     parse via simple preprocessor expansion;
//   * an inline _lrotl shim used by CRC.CPP / CRC.H.
//
// MSVC is unchanged because its compiler defines _MSC_VER and provides
// all of the above natively.

#ifndef LINUX_WIN32_STUBS_MSVC_COMPAT_H
#define LINUX_WIN32_STUBS_MSVC_COMPAT_H

// TIM-339: CHEAT_KEYS is defined unconditionally in DEFINES.H, but STAGE.H
// is parsed earlier (via wwlib32.h→MOUSE.H) before DEFINES.H is reached.
// Pre-define here so StageClass::Debug_Dump is compiled into StageClass.
#ifndef CHEAT_KEYS
#define CHEAT_KEYS
#endif

#if !defined(_MSC_VER)

// TIM-11: Honor DDRAW.H's upstream `#if defined(_WIN32) && !defined(_NO_COM)`
// guard so its COM interface block (DECLARE_INTERFACE_ / STDMETHOD / IUnknown)
// is skipped on Linux. WIN32LIB/wwstd.h auto-defines _WIN32, so without this
// the COM cascade explodes against our minimal objbase.h placeholder
// (TIM-5). The SDL2 / DirectDraw replacement is a separate later port.
#ifndef _NO_COM
#define _NO_COM
#endif

// Calling-convention and far-pointer attributes are no-ops on x86_64
// Linux — there is no equivalent and only one ABI.
#ifndef __cdecl
#define __cdecl
#endif
#ifndef __stdcall
#define __stdcall
#endif
#ifndef __fastcall
#define __fastcall
#endif
#ifndef _cdecl
#define _cdecl
#endif
#ifndef _stdcall
#define _stdcall
#endif
#ifndef _fastcall
#define _fastcall
#endif
#ifndef CDECL
#define CDECL
#endif
#ifndef PASCAL
#define PASCAL
#endif
#ifndef WINAPI
#define WINAPI
#endif
#ifndef APIENTRY
#define APIENTRY
#endif
#ifndef CALLBACK
#define CALLBACK
#endif
#ifndef FAR
#define FAR
#endif
#ifndef NEAR
#define NEAR
#endif
#ifndef HUGE
#define HUGE
#endif

// TIM-29: lowercase Win16 pointer-attribute and calling-convention
// keywords. WIN32LIB/TIMER.H:184 and WIN32LIB/SOSDEFS.H:60-69 use the
// bare `far`/`near` qualifier on prototypes and typedefs; MSVC silently
// accepts them, g++ rejects. Audit (TIM-29 method step 3) confirmed the
// codebase only uses these as type qualifiers, never as identifiers.
#ifndef far
#define far
#endif
#ifndef near
#define near
#endif
#ifndef pascal
#define pascal
#endif
#ifndef __far
#define __far
#endif
#ifndef __near
#define __near
#endif
#ifndef __pascal
#define __pascal
#endif
#ifndef _far
#define _far
#endif
#ifndef _near
#define _near
#endif
#ifndef _pascal
#define _pascal
#endif

// TIM-50: bare lowercase `cdecl` keyword. FUNCTION.H:601, WWALLOC.H,
// CDFILE.CPP, WIN32LIB/GETSHAPE.CPP, MEMCHECK.H all use `<type> cdecl
// <ident>(...)` as a calling-convention qualifier on prototypes /
// definitions; MSVC silently accepts, g++ rejects. Sister macros
// (__cdecl, _cdecl, CDECL) were already defined empty above; bare
// `cdecl` was the only spelling missed. Audit confirmed no use as an
// identifier.
#ifndef cdecl
#define cdecl
#endif

// MSVC's 64-bit integer extension. <cstdint>'s int64_t is the
// portable equivalent on Linux. Use the GCC/Clang extension
// __extension__ to silence -Wpedantic warnings about the typedef.
#ifdef __cplusplus
#include <cstdint>
#else
#include <stdint.h>
#endif

// TIM-62: __int64 is exposed as a #define rather than a typedef so
// that 'unsigned __int64' / 'signed __int64' / 'typedef unsigned
// __int64 uint64' parse via simple preprocessor expansion. C++ does
// not allow 'unsigned <typedef-name>', so the prior typedef form
// blocked DLLInterface.h:794 (struct member) and DLLInterface.cpp:59
// (typedef). 'long long' is 64-bit on every platform we target and
// matches MSVC's __int64 width exactly.
#if !defined(__INT64_DEFINED)
#define __INT64_DEFINED
#define __int64 long long
#endif

// _lrotl: MSVC CRT "rotate left long". Used by CRC.CPP / CRC.H. The
// rotate is on the natural width of `unsigned long`, which on LP32
// (Win32) was 32 bits and on LP64 (Linux x86_64) is 64 bits. Producing
// CRC values that match the original engine across architectures is a
// LP32 → LP64 type-width problem (deferred to TIM-7+). For now the
// shim just unblocks the parser with the same semantics the original
// code expected on its target ABI.
#ifndef _lrotl
#ifdef __cplusplus
static inline unsigned long _lrotl(unsigned long value, int shift)
{
    return (value << shift)
         | (value >> ((sizeof(unsigned long) * 8) - shift));
}
#else
#define _lrotl(value, shift) \
    (((unsigned long)(value) << (shift)) \
     | ((unsigned long)(value) >> ((sizeof(unsigned long) * 8) - (shift))))
#endif
#endif

// TIM-15: itoa / ltoa are MSVC CRT extensions, not in glibc. WIN32LIB's
// GBUFFER.H::Print(int|short|long) overloads call them at radix 10 to
// stringify numbers before forwarding to the text renderer. The shim
// preserves MSVC return semantics (returns the destination buffer) and
// supports the documented radix range 2..36. The caller is responsible
// for sizing `buffer` — same contract as MSVC's CRT.
#ifndef _ITOA_LTOA_DEFINED
#define _ITOA_LTOA_DEFINED
static inline char* _wwlib_itoa_impl(long value, char* buffer, int radix)
{
    if (radix < 2 || radix > 36) {
        buffer[0] = '\0';
        return buffer;
    }
    unsigned long uvalue;
    int negative = 0;
    if (radix == 10 && value < 0) {
        negative = 1;
        // Two-step negation is safe even at LONG_MIN, where -value
        // would overflow signed long.
        uvalue = (unsigned long)(-(value + 1)) + 1;
    } else {
        uvalue = (unsigned long)value;
    }
    char* p = buffer;
    do {
        int digit = (int)(uvalue % (unsigned long)radix);
        *p++ = (char)(digit < 10 ? '0' + digit : 'a' + digit - 10);
        uvalue /= (unsigned long)radix;
    } while (uvalue != 0);
    if (negative) {
        *p++ = '-';
    }
    *p = '\0';
    // Reverse the digits in place (they were emitted least-significant first).
    char* start = buffer;
    char* end = p - 1;
    while (start < end) {
        char tmp = *start;
        *start = *end;
        *end = tmp;
        ++start;
        --end;
    }
    return buffer;
}
static inline char* itoa(int value, char* buffer, int radix)
{
    return _wwlib_itoa_impl((long)value, buffer, radix);
}
static inline char* ltoa(long value, char* buffer, int radix)
{
    return _wwlib_itoa_impl(value, buffer, radix);
}
#endif // _ITOA_LTOA_DEFINED

// TIM-45: stricmp / strnicmp / _stricmp / _strnicmp / memicmp / _memicmp
// are MSVC CRT extensions; POSIX has strcasecmp / strncasecmp and no
// case-insensitive memcmp at all. The 181-TU first-error cohort that
// previously gated at list.h then drop.h relocated to TEVENT.H:172
// (EventChoiceClass operator< / > / <= / >= bodies that call stricmp on
// inline-class member function results). TACTION.H:141-144 has the same
// pattern; many .CPP call sites also use stricmp / strnicmp / _stricmp /
// memicmp directly. Inline wrappers preserve the MSVC contract (returns
// 0 on match, sign of first differing byte otherwise) without touching
// upstream call sites.
#ifndef _MSVC_STRICMP_DEFINED
#define _MSVC_STRICMP_DEFINED
#ifdef __cplusplus
#include <strings.h>  // POSIX strcasecmp / strncasecmp
#include <cstddef>    // size_t
#include <cctype>     // tolower (for memicmp)
static inline int stricmp(const char* a, const char* b)
{
    return strcasecmp(a, b);
}
static inline int _stricmp(const char* a, const char* b)
{
    return strcasecmp(a, b);
}
static inline int strnicmp(const char* a, const char* b, std::size_t n)
{
    return strncasecmp(a, b, n);
}
static inline int _strnicmp(const char* a, const char* b, std::size_t n)
{
    return strncasecmp(a, b, n);
}
static inline int _wwlib_memicmp_impl(const void* a, const void* b, std::size_t n)
{
    const unsigned char* pa = static_cast<const unsigned char*>(a);
    const unsigned char* pb = static_cast<const unsigned char*>(b);
    for (std::size_t i = 0; i < n; ++i) {
        int ca = std::tolower(pa[i]);
        int cb = std::tolower(pb[i]);
        if (ca != cb) {
            return ca - cb;
        }
    }
    return 0;
}
static inline int memicmp(const void* a, const void* b, std::size_t n)
{
    return _wwlib_memicmp_impl(a, b, n);
}
static inline int _memicmp(const void* a, const void* b, std::size_t n)
{
    return _wwlib_memicmp_impl(a, b, n);
}
#else
#include <strings.h>
#define stricmp(a, b)        strcasecmp((a), (b))
#define _stricmp(a, b)       strcasecmp((a), (b))
#define strnicmp(a, b, n)    strncasecmp((a), (b), (n))
#define _strnicmp(a, b, n)   strncasecmp((a), (b), (n))
#endif
#endif // _MSVC_STRICMP_DEFINED

// TIM-55: MSVC CRT case-fold-in-place helpers. _strlwr / strupr modify
// the buffer in place and return it; glibc has no equivalent. Targets
// SESSION.CPP:1219 (_strlwr on a copied path), PROFILE.CPP:271 and
// SESSION.CPP:818/843/851 (strupr on phone book entries / section name).
// Same contract as MSVC's CRT: caller owns the buffer, NUL-terminated.
#ifndef _MSVC_STRLWR_STRUPR_DEFINED
#define _MSVC_STRLWR_STRUPR_DEFINED
#ifdef __cplusplus
#include <cctype>
static inline char* _strlwr(char* s)
{
    if (s) {
        for (char* p = s; *p; ++p) {
            *p = (char)std::tolower((unsigned char)*p);
        }
    }
    return s;
}
static inline char* strlwr(char* s) { return _strlwr(s); }
static inline char* _strupr(char* s)
{
    if (s) {
        for (char* p = s; *p; ++p) {
            *p = (char)std::toupper((unsigned char)*p);
        }
    }
    return s;
}
static inline char* strupr(char* s) { return _strupr(s); }
#else
#include <ctype.h>
static inline char* _strlwr(char* s)
{
    if (s) {
        for (char* p = s; *p; ++p) {
            *p = (char)tolower((unsigned char)*p);
        }
    }
    return s;
}
static inline char* strlwr(char* s) { return _strlwr(s); }
static inline char* _strupr(char* s)
{
    if (s) {
        for (char* p = s; *p; ++p) {
            *p = (char)toupper((unsigned char)*p);
        }
    }
    return s;
}
static inline char* strupr(char* s) { return _strupr(s); }
#endif
#endif // _MSVC_STRLWR_STRUPR_DEFINED

// TIM-53: MSVC path-length limits and _makepath / _splitpath family.
// MSVC's <stdlib.h> defines these; glibc has no equivalent. Engine code
// uses _MAX_PATH for char buffers (CDFILE.CPP MAX_PATH alias, SESSION
// _MAX_PATH+1, STARTUP _MAX_PATH, LOADDLG _MAX_NAME+_MAX_EXT) and
// _makepath to assemble drive\dir\fname.ext paths from components
// (AADATA, ADATA, BBDATA, BDATA, CDATA, IDATA, ODATA, SDATA, SIDEBAR,
// TDATA, UDATA, VDATA: 12 TUs). Values mirror MSVC's <stdlib.h>.
#ifndef _MAX_PATH
#define _MAX_PATH    260
#endif
#ifndef _MAX_DRIVE
#define _MAX_DRIVE   3
#endif
#ifndef _MAX_DIR
#define _MAX_DIR     256
#endif
#ifndef _MAX_FNAME
#define _MAX_FNAME   256
#endif
#ifndef _MAX_EXT
#define _MAX_EXT     256
#endif
#ifndef _MAX_NAME
// MSVC names this _MAX_FNAME; some engine code uses _MAX_NAME (see
// LOADDLG.CPP:187 `char fname[_MAX_NAME+_MAX_EXT]`).
#define _MAX_NAME    _MAX_FNAME
#endif

// _makepath: MSVC CRT path assembler. Real signature returns void and
// writes drive:dir\fname.ext into `path`. Engine call sites pass NULL
// for drive/dir (e.g. AADATA:421 _makepath(fullname, NULL, NULL,
// buffer, ".SHP")), so the directory-separator semantics are not
// exercised here. The shim concatenates the non-NULL components with
// portable forward-slash separators. The destination buffer is the
// caller's responsibility -- same contract as MSVC's CRT.
#ifndef _WWLIB_MAKEPATH_DEFINED
#define _WWLIB_MAKEPATH_DEFINED
#ifdef __cplusplus
#include <cstring>
static inline void _makepath(char* path,
                             const char* drive,
                             const char* dir,
                             const char* fname,
                             const char* ext)
{
    if (!path) return;
    path[0] = '\0';
    if (drive && drive[0]) {
        std::strcat(path, drive);
        // MSVC appends ':' if missing. Engine never relies on it.
    }
    if (dir && dir[0]) {
        std::strcat(path, dir);
        std::size_t len = std::strlen(path);
        if (len > 0 && path[len - 1] != '/' && path[len - 1] != '\\') {
            std::strcat(path, "/");
        }
    }
    if (fname && fname[0]) {
        std::strcat(path, fname);
    }
    if (ext && ext[0]) {
        // MSVC tolerates a leading '.' on ext; reproduce that.
        if (ext[0] != '.') {
            std::strcat(path, ".");
        }
        std::strcat(path, ext);
    }
}
#else
#include <string.h>
static inline void _makepath(char* path,
                             const char* drive,
                             const char* dir,
                             const char* fname,
                             const char* ext)
{
    if (!path) return;
    path[0] = '\0';
    if (drive && drive[0]) strcat(path, drive);
    if (dir && dir[0]) {
        strcat(path, dir);
        size_t len = strlen(path);
        if (len > 0 && path[len - 1] != '/' && path[len - 1] != '\\') {
            strcat(path, "/");
        }
    }
    if (fname && fname[0]) strcat(path, fname);
    if (ext && ext[0]) {
        if (ext[0] != '.') strcat(path, ".");
        strcat(path, ext);
    }
}
#endif
#endif // _WWLIB_MAKEPATH_DEFINED

// TIM-99: MSVC unqualified min/max drain. MSVC's <windows.h> defines
// `min`/`max` as macros (unless NOMINMAX is defined), so engine sources
// like SCORE.CPP:1008 / 1064 / 1074 / 1177 / 1185 call `max(a, b)` and
// `min(...)` (lowercase, unqualified) in MSVC-style. On Linux <algorithm>
// is already reached transitively via list.h → function.h, but it puts
// std::max / std::min only in `std`. Most engine TUs work around this with
// a per-TU `#define min/max` block (see TIM-54/TIM-61: AIRCRAFT/ANIM/
// BUILDING/CCINI/SCENARIO/... — 39 TUs). SCORE.CPP doesn't have one. A
// global `using` brings the std overloads into the unqualified namespace
// for all TUs without colliding with per-TU `#define min/max` blocks
// (those override at preprocessor time at the call site, and msvc-compat.h
// is force-included before any per-TU code, so the using-decls are parsed
// while `min`/`max` are still plain identifiers). #include <algorithm> is
// explicit here even though it already arrives transitively, so the shim
// owns the dependency rather than relying on inline.h / list.h ordering.
#ifndef _MSVC_MINMAX_USING_DEFINED
#define _MSVC_MINMAX_USING_DEFINED
#ifdef __cplusplus
#include <algorithm>
using std::min;
using std::max;
#endif
#endif // _MSVC_MINMAX_USING_DEFINED

/* TIM-138: UNREFERENCED_PARAMETER -- Win32 SDK helper macro from
 * winnt.h. Standard expansion is `((void)(P))`, which discards the
 * argument expression as a void value -- no codegen, no warning.
 *
 * Wide-blast safety: ripgrep finds 1 call site in the entire tree
 * (DLLInterface.cpp:6192, inside Get_Occupier_State which ignores
 * its `player_id` argument). No other TU references the macro, so
 * this shim graduates the single call site and cannot regress
 * anything. */
#ifndef UNREFERENCED_PARAMETER
#define UNREFERENCED_PARAMETER(P) ((void)(P))
#endif

// TIM-197: _splitpath real implementation. MSVC CRT path decomposer.
// Three engine call sites: LOADDLG.CPP:760 (reads ext, atoi(ext+1)),
// MIXFILE.CPP Finder (reads name+ext to reconstruct bare FILENAME.EXT),
// STARTUP.CPP:342 (in disabled #if(0) block — never executed).
// The inert no-op broke MFCD::Finder: it always produced name="" ext=""
// so stricmp("","LOCAL.MIX") never matched → MFCD::Cache always returned
// false → assert(ok) fired after LOCAL.MIX ctor.
// Implements MSVC semantics: drive="X:" dir="path\" fname="base" ext=".ext"
#ifndef _WWLIB_SPLITPATH_DEFINED
#define _WWLIB_SPLITPATH_DEFINED
#include <cstring>
static inline void _splitpath(const char* path,
                              char* drive,
                              char* dir,
                              char* fname,
                              char* ext)
{
    if (drive) drive[0] = '\0';
    if (dir)   dir[0]   = '\0';
    if (fname) fname[0] = '\0';
    if (ext)   ext[0]   = '\0';
    if (!path || !path[0]) return;

    const char* p = path;

    // Drive: "X:" at start
    if (path[0] && path[1] == ':') {
        if (drive) { drive[0] = path[0]; drive[1] = ':'; drive[2] = '\0'; }
        p = path + 2;
    }

    // Last directory separator
    const char* last_sep = NULL;
    for (const char* q = p; *q; ++q)
        if (*q == '/' || *q == '\\') last_sep = q;

    const char* name_start = p;
    if (last_sep) {
        if (dir) {
            std::size_t len = (std::size_t)(last_sep - p + 1);
            std::strncpy(dir, p, len);
            dir[len] = '\0';
        }
        name_start = last_sep + 1;
    }

    // Last dot in the name part → extension
    const char* last_dot = NULL;
    for (const char* q = name_start; *q; ++q)
        if (*q == '.') last_dot = q;

    if (last_dot) {
        if (fname) {
            std::size_t len = (std::size_t)(last_dot - name_start);
            std::strncpy(fname, name_start, len);
            fname[len] = '\0';
        }
        if (ext) std::strcpy(ext, last_dot); // includes leading '.'
    } else {
        if (fname) std::strcpy(fname, name_start);
    }
}
#endif // _WWLIB_SPLITPATH_DEFINED

#endif // !_MSC_VER

// TIM-9: pull in the Win32 type taxonomy stub for every TU. Several
// upstream headers (DDRAW.H, MMSYSTEM.H, the wwlib32 chain) reference
// BOOL/HRESULT/GUID/LPSTR without an explicit #include <windows.h>,
// because the original build relied on FUNCTION.H's `#ifdef WIN32`
// guard pulling windows.h in first. We don't define WIN32 in the
// Linux preprocessor (it would re-enable too much Win32-only code in
// one go), so we make windows.h visible the same way as the rest of
// this shim: via -include on the command line. The header is fully
// guarded so re-inclusion is free.
#include "windows.h"

// TIM-135: Glyphx wrapper compile-floor compatibility for
// DLLInterface.cpp / DLLInterfaceEditor.cpp.
//
// (1) __declspec(dllexport/dllimport/...): GCC requires -fdeclspec to
//     accept the keyword; we macro-stub it to a no-op instead. This is
//     a parser-level no-op only — we are not building a PE DLL on Linux.
//     Wide-blast safety: ripgrep confirms __declspec appears in only
//     three RedAlert files: MOVIE.H (gated behind #ifdef MPEGMOVIE,
//     never reached) and the two DLLInterface*.cpp TUs covered here.
//
// (2) OLE Automation declarations (SAFEARRAY / SAFEARRAYBOUND /
//     SafeArrayCreate / SafeArrayAccessData / SafeArrayUnaccessData /
//     SUCCEEDED / VT_UI1 / VT_I4 / VARTYPE) needed by
//     DLLInterfaceEditor.cpp's CNC_Editor_Get_Cell_Texture_Buffer and
//     CNC_Editor_Get_Template_Data exports (lines 36, 38, 542, 592,
//     596, 600, 627, 646, 671, 674, 677). HRESULT is already defined
//     in linux/win32-stubs/windows.h. Under -fsyntax-only the linker
//     is never invoked, so declarations alone suffice. Real OLE
//     Automation runtime (or a Wine-backed replacement) is a
//     separate later port.
//     Wide-blast safety: ripgrep confirms zero other RedAlert TUs
//     reference SAFEARRAY / SafeArray* / VT_UI1 / VT_I4.
//     Placed after #include "windows.h" so HRESULT is already defined
//     when the SafeArray* function declarations are parsed.
#ifndef __declspec
#define __declspec(x)
#endif

#ifndef SUCCEEDED
#define SUCCEEDED(hr) (((HRESULT)(hr)) >= 0)
#endif

#ifndef _TIM135_OLE_AUTOMATION_DEFINED
#define _TIM135_OLE_AUTOMATION_DEFINED
typedef unsigned short VARTYPE;
#define VT_I4   3
#define VT_UI1 17

typedef struct tagSAFEARRAYBOUND {
    unsigned long cElements;
    long          lLbound;
} SAFEARRAYBOUND;

typedef struct tagSAFEARRAY SAFEARRAY;

#ifdef __cplusplus
extern "C" {
#endif
SAFEARRAY* SafeArrayCreate(VARTYPE vt, unsigned int cDims, SAFEARRAYBOUND* rgsabound);
HRESULT    SafeArrayAccessData(SAFEARRAY* psa, void** ppvData);
HRESULT    SafeArrayUnaccessData(SAFEARRAY* psa);
#ifdef __cplusplus
}
#endif
#endif // _TIM135_OLE_AUTOMATION_DEFINED

/* TIM-339: sprintf_s is an MSVC safe-string extension; map to snprintf on Linux. */
#ifndef _MSC_VER
#include <stdio.h>
#define sprintf_s(buf, sz, ...) snprintf((buf), (sz), __VA_ARGS__)
#endif

// TIM-352: CDFileClass-based Write_PCX_File overload for CHEAT_KEYS screenshot
// code in GADGET.CPP. CDFileClass has no implicit char* conversion so the
// existing Write_PCX_File(char*,...) declaration doesn't match. This no-op
// overload satisfies the call; Benches is always NULL so screenshots never fire.
#ifdef CHEAT_KEYS
#ifdef __cplusplus
class CDFileClass;
class GraphicBufferClass;
class PaletteClass;
static inline int Write_PCX_File(CDFileClass&, GraphicBufferClass&, PaletteClass*) { return 0; }
#endif
#endif

// TIM-376: Emscripten/WASM-specific compatibility layer.
//
// Embedded here (rather than a second force-include) to avoid CMake's
// deduplication of adjacent "-include" flags collapsing two separate
// preinclude pairs into a single -include with two paths.
//
// Fix 1 — `register` keyword: Clang/C++17 makes it a hard error via
//   [-Wregister]. GCC accepts it with -fpermissive; Clang does not.
//   The pragma downgrades the diagnostic to nothing.
//
// Fix 2 — random() type conflict: musl's stdlib.h always declares
//   `long int random(void)`.  WIN32LIB/MISC.H later declares
//   `unsigned long random(unsigned long mod)` — a conflicting
//   redeclaration of a C-linkage function, which Clang rejects even
//   with -fpermissive.  Include <stdlib.h> first to lock in the musl
//   declaration, then rename every subsequent occurrence of `random`
//   to `ww_lib_random` via macro.  MISC.H's declaration, IRANDOM.CPP's
//   definition, and all WW call sites are renamed consistently; the
//   standard-library `random()` (already declared, no longer subject
//   to the macro) is unaffected.
#ifdef __EMSCRIPTEN__
#pragma clang diagnostic ignored "-Wregister"
// Fix 3 — narrowing case values: hash macros like PARM_INSTALL (0xD95C68A2)
//   exceed LONG_MAX on wasm32 (32-bit signed long). Clang's
//   [-Wc++11-narrowing] is DefaultError and not suppressed by -w.
#pragma clang diagnostic ignored "-Wc++11-narrowing"
// Fix 5 — non-POD variadic args: TECHNO.CPP passes StageClass through Printf
//   variadic arg. Clang makes [-Wnon-pod-varargs] a hard error in C++17.
#pragma clang diagnostic ignored "-Wnon-pod-varargs"
// Fix 4 — TARGET_NONE pointer assignment: on WASM ((long)0) cannot be
//   implicitly assigned to pointer types (C++ hard error, not a warning).
//   We define a sentinel class with dual conversion operators so that
//   TARGET_NONE works in both long/TARGET contexts (for integer comparisons
//   and TargetClass constructor resolution) AND pointer contexts (for the
//   Code_Pointers / Decode_Pointers null-encoding pattern). DEFINES.H
//   is patched to use this sentinel via #ifdef __EMSCRIPTEN__.
#ifdef __cplusplus
// _WasmTargetNone is in the global namespace (not anonymous) so TARGET.H
// can forward-declare it and add a TargetClass(_WasmTargetNone) ctor.
struct _WasmTargetNone {
    constexpr operator long() const noexcept { return 0L; }
    template<class T> constexpr operator T*() const noexcept { return nullptr; }
};
inline constexpr _WasmTargetNone _wasm_target_none;
#endif // __cplusplus
#include <stdlib.h>
#define random ww_lib_random
#endif // __EMSCRIPTEN__

#endif // LINUX_WIN32_STUBS_MSVC_COMPAT_H
