#!/usr/bin/env python3
"""
Minimal asset server for C&C MIX files in WASM e2e tests.

Serves a directory with CORS + Cross-Origin-Resource-Policy headers so that
a COEP-enabled page (served by serve-coop.py) can fetch MIX files from a
different origin (different port).

Usage:
    python3 wasm/serve-assets.py <directory> [port]

Red Alert example:
    python3 wasm/serve-assets.py /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1 9090

Tiberian Dawn example:
    python3 wasm/serve-assets.py /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1 9090
"""
import http.server
import os
import sys


class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        # COEP requires either CORS or CORP for cross-origin resources.
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <directory> [port]", file=sys.stderr)
        sys.exit(1)

    directory = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9090

    if not os.path.isdir(directory):
        print(f"ERROR: directory not found: {directory}", file=sys.stderr)
        sys.exit(1)

    os.chdir(directory)
    print(f"Serving {directory} at http://localhost:{port}/")
    print("  CORS + CORP headers enabled (required for COEP pages)")
    print("  Press Ctrl-C to stop.")
    http.server.test(CORSHandler, port=port, bind="localhost")
