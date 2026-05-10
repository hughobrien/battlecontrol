# Serving the WASM Bundle Locally

The Red Alert WASM build (produced by [TIM-376]) requires **cross-origin isolation**
for `SharedArrayBuffer`, which Emscripten uses for pthreads (audio threading).
Browsers enforce cross-origin isolation by checking two response headers on every
request to the serving origin:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`file://` URIs do not support these headers, and plain `python3 -m http.server` does
not add them. Use one of the methods below.

---

## Quickstart: Nix (recommended)

```sh
# 1. Build the WASM bundle
emcmake cmake --preset wasm && cmake --build build-wasm --target ra

# 2. Start the nginx server (port 8080)
nix run .#wasm-server

# 3. Open in a browser
xdg-open http://localhost:8080/ra.html

# Optional: use a different port
PORT=9090 nix run .#wasm-server

# Optional: point at a different build directory
WASM_DIR=/path/to/build-wasm nix run .#wasm-server
```

Acceptance check:

```sh
curl -I http://localhost:8080/ra.html | grep -E "opener-policy|embedder-policy"
# Expected:
# cross-origin-opener-policy: same-origin
# cross-origin-embedder-policy: require-corp
```

---

## Manual: nginx (non-Nix)

The nginx config is at `wasm/nginx.conf`. It serves `build-wasm/` on port 8080.

Run from the repo root so that the relative `root build-wasm;` path resolves:

```sh
# Run nginx in the foreground, writing pid/logs to /tmp
nginx -c "$PWD/wasm/nginx.conf" \
      -g "pid /tmp/ra-nginx.pid; error_log /tmp/ra-nginx.err; daemon off;"
```

If nginx is not in your path: `sudo apt-get install nginx` (Debian/Ubuntu) or
`sudo dnf install nginx` (Fedora).

If `/etc/nginx/mime.types` doesn't exist on your system, update the `include` line
in `wasm/nginx.conf` to point at your nginx MIME types file
(e.g. `/usr/share/nginx/mime.types` on Arch).

---

## Why not `python3 -m http.server`?

Python's built-in server does not add `Cross-Origin-Opener-Policy` or
`Cross-Origin-Embedder-Policy` headers, so the browser withholds `SharedArrayBuffer`
and Emscripten pthreads fail to initialize. For quick iteration you can use:

```python
# serve-coop.py — minimal dev server with cross-origin isolation headers
import http.server

class COOPHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def guess_type(self, path):
        if path.endswith(".wasm"):
            return "application/wasm"
        return super().guess_type(path)

if __name__ == "__main__":
    import os, sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    os.chdir("build-wasm")
    http.server.test(COOPHandler, port=port)
```

Run with: `python3 wasm/serve-coop.py 8080`

This is fine for local testing but nginx (via `nix run .#wasm-server`) is the
canonical server for CI and demo purposes.

---

## Build output layout

After `cmake --build build-wasm --target ra`, the directory `build-wasm/` contains:

| File | Description |
|------|-------------|
| `ra.html` | Entry point (generated from `wasm/shell.html`) |
| `ra.js` | Emscripten JS glue |
| `ra.wasm` | WebAssembly binary |
| `ra.worker.js` | pthread worker thread script |

Open `http://localhost:8080/ra.html` in a browser to run the game.
Game data files must be loaded via the in-page file picker (Emscripten FS) or
pre-packaged with `--preload-file` at build time (not yet wired up).
