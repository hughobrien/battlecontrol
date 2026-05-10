/* TIM-376: execinfo.h stub for Emscripten/musl which lacks glibc's backtrace API.
 * Provides no-op stubs so STARTUP.CPP's crash handler compiles without
 * producing any output on WASM. */
#ifndef _WASM_EXECINFO_H
#define _WASM_EXECINFO_H

#ifdef __cplusplus
extern "C" {
#endif

static inline int backtrace(void** /*buffer*/, int /*size*/) { return 0; }
static inline char** backtrace_symbols(void* const* /*buffer*/, int /*size*/) { return 0; }
static inline void backtrace_symbols_fd(void* const* /*buffer*/, int /*size*/, int /*fd*/) {}

#ifdef __cplusplus
}
#endif

#endif /* _WASM_EXECINFO_H */
