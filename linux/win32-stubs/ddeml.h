/* TIM-52 stub: minimum-viable Win32 DDEML handle taxonomy.
 *
 * REDALERT/DDE.H declares Instance_Class members typed HSZ / HCONV /
 * HDDEDATA without including <ddeml.h>; CCDDE.H pulls dde.h under
 * `#ifdef WIN32` and the upstream Win32 build relied on a /FI or PCH
 * path that made the DDEML taxonomy globally visible — same shape as
 * TIM-51 (Winsock1) and TIM-46 (mmsystem.h transitive). Pull this stub
 * from windows.h so every TU that force-includes msvc-compat.h reaches
 * the typedefs.
 *
 * Rules: declarations only, smallest opaque shape, guarded. We do not
 * implement DDE — Westwood used DDE only for the `WChat` lobby and
 * single-instance-detection paths, both irrelevant to the Linux port.
 */
#ifndef LINUX_STUBS_DDEML_H
#define LINUX_STUBS_DDEML_H

/* All DDEML handles are pointer-sized opaque cookies. Pointer-to-void
 * lets dde.h's class members and parameter lists parse and is byte-
 * compatible with the real Win32 typedefs (HSZ etc. are HANDLE-shaped
 * in the SDK). */
typedef void* HSZ;
typedef void* HCONV;
typedef void* HDDEDATA;
typedef void* HCONVLIST;

#endif /* LINUX_STUBS_DDEML_H */
