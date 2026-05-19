#!/usr/bin/env python3
"""Capture checkpoint screenshots from any mission or VQA across all targets.

Drives Wine OG, native Linux, and WASM capture drivers to produce
pixel-level parity comparisons.

Usage:
  capture-checkpoint mission allied-l2 --frame 200 --targets wine,native
  capture-checkpoint vqa ENGLISH --frame 120 --targets wine
  capture-checkpoint mission allied-l1 --targets all
  capture-checkpoint title --targets wine
  capture-checkpoint menu --targets wine
"""

import argparse
import sys
import pathlib
import json
import time
import socket

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers import WineCapture, NativeCapture, WasmCapture
from drivers.compare import full_report

SCENARIO_MAP = {
    "allied-l1": "SCG01EA",
    "allied-l2": "SCG02EA",
    "allied-l3": "SCG03EA",
    "soviet-l1": "SCU01EA",
    "soviet-l2": "SCU02EA",
    "soviet-l3": "SCU03EA",
}


def resolve_scenario(id: str) -> str:
    if id.upper().startswith("SC"):
        return id
    if id in SCENARIO_MAP:
        return SCENARIO_MAP[id]
    raise ValueError(
        f"unknown mission: {id} (try allied-l1, allied-l2, allied-l3, soviet-l1)"
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "type", choices=["mission", "vqa", "title", "menu"], help="capture type"
    )
    ap.add_argument("id", help="mission (allied-l1) or VQA stem (ENGLISH)")
    ap.add_argument(
        "--frame", type=int, default=0, help="frame number to capture (default: 0)"
    )
    ap.add_argument(
        "--targets",
        default="wine,native",
        help="comma-separated targets: wine,native,wasm,all",
    )
    ap.add_argument(
        "--output", default="/tmp/battlecontrol", help="output root directory"
    )
    ap.add_argument(
        "--threshold-ssim",
        type=float,
        default=0.90,
        help="SSIM pass threshold (default: 0.90)",
    )
    args = ap.parse_args()

    targets = args.targets.split(",")
    if "all" in targets:
        targets = ["wine", "native", "wasm"]

    output_root = pathlib.Path(args.output)
    manifest = {
        "type": args.type,
        "id": args.id,
        "frame": args.frame,
        "targets": targets,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    if args.type == "mission":
        scenario = resolve_scenario(args.id)
        manifest["scenario"] = f"{scenario}.INI"
    else:
        scenario = None
        manifest["vqa_stem"] = args.id

    timestamp = time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime())
    session_base = f"{timestamp}-{args.type}-{args.id}"
    checkpoint_dir = output_root / session_base
    if checkpoint_dir.exists():
        suffix = 1
        while (output_root / f"{session_base}-{suffix}").exists():
            suffix += 1
        checkpoint_dir = output_root / f"{session_base}-{suffix}"

    checkpoint_dir.mkdir(parents=True, exist_ok=False)

    # Boot capture types (title/menu) — single target, no comparison
    if args.type in ("title", "menu"):
        for target in targets:
            if target != "wine":
                print(f"  SKIP {target}: title/menu only supports wine")
                continue
            driver = WineCapture()
            path = driver.capture_boot(args.type, checkpoint_dir)
            print(f"  OK wine: {path}")
        return

    with open(checkpoint_dir / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    captures = {}
    for target in targets:
        if target not in ("wine", "native", "wasm"):
            raise ValueError(f"unknown target: {target} (allowed: wine, native, wasm)")
        target_dir = checkpoint_dir
        log_path = checkpoint_dir / f"{target}-driver.log"
        logfile = open(log_path, "w")
        try:
            if target == "wine":
                driver = WineCapture()
                if args.type == "mission":
                    result = driver.capture_mission(
                        scenario, args.frame, target_dir, logfile
                    )
                else:
                    result = driver.capture_vqa(
                        args.id, args.frame, target_dir, logfile
                    )
            elif target == "native":
                driver = NativeCapture()
                result = driver.capture_mission(
                    scenario, args.frame, target_dir, logfile
                )
            else:  # wasm
                driver = WasmCapture()
                result = driver.capture_mission(
                    scenario, args.frame, target_dir, logfile
                )
            captures[target] = str(result)
            sz = result.stat().st_size if result.exists() else 0
            if result and result.exists():
                flat_path = checkpoint_dir / f"{target}.png"
                result.rename(flat_path)
                captures[target] = str(flat_path)
                sz = flat_path.stat().st_size
            print(f"  OK {target}: {captures[target]} ({sz} bytes)")
        finally:
            logfile.close()

    if len(captures) >= 2:
        report = full_report(captures, str(checkpoint_dir), args.threshold_ssim)
        print(f"\n=== Comparison: {report['summary']} ===")
        for r in report["pairs"]:
            status = "PASS" if r["passed"] else "FAIL"
            print(f"  {r['pair']}: SSIM={r['ssim']:.4f} p99={r['p99']:.1f} [{status}]")
        # Promote diffs from diff/ subdir to session dir
        diff_dir = checkpoint_dir / "diff"
        if diff_dir.exists():
            for f in diff_dir.iterdir():
                f.rename(checkpoint_dir / f.name)
            diff_dir.rmdir()
    elif len(captures) == 1:
        print("\n(one target — no comparison)")
    else:
        print("\nFAIL: no captures produced")
        sys.exit(1)

    with open(checkpoint_dir / "manifest.json", "w") as f:
        manifest["captures"] = captures
        json.dump(manifest, f, indent=2)

    # Start HTTP server on port 1234, restarting it if an existing instance
    # is serving the wrong directory (so the index shows every session under
    # output_root, not just one).
    import subprocess

    def _server_dir_on_port(port):
        r = subprocess.run(
            ["pgrep", "-af", f"http.server {port}"],
            capture_output=True,
            text=True,
        )
        for line in r.stdout.splitlines():
            parts = line.split()
            if "--directory" in parts:
                return parts[parts.index("--directory") + 1]
        return None

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    running = False
    try:
        sock.connect(("localhost", 1234))
        running = True
    except ConnectionRefusedError:
        pass
    sock.close()

    want = str(output_root)
    if running:
        current = _server_dir_on_port(1234)
        if current == want:
            print(f"  HTTP server already serving {want} at http://localhost:1234/")
        else:
            print(
                f"  HTTP server on :1234 is serving {current!r}; "
                f"restarting to serve {want!r}"
            )
            subprocess.run(["pkill", "-f", "http.server 1234"], check=False)
            time.sleep(0.5)
            running = False

    if not running:
        subprocess.Popen(
            ["python3", "-m", "http.server", "1234", "--directory", want],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"  HTTP server started at http://localhost:1234/ (serving {want})")

    print(f"\nSession dir: {checkpoint_dir}")


if __name__ == "__main__":
    main()
