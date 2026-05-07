/* TIM-9 stub: minimum-viable Win32 type taxonomy.
 *
 * Populated to satisfy the upstream Win32 declarations the engine drags
 * in via WIN32LIB headers (DDRAW.H, MMSYSTEM.H, the wwlib32 chain).
 * Every declaration here is the smallest opaque shape that lets cc1plus
 * advance past parse — NOT a Win32 SDK port. We are not implementing
 * COM, DirectDraw, DirectSound, the registry, GDI, kernel handles, or
 * any other subsystem; replacement of those happens in TIM-10+.
 *
 * Rules (see linux/win32-stubs/README.md):
 *   - Declarations only, no implementations.
 *   - Smallest shape that lets the parser reach the next layer.
 *   - Guard everything so we can't conflict with future real ports.
 */
#ifndef LINUX_STUBS_WINDOWS_H
#define LINUX_STUBS_WINDOWS_H

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
#else
#include <stddef.h>
#include <stdint.h>
#endif

/* ------------------------------------------------------------------
 * Standard POSIX seek constants. <windows.h> normally pulls in <stdio.h>
 * transitively, and several upstream files use SEEK_SET/CUR/END without
 * an explicit <stdio.h> include. Reproduce the constants here so the
 * include chain that gets <windows.h> also gets the stdio constants,
 * matching what the original MSVC build would have provided.
 * ------------------------------------------------------------------ */
#ifndef SEEK_SET
#define SEEK_SET 0
#endif
#ifndef SEEK_CUR
#define SEEK_CUR 1
#endif
#ifndef SEEK_END
#define SEEK_END 2
#endif

/* ------------------------------------------------------------------
 * Boolean / void / fixed-width integer typedefs.
 *
 * Win32 BOOL is `int` (signed, 4 bytes on every Win32-ish ABI). DWORD
 * is exactly 32-bit unsigned regardless of host long width — using
 * uint32_t here keeps semantics on LP64 Linux. LONG stays `long` to
 * match the upstream sizeof(LONG) == sizeof(void*) assumption that
 * pervades the codebase; the LP32→LP64 width audit is TIM-7+.
 * ------------------------------------------------------------------ */
typedef int                BOOL;
typedef unsigned char      BOOLEAN;
typedef void               VOID;
typedef unsigned char      BYTE;
typedef uint16_t           WORD;
typedef uint32_t           DWORD;
typedef unsigned int       UINT;
typedef long               LONG;
typedef unsigned long      ULONG;
typedef int                INT;
typedef short              SHORT;
typedef unsigned short     USHORT;
typedef wchar_t            WCHAR;

#ifndef TRUE
#define TRUE  1
#endif
#ifndef FALSE
#define FALSE 0
#endif
/* NULL comes from <cstddef>/<stddef.h> above; do not redefine. */

/* ------------------------------------------------------------------
 * Opaque handle types. All HANDLE-shaped names are pointer-sized; the
 * actual referent is a Win32 kernel object we cannot reproduce here.
 * Pointer-to-incomplete is enough for declarations and parameter
 * passing; assignments and comparisons against NULL still parse.
 * ------------------------------------------------------------------ */
typedef void*              HANDLE;
typedef void*              HWND;
typedef void*              HINSTANCE;
typedef void*              HMODULE;
typedef void*              HDC;
typedef void*              HBITMAP;
typedef void*              HICON;
typedef void*              HCURSOR;
typedef void*              HMENU;
typedef void*              HKEY;
typedef void*              HMONITOR;
typedef void*              HPALETTE;     /* GDI palette handle, used by upstream blit code */

/* TIM-31: INVALID_HANDLE_VALUE. Win32 SDK form is
 * `((HANDLE)(LONG_PTR)-1)`; on LP64 Linux we use intptr_t to get the
 * pointer-sized signed integer with no platform-dependent assumptions.
 * Referenced by REDALERT/RAWFILE.H:269 (RawFileClass ctor) and :326
 * (Is_Open) inside `#ifdef WIN32` blocks; the WWLIB32 chain defensively
 * defines WIN32 in several headers (wwstd.h, TIMER.H, RAWFILE.H,
 * WINCOMM.H, MODEMREG.H), so on Linux this constant must exist as a
 * stub even though we never run a Win32 kernel handle. */
#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#endif

/* HRESULT is `long` on Win32 and is treated as a signed 32-bit error
 * code throughout DDRAW.H (DDERR_* macros are signed long literals). */
typedef long               HRESULT;

/* ------------------------------------------------------------------
 * String / byte pointer typedefs.
 * ------------------------------------------------------------------ */
typedef char*              LPSTR;
typedef const char*        LPCSTR;
typedef wchar_t*           LPWSTR;
typedef const wchar_t*     LPCWSTR;
typedef void*              LPVOID;
typedef const void*        LPCVOID;
typedef BYTE*              LPBYTE;
typedef WORD*              LPWORD;
typedef DWORD*             LPDWORD;
typedef LONG*              LPLONG;

/* ------------------------------------------------------------------
 * Geometry primitives — RECT/POINT/SIZE.
 *
 * Judgement-call additions (per TIM-9's "if it surfaces, add the
 * minimum-viable shape" rule). DDRAW.H and the wwlib32 blit headers
 * pass `LPRECT` through every clipping/blit signature. Defining the
 * struct opaquely here unblocks ~400 pass-3 errors with the same
 * zero-implementation policy as everything else above. The field
 * layout matches the real Win32 RECT so any byte-level copy from
 * engine-side code is harmless.
 * ------------------------------------------------------------------ */
typedef struct tagRECT  { LONG left, top, right, bottom; } RECT;
typedef RECT*              LPRECT;
typedef const RECT*        LPCRECT;

typedef struct tagPOINT { LONG x, y; } POINT;
typedef POINT*             LPPOINT;

typedef struct tagSIZE  { LONG cx, cy; } SIZE;
typedef SIZE*              LPSIZE;

/* ------------------------------------------------------------------
 * GUID. DDRAW.H takes `GUID FAR *` in its enumeration callbacks and
 * COM IID/CLSID arguments. Layout matches the real Win32 GUID (16
 * bytes, well-defined ABI) so any cast/pun against engine code that
 * encodes a GUID as bytes still works. Contents are inert — we are
 * not running the COM activation path.
 * ------------------------------------------------------------------ */
typedef struct _GUID {
    DWORD Data1;
    WORD  Data2;
    WORD  Data3;
    BYTE  Data4[8];
} GUID;
typedef GUID*              LPGUID;
typedef GUID               IID;
typedef GUID               CLSID;
typedef const GUID*        REFGUID;
typedef const IID*         REFIID;
typedef const CLSID*       REFCLSID;

/* ------------------------------------------------------------------
 * DEFINE_GUID. Upstream DDRAW.H invokes this macro at file scope to
 * declare named GUID constants (CLSID_DirectDraw, IID_*, ...). The
 * real macro from <guiddef.h> emits an `EXTERN_C const GUID name;`
 * declaration and, when INITGUID is defined, the initialiser. We
 * absorb both forms into a single static-const definition with zero
 * payload — the GUIDs are never actually used because we never call
 * CoCreateInstance / DirectDrawCreate. This unblocks ~1600 of the
 * pass-3 "expected constructor before '(' token" errors.
 * ------------------------------------------------------------------ */
#ifndef DEFINE_GUID
#define DEFINE_GUID(name, l, w1, w2, b1, b2, b3, b4, b5, b6, b7, b8) \
    static const GUID name = { 0u, 0u, 0u, { 0, 0, 0, 0, 0, 0, 0, 0 } }
#endif

/* MAKE_HRESULT — DDRAW.H expands DDERR_* values via MAKE_DDHRESULT
 * which expands to MAKE_HRESULT. Pack the bits the same way the real
 * macro does so any `case DDERR_FOO:` that survives still constant-
 * folds to the right integer. We do not honour HRESULT semantics. */
#ifndef MAKE_HRESULT
#define MAKE_HRESULT(sev, fac, code) \
    ((HRESULT)(((unsigned long)(sev)  << 31) \
             | ((unsigned long)(fac)  << 16) \
             |  (unsigned long)(code)))
#endif

/* ------------------------------------------------------------------
 * DirectDraw enumeration callback function-pointer typedefs.
 *
 * DDRAW.H also typedefs LPDDENUMCALLBACKA/W itself when _WIN32 is
 * defined (and several wwlib32 headers force-define _WIN32). C++17
 * permits a duplicate typedef of the same type, and FAR/PASCAL are
 * empty macros in our msvc-compat shim, so the redeclaration is
 * benign. The EXA/EXW variants are NOT redefined by DDRAW.H, but the
 * issue lists them as in-scope so we provide opaque shapes.
 * ------------------------------------------------------------------ */
typedef BOOL (*LPDDENUMCALLBACKA)  (GUID*, LPSTR,  LPSTR,  LPVOID);
typedef BOOL (*LPDDENUMCALLBACKW)  (GUID*, LPWSTR, LPWSTR, LPVOID);
typedef BOOL (*LPDDENUMCALLBACKEXA)(GUID*, LPSTR,  LPSTR,  LPVOID, HMONITOR);
typedef BOOL (*LPDDENUMCALLBACKEXW)(GUID*, LPWSTR, LPWSTR, LPVOID, HMONITOR);

/* TIM-46: mirror real Win32 transitive include of <mmsystem.h>.
 * DSOUND.H references LPWAVEFORMATEX outside any _NO_COM / _WIN32
 * guard but never #includes mmsystem.h itself; the SDK relied on the
 * windows.h -> mmsystem.h chain to make the typedef visible. Pull our
 * stub mmsystem.h here so DSOUND.H sees WAVEFORMATEX through the
 * force-included msvc-compat.h -> windows.h -> mmsystem.h path. */
#include "mmsystem.h"

/* TIM-51: same transitive-include trick for the Winsock1 type taxonomy.
 * REDALERT/tcpip.h declares TcpipManagerClass members typed SOCKET /
 * WSADATA / IN_ADDR / struct in_addr without including <winsock.h>;
 * function.h doesn't pull it either. Upstream's Win32 build relied on
 * a /FI or PCH path that made winsock1 globally visible. Pull our stub
 * winsock.h from windows.h so every force-include of msvc-compat.h ->
 * windows.h reaches the taxonomy, mirroring TIM-46. */
#include "winsock.h"

#endif /* LINUX_STUBS_WINDOWS_H */
