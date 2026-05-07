/* TIM-34/TIM-36 stub: MemoryClass and AUDIO.H choke-header surface.
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
 * TIM-36 expanded the stub from "MemoryClass forward type" to the full
 * set of references AUDIO.H makes. Without these, single-symbol stubs
 * keep substituting in 1:1 under -fmax-errors=20 and the OK count
 * stays pinned at 95 (passes 12-14, three strikes, falsification
 * clause from TIM-35). Static enumeration of AUDIO.H surfaces:
 *
 *   - MemoryClass::operator bool() const   (audio.h:74, `if (mem)`)
 *   - MemoryClass::Free(void const *)      (audio.h:88, Data is const)
 *   - extern bool GameActive               (audio.h:86, dtor guard)
 *   - free(void const *)                   (audio.h:87, free(Name)
 *                                          where Name is char const *)
 *
 * Implementation bodies are intentionally absent. This is a parser-
 * unblock stub, not a runtime port. Real semantics (allocator pool,
 * ref-counting, game-loop ownership of GameActive) belong to a later
 * runtime-correctness pass once we have a runnable binary to validate
 * them against.
 *
 * The `<string.h>` include preserves the memcpy/memmove decls that
 * glibc's <memory.h> would have surfaced, so any TU that relied on
 * the silent fallthrough still sees them. `<stdlib.h>` is added for
 * the `free(void *)` declaration the const-overload forwards to.
 */
#ifndef LINUX_STUBS_MEMORY_H
#define LINUX_STUBS_MEMORY_H

#include <string.h>
#include <stdlib.h>

class MemoryClass {
public:
    void Free(void const *);

    // AUDIO.H:74 does `if (mem)` on a MemoryClass& parameter. Always
    // true here; the real engine's MemoryClass tests an internal
    // allocator handle. Stub returns true so the inline ctor body
    // selects the caller-provided memory handler over global ::Mem.
    operator bool() const { return true; }
};

extern MemoryClass Mem;

// AUDIO.H:86 guards its dtor body on a global "is the game loop
// alive?" flag. The real engine sets this from main(). For -fsyntax-
// only it just needs a declaration so the lookup resolves.
extern bool GameActive;

// AUDIO.H:87 calls `free(Name)` where `Name` is `char const *`. POSIX
// `free()` takes `void *`, and `char const *` does not implicitly
// convert. The cleanest unblock without editing AUDIO.H itself is a
// const-correct overload that forwards to the C library. Inside the
// body, `free(const_cast<void *>(p))` resolves through normal C++
// overload resolution: the libc `void free(void *)` is an exact match
// for a `void *` argument, while this overload would require adding
// const -- so the call dispatches to libc, not back into the overload.
inline void free(void const *p)
{
    free(const_cast<void *>(p));
}

#endif /* LINUX_STUBS_MEMORY_H */
