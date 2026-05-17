# Contributing to battlecontrol

## Smoke-test design rule

Every PR that adds or modifies a smoke test **must follow the
[smoke-test design rule](docs/smoke-test-design-rule.md)**:

> Define explicit pass/fail assertions *before* writing the harness.
> For rendering output: pixel-range or pixel-diff assertion required —
> fill% alone is not sufficient.

The rule was established after TIM-587, where a CI job passed on fill% while
frames showed block-aligned cyan corruption.

**Reviewer checklist** (also in the design rule doc):

- [ ] Test file header lists numbered acceptance criteria
- [ ] Every criterion has a matching `expect()` / `assert` in the body
- [ ] Rendering tests include at least one pixel-range or pixel-diff assertion
- [ ] Audio tests include a frequency-domain check, not just a log-line grep
- [ ] Screenshots are saved and uploaded as artefacts on failure
- [ ] Each assertion comment names the specific regression it guards

## Issue labelling — `tier:milestone`

When an issue marks a **categorical phase transition** in the port (first clean link,
first menu render, first in-game frame, first playable WASM build, etc.) apply the
`tier:milestone` label.  Routine bug-fixes and refactors do not qualify.

This lets future contributors scan the roadmap at a glance without wading through
the full pass-number chronology.

The label is company-wide in the TIM project (colour `#7C3AED`).

## Branch workflow

All work is done on feature branches. See
[`AGENTS.md`](AGENTS.md#branch-and-pr-workflow) for the full workflow.

## Commit messages

- One short imperative sentence in the subject
- Add `Co-Authored-By: Paperclip <noreply@paperclip.ing>` as a trailer

## License

Source code is GPLv3. Do not commit game assets or proprietary content.
