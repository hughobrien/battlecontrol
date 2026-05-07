/* TIM-46 stub: mmsystem.h — minimum-viable Win32 audio typedefs.
 *
 * Pre-TIM-46 this was an empty placeholder so #include resolves. Pass-21
 * (TIM-45) cleared tevent.h:172 and the 179-TU first-error cohort
 * relocated wholesale to DSOUND.H:111 -- the LPWAVEFORMATEX field of
 * the _DSBUFFERDESC struct (outside the _NO_COM / #ifdef _WIN32 guards
 * in DSOUND.H, so it is parsed unconditionally). Real Win32 makes
 * WAVEFORMATEX visible via the windows.h -> mmsystem.h -> mmreg.h
 * transitive include chain; the engine relies on it.
 *
 * Same pattern as TIM-9's windows.h Win32 type taxonomy: smallest opaque
 * shape that lets cc1plus advance past parse, no implementation. Layout
 * matches the Win32 SDK so any byte-level engine code stays sound.
 *
 * Pulled in two ways: (a) explicit `#include <mmsystem.h>` in
 * REDALERT/MCI.H, REDALERT/MCIMOVIE.H, REDALERT/WIN32LIB/MOUSEWW.CPP,
 * REDALERT/WIN32LIB/TIMERINI.CPP, and (b) transitively from
 * linux/win32-stubs/windows.h so DSOUND.H sees LPWAVEFORMATEX through
 * the force-included msvc-compat.h -> windows.h -> mmsystem.h chain
 * even when no source #includes mmsystem.h directly.
 */
#ifndef LINUX_STUBS_MMSYSTEM_H_INCLUDED
#define LINUX_STUBS_MMSYSTEM_H_INCLUDED

/* Pull WORD/DWORD/etc. from the windows.h type taxonomy. The header is
 * fully guarded so re-inclusion via windows.h -> mmsystem.h -> windows.h
 * is a no-op. */
#include "windows.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------
 * WAVEFORMATEX — PCM/extensible wave format header. Layout matches
 * the Win32 SDK form in mmreg.h (7 fields, packed WORD/DWORD/WORD).
 * Used by DSBUFFERDESC.lpwfxFormat in DSOUND.H and by the WIN32LIB
 * audio playback path. We are not implementing a working audio
 * subsystem in this stub; the typedef just lets the parser advance.
 * ------------------------------------------------------------------ */
typedef struct tWAVEFORMATEX {
    WORD  wFormatTag;
    WORD  nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD  nBlockAlign;
    WORD  wBitsPerSample;
    WORD  cbSize;
} WAVEFORMATEX;

typedef WAVEFORMATEX*       PWAVEFORMATEX;
typedef WAVEFORMATEX*       NPWAVEFORMATEX;
typedef WAVEFORMATEX*       LPWAVEFORMATEX;
typedef const WAVEFORMATEX* LPCWAVEFORMATEX;

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LINUX_STUBS_MMSYSTEM_H_INCLUDED */
