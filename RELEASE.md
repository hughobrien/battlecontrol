# Release Process

## Before cutting a release

- [ ] All CI checks on master are green (ci.yml, gh-pages.yml)
- [ ] All regression tests pass: T1–T10 WASM gates, parity comparisons, Wine OG diffs
- [ ] README release-notes section updated with what's new for this version
- [ ] WASM artifacts smoke-tested: ra.html + td.html load without pageerror
- [ ] Native Linux binaries build and validate: `bash scripts/first-run-pass-94.sh`

## Cutting a release

1. Push a semver tag:

```bash
git tag v0.X.0
git push origin v0.X.0
```

2. The [`release.yml`](.github/workflows/release.yml) workflow triggers automatically on `v*.*.*` tags.

   It builds and packages four artifacts in parallel:
   - RA Linux x86_64 (`.tar.gz`)
   - TD Linux x86_64 (`.tar.gz`)
   - RA WASM (`.zip`)
   - TD WASM (`.zip`)

3. After all four builds succeed, the `release` job:

   - Generates SHA-256 checksums
   - Writes a release manifest (commit SHA, run ID, build date, artifact checksums)
   - Creates a GitHub Release with auto-generated release notes
   - Attaches all artifacts + checksums + manifest

## Post-release

- [ ] Verify the release is published with all four artifacts attached
- [ ] Verify the gh-pages deploy runs on master (deploys latest WASM to GitHub Pages)
- [ ] Update the README status line if needed
- [ ] Test the deployed WASM binaries at the GitHub Pages URL
- [ ] Download one native binary, verify it runs: `tar xzf *.tar.gz && ./redalert`
