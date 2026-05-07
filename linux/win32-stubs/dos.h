/* TIM-5 stub: dos.h — empty placeholder so #include resolves. See README.md.
 *
 * TIM-85: pass-40F. Populated with the Watcom DOS file-API family used by
 * REDALERT/RAWFILE.CPP inside its `#ifndef WIN32` branch. The branch
 * fires on Linux because the WWLIB32 chain defensively un-defines WIN32
 * in several headers (wwstd.h, RAWFILE.H, etc.). The original engine
 * relied on Watcom's <i86.h>/<dos.h> / `_dos_*` family to talk DOS
 * INT 21h calls; on Linux the call sites are dormant -- the actual
 * file I/O port will go through fopen/fread once the build links. For
 * now we only need each symbol to parse, so a variadic-template inert
 * stub returning 0 (success-shaped int) is sufficient. The matching
 * SH_DENYNO/SH_DENYRD bit constants live in <share.h> (TIM-53). */
#ifndef LINUX_STUBS_DOS_H_INCLUDED
#define LINUX_STUBS_DOS_H_INCLUDED

#ifdef __cplusplus
template <typename... Args> int _dos_open   (Args&&...) { return 0; }
template <typename... Args> int _dos_creat  (Args&&...) { return 0; }
template <typename... Args> int _dos_close  (Args&&...) { return 0; }
template <typename... Args> int _dos_read   (Args&&...) { return 0; }
template <typename... Args> int _dos_write  (Args&&...) { return 0; }
template <typename... Args> int _dos_getftime(Args&&...) { return 0; }
template <typename... Args> int _dos_setftime(Args&&...) { return 0; }
#endif

#endif
