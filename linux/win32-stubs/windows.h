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

#endif /* LINUX_STUBS_WINDOWS_H */
