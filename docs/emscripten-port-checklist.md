# Emscripten Port Checklist

Quick pre-port reference. One-line rule + ticket for full context.
See [emscripten-playbook.md](emscripten-playbook.md) for symptom → root-cause → fix depth.

---

## 1. Audio

- [ ] **Query `AudioContext.sampleRate` before opening any audio device** — SDL uses
  your requested rate; the browser plays at its own rate; the pitch shifts by the ratio.
  Inject `AUDIO_SAMPLE_RATE` via `Module.ENV` before `onRuntimeInitialized`.
  ([TIM-555], [TIM-602])

- [ ] **Use `AudioBufferSourceNode` scheduling, not `ScriptProcessorNode`** —
  `ScriptProcessorNode` cannot be driven from a Worker under `PROXY_TO_PTHREAD`; it
  causes a null-function trap at ~50% probability. Schedule each PCM chunk with
  `source.start(nextTime)` from `MAIN_THREAD_EM_ASM`. ([TIM-604])

- [ ] **Stride-resample at queue boundaries when source rate ≠ device rate** — do the
  resample in C++ at the point where samples are pushed to the queue, not in JS.
  ([TIM-602])

- [ ] **Use a sentinel (e.g. `vqa_audio_dev = 1`) for the WASM audio device handle** —
  skip `SDL_OpenAudioDevice` on WASM entirely; callers test the sentinel rather than a
  real handle. ([TIM-604])

- [ ] **Require 5/5 cold-cache CI passes before marking WASM audio verified** —
  a single green run conceals the ~50% null-function trap; each run must start with a
  cleared browser profile. ([TIM-600])

---

## 2. Threading (PROXY_TO_PTHREAD)

- [ ] **Audit every `EM_ASM` block; replace with `MAIN_THREAD_EM_ASM` where needed** —
  under `PROXY_TO_PTHREAD` the game loop runs in a Worker; plain `EM_ASM` runs in that
  Worker's `Module` context and cannot see the DOM, Web Audio, or main-thread JS state.
  ([TIM-620])

- [ ] **Any code reading `Module['_key']` or browser APIs must use `MAIN_THREAD_EM_ASM`**
  — the Worker's `Module` is per-thread; symbol exports set before `onRuntimeInitialized`
  on the main thread are invisible in the Worker. ([TIM-620])

- [ ] **Use `SDL_RENDERER_SOFTWARE` on WASM** — `WebGLRenderingContext` cannot be
  acquired from a Worker thread; hardware rendering falls back silently to a black screen.
  ([TIM-593])

---

## 3. CI / JIT

- [ ] **Gate on `onRuntimeInitialized`, not on `waitForFunction` with a short timeout** —
  `-O2` WASM takes >240 s to JIT-compile in CI headless browsers; short-timeout gates
  fire before the engine is ready. ([TIM-597])

- [ ] **Do not revert the `onRuntimeInitialized` gate when CI times out** — the fix is
  to raise the timeout, not to switch back to `waitForFunction`. ([TIM-597])

- [ ] **Add a size guard (~1 MB minimum) to the smoke test** — catches a build that
  silently drops the `.wasm` payload or produces a stub. ([TIM-597])

---

## 4. LP64 / Integer-Width Audit

- [ ] **Run the LP64 static audit (see [TIM-640]) before attempting native boot** —
  Win32 source assumes LLP64; `long` and `DWORD` have different widths on Linux LP64;
  silent data-corruption bugs outnumber link errors.

- [ ] **Check `bsearch` / `qsort` comparator casts** — comparators typed as
  `int (*)(const void*, const void*)` that cast internally to `long*` truncate on LP64.
  ([TIM-447])

- [ ] **Check `CompHeaderType` and similar packed structs for implicit padding** —
  `#pragma pack` sections that mix `int` and `long` members gain hidden bytes on LP64;
  use `int32_t`/`uint32_t` in serialised structs. ([TIM-202])

- [ ] **Check `IControl_Type` and other enum-backed fields used in size comparisons** —
  enums are `int` on MSVC but may be wider under g++ with `-fshort-enums` absent.
  ([TIM-447])

---

## 5. Codec Testing

- [ ] **Wire up the pixel-diff harness ([TIM-639]) before merging any codec PR** —
  quantitative fill-% metrics passed while frames showed block-aligned cyan scatter;
  visual screenshot inspection is mandatory, not optional. ([TIM-587])

- [ ] **VQA solid-marker is blockH-dependent: 0xFF for blockH=4, 0x0F for blockH=2** —
  `ENGLISH.VQA` uses blockH=4 (0xFF); `PROLOG` and all `MAIN.MIX` movies use
  blockH=2 (0x0F); pre-fill both codebook ranges or the wrong movie set goes black.
  ([TIM-613])

- [ ] **Inspect VQA frames visually, not just fill-%** — a frame showing only 23% fill
  can still be correct arctic terrain; a frame showing 100% fill can still be entirely
  wrong if the pixels are the wrong color. ([TIM-587], [TIM-613])

---

## 6. Input / Menu Navigation

- [ ] **Use synthetic event injection (LCLICK + KN_RETURN) for automated menu testing**
  — `RA_AUTOSTART` bypasses the menu entirely and hides input-path regressions; inject
  synthetic clicks to exercise the real menu → scenario navigation path. ([TIM-206])

- [ ] **Do not rely on `RA_AUTOSTART` as the only smoke-run entry point** — it skips
  menu rendering, palette init, and input dispatch; regressions in those paths are
  invisible. ([TIM-206])

---

## 7. VQA Verification

- [ ] **Require visual inspection of rendered VQA frames, not just metric gates** —
  pixel scatter that is visually broken can still pass fill-% and frame-count checks.
  ([TIM-587])

- [ ] **Require 5/5 cold-cache passes for WASM audio on VQA playback** — see §1;
  applies equally to standalone VQA verification as to general WASM audio. ([TIM-600])

- [ ] **Confirm blockH for each VQA file before writing decoder logic** — wrong
  solid-marker value produces black squares on half the movie set with no error output.
  ([TIM-613])

---

## Quick Checklist Index

| Topic | Issues |
|---|---|
| Audio sample-rate mismatch | [TIM-555], [TIM-602] |
| SDL ScriptProcessorNode → AudioBufferSourceNode | [TIM-604] |
| WASM audio 5× cold-cache verification | [TIM-600] |
| PROXY_TO_PTHREAD / EM_ASM scoping | [TIM-620] |
| onRuntimeInitialized CI gate | [TIM-597] |
| LP64 static audit | [TIM-640], [TIM-447], [TIM-202] |
| Pixel-diff codec harness | [TIM-639], [TIM-587] |
| VQA blockH solid-marker | [TIM-613] |
| Synthetic input injection | [TIM-206] |

[TIM-555]: /TIM/issues/TIM-555
[TIM-587]: /TIM/issues/TIM-587
[TIM-593]: /TIM/issues/TIM-593
[TIM-597]: /TIM/issues/TIM-597
[TIM-600]: /TIM/issues/TIM-600
[TIM-602]: /TIM/issues/TIM-602
[TIM-604]: /TIM/issues/TIM-604
[TIM-613]: /TIM/issues/TIM-613
[TIM-620]: /TIM/issues/TIM-620
[TIM-206]: /TIM/issues/TIM-206
[TIM-202]: /TIM/issues/TIM-202
[TIM-447]: /TIM/issues/TIM-447
[TIM-639]: /TIM/issues/TIM-639
[TIM-640]: /TIM/issues/TIM-640

---

*Last updated: 2026-05-14. Maintainer: FoundingEngineer.*
*Companion document: [emscripten-playbook.md](emscripten-playbook.md) (symptom → root-cause → fix depth for each topic).*
