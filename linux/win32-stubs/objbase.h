/* TIM-5 stub: objbase.h — empty placeholder so #include resolves. See README.md. */
#ifndef LINUX_STUBS_OBJBASE_H_INCLUDED
#define LINUX_STUBS_OBJBASE_H_INCLUDED

/* TIM-11: Defensive mirror of the _NO_COM guard set in msvc-compat.h, so any
 * direct #include <objbase.h> from upstream code still gates DDRAW.H's COM
 * block off on Linux even if the force-include shim were ever bypassed. */
#ifndef _NO_COM
#define _NO_COM
#endif

#endif
