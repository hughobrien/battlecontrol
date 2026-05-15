# Emscripten Port Playbook

**Read this before starting any C++ → WASM port.**
Distilled from TIM-399, TIM-489, TIM-593, TIM-602, TIM-604.
Each entry: symptom → root cause → fix → reference.

---

## 1. PROXY_TO_PTHREAD

### EM_ASM vs MAIN_THREAD_EM_ASM

**Symptom:** JS code in `EM_ASM` silently fails — `Module['_key']` is undefined,
browser APIs return null, or DOM reads produce garbage.

**Root cause:** Under `-sPROXY_TO_PTHREAD` the game loop runs in a Worker.
`EM_ASM` executes in that Worker's `Module` context. The browser main thread,
the DOM, Web Audio, and any JS state set before `onRuntimeInitialized` are
invisible from the Worker.

**Fix:** Any call that reads `Module['_key']`, touches the DOM, or uses Web Audio
must use `MAIN_THREAD_EM_ASM` or `MAIN_THREAD_EM_ASM_INT`. Audit every
`EM_ASM` block in files ported from native; replace those that cross the
thread boundary. *(Landed in TIM-620.)*

**Reference:** [Emscripten pthreads doc — calling JS from a pthread](https://emscripten.org/docs/porting/pthreads.html#accessing-the-dom-from-pthreads)

---

### SDL audio incompatibility

**Symptom:** SDL2 audio device opens, but sound is garbled, stutters, or causes a
null-function trap in the browser. Audio is fine on native.

**Root cause:** SDL2's audio backend uses a `ScriptProcessorNode`, which cannot
be created or driven from a Worker thread under PROXY_TO_PTHREAD. The SDL
audio thread and the proxy Worker fight over JS context ownership.

**Fix:** Do **not** call `SDL_OpenAudioDevice` on the WASM target. Instead,
bypass SDL audio entirely and schedule audio via the Web Audio path
(see §4 below). Use a sentinel value (`vqa_audio_dev=1`) to distinguish the
WASM audio device handle from real SDL handles. *(Landed in TIM-604.)*

**Reference:** [SDL issue #4740 — ScriptProcessorNode not usable from Workers](https://github.com/libsdl-org/SDL/issues/4740)

---

### SDL_RENDERER_SOFTWARE

**Symptom:** Renderer fails silently; `GLctx` is `undefined` in browser console;
black screen even when the game loop runs.

**Root cause:** Hardware-accelerated rendering requires a valid `WebGLRenderingContext`,
which cannot be acquired from a Worker thread. The SDL renderer falls back
to nothing, leaving a black window.

**Fix:** Always pass `SDL_RENDERER_SOFTWARE` in WASM renderer init:

```cpp
#ifdef __EMSCRIPTEN__
    SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
#else
    SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
#endif
```

**Reference:** [Emscripten SDL2 doc — renderer notes](https://emscripten.org/docs/porting/multimedia_and_graphics/OpenGL-support.html)

---

## 2. Filesystem

**Symptom:** `fopen`/`stat` succeed on native but silently fail in the browser;
no error is logged; file contents are never read.

**Root cause:** IDBFS (IndexedDB-backed persistent storage) is stripped when
`FORCE_FILESYSTEM=1` is absent. Without it, the Emscripten VFS is a stub and
filesystem calls are no-ops in optimised builds.

**Fix:** Add to your Emscripten link flags:

```cmake
target_link_options(my_target PRIVATE -sFORCE_FILESYSTEM=1)
```

Also confirm that any `--preload-file` or `--embed-file` paths match the
runtime VFS tree exactly — path mismatches fail silently at runtime.

**Reference:** [Emscripten filesystem overview](https://emscripten.org/docs/api_reference/Filesystem-API.html#persistent-data)

---

## 3. Environment variable injection

**Symptom:** `getenv("MY_VAR")` returns `NULL` in the browser even though the
variable is exported in the shell that built the WASM module.

**Root cause:** The browser has no shell environment. `getenv` in the Emscripten
runtime reads from `Module.ENV`, not from the process environment.

**Fix:** Inject env vars in the JS harness **before** `onRuntimeInitialized`:

```js
var Module = {
  ENV: {
    MY_VAR: "value",
    RA_AUTOSTART: "1",
  },
  onRuntimeInitialized: function() { /* … */ },
};
```

Do not rely on `putenv` from C++ for variables that must be set at startup;
by the time `main()` runs, the value must already be in `Module.ENV`.

**Alternative — flag files via IDBFS/VFS:** For opt-in features that don't
require a JS harness change, check for a sentinel file with `RawFileClass`:

```cpp
bool enabled = (std::getenv("MY_VAR") != nullptr);
#ifdef __EMSCRIPTEN__
if (!enabled) enabled = RawFileClass("MY_VAR.FLAG").Is_Available();
#endif
```

Create the file via the browser DevTools console (`FS.writeFile('/MY_VAR.FLAG','1')`).
Used by RA_AUTOSTART.FLAG (TIM-506) and VQA_SCANLINES.FLAG (TIM-619).

**Reference:** [Emscripten environment variables](https://emscripten.org/docs/porting/connecting_cpp_and_javascript/Interacting-with-code.html#environment-variables)

---

## 4. Audio

### SDL audio bypass + AudioBufferSourceNode

**Symptom:** (see SDL audio incompatibility in §1). No native-equivalent audio
path survives PROXY_TO_PTHREAD.

**Fix:** Replace the SDL audio callback with Web Audio scheduling:

1. In the WASM build, skip `SDL_OpenAudioDevice`; use a sentinel handle
   (`vqa_audio_dev=1`) so callers can distinguish WASM vs native.
2. Push decoded PCM frames through a queue (e.g. `vqa_audio_queue_s16`).
3. In `MAIN_THREAD_EM_ASM`, create an `AudioBufferSourceNode` per chunk,
   fill it from the queue, schedule it with `source.start(nextTime)`, and
   advance `nextTime += buffer.duration`. This gives glitch-free scheduling
   without requiring a Worker-accessible audio thread.

*(Landed in TIM-604 for RA VQA; TIM-555 established the same pattern for TD.)*

---

### Sample-rate mismatch

**Symptom:** Audio plays at the wrong pitch — slightly too high or too low.
Pitch error is proportional to `device_rate / context_rate`.

**Root cause:** `AudioContext.sampleRate` is browser-determined (typically 44100
or 48000 Hz) and may differ from the SDL audio device rate you requested.
SDL silently uses the requested rate; the browser silently plays at its own
rate, causing a pitch shift.

**Fix:** Query `AudioContext.sampleRate` before opening any audio device and
configure SDL (or your queue) to match:

```js
var audioCtx = new AudioContext();
Module.ENV.AUDIO_SAMPLE_RATE = String(audioCtx.sampleRate);
```

Then in C++:

```cpp
int sample_rate = atoi(getenv("AUDIO_SAMPLE_RATE") ?: "44100");
```

Alternatively, stride-resample at queue boundaries: if the source rate and
device rate differ, resample each chunk before enqueueing.
*(TIM-555 / TIM-602 pattern.)*

**Reference:** [Web Audio spec — AudioContext.sampleRate](https://webaudio.github.io/web-audio-api/#dom-baseaudiocontext-samplerate)

---

### Intermittent audio trap verification

**Symptom:** CI passes on a single run, but the null-function trap recurs in
subsequent runs at ~50% probability.

**Root cause:** WASM audio timing races are non-deterministic. A single green
run provides almost no statistical confidence.

**Fix:** Require **5/5 cold-cache passes** before marking WASM audio as
verified. In CI, clear the browser profile between runs. One pass is not
sufficient evidence. *(Rule established from TIM-600 incident.)*

---

## 5. Build and link

### Linker order (ld.bfd)

**Symptom:** Link fails with undefined symbol errors for functions that are
clearly present in `-lSDL2` (or another system library).

**Root cause:** `ld.bfd` resolves symbols left-to-right. If `-lSDL2` appears
before the object files that reference it, the undefined symbols are not yet
known when `ld.bfd` scans the library, so they are discarded.

**Fix:** Always place `-lSDL2` (and other system libraries) **after** all object
files in the link command:

```cmake
target_link_libraries(my_target PRIVATE my_objects SDL2)
# NOT: target_link_libraries(my_target PRIVATE SDL2 my_objects)
```

**Reference:** [GNU ld manual — archive ordering](https://sourceware.org/binutils/docs/ld/Archives.html)

---

### -O2 JIT cold-start in CI

**Symptom:** CI times out or the WASM-ready gate is never reached. Locally it
starts in seconds.

**Root cause:** Optimised (`-O2`) WASM can take 240 s+ to JIT-compile in a
headless browser in CI. `waitForFunction` with a short timeout fires before
the JIT is done.

**Fix:** Gate on `onRuntimeInitialized`, not on `waitForFunction`:

```js
var Module = {
  onRuntimeInitialized: function() {
    // signal to the test harness that WASM is ready
    window.__wasmReady = true;
  },
};
```

In the Playwright/Puppeteer test, wait for the `window.__wasmReady` flag with
a timeout of ≥300 s. Do **not** revert to `waitForFunction` with a short
timeout as a "fix" for a flaky gate. *(Established in TIM-597.)*

**Reference:** [Emscripten Module object docs](https://emscripten.org/docs/api_reference/module.html#Module.onRuntimeInitialized)

---

## 6. Verification bar

Before marking any WASM porting work done, all of the following must be true:

| Gate | Minimum proof |
|---|---|
| **Build** | `emcc` produces `.wasm` + `.js` without warnings about undefined symbols |
| **Loads in browser** | `onRuntimeInitialized` fires; no `Uncaught` errors in DevTools console |
| **File I/O** | Required asset files are accessible via VFS (preload log or runtime probe) |
| **Audio (if applicable)** | 5/5 cold-cache CI runs pass without null-function trap; pitch confirmed correct |
| **Video (if applicable)** | Visual screenshot inspection of rendered frames — quantitative fill-% alone is insufficient (TIM-587 lesson: cyan scatter passed metrics but was visually broken) |
| **Exit** | Process exits cleanly (SDL_QUIT or expected shutdown); no runaway Worker |

**Never mark WASM audio verified on a single CI run.** Never rely solely on
quantitative metrics for visual output. Screenshot inspection is required.

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

---

## Sharing a VQA player across C++ targets (TIM-682, 2026-05-14)

**Symptom:** A second C++ game target (e.g. TiberiaDawn) has a no-op `Play_Movie_GlyphX`
because `vqa_player.cpp` was never added to its build.

**Root cause:** The glob that picks up `vqa_player.cpp` for Target A doesn't apply to
Target B; each target has its own `*_STUB_SOURCES` list in CMakeLists.txt.

**Fix:**

1. Add `vqa_player.cpp` explicitly to the new target's `TD_STUB_SOURCES`.
2. `vqa_player.cpp` calls four symbols that are only defined for the RA target in
   `REDALERT/WIN32LIB/DDRAW.CPP`: `SDL_Has_Primary_Surface`, `SDL_Get_Primary_Pixels`,
   `SDL_Get_Primary_Pitch`, `Set_DD_Palette_8bit`. Provide equivalents in the new
   target's stub file that delegate to its own pixel-buffer state (e.g. `TD_SeenPixels`,
   `TD_SDL_Palette`). Declare them in the target's `WIN32LIB/DDRAW.H` behind
   `#ifndef _MSC_VER` guards.
3. `vqa_player.cpp` also references `SDL_Audio_*` functions from `sdl_audio.h`
   (implemented in `REDALERT/AUDIO.CPP`). If the new target has its own audio
   substrate, add extern "C" no-op stubs: `Is_Open=false` makes vqa_player skip the
   "audio steal" and open its own device cleanly.
4. Add a `TD_AUTOSTART` (or equivalent) skip guard to `Play_Movie_Linux` alongside the
   existing `RA_AUTOSTART` guard so CI e2e tests that expect immediate scenario start
   are not blocked by VQA playback.

**Blocksize note:** All TD VQA files use `blockH=2` (same as RA PROLOG.VQA), so the
existing solid-marker handling (TIM-613) is already correct. Always verify `blockH` from
a VQA header parse before porting a new title.

**Reference:** TIM-682 commit 3d48765; TIM-613 (blockH-dependent solid-marker).

---

## PROXY_TO_PTHREAD event proxy queue — mouse clicks silently dropped (TIM-694, 2026-05-14)

**Symptom:** Real mouse clicks on the RA WASM menu do nothing. `SDL_PeepEvents` for
`SDL_MOUSEBUTTONDOWN` always returns 0 even though Playwright / browser DevTools confirm
the `mousedown` DOM event fires. No `[MENU] input=` log appears in `#output`.

**Root cause:** Under `-sPROXY_TO_PTHREAD`, `SDL_InitSubSystem(SDL_INIT_VIDEO)` is called
from the worker (game) thread. Emscripten's SDL2 backend therefore registers its DOM
event callbacks (mousedown, mouseup, mousemove) with
`EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD`, meaning the SDL callback runs on the worker,
not the main thread. When a DOM event fires on the main thread, Emscripten queues a proxy
call for the worker. That proxy call runs when the worker next calls
`emscripten_current_thread_process_queued_calls()` — which normally happens inside blocking
Emscripten internals (e.g. `emscripten_sleep`, futex waits). With `SDL_RENDERER_SOFTWARE`
there is no vsync block: `SDL_RenderPresent` is fire-and-forget. The worker therefore
never enters a blocking call, the proxy queue never drains, and `SDL_SendMouseButton` is
never called — so `SDL_PeepEvents` sees an empty queue.

Note: `SDL_PumpEvents()` is already a **no-op** in Emscripten's SDL2 backend, so the
traditional "call `SDL_PumpEvents` before `SDL_PeepEvents`" pattern gives no relief here.

**Fix:** Call `emscripten_current_thread_process_queued_calls()` explicitly in
`SDL_Process_Input_Events()` before `SDL_PeepEvents`, guarded on
`__EMSCRIPTEN__ && __EMSCRIPTEN_PTHREADS__`. This flushes all pending proxy calls (the
DOM event callbacks that queued `SDL_SendMouseButton`) so the event queue is populated
when `SDL_PeepEvents` reads it.

```cpp
// REDALERT/KEY.CPP — SDL_Process_Input_Events()
#if defined(__EMSCRIPTEN__) && defined(__EMSCRIPTEN_PTHREADS__)
    emscripten_current_thread_process_queued_calls();
#endif
    SDL_PumpEvents();   // no-op on Emscripten, kept for native builds
```

Add `#include <emscripten/threading.h>` in the `#ifndef _MSC_VER` block.

**Verification gate:** After the fix, `[MENU] input=0x` appears in `#output` (stderr via
`printErr`) within ~30 s of a real Playwright click. This log fires from `MENUS.CPP` when
`commands->Input()` returns non-zero, confirming the event traversed the full
SDL → `_Kbd` → `GadgetClass::Input()` pipeline.

**Related:** TIM-684 (native Linux pump starvation fix), TIM-664 (WWKEY_VK_BIT mouse bug),
TIM-686 (T5 regression spec). See also `lens #1` (PROXY_TO_PTHREAD module context) and
`lens #4` (SDL_RENDERER_SOFTWARE).

**Reference:** `emscripten_current_thread_process_queued_calls` in
`<emscripten/threading.h>`; Emscripten wiki "Proxying" section.

---

*Last updated: 2026-05-14. Maintainer: EmscriptenExpert agent.*
*Source issues: TIM-399, TIM-489, TIM-555, TIM-593, TIM-597, TIM-600, TIM-602, TIM-604, TIM-613, TIM-619, TIM-620, TIM-682, TIM-694.*
