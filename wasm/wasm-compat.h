// wasm/wasm-compat.h — WASM/Emscripten compatibility shim.
// Force-included before all ra WASM compile units via -include.
//
// Problem 1: `register` keyword removed in C++17.
//   Upstream WW sources use `register` in declarations. GCC accepts
//   it with -fpermissive; Clang makes it a hard error even with -w.
//   Downgrade via pragma (the [-Wregister] suffix confirms it's a
//   suppressible diagnostic, not a hard parse error).
//
// Problem 2: `random()` type conflict with musl stdlib.h.
//   musl always declares: `long int random(void)`
//   WIN32LIB/MISC.H declares: `unsigned long random(unsigned long mod)`
//   These conflict in Clang even with -fpermissive.
//   Fix: include <stdlib.h> first (locking in the musl declaration)
//   then #define random → ww_lib_random so all subsequent WIN32LIB
//   tokens (declaration in MISC.H, definition in IRANDOM.CPP, all
//   call sites) are consistently renamed. stdlib's random() is already
//   declared before the #define fires, so it stays as `random`.

#pragma clang diagnostic ignored "-Wregister"

#include <stdlib.h>
// Rename WIN32LIB's random(unsigned long mod) to avoid conflicting
// with the already-declared stdlib long int random(void).
#define random ww_lib_random
