# Roadmap

## Completed Milestones

### v0.1.0 / v0.1-beta — Toolchain Bootstrap & First Playable Frame

**Commits:** ~73 (tags: `v0.1.0`, `v0.1-beta`)

The foundation was laid: a CMake build system alongside the upstream MSVC solution, a complete Win32→Linux shim layer, and the first 94 measured passes from initial compile error to ASAN-clean gameplay.

- CMake + g++14/clang++19 toolchain with out-of-tree builds (TIM-3)
- Win32 type taxonomy: `DWORD`, `WORD`, `HANDLE`, and full primitive hierarchy shimmed as LP64-safe typedefs (TIM-6–65)
- MSVC intrinsics layer: `__int64`, `__cdecl`, `far`/`near`/`pascal`, CRT shims (TIM-28–29)
- LP64 struct audit: ~40 source-level patches fixing `long`→`int32_t` in MIX headers, shape blocks, IControl (TIM-15–17)
- Header self-containment: full include graph audit — Big Six, SIDEBAR, RADAR, AUDIO, all stand-alone (TIM-20–33)
- x86 assembly ported to portable C++ (IRANDOM, ASM stubs) (TIM-160, TIM-164)
- Audio substrate: SDL2 device/mixer, ADPCM decode, streaming (TIM-148–149)
- DirectDraw→SDL2 graphics: indexed surface, palette updates, frame presentation (TIM-141)
- First clean link at pass-32, first menu render at pass-51 (TIM-156, TIM-172)
- `Start_Scenario` fires at pass-71; 640×480 full render at pass-69 (TIM-206, TIM-250)
- ASAN-clean smoke test: 12 fps, 12 win/loss cycles, 0 crashes at pass-94 (TIM-316)

**Key artifacts:** RA native Linux binary (development testbed), ASAN/GDB/rr integration, Xvfb headless CI runner.

---

### v0.2.0 — WASM Debut: Both Games Playable in Browser

**Tag:** `v0.2.0` · **Commits:** ~86

The primary deliverable shifted to the browser. Both Red Alert and Tiberian Dawn shipped as WASM bundles playable at GitHub Pages.

| Game | Browser (WASM) | Native Linux |
|------|---------------|--------------|
| Red Alert | Fully playable — game loop, unit control, AI, VQA cinematics, audio | ASAN-clean testbed (debug only) |
| Tiberian Dawn | Fully playable — game loop, audio, real font rendering | Not yet |

- Emscripten port: pthreads (audio threading), SDL2-on-Emscripten, File System Access API preloader (TIM-376, TIM-529, TIM-555)
- VQA cinematics: skip of hi==0xFF blocks, SND2 IMA ADPCM audio, CPL0 palette fix (TIM-400, TIM-453, TIM-478)
- WASM audio pitch correct: `AudioContext.sampleRate` queried before SDL open (TIM-555)
- TD SDL2 rendering: keyboard/mouse input, 640×480 viewport, full gameplay (TIM-535, TIM-564)
- E2E regression test suite: Playwright-based smoke gates for both games (TIM-587, TIM-603)
- Release CI: `release.yml` with parallel artifact packaging (TIM-481, TIM-619)
- GitHub Pages deploy: `ra.html` + `td.html` served with cross-origin isolation headers

**Key artifacts:** RA-WASM + TD-WASM bundles, GitHub Pages landing page, nginx/nginx-based local dev server.

---

### v0.3.0 — Parity Verification & CI Regression Gates

**Tag:** `v0.3.0` · **Commits:** ~294

All three L1 missions were frame-level parity-verified against original Windows binaries running under Wine. CI regression gates run on every push. Four release artifacts are packaged per release.

| Mission | Status | Method |
|---------|--------|--------|
| RA Allied L1 | Parity-verified | Per-pixel SSIM vs Wine OG (TIM-710) |
| RA Soviet L1 | Parity-verified | Translation-invariant SSIM, Soviet button coordinate fixed (TIM-776) |
| TD GDI L1 | Parity-verified | Screenshot comparison at mission-start + game-loop frames (TIM-768) |

- `scripts/parity-compare.py`: translation-invariant SSIM with auto-registration of baseline captures (TIM-797)
- CI regression gates: RA WASM boot + menu + mission-start + audio-pitch probe (TIM-773)
- TD campaign-completion smoke: plays full GDI campaign to victory VQA (TIM-774)
- Release artifacts: RA-Linux, TD-Linux, RA-WASM, TD-WASM all packaged per release (TIM-775)
- Smoke-test design rule codified: explicit pass/fail assertions before harness, pixel-diff required for rendering gates (TIM-587)
- Side-by-side screenshot comparison output in CI (TIM-831)

**Key artifacts:** Four-binary release pipeline, parity comparison script, CI regression matrix.

---

## Current Status

**v0.3.0+** (98 commits on `master` as of May 2026)

Post-v0.3.0 work expanded beyond hardening into TD WASM completion, M2+ mission parity expansion, and CI matrix growth:

- **TD WASM playable in browser** — TD WASM port completed with SDL keyboard input, wait-strategy fix, DisplayClass bounds guards preventing crash on specific cells, and audio null-function guard. Playwright e2e smoke gates and CI regression pipeline verify every push ([TIM-858](/TIM/issues/TIM-858), [TIM-856](/TIM/issues/TIM-856), [TIM-844](/TIM/issues/TIM-844), [TIM-843](/TIM/issues/TIM-843), [TIM-846](/TIM/issues/TIM-846), [TIM-848](/TIM/issues/TIM-848))
- **M2+ mission parity expansion** — RA Allied M2, RA Soviet M2, TD GDI M2, and TD Nod M1 all have Wine OG reference captures and translation-invariant SSIM parity gates. Scenario-patching scripts and golden frame databases committed ([TIM-869](/TIM/issues/TIM-869), [TIM-857](/TIM/issues/TIM-857), [TIM-859](/TIM/issues/TIM-859), [TIM-803](/TIM/issues/TIM-803), [TIM-861](/TIM/issues/TIM-861))
- **CI matrix expansion** — Firefox added to Playwright browser matrix alongside Chromium; nightly build pipeline with expanded smoke-test coverage ([TIM-873](/TIM/issues/TIM-873), [TIM-861](/TIM/issues/TIM-861))
- **WASM build hardening** — Emscripten cache fix, binary size reduction, WASM-specific CI job ([TIM-826](/TIM/issues/TIM-826), [TIM-792](/TIM/issues/TIM-792))
- **SSIM golden comparison** integrated into WASM gameplay CI; side-by-side screenshot output ([TIM-849](/TIM/issues/TIM-849), [TIM-831](/TIM/issues/TIM-831))
- **Bug fixes** — VQA CPL0 palette handler for inter-frame colour drift ([TIM-845](/TIM/issues/TIM-845)); post-game menu map-bleed fix ([TIM-777](/TIM/issues/TIM-777)); WASM difficulty-selector seam artifact ([TIM-772](/TIM/issues/TIM-772)); audio log-spam removal, clean-exit after autostart ([TIM-838](/TIM/issues/TIM-838), [TIM-834](/TIM/issues/TIM-834), [TIM-839](/TIM/issues/TIM-839)); clang build restored on Linux ([TIM-820](/TIM/issues/TIM-820))
- **CI hardening** — ccache key fix, binary smoke test, ccache size cap, job timeouts, auto-merge workflow ([TIM-829](/TIM/issues/TIM-829), [TIM-792](/TIM/issues/TIM-792), [TIM-831](/TIM/issues/TIM-831))
- **Windows stubs audit** — all 63 `linux/win32-stubs` files inventoried, zero dead stubs confirmed ([TIM-840](/TIM/issues/TIM-840))

All CI checks green. WASM bundles for both RA and TD deploy to GitHub Pages on every push to `master`.

---

## v0.4.0 — Scope

The v0.4.0 milestone expands parity coverage, adds persistence, and hardens the e2e test suite.

### Primary objectives

| Objective | Description |
|-----------|-------------|
| **TD WASM parity** | Bring Tiberian Dawn WASM to the same frame-level parity verification standard that RA achieved in v0.3.0 — all L1 missions matched against Wine OG with translation-invariant SSIM |
| **M2+ mission expansion** | Extend mission coverage beyond L1 — verify additional campaign missions under Wine OG parity comparison, expanding the regression surface |
| **Save/load via IDBFS** | Expose in-game save/load through Emscripten's IndexedDB-backed filesystem (IDBFS). Mount the save directory, wire `SaveGame`/`LoadGame` calls, and add Playwright e2e tests for save→refresh→load round-trip |
| **Playwright e2e hardening** | Hardening the e2e test suite: increase timeout resilience, add per-test screenshot archives on failure, cover save/load and additional mission scenarios |

### Secondary objectives

- **CD audio parity audit** — verify CD audio playback match between WASM and Wine OG for mission-start and in-game tracks
- **WASM preloader polish** — improve loading UX (progress indicator, error handling for missing game data)
- **CI matrix expansion** — add Firefox to browser regression matrix alongside Chrome

### Out of scope for v0.4.0

- Native Linux performance polish
- Multiplayer networking
- Additional platform support (macOS, mobile)
- Map editor port

---

## Post-v0.4.0

### v0.5.0 — Native Perf & Platform Polish

- **Native Linux performance** — profile and optimize the SDL2 render path for 60 fps gameplay. Current native build runs at ~12 fps (ASAN testbed); target production-grade frame rates.
- **Hardware-accelerated rendering** — evaluate SDL2 hardware-accelerated backends (OpenGL, Vulkan via SDL_gpu or custom) for native build
- **Audio latency reduction** — reduce SDL2 audio buffer underruns and latency
- **Full mission parity** — complete parity verification for all campaign missions in both games (not just L1)

### Later

- **Multiplayer networking** — LAN and internet multiplayer for both games (IPX/UDP shim over enet or similar)
- **Skirmish / AI improvements** — configurable AI difficulty, random map generation
- **Mod support** — documented modding interface, asset override system
- **Map editor** — port `CnCTDRAMapEditor` to Linux
- **Additional platforms** — macOS, mobile (iOS/Android), Raspberry Pi

---

## Version Map

| Version | Tag | Key Milestone |
|---------|-----|---------------|
| v0.1.0 / v0.1-beta | `v0.1.0`, `v0.1-beta` | First link, first menu render, first in-game frame, ASAN-clean smoke |
| v0.2.0 | `v0.2.0` | RA + TD fully playable in browser (WASM) |
| v0.3.0 | `v0.3.0` | Frame-level parity verification, CI regression gates, 4-binary release pipeline |
| v0.4.0 | — | TD WASM parity, M2+ expansion, save/load via IDBFS, e2e hardening |
| v0.5.0+ | — | Native perf, multiplayer, map editor, additional platforms |

---

## Related Documents

- [ARCH.md](ARCH.md) — Linux port architecture, platform abstraction layer, build system design
- [README.md](README.md) — Release notes, build instructions, method
- [RELEASE.md](RELEASE.md) — Release process checklist
- [CONTRIBUTING.md](CONTRIBUTING.md) — Contributing guidelines, smoke-test design rule
- [docs/](docs/) — Design documents, porting checklists, experiment logs
