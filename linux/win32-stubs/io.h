/* TIM-5 stub: io.h — empty placeholder so #include resolves. See README.md.
 *
 * TIM-87: pass-40G. Populated with `filelength`, the MS C runtime
 * file-size primitive. REDALERT/RAWFILE.CPP:881 calls it inside the
 * `#else` (non-WIN32) branch of RawFileClass::Size to query the size
 * of an open low-level file handle. Original engine relied on the
 * Watcom CRT signature `long filelength(int handle)`; on Linux the
 * call site is dormant under the stub -- the eventual port will use
 * `fstat(2)` once the build links. For now we only need the symbol to
 * parse, so a variadic-template inert stub returning 0 is sufficient
 * (the loop in RawFileClass::Size treats `size == -1` as the only
 * error sentinel; size == 0 just falls through). Same shape as TIM-85
 * `_dos_*` family in dos.h. */
#ifndef LINUX_STUBS_IO_H_INCLUDED
#define LINUX_STUBS_IO_H_INCLUDED

/* TIM-339: Windows <io.h> provides unlink(); on Linux it comes from <unistd.h>. */
#include <unistd.h>

#ifdef __cplusplus
template <typename... Args> long filelength(Args&&...) { return 0; }
/* TIM-88: pass-40H. RAWFILE.CPP:1317 calls `lseek(Handle, pos, dir)`
 * inside the `#else` (non-WIN32) branch of RawFileClass::Raw_Seek. POSIX
 * normally exposes lseek via <unistd.h>, but the Watcom CRT placed it in
 * <io.h>, which is the include the engine reaches through. Same shape as
 * `filelength` above and the TIM-85 `_dos_*` family in dos.h. The call
 * site assigns the return into `pos` and only treats `pos == -1` as a
 * fatal seek error, so an inert `0` return is safe (caller proceeds with
 * a position-zero file pointer). */
template <typename... Args> long lseek(Args&&...) { return 0; }
#endif

#endif
