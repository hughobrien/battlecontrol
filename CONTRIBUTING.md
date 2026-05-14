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

## Worktree protocol

All engineering work happens in a per-issue git worktree. See
[`CLAUDE.md`](CLAUDE.md) for the full protocol.

## Commit messages

- One short imperative sentence in the subject
- Add `Co-Authored-By: Paperclip <noreply@paperclip.ing>` as a trailer

## License

Source code is GPLv3. Do not commit game assets or proprietary content.
