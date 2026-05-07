/* TIM-5 stub: share.h — placeholder so #include resolves. See README.md.
 *
 * TIM-53: populated with the MSVC <share.h> file-sharing-mode constants.
 * RAWFILE.CPP:259 calls _dos_open(name, O_RDONLY|SH_DENYNO, ...) inside
 * the !WIN32 branch; even though we are on Linux, that branch fires
 * because we deliberately do not define WIN32 globally (see
 * windows.h note on the WWLIB32 chain's defensive WIN32 #define).
 * Constants mirror MSVC's share.h so any bitwise OR'd combination
 * parses with the same numeric value the original engine produced.
 * The actual share semantics are unenforced on Linux. */
#ifndef LINUX_STUBS_SHARE_H_INCLUDED
#define LINUX_STUBS_SHARE_H_INCLUDED

#ifndef SH_COMPAT
#define SH_COMPAT    0x00
#endif
#ifndef SH_DENYRW
#define SH_DENYRW    0x10
#endif
#ifndef SH_DENYWR
#define SH_DENYWR    0x20
#endif
#ifndef SH_DENYRD
#define SH_DENYRD    0x30
#endif
#ifndef SH_DENYNO
#define SH_DENYNO    0x40
#endif

#endif
