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

/* TIM-55: timeBeginPeriod / timeEndPeriod -- Win32 winmm.dll multimedia
 * timer-resolution APIs. WIN32LIB/TIMERINI.CPP:107/110/161 calls these
 * to bump the system tick from the default ~15.6ms down to a sub-ms
 * cadence for the engine's frame timing. On Linux clock_gettime already
 * provides ns resolution, so the no-op stub is semantically correct
 * once the timer subsystem is ported (TIM follow-up). MMRESULT is the
 * SDK's `unsigned int` typedef; TIMERR_NOERROR is 0.
 *
 * The stub is intentionally NOT marked WINAPI (which is empty on Linux
 * via msvc-compat.h) so the prototype matches whatever the upstream
 * call site assumed about the calling convention. */
#ifndef _MMSYSTEM_TIMEPERIOD_DEFINED
#define _MMSYSTEM_TIMEPERIOD_DEFINED
typedef UINT MMRESULT;
#ifndef TIMERR_NOERROR
#define TIMERR_NOERROR 0
#endif
static inline MMRESULT timeBeginPeriod(UINT period) { (void)period; return TIMERR_NOERROR; }
static inline MMRESULT timeEndPeriod(UINT period)   { (void)period; return TIMERR_NOERROR; }
#endif

/* TIM-56: multimedia-timer event-type macros. WIN32LIB/TIMERINI.CPP:122
 * passes `TIME_PERIODIC | TIME_KILL_SYNCHRONOUS` as the fuEvent flags
 * argument to timeSetEvent. Standard SDK values from <mmsystem.h>
 * (https://learn.microsoft.com/windows/win32/api/timeapi/nf-timeapi-timesetevent).
 * The actual periodic-timer dispatch is dormant in this stub --
 * timeSetEvent is itself stubbed below as a no-op returning 0 -- but
 * the bitwise-OR call site needs the integer constants to parse. */
#ifndef TIME_ONESHOT
#define TIME_ONESHOT            0x0000
#endif
#ifndef TIME_PERIODIC
#define TIME_PERIODIC           0x0001
#endif
#ifndef TIME_CALLBACK_FUNCTION
#define TIME_CALLBACK_FUNCTION  0x0000
#endif
#ifndef TIME_CALLBACK_EVENT_SET
#define TIME_CALLBACK_EVENT_SET 0x0010
#endif
#ifndef TIME_CALLBACK_EVENT_PULSE
#define TIME_CALLBACK_EVENT_PULSE 0x0020
#endif
#ifndef TIME_KILL_SYNCHRONOUS
#define TIME_KILL_SYNCHRONOUS   0x0100
#endif

/* TIM-59: timeSetEvent / timeKillEvent + LPTIMECALLBACK -- Win32 winmm
 * multimedia-timer pump. WIN32LIB/TIMERINI.CPP:122 installs a 1ms
 * periodic callback (Timer_Callback, signature `void CALLBACK (UINT,
 * UINT, DWORD, DWORD, DWORD)`) and stores the returned timer id in
 * TimerHandle; line 156 tears it down via timeKillEvent. The periodic
 * dispatch is dormant under the stub -- a real Linux port wires this
 * to timer_create+timerfd or a dedicated POSIX thread. The stubs
 * return 0 (timeSetEvent: 0 == failure, which sets TimerSystemOn =
 * false at line 123; the caller logs an OutputDebugString diagnostic
 * but otherwise advances). The LPTIMECALLBACK typedef matches the SDK
 * exactly so Timer_Callback's `void CALLBACK (UINT, UINT, DWORD,
 * DWORD, DWORD)` declaration is implicitly convertible. */
typedef void (CALLBACK *LPTIMECALLBACK)(UINT, UINT, DWORD, DWORD, DWORD);
static inline MMRESULT timeSetEvent(UINT, UINT, LPTIMECALLBACK, DWORD, UINT) { return 0; }
static inline MMRESULT timeKillEvent(UINT) { return TIMERR_NOERROR; }

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LINUX_STUBS_MMSYSTEM_H_INCLUDED */
