---
name: gha-updater
description: Scans GitHub Actions workflow files for stale action versions and updates them to the latest releases. Use when maintaining CI/CD workflows or when Node.js deprecation warnings appear.
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

## Notes

- Only updates the version tag after `@` (e.g. `@v4` → `@v6`)
- Skips non-GitHub actions and actions without a `@version` suffix
- Uses the GitHub API with no authentication (60 req/hr unauthenticated; set `GITHUB_TOKEN` for higher limits)
- Shows a warning for breaking major version bumps but applies them
