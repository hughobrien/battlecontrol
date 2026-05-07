/* TIM-34 stub: MemoryClass forward type for AUDIO.H.
 *
 * REDALERT/AUDIO.H and TIBERIANDAWN/AUDIO.H do `#include "memory.h"`
 * to pull in the engine's MemoryClass. The class is referenced (member
 * pointer at audio.h:44, ctor parameter at audio.h:49, Mem->Free at
 * audio.h:88, global ::Mem at audio.h:77) but is **not defined
 * anywhere in the published source tree** -- the type was lost when
 * the codebase was extracted/published. Pass 13 (TIM-33) measured
 * 180/206 (87.4%) of primary failures cascading off audio.h:44
 * 'MemoryClass does not name a type'.
 *
 * Without this file, `#include "memory.h"` silently resolves to
 * glibc's /usr/include/memory.h (memcpy/memmove only). Placing this
 * header in linux/win32-stubs/ shadows the glibc fallback and gives
 * AUDIO.H the type it needs.
 *
 * Surface is the minimum required for -fsyntax-only:
 *   - `class MemoryClass` with `void Free(void*)`
 *   - `extern MemoryClass Mem` for the global ::Mem reference
 *
 * Implementation bodies are intentionally absent. This is a parser-
 * unblock stub, not a runtime port. The real MemoryClass semantics
 * (allocator pool, ref-counting, etc.) belong to a later runtime-
 * correctness pass once we have a runnable binary to validate them.
 *
 * The transitive `<string.h>` include preserves the memcpy/memmove
 * declarations that glibc's <memory.h> would have surfaced, so any
 * TU that relied on the silent fallthrough still sees them.
 */
#ifndef LINUX_STUBS_MEMORY_H
#define LINUX_STUBS_MEMORY_H

#include <string.h>

class MemoryClass {
public:
    void Free(void *);
};

extern MemoryClass Mem;

#endif /* LINUX_STUBS_MEMORY_H */
