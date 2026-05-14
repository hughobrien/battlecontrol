## Summary

<!-- What does this PR do? -->

## Test plan

<!-- How was this verified? -->

## Smoke-test checklist (required if this PR adds or modifies a test)

> See [smoke-test design rule](../docs/smoke-test-design-rule.md) for details.

- [ ] Test header lists numbered acceptance criteria
- [ ] Every criterion has a matching `expect()` / `assert` in the body
- [ ] Rendering tests: pixel-range or pixel-diff assertion present (not just fill%)
- [ ] Audio tests: frequency-domain check present (not just log-line grep)
- [ ] Screenshots saved and uploaded as CI artefacts on failure
- [ ] Each assertion comment names the regression it guards

_Not applicable (no smoke test changes in this PR)_ — delete this section if so.
