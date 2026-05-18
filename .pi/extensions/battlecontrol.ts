/**
 * pi-battlecontrol-dev — BattleControl development tools extension.
 *
 * Provides custom tools for WASM build, screenshot capture, and server
 * management for both Red Alert (ra) and Tiberian Dawn (td) targets.
 *
 * Auto-discovered from .pi/extensions/ — reload with /reload.
 *
 * Requirements (install once):
 *   npm install playwright   (in project root)
 *   npx playwright install chromium
 *
 * For the WASM build, run from a nix develop shell (or have emcmake in PATH):
 *   nix develop
 *   # then use the tools
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn, execSync } from "child_process";
import path from "path";
import fs from "fs";
import { createServer } from "net";

// ────────────────────────────────────────────────────────────────────────────
// Constants
// ────────────────────────────────────────────────────────────────────────────

const REPO_ROOT = path.resolve(process.cwd());
const BUILD_DIR = path.join(REPO_ROOT, "build-wasm");
const SCRIPTS_DIR = path.join(REPO_ROOT, "scripts");
const WASM_DIR = path.join(REPO_ROOT, "wasm");

const RA_ASSETS_DEFAULT = "/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1";
const TD_ASSETS_DEFAULT = "/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1";

type Game = "ra" | "td";
type Target = Game | "both";

const GAMES: Record<Game, {
  name: string;
  html: string;
  buildTarget: string;
  defaultAssets: string;
  shell: string;
}> = {
  ra: {
    name: "Red Alert",
    html: "ra.html",
    buildTarget: "ra",
    defaultAssets: RA_ASSETS_DEFAULT,
    shell: "shell.html",
  },
  td: {
    name: "Tiberian Dawn",
    html: "td.html",
    buildTarget: "td",
    defaultAssets: TD_ASSETS_DEFAULT,
    shell: "td-shell.html",
  },
};

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

function repoPath(...parts: string[]): string {
  return path.resolve(REPO_ROOT, ...parts);
}

function buildDir(...parts: string[]): string {
  return path.resolve(BUILD_DIR, ...parts);
}

function hasTool(tool: string): boolean {
  try {
    execSync(`which ${tool}`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/**
 * Auto-wrap a command in `nix develop` if not already inside a nix dev shell.
 * This ensures all tool commands run in the project's Nix environment.
 */
function nixWrap(cmd: string, args: string[]): { cmd: string; args: string[] } {
  if (process.env.IN_NIX_SHELL || !hasTool("nix")) {
    return { cmd, args };
  }
  return {
    cmd: "nix",
    args: [
      "develop",
      "--extra-experimental-features", "nix-command flakes",
      "--command",
      cmd,
      ...args,
    ],
  };
}

/** Strip the nix develop banner from stderr output (printed on first load). */
const NIX_BANNER_RE = /^(warning:.*\n)?[A-Z].*?— dev shell\n\nWorkflows \(from repo root\):[\s\S]*?Quick start:[\s\S]*?\n\n?/m;
function stripNixBanner(text: string): string {
  return text.replace(NIX_BANNER_RE, "");
}

/** Run a command and return { stdout, stderr, exitCode }. */
function run(
  cmd: string,
  args: string[],
  options?: { cwd?: string; timeout?: number }
): { stdout: string; stderr: string; exitCode: number } {
  const wrapped = nixWrap(cmd, args);
  try {
    const out = execSync(`${wrapped.cmd} ${wrapped.args.map(a => `'${a}'`).join(" ")}`, {
      cwd: options?.cwd ?? REPO_ROOT,
      timeout: options?.timeout ?? 600_000,
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf-8",
    });
    return {
      stdout: out.stdout ?? "",
      stderr: stripNixBanner(out.stderr ?? ""),
      exitCode: 0,
    };
  } catch (e: any) {
    return {
      stdout: e.stdout?.toString() ?? "",
      stderr: stripNixBanner(e.stderr?.toString() ?? ""),
      exitCode: e.status ?? 1,
    };
  }
}

/** Start a background process, returns the ChildProcess and a kill function. */
function background(
  cmd: string,
  args: string[],
  options?: { cwd?: string }
): { proc: import("child_process").ChildProcess; kill: () => void } {
  const proc = spawn(cmd, args, {
    cwd: options?.cwd ?? REPO_ROOT,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  return {
    proc,
    kill: () => {
      try { process.kill(-proc.pid!, "SIGINT"); } catch { /* ignore */ }
      try { process.kill(-proc.pid!, "SIGKILL"); } catch { /* ignore */ }
    },
  };
}

/** Wait for a URL to return HTTP 200. */
async function waitForServer(url: string, timeoutMs = 15_000, label = "server"): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (res.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise(r => setTimeout(r, 300));
  }
  throw new Error(`${label} at ${url} did not respond within ${timeoutMs}ms`);
}

/** Find a port that is free (or return the requested one if available). */
async function findFreePort(preferred = 8080): Promise<number> {
  return new Promise((resolve) => {
    const srv = createServer();
    srv.listen(preferred, "localhost", () => {
      const addr = srv.address();
      srv.close(() => resolve(addr?.port ?? preferred));
    });
    srv.on("error", () => {
      // preferred taken, let OS assign
      const srv2 = createServer();
      srv2.listen(0, "localhost", () => {
        const addr = srv2.address();
        srv2.close(() => resolve(addr?.port ?? 9090));
      });
    });
  });
}

/**
 * Kill any process listening on a given port.
 */
function killPort(port: number): void {
  try {
    const pid = execSync(`lsof -ti :${port} 2>/dev/null || ss -tlnp "sport = :${port}" | grep -oP 'pid=\\K\\d+' | head -1`, { encoding: "utf-8" }).trim();
    if (pid) {
      try { process.kill(parseInt(pid), "SIGINT"); } catch { /* ok */ }
    }
  } catch {
    // no process or tool missing
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Extension
// ────────────────────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // Verify we're in the battlecontrol repo
  if (!fs.existsSync(repoPath("CMakeLists.txt"))) {
    console.warn("[battlecontrol] Not in battlecontrol repo root — tools may not work correctly.");
  }

  // ── Tool: wasm_build ────────────────────────────────────────────────────

  pi.registerTool({
    name: "build_wasm",
    label: "WASM Build",
    description: "Build one or both WASM targets (ra, td) using Emscripten. Auto-wraps in nix develop if needed.",
    promptSnippet: "Build the Red Alert and/or Tiberian Dawn WASM targets with emcmake/cmake",
    promptGuidelines: [
      "Use wasm_build to compile C++ sources into WASM before running screenshots or tests",
      "The build target 'both' builds ra and td sequentially",
    ],
    parameters: Type.Object({
      target: Type.Union(
        [Type.Literal("ra"), Type.Literal("td"), Type.Literal("both")],
        { default: "both", description: "WASM target to build: ra, td, or both" }
      ),
      clean: Type.Optional(
        Type.Boolean({ default: false, description: "Reconfigure from scratch (delete build dir first)" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const target: Target = (params.target as Target) ?? "both";
      const clean = params.clean ?? false;

      if (!hasTool("emcmake")) {
        return {
          content: [{ type: "text", text: "❌ `emcmake` not found in PATH (tried via nix develop). Install Emscripten or check nix flake." }],
          isError: true,
        };
      }

      if (clean && fs.existsSync(BUILD_DIR)) {
        onUpdate?.({ content: [{ type: "text", text: "Cleaning build directory..." }] });
        fs.rmSync(BUILD_DIR, { recursive: true, force: true });
      }

      // Configure
      if (!fs.existsSync(BUILD_DIR) || clean) {
        onUpdate?.({ content: [{ type: "text", text: "Configuring with emcmake cmake --preset wasm..." }] });
        const cfg = run("emcmake", ["cmake", "--preset", "wasm"], { timeout: 120_000 });
        if (cfg.exitCode !== 0) {
          return {
            content: [{ type: "text", text: `❌ cmake configure failed:\n${cfg.stderr || cfg.stdout}` }],
            isError: true,
          };
        }
      }

      // Build targets
      const targets = target === "both" ? ["ra", "td"] : [target];
      const results: string[] = [];

      for (const t of targets) {
        const game = GAMES[t as Game];
        onUpdate?.({ content: [{ type: "text", text: `Building ${game.name} (${t})...` }] });
        const b = run("cmake", ["--build", BUILD_DIR, "--target", t, "--parallel"], { timeout: 600_000 });
        if (b.exitCode === 0) {
          const wasmFile = buildDir(`${t}.wasm`);
          const size = fs.existsSync(wasmFile) ? `${Math.round(fs.statSync(wasmFile).size / 1024)} KB` : "?";
          results.push(`✅ ${game.name} (${t}) — ${size}`);
        } else {
          results.push(`❌ ${game.name} (${t}) failed:\n${b.stderr || b.stdout}`);
        }
      }

      return {
        content: [{ type: "text", text: results.join("\n") }],
      };
    },
  });

  // ── Tool: serve_wasm ────────────────────────────────────────────────────

  pi.registerTool({
    name: "serve_wasm",
    label: "Serve WASM",
    description: "Start the WASM dev server with COOP/COEP headers on a given port.",
    promptSnippet: "Start the HTTP server for the WASM bundle with cross-origin isolation headers",
    promptGuidelines: [
      "Use serve_wasm before running browser-based tests or screenshots",
      "The server must be started on port 8080 (or pass a custom port)",
    ],
    parameters: Type.Object({
      port: Type.Optional(Type.Number({ default: 8080, description: "Server port" })),
      killExisting: Type.Optional(Type.Boolean({ default: true, description: "Kill existing process on port first" })),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const port = params.port ?? 8080;
      const killExisting = params.killExisting ?? true;

      if (!fs.existsSync(buildDir("ra.html"))) {
        return {
          content: [{ type: "text", text: `❌ ${buildDir("ra.html")} not found. Build the WASM targets first with wasm_build.` }],
          isError: true,
        };
      }

      if (killExisting) killPort(port);

      const script = repoPath("wasm", "serve-coop.py");
      const { proc, kill } = background("python3", [script, String(port), BUILD_DIR]);

      try {
        await waitForServer(`http://localhost:${port}/`, 10_000, "WASM server");
        return {
          content: [{ type: "text", text: `✅ WASM server running at http://localhost:${port}/ra.html (and /td.html)\n  PID: ${proc.pid}` }],
          details: { port, pid: proc.pid },
        };
      } catch (e: any) {
        kill();
        return {
          content: [{ type: "text", text: `❌ Failed to start WASM server: ${e.message}` }],
          isError: true,
        };
      }
    },
  });

  // ── Tool: serve_assets ──────────────────────────────────────────────────

  pi.registerTool({
    name: "serve_assets",
    label: "Serve Game Assets",
    description: "Start the MIX asset server with CORS headers for a game data directory.",
    promptSnippet: "Start the HTTP server for game data (MIX files) with CORS headers",
    promptGuidelines: [
      "Use serve_assets before running screenshots or tests that need game data",
      "Point it at the directory containing REDALERT.MIX (RA) or CCLOCAL.MIX (TD)",
    ],
    parameters: Type.Object({
      game: Type.Union(
        [Type.Literal("ra"), Type.Literal("td")],
        { default: "ra", description: "Which game's default asset directory to use" }
      ),
      dir: Type.Optional(Type.String({ description: "Custom asset directory path (overrides game default)" })),
      port: Type.Optional(Type.Number({ default: 9090, description: "Server port" })),
      killExisting: Type.Optional(Type.Boolean({ default: true, description: "Kill existing process on port first" })),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const game = (params.game ?? "ra") as Game;
      const port = params.port ?? 9090;
      const killExisting = params.killExisting ?? true;
      const assetDir = params.dir ?? GAMES[game].defaultAssets;

      if (!fs.existsSync(assetDir)) {
        return {
          content: [{ type: "text", text: `❌ Asset directory not found: ${assetDir}` }],
          isError: true,
        };
      }

      if (killExisting) killPort(port);

      const script = repoPath("wasm", "serve-assets.py");
      const { kill } = background("python3", [script, assetDir, String(port)]);

      try {
        // Check a known MIX file to verify the server works
        const mixFiles = game === "ra"
          ? ["REDALERT.MIX", "MAIN.MIX"]
          : ["CCLOCAL.MIX", "CONQUER.MIX"];
        await waitForServer(`http://localhost:${port}/${mixFiles[0]}`, 10_000, "Asset server");
        return {
          content: [{ type: "text", text: `✅ Asset server for ${GAMES[game].name} at http://localhost:${port}/\n  Directory: ${assetDir}` }],
          details: { port, assetDir },
        };
      } catch (e: any) {
        kill();
        return {
          content: [{ type: "text", text: `❌ Failed to start asset server: ${e.message}\n  Check directory: ${assetDir}` }],
          isError: true,
        };
      }
    },
  });

  // ── Tool: wasm_screenshot ───────────────────────────────────────────────

  pi.registerTool({
    name: "wasm_screenshot",
    label: "WASM Screenshot",
    description:
      "Build WASM target (optional), start servers, open in headless Chromium, wait, and capture a screenshot. " +
      "Requires playwright (`npm install playwright`) and chromium (`npx playwright install chromium`).",
    promptSnippet: "Build WASM, serve with game assets, and capture a Playwright screenshot of the running game",
    promptGuidelines: [
      "Use wasm_screenshot to visually verify the game is rendering correctly after a build",
      "The screenshot is saved to build-wasm/{target}-screenshot.png",
      "Game data is served from the default asset directories unless assetDir is specified",
      "Set headless: false and use Xvfb if headless mode produces a black canvas",
    ],
    parameters: Type.Object({
      target: Type.Union(
        [Type.Literal("ra"), Type.Literal("td")],
        { default: "ra", description: "Game target: ra (Red Alert) or td (Tiberian Dawn)" }
      ),
      waitMs: Type.Optional(
        Type.Number({ default: 1000, description: "Milliseconds to wait after page load before screenshot" })
      ),
      buildFirst: Type.Optional(
        Type.Boolean({ default: true, description: "Build the WASM target before taking the screenshot" })
      ),
      assetDir: Type.Optional(
        Type.String({ description: "Path to game data directory (defaults to game-specific asset path)" })
      ),
      wasmPort: Type.Optional(
        Type.Number({ default: 8080, description: "Port for the WASM dev server" })
      ),
      assetPort: Type.Optional(
        Type.Number({ default: 9090, description: "Port for the asset server" })
      ),
      headless: Type.Optional(
        Type.Boolean({ default: true, description: "Run headless (false = headed mode, requires Xvfb on :99)" })
      ),
      autostart: Type.Optional(
        Type.Boolean({ default: true, description: "Add ?autostart=1 to skip the main menu" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const target: Game = (params.target ?? "ra") as Game;
      const waitMs = params.waitMs ?? 1000;
      const buildFirst = params.buildFirst ?? true;
      const assetDir = params.assetDir ?? GAMES[target].defaultAssets;
      const wasmPort = params.wasmPort ?? 8080;
      const assetPort = params.assetPort ?? 9090;
      const headless = params.headless ?? true;
      const autostart = params.autostart ?? true;
      const game = GAMES[target];

      let screenshotsDir = buildDir();

      // ── Step 1: Build (optional) ──
      if (buildFirst) {
        onUpdate?.({ content: [{ type: "text", text: `Step 1/4: Building ${game.name} WASM target...` }] });
        if (!hasTool("emcmake")) {
          return {
            content: [{ type: "text", text: "❌ `emcmake` not found in PATH. Run `nix develop` first, or set buildFirst: false if the build is already up to date." }],
            isError: true,
          };
        }

        if (!fs.existsSync(BUILD_DIR)) {
          const cfg = run("emcmake", ["cmake", "--preset", "wasm"], { timeout: 120_000 });
          if (cfg.exitCode !== 0) {
            return { content: [{ type: "text", text: `❌ cmake configure failed:\n${cfg.stderr || cfg.stdout}` }], isError: true };
          }
        }

        const b = run("cmake", ["--build", BUILD_DIR, "--target", target, "--parallel"], { timeout: 600_000 });
        if (b.exitCode !== 0) {
          return { content: [{ type: "text", text: `❌ Build failed:\n${b.stderr || b.stdout}` }], isError: true };
        }
        onUpdate?.({ content: [{ type: "text", text: `✅ ${game.name} built` }] });
      }

      // Verify output exists
      if (!fs.existsSync(buildDir(game.html))) {
        return {
          content: [{ type: "text", text: `❌ ${buildDir(game.html)} not found. Build first or check target.` }],
          isError: true,
        };
      }

      // ── Step 2: Start servers ──
      onUpdate?.({ content: [{ type: "text", text: "Step 2/4: Starting servers..." }] });

      killPort(wasmPort);
      killPort(assetPort);

      // WASM server
      const wasmScript = repoPath("wasm", "serve-coop.py");
      const wasmSrv = background("python3", [wasmScript, String(wasmPort), BUILD_DIR]);
      await waitForServer(`http://localhost:${wasmPort}/`, 10_000, "WASM server");

      // Asset server
      if (!fs.existsSync(assetDir)) {
        wasmSrv.kill();
        return {
          content: [{ type: "text", text: `❌ Asset directory not found: ${assetDir}\n  Specify a valid path for the ${game.name} game data.` }],
          isError: true,
        };
      }
      const assetScript = repoPath("wasm", "serve-assets.py");
      const assetSrv = background("python3", [assetScript, assetDir, String(assetPort)]);
      await waitForServer(`http://localhost:${assetPort}/`, 10_000, "Asset server");

      let browserCleanup: (() => void) | null = null;

      try {
        // ── Step 3: Launch browser ──
        onUpdate?.({ content: [{ type: "text", text: "Step 3/4: Launching headless browser..." }] });

        // Dynamic import of playwright
        let playwright: any;
        try {
          playwright = await import(REPO_ROOT + "/node_modules/playwright/index.mjs");
        } catch {
          try {
            playwright = await import("playwright");
          } catch {
            wasmSrv.kill();
            assetSrv.kill();
            return {
              content: [{ type: "text", text: "❌ `playwright` package not installed. Run: npm install playwright && npx playwright install chromium" }],
              isError: true,
            };
          }
        }

        const browserArgs = [
          "--enable-features=SharedArrayBuffer",
          "--autoplay-policy=no-user-gesture-required",
          "--enable-webgl",
          "--enable-unsafe-swiftshader",
          "--ignore-gpu-blocklist",
          "--disable-gpu-sandbox",
        ];

        if (headless) {
          browserArgs.push("--use-gl=angle", "--use-angle=swiftshader");
        }

        const browser = await playwright.chromium.launch({
          headless: headless ? true : false,
          args: browserArgs,
        });

        browserCleanup = () => { try { browser.close(); } catch { /* ok */ } };

        const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });

        // Collect page errors
        const pageErrors: string[] = [];
        page.on("pageerror", (err: Error) => pageErrors.push(err.message));

        // Build URL
        const srcUrl = `http://localhost:${assetPort}/`;
        let pageUrl = `http://localhost:${wasmPort}/${game.html}?src=${encodeURIComponent(srcUrl)}`;
        if (autostart) pageUrl += "&autostart=1";

        await page.goto(pageUrl, { waitUntil: "networkidle", timeout: 120_000 });

        // ── Step 4: Wait and screenshot ──
        onUpdate?.({ content: [{ type: "text", text: `Step 4/4: Waiting ${waitMs}ms and capturing screenshot...` }] });
        await page.waitForTimeout(waitMs);

        const screenshotPath = buildDir(`${target}-screenshot.png`);
        await page.screenshot({ path: screenshotPath, fullPage: false });

        // Check pixel diversity
        const stats = await page.evaluate(() => {
          const canvas = document.getElementById("canvas") as HTMLCanvasElement | null;
          if (!canvas) return { error: "no canvas element" };
          const ctx = canvas.getContext("2d");
          if (!ctx) return { error: "no 2d context" };
          const { width: w, height: h } = canvas;
          const data = ctx.getImageData(0, 0, w, h).data;
          let nonBlack = 0;
          for (let i = 0; i < data.length; i += 4) {
            if (data[i] > 15 || data[i + 1] > 15 || data[i + 2] > 15) nonBlack++;
          }
          return {
            width: w, height: h,
            totalPixels: w * h,
            nonBlackPixels: nonBlack,
            fillPercent: Math.round(nonBlack / (w * h) * 100),
          };
        });

        const status = await page.locator("#status-line").textContent().catch(() => "(unknown)");
        await browser.close();
        browserCleanup = null;

        // Build result message
        const lines: string[] = [];
        lines.push(`✅ ${game.name} screenshot saved to \`${screenshotPath}\``);
        lines.push(`   Page status: "${status}"`);
        if (stats && "fillPercent" in stats) {
          lines.push(`   Canvas: ${stats.width}×${stats.height}, ${stats.fillPercent}% non-black pixels`);
        }
        if (pageErrors.length > 0) {
          lines.push(`   ⚠️ ${pageErrors.length} page error(s): ${pageErrors.slice(0, 3).join("; ")}`);
        }

        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details: { screenshotPath, stats, pageErrors, status },
        };

      } catch (e: any) {
        return {
          content: [{ type: "text", text: `❌ Screenshot failed: ${e.message}` }],
          isError: true,
        };
      } finally {
        wasmSrv.kill();
        assetSrv.kill();
        browserCleanup?.();
      }
    },
  });

  // ── Tool: run_e2e_test ──────────────────────────────────────────────────

  pi.registerTool({
    name: "run_e2e_test",
    label: "Run E2E Test",
    description:
      "Run a Playwright e2e test spec against the WASM build. " +
      "Starts Xvfb, WASM server, runs the test, and cleans up.",
    promptSnippet: "Run a Playwright e2e test spec against the WASM build",
    promptGuidelines: [
      "Use run_e2e_test to run regression tests or specific e2e specs",
      "The test file path is relative to the repo root (e.g., e2e/regression/T1-ra-wasm-boot.spec.ts)",
    ],
    parameters: Type.Object({
      spec: Type.String({ description: "Test spec file path (e.g. e2e/regression/T1-ra-wasm-boot.spec.ts)" }),
      args: Type.Optional(
        Type.Array(Type.String(), { default: [], description: "Additional Playwright args (e.g. --grep, --headed)" })
      ),
      wasmPort: Type.Optional(Type.Number({ default: 8080, description: "Port for WASM server" })),
      xvfbDisplay: Type.Optional(Type.String({ default: ":99", description: "Xvfb display number" })),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const spec = params.spec;
      const extraArgs = params.args ?? [];
      const wasmPort = params.wasmPort ?? 8080;
      const xvfbDisplay = params.xvfbDisplay ?? ":99";
      const specPath = repoPath(spec);

      if (!fs.existsSync(specPath)) {
        return {
          content: [{ type: "text", text: `❌ Test spec not found: ${specPath}` }],
          isError: true,
        };
      }

      // Ensure WASM HTML exists
      if (!fs.existsSync(buildDir("ra.html")) && !fs.existsSync(buildDir("td.html"))) {
        return {
          content: [{ type: "text", text: "❌ No WASM builds found in build-wasm/. Build first with wasm_build." }],
          isError: true,
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Starting Xvfb, WASM server, and running test..." }] });

      // Source the helper scripts via bash -c
      const runner = repoPath("scripts", "skill-run-e2e.sh");
      const cmd = `bash '${runner}' '${spec}' ${extraArgs.join(" ")}`;
      const result = run("bash", ["-c", cmd], { timeout: 600_000 });

      if (result.exitCode === 0) {
        return {
          content: [{ type: "text", text: `✅ E2E test passed: ${spec}\n${result.stdout}` }],
        };
      } else {
        return {
          content: [{ type: "text", text: `❌ E2E test failed (exit ${result.exitCode}): ${spec}\n${result.stderr || result.stdout}` }],
          isError: true,
        };
      }
    },
  });

  // ── Tool: toolchain_check ──────────────────────────────────────────────
  // From: skills/native-build §0

  pi.registerTool({
    name: "toolchain_check",
    label: "Toolchain Check",
    description: "Verify that the native build toolchain (clang++, cmake, ninja, SDL2, etc.) is installed and meets version requirements. Auto-wraps in nix develop if needed.",
    promptSnippet: "Check that Clang, CMake, Ninja, SDL2, and Python are all present for native builds",
    promptGuidelines: [
      "Use toolchain_check before attempting a native build to catch missing dependencies early",
      "Runs scripts/toolchain-check.sh which checks clang++, cmake >=3.20, ninja, python3, pkg-config, SDL2",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId: string, _params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      onUpdate?.({ content: [{ type: "text", text: "Checking native build toolchain..." }] });
      const script = repoPath("scripts", "toolchain-check.sh");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ Helper script not found: ${script}` }], isError: true };
      }
      const result = run("bash", [script], { timeout: 30_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ All native build prerequisites are installed.
${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Some prerequisites are missing (exit ${result.exitCode}):
${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: native_build ──────────────────────────────────────────────────
  // From: skills/native-build §3

  pi.registerTool({
    name: "build_native",
    label: "Native Build",
    description: "Build Red Alert and/or Tiberian Dawn native Linux targets with cmake + ninja (Clang).",
    promptSnippet: "Build the native Linux binary for Red Alert and/or Tiberian Dawn",
    promptGuidelines: [
      "Use native_build to compile the native Linux port (not WASM)",
      "Run toolchain_check first if you're unsure about prerequisites",
      "The native smoke tests require game data and Xvfb",
    ],
    parameters: Type.Object({
      target: Type.Union(
        [Type.Literal("ra"), Type.Literal("td"), Type.Literal("both")],
        { default: "both", description: "Native target to build" }
      ),
      compiler: Type.Optional(
        Type.Literal("clang"), { default: "clang", description: "Compiler to use (clang only)" }
      ),
      clean: Type.Optional(
        Type.Boolean({ default: false, description: "Reconfigure from scratch" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const target: Target = (params.target as Target) ?? "both";
      const compiler = params.compiler ?? "clang";
      const clean = params.clean ?? false;
      const buildDirNative = repoPath("build");

      if (!hasTool("cmake")) {
        return { content: [{ type: "text", text: "❌ cmake not found. Install build prerequisites first." }], isError: true };
      }

      if (clean && fs.existsSync(buildDirNative)) {
        onUpdate?.({ content: [{ type: "text", text: "Cleaning native build directory..." }] });
        fs.rmSync(buildDirNative, { recursive: true, force: true });
      }

      // Configure
      if (!fs.existsSync(buildDirNative) || clean) {
        onUpdate?.({ content: [{ type: "text", text: "Configuring with cmake --preset linux-native..." }] });
        const cfg = run("cmake", ["--preset", "linux-native"], { timeout: 120_000 });
        if (cfg.exitCode !== 0) {
          return { content: [{ type: "text", text: `❌ cmake configure failed:
${cfg.stderr || cfg.stdout}` }], isError: true };
        }
      }

      // Build targets
      const targets = target === "both" ? ["ra", "td"] : [target];
      const results: string[] = [];

      for (const t of targets) {
        onUpdate?.({ content: [{ type: "text", text: `Building ${t} native target...` }] });
        const b = run("cmake", ["--build", buildDirNative, "--target", t, "--parallel"], { timeout: 600_000 });
        if (b.exitCode === 0) {
          const binPath = repoPath("build", t);
          const size = fs.existsSync(binPath) ? `${Math.round(fs.statSync(binPath).size / 1024)} KB` : "?";
          results.push(`✅ ${t} — ${size}`);
        } else {
          results.push(`❌ ${t} failed:\n${b.stderr || b.stdout}`);
        }
      }

      return { content: [{ type: "text", text: results.join("\n") }] };
    },
  });

  // ── Tool: wasm_validate ─────────────────────────────────────────────────
  // From: skills/ci-cd §2.5, skills/emscripten §8

  pi.registerTool({
    name: "wasm_validate",
    label: "Validate WASM",
    description: "Validate WASM binaries (magic bytes \\x00asm, size > 1MB) for both RA and TD targets.",
    promptSnippet: "Validate that WASM binaries have correct magic bytes and reasonable size",
    promptGuidelines: [
      "Use wasm_validate after building to catch corrupt or truncated WASM binaries",
      "Checks: magic header must be \\x00asm and file must be > 1MB",
    ],
    parameters: Type.Object({
      target: Type.Optional(
        Type.Union([Type.Literal("ra"), Type.Literal("td"), Type.Literal("both")], { default: "both" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const target = (params.target ?? "both") as Target;
      const targets = target === "both" ? ["ra", "td"] : [target];
      const results: string[] = [];
      let allPassed = true;

      for (const t of targets) {
        const wasmFile = buildDir(`${t}.wasm`);
        if (!fs.existsSync(wasmFile)) {
          results.push(`❌ ${t}.wasm — not found`);
          allPassed = false;
          continue;
        }
        const buf = fs.readFileSync(wasmFile);
        const magic = buf.subarray(0, 4).toString("binary");
        const size = buf.length;
        const magicOk = magic === "\x00asm";
        const sizeOk = size > 1_000_000;

        if (magicOk && sizeOk) {
          results.push(`✅ ${t}.wasm — ${Math.round(size / 1024)} KB, valid`);
        } else {
          results.push(`❌ ${t}.wasm — ${Math.round(size / 1024)} KB, ` +
            `${magicOk ? "" : "invalid magic"}${!magicOk && !sizeOk ? ", " : ""}${sizeOk ? "" : "too small (< 1MB)"}`);
          allPassed = false;
        }
      }

      return {
        content: [{ type: "text", text: results.join("\n") }],
        isError: !allPassed,
      };
    },
  });

  // ── Tool: data_verify ───────────────────────────────────────────────────
  // From: skills/parity-comparison §0

  pi.registerTool({
    name: "data_verify",
    label: "Verify Game Data",
    description: "Verify game data integrity by running MIX checksum verification on a game data directory.",
    promptSnippet: "Verify game data MIX files have correct checksums",
    promptGuidelines: [
      "Use data_verify to check that game data isn't corrupt before running comparisons",
      "If data_verify fails, the game data is from a different release or corrupt — visual parity results would be invalid",
    ],
    parameters: Type.Object({
      dir: Type.Optional(
        Type.String({ description: "Game data directory to verify (defaults to RA CD1)" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const dataDir = params.dir ?? RA_ASSETS_DEFAULT;

      if (!fs.existsSync(dataDir)) {
        return { content: [{ type: "text", text: `❌ Directory not found: ${dataDir}` }], isError: true };
      }

      const script = repoPath("scripts", "ra-data-verify.py");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ Verification script not found: ${script}` }], isError: true };
      }

      onUpdate?.({ content: [{ type: "text", text: `Verifying MIX checksums in ${dataDir}...` }] });
      const result = run("python3", [script, dataDir], { timeout: 120_000 });

      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Game data verified OK at ${dataDir}\n${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Data verification failed (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: wine_check ────────────────────────────────────────────────────
  // From: skills/wine-testing §0

  pi.registerTool({
    name: "wine_check",
    label: "Wine Check",
    description: "Check that Wine (with 32-bit support), xdotool, ffmpeg, and ImageMagick are installed for Wine OG baseline testing.",
    promptSnippet: "Check that Wine and related tools are installed for OG baseline comparison",
    promptGuidelines: [
      "Use wine_check before wine_capture to verify Wine OG environment",
      "Wine is needed for capturing baseline screenshots from original Win32 executables",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId: string, _params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      onUpdate?.({ content: [{ type: "text", text: "Checking Wine environment..." }] });
      const script = repoPath("scripts", "wine-check.sh");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ Helper script not found: ${script}` }], isError: true };
      }
      const result = run("bash", [script], { timeout: 30_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Wine environment is ready.\n${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Some Wine prerequisites are missing (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: wine_capture ──────────────────────────────────────────────────
  // From: skills/wine-testing §3

  pi.registerTool({
    name: "capture_wine",
    label: "Wine Capture",
    description: "Capture Wine OG baseline screenshots (title screen) for Red Alert or Tiberian Dawn under Xvfb. Requires Wine, game data, and the original EXE. Note: title→menu transition requires a GPU GL context — under Xvfb the menu screenshot will match the title screen.",
    promptSnippet: "Capture baseline screenshots from original Wine RA95.EXE or C&C95.EXE",
    promptGuidelines: [
      "Use wine_capture to generate reference screenshots for visual parity comparison",
      "Requires the original Win32 EXE (RA95.EXE or C&C95.EXE) and game data",
      "Screenshots are saved to e2e/screenshots/wine-{game}-title.png and wine-{game}-menu.png",
      "Run wine_check first to verify prerequisites",
      "Wine 11.0 (wow64) requires the stub THIPX32.DLL from tools/stub-thipx/",
      "Title→menu transition fails without GL context — only title screen is captured",
    ],
    parameters: Type.Object({
      game: Type.Union(
        [Type.Literal("ra"), Type.Literal("td")],
        { default: "ra", description: "Game to capture" }
      ),
      dataDir: Type.Optional(
        Type.String({ description: "Game data directory (overrides default asset path)" })
      ),
      exePath: Type.Optional(
        Type.String({ description: "Path to the Win32 EXE (RA95.EXE or C&C95.EXE)" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const game = (params.game ?? "ra") as Game;
      const dataDir = params.dataDir;
      const exePath = params.exePath;

      const script = game === "ra"
        ? repoPath("scripts", "wine-ra.sh")
        : repoPath("scripts", "wine-td.sh");

      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ Script not found: ${script}` }], isError: true };
      }

      // Check Wine
      if (!hasTool("wine")) {
        return { content: [{ type: "text", text: "❌ wine not found in PATH. Run wine_check for details." }], isError: true };
      }

      onUpdate?.({ content: [{ type: "text", text: `Capturing ${GAMES[game].name} Wine OG screenshots (this takes ~30s)...` }] });

      const args: string[] = [];
      if (exePath) args.push(exePath);
      if (dataDir) args.push(dataDir);

      const result = run("bash", [script, ...args], { timeout: 120_000 });

      if (result.exitCode === 0) {
        const titleShot = repoPath("e2e", "screenshots", `wine-${game}-title.png`);
        const menuShot = repoPath("e2e", "screenshots", `wine-${game}-menu.png`);
        const lines: string[] = [];
        lines.push(`✅ ${GAMES[game].name} Wine OG screenshots captured`);
        if (fs.existsSync(titleShot)) lines.push(`   Title: ${titleShot} (${Math.round(fs.statSync(titleShot).size / 1024)} KB)`);
        if (fs.existsSync(menuShot)) lines.push(`   Menu:  ${menuShot} (${Math.round(fs.statSync(menuShot).size / 1024)} KB)`);
        return { content: [{ type: "text", text: lines.join("\n") }] };
      } else if (result.exitCode === 2) {
        return { content: [{ type: "text", text: `⏭️ Wine capture skipped (exit 2): EXE or data not found.\n${result.stderr || result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Wine capture failed (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: parity_compare ────────────────────────────────────────────────
  // From: skills/parity-comparison §2.3

  pi.registerTool({
    name: "parity_compare",
    label: "Parity Compare",
    description: "Run SSIM comparison between two screenshot images using parity-compare.py. Useful for WASM vs Wine OG visual regression testing.",
    promptSnippet: "Compare two screenshots using SSIM structural similarity",
    promptGuidelines: [
      "Use parity_compare to check visual parity between WASM/Linux output and Wine OG baseline",
      "SSIM >= 0.90 is considered passing",
      "The diff output PNG highlights regions that differ between the two images",
    ],
    parameters: Type.Object({
      imageA: Type.String({ description: "Path to first image (e.g. Wine OG baseline)" }),
      imageB: Type.String({ description: "Path to second image (e.g. WASM screenshot)" }),
      label: Type.Optional(Type.String({ description: "Label for the comparison result" })),
      thresholdSsim: Type.Optional(
        Type.Number({ default: 0.90, description: "SSIM pass/fail threshold (0–1)" })
      ),
      diffOut: Type.Optional(
        Type.String({ description: "Path to write the diff visualization PNG" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const imgA = repoPath(params.imageA);
      const imgB = repoPath(params.imageB);
      const label = params.label ?? "parity";
      const thresholdSsim = params.thresholdSsim ?? 0.90;
      const diffOut = params.diffOut ? repoPath(params.diffOut) : undefined;

      if (!fs.existsSync(imgA)) return { content: [{ type: "text", text: `❌ Image not found: ${imgA}` }], isError: true };
      if (!fs.existsSync(imgB)) return { content: [{ type: "text", text: `❌ Image not found: ${imgB}` }], isError: true };

      const script = repoPath("scripts", "parity-compare.py");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ parity-compare.py not found` }], isError: true };
      }

      const args = [script, imgA, imgB, "--label", label, "--threshold-ssim", String(thresholdSsim)];
      if (diffOut) args.push("--diff-out", diffOut);

      onUpdate?.({ content: [{ type: "text", text: `Comparing ${path.basename(imgA)} vs ${path.basename(imgB)}...` }] });
      const result = run("python3", args, { timeout: 60_000 });

      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ ${label}: SSIM >= ${thresholdSsim} — PASS\n${result.stdout}` }] };
      } else if (result.exitCode === 1) {
        return { content: [{ type: "text", text: `❌ ${label}: SSIM < ${thresholdSsim} — FAIL\n${result.stderr || result.stdout}` }], isError: true };
      } else {
        return { content: [{ type: "text", text: `⏭️ ${label}: SKIP (exit ${result.exitCode})\n${result.stderr || result.stdout}` }] };
      }
    },
  });

  // ── Tool: vqa_pixel_diff ────────────────────────────────────────────────
  // From: skills/vqa-codec §0

  pi.registerTool({
    name: "vqa_pixel_diff",
    label: "VQA Pixel Diff",
    description: "Run the synthetic VQA pixel-diff gate against a test VQA file or game VQA data. Compares our decoder against ffmpeg's.",
    promptSnippet: "Run VQA codec pixel-diff test against the synthetic test VQA or game VQAs",
    promptGuidelines: [
      "Use vqa_pixel_diff to verify the VQA decoder produces correct output",
      "The synthetic test (no game data needed) uses e2e/goldens/vqa/test.vqa",
      "For full game VQA verification, point at a MAIN.MIX or CONQUER.MIX file",
    ],
    parameters: Type.Object({
      mode: Type.Optional(
        Type.Union(
          [Type.Literal("synthetic"), Type.Literal("cinematic")],
          { default: "synthetic", description: "'synthetic' = test.vqa (no data needed), 'cinematic' = full game VQA scan" }
        )
      ),
      mixPath: Type.Optional(
        Type.String({ description: "Path to MIX file for cinematic mode (e.g. MAIN.MIX)" })
      ),
      threshold: Type.Optional(
        Type.Number({ default: 8, description: "p99 pixel diff threshold" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const mode = params.mode ?? "synthetic";
      const threshold = params.threshold ?? 8;

      if (mode === "synthetic") {
        const script = repoPath("scripts", "vqa-pixel-diff.py");
        const testVqa = repoPath("e2e", "goldens", "vqa", "test.vqa");
        if (!fs.existsSync(script)) return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
        if (!fs.existsSync(testVqa)) return { content: [{ type: "text", text: `❌ ${testVqa} not found` }], isError: true };

        onUpdate?.({ content: [{ type: "text", text: "Running synthetic VQA pixel-diff gate..." }] });
        const args = [script, testVqa, "--frames", "0,1,2", "--threshold", String(threshold)];
        const result = run("python3", args, { timeout: 60_000 });

        if (result.exitCode === 0) return { content: [{ type: "text", text: `✅ Synthetic VQA pixel-diff PASS\n${result.stdout}` }] };
        else return { content: [{ type: "text", text: `❌ Synthetic VQA pixel-diff FAIL (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };

      } else {
        // Cinematic mode — run full game VQA comparison
        const mixPath = params.mixPath ?? repoPath("scripts", "..", RA_ASSETS_DEFAULT, "MAIN.MIX");
        const resolvedMix = repoPath(mixPath);
        if (!fs.existsSync(resolvedMix)) {
          return { content: [{ type: "text", text: `❌ MIX file not found: ${resolvedMix}` }], isError: true };
        }

        const script = repoPath("scripts", "cinematic-compare.py");
        if (!fs.existsSync(script)) return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };

        onUpdate?.({ content: [{ type: "text", text: `Running cinematic VQA comparison against ${path.basename(resolvedMix)}...` }] });
        const result = run("python3", [script, resolvedMix, "--threshold", String(threshold)], { timeout: 300_000 });

        if (result.exitCode === 0) return { content: [{ type: "text", text: `✅ Cinematic VQA comparison PASS\n${result.stdout}` }] };
        else return { content: [{ type: "text", text: `❌ Cinematic VQA comparison FAIL (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: lint_lp64 ─────────────────────────────────────────────────────
  // Wraps: scripts/lint-lp64.py

  pi.registerTool({
    name: "lint_lp64",
    label: "LP64 Audit",
    description:
      "Scan C++ source for LP64 portability hazards: long→4-byte assumptions, _lrotl misuse, " +
      "pointer-to-int casts, and packed-struct field width mismatches. " +
      "Exit 0 = clean, non-zero = hazards found.",
    promptSnippet: "Run LP64 static analysis — must be clean after any struct/typedef/binary-I/O change",
    promptGuidelines: [
      "Run lint_lp64 after every change that touches struct layouts, typedefs, or ReadFile/WriteFile calls — LP64 bugs produce silent corruption, not compile errors",
      "lint_lp64 --errors-only flags E1-E4 must-fix hazards; the full scan includes warnings that may be benign (known exclusions in the C++ decoder stubs)",
    ],
    parameters: Type.Object({
      errorsOnly: Type.Optional(
        Type.Boolean({ default: true, description: "Only show E1-E4 errors, skip warnings" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, _onUpdate: any, _ctx: any) {
      const errorsOnly = params.errorsOnly ?? true;
      const script = repoPath("scripts", "lint-lp64.py");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
      }
      const args = [script];
      if (errorsOnly) args.push("--errors-only");
      const result = run("python3", args, { timeout: 120_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ LP64 audit — clean\n${result.stdout.trim() || "(no output)"}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ LP64 hazards found (exit ${result.exitCode}):\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: generate_include_shim ─────────────────────────────────────────
  // Wraps: scripts/generate-include-shim.py

  pi.registerTool({
    name: "include_shim",
    label: "Generate Include Shim",
    description:
      "Regenerate the case-folding include shim (build/include-shim/) after adding a new " +
      "#include directive or creating a new header file. Linux is case-sensitive; the shim " +
      "creates lower-cased symlinks so mixed-case #include \"FUNCTION.H\" resolves.",
    promptSnippet: "Regenerate case-folding symlinks after adding any new #include or header file",
    promptGuidelines: [
      "Run generate_include_shim after adding a #include to any .CPP file or creating a new header — without it the build fails with 'file not found' on Linux",
      "The shim is not committed; it is regenerated by CMake at configure time, but running it manually avoids a full reconfigure",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId: string, _params: any, _signal: AbortSignal | undefined, _onUpdate: any, _ctx: any) {
      const script = repoPath("scripts", "generate-include-shim.py");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
      }
      const result = run("python3", [script, "--repo-root", REPO_ROOT, "--shim-root", repoPath("build", "include-shim"), "--quiet"], { timeout: 60_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Include shim regenerated in build/include-shim/` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Shim generation failed:\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: ci_local ──────────────────────────────────────────────────────
  // Wraps: scripts/ci-local.sh

  pi.registerTool({
    name: "ci_local",
    label: "Run Local CI",
    description:
      "Run all available CI gates locally (native build, LP64 audit, WASM build+validate, " +
      "WASM smoke, VQA pixel-diff, include shim). Auto-skips gates with missing deps. " +
      "One-command pre-push verification. Runs each gate via its corresponding skill script.",
    promptSnippet: "Run all CI gates locally — pre-push sanity check with auto-skip for missing deps",
    promptGuidelines: [
      "Run ci_local before pushing to catch regressions across native build, WASM build, LP64 audit, and smoke tests",
      "ci_local auto-skips gates whose dependencies are missing (e.g., no emcmake = WASM gates skipped), so it's safe to run on any machine",
    ],
    parameters: Type.Object({
      mode: Type.Optional(
        Type.Union(
          [Type.Literal("all"), Type.Literal("wasm-only"), Type.Literal("native-only")],
          { default: "all", description: "Which gates to run" }
        )
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const script = repoPath("scripts", "ci-local.sh");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
      }
      const mode = params.mode ?? "all";
      const flag = mode === "wasm-only" ? "--wasm-only" : mode === "native-only" ? "--native-only" : "";

      onUpdate?.({ content: [{ type: "text", text: `Running local CI (${mode})...` }] });
      const args = [script];
      if (flag) args.push(flag);
      const result = run("bash", args, { timeout: 600_000 });

      // Strip the nix banner from stdout (ci-local.sh re-execs via nix develop)
      const nixBannerEnd = result.stdout.indexOf("=== CI-Local ===");
      const cleanStdout = nixBannerEnd >= 0 ? result.stdout.slice(nixBannerEnd) : result.stdout;

      // Filter stderr: only show non-banner lines (ignore nix build log noise)
      const cleanStderr = result.stderr
        .split("\n")
        .filter(l => !l.includes("Git tree") && !l.includes("C&C Red Alert") && !l.includes("Workflows"))
        .join("\n")
        .trim();

      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Local CI passed (${mode})\n${cleanStdout}` }] };
      } else {
        const extra = cleanStderr ? `\n(stderr: ${cleanStderr})` : "";
        return { content: [{ type: "text", text: `❌ Local CI failed (exit ${result.exitCode}):\n${cleanStdout}${extra}` }], isError: true };
      }
    },
  });

  // ── Tool: gen_vqa_golden ────────────────────────────────────────────────
  // Wraps: scripts/gen-vqa-golden.py

  pi.registerTool({
    name: "vqa_golden",
    label: "Generate VQA Golden Frames",
    description:
      "Decode a VQA file into N evenly-spaced golden PNG frames for visual reference. " +
      "Output goes to e2e/goldens/vqa/<stem>/. Used to establish reference frames for codec testing.",
    promptSnippet: "Generate evenly-spaced golden PNG frames from a VQA file for codec testing reference",
    promptGuidelines: [
      "Use gen_vqa_golden when you need reference frames from a VQA file for visual inspection or as input to parity-compare",
      "The frames are evenly spaced across the full duration — N=4 gives frames at 0%, 33%, 66%, 100% of the playback",
    ],
    parameters: Type.Object({
      vqaPath: Type.String({ description: "Path to the .VQA file" }),
      numFrames: Type.Optional(
        Type.Number({ default: 4, description: "Number of evenly-spaced frames to extract" })
      ),
      outDir: Type.Optional(
        Type.String({ description: "Output directory (defaults to e2e/goldens/vqa/<stem>/)" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, _onUpdate: any, _ctx: any) {
      const vqaPath = repoPath(params.vqaPath);
      const numFrames = params.numFrames ?? 4;
      const outDir = params.outDir;

      if (!fs.existsSync(vqaPath)) {
        return { content: [{ type: "text", text: `❌ VQA file not found: ${vqaPath}` }], isError: true };
      }

      const script = repoPath("scripts", "gen-vqa-golden.py");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
      }

      const args = [script, vqaPath, String(numFrames)];
      if (outDir) args.push(outDir);

      const result = run("python3", args, { timeout: 120_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Golden frames generated from ${path.basename(vqaPath)}\n${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Golden frame generation failed:\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: parity_report ─────────────────────────────────────────────────
  // Wraps: scripts/parity-report.sh

  pi.registerTool({
    name: "parity_report",
    label: "Parity Report",
    description:
      "Run a three-way SSIM parity report comparing golden frames against captures from " +
      "Wine OG, WASM, and/or native Linux targets. Supports both VQA (multi-frame) and " +
      "gameplay (single-frame) modes. Output is structured per-target SSIM results.",
    promptSnippet: "Generate three-way SSIM parity report — Wine vs WASM vs native for a scene",
    promptGuidelines: [
      "Use parity_report when you need a structured SSIM comparison across multiple targets for a specific scene (VQA or gameplay mission)",
      "The report requires pre-generated golden frames and target captures — run gen_vqa_golden, wine_capture, wasm_screenshot, or native_capture first",
    ],
    parameters: Type.Object({
      scene: Type.String({ description: "Scene name (e.g. 'ENGLISH', 'allied-l1', 'soviet-l1')" }),
      mode: Type.Optional(
        Type.Union(
          [Type.Literal("vqa"), Type.Literal("gameplay")],
          { default: "vqa", description: "Comparison mode" }
        )
      ),
      targets: Type.Optional(
        Type.String({ default: "wine,wasm,native", description: "Comma-separated target list" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const script = repoPath("scripts", "parity-report.sh");
      if (!fs.existsSync(script)) {
        return { content: [{ type: "text", text: `❌ ${script} not found` }], isError: true };
      }
      const scene = params.scene;
      const mode = params.mode ?? "vqa";
      const targets = params.targets ?? "wine,wasm,native";

      onUpdate?.({ content: [{ type: "text", text: `Generating ${mode} parity report for \"${scene}\"...` }] });
      const result = run("bash", [script, "--mode", mode, "--targets", targets, scene], { timeout: 120_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Parity report: ${scene}\n${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Parity report failed:\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: native_capture ────────────────────────────────────────────────
  // Wraps: scripts/native-capture.sh

  pi.registerTool({
    name: "capture_native",
    label: "Native Linux Capture",
    description:
      "Launch the native Linux binary under Xvfb, auto-start a campaign mission, and capture " +
      "a gameplay screenshot. Used to generate native Linux reference frames for three-way parity " +
      "comparison (Wine OG vs native vs WASM). Requires a native build in build/ra or build/td.",
    promptSnippet: "Capture a gameplay screenshot from the native Linux build under Xvfb",
    promptGuidelines: [
      "Use native_capture when you need a native Linux reference screenshot for three-way parity comparison alongside Wine OG and WASM captures",
      "The native build must exist in build/ra or build/td first — run native_build before capturing",
    ],
    parameters: Type.Object({
      mission: Type.String({ description: "Mission identifier (e.g. 'allied-l1', 'soviet-l1', 'gdi-m1', 'nod-l1')" }),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const mission = params.mission;
      onUpdate?.({ content: [{ type: "text", text: `Capturing native Linux gameplay for ${mission} via capture-checkpoint...` }] });
      const result = run("python3", [
        repoPath("scripts", "capture-checkpoint.py"), "mission", mission, "--targets", "native"
      ], { timeout: 120_000 });
      if (result.exitCode === 0) {
        return { content: [{ type: "text", text: `✅ Native capture: ${mission}\n${result.stdout}` }] };
      } else {
        return { content: [{ type: "text", text: `❌ Native capture failed:\n${result.stderr || result.stdout}` }], isError: true };
      }
    },
  });

  // ── Tool: edit_loop ────────────────────────────────────────────────────

  pi.registerTool({
    name: "edit_loop",
    label: "Edit Loop",
    description:
      "Run the full native edit-compile-test loop: include shim → LP64 lint → " +
      "native build → WASM smoke test.  Call this after editing source code.",
    promptSnippet: "Run the edit-compile-test loop: shim → lint → build → smoke",
    promptGuidelines: [
      "Call edit_loop after editing C++ source to catch regressions early — it runs the shim, LP64 audit, native build, and WASM smoke test in sequence",
      "The loop stops at the first failure so you can fix issues incrementally",
    ],
    parameters: Type.Object({
      target: Type.Optional(
        Type.Union([Type.Literal("native"), Type.Literal("wasm")], { default: "native", description: "Which loop to run" })
      ),
    }),
    async execute(_toolCallId: string, params: any, _signal: AbortSignal | undefined, onUpdate: any, _ctx: any) {
      const target = params.target ?? "native";

      if (target === "native") {
        onUpdate?.({ content: [{ type: "text", text: "=== Native edit loop: shim → lint → build → smoke ===" }] });

        const shim = run("python3", ["scripts/generate-include-shim.py", "--repo-root", REPO_ROOT, "--shim-root", repoPath("build", "include-shim"), "--quiet"], { timeout: 30_000 });
        if (shim.exitCode !== 0) return { content: [{ type: "text", text: `❌ shim failed:\n${shim.stderr}` }], isError: true };

        const lint = run("python3", ["scripts/lint-lp64.py", "--errors-only"], { timeout: 120_000 });
        if (lint.exitCode !== 0) return { content: [{ type: "text", text: `❌ LP64 lint failed:\n${lint.stderr || lint.stdout}` }], isError: true };

        const build = run("bash", ["scripts/build-native.sh"], { timeout: 600_000 });
        if (build.exitCode !== 0) return { content: [{ type: "text", text: `❌ Build failed:\n${build.stderr || build.stdout}` }], isError: true };

        onUpdate?.({ content: [{ type: "text", text: "Build OK. Running WASM smoke test..." }] });
        const test = run("bash", ["scripts/run-e2e.sh", "e2e/regression/T1-ra-wasm-boot.spec.ts"], { timeout: 300_000 });
        return test.exitCode === 0
          ? { content: [{ type: "text", text: `✅ Native edit loop: all passed\n${build.stdout}` }] }
          : { content: [{ type: "text", text: `❌ Smoke test failed:\n${test.stderr || test.stdout}` }], isError: true };

      } else {
        onUpdate?.({ content: [{ type: "text", text: "=== WASM loop: build → validate → smoke ===" }] });

        if (!hasTool("emcmake")) {
          return { content: [{ type: "text", text: "❌ emcmake not found. Run `nix develop` first." }], isError: true };
        }

        const cfg = run("emcmake", ["cmake", "--preset", "wasm"], { timeout: 120_000 });
        if (cfg.exitCode !== 0) return { content: [{ type: "text", text: `❌ cmake configure failed:\n${cfg.stderr}` }], isError: true };

        for (const t of ["ra", "td"]) {
          onUpdate?.({ content: [{ type: "text", text: `Building ${t}...` }] });
          const b = run("cmake", ["--build", BUILD_DIR, "--target", t, "--parallel"], { timeout: 600_000 });
          if (b.exitCode !== 0) return { content: [{ type: "text", text: `❌ ${t} build failed:\n${b.stderr}` }], isError: true };
        }

        onUpdate?.({ content: [{ type: "text", text: "Running WASM smoke tests..." }] });
        const test = run("bash", ["scripts/run-e2e.sh", "e2e/regression/T1-ra-wasm-boot.spec.ts", "e2e/regression/T2-td-wasm-boot.spec.ts"], { timeout: 300_000 });
        return test.exitCode === 0
          ? { content: [{ type: "text", text: "✅ WASM loop: all passed" }] }
          : { content: [{ type: "text", text: `❌ WASM smoke failed:\n${test.stderr || test.stdout}` }], isError: true };
      }
    },
  });

  // Log startup
  const tools = [
    "wasm_build", "serve_wasm", "serve_assets", "wasm_screenshot", "run_e2e_test",
    "toolchain_check", "native_build", "wasm_validate", "data_verify",
    "wine_check", "wine_capture", "parity_compare", "vqa_pixel_diff",
    "lint_lp64", "generate_include_shim", "ci_local", "gen_vqa_golden",
    "parity_report", "native_capture", "edit_loop",
  ];
  console.log(`[battlecontrol] Tools registered: ${tools.length} tools`);
  console.log(`[battlecontrol]   ${tools.join(", ")}`);
}
