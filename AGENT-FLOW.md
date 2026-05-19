# Agent Flow — Recommendations for Agentic Development

_battlecontrol — 2026-05-16_

This file is an assessment of the current developer experience for AI coding
agents working in this repo. It covers what works, what creates friction, and
concrete improvements ordered by impact.

---

## What Works Well

### 1. Skills are high-quality and follow a consistent format
Every skill has a YAML frontmatter with trigger symptoms, a Phase 0 smoke
check, a Phase 1 symptom-classification table, root-cause sections with code
examples, and a verification bar. An agent landing on a symptom can jump
straight to the fix without re-deriving context.

### 2. Companion scripts are idempotent and self-cleaning
Scripts like `xvfb-ensure.sh` and `serve-wasm.sh` register `EXIT` traps, kill stale services, and wait for
readiness. They collapse multi-step manual sequences into single invocations
and work correctly on repeat runs. This is the right design pattern.

### 3. `parity-compare.py` and `lint-lp64.py` are production-quality tools
Both have clear exit codes (0/1/2), structured output, and are CI-gate-ready.
They're well-documented with usage examples and do one thing well.

### 4. Reference docs are thorough and domain-specific
`ARCH.md`, `emscripten-playbook.md`, `lp64-audit.md`, and
`smoke-test-design-rule.md` each cover their domain deeply and correctly.
The playbook in particular is a strong symptom->root-cause->fix reference.

### 5. Branch-and-PR workflow solves concurrent-agent collisions
Per-feature branches with automerge prevent filesystem conflicts when multiple
agents run concurrently. This is a solved problem.

---

## What Creates Friction

### 1. ~180 of ~200 scripts are historical build logs, not automation
The `scripts/` directory is dominated by pass-tracking scripts
(`first-compile-pass*.sh`, `first-run-pass*.sh`, `first-link-pass*.sh`)
that were produced as measurement checkpoints during the initial port.

**Impact for agents:**
When an agent opens a file listing of `scripts/`, it sees a flat 200-entry
directory. Finding the ~20 reusable scripts requires manual scanning or
guessing by prefix. This wastes context and increases the chance an agent
picks the wrong script.

### 2. No entry point for a fresh agent
An agent that has never seen this repo needs to know:

- What to run first to verify its toolchain
- What the canonical build command is
- How to run smoke tests
- What the change cycle looks like

Currently this information exists but is scattered across `BUILD-LINUX.md`,
`CLAUDE.md`, `skills/README.md`, and `README.md`. None of these documents
are written for the agent's workflow — they're written for human engineers.

### 3. Skills reference scripts that don't exist (or may not)
The skills README table lists companion scripts including:

- `scripts/wine-check.sh` — referenced by `wine-testing` Phase 0, but
  could not be found in `scripts/`
- `scripts/td/setup-run-td.sh` — referenced by `native-build` §2.6, not present
- `scripts/xvfb-ensure.sh` — present, good
- `scripts/serve-wasm.sh` — present, good

### 4. CLAUDE.md assumes Claude/Paperclip agent infrastructure
`CLAUDE.md` describes agent roles (`FoundingEngineer`, `StaffEngineer`,
`WineExpert`) that are specific to the Claude/Paperclip agent platform. When
a DeepSeek-based agent (or any non-Paperclip agent) reads this file, these
instructions are either irrelevant or confusing.

### 5. ✓ Resolved — four-tier workflow provides single-command CI
CI is now a single command: `nix run .#test -- --all`. Four tiers
(`lint` → `build` → `smoke` → `test`) each exposed as a nix app, with
diff-gating so only changed targets are tested. GitHub CI runs the same
command. See the four-tier workflow table in R2 below.

### 6. History scripts are mixed with reusable scripts, creating ambiguity
Some historical scripts are genuinely useful for agents (e.g.,
`wine-ra-setup.sh` for first-time Wine configuration). Others are one-time
measurements that would produce incorrect results if re-run (e.g., a
`first-compile-pass16.sh` trying to verify the pass-16 error count against a
codebase that has since changed). An agent cannot distinguish these without
reading every file.

### 7. Skills are deep-linked to a ticketing system that may not be accessible
Many skill entries reference TIM-{number} tickets. If the agent does not have
access to the TIM project (or the tickets are closed/archived), the reference
is a dead end. The context in the skill body should be self-sufficient.

### 8. No verification gate for skills themselves
The skills README describes a format and a smoke test, but there's no
automated check that ensures all skill companion scripts exist and exit
correctly. A `skill-verify.sh` that walks every `SKILL.md`, extracts
referenced scripts, and validates they exist and exit 0 would catch drift.

---

## Recommendations

### High Impact (implement first)

#### R2. Four-tier workflow — single-command local CI ✓ (implemented)

Local CI is now a four-tier hierarchy, each exposed as a nix app:

| Tier | Command | What it does | Time |
|------|---------|-------------|------|
| L1 | `nix run .#lint` | All linters + /opt audit | seconds |
| L2 | `nix run .#build [--all]` | L1 + diff-gated compile | <1 min |
| L3 | `nix run .#smoke [--all]` | L2 + CI-tier boot tests | <2 min |
| L4 | `nix run .#test [--all]` | L2 + full regression | minutes |

Each tier calls the one before it. `--all` forces every gate (default: diff
against origin/master). `--base REF` diffs against a different ref.

Backed by `scripts/lint.sh`, `scripts/build.sh`, `scripts/smoke.sh`, `scripts/test.sh`,
with `scripts/_gating.sh` providing diff analysis and `scripts/test-runner.sh`
as the unified backend for all `{game}-{platform}-test` apps.

A single command runs the entire verification chain, with per-gate reporting
and diff-aware skip semantics. GitHub CI calls `nix run .#test -- --all`.

#### R3. Add `AGENTS.md` as the canonical agent entry point

Create `AGENTS.md` at the repo root. This is the file DeepSeek-compatible
agents read first. It should contain:

1. **Quickstart** (3 commands to verify readiness)
2. **Build commands** (one-liners for native and WASM)
3. **Test commands** (smoke, e2e, parity)
4. **Change cycle** (edit -> build -> test -> commit -> PR)
5. **Skill index** (table mapping domain to skill file)
6. **Critical invariants** (things agents must never break)

The `CLAUDE.md` file should remain for Paperclip-specific protocol, but
`AGENTS.md` becomes the primary agent-facing doc.

#### R4. Consolidate skill references into each skill file

Each skill should inline or clearly reference only scripts that actually exist.
Remove references to `wine-check.sh` and `setup-run-td.sh` if those
scripts aren't committed. Instead, inline the prerequisite check commands
directly into the skill body.

When a skill references a companion script, it should use the canonical path
from the repo root (e.g., `bash scripts/xvfb-ensure.sh :99 640x480x24`).

---

### Medium Impact

#### R5. Add a `scripts/skill-verify.sh` validation gate

A script that:
1. Walks every `skills/*/SKILL.md`
2. Extracts `bash scripts/...` / `source scripts/...` references
3. Checks that each referenced script exists
4. Reports missing scripts as errors

This prevents skill/script drift and can be run as a pre-commit hook or in CI.

#### R6. Add a "depends on" field to skill frontmatter

```yaml
---
name: e2e-testing
version: 0.1.0
depends_on:
  - skill: emscripten          # needs WASM build
  - script: xvfb-ensure.sh
  - script: serve-wasm.sh
---
```

This lets an agent know what prerequisites to satisfy before running a skill.
The `skill-verify.sh` gate from R5 can cross-reference these.

#### R7. Standardize script exit-code semantics across all scripts

Currently some scripts exit 0 on success, some have 0/1/2 semantics
(`parity-compare.py`), and some (historical pass scripts) exit based on the
last compile unit's exit code. All reusable scripts should follow the pattern:

| Exit code | Meaning |
|-----------|---------|
| 0 | PASS — all checks passed |
| 1 | FAIL — a check failed |
| 2 | SKIP — prerequisite not available (not a failure) |

Document this in `AGENTS.md` and enforce it via review on new scripts.

#### R8. Move e2e test log files to `.gitignore` or an archive directory

The `e2e/` directory contains ~20 `test-run-*.log` files mixed with the actual
Playwright spec files. These are generated artifacts. Either add them to
`.gitignore` or move to `e2e/logs/`. An agent listing the e2e directory should
see only test specs and goldens, not historical run output.

---

### Low Impact (nice to have)

#### R9. Add `BUILD-NATIVE.md` and `BUILD-WASM.md` as skill-linked quick-refs

Split the build documentation into two focused files, each under 50 lines:

- `BUILD-NATIVE.md`: one-liner build + run + smoke
- `BUILD-WASM.md`: one-liner build + serve + test

The skills reference these as "pre-reading" instead of the current approach
of inlining build commands into each skill body.

#### R10. Generate a `AGENTS.md` skill index table automatically

Instead of manually maintaining the skill index in both `skills/README.md`
and `AGENTS.md`, extract it from YAML frontmatter:

```bash
for f in skills/*/SKILL.md; do
    # extract name, description, depends_on
done
```

#### R11. Tag which scripts are tier-level vs individual

Some scripts (`test.sh`) run the full CI cycle and take minutes. Others
(`lint.sh`) take seconds. Add a comment convention:

```bash
# @tier: lint|build|smoke|test  — which tier this script belongs to
# @time: <seconds>              — approximate runtime
```

#### R12. Provide a Nix flake devShell with all agent prerequisites

The repo already has `flake.nix` / `flake.lock`. Enhance the devShell to
include all toolchain prerequisites: `emscripten`, `wine`, `xvfb-run`,
`node`, `chromium`, `ffmpeg`, `imagemagick`, `xdotool`. Then a new agent
can `nix develop` and have the full toolchain.

---

## Summary Priority Order

| Rank | What | Effort | Impact |
|------|------|--------|--------|
| 1 | R1 — Archive historical scripts | Low (one `mv` + commit) | High |
| 2 | R3 — Create `AGENTS.md` | Low (one new file) | High |
| 3 | R2 — `ci-local.sh` ✓ implemented as four-tier `lint`/`build`/`smoke`/`test` | — | — |
| 4 | R4 — Fix skill script references | Low (edits to 7 files) | Medium |
| 5 | R5 — `skill-verify.sh` gate | Low (new script) | Medium |
| 6 | R6 — Skill `depends_on` frontmatter | Low (7 YAML blocks) | Medium |
| 7 | R8 — Clean e2e log files | Low | Medium |
| 8 | R7 — Standardize exit codes | Medium (audit all scripts) | Medium |
| 9 | R9 — Split build docs | Low | Low |
| 10 | R10 — Auto-generate skill index | Low | Low |
| 11 | R11 — Tag scripts with @ci/@local | Low | Low |
| 12 | R12 — Nix devShell | Medium | Low |

The top 4 items can be done in a single session and would measurably improve
the agent developer experience.
