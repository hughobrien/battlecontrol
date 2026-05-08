/* TIM-5 stub: conio.h — minimal shim for DOS/MSVC console I/O. */
#ifndef LINUX_STUBS_CONIO_H_INCLUDED
#define LINUX_STUBS_CONIO_H_INCLUDED
#include <stdio.h>
/* getch() — TIM-159: used only in DOS error-path branches; map to getchar(). */
static inline int getch(void) { return getchar(); }
#endif
