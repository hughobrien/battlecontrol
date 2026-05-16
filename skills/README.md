# BattleControl Project Skills

Reusable agent skills for the C&C Red Alert + Tiberian Dawn port to modern Linux
and browser (WASM). Each skill captures a domain workflow as step-by-step
instructions with symptom→diagnosis→fix tables and a verification bar.

## Available Skills

| Skill | Directory | Domain | Agent |
|-------|-----------|--------|-------|
| **emscripten** | [`skills/emscripten/`](emscripten/SKILL.md) | WASM/Emscripten porting, debugging, CMake flags | [EmscriptenExpert](/TIM/agents/emscriptenexpert) |
| **native-build** | [`skills/native-build/`](native-build/SKILL.md) | Native Linux GCC/Clang build, LP64 audit, SDL2 shims | [FoundingEngineer](/TIM/agents/foundingengineer), [StaffEngineer](/TIM/agents/staffengineer) |
| **wine-testing** | [`skills/wine-testing/`](wine-testing/SKILL.md) | Wine baseline comparison, headless screenshot capture | [WineExpert](/TIM/agents/wineexpert) |
| **vqa-codec** | [`skills/vqa-codec/`](vqa-codec/SKILL.md) | VQA video codec testing, pixel-diff, synthetic VQA | [VideoEngineer](/TIM/agents/videoengineer) |
| **e2e-testing** | [`skills/e2e-testing/`](e2e-testing/SKILL.md) | Playwright e2e tests, WASM readiness gates, audio pitch probes | [PlaywrightEngineer](/TIM/agents/playwrightengineer) |
| **ci-cd** | [`skills/ci-cd/`](ci-cd/SKILL.md) | CI/CD pipeline, release automation, regression tiers | [CICDExpert](/TIM/agents/cicdexpert) |
| **parity-comparison** | [`skills/parity-comparison/`](parity-comparison/SKILL.md) | WASM/Linux vs Wine/RA95 visual parity validation, SSIM comparison | [WineExpert](/TIM/agents/wineexpert), [PlaywrightEngineer](/TIM/agents/playwrightengineer) |

## Skill Format

Every skill follows the same structure:

- **YAML frontmatter** — name, description (triggers), version
- **Phase 0** — Quick check or prerequisite verification (runnable as smoke test)
- **Phase 1** — Symptom classification table (symptom → lens → section)
- **§2 sections** — Root cause + fix for each classified symptom
- **§3+ sections** — Standard commands, reference, verification bar

Skills are self-contained: a single agent can follow one start to finish without
external context.

## Conventions

- **Symptom-first.** The classification table is the entry point — agents match
  what they see to what's documented.
- **Verification bar.** Every skill ends with a table of gates and minimum proof.
  No skill is "done" until the smoke test passes.
- **Reference section.** Links to project docs, source files, and external docs
  needed to go deeper.
- **Code examples.** Every §2 fix includes a concrete code snippet.
- **Ticket references.** [TIM-587](/TIM/issues/TIM-587) style links connect
  patterns back to the bug that motivated them.

## Adding a New Skill

1. Create `skills/<topic>/SKILL.md` following the format above.
2. Include a smoke test that can be run to verify the skill works:
   ```bash
   # Example: vqa codec smoke test
   python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2
   ```
3. Add the skill to this index with domain and responsible agent.
4. Tag [SkillWritingExpert](/TIM/agents/skillwritingexpert) for review.

## Deprecation

When a workflow changes:
1. If the change is minor, update the skill file and bump the version.
2. If the workflow is fundamentally different, create a new skill and move the
   old one to `skills/_archived/` with a note in its frontmatter pointing to the
   replacement.

## Skill Maintenance

Skills are owned by their corresponding domain agents (see table above).
[SkillWritingExpert](/TIM/agents/skillwritingexpert) owns the index and format
conventions.

## Companion Scripts

Skills reference automation scripts in `scripts/` rather than inlining repetitive
multi-step command sequences. Each script handles setup, teardown, and error recovery.

| Script | Purpose | Referenced by |
|--------|---------|---------------|
| `scripts/skill-dev-check.sh` | One-command toolchain prerequisite gate | native-build |
| `scripts/skill-wine-check.sh` | One-command Wine prerequisite gate | wine-testing |
| `scripts/skill-xvfb-ensure.sh` | Idempotent Xvfb start (kills stale, wait loop, EXIT trap) | native-build, e2e-testing, parity-comparison, ci-cd |
| `scripts/skill-wasm-serve.sh` | Start serve-coop.py with auto-cleanup EXIT trap | e2e-testing, ci-cd |
| `scripts/skill-run-e2e.sh` | Full E2E: Xvfb + server + Playwright test + cleanup | e2e-testing, ci-cd |
| `scripts/skill-native-build.sh` | Single-cmd cmake configure + build RA + build TD | native-build, ci-cd |
| `scripts/skill-vqa-check.sh` | VQA CI gate: regenerate → diff → pixel-diff | ci-cd, vqa-codec |
| `scripts/skill-ci-wasm-smoke.sh` | Full WASM CI: emcmake, build, validate, T1+T2 smoke | ci-cd |

### Script design rules

- **Prefixed `skill-`** to distinguish from existing project scripts
- **Idempotent** — safe to run multiple times (reuses running services, kills stale ones)
- **Self-cleaning** — registers EXIT traps so services are killed on shell exit
- **One command per workflow** — collapses multi-step manual sequences into a single invocation
- **Exits 0 on success** — works as a CI gate or a skill verification step
