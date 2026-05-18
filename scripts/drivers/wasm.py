"""WASM capture driver — capture screenshots from WASM build via Playwright."""

import subprocess, os, time, pathlib, sys
from .common import *


class WasmCapture:
    """Capture screenshots from WASM build via Playwright headless."""

    def __init__(self, wasm_dir="build-wasm", port=9876):
        self.wasm_dir = pathlib.Path(wasm_dir)
        self.port = port

    def _start_server(self, logfile):
        server_script = (pathlib.Path(__file__).resolve().parent.parent
                         / "wasm" / "serve-coop.py")
        proc = subprocess.Popen(
            [sys.executable, str(server_script),
             "--directory", str(self.wasm_dir),
             "--port", str(self.port)],
            stdout=logfile, stderr=logfile)
        time.sleep(2)
        return proc

    def capture_mission(self, scenario: str, frame: int,
                        output_dir: pathlib.Path,
                        logfile=None) -> pathlib.Path:
        """Capture WASM canvas at given game frame."""
        logfile = logfile or subprocess.DEVNULL
        server = None
        try:
            server = self._start_server(logfile)
            output_dir.mkdir(parents=True, exist_ok=True)
            cap_path = output_dir / "capture.png"
            self._playwright_capture(scenario, frame, str(cap_path))
            return cap_path
        finally:
            if server:
                kill_process_tree(server)

    def _playwright_capture(self, scenario: str, frame: int, output_path: str):
        from playwright.sync_api import sync_playwright
        scenario_name = f"{scenario}.INI"
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page(viewport={"width": 1024, "height": 768})
            page.goto(
                f"http://localhost:{self.port}/ra.html"
                f"?autostart=1&scenario={scenario_name}",
                wait_until="networkidle", timeout=60000)
            page.wait_for_function(
                "() => typeof Module !== 'undefined' && Module.__wasmReady",
                timeout=60000)
            frame_wait = max(frame / 15.0, 3.0)
            page.wait_for_timeout(int(frame_wait * 1000))
            canvas = page.query_selector("canvas")
            if canvas:
                canvas.screenshot(path=output_path)
            else:
                page.screenshot(path=output_path)
            browser.close()

    def capture_vqa(self, vqa_stem: str, frame: int,
                    output_dir: pathlib.Path,
                    logfile=None) -> pathlib.Path:
        """Capture WASM VQA frame — stub, not yet implemented."""
        raise NotImplementedError("WASM VQA capture not yet implemented")
