// TIM-149 pass-45B: POSIX-backed file-IO substrate bodies.
//
// This TU is the link-time partner of the windows.h kernel32 file-IO
// declarations promoted from inert variadic-template stubs in pass-45B.
// It also defines the RA_PosixFile_* C-extern surface declared in
// posix_fileio.h, kept around for direct use by the substrate's own
// internal helpers and any future Linux-native file-IO that wants to
// bypass the Win32 wrappers.
//
// Backend choice: raw POSIX (open/read/write/lseek/fstat/close), not
// std::fstream. Reasons:
//   - The Win32 file-IO API delivers byte counts via out-pointer
//     arguments and signals success via BOOL return; std::fstream's
//     iostate machinery would require a translation layer.
//   - The engine's RawFileClass::Read/Write loops expect short-read
//     semantics (read fewer bytes than requested == EOF / EINTR retry
//     responsibility on the caller side); read(2) matches naturally.
//   - The HANDLE encoding stays a heap-allocated descriptor that's
//     trivial to introspect under a debugger.
//
// HANDLE encoding: a HANDLE is either INVALID_HANDLE_VALUE or a
// pointer to a heap-allocated PosixFileDesc whose `fd` field holds a
// real Linux file descriptor. The descriptor is freed on CloseHandle.
// Returning bare `(HANDLE)(intptr_t)fd` would be tempting but breaks
// the INVALID_HANDLE_VALUE sentinel (-1 in either encoding) and would
// make CloseHandle ambiguous. The descriptor wrapper is also where
// future flags (e.g. case-fold-applied path, OPEN_ALWAYS-vs-CREATE_ALWAYS
// recovery state) will live in pass-45D.
//
// !_MSC_VER guarded: MSVC builds keep the upstream Win32 path. Same
// pattern as REDALERT/AUDIO.CPP's `#ifndef _MSC_VER` audio substrate,
// REDALERT/WIN32LIB/DDRAW.CPP's DDRAW substrate, and KEY.CPP's input
// pump.
//
// Compile-floor note: this TU lives in linux/win32-stubs/, not
// REDALERT/. The compile-floor measurement
// (scripts/first-compile-pass45*.sh) globs `REDALERT/*.cpp` and
// `REDALERT/WIN32LIB/*.cpp` -- this file is not in that set. That is
// intentional: the floor measures upstream-engine TU compilation, not
// the SDL/POSIX substrate. The substrate .cpp is exercised at link
// time, owned by the link-side workstream (TIM-144) and the
// CMakeLists.txt that will eventually build redalert.elf.

#if !defined(_MSC_VER)

#include "windows.h"      // HANDLE, DWORD, BOOL, INVALID_HANDLE_VALUE, GENERIC_*,
                          // FILE_SHARE_*, OPEN_EXISTING / CREATE_ALWAYS / ...,
                          // FILE_BEGIN / FILE_CURRENT / FILE_END, LPOVERLAPPED.
#include "posix_fileio.h" // RA_PosixFile_* C-extern decls.

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdlib.h>
#include <errno.h>

namespace {

struct PosixFileDesc {
    int fd;
};

// Translate Win32 GENERIC_*/dwCreationDisposition into POSIX open(2)
// flags. The SDK contract:
//   - GENERIC_READ alone           -> O_RDONLY
//   - GENERIC_WRITE alone          -> O_WRONLY (CREATE_ALWAYS implies O_CREAT|O_TRUNC)
//   - GENERIC_READ | GENERIC_WRITE -> O_RDWR
// Anything else (GENERIC_EXECUTE, GENERIC_ALL) is not exercised by the
// engine; we map to O_RDWR as the safe superset.
int translate_open_flags(DWORD desired_access, DWORD creation_disposition)
{
    int flags;
    DWORD const rw_mask = GENERIC_READ | GENERIC_WRITE;
    DWORD const masked  = desired_access & rw_mask;

    if (masked == GENERIC_READ) {
        flags = O_RDONLY;
    } else if (masked == GENERIC_WRITE) {
        flags = O_WRONLY;
    } else if (masked == rw_mask) {
        flags = O_RDWR;
    } else {
        // No GENERIC bits set, or only GENERIC_EXECUTE. Treat as RDWR
        // for the engine -- but flag as O_RDONLY when desired_access is
        // zero outright (rare, but seen in the Westwood code).
        flags = (desired_access == 0) ? O_RDONLY : O_RDWR;
    }

    switch (creation_disposition) {
    case CREATE_NEW:
        flags |= O_CREAT | O_EXCL;
        break;
    case CREATE_ALWAYS:
        flags |= O_CREAT | O_TRUNC;
        break;
    case OPEN_EXISTING:
        // No extra flags. open(2) without O_CREAT will return ENOENT
        // for nonexistent paths -- exactly the Win32 contract.
        break;
    case OPEN_ALWAYS:
        flags |= O_CREAT;
        break;
    case TRUNCATE_EXISTING:
        flags |= O_TRUNC;
        break;
    default:
        // Unknown disposition; fall through to OPEN_EXISTING semantics.
        break;
    }

    return flags;
}

int translate_seek_whence(DWORD move_method)
{
    switch (move_method) {
    case FILE_BEGIN:   return SEEK_SET;
    case FILE_CURRENT: return SEEK_CUR;
    case FILE_END:     return SEEK_END;
    default:           return SEEK_SET;
    }
}

PosixFileDesc * desc_from_handle(HANDLE h)
{
    if (h == nullptr || h == INVALID_HANDLE_VALUE) return nullptr;
    return static_cast<PosixFileDesc *>(h);
}

} // namespace

extern "C" {

void *RA_PosixFile_CreateFileA(const char *filename,
                               unsigned long desired_access,
                               unsigned long /*share_mode*/,
                               void * /*security_attributes*/,
                               unsigned long creation_disposition,
                               unsigned long /*flags_and_attributes*/,
                               void * /*template_file*/)
{
    if (filename == nullptr || filename[0] == '\0') {
        return INVALID_HANDLE_VALUE;
    }

    int const flags = translate_open_flags(static_cast<DWORD>(desired_access),
                                           static_cast<DWORD>(creation_disposition));
    // Default mode for newly-created files: rw-r--r-- (0644). The engine
    // never sets explicit mode bits via the Win32 API, so this default
    // matches Westwood's de facto behavior on Win9x/NT.
    mode_t const mode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;

    int const fd = ::open(filename, flags, mode);
    if (fd < 0) {
        return INVALID_HANDLE_VALUE;
    }

    PosixFileDesc *d = static_cast<PosixFileDesc *>(::malloc(sizeof(PosixFileDesc)));
    if (d == nullptr) {
        ::close(fd);
        return INVALID_HANDLE_VALUE;
    }
    d->fd = fd;
    return d;
}

int RA_PosixFile_CloseHandle(void *handle)
{
    PosixFileDesc *d = desc_from_handle(handle);
    if (d == nullptr) return 0; // Win32 BOOL FALSE: nothing to close.
    int const r = ::close(d->fd);
    ::free(d);
    return (r == 0) ? 1 : 0;
}

int RA_PosixFile_ReadFile(void *handle,
                          void *buffer,
                          unsigned long bytes_to_read,
                          unsigned long *bytes_read_out,
                          void *overlapped)
{
    if (overlapped != nullptr) {
        // Engine doesn't issue async I/O. If a caller ever does, surface
        // it as a contract violation rather than silently mis-handling.
        if (bytes_read_out) *bytes_read_out = 0;
        return 0;
    }
    PosixFileDesc *d = desc_from_handle(handle);
    if (d == nullptr || buffer == nullptr) {
        if (bytes_read_out) *bytes_read_out = 0;
        return 0;
    }

    // Honor short reads: read(2) may return fewer bytes than requested
    // (signals, partial reads). We loop until either bytes_to_read is
    // satisfied, EOF (read returns 0), or a hard error.
    unsigned long total = 0;
    char *p = static_cast<char *>(buffer);
    while (total < bytes_to_read) {
        ssize_t const n = ::read(d->fd, p + total,
                                 static_cast<size_t>(bytes_to_read - total));
        if (n == 0) break;            // EOF.
        if (n < 0) {
            if (errno == EINTR) continue;
            if (bytes_read_out) *bytes_read_out = total;
            return 0;
        }
        total += static_cast<unsigned long>(n);
    }
    if (bytes_read_out) *bytes_read_out = total;
    return 1;
}

int RA_PosixFile_WriteFile(void *handle,
                           const void *buffer,
                           unsigned long bytes_to_write,
                           unsigned long *bytes_written_out,
                           void *overlapped)
{
    if (overlapped != nullptr) {
        if (bytes_written_out) *bytes_written_out = 0;
        return 0;
    }
    PosixFileDesc *d = desc_from_handle(handle);
    if (d == nullptr || buffer == nullptr) {
        if (bytes_written_out) *bytes_written_out = 0;
        return 0;
    }

    unsigned long total = 0;
    const char *p = static_cast<const char *>(buffer);
    while (total < bytes_to_write) {
        ssize_t const n = ::write(d->fd, p + total,
                                  static_cast<size_t>(bytes_to_write - total));
        if (n < 0) {
            if (errno == EINTR) continue;
            if (bytes_written_out) *bytes_written_out = total;
            return 0;
        }
        total += static_cast<unsigned long>(n);
    }
    if (bytes_written_out) *bytes_written_out = total;
    return 1;
}

unsigned long RA_PosixFile_SetFilePointer(void *handle,
                                          long distance_low,
                                          long *distance_high,
                                          unsigned long move_method)
{
    PosixFileDesc *d = desc_from_handle(handle);
    if (d == nullptr) return INVALID_SET_FILE_POINTER;

    // Combine 32-bit low + 32-bit high into a 64-bit offset. The engine
    // almost always passes distance_high == NULL (offsets fit in 31
    // bits); preserve full precision when the caller does pass a high
    // word.
    long long offset = static_cast<long long>(static_cast<int>(distance_low));
    if (distance_high != nullptr) {
        offset = (static_cast<long long>(*distance_high) << 32)
               | (static_cast<long long>(static_cast<unsigned int>(distance_low)));
    }

    int const whence = translate_seek_whence(static_cast<DWORD>(move_method));
    off_t const r = ::lseek(d->fd, static_cast<off_t>(offset), whence);
    if (r == static_cast<off_t>(-1)) {
        return INVALID_SET_FILE_POINTER;
    }

    if (distance_high != nullptr) {
        *distance_high = static_cast<long>(static_cast<long long>(r) >> 32);
    }
    return static_cast<unsigned long>(static_cast<long long>(r) & 0xFFFFFFFFLL);
}

unsigned long RA_PosixFile_GetFileSize(void *handle, unsigned long *size_high)
{
    PosixFileDesc *d = desc_from_handle(handle);
    if (d == nullptr) return INVALID_FILE_SIZE;

    struct stat st;
    if (::fstat(d->fd, &st) != 0) {
        return INVALID_FILE_SIZE;
    }
    long long const sz = static_cast<long long>(st.st_size);
    if (size_high != nullptr) {
        *size_high = static_cast<unsigned long>((sz >> 32) & 0xFFFFFFFFLL);
    }
    return static_cast<unsigned long>(sz & 0xFFFFFFFFLL);
}

// =====================================================================
// Win32 SDK names. Definitions of the symbols declared in windows.h.
// =====================================================================

HANDLE CreateFileA(LPCSTR lpFileName,
                   DWORD dwDesiredAccess,
                   DWORD dwShareMode,
                   LPSECURITY_ATTRIBUTES lpSecurityAttributes,
                   DWORD dwCreationDisposition,
                   DWORD dwFlagsAndAttributes,
                   HANDLE hTemplateFile)
{
    return RA_PosixFile_CreateFileA(lpFileName,
                                    static_cast<unsigned long>(dwDesiredAccess),
                                    static_cast<unsigned long>(dwShareMode),
                                    static_cast<void *>(lpSecurityAttributes),
                                    static_cast<unsigned long>(dwCreationDisposition),
                                    static_cast<unsigned long>(dwFlagsAndAttributes),
                                    static_cast<void *>(hTemplateFile));
}

BOOL CloseHandle(HANDLE hObject)
{
    return RA_PosixFile_CloseHandle(hObject) ? TRUE : FALSE;
}

BOOL ReadFile(HANDLE hFile,
              LPVOID lpBuffer,
              DWORD nNumberOfBytesToRead,
              LPDWORD lpNumberOfBytesRead,
              LPOVERLAPPED lpOverlapped)
{
    unsigned long n = 0;
    int const r = RA_PosixFile_ReadFile(hFile, lpBuffer,
                                        static_cast<unsigned long>(nNumberOfBytesToRead),
                                        &n,
                                        static_cast<void *>(lpOverlapped));
    if (lpNumberOfBytesRead) {
        *lpNumberOfBytesRead = static_cast<DWORD>(n);
    }
    return r ? TRUE : FALSE;
}

BOOL WriteFile(HANDLE hFile,
               const void * lpBuffer,
               DWORD nNumberOfBytesToWrite,
               LPDWORD lpNumberOfBytesWritten,
               LPOVERLAPPED lpOverlapped)
{
    unsigned long n = 0;
    int const r = RA_PosixFile_WriteFile(hFile, lpBuffer,
                                         static_cast<unsigned long>(nNumberOfBytesToWrite),
                                         &n,
                                         static_cast<void *>(lpOverlapped));
    if (lpNumberOfBytesWritten) {
        *lpNumberOfBytesWritten = static_cast<DWORD>(n);
    }
    return r ? TRUE : FALSE;
}

DWORD SetFilePointer(HANDLE hFile,
                     LONG lDistanceToMove,
                     LONG * lpDistanceToMoveHigh,
                     DWORD dwMoveMethod)
{
    return static_cast<DWORD>(
        RA_PosixFile_SetFilePointer(hFile,
                                    static_cast<long>(lDistanceToMove),
                                    reinterpret_cast<long *>(lpDistanceToMoveHigh),
                                    static_cast<unsigned long>(dwMoveMethod)));
}

DWORD GetFileSize(HANDLE hFile, LPDWORD lpFileSizeHigh)
{
    unsigned long high = 0;
    unsigned long const low = RA_PosixFile_GetFileSize(hFile, &high);
    if (lpFileSizeHigh) {
        *lpFileSizeHigh = static_cast<DWORD>(high);
    }
    return static_cast<DWORD>(low);
}

} // extern "C"

#endif // !_MSC_VER
