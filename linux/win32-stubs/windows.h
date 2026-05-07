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
/* TIM-53: UCHAR is needed by wsnwlink.h:140 (IPX_ADDRESS_DATA fields).
 * Win32 SDK has it as `unsigned char`. */
typedef unsigned char      UCHAR;

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

/* TIM-63: named HRESULT error-code constants. The DDRAW.H shim aliases
 * a handful of DDERR_* values to the standard <winerror.h> named
 * HRESULTs (E_FAIL at ddraw.h:2623, E_INVALIDARG at 2660, E_OUTOFMEMORY
 * and E_NOTIMPL further on). Without these the entire DDRAW.CPP shim
 * chain fails on the first DDERR_GENERIC line. Standard SDK values from
 * <winerror.h> (sev=1, fac=FACILITY_WIN32 for INVALIDARG, fac=FACILITY_NULL
 * for the rest); engine code never compares against them numerically,
 * so the literals only need to parse and link as ordinary HRESULTs. */
#ifndef E_FAIL
#define E_FAIL          ((HRESULT)0x80004005L)
#endif
#ifndef E_INVALIDARG
#define E_INVALIDARG    ((HRESULT)0x80070057L)
#endif
#ifndef E_OUTOFMEMORY
#define E_OUTOFMEMORY   ((HRESULT)0x8007000EL)
#endif
#ifndef E_NOTIMPL
#define E_NOTIMPL       ((HRESULT)0x80004001L)
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

/* TIM-53: WM_USER -- Win32 message-id base for user-defined messages.
 * Real <winuser.h> has `#define WM_USER 0x0400`. WSProto.h:60-61
 * (WM_IPXASYNCEVENT / WM_UDPASYNCEVENT) and WINSTUB.CPP:58 reference
 * it without including <winuser.h>; upstream relied on windows.h's
 * transitive winuser pull. Kept as a bare integer constant since the
 * engine only computes message ids from it, never dispatches them. */
#ifndef WM_USER
#define WM_USER     0x0400
#endif

/* TIM-53: MAX_PATH alias for path-buffer dimensions. MSVC <windows.h>
 * exposes both MAX_PATH (260) and the lowercase _MAX_PATH from stdlib.h
 * via the same headers. Engine code uses MAX_PATH (CDFILE.CPP:394) and
 * _MAX_PATH (SESSION.CPP:1217, STARTUP.CPP:54) interchangeably. The
 * underscored variant is defined in msvc-compat.h. Mirror MAX_PATH here
 * so windows.h consumers see it without needing to pull stdlib. */
#ifndef MAX_PATH
#define MAX_PATH    260
#endif

/* TIM-53: FILETIME -- Win32 64-bit timestamp split across two DWORDs.
 * Real <minwinbase.h> has the same shape; engine code in EVENT.CPP:610
 * uses `FILETIME ft; GetSystemTimeAsFileTime(&ft);` then composes a
 * 64-bit unsigned from the low/high halves. Stub matches the layout
 * so engine arithmetic on dwLowDateTime / dwHighDateTime parses; the
 * GetSystemTimeAsFileTime declaration unblocks the call site. The
 * actual time-source replacement is a separate later port. */
typedef struct _FILETIME {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME, *LPFILETIME, *PFILETIME;

#ifdef __cplusplus
extern "C" {
#endif
void GetSystemTimeAsFileTime(LPFILETIME);
#ifdef __cplusplus
}
#endif

/* TIM-53: OVERLAPPED -- Win32 async I/O context. Real <minwinbase.h>
 * has a tagged struct with an internal pointer and an HANDLE event
 * field; engine code in WIN32LIB/WINCOMM.H:237/242 stores OVERLAPPED
 * by value as class members (ReadOverlap / WriteOverlap) under a
 * `#ifdef WIN32` guarded block. Layout matches the real ABI for any
 * byte-level reasoning, but no field is read by code that we are
 * actually compiling -- the wincomm path is dormant on Linux. */
typedef struct _OVERLAPPED {
    ULONG*  Internal;
    ULONG*  InternalHigh;
    union {
        struct {
            DWORD Offset;
            DWORD OffsetHigh;
        } DUMMYSTRUCTNAME;
        void* Pointer;
    } DUMMYUNIONNAME;
    HANDLE  hEvent;
} OVERLAPPED, *LPOVERLAPPED;

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

/* TIM-52: same transitive-include trick for the Win32 DDEML handle
 * taxonomy. REDALERT/dde.h declares Instance_Class members typed HSZ /
 * HCONV / HDDEDATA without including <ddeml.h>; ccdde.h pulls dde.h
 * under `#ifdef WIN32` but never includes ddeml itself. Upstream relied
 * on /FI or PCH to make the taxonomy globally visible. Pull our stub
 * ddeml.h here so the full force-include chain reaches it. */
#include "ddeml.h"

/* TIM-54: CRITICAL_SECTION -- Win32 user-mode mutex object. Real
 * <synchapi.h> / <minwinbase.h> exposes RTL_CRITICAL_SECTION as a tagged
 * struct with kernel-internal fields (DebugInfo, LockCount, OwningThread,
 * LockSemaphore, SpinCount, ...). Engine code stores it by value as a
 * class member in WIN32LIB/MOUSE.H:103 (WWMouseClass::MouseCriticalSection),
 * WIN32LIB/SOUNDINT.H:185 (LockedDataType::AudioCriticalSection), and
 * WIN32LIB/AUDIO.H:157 (extern GlobalAudioCriticalSection). Layout here
 * is opaque vs the real ABI -- we never run any of the Initialize/Enter/
 * LeaveCriticalSection paths (those would be Pthread mutex shims in a
 * later port). Field set is intentionally inert; we just need a complete
 * type so the member declarations parse. Prerequisite for TIM-54's
 * source-level fix that pulls WIN32LIB/MOUSE.H into the WWMouseClass
 * call sites (DIALOG.CPP, GSCREEN.CPP, QUEUE.CPP). */
typedef struct _RTL_CRITICAL_SECTION {
    void*  DebugInfo;
    LONG   LockCount;
    LONG   RecursionCount;
    HANDLE OwningThread;
    HANDLE LockSemaphore;
    ULONG* SpinCount;
} CRITICAL_SECTION, *LPCRITICAL_SECTION, *PCRITICAL_SECTION;

/* TIM-68: Initialize/Enter/Leave/DeleteCriticalSection -- inert
 * stubs. WIN32LIB/MOUSEWW.CPP:78,113,142,150 are the first call
 * sites that actually invoke these (prior TUs only declared a
 * CRITICAL_SECTION member). The whole mouse/audio threading path is
 * dormant on the Linux port; these no-ops just let MOUSEWW.CPP parse.
 * Pthread-backed implementations land later. */
static inline void InitializeCriticalSection(LPCRITICAL_SECTION) {}
static inline void DeleteCriticalSection(LPCRITICAL_SECTION) {}
static inline void EnterCriticalSection(LPCRITICAL_SECTION) {}
static inline void LeaveCriticalSection(LPCRITICAL_SECTION) {}

/* TIM-55: PALETTEENTRY -- Win32 GDI palette entry. REDALERT/WIN32LIB/
 * DDRAW.CPP:55 declares `PALETTEENTRY PaletteEntries[256]` and writes
 * .peRed/.peGreen/.peBlue/.peFlags fields at lines 739-741. Layout
 * matches the Win32 SDK (4 BYTE fields, 4 bytes total). The blit/palette
 * subsystem is dormant under the DDraw stub; this just lets the parser
 * advance past the global array declaration that gates the rest of
 * DDRAW.CPP. */
#ifndef _PALETTEENTRY_DEFINED
#define _PALETTEENTRY_DEFINED
typedef struct tagPALETTEENTRY {
    BYTE peRed;
    BYTE peGreen;
    BYTE peBlue;
    BYTE peFlags;
} PALETTEENTRY, *PPALETTEENTRY, *LPPALETTEENTRY;
#endif

/* TIM-55: DLL_PROCESS_* / DLL_THREAD_* reason codes. REDALERT/STARTUP.CPP
 * :100-141 implements DllMain(...) with the standard four-case switch on
 * fdwReason. Real <minwinbase.h> values (1, 0, 2, 3). The DLL is never
 * actually loaded on Linux; the call sites just need the integer
 * constants to compile. */
#ifndef DLL_PROCESS_DETACH
#define DLL_PROCESS_DETACH 0
#endif
#ifndef DLL_PROCESS_ATTACH
#define DLL_PROCESS_ATTACH 1
#endif
#ifndef DLL_THREAD_ATTACH
#define DLL_THREAD_ATTACH  2
#endif
#ifndef DLL_THREAD_DETACH
#define DLL_THREAD_DETACH  3
#endif

/* TIM-56: WIN32_FIND_DATA -- Win32 directory-enumeration record. Real
 * <fileapi.h> shape: dwFileAttributes + three FILETIMEs + size halves +
 * two reserved DWORDs + cFileName[MAX_PATH] + cAlternateFileName[14].
 * SESSION.CPP:1325/1446 declares one on the stack, calls FindFirstFile/
 * FindNextFile, and reads block.dwFileAttributes (line 1328) and
 * block.cAlternateFileName / block.cFileName (lines 1331-1332). Layout
 * matches the SDK so any sizeof / pointer-cast through engine code
 * stays well-defined; the file-enumeration path itself is dormant under
 * the stub (FindFirstFile resolves to the no-op declaration in
 * win32-stubs/fileapi.h-equivalent surface, which a later port replaces
 * with opendir/readdir). */
#ifndef _WIN32_FIND_DATA_DEFINED
#define _WIN32_FIND_DATA_DEFINED
typedef struct _WIN32_FIND_DATAA {
    DWORD    dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD    nFileSizeHigh;
    DWORD    nFileSizeLow;
    DWORD    dwReserved0;
    DWORD    dwReserved1;
    char     cFileName[MAX_PATH];
    char     cAlternateFileName[14];
} WIN32_FIND_DATAA, *PWIN32_FIND_DATAA, *LPWIN32_FIND_DATAA;
typedef WIN32_FIND_DATAA  WIN32_FIND_DATA;
typedef PWIN32_FIND_DATAA PWIN32_FIND_DATA;
typedef LPWIN32_FIND_DATAA LPWIN32_FIND_DATA;
#endif

/* TIM-56: FILE_ATTRIBUTE_* bitflags read out of WIN32_FIND_DATA.
 * dwFileAttributes. SESSION.CPP:1328/1448 masks against the
 * DIRECTORY|HIDDEN|SYSTEM|TEMPORARY set. RAWFILE.CPP and CONQUER.CPP
 * pass FILE_ATTRIBUTE_NORMAL/READONLY to CreateFile. Standard SDK
 * values from <fileapi.h>; they're compile-time bit constants only. */
#ifndef FILE_ATTRIBUTE_READONLY
#define FILE_ATTRIBUTE_READONLY  0x00000001
#endif
#ifndef FILE_ATTRIBUTE_HIDDEN
#define FILE_ATTRIBUTE_HIDDEN    0x00000002
#endif
#ifndef FILE_ATTRIBUTE_SYSTEM
#define FILE_ATTRIBUTE_SYSTEM    0x00000004
#endif
#ifndef FILE_ATTRIBUTE_DIRECTORY
#define FILE_ATTRIBUTE_DIRECTORY 0x00000010
#endif
#ifndef FILE_ATTRIBUTE_ARCHIVE
#define FILE_ATTRIBUTE_ARCHIVE   0x00000020
#endif
#ifndef FILE_ATTRIBUTE_NORMAL
#define FILE_ATTRIBUTE_NORMAL    0x00000080
#endif
#ifndef FILE_ATTRIBUTE_TEMPORARY
#define FILE_ATTRIBUTE_TEMPORARY 0x00000100
#endif

/* TIM-56: MessageBox style flags. WIN32LIB/DDRAW.CPP:90+ and many
 * STARTUP.CPP / BMP8.CPP / MPMGRW.CPP sites pass MB_OK |
 * MB_ICONEXCLAMATION (et al.) as the fourth argument. Real <winuser.h>
 * defines them as a packed bit set: button group in low nibble, icon
 * group in 0xF0, modality / default button in higher bits. We are not
 * dispatching any actual dialog; the macros just need to be integer
 * constants so the bitwise-OR call sites parse. Values match the SDK
 * (https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-messageboxa). */
#ifndef MB_OK
#define MB_OK                0x00000000L
#endif
#ifndef MB_OKCANCEL
#define MB_OKCANCEL          0x00000001L
#endif
#ifndef MB_ABORTRETRYIGNORE
#define MB_ABORTRETRYIGNORE  0x00000002L
#endif
#ifndef MB_YESNOCANCEL
#define MB_YESNOCANCEL       0x00000003L
#endif
#ifndef MB_YESNO
#define MB_YESNO             0x00000004L
#endif
#ifndef MB_RETRYCANCEL
#define MB_RETRYCANCEL       0x00000005L
#endif
#ifndef MB_ICONHAND
#define MB_ICONHAND          0x00000010L
#endif
#ifndef MB_ICONSTOP
#define MB_ICONSTOP          MB_ICONHAND
#endif
#ifndef MB_ICONERROR
#define MB_ICONERROR         MB_ICONHAND
#endif
#ifndef MB_ICONQUESTION
#define MB_ICONQUESTION      0x00000020L
#endif
#ifndef MB_ICONEXCLAMATION
#define MB_ICONEXCLAMATION   0x00000030L
#endif
#ifndef MB_ICONWARNING
#define MB_ICONWARNING       MB_ICONEXCLAMATION
#endif
#ifndef MB_ICONASTERISK
#define MB_ICONASTERISK      0x00000040L
#endif
#ifndef MB_ICONINFORMATION
#define MB_ICONINFORMATION   MB_ICONASTERISK
#endif
#ifndef MB_DEFBUTTON1
#define MB_DEFBUTTON1        0x00000000L
#endif
#ifndef MB_DEFBUTTON2
#define MB_DEFBUTTON2        0x00000100L
#endif
#ifndef MB_DEFBUTTON3
#define MB_DEFBUTTON3        0x00000200L
#endif
#ifndef MB_APPLMODAL
#define MB_APPLMODAL         0x00000000L
#endif
#ifndef MB_SYSTEMMODAL
#define MB_SYSTEMMODAL       0x00001000L
#endif
#ifndef MB_TASKMODAL
#define MB_TASKMODAL         0x00002000L
#endif

/* TIM-56: ShowWindow nCmdShow values. STARTUP.CPP:180 declares
 * `int command_show = SW_HIDE;` and CCDDE.CPP / INTERNET.CPP /
 * NETDLG.CPP / WOLAPIOB.CPP call ShowWindow(...) with SW_RESTORE,
 * SW_MINIMIZE, SW_SHOW, SW_SHOWMAXIMIZED, etc. Real <winuser.h> values.
 * The actual ShowWindow path is dormant on Linux (no HWND universe);
 * the values are only consumed as integer parameters. */
#ifndef SW_HIDE
#define SW_HIDE             0
#endif
#ifndef SW_SHOWNORMAL
#define SW_SHOWNORMAL       1
#endif
#ifndef SW_NORMAL
#define SW_NORMAL           1
#endif
#ifndef SW_SHOWMINIMIZED
#define SW_SHOWMINIMIZED    2
#endif
#ifndef SW_SHOWMAXIMIZED
#define SW_SHOWMAXIMIZED    3
#endif
#ifndef SW_MAXIMIZE
#define SW_MAXIMIZE         3
#endif
#ifndef SW_SHOWNOACTIVATE
#define SW_SHOWNOACTIVATE   4
#endif
#ifndef SW_SHOW
#define SW_SHOW             5
#endif
#ifndef SW_MINIMIZE
#define SW_MINIMIZE         6
#endif
#ifndef SW_SHOWMINNOACTIVE
#define SW_SHOWMINNOACTIVE  7
#endif
#ifndef SW_SHOWNA
#define SW_SHOWNA           8
#endif
#ifndef SW_RESTORE
#define SW_RESTORE          9
#endif

/* TIM-59: FindFirstFile / FindNextFile / FindClose -- Win32 directory
 * enumeration triplet. SESSION.CPP:1325/1446 walks "*.PKT" / "*.MPR"
 * with the standard `handle = FindFirstFile(...); while (handle !=
 * INVALID_HANDLE_VALUE) { ...; if (!FindNextFile(handle, &block))
 * break; }` shape. The stub returns INVALID_HANDLE_VALUE so the loop
 * terminates without entering the body; FindNextFile / FindClose are
 * declared so call sites parse, but never executed. A real port wires
 * these to opendir/readdir + glob. The WIN32_FIND_DATA payload is
 * untouched on the failure path. */
static inline HANDLE FindFirstFileA(LPCSTR, LPWIN32_FIND_DATAA) { return INVALID_HANDLE_VALUE; }
static inline BOOL   FindNextFileA(HANDLE, LPWIN32_FIND_DATAA)  { return FALSE; }
static inline BOOL   FindClose(HANDLE)                          { return FALSE; }
#ifndef FindFirstFile
#define FindFirstFile FindFirstFileA
#endif
#ifndef FindNextFile
#define FindNextFile  FindNextFileA
#endif

/* TIM-59: MessageBox / MessageBoxA -- Win32 dialog box. WIN32LIB/DDRAW
 * .CPP:90+ chain calls MessageBox(MainWindow, text, caption, MB_*) for
 * DirectDraw error reports; STARTUP / BMP8 / MPMGRW etc. also use it
 * defensively. Return value is IDOK (engine never branches on it for
 * the MB_OK paths in our scope). The dialog itself is dormant on
 * Linux; a later port routes through SDL_ShowSimpleMessageBox or
 * stderr. Real <winuser.h> arg order: (HWND, LPCSTR text, LPCSTR
 * caption, UINT type). */
#ifndef IDOK
#define IDOK      1
#endif
#ifndef IDCANCEL
#define IDCANCEL  2
#endif
#ifndef IDYES
#define IDYES     6
#endif
#ifndef IDNO
#define IDNO      7
#endif
static inline int MessageBoxA(HWND, LPCSTR, LPCSTR, UINT) { return IDOK; }
#ifndef MessageBox
#define MessageBox MessageBoxA
#endif

/* TIM-70: GetKeyState -- Win32 keyboard input snapshot. KEY.CPP:217 and
 * KEYBOARD.CPP:194 (WWKeyboardClass::Put_Key_Message) call
 * GetKeyState(VK_SHIFT|VK_CONTROL|VK_MENU|VK_CAPITAL|VK_NUMLOCK) and mask
 * with 0x8000 (high bit = currently pressed) / 0x0008 (caps/numlock toggle
 * — engine-specific bit, not the SDK 0x0001 convention) to fold modifier
 * state into the polled keystroke. Real <winuser.h> signature:
 * `SHORT WINAPI GetKeyState(int nVirtKey)`. The Linux input pipeline is
 * dormant under the stub (SDL_GetKeyboardState lands in a later port), so
 * the inert return is "no modifiers held / no toggle active" -- engine
 * code OR-fold paths simply skip the SHIFT/CTRL/ALT bit decorations and
 * still produce a usable Put_Key_Message call. The VK_* constants are
 * defined by the engine's own KEY.H, not here. */
static inline SHORT GetKeyState(int) { return 0; }

/* TIM-71: Win32 input + message-pump cluster. KEY.CPP / KEYBOARD.CPP
 * (WWKeyboardClass::To_ASCII / Down / Fill_Buffer_From_System /
 * Message_Handler) call MapVirtualKey/GetAsyncKeyState/ToAscii to
 * translate physical scancodes and PeekMessage/GetMessage/Translate
 * Message/DispatchMessage to pump the OS event loop. The Linux input
 * pipeline is dormant under the stub (SDL_PollEvent + scancode
 * translation lands in a later port), so everything here is inert:
 * PeekMessage returns FALSE so the pump loop exits immediately,
 * Translate/Dispatch never run, ToAscii/MapVirtualKey return 0
 * (engine code already gates "no key produced" branches downstream),
 * GetAsyncKeyState reports no key held.
 *
 * MSG / LPMSG / WPARAM / LPARAM exist only to give &msg arguments a
 * complete type. WPARAM/LPARAM are pointer-sized integer typedefs to
 * match the Win32 SDK ABI on LP64 (UINT_PTR / LONG_PTR). The MSG layout
 * matches the SDK so any sizeof / pointer-cast through engine code stays
 * well-defined; no field is read on the dormant code path. POINT and
 * BOOL/HWND/UINT/DWORD/WORD are already defined above.
 *
 * VK_* constants live in the engine's own KEY.H. WM_* / PM_* / LOWORD /
 * HIWORD live here. PBYTE is the natural twin of the existing LPBYTE
 * typedef; it surfaces only now because the (PBYTE)KeyState casts at
 * KEY.CPP:321 / KEYBOARD.CPP:264 land once ToAscii is declared. */

typedef BYTE*              PBYTE;
typedef uintptr_t          WPARAM;
typedef intptr_t           LPARAM;

typedef struct tagMSG {
    HWND    hwnd;
    UINT    message;
    WPARAM  wParam;
    LPARAM  lParam;
    DWORD   time;
    POINT   pt;
} MSG, *LPMSG;

#ifndef PM_NOREMOVE
#define PM_NOREMOVE 0x0000
#endif
#ifndef PM_REMOVE
#define PM_REMOVE   0x0001
#endif

#ifndef WM_KEYDOWN
#define WM_KEYDOWN          0x0100
#endif
#ifndef WM_KEYUP
#define WM_KEYUP            0x0101
#endif
#ifndef WM_SYSKEYDOWN
#define WM_SYSKEYDOWN       0x0104
#endif
#ifndef WM_SYSKEYUP
#define WM_SYSKEYUP         0x0105
#endif
#ifndef WM_MOUSEMOVE
#define WM_MOUSEMOVE        0x0200
#endif
#ifndef WM_LBUTTONDOWN
#define WM_LBUTTONDOWN      0x0201
#endif
#ifndef WM_LBUTTONUP
#define WM_LBUTTONUP        0x0202
#endif
#ifndef WM_LBUTTONDBLCLK
#define WM_LBUTTONDBLCLK    0x0203
#endif
#ifndef WM_RBUTTONDOWN
#define WM_RBUTTONDOWN      0x0204
#endif
#ifndef WM_RBUTTONUP
#define WM_RBUTTONUP        0x0205
#endif
#ifndef WM_RBUTTONDBLCLK
#define WM_RBUTTONDBLCLK    0x0206
#endif
#ifndef WM_MBUTTONDOWN
#define WM_MBUTTONDOWN      0x0207
#endif
#ifndef WM_MBUTTONUP
#define WM_MBUTTONUP        0x0208
#endif
#ifndef WM_MBUTTONDBLCLK
#define WM_MBUTTONDBLCLK    0x0209
#endif

#ifndef LOWORD
#define LOWORD(l) ((WORD)((DWORD)(l) & 0xFFFF))
#endif
#ifndef HIWORD
#define HIWORD(l) ((WORD)(((DWORD)(l) >> 16) & 0xFFFF))
#endif

static inline UINT  MapVirtualKey(UINT, UINT)                      { return 0; }
static inline SHORT GetAsyncKeyState(int)                          { return 0; }
static inline int   ToAscii(UINT, UINT, const BYTE*, LPWORD, UINT) { return 0; }
static inline BOOL  PeekMessage(LPMSG, HWND, UINT, UINT, UINT)     { return FALSE; }
static inline BOOL  GetMessage(LPMSG, HWND, UINT, UINT)            { return FALSE; }
static inline BOOL  TranslateMessage(const MSG*)                   { return FALSE; }
static inline LONG  DispatchMessage(const MSG*)                    { return 0; }

/* TIM-74: Win32 GDI / window-misc cluster. MOUSEWW.CPP calls
 * GetCursorPos to seed the mouse position before WIN32LIB's own
 * mouse-tracking takes over; INIT.CPP calls SetForegroundWindow when
 * the engine raises its top-level window after init; TIMERINI.CPP
 * pokes GetLastError after a CreateThread/SetThreadPriority pair to
 * log a startup failure code. All three Win32 surfaces are dormant
 * under the stub (the real input/window/thread paths land with the
 * SDL2 + pthread port), so the inert returns are TRUE / TRUE / 0 --
 * no engine code makes a control-flow decision on the values yet.
 *
 * GetCursorPos zero-initialises *lpPoint when non-null so MOUSEWW
 * sees a deterministic (0,0) seed instead of an indeterminate stack
 * read on the first cursor sample. Real <winuser.h> signature:
 * `BOOL WINAPI GetCursorPos(LPPOINT lpPoint)`. POINT/LPPOINT and
 * HWND/BOOL/TRUE/DWORD are already defined above.
 *
 * S_OK is the canonical HRESULT success code; included here so the
 * shim header can return it from any HRESULT-typed surface added in
 * a follow-up pass without forcing a separate header edit. */

#ifndef S_OK
#define S_OK            ((HRESULT)0L)
#endif
#ifndef S_FALSE
#define S_FALSE         ((HRESULT)1L)
#endif

static inline BOOL  GetCursorPos(LPPOINT lpPoint)                  { if (lpPoint) { lpPoint->x = 0; lpPoint->y = 0; } return TRUE; }
static inline DWORD GetLastError(void)                             { return 0; }
static inline BOOL  SetForegroundWindow(HWND)                      { return TRUE; }

/* TIM-75: Win32 GDI/window-misc continuation. INIT.CPP:1079 calls
 * ShowWindow(MainWindow, ShowCommand) right after SetForegroundWindow
 * to raise the engine's top-level window; TIMERINI.CPP:133 calls
 * OutputDebugString(error_str) on the timer-system failure path. Both
 * surfaces are dormant under the stub (no HWND universe; debug output
 * lands on a real logger in the SDL2 port), so the inert returns are
 * TRUE / nothing -- no engine code makes a control-flow decision on
 * the values yet. OutputDebugString is aliased to the A variant since
 * no UNICODE convention is established in this header. */
static inline BOOL  ShowWindow(HWND, int)                          { return TRUE; }
static inline void  OutputDebugStringA(LPCSTR)                     {}
static inline void  OutputDebugStringW(LPCWSTR)                    {}
#ifndef OutputDebugString
#define OutputDebugString OutputDebugStringA
#endif

/* TIM-80: SendMessage -- Win32 window-message synchronous dispatch.
 * WSPROTO.CPP:453/506 (WIC::Send / WIC::Broadcast) and WSPUDP.CPP:280
 * (WinsockInterfaceClass::Broadcast) post a `(MainWindow,
 * Protocol_Event_Message(), 0, (LONG)FD_WRITE)` self-message after
 * queueing an outbound packet, so the next message-pump turn kicks
 * the asynchronous Winsock writer. Real <winuser.h> signature:
 * `LRESULT WINAPI SendMessageA(HWND, UINT, WPARAM, LPARAM)`. The
 * window-message universe is dormant under the stub (no HWND, no
 * pump -- PeekMessage/GetMessage already return FALSE per TIM-71),
 * so the inert return is `0`. The matching SDL2-event port is in a
 * later pass. LONG return matches the TIM-71 sibling style for the
 * message-pump cluster (PeekMessage/GetMessage/TranslateMessage/
 * DispatchMessage) and is wide enough on LP64 to absorb the LRESULT
 * convention; engine code never reads the return value at any of the
 * surveyed call sites. */
static inline LONG  SendMessage(HWND, UINT, WPARAM, LPARAM)        { return 0; }

/* TIM-95: pass-40L STARTUP shutdown-message cluster. STARTUP.CPP:780 and
 * :1086 (Main_Game cleanup paths) post `(MainWindow, WM_DESTROY, 0, 0)`
 * to trigger the Win32 message-pump destroy handler. Real <winuser.h>:
 * `#define WM_DESTROY 0x0002` and `BOOL WINAPI PostMessageA(HWND, UINT,
 * WPARAM, LPARAM)`. The window-message universe is dormant under the
 * stub (no HWND, no pump -- the engine's headless shutdown path drives
 * itself via ReadyToQuit), so PostMessage is the inert FALSE return.
 * Sibling shape to the TIM-80 SendMessage shim and the TIM-71 message-
 * pump cluster. */
#ifndef WM_DESTROY
#define WM_DESTROY          0x0002
#endif
static inline BOOL  PostMessage(HWND, UINT, WPARAM, LPARAM)        { return FALSE; }

/* TIM-85: pass-40F Win32 type/API stub bundle. Five additive declarations
 * to drain the CONQUER / MENUS / WINSTUB / RAWFILE / BMP8 cluster. Same
 * inert-stub policy as the TIM-71 / TIM-74 / TIM-75 bundles -- no engine
 * behaviour change, just enough surface for the parser to walk through
 * the dormant Win32 branches. */

/* TIM-85: LPCTSTR -- Win32 const-TCHAR string pointer. WINSTUB.CPP:499
 * (Window_Dialog_Box) takes an LPCTSTR template name on a Win32-only
 * dialog API. Without UNICODE the SDK defines TCHAR=char, so LPCTSTR
 * collapses to LPCSTR. Engine never reads through the pointer (the
 * dialog body itself is `#if (0)//PG`-disabled), so a typedef alias
 * is sufficient. */
typedef LPCSTR LPCTSTR;
typedef LPSTR  LPTSTR;

/* TIM-85: SYSTEMTIME -- Win32 broken-down clock record. Real
 * <minwinbase.h> shape; field set fully populated because INIT.CPP:2499
 * (CryptRandom seeding) reads wMilliseconds/wSecond/wMinute/wHour/wDay/
 * wDayOfWeek/wMonth/wYear. MENUS.CPP:842 only reads wMilliseconds. The
 * struct is just a passive seed source on Linux; the matching
 * GetSystemTime declaration is the inert sibling -- engine never asserts
 * on the values, only feeds them into the cryptographic RNG. */
typedef struct _SYSTEMTIME {
    WORD wYear;
    WORD wMonth;
    WORD wDayOfWeek;
    WORD wDay;
    WORD wHour;
    WORD wMinute;
    WORD wSecond;
    WORD wMilliseconds;
} SYSTEMTIME, *LPSYSTEMTIME, *PSYSTEMTIME;

#ifdef __cplusplus
extern "C" {
#endif
/* Inert: leaves the SYSTEMTIME zero-initialized at declaration time, so
 * the seed bits are deterministic until the SDL2 time-source port
 * lands. RNG seeding is the only consumer. */
static inline void GetSystemTime(LPSYSTEMTIME) {}
/* TIM-89: GetLocalTime -- Win32 local-time-of-day API, sibling of
 * GetSystemTime. WINSTUB.CPP:746 (Assert_Failure) calls it to stamp the
 * assertion-log line written to ASSERT.TXT. Inert stub leaves the
 * SYSTEMTIME zero-initialized; the assert path is engine-side
 * diagnostic only and the timestamp is cosmetic. The eventual port
 * wires this to localtime_r/clock_gettime alongside GetSystemTime. */
static inline void GetLocalTime(LPSYSTEMTIME) {}
/* TIM-92: pass-40K STARTUP first-error drain -- GetModuleFileName.
 * STARTUP.CPP:280 (main entry) calls it with the process HMODULE to
 * populate path_to_exe[132], which is then assigned to argv[0]. Inert
 * stub returns 0 (no chars written) and writes a NUL terminator at
 * offset 0 so argv[0] points at "" rather than uninitialised stack --
 * same safety contract as TIM-91 _splitpath / _makepath shims.
 * Canonical SDK signature:
 *   `DWORD GetModuleFileNameA(HMODULE, LPSTR, DWORD)`.
 * The eventual port resolves the binary path via /proc/self/exe
 * (readlink) on Linux. */
static inline DWORD GetModuleFileName(HMODULE, LPSTR lpFilename, DWORD nSize) {
    if (lpFilename && nSize > 0) lpFilename[0] = '\0';
    return 0;
}
#ifdef __cplusplus
}
#endif

/* TIM-94: pass-40K sibling drain -- ShowCursor.
 * INIT.CPP:3422 (Init_Mouse) calls `ShowCursor(false)` inside a
 * `#ifdef WIN32` block to hide the OS cursor before the engine's own
 * mouse-shape system takes over. Real Win32 signature:
 *   `int ShowCursor(BOOL bShow)` -- returns the post-call display
 *   counter (negative when hidden). Engine code discards the return
 *   value, so the inert stub returns 0. The OS-cursor universe is
 *   dormant on Linux; the eventual SDL2 port replaces this with
 *   SDL_ShowCursor / SDL_SetRelativeMouseMode. Variadic-template
 *   shape mirrors the TIM-87 CreateFile / DeleteObject family;
 *   placed outside the extern "C" block above because C linkage
 *   forbids templates. */
template <typename... Args> int ShowCursor(Args&&...) { return 0; }

/* TIM-85: GetVolumeInformation -- Win32 file-system label/serial query.
 * CONQUER.CPP:4289 (Get_CD_Index) probes the CD drive for a known
 * volume label to identify which CD is inserted. Real signature:
 * `BOOL GetVolumeInformationA(LPCSTR, LPSTR, DWORD, LPDWORD, LPDWORD,
 * LPDWORD, LPSTR, DWORD)`. Variadic-template inert stub returning 0
 * (FALSE) so the volume-detect loop falls through to the no-CD branch.
 * The CD-detect path is dormant on Linux (we don't enumerate physical
 * drive letters); the eventual port replaces this with an
 * SDL_RWops/asset-pack lookup. Variadic shape mirrors the
 * TIM-74/TIM-75 GDI-cluster stubs -- same return-int policy. */
template <typename... Args> int GetVolumeInformation(Args&&...) { return 0; }
template <typename... Args> int GetVolumeInformationA(Args&&...) { return 0; }

/* TIM-85: hBitmap -- referenced by REDALERT/BMP8.CPP:23/24 in
 * BMP8::~BMP8 as `if( hBitmap ) ::DeleteObject( hBitmap );`. Note: this
 * is an upstream typo -- the BMP8.H member is `hBMP`, not `hBitmap`,
 * so the destructor ALREADY did not free its own bitmap on the original
 * Watcom build (the symbol must have resolved to a global elsewhere or
 * the file was simply never compiled). On Linux we expose a global
 * HBITMAP `hBitmap` so the parser walks past the destructor body; the
 * BMP8 class is unused by any compiling call site, so the latent
 * destructor leak is preserved as-is rather than introduced. The
 * `inline` makes this header-safe across all TUs. */
inline HBITMAP hBitmap = nullptr;

/* TIM-87: pass-40G Win32-stub-shape bundle.
 *
 * Four sibling first-errors surfaced post-TIM-85 (pass-40F):
 *   WINSTUB.CPP:499 -> DLGPROC          (function-pointer typedef)
 *   CONQUER.CPP:4300 -> GENERIC_READ    (CreateFile flag-constant cluster)
 *   RAWFILE.CPP:881  -> filelength      (DOS file-size API; see dos.h)
 *   BMP8.CPP:24      -> ::DeleteObject  (Win32 GDI cleanup)
 *
 * All shimmed here as inert / canonical-value stubs.
 *
 * Pointer-sized integer aliases. Win32 SDK signature for DLGPROC is
 * `INT_PTR (CALLBACK *)(HWND, UINT, WPARAM, LPARAM)`. We already
 * have WPARAM = uintptr_t and LPARAM = intptr_t (see ~line 634); add
 * the matching INT_PTR / UINT_PTR / LONG_PTR / ULONG_PTR aliases for
 * symmetry. CALLBACK / WINAPI / APIENTRY collapse to nothing on
 * non-Windows -- the Win32 calling-convention attributes don't apply
 * here (msvc-compat.h already collapses __stdcall / __cdecl).
 */
typedef intptr_t           INT_PTR;
typedef uintptr_t          UINT_PTR;
typedef intptr_t           LONG_PTR;
typedef uintptr_t          ULONG_PTR;
#ifndef CALLBACK
#define CALLBACK
#endif
#ifndef WINAPI
#define WINAPI
#endif
#ifndef APIENTRY
#define APIENTRY
#endif

/* DLGPROC -- standard Win32 SDK shape. WINSTUB.CPP:499 uses it as a
 * `Window_Dialog_Box` parameter type; the dialog-procedure dispatch
 * surface is dormant on Linux (Window_Dialog_Box body is `#if (0)//PG`
 * gated). The typedef just satisfies the parser. */
typedef INT_PTR (CALLBACK *DLGPROC)(HWND, UINT, WPARAM, LPARAM);

/* CreateFile / CloseHandle -- file-handle open/close. Used unguarded by
 * CONQUER.CPP:4300 (CD volume-detect: opens main.mix to verify CD),
 * BMP8.CPP:52 (loads a .bmp via Win32 file API), and inside `#ifdef
 * WIN32` blocks in RAWFILE.CPP / WINSTUB.CPP / NULLMGR.CPP that we are
 * not pruning. Variadic-template inert stubs return INVALID_HANDLE_VALUE
 * (CreateFile) and FALSE (CloseHandle), same shape as the TIM-85
 * GetVolumeInformation / _dos_* family. The filesystem surface is
 * dormant under the stub -- eventual SDL2/std::fstream port replaces
 * these with real file IO. */
template <typename... Args> HANDLE CreateFile (Args&&...) { return INVALID_HANDLE_VALUE; }
template <typename... Args> HANDLE CreateFileA(Args&&...) { return INVALID_HANDLE_VALUE; }
template <typename... Args> BOOL   CloseHandle(Args&&...) { return FALSE; }

/* DeleteObject -- Win32 GDI cleanup function. BMP8.CPP:24/26 calls it
 * on hBitmap / hPal in the destructor. The GDI universe is dormant
 * (palette/bitmap handles are inert pointers), so the inert stub
 * returns FALSE. Variadic-template form mirrors TIM-74 GDI cluster. */
template <typename... Args> BOOL   DeleteObject(Args&&...) { return FALSE; }

/* GENERIC_* access-mask constants. Canonical Win32 SDK values from
 * winnt.h. Bit positions are ABI for the access-mask DWORD passed to
 * CreateFile et al; see WIN32 SDK `<winnt.h>` GENERIC_READ etc. */
#ifndef GENERIC_READ
#define GENERIC_READ    0x80000000L
#endif
#ifndef GENERIC_WRITE
#define GENERIC_WRITE   0x40000000L
#endif
#ifndef GENERIC_EXECUTE
#define GENERIC_EXECUTE 0x20000000L
#endif
#ifndef GENERIC_ALL
#define GENERIC_ALL     0x10000000L
#endif

/* FILE_SHARE_* share-mode bitflags. Canonical from winnt.h. */
#ifndef FILE_SHARE_READ
#define FILE_SHARE_READ   0x00000001
#endif
#ifndef FILE_SHARE_WRITE
#define FILE_SHARE_WRITE  0x00000002
#endif
#ifndef FILE_SHARE_DELETE
#define FILE_SHARE_DELETE 0x00000004
#endif

/* CreateFile dwCreationDisposition values. Canonical from winbase.h. */
#ifndef CREATE_NEW
#define CREATE_NEW        1
#endif
#ifndef CREATE_ALWAYS
#define CREATE_ALWAYS     2
#endif
#ifndef OPEN_EXISTING
#define OPEN_EXISTING     3
#endif
#ifndef OPEN_ALWAYS
#define OPEN_ALWAYS       4
#endif
#ifndef TRUNCATE_EXISTING
#define TRUNCATE_EXISTING 5
#endif

/* TIM-94: pass-40K BMP8 kernel32 file/global-mem cluster.
 *
 * Post-TIM-90 (wingdi struct cluster), BMP8.CPP first-fails on
 * `::ReadFile @65`. The next surface before any GDI dispatch is a
 * tight kernel32 file-IO and global-memory family. All inert
 * variadic-template stubs in the same shape as TIM-87 (CreateFile /
 * CloseHandle / DeleteObject) -- the kernel32 universe is dormant in
 * headless mode (no real file IO, no Windows global heap), and the
 * eventual SDL2 / std::fstream / std::malloc port replaces these.
 *
 * BMP8.CPP call sites (also covered: DIBUTIL.CPP, DIBFILE.CPP,
 * RAWFILE.CPP, WOLAPIOB.CPP -- the global-namespace template matches
 * both `::ReadFile(...)` and `ReadFile(...)` use):
 *   ::ReadFile      @ 65, 68, 90, 116    -- kernel32 sync read
 *   ::GlobalAlloc   @ 71, 111            -- global-heap alloc
 *   ::GlobalLock    @ 73, 113            -- pin / map global handle
 *   ::GlobalUnlock  @ 131, 132           -- release global handle
 *   GHND            @ 71, 111            -- GMEM_MOVEABLE | GMEM_ZEROINIT
 *
 * Real Win32 SDK signatures (from <fileapi.h> / <winbase.h>):
 *   BOOL    ReadFile(HANDLE, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
 *   HGLOBAL GlobalAlloc(UINT uFlags, SIZE_T dwBytes);
 *   LPVOID  GlobalLock(HGLOBAL hMem);
 *   BOOL    GlobalUnlock(HGLOBAL hMem);
 *
 * GlobalAlloc returns HANDLE (not HGLOBAL) because the wingdi cluster
 * below contains `typedef HANDLE HGLOBAL;` -- using HANDLE here
 * avoids a forward-decl cycle while remaining type-compatible at
 * every call site (HGLOBAL == HANDLE).
 *
 * GHND constant from <winbase.h>: 0x0042 = GMEM_MOVEABLE (0x0002) |
 * GMEM_ZEROINIT (0x0040). Engine code only uses the value as a flag
 * passthrough -- no allocator code path inspects the bits under the
 * stub. */
template <typename... Args> BOOL   ReadFile     (Args&&...) { return FALSE; }
template <typename... Args> HANDLE GlobalAlloc  (Args&&...) { return nullptr; }
template <typename... Args> LPVOID GlobalLock   (Args&&...) { return nullptr; }
template <typename... Args> BOOL   GlobalUnlock (Args&&...) { return FALSE; }

#ifndef GHND
#define GHND 0x0042
#endif

/* TIM-90: pass-40J BMP8 wingdi struct cluster. POD typedefs for the
 * BMP loader's parser-only path. BMP8.CPP first-fails post-TIM-87 on
 * BITMAPFILEHEADER @35; the cluster drains a tight family of wingdi.h
 * structs the BMP loader declares on the stack / casts pointers
 * through. Field names + layouts match the canonical Win32 SDK
 * (wingdi.h / minwinbase.h / winuser.h) so any sizeof / pointer-cast
 * through engine code stays well-defined; no field is read at runtime
 * because the GDI universe is dormant under the stub (CreatePalette,
 * GetDC, SelectPalette, BitBlt, ... all land in a later SDL2/OpenGL
 * port).
 *
 * Canonical SDK shapes (pulled from public Win32 headers):
 *   BITMAPFILEHEADER  : <wingdi.h>  -- BMP file header, 5 fields.
 *   BITMAPINFOHEADER  : <wingdi.h>  -- DIB info header, 11 fields.
 *   RGBQUAD           : <wingdi.h>  -- 4-byte BGRA palette entry.
 *   BITMAPINFO        : <wingdi.h>  -- BITMAPINFOHEADER + RGBQUAD[].
 *   LOGPALETTE        : <wingdi.h>  -- WORD,WORD + PALETTEENTRY[].
 *   PAINTSTRUCT       : <winuser.h> -- BeginPaint context.
 *   HGLOBAL           : <minwinbase.h> -- opaque global-mem handle.
 *   SECURITY_ATTRIBUTES: <minwinbase.h> -- CreateFile lpSecurity arg
 *     (only used as a (LPSECURITY_ATTRIBUTES)NULL cast in BMP8.CPP).
 *
 * PALETTEENTRY (TIM-55), HPALETTE (~line 94), LPVOID (~line 119),
 * HBITMAP (~line 88), HDC (~line 87), RECT (~line 137), BOOL/BYTE/
 * WORD/DWORD/LONG/HANDLE are all already shimmed above.
 */

/* HGLOBAL -- opaque global-memory handle. Same shape as HBITMAP /
 * HFILE / HHANDLE family. BMP8.CPP:39/71/111 stores GlobalAlloc results
 * here. The global-mem subsystem is dormant under the stub. */
typedef HANDLE             HGLOBAL;

/* SECURITY_ATTRIBUTES -- canonical layout. BMP8.CPP:56 only uses the
 * (LPSECURITY_ATTRIBUTES)NULL cast as the lpSecurityAttributes arg to
 * CreateFile; the struct is never populated or read on the stub path. */
typedef struct _SECURITY_ATTRIBUTES {
    DWORD  nLength;
    LPVOID lpSecurityDescriptor;
    BOOL   bInheritHandle;
} SECURITY_ATTRIBUTES, *PSECURITY_ATTRIBUTES, *LPSECURITY_ATTRIBUTES;

/* BITMAPFILEHEADER -- canonical 14-byte BMP file prefix. Real SDK
 * applies #pragma pack(2) so total size is 14 bytes; we omit the
 * pragma here because no engine code on the stub path reads/writes
 * BMP files at runtime (ReadFile is itself a stub). Field names match
 * BMP8.CPP usage at lines 65/111/116 (bfSize, bfOffBits). */
typedef struct tagBITMAPFILEHEADER {
    WORD  bfType;
    DWORD bfSize;
    WORD  bfReserved1;
    WORD  bfReserved2;
    DWORD bfOffBits;
} BITMAPFILEHEADER, *LPBITMAPFILEHEADER, *PBITMAPFILEHEADER;

/* BITMAPINFOHEADER -- canonical DIB header. BMP8.CPP:76-86 reads every
 * biSize/biWidth/biHeight/biPlanes/biBitCount/biCompression/biSizeImage/
 * biXPelsPerMeter/biYPelsPerMeter/biClrUsed/biClrImportant field, so
 * the full 11-field SDK shape is required for the parser. */
typedef struct tagBITMAPINFOHEADER {
    DWORD biSize;
    LONG  biWidth;
    LONG  biHeight;
    WORD  biPlanes;
    WORD  biBitCount;
    DWORD biCompression;
    DWORD biSizeImage;
    LONG  biXPelsPerMeter;
    LONG  biYPelsPerMeter;
    DWORD biClrUsed;
    DWORD biClrImportant;
} BITMAPINFOHEADER, *LPBITMAPINFOHEADER, *PBITMAPINFOHEADER;

/* RGBQUAD -- BMP palette entry (BGRA byte order, matches SDK). BMP8.CPP
 * uses sizeof(RGBQUAD) at lines 71/90 and walks the palette as raw
 * bytes via the BITMAPINFO::bmiColors[] trailer below. */
typedef struct tagRGBQUAD {
    BYTE rgbBlue;
    BYTE rgbGreen;
    BYTE rgbRed;
    BYTE rgbReserved;
} RGBQUAD, *LPRGBQUAD;

/* BITMAPINFO -- BITMAPINFOHEADER + flexible-array RGBQUAD trailer. SDK
 * declares bmiColors[1] as the standard "extensible struct" idiom; the
 * actual allocation at BMP8.CPP:71 sizes for sizeof(BITMAPINFOHEADER) +
 * (1<<biBitCount)*sizeof(RGBQUAD), then casts and dereferences
 * lpHeaderMem->bmiHeader and lpHeaderMem->bmiColors. */
typedef struct tagBITMAPINFO {
    BITMAPINFOHEADER bmiHeader;
    RGBQUAD          bmiColors[1];
} BITMAPINFO, *LPBITMAPINFO, *PBITMAPINFO;

/* LOGPALETTE -- canonical GDI logical-palette descriptor. BMP8.CPP:94
 * allocates `(LPLOGPALETTE)new char[sizeof(LOGPALETTE) +
 * sizeof(PALETTEENTRY)*256]` then writes palVersion / palNumEntries and
 * iterates palPalEntry[i].peRed/peGreen/peBlue/peFlags. The SDK uses
 * the same flexible-array trailer idiom as BITMAPINFO. PALETTEENTRY is
 * already defined above (TIM-55). */
typedef struct tagLOGPALETTE {
    WORD         palVersion;
    WORD         palNumEntries;
    PALETTEENTRY palPalEntry[1];
} LOGPALETTE, *PLOGPALETTE, *LPLOGPALETTE, *NPLOGPALETTE;

/* PAINTSTRUCT -- BeginPaint/EndPaint context. BMP8.CPP:41/146 declares
 * one on the stack and reads ps.hdc at line 155 (drawBmp). Real
 * <winuser.h> shape; rgbReserved is 32 bytes per the SDK. The
 * paint-cycle universe is dormant on Linux. */
typedef struct tagPAINTSTRUCT {
    HDC  hdc;
    BOOL fErase;
    RECT rcPaint;
    BOOL fRestore;
    BOOL fIncUpdate;
    BYTE rgbReserved[32];
} PAINTSTRUCT, *PPAINTSTRUCT, *NPPAINTSTRUCT, *LPPAINTSTRUCT;

/* TIM-96: pass-40L BMP8 GDI-dispatch surface.
 *
 * Post-TIM-94 (kernel32 file/global-mem cluster), BMP8.CPP first-fails
 * on `::CreatePalette @107`. The remaining surface is a tight wingdi /
 * winuser GDI-dispatch family that BMP8::Init and BMP8::drawBmp walk
 * before any DirectDraw or SDL2 path can take over. All inert
 * variadic-template stubs in the same shape as the TIM-87 / TIM-94
 * kernel32 cluster -- the GDI universe is dormant in headless mode (no
 * device contexts, no real bitmap blitting), and the eventual SDL2 +
 * OpenGL/Vulkan port replaces every entry point here.
 *
 * BMP8.CPP call sites (also covered by the global-namespace match:
 * DIBUTIL.CPP, DIBFILE.CPP, WOLAPIOB.CPP):
 *   ::CreatePalette       @107        -- HPALETTE from LOGPALETTE*
 *   ::GetDC               @119        -- HDC from HWND
 *   ::SelectPalette       @120, 155   -- HPALETTE swap on HDC
 *   ::RealizePalette      @123, 161   -- UINT (entries realized) or
 *                                        GDI_ERROR
 *   ::CreateDIBitmap      @127        -- HBITMAP from BITMAPINFO+bits
 *   ::ReleaseDC           @128        -- int (1=released, 0=fail)
 *    BeginPaint           @152        -- HDC into PAINTSTRUCT
 *    EndPaint             @184        -- BOOL
 *    CreateCompatibleDC   @168        -- HDC compatible with another
 *    SelectObject         @169        -- previous HGDIOBJ
 *    GetObject            @171        -- int bytes copied
 *    GetClientRect        @177        -- BOOL, fills RECT
 *    InvalidateRect       @150        -- BOOL
 *    SetStretchBltMode    @178        -- int (previous mode)
 *    StretchBlt           @179        -- BOOL
 *    DeleteDC             @183        -- BOOL
 *
 * Real Win32 SDK signatures (from <wingdi.h> / <winuser.h>):
 *   HPALETTE CreatePalette(const LOGPALETTE*);
 *   HDC      GetDC(HWND);
 *   HPALETTE SelectPalette(HDC, HPALETTE, BOOL);
 *   UINT     RealizePalette(HDC);
 *   HBITMAP  CreateDIBitmap(HDC, const BITMAPINFOHEADER*, DWORD, const VOID*, const BITMAPINFO*, UINT);
 *   int      ReleaseDC(HWND, HDC);
 *   HDC      BeginPaint(HWND, LPPAINTSTRUCT);
 *   BOOL     EndPaint(HWND, const PAINTSTRUCT*);
 *   HDC      CreateCompatibleDC(HDC);
 *   BOOL     DeleteDC(HDC);
 *   HGDIOBJ  SelectObject(HDC, HGDIOBJ);
 *   int      GetObject(HANDLE, int, LPVOID);
 *   BOOL     GetClientRect(HWND, LPRECT);
 *   BOOL     InvalidateRect(HWND, const RECT*, BOOL);
 *   int      SetStretchBltMode(HDC, int);
 *   BOOL     StretchBlt(HDC, int, int, int, int, HDC, int, int, int, int, DWORD);
 *
 * HBITMAP/HDC/HPALETTE/HGDIOBJ are all `typedef void*` in this shim
 * (see ~lines 87-94), and HANDLE is also `typedef void*`, so returning
 * HANDLE from the pointer-typed surfaces avoids any forward-decl cycle
 * and is type-compatible at every call site (same trick as TIM-94's
 * GlobalAlloc -> HANDLE return).
 *
 * RealizePalette returns UINT 0 (not GDI_ERROR) so the
 * `if (realize == GDI_ERROR)` failure branches in BMP8 / DIBUTIL stay
 * dormant. SelectPalette returns nullptr; the `if (!select) return
 * false;` path in BMP8::Init then takes the safe early-return -- the
 * function itself is never called by anything compiling in this pass,
 * so the latent "no GDI" semantics are preserved as-is. */
template <typename... Args> HANDLE CreatePalette     (Args&&...) { return nullptr; }
template <typename... Args> HANDLE GetDC             (Args&&...) { return nullptr; }
template <typename... Args> HANDLE SelectPalette     (Args&&...) { return nullptr; }
template <typename... Args> UINT   RealizePalette    (Args&&...) { return 0; }
template <typename... Args> HANDLE CreateDIBitmap    (Args&&...) { return nullptr; }
template <typename... Args> int    ReleaseDC         (Args&&...) { return 0; }
template <typename... Args> HANDLE BeginPaint        (Args&&...) { return nullptr; }
template <typename... Args> BOOL   EndPaint          (Args&&...) { return TRUE; }
template <typename... Args> HANDLE CreateCompatibleDC(Args&&...) { return nullptr; }
template <typename... Args> BOOL   DeleteDC          (Args&&...) { return TRUE; }
template <typename... Args> HANDLE SelectObject      (Args&&...) { return nullptr; }
template <typename... Args> int    GetObject         (Args&&...) { return 0; }
template <typename... Args> int    GetObjectA        (Args&&...) { return 0; }
template <typename... Args> BOOL   GetClientRect     (Args&&...) { return TRUE; }
template <typename... Args> BOOL   InvalidateRect    (Args&&...) { return TRUE; }
template <typename... Args> int    SetStretchBltMode (Args&&...) { return 0; }
template <typename... Args> BOOL   StretchBlt        (Args&&...) { return TRUE; }

/* BITMAP -- canonical <wingdi.h> bitmap descriptor. BMP8.CPP:170-179
 * declares `BITMAP bm;`, calls `GetObject(BitmapHandle_, sizeof(BITMAP),
 * &bm)`, then reads bm.bmWidth / bm.bmHeight to feed StretchBlt. The
 * full SDK shape lets sizeof(BITMAP) round-trip correctly even though
 * the GetObject stub never populates the struct on the dormant path --
 * bm is uninitialised, but the StretchBlt call below is itself a no-op
 * stub so the indeterminate width/height never reach a real blitter. */
typedef struct tagBITMAP {
    LONG   bmType;
    LONG   bmWidth;
    LONG   bmHeight;
    LONG   bmWidthBytes;
    WORD   bmPlanes;
    WORD   bmBitsPixel;
    LPVOID bmBits;
} BITMAP, *PBITMAP, *NPBITMAP, *LPBITMAP;

/* TIM-96: GDI dispatch constants. Canonical Win32 SDK values from
 * <wingdi.h>. Bit positions are ABI for the flags / mode parameters
 * passed to the GDI calls above; engine code only uses them as opaque
 * passthrough values under the stub. */
#ifndef GDI_ERROR
#define GDI_ERROR        ((UINT)0xFFFFFFFF)
#endif
#ifndef CBM_INIT
#define CBM_INIT         0x04L
#endif
#ifndef DIB_RGB_COLORS
#define DIB_RGB_COLORS   0
#endif
#ifndef DIB_PAL_COLORS
#define DIB_PAL_COLORS   1
#endif
#ifndef COLORONCOLOR
#define COLORONCOLOR     3
#endif
#ifndef SRCCOPY
#define SRCCOPY          0x00CC0020L
#endif

/* TIM-97: pass-40M WINSTUB text-constant alias drain. WINSTUB.CPP:802
 * (Memory_Error_Handler) calls
 *     WWMessageBox().Process(TEXT_MEMORY_ERROR, TEXT_ABORT, false);
 * The TEXT_* spelling is the LANGUAGE.H string-table convention -- those
 * macros expand only when the TU pins ENGLISH (see the TIM-84 INIT.CPP /
 * STARTUP.CPP fix). WINSTUB.CPP is not ENGLISH-pinned, so the symbols are
 * undeclared. The TU only ever uses the int overload of
 * WWMessageBox::Process (msgbox.h:47), so a textual alias to the
 * existing TXT_* int constants from CONQUER.H is enough to let the
 * parser resolve and the overload to bind:
 *     Process(int msg, int b1txt=TXT_OK, int b2txt=TXT_NONE,
 *             int b3txt=TXT_NONE, bool preserve=false)
 * TEXT_MEMORY_ERROR -> TXT_ERROR_ERROR (the closest existing TXT_* slot
 * the compiler itself suggests; the engine's runtime text universe is
 * dormant under the stub, so the precise table index is moot here).
 * TEXT_ABORT -> TXT_ABORT (canonical 1:1 match).
 *
 * In TUs that DO pin ENGLISH (INIT.CPP, STARTUP.CPP per TIM-84),
 * LANGUAGE.H later redefines TEXT_MEMORY_ERROR / TEXT_ABORT to their
 * string-literal forms. The pass harness compiles with -w so the
 * preprocessor's redefinition warning is silenced and the LANGUAGE.H
 * string macro replaces this alias for those TUs -- no behaviour change
 * for the TIM-84 compile paths. The TXT_* names resolve at the call
 * site (post-CONQUER.H), not here, so there is no ordering hazard at
 * force-include time. */
#ifndef TEXT_MEMORY_ERROR
#define TEXT_MEMORY_ERROR   TXT_ERROR_ERROR
#endif
#ifndef TEXT_ABORT
#define TEXT_ABORT          TXT_ABORT
#endif

#endif /* LINUX_STUBS_WINDOWS_H */
