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
import os
import re
import shutil
import time
import socket

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from drivers import WineCapture, NativeCapture, WasmCapture
from drivers.compare import full_report
from drivers.common import sweep_state, tactical_nonblack_fraction

SCENARIO_MAP = {
    "allied-l1": "SCG01EA",
    "allied-l2": "SCG02EA",
    "allied-l3": "SCG03EA",
    "allied-l4": "SCG04EA",
    "allied-l5": "SCG05EA",
    "soviet-l1": "SCU01EA",
    "soviet-l2": "SCU02EA",
    "soviet-l3": "SCU03EA",
    "soviet-l4": "SCU04EA",
    "soviet-l5": "SCU05EA",
}

SESSION_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(mission|vqa|title|menu)-"
)


def resolve_scenario(id: str) -> str:
    if id.upper().startswith("SC"):
        return id
    if id in SCENARIO_MAP:
        return SCENARIO_MAP[id]
    raise ValueError(
        f"unknown mission: {id} (try allied-l1..allied-l5 or soviet-l1..soviet-l5)"
    )


def prune_old_sessions(
    output_root: pathlib.Path, keep: int, current: pathlib.Path
) -> int:
    if keep <= 0:
        return 0
    sessions = [
        path
        for path in output_root.iterdir()
        if path.is_dir() and SESSION_RE.match(path.name)
    ]
    sessions.sort(key=lambda path: (path.stat().st_mtime, path.name), reverse=True)

    removed = 0
    for path in sessions[keep:]:
        if path == current:
            continue
        shutil.rmtree(path)
        removed += 1
    return removed


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

    try:
        return _run(args)
    finally:
        # Backstop cleanup: per-driver _cleanup handles the happy path, but
        # an exception above (e.g. driver init failure) skips it. sweep_state
        # is idempotent and only nukes per-run artefacts we know we own.
        sweep_state(verbose=False)


def _run(args):
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
    effective_frames = {}
    seed_file = checkpoint_dir / "RA_RANDOM_SEED.txt"
    if args.type == "mission" and ("wine" in targets or "native" in targets):
        os.environ.setdefault("RA_CAPTURE_FPS", "10")
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
                    min_tactical = float(
                        os.environ.get("RA_MIN_TACTICAL_NONBLACK", "0.20")
                    )
                    max_retries = int(os.environ.get("WINE_GAMEPLAY_RETRIES", "4"), 0)
                    retry = 0
                    while (
                        tactical_nonblack_fraction(str(result)) < min_tactical
                        and retry < max_retries
                    ):
                        retry += 1
                        invalid_path = checkpoint_dir / f"wine-invalid-{retry}.png"
                        result.rename(invalid_path)
                        print(
                            f"  NOTE Wine tactical viewport was blank; "
                            f"retrying gameplay capture ({retry}/{max_retries})"
                        )
                        result = driver.capture_mission(
                            scenario, args.frame, target_dir, logfile
                        )
                    tactical_fill = tactical_nonblack_fraction(str(result))
                    if tactical_fill < min_tactical:
                        raise RuntimeError(
                            "Wine capture did not enter gameplay "
                            f"(tactical nonblack={tactical_fill:.3f})"
                        )
                    effective_frames[target] = args.frame
                    wine_frame = checkpoint_dir / "wine-frame.txt"
                    if wine_frame.exists():
                        values = {}
                        for line in wine_frame.read_text().splitlines():
                            if "=" in line:
                                key, value = line.split("=", 1)
                                values[key] = value
                        if "actual" in values:
                            effective_frames[target] = int(values["actual"], 0)
                else:
                    result = driver.capture_vqa(
                        args.id, args.frame, target_dir, logfile
                    )
            elif target == "native":
                capture_frame = args.frame
                wine_frame = checkpoint_dir / "wine-frame.txt"
                if (
                    args.type == "mission"
                    and wine_frame.exists()
                    and os.environ.get("RA_SYNC_NATIVE_TO_WINE_FRAME", "0")
                    not in ("", "0")
                ):
                    values = {}
                    for line in wine_frame.read_text().splitlines():
                        if "=" in line:
                            key, value = line.split("=", 1)
                            values[key] = value
                    reason = values.get("reason", "")
                    actual = int(values.get("actual", args.frame), 0)
                    if reason == "stable" and actual > 0:
                        capture_frame = actual
                        print(
                            f"  NOTE native frame synced to Wine actual={actual} "
                            f"(requested {args.frame})"
                        )
                effective_frames[target] = capture_frame
                driver = NativeCapture()
                result = driver.capture_mission(
                    scenario, capture_frame, target_dir, logfile
                )
            else:  # wasm
                driver = WasmCapture()
                result = driver.capture_mission(
                    scenario, args.frame, target_dir, logfile
                )
                effective_frames[target] = args.frame
            captures[target] = str(result)
            if target == "wine" and "RA_RANDOM_SEED" in os.environ:
                seed_file.write_text(f"{os.environ['RA_RANDOM_SEED']}\n")
                manifest["random_seed"] = int(os.environ["RA_RANDOM_SEED"], 0)
            if target == "native" and seed_file.exists():
                manifest["random_seed"] = int(seed_file.read_text().strip(), 0)
            sz = result.stat().st_size if result.exists() else 0
            if result and result.exists():
                flat_path = checkpoint_dir / f"{target}.png"
                result.rename(flat_path)
                captures[target] = str(flat_path)
                sz = flat_path.stat().st_size
            print(f"  OK {target}: {captures[target]} ({sz} bytes)")
        finally:
            logfile.close()

    def _remove_old_diffs():
        for old in checkpoint_dir.glob("diff-*.png"):
            old.unlink()
        diff_dir = checkpoint_dir / "diff"
        if diff_dir.exists():
            for f in diff_dir.iterdir():
                f.unlink()
            diff_dir.rmdir()

    if len(captures) >= 2:
        report = full_report(captures, str(checkpoint_dir), args.threshold_ssim)
        if (
            args.type == "mission"
            and "wine" in captures
            and "native" in captures
            and effective_frames.get("wine") == 1
            and effective_frames.get("native") == 1
            and report["summary"] != "PASS"
            and os.environ.get("RA_RETRY_NATIVE_FRAME2_ON_FAIL", "1") not in ("", "0")
        ):
            old_native = checkpoint_dir / "native.png"
            if old_native.exists():
                old_native.rename(checkpoint_dir / "native-frame1.png")
            _remove_old_diffs()
            log_path = checkpoint_dir / "native-frame2-driver.log"
            with open(log_path, "w") as logfile:
                print(
                    "  NOTE retrying native at frame 2 after frame-1 comparison failed"
                )
                driver = NativeCapture()
                result = driver.capture_mission(scenario, 2, checkpoint_dir, logfile)
            flat_path = checkpoint_dir / "native.png"
            result.rename(flat_path)
            captures["native"] = str(flat_path)
            effective_frames["native"] = 2
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
        if effective_frames:
            manifest["effective_frames"] = effective_frames
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
    keep_sessions = int(os.environ.get("RA_KEEP_CAPTURE_SESSIONS", "5"), 0)
    removed = prune_old_sessions(output_root, keep_sessions, checkpoint_dir)
    if removed:
        print(f"  Pruned {removed} old capture session(s); kept newest {keep_sessions}")


if __name__ == "__main__":
    main()
