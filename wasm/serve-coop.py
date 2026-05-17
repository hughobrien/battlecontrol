#!/usr/bin/env python3
"""
Minimal dev server for the WASM bundle.

Adds Cross-Origin-Opener-Policy + Cross-Origin-Embedder-Policy headers so
SharedArrayBuffer (required for Emscripten pthreads) is available in the
browser.

Usage (from repo root):
    python3 wasm/serve-coop.py           # port 8080
    python3 wasm/serve-coop.py 9090      # custom port

For production or CI, prefer nginx:
    nix run .#wasm-server
"""

import http.server
import os
import sys


class COOPHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def guess_type(self, path):
        if str(path).endswith(".wasm"):
            return "application/wasm"
        return super().guess_type(path)

    def log_message(self, fmt, *args):
        # Suppress noisy per-request logs; show only start/stop.
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    # Optional second arg: serve directory (defaults to build-wasm/)
    if len(sys.argv) > 2:
        wasm_dir = os.path.normpath(sys.argv[2])
    else:
        wasm_dir = os.path.normpath(
            os.path.join(os.path.dirname(__file__), "..", "build-wasm")
        )

    # Accept builds that have ra.html, td.html, or both.
    has_ra = os.path.isfile(os.path.join(wasm_dir, "ra.html"))
    has_td = os.path.isfile(os.path.join(wasm_dir, "td.html"))
    if not has_ra and not has_td:
        print(f"ERROR: neither ra.html nor td.html found in {wasm_dir}.")
        print("  Build the WASM bundle first:")
        print("    emcmake cmake --preset wasm && cmake --build build-wasm --target ra")
        print("    emcmake cmake --preset wasm && cmake --build build-wasm --target td")
        sys.exit(1)

    os.chdir(wasm_dir)
    if has_ra:
        print(f"Serving WASM bundle at http://localhost:{port}/ra.html")
    if has_td:
        print(f"Serving WASM bundle at http://localhost:{port}/td.html")
    print("  COOP + COEP headers enabled — SharedArrayBuffer available")
    print("  Press Ctrl-C to stop.")
    http.server.test(COOPHandler, port=port, bind="localhost")
