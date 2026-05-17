# WASM deployment

Deployed to GitHub Pages on every push to `master`.
COOP/COEP headers are injected via `coi-serviceworker.min.js`.

## Local development (nginx)

Run WASM builds locally with native COOP/COEP headers — no service-worker shim, no
external accounts. Requires Docker.

**Quickstart** (from the repo root, after building WASM artifacts into `wasm/deploy/`):

```bash
cd wasm/deploy
docker compose up
```

Then open <http://localhost:8080/ra.html> or <http://localhost:8080/td.html> in Chrome.

`docker-compose.yml` mounts the current directory as the nginx document root and
injects COOP/COEP via `nginx.conf`. Stop with `Ctrl-C` or `docker compose down`.

**One-liner** (no compose, from the repo root):

```bash
docker run --rm -p 8080:80 \
  -v "$(pwd)/wasm/deploy:/usr/share/nginx/html:ro" \
  -v "$(pwd)/wasm/deploy/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:alpine
```

**Verify headers are correct:**

```bash
curl -sI http://localhost:8080/ra.html | grep -i cross-origin
# Expected:
#   Cross-Origin-Opener-Policy: same-origin
#   Cross-Origin-Embedder-Policy: require-corp
#   Cross-Origin-Resource-Policy: cross-origin
```

**Build WASM first** (if you haven't already):

```bash
emcmake cmake --preset wasm
cmake --build build-wasm --target ra --parallel
cmake --build build-wasm --target td --parallel
cp build-wasm/ra.{html,js,wasm} build-wasm/td.{html,js,wasm} wasm/deploy/
cp wasm/preloader.js wasm/deploy/
```

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

GitHub Pages cannot set these headers directly — hence `coi-serviceworker`.

## Provider comparison

| | GitHub Pages |
|---|---|
| HTTPS | ✓ |
| Native COOP/COEP headers | ✗ (need SW shim) |
| Free tier bandwidth | 100 GB/mo soft |
| Max file size | 100 MB |
| Credentials required | GitHub token (built-in) |


