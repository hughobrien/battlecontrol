// TIM-149 pass-45A: forward declarations for the POSIX file-IO substrate.
//
// Today (master tip d9d674b), `linux/win32-stubs/windows.h:993` ships
// CreateFile / CreateFileA / CloseHandle as variadic-template inert stubs
// returning INVALID_HANDLE_VALUE / FALSE. Under the link build (-DWIN32),
// REDALERT/RAWFILE.CPP::Open (RAWFILE.CPP:256) calls CreateFile, gets
// INVALID_HANDLE_VALUE, and Is_Available / Read / mixfile bootstrap all
// observe "asset not found". No asset will load, so no first-runtime
// exercise of audio/graphics/input is possible end-to-end.
//
// The file-IO substrate replaces those inert stubs with POSIX-backed bodies
// (open(2) / read(2) / write(2) / lseek(2) / fstat(2) / close(2)) on Linux
// only -- MSVC builds keep the upstream Win32 path byte-for-byte. The split
// mirrors TIM-148 pass-44A (audio seam) / TIM-141 pass-41A (DDRAW seam) /
// TIM-145 pass-43A (input seam): pass-45A ships this header only, real
// bodies land in pass-45B.
//
// Why a fresh seam header instead of editing windows.h directly?
//
//   - The variadic-template stubs in windows.h are intentionally inert
//     across many Win32 surfaces (kernel32, user32, gdi32). Promoting only
//     the file-IO subset to real bodies inside the same file would muddy
//     the "all stubs are inert" invariant and risk accidental ABI drift on
//     adjacent stubs.
//   - Consumers outside the substrate .cpp (RAWFILE.CPP, BMP8.CPP,
//     CONQUER.CPP:4300, NULLMGR.CPP, WINSTUB.CPP) all include
//     `<windows.h>` for the HANDLE / DWORD / GENERIC_READ macros and don't
//     need to know about POSIX. The HANDLE encoding is internal to the
//     substrate -- callers stay portable Win32-flavored.
//   - This header is intentionally NOT included by any engine TU in 45A.
//     It is the public surface for the future substrate .cpp and for
//     unit-style smoke tests. Including it from windows.h (or the engine)
//     is the second deliverable in pass-45B, paired with the body landing.
//
// HANDLE encoding (locked in here so 45B doesn't drift):
//
//   On the POSIX substrate, a HANDLE is a heap-allocated descriptor whose
//   address is cast to HANDLE. The descriptor carries the int file
//   descriptor plus enough state to honor Win32 contract:
//     - SetFilePointer with FILE_BEGIN/FILE_CURRENT/FILE_END (lseek SEEK_*)
//     - GetFileSize returning a 32-bit low + 32-bit high pair (fstat st_size
//       split)
//     - ReadFile/WriteFile signaling "bytes transferred" via an out
//       parameter, not the return value (the return is BOOL success)
//
//   INVALID_HANDLE_VALUE remains the upstream sentinel. The substrate
//   returns it on open() failure; CloseHandle on it is a no-op.
//
// 45A non-deliverables (queued for 45B):
//
//   - Real bodies for the six entry points below.
//   - Replacement of the variadic-template stubs in
//     `linux/win32-stubs/windows.h:993-1001` with real declarations bound
//     to the substrate.
//   - First end-to-end smoke: a -DWIN32 -DRA_LINUX_FILEIO build of
//     RAWFILE.CPP that opens REDALERT.MIX and reports its size via
//     GetFileSize. (Smoke is a pass-45B deliverable, not 45A.)
//
// 45A guarantees:
//
//   - Compile floor unchanged (this header is included by no engine TU).
//   - HANDLE / DWORD / BOOL types remain whatever windows.h says they are
//     -- no redefinition.
//   - !_MSC_VER guard ensures the MSVC build is byte-identical.
//
// See `runtime-path-survey` document on TIM-149 for the full §2 rationale,
// the per-pass split (45A..45E), and the upstream call-site inventory.

#ifndef LINUX_WIN32_STUBS_POSIX_FILEIO_H
#define LINUX_WIN32_STUBS_POSIX_FILEIO_H

#if !defined(_MSC_VER)

// We deliberately avoid pulling <windows.h> here -- this header is the
// substrate's *public* surface and must be includable from a substrate .cpp
// that hasn't already had the full Win32 stub avalanche dragged in. The
// substrate .cpp itself will `#include "windows.h"` first to pick up the
// HANDLE / DWORD / BOOL typedefs and the GENERIC_READ / FILE_BEGIN /
// CREATE_ALWAYS macros, then `#include "posix_fileio.h"` for these decls.
//
// Forward-declare the Win32 types we need on the substrate boundary. Using
// `void *` for HANDLE matches `linux/win32-stubs/windows.h`'s existing
// HANDLE typedef; the typedefs here are local to this header so consumers
// that already pulled windows.h see one consistent type.

#ifdef __cplusplus
extern "C" {
#endif

// CreateFile / CreateFileA: open or create a file. The substrate body in
// pass-45B honors:
//   - GENERIC_READ -> O_RDONLY
//   - GENERIC_WRITE -> O_WRONLY | O_CREAT
//   - GENERIC_READ|GENERIC_WRITE -> O_RDWR | O_CREAT
//   - dwCreationDisposition: OPEN_EXISTING / CREATE_ALWAYS / OPEN_ALWAYS /
//     CREATE_NEW / TRUNCATE_EXISTING (mapped to O_CREAT/O_EXCL/O_TRUNC
//     combinations).
// Other CreateFile arguments (security attrs, template handle, share mode,
// flags-and-attributes) are accepted-and-ignored -- the engine never
// exercises them on the runtime hot path.
void *RA_PosixFile_CreateFileA(const char *filename,
                               unsigned long desired_access,
                               unsigned long share_mode,
                               void *security_attributes,
                               unsigned long creation_disposition,
                               unsigned long flags_and_attributes,
                               void *template_file);

// CloseHandle: close + free the descriptor. Returns nonzero on success,
// zero on failure (Win32 BOOL contract). No-op on INVALID_HANDLE_VALUE.
int RA_PosixFile_CloseHandle(void *handle);

// ReadFile: read up to nNumberOfBytesToRead bytes. Returns nonzero on
// success (including short reads / EOF); writes the actual byte count to
// *lpNumberOfBytesRead. *lpOverlapped must be NULL on the substrate -- the
// engine doesn't issue async I/O.
int RA_PosixFile_ReadFile(void *handle,
                          void *buffer,
                          unsigned long bytes_to_read,
                          unsigned long *bytes_read_out,
                          void *overlapped);

// WriteFile: counterpart to ReadFile. Same contract. Required for save
// files and the encryption-key persisted blob; not on the asset hot path.
int RA_PosixFile_WriteFile(void *handle,
                           const void *buffer,
                           unsigned long bytes_to_write,
                           unsigned long *bytes_written_out,
                           void *overlapped);

// SetFilePointer: lseek(2) with FILE_BEGIN (SEEK_SET) / FILE_CURRENT
// (SEEK_CUR) / FILE_END (SEEK_END) translation. Returns the new low-32 of
// the file pointer; pHigh (if non-NULL) receives the high-32. Returns
// INVALID_SET_FILE_POINTER (0xFFFFFFFF) on error. The engine seldom uses
// 64-bit-aware seeks, but the contract is honored.
unsigned long RA_PosixFile_SetFilePointer(void *handle,
                                          long distance_low,
                                          long *distance_high,
                                          unsigned long move_method);

// GetFileSize: fstat(2) split into low/high 32-bit halves. Returns the
// low-32; if pHigh is non-NULL it receives the high-32. The mixfile
// loader reads this through CCFileClass / CDFileClass which forward to
// RawFileClass, but the file-size query also goes through GetFileSize
// directly in BMP8.CPP and the audio sample loader.
unsigned long RA_PosixFile_GetFileSize(void *handle, unsigned long *size_high);

#ifdef __cplusplus
}
#endif

#endif // !_MSC_VER

#endif // LINUX_WIN32_STUBS_POSIX_FILEIO_H
