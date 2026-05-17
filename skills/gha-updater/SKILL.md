---
name: gha-updater
description: Scans GitHub Actions workflow files for stale action versions and updates them to the latest releases. Use when maintaining CI/CD workflows or when Node.js deprecation warnings appear.
version: 0.2.0
---

# GitHub Actions Updater

Scans all `.github/workflows/*.yml` files, checks each action against its latest GitHub release, and updates stale version pins.

## Usage

```bash
# Check for stale actions without making changes
bash .pi/skills/gha-updater/scripts/check-gha-versions.sh

# Check and update
bash .pi/skills/gha-updater/scripts/check-gha-versions.sh --update
```

## How it works

1. Parses all `uses:` lines from workflow YAML files
2. For each action (e.g. `actions/checkout@v4`), queries the GitHub API for the latest release tag
3. Compares current vs latest version
4. Reports stale actions or applies updates in-place

## Output

```
.github/workflows/ci.yml
  actions/checkout@v4 → v6 (via GitHub API)
  actions/cache@v4 → v5
  (up to date) actions/upload-artifact@v7

.github/workflows/release.yml
  actions/checkout@v4 → v6
  softprops/action-gh-release@v2 → v3
```

## Node.js deprecation warnings

GitHub Actions runners emit deprecation warnings when a workflow uses an action
pinned to a Node.js runtime that is end-of-life. Common patterns:

| Warning | Likely cause | Fix |
|---------|-------------|-----|
| `Node.js 16 actions are deprecated.` | `actions/checkout@v3` or older | Bump to `@v4` |
| `The `set-output` command is deprecated.` | Action uses `::set-output` | Update to `GITHUB_OUTPUT` |
| `The `save-state` command is deprecated.` | Action uses `::save-state` | Update to `GITHUB_STATE` |

**Detection:**

```bash
gh run view <run-id> --log | grep -i "deprecated\|Node.js 16\|Node.js 12"
```

**Remediation:** Run the updater script which bumps major version pins. For
actions that bundle their own Node.js runtime (e.g. `setup-emsdk`, `setup-node`),
check the action's CHANGELOG for the minimum supported runner image version.

> **Check runner image compatibility** before committing a major-version bump:
> 1. Look up the runner image spec: `gh run view <run-id> --json 'headBranch,headSha'`
> 2. Verify the new major version targets Node.js 20+ (current runner default).
> 3. Run the affected CI workflow with `act` if available, or push to a draft PR.

## Verification

After updating, verify the workflow runs cleanly:

```bash
# Re-run the workflow on the branch
gh workflow run ci.yml --ref <branch>

# Check for deprecation warnings in the new run
gh run view --log | grep -i "deprecated"
```

## Notes

- Only updates the version tag after `@` (e.g. `@v4` → `@v6`)
- Skips non-GitHub actions and actions without a `@version` suffix
- Uses the GitHub API with no authentication (60 req/hr unauthenticated; set `GITHUB_TOKEN` for higher limits)
- Shows a warning for breaking major version bumps but applies them

## Lifecycle

| When to run | Why |
|-------------|-----|
| Monthly | Catch stale versions before Node.js deprecation kicks in |
| After runner image update | New runner may deprecate old Node.js runtimes |
| Before Emscripten version bump | `setup-emsdk` may require a newer `actions/checkout` |
| When CI shows `::warning::deprecated` | Deprecation warning in log output |
