# WASM deployment

Two deployment paths are wired up in CI. GitHub Pages is the primary active path
(no external secrets needed). Cloudflare Pages is the preferred long-term target
(better headers) but requires a one-time credential setup.

## Active deployment: GitHub Pages

**URL:** `https://hughobrien.github.io/battlecontrol/`

Workflow: `.github/workflows/gh-pages.yml` — triggers on every push to `master`
that touches source, `wasm/`, or `CMakeLists.txt`.

COOP/COEP are injected via `coi-serviceworker.min.js` (vendored at
`wasm/coi-serviceworker.min.js`, MIT license). The service worker auto-reloads
the page once on first visit to activate; subsequent loads are transparent.

**One-time repo setup** (already done or do once):

1. Push the workflow to `master` — CI will push a `gh-pages` branch on the next run.
2. In the GitHub repo: **Settings → Pages → Source → Deploy from branch → `gh-pages` / `/ (root)`**.

That's it. No API tokens or external accounts needed.

## Why COOP + COEP are required

`SharedArrayBuffer` is only available in a cross-origin-isolated context.
Emscripten's pthread support (used for audio threading and async I/O) depends on
`SharedArrayBuffer`. Both headers must be present on every response from the origin.

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

GitHub Pages cannot set these headers directly — hence `coi-serviceworker`. Cloudflare
Pages / Netlify can set them via the `_headers` file in this directory.

## Provider comparison

| | GitHub Pages | Cloudflare Pages | Netlify |
|---|---|---|---|
| HTTPS | ✓ | ✓ | ✓ |
| Native COOP/COEP headers | ✗ (need SW shim) | ✓ | ✓ |
| Free tier bandwidth | 100 GB/mo soft | Unlimited | 100 GB/mo |
| Max file size | 100 MB | 25 MB | 100 MB |
| Credentials required | GitHub token (built-in) | API token + account ID | Site ID + token |

## Upgrading to Cloudflare Pages

If you want native COOP/COEP headers (no SW shim, works in all security environments):

1. Create a Cloudflare account (free tier).
2. Create an API token: Dashboard → My Profile → API Tokens →
   "Edit Cloudflare Workers" template, scoped to Pages.
3. Find your Account ID in the dashboard right sidebar.
4. Add to GitHub repo secrets:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
5. Create the Pages project (one-time, from any authenticated machine):
   ```
   npx wrangler pages project create cnc-remastered-linux
   ```
6. Enable `.github/workflows/wasm-deploy.yml` (currently present but requires secrets).

Cloudflare reads `_headers` automatically from the published directory root — no
code change needed beyond adding the secrets.

## Manual deployment (Cloudflare Pages)

```bash
# Build
emcmake cmake --preset wasm
cmake --build build-wasm --target ra --parallel
cmake --build build-wasm --target td --parallel

# Collect artifacts
cp build-wasm/ra.{html,js,wasm} build-wasm/td.{html,js,wasm} wasm/deploy/
cp wasm/preloader.js wasm/deploy/

# Deploy (requires wrangler login or CLOUDFLARE_API_TOKEN set)
npx wrangler pages deploy wasm/deploy --project-name cnc-remastered-linux
```

Verify headers after deploy:
```bash
curl -sI https://cnc-remastered-linux.pages.dev/ra.html | grep -i cross-origin
```
