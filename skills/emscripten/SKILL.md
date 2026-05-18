---
name: emscripten
description: Use when porting C++ to WebAssembly with Emscripten, debugging WASM-specific issues, or configuring CMake/linker flags for an Emscripten build. Also trigger on symptoms like EM_ASM silently failing, WASM audio garbled or pitched wrong, black screen despite game loop running, onRuntimeInitialized never firing, getenv returning NULL in browser, IDBFS file I/O silently dropped, undefined symbols at link time, or CI timing out waiting for WASM to load.
version: 0.2.0
---

# Emscripten / WebAssembly Porting Skill

> **Tools available via `pi-battlecontrol-dev` extension:** `build_wasm`, `wasm_validate`,
> `wasm_screenshot`, `run_e2e_test`.
> Ask the agent to run these instead of typing raw commands.

You are guiding work on a C++ → WASM port using Emscripten. This project has an active
playbook at `docs/emscripten-playbook.md` — read it first for symptom→root-cause→fix
entries derived from real issues in this repo.

---

## Phase 0 — Read the playbook before anything else

```bash
cat docs/emscripten-playbook.md
```

The playbook is the single source of truth for patterns already solved in this project
(PROXY_TO_PTHREAD boundaries, SDL audio bypass, sample-rate mismatch, FORCE_FILESYSTEM,
linker order, CI JIT cold-start, verification bar). If the symptom matches a playbook
entry, apply the documented fix directly — do not re-derive it.

If you discover a new gotcha not yet in the playbook, add a dated entry (symptom → root
cause → fix → reference) and commit it alongside the code fix.

---

## Phase 1 — Classify the symptom

Apply these lenses in order. The first match drives Phase 2.

| Symptom | Lens | Go to |
|---|---|---|
| `EM_ASM` block does nothing; `Module['_key']` undefined; browser APIs return null | PROXY_TO_PTHREAD — EM_ASM runs in Worker | §2.1 |
| SDL audio opens but sound is garbled, stutters, or null-function trap | PROXY_TO_PTHREAD — SDL ScriptProcessorNode from Worker | §2.2 |
| Black screen; `GLctx` undefined in DevTools; game loop runs fine | PROXY_TO_PTHREAD — hardware renderer needs main thread | §2.3 |
| `fopen`/`stat` silently fail; assets missing at runtime | FORCE_FILESYSTEM not set | §3 |
| `getenv("VAR")` returns NULL despite being set in shell | Module.ENV not injected | §4 |
| Audio pitch wrong — too high or too low by a fixed ratio | AudioContext.sampleRate mismatch | §5.1 |
| Audio null-function trap passes once, fails ~50% of subsequent runs | Intermittent WASM audio race | §5.2 |
| Link fails with undefined symbols for functions in `-lSDL2` | Linker order (ld.bfd left-to-right) | §6.1 |
| CI times out; `onRuntimeInitialized` never fires in headless browser | -O2 JIT cold-start | §6.2 |
| New C++ target to port (first time on this codebase) | Onboarding checklist | §7 |

---

## §2.1 — PROXY_TO_PTHREAD: EM_ASM boundary crossing

Under `-sPROXY_TO_PTHREAD` the game loop runs in a Worker. Plain `EM_ASM` executes in
that Worker's Module context — it cannot see the browser main thread, the DOM, Web Audio,
or any JS state set before `onRuntimeInitialized`.

**Fix:** Replace `EM_ASM` / `EM_ASM_INT` with `MAIN_THREAD_EM_ASM` /
`MAIN_THREAD_EM_ASM_INT` for any block that:

- reads `Module['_key']`
- accesses the DOM or window
- creates or uses a Web Audio node

Audit every `EM_ASM` block in ported files. In particular: audio setup, renderer init,
and any env-var probing that touches the JS harness.

**Reference:** [Emscripten pthreads — calling JS from a pthread](https://emscripten.org/docs/porting/pthreads.html#accessing-the-dom-from-pthreads)

---

## §2.2 — PROXY_TO_PTHREAD: SDL audio / ScriptProcessorNode

SDL2's audio backend uses `ScriptProcessorNode`, which cannot be created or driven from
a Worker thread. Do **not** call `SDL_OpenAudioDevice` in the WASM target.

**Fix pattern (established in TIM-604 and TIM-555):**

1. Conditionally skip `SDL_OpenAudioDevice` under `__EMSCRIPTEN__`.
2. Use a sentinel handle (e.g. `vqa_audio_dev = 1`) so callers can distinguish the WASM
   path from a real SDL device.
3. Push decoded PCM into a C-side queue (e.g. `vqa_audio_queue_s16`).
4. In `MAIN_THREAD_EM_ASM`, create an `AudioBufferSourceNode` per chunk, schedule it
   with `source.start(nextTime)`, and advance `nextTime += buffer.duration`.

```cpp
#ifdef __EMSCRIPTEN__
    vqa_audio_dev = 1; // sentinel — no SDL_OpenAudioDevice
#else
    vqa_audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
#endif
```

**Reference:** [SDL issue #4740 — ScriptProcessorNode not usable from Workers](https://github.com/libsdl-org/SDL/issues/4740)

---

## §2.3 — PROXY_TO_PTHREAD: software renderer

Hardware rendering requires a `WebGLRenderingContext` on the main thread, unavailable
from a Worker. Always use `SDL_RENDERER_SOFTWARE` in WASM builds.

```cpp
#ifdef __EMSCRIPTEN__
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
#else
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
#endif
```

---

## §3 — FORCE_FILESYSTEM / IDBFS

IDBFS (persistent storage) requires `-sFORCE_FILESYSTEM=1`. Without it, the Emscripten
VFS is a stub in optimised builds and all filesystem calls are silent no-ops.

**Fix:**
```cmake
target_link_options(my_target PRIVATE -sFORCE_FILESYSTEM=1)
```

Also verify that `--preload-file` / `--embed-file` paths match the VFS tree exactly —
path mismatches fail silently at runtime with no error logged.

**Reference:** [Emscripten Filesystem API — persistent data](https://emscripten.org/docs/api_reference/Filesystem-API.html#persistent-data)

---

## §4 — Environment variable injection via Module.ENV

The browser has no shell environment. `getenv()` reads from `Module.ENV`, not from the
process environment. Inject before `onRuntimeInitialized` fires.

```js
var Module = {
  ENV: {
    MY_VAR: "value",
    RA_AUTOSTART: "1",
    AUDIO_SAMPLE_RATE: String(new AudioContext().sampleRate),
  },
  onRuntimeInitialized: function() { /* … */ },
};
```

Variables needed at startup (e.g. `RA_AUTOSTART`) must be in `Module.ENV` — C++ `main()`
runs after `onRuntimeInitialized`, so injecting them in C++ `putenv` is already too late
for checks at the top of `main()`.

**Reference:** [Emscripten — environment variables](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/Interacting-with-code.html#environment-variables)

---

## §5.1 — Audio sample-rate mismatch (pitch artifacts)

`AudioContext.sampleRate` is browser-determined (44100 or 48000 Hz) and may differ from
the SDL device rate you requested. SDL uses the requested rate; the browser plays at its
own rate → pitch shift proportional to `device_rate / context_rate`.

**Fix:** Query `AudioContext.sampleRate` before opening any audio device and pass it
to C++ via `Module.ENV`:

```js
var audioCtx = new AudioContext();
Module.ENV.AUDIO_SAMPLE_RATE = String(audioCtx.sampleRate);
```

```cpp
int sample_rate = atoi(getenv("AUDIO_SAMPLE_RATE") ?: "44100");
```

Or stride-resample at queue boundaries: compute `stride = src_rate / dev_rate` and
interpolate each chunk before enqueueing. (Pattern from TIM-555 / TIM-602.)

**Reference:** [Web Audio — AudioContext.sampleRate](https://webaudio.github.io/web-audio-api/#dom-baseaudiocontext-samplerate)

---

## §5.2 — Intermittent audio trap (5/5 rule)

WASM audio timing races are non-deterministic. A single CI pass hides a ~50%
null-function trap probability.

**Rule:** Require **5/5 cold-cache passes** before marking WASM audio verified. Between
runs, clear the browser profile. Never accept one green run as sufficient evidence.
(Rule established from TIM-600 incident.)

---

## §6.1 — Linker order for ld.bfd

`ld.bfd` resolves symbols left-to-right. `-lSDL2` placed before object files causes
undefined symbols because the library is scanned before the references are known.

**Fix:** System libraries always after object files:
```cmake
# Correct:
target_link_libraries(my_target PRIVATE my_objects SDL2)
# Wrong:
target_link_libraries(my_target PRIVATE SDL2 my_objects)
```

**Reference:** [GNU ld — archive ordering](https://sourceware.org/binutils/docs/ld/Archives.html)

---

## §6.2 — -O2 JIT cold-start in CI

Optimised (`-O2`) WASM takes 240 s+ to JIT-compile in a headless browser. `waitForFunction`
with a short timeout fires before JIT is done → flaky or always-failing CI.

**Fix:** Gate on `onRuntimeInitialized` with ≥300 s timeout:

```js
var Module = {
  onRuntimeInitialized: function() {
    window.__wasmReady = true;
  },
};
```

```ts
// Playwright — wait up to 5 minutes
await page.waitForFunction(() => (window as any).__wasmReady === true, { timeout: 300_000 });
```

Do **not** revert to `waitForFunction` with a short timeout. (Pattern from TIM-597.)

**Reference:** [Emscripten Module — onRuntimeInitialized](https://emscripten.org/docs/api_reference/module.html#Module.onRuntimeInitialized)

---

## §7 — Onboarding a new C++ target

When adding a new C++ executable to the WASM build:

1. **Read the playbook** (`docs/emscripten-playbook.md`) and scan for prior art on
   similar targets in this repo.
2. **Apply the CMake template** (reproduced at the bottom of the playbook) as a starting
   point; adjust `INITIAL_MEMORY` and `--preload-file` paths.
3. **Audit every `EM_ASM`** block for PROXY_TO_PTHREAD boundary violations (§2.1).
4. **Skip `SDL_OpenAudioDevice`** on the WASM path (§2.2); wire up the
   `AudioBufferSourceNode` scheduler.
5. **Set `SDL_RENDERER_SOFTWARE`** (§2.3).
6. **Inject required env vars** in the JS harness (§4), including `AUDIO_SAMPLE_RATE`.
7. **Add `-sFORCE_FILESYSTEM=1`** if any file I/O is expected at runtime (§3).
8. **Run the verification bar** below before marking the port done.

Target: collapse the porting work to 2–3 commits using this checklist.

---

## §8 — Verification bar (required before marking done)

| Gate | How | Minimum proof |
|------|-----|---------------|
| **Build** | `build_wasm(target: "ra")` then `wasm_validate(target: "ra")` | `.wasm` + `.js` produced, magic + size > 1MB valid |
| **Loads** | `run_e2e_test(spec: "e2e/regression/T1-ra-wasm-boot.spec.ts")` | `onRuntimeInitialized` fires; no `Uncaught` in DevTools |
| **File I/O** | Required assets accessible via VFS (preload log or runtime probe) | Manual check |
| **Audio** | `run_e2e_test(spec: "e2e/tim603-audio-pitch-probe.spec.ts")` | 5/5 cold-cache CI runs pass |
| **Video** | `wasm_screenshot(target: "ra", waitMs: 2000)` — inspect visually | Fill-% alone insufficient (TIM-587) |
| **Exit** | Process exits cleanly; no runaway Worker | Manual check |

Never mark WASM audio verified on a single CI run. Screenshot inspection is required for
any visual output — quantitative metrics can pass while frames show corruption (TIM-587).

---

## Quick CMake template

```cmake
if(EMSCRIPTEN)
  target_compile_options(my_game PRIVATE -O2)
  target_link_options(my_game PRIVATE
    -sUSE_SDL=2
    -sPROXY_TO_PTHREAD=1
    -sFORCE_FILESYSTEM=1
    -sALLOW_MEMORY_GROWTH=1
    -sINITIAL_MEMORY=67108864
    --preload-file ${CMAKE_SOURCE_DIR}/assets@/assets
  )
  # SDL2 MUST come after object files for ld.bfd
  target_link_libraries(my_game PRIVATE SDL2)
endif()
```

---

## §9 — WASM memory debugging

### Linear memory overflow

When the game allocates more memory than `INITIAL_MEMORY`, Emscripten either
crashes (without `ALLOW_MEMORY_GROWTH`) or expands the heap (with it).

**Symptom:** Silent crash, `abort()` with no message, or `Out of memory` in
browser console.

**Diagnose:**
```js
// In browser DevTools console, after crash:
console.log(Module.HEAP8.length);  // Current heap size in bytes
console.log(Module.HEAP8.buffer.maxByteLength); // Max allowed (if growth enabled)
```

**Fix:** Increase `INITIAL_MEMORY` or enable `ALLOW_MEMORY_GROWTH`:
```cmake
target_link_options(my_target PRIVATE
  -sINITIAL_MEMORY=134217728     # 128 MB
  -sALLOW_MEMORY_GROWTH=1        # Allow growth beyond INITIAL
  -sMAXIMUM_MEMORY=268435456     # Cap at 256 MB
)
```

### Getting stack traces from WASM

Build with debug info to get line-numbered stack traces in the browser:
```cmake
# In CMakeLists.txt, for debug builds:
target_compile_options(my_target PRIVATE
  $<$<CONFIG:Debug>:-g4 -O0 -sASSERTIONS=2>
)
target_link_options(my_target PRIVATE
  $<$<CONFIG:Debug>:-g4 -sASSERTIONS=2>
)
```

Then in DevTools:
- Sources panel → find the `.wasm` file → DWARF info enables source-mapped stepping
- Console: `new Error().stack` shows WASM call stack with function names
- Use `EM_ASM({ console.trace(); })` to log a stack trace from C++

### `.wasm` file size analysis

If the WASM binary grows beyond GitHub's 100 MB artifact limit, identify oversized
symbols:

```bash
# Using wasm-objdump (from wabt)
wasm-objdump -h build-wasm/ra.wasm  # Section sizes

# Using twiggy (Rust tool, npm install -g twiggy)
twiggy top build-wasm/ra.wasm       # Largest functions by code size
twiggy paths build-wasm/ra.wasm     # Call graph with per-path sizes
twiggy monos build-wasm/ra.wasm     # Polymorphism overhead
```

**Common size bloat sources:**
- C++ templates instantiated many times (check with `twiggy monos`)
- `-g` debug info left in release build (use `-O2` + `--strip-debug`)
- Unused functions linked in (check with `-sWASM_SIDE_MODULE` or `-ffunction-sections --gc-sections`)
- `EM_ASM` blocks with large JS strings (each adds ~200 bytes of glue code)

### Checking thread sanity

The pthreads implementation creates one Web Worker per hardware thread. Verify:
- DevTools → Sources → Threads panel shows expected number of workers
- `Module.pthreadPoolSize` reflects the pool size at runtime
- SharedArrayBuffer is available: `typeof SharedArrayBuffer` in console

If threads don't start, check the `-sPROXY_TO_PTHREAD=1` linker flag and that
COOP/COEP headers are set (see e2e-testing skill §2.1).

### Firefox vs Chrome differences

| Feature | Chrome | Firefox |
|---------|--------|---------|
| SharedArrayBuffer without COOP/COEP | Fails (needs `--enable-features=SharedArrayBuffer`) | Fails in Nightly, works in release with flags |
| AudioContext sample rate | Usually 48000 | Usually 44100 |
| OffscreenCanvas in headless mode | Requires `--headless=new` or headed Chrome on Xvfb | Works in headless mode |
| WASM JIT cold-start | ~240s for -O2 | ~180s for -O2 |

Test on both browsers before marking a WASM change as done.

---

## Prefer EM_ASYNC_JS over blanket Asyncify

`--asyncify` adds significant code-size overhead and stack-scanning cost for every
function in the call graph. Prefer `EM_ASYNC_JS` to isolate async calls to the minimal
callchain that actually needs it:

```cpp
EM_ASYNC_JS(void, wait_for_user_gesture, (), {
  await new Promise(resolve => document.addEventListener('click', resolve, { once: true }));
});
```

Only reach for `--asyncify` when the async callchain is too deep or too spread to annotate.

**Reference:** [Emscripten — Asyncify](https://emscripten.org/docs/porting/asyncify.html)

---

## Reference

- `docs/emscripten-playbook.md` — project playbook (symptom → root cause → fix, with TIM issue numbers)
- [Emscripten pthreads](https://emscripten.org/docs/porting/pthreads.html)
- [Emscripten Filesystem API](https://emscripten.org/docs/api_reference/Filesystem-API.html)
- [Emscripten Module object](https://emscripten.org/docs/api_reference/module.html)
- [Web Audio API spec](https://webaudio.github.io/web-audio-api/)
- [SDL issue #4740 — ScriptProcessorNode + Workers](https://github.com/libsdl-org/SDL/issues/4740)
