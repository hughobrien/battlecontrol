// TIM-6: MSVC / Watcom compatibility shim.
//
// Force-included on non-MSVC builds (see scripts/first-compile-pass3.sh
// and CMakeLists.txt). Keeps the upstream sources untouched for the
// MSVC keyword and CRT-extension cases identified by TIM-4 pass 2:
//
//   * empty calling-convention macros (__cdecl / __stdcall / __fastcall)
//     and Win16-era pointer attributes (FAR / NEAR / PASCAL / HUGE) so
//     the parser advances past Win32 prototypes;
//   * a typedef for __int64 / unsigned __int64 (used in fixed-point
//     math in FIXED.H and the GlyphX DLL interface);
//   * an inline _lrotl shim used by CRC.CPP / CRC.H.
//
// MSVC is unchanged because its compiler defines _MSC_VER and provides
// all of the above natively.

#ifndef LINUX_WIN32_STUBS_MSVC_COMPAT_H
#define LINUX_WIN32_STUBS_MSVC_COMPAT_H

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

// MSVC's 64-bit integer extension. <cstdint>'s int64_t is the
// portable equivalent on Linux. Use the GCC/Clang extension
// __extension__ to silence -Wpedantic warnings about the typedef.
#ifdef __cplusplus
#include <cstdint>
#else
#include <stdint.h>
#endif

#if !defined(__INT64_DEFINED)
#define __INT64_DEFINED
typedef int64_t __int64;
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

#endif // LINUX_WIN32_STUBS_MSVC_COMPAT_H
