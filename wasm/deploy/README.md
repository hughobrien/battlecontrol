# WASM deployment skeleton

Target host: **Cloudflare Pages** (free tier).

## Provider rationale

| Requirement | GitHub Pages | Netlify | Cloudflare Pages |
|---|---|---|---|
| HTTPS | ✓ | ✓ | ✓ |
| Custom response headers (COOP/COEP) | ✗ | ✓ | ✓ |
| Free bandwidth | 100 GB/mo | 100 GB/mo | Unlimited |
| Max file size | 100 MB | 100 MB | 25 MB |

GitHub Pages cannot set custom headers — SharedArrayBuffer is blocked outright.
Netlify and Cloudflare Pages both use the same `_headers` file format (trivial
to switch between them).  Cloudflare Pages wins on unlimited bandwidth, which
matters once game assets are in play.

## Why COOP + COEP are required

`SharedArrayBuffer` is only available in a cross-origin-isolated context.
Emscripten's pthread support (used for audio threading and async I/O) depends
on `SharedArrayBuffer`. Both headers must be present on **every** HTTP response
from the origin — not just the HTML file.

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: cross-origin
```

The `_headers` file in this directory sets all three on `/*`.

## Deploying to Cloudflare Pages (TIM-407 checklist)

1. Build the WASM artifacts:
   ```
   emcmake cmake --preset wasm && cmake --build build-wasm --target ra
   emcmake cmake --preset wasm && cmake --build build-wasm --target td
   ```

2. Collect deploy artifacts into this directory:
   ```
   cp build-wasm/ra.html   wasm/deploy/
   cp build-wasm/ra.js     wasm/deploy/
   cp build-wasm/ra.wasm   wasm/deploy/
   cp build-wasm/td.html   wasm/deploy/
   cp build-wasm/td.js     wasm/deploy/
   cp build-wasm/td.wasm   wasm/deploy/
   cp wasm/shell.html      wasm/deploy/   # if used as index
   ```
   Do **not** commit game asset MIX files — users supply those at runtime via
   the in-browser file picker.

3. Create a Cloudflare Pages project (one-time):
   - Dashboard → Workers & Pages → Create application → Pages → Connect to Git
   - Or: `npx wrangler pages project create cnc-remastered-linux`

4. Deploy:
   ```
   npx wrangler pages deploy wasm/deploy --project-name cnc-remastered-linux
   ```
   Cloudflare Pages reads `_headers` automatically from the published directory root.

5. Verify headers:
   ```
   curl -sI https://<your-project>.pages.dev/ra.html | grep -i cross-origin
   ```
   Expected:
   ```
   cross-origin-opener-policy: same-origin
   cross-origin-embedder-policy: require-corp
   cross-origin-resource-policy: cross-origin
   ```

## Netlify (alternative)

The `_headers` file works identically on Netlify. Deploy with:
```
npx netlify deploy --dir wasm/deploy --prod
```

## Gotchas

- **25 MB per file limit (Cloudflare Pages)**: WASM binaries are ~1-2 MB — well
  within limits. If future builds include inlined assets and exceed 25 MB,
  switch to Netlify (100 MB limit) or move large assets to R2/a CDN.

- **`Cross-Origin-Resource-Policy: cross-origin`**: Required so the WASM worker
  can fetch subresources (`.data` files, audio) that are loaded cross-origin by
  the Emscripten runtime. Without it, the worker fetch is blocked.

- **GitHub Pages workaround exists but is fragile**: The `coi-serviceworker`
  trick injects COOP/COEP via a service worker shim. It requires user interaction
  on first load to register, breaks SSR, and is rejected by some security scanners.
  Not recommended.
