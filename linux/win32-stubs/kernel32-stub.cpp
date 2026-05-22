// TIM-146 kernel32 thin stub: GetSystemTimeAsFileTime.
//
// EVENT.CPP:610 reads a FILETIME and composes a 64-bit value for
// jitter/heartbeat math. Trivially correct: convert clock_gettime()
// to Win32's "100-ns intervals since 1601-01-01" representation.
// Win32 epoch precedes the Unix epoch by 11644473600 seconds.

#include <time.h>
#include "windows.h"

extern "C" void GetSystemTimeAsFileTime(LPFILETIME ft)
{
    if (!ft) return;

#if defined(__MINGW32__)
    time_t now = time(nullptr);
    long nsec = 0;
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    time_t now = ts.tv_sec;
    long nsec = ts.tv_nsec;
#endif

    unsigned long long hundred_ns =
        ((unsigned long long)now + 11644473600ULL) * 10000000ULL
        + (unsigned long long)(nsec / 100);

    ft->dwLowDateTime  = (DWORD)(hundred_ns & 0xFFFFFFFFULL);
    ft->dwHighDateTime = (DWORD)(hundred_ns >> 32);
}
