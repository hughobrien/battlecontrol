{
  description = "Linux port of Command & Conquer: Red Alert (EA open-source release)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    wine-input.url = "path:./tools/wine-input";
    cnc-ddraw.url = "path:./tools/cnc-ddraw";
  };

  outputs = { self, nixpkgs, wine-input, cnc-ddraw }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};
      mkApp  = name: script: rec {
        type = "app";
        program = toString (pkgs.writeShellScript name script);
      };
    in {
      # -----------------------------------------------------------------------
      # packages.redalert  —  builds the redalert binary
      # -----------------------------------------------------------------------
      packages.${system} = rec {
        redalert = pkgs.stdenv.mkDerivation {
          pname   = "cnc-redalert";
          version = "unstable-2026-05-09";

          src = ./.;

          nativeBuildInputs = with pkgs; [ python3 ];
          buildInputs       = with pkgs; [ SDL2 SDL2.dev ];

          buildPhase = ''
            runHook preBuild

            SHIM="$PWD/build/include-shim"
            RA="$PWD/REDALERT"
            STUBS="$PWD/linux/win32-stubs"
            OBJS="$PWD/build/obj"
            mkdir -p "$OBJS/RA" "$OBJS/W32" "$OBJS/STUBS"

            python3 scripts/generate-include-shim.py \
              --repo-root "$PWD" --shim-root "$SHIM" --quiet

            CXXF="-std=c++17 -c -fno-strict-aliasing -w -O2 \
              -I$SHIM/redalert -I$SHIM/win32lib \
              -I$RA -I$RA/WIN32LIB -I$STUBS \
              -include $STUBS/msvc-compat.h"

            ok=0; fail=0
            obj_list=$(mktemp)

            compile() {
              local src=$1 obj=$2
              if g++ $CXXF "$src" -o "$obj"; then
                ok=$((ok+1)); echo "$obj" >> "$obj_list"
              else
                fail=$((fail+1)); echo "FAIL: $src" >&2
              fi
            }

            for src in "$RA"/*.CPP "$RA"/*.cpp; do
              [ -f "$src" ] || continue
              base=$(basename "$src")
              upper=$(echo "$base" | tr '[:lower:]' '[:upper:]')
              case "$upper" in DTABLE.CPP|ITABLE.CPP|LZWOTRAW.CPP|STUB.CPP) continue ;; esac
              stem=$(basename "$src" .cpp); stem=$(basename "$stem" .CPP)
              compile "$src" "$OBJS/RA/$stem.o"
            done

            for src in "$RA/WIN32LIB"/*.CPP "$RA/WIN32LIB"/*.cpp; do
              [ -f "$src" ] || continue
              stem=$(basename "$src" .cpp); stem=$(basename "$stem" .CPP)
              compile "$src" "$OBJS/W32/$stem.o"
            done

            for src in "$STUBS"/*.cpp; do
              [ -f "$src" ] || continue
              stem=$(basename "$src" .cpp)
              compile "$src" "$OBJS/STUBS/$stem.o"
            done

            echo "Compile: ok=$ok fail=$fail"
            [ "$fail" -eq 0 ] || { echo "Build failed"; exit 1; }

            g++ -no-pie $(cat "$obj_list" | tr '\n' ' ') -o redalert -lSDL2

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m755 redalert "$out/bin/redalert"
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description  = "Command & Conquer: Red Alert — native Linux port";
            longDescription = ''
              Native Linux port of Command & Conquer: Red Alert built from the
              EA GPL open-source release. Requires legally-acquired game data to run.
              See README for data setup instructions.
            '';
            license   = licenses.gpl3Plus;
            platforms = [ "x86_64-linux" ];
            mainProgram = "redalert";
          };
        };

        tiberiandawn = pkgs.stdenv.mkDerivation {
          pname   = "cnc-tiberiandawn";
          version = "unstable-2026-05-09";

          src = ./.;

          nativeBuildInputs = with pkgs; [ cmake ninja gcc python3 pkg-config ];
          buildInputs       = with pkgs; [ SDL2 SDL2.dev openal libx11 ];

          buildPhase = ''
            runHook preBuild
            cmake -S . -B build-td -G Ninja \
              -DCMAKE_BUILD_TYPE=RelWithDebInfo \
              -DCMAKE_CXX_FLAGS="-w"
            cmake --build build-td --target td --parallel
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m755 build-td/td "$out/bin/tiberiandawn"
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description  = "Command & Conquer: Tiberian Dawn — native Linux port";
            license   = licenses.gpl3Plus;
            platforms = [ "x86_64-linux" ];
            mainProgram = "tiberiandawn";
          };
        };

        default = redalert;
      };

      # -----------------------------------------------------------------------
      # devShells.default  —  nix develop
      # -----------------------------------------------------------------------
      devShells.${system}.default = (pkgs.mkShell.override { stdenv = pkgs.clangStdenv; }) {
        pure = true;
        nativeBuildInputs = with pkgs; [
          cmake
          gnumake
          ninja
          python3
          pkg-config
          emscripten  # WASM builds: emcmake cmake --preset wasm && cmake --build build-wasm --target ra
          # CI deps
          xvfb-run
          ffmpeg-headless
          ccache
          nodejs
          pnpm
          clang-tools
          cppcheck
          # Linting tools
          ruff
          shellcheck
          shfmt
          yamllint
          nixfmt
          uv
        ];

        buildInputs = with pkgs; [
          SDL2
          SDL2.dev
          SDL2_ttf
          openal
          libx11
          # Script deps (campaign captures, screenshots, etc.)
          openbox
          xdotool
          imagemagick
          curl
          wineWow64Packages.stable
        ];

        shellHook = ''
          export RA_ASSETS="''${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
          export TD_ASSETS="''${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"

          # Install git pre-commit hook for linting all staged files
          REPO_ROOT="''$(git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$REPO_ROOT" ] && [ ! -f "$REPO_ROOT/.git/hooks/pre-commit" ]; then
            HOOK="$REPO_ROOT/.git/hooks/pre-commit"
            cat > "$HOOK" << 'PREHOOK'
          #!/usr/bin/env bash
          set -euo pipefail
          ERRORS=0

          auto_fixer() { "$@" 2>/dev/null || true; }
          checker() { if ! "$@" 2>/dev/null; then ERRORS=$((ERRORS + 1)); fi; }

          # ── Phase 1: Auto-fixers (never block) ─────────────────────────
          PY_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.py$' || true)
          for f in $PY_STAGED; do auto_fixer ruff check --fix "$f"; done
          for f in $PY_STAGED; do auto_fixer ruff format "$f"; done

          SH_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sh$' || true)
          for f in $SH_STAGED; do auto_fixer shfmt -w "$f"; done

          # ── Phase 2: Checkers (block on failure) ────────────────────────
          echo "" && echo "=== Pre-commit linting ==="

          C_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(cpp|c|h|hpp)$' || true)
          for f in $C_STAGED; do checker python3 scripts/lint-lp64.py --dirs "$(dirname "$f")"; done
          for f in $C_STAGED; do checker clang-tidy -p build --quiet "$f"; done

          for f in $PY_STAGED; do checker ruff check "$f"; done

          YML_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.ya?ml$' || true)
          for f in $YML_STAGED; do checker yamllint "$f"; done

          for f in $SH_STAGED; do checker shellcheck "$f"; done

          NIX_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.nix$' || true)
          for f in $NIX_STAGED; do checker nixfmt --check "$f"; done

          if [ "$ERRORS" -gt 0 ]; then
            echo "" && echo "✗ $ERRORS lint error(s) — commit blocked. Re-stage auto-fixed files and retry."
            exit 1
          fi
          PREHOOK
            chmod +x "$HOOK"
            echo "Installed git pre-commit hook for linting"
          fi

          echo "C&C Red Alert — dev shell"
          echo ""
          echo "Workflows (from repo root):"
          echo "  nix run .#check              toolchain prerequisites"
          echo "  nix run .#build-native       native Linux build (ra/td/both)"
          echo "  nix run .#lint               LP64 hazard audit"
          echo "  nix run .#lint-all           LP64 + tidy + cppcheck + ruff + yamllint + shellcheck + nixfmt"
          echo "  nix run .#build-wasm         WASM build (ra/td/both)"
          echo "  nix run .#validate-wasm      WASM binary validation"
          echo "  nix run .#serve              both dev servers"
          echo "  nix run .#screenshot         capture WASM screenshot"
          echo "  nix run .#test -- <spec>     run an e2e test"
          echo "  nix run .#capture-wine       Wine OG baseline capture"
          echo "  nix run .#capture-native     Native Linux gameplay capture"
          echo "  nix run .#vqa-check          VQA pixel-diff gate"
          echo "  nix run .#vqa-golden         Generate golden frames from VQA"
          echo "  nix run .#compare -- a b     SSIM compare two screenshots"
          echo "  nix run .#verify             verify game data checksums"
          echo "  nix run .#smoke-ra           RA native smoke test"
          echo "  nix run .#smoke-td           TD native smoke test"
          echo "  nix run .#regression          Run regression suite"
          echo "  nix run .#report -- <scene>   Three-way parity report"
          echo "  nix run .#edit-loop   — shim→lint→build→smoke (native)"
          echo "  nix run .#wasm-loop   — build→validate→smoke (WASM)"
          echo "  nix run .#test-t1     — T1 RA boot smoke"
          echo "  nix run .#test-t2     — T2 TD boot smoke"
          echo "  nix run .#ci                 all local CI gates"
          echo "  nix run .#ci-build-native     CI: native build (gcc/clang)"
          echo "  nix run .#ci-vqa              CI: VQA pixel-diff gate"
          echo "  nix run .#ci-build-wasm       CI: WASM build + validate + smoke"
          echo "  nix run .#ci-clang-tidy       CI: clang-tidy static analysis"
          echo "  nix run .#ci-cppcheck         CI: cppcheck static analysis"
          echo ""
          echo "  nix run .#redalert           run Red Alert (needs RA data)"
          echo "  nix run .#tiberiandawn        run Tiberian Dawn (needs TD data)"
          echo "  nix build path:./tools/wine-input#ra-sendinput   build Wine SendInput helpers"
          echo "  nix build path:./tools/cnc-ddraw#cnc-ddraw       build cnc-ddraw ddraw.dll"
          echo ""
          echo "  or use the pi agent: 19 extension tools"
          echo ""
          echo "Quick start:"
          echo "  nix run .#check && nix run .#build-native"
        '';
      };

      # -----------------------------------------------------------------------
      # apps.redalert  —  nix run
      #
      # Run from your game-data directory, or set RA_ASSETS:
      #   cd /path/to/red-alert-data && nix run github:hughobrien/battlecontrol
      #   RA_ASSETS=/path/to/data   nix run github:hughobrien/battlecontrol
      # -----------------------------------------------------------------------
      apps.${system} = rec {
        redalert = {
          type    = "app";
          program = toString (pkgs.writeShellScript "run-redalert" ''
            set -e
            DATA_DIR="''${RA_ASSETS:-$PWD}"
            if [ ! -f "$DATA_DIR/MAIN.MIX" ] && [ ! -f "$DATA_DIR/main.mix" ]; then
              echo "ERROR: MAIN.MIX not found in $DATA_DIR"
              echo "  cd /path/to/red-alert-data && nix run"
              echo "  or set RA_ASSETS=/path/to/red-alert-data"
              exit 1
            fi
            cd "$DATA_DIR"
            exec ${self.packages.${system}.redalert}/bin/redalert "$@"
          '');
        };

        tiberiandawn = {
          type    = "app";
          program = toString (pkgs.writeShellScript "run-tiberiandawn" ''
            set -e
            DATA_DIR="''${TD_ASSETS:-$PWD}"
            if [ ! -f "$DATA_DIR/CONQUER.MIX" ] && [ ! -f "$DATA_DIR/conquer.mix" ]; then
              echo "ERROR: CONQUER.MIX not found in $DATA_DIR"
              echo "  cd /path/to/tiberian-dawn-data && nix run .#tiberiandawn"
              echo "  or set TD_ASSETS=/path/to/tiberian-dawn-data"
              exit 1
            fi
            cd "$DATA_DIR"
            exec ${self.packages.${system}.tiberiandawn}/bin/tiberiandawn "$@"
          '');
        };

        # -----------------------------------------------------------------------
        # apps.wasm-server  —  nix run .#wasm-server
        #
        # Serves build-wasm/ over HTTP with the COOP + COEP headers required for
        # SharedArrayBuffer (Emscripten pthreads / audio threading).
        #
        # Build the WASM bundle first:
        #   emcmake cmake --preset wasm && cmake --build build-wasm --target ra
        #
        # Then start the server:
        #   nix run .#wasm-server          # port 8080 (default)
        #   PORT=9090 nix run .#wasm-server
        #
        # Acceptance check:
        #   curl -I http://localhost:8080/ra.html | grep -E "opener-policy|embedder-policy"
        # -----------------------------------------------------------------------
        wasm-server = {
          type    = "app";
          program = toString (pkgs.writeShellScript "wasm-server" ''
            set -e
            WASM_DIR="''${WASM_DIR:-$PWD/build-wasm}"
            PORT="''${PORT:-8080}"

            if [ ! -f "$WASM_DIR/ra.html" ]; then
              echo "ERROR: $WASM_DIR/ra.html not found."
              echo "  Build the WASM bundle first:"
              echo "    emcmake cmake --preset wasm && cmake --build build-wasm --target ra"
              exit 1
            fi

            _NGINX_TMPDIR=$(mktemp -d)
            trap 'rm -rf "$_NGINX_TMPDIR"' EXIT

            # Write a self-contained nginx config into the tmpdir.
            # Paths must be absolute; nginx rejects relative root values.
            cat > "$_NGINX_TMPDIR/nginx.conf" <<NGINXCONF
            events { worker_connections 64; }
            http {
              include ${pkgs.nginx}/conf/mime.types;
              default_type application/octet-stream;
              add_header Cross-Origin-Opener-Policy  "same-origin"  always;
              add_header Cross-Origin-Embedder-Policy "require-corp" always;
              types { application/wasm wasm; }
              sendfile on;
              server {
                listen $PORT;
                server_name localhost;
                root $WASM_DIR;
                index ra.html;
                location / { try_files \$uri \$uri/ =404; }
              }
            }
            NGINXCONF

            echo "Serving WASM bundle at http://localhost:$PORT/ra.html"
            echo "  COOP + COEP headers enabled — SharedArrayBuffer available"
            echo "  Press Ctrl-C to stop."
            echo ""
            echo "  Verify headers:  curl -I http://localhost:$PORT/ra.html"

            ${pkgs.nginx}/bin/nginx \
              -c "$_NGINX_TMPDIR/nginx.conf" \
              -g "pid $_NGINX_TMPDIR/nginx.pid; error_log /dev/stderr; daemon off;"
          '');
        };

        default = redalert;

        # ── Developer workflow apps ────────────────────────────────────────
        # nix run .#<name> [args...]  from the repo root.

        check = mkApp "check-toolchain" ''
          exec bash scripts/skill-dev-check.sh
        '';

        build-native = mkApp "build-native" ''
          export CC=clang CXX=clang++
          exec bash scripts/skill-native-build.sh "$@"
        '';

        lint = mkApp "lint-lp64" ''
          exec python3 scripts/lint-lp64.py --errors-only
        '';

        lint-all = mkApp "lint-all" ''
          set -e
          echo "=== LP64 hazard audit ==="
          python3 scripts/lint-lp64.py --errors-only
          echo ""
          echo "=== clang-tidy ==="
          cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
          find REDALERT TIBERIANDAWN -type f \
            \! -path '*/WIN32LIB/*' \
            \( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
            | xargs -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 \
            | tee /tmp/clang-tidy-report.txt
          echo "$(grep -c 'warning:\|error:' /tmp/clang-tidy-report.txt 2>/dev/null || echo 0) clang-tidy finding(s)"
          echo ""
          echo "=== cppcheck ==="
          cppcheck --enable=warning,performance,portability,information \
            --suppress=missingIncludeSystem \
            --suppress=unmatchedSuppression \
            --inline-suppr --error-exitcode=0 \
            -j "$(nproc)" --quiet \
            -I REDALERT -I REDALERT/WIN32LIB \
            -I TIBERIANDAWN -I TIBERIANDAWN/WIN32LIB \
            -I linux/win32-stubs \
            REDALERT TIBERIANDAWN 2>&1 | tee /tmp/cppcheck-report.txt
          echo "$(grep -c 'error:\|warning:' /tmp/cppcheck-report.txt 2>/dev/null || echo 0) cppcheck finding(s)"
          echo ""
          echo "=== Python (ruff check + format) ==="
          ruff check scripts/ e2e/ wasm/ 2>&1 || true
          ruff format --check --diff scripts/ e2e/ wasm/ 2>&1 || true
          echo ""
          echo "=== YAML (yamllint) ==="
          yamllint .github/workflows/ 2>&1 || true
          echo ""
          echo "=== Shell (shellcheck + shfmt) ==="
          find scripts/ -name '*.sh' -exec shellcheck {} + 2>&1 || true
          find scripts/ -name '*.sh' -exec shfmt -d {} + 2>&1 || true
          echo ""
          echo "=== Nix (nixfmt) ==="
          find . -name '*.nix' -not -path './build/*' -exec nixfmt --check {} + 2>&1 || true
        '';

        shim = mkApp "generate-shim" ''
          exec python3 scripts/generate-include-shim.py \
            --repo-root . --shim-root build/include-shim --quiet
        '';

        build-wasm = mkApp "build-wasm" ''
          set -e
          TARGET="''${1:-both}"
          emcmake cmake --preset wasm
          for t in ra td; do
            [ "$TARGET" != "$t" ] && [ "$TARGET" != "both" ] && continue
            cmake --build build-wasm --target "$t" --parallel
          done
        '';

        validate-wasm = mkApp "validate-wasm" ''
          python3 -c "
import os, struct
for fn in ['build-wasm/ra.wasm', 'build-wasm/td.wasm']:
    if not os.path.exists(fn): continue
    with open(fn,'rb') as f:
        assert f.read(4) == b'\\x00asm', fn + ': bad magic'
    sz = os.path.getsize(fn)
    assert sz > 1_000_000, fn + ': too small (' + str(sz) + ' bytes)'
    print('  ' + fn.split('/')[1] + ': ' + str(sz//1024) + ' KB OK')
"
        '';

        serve-wasm = mkApp "serve-wasm" ''
          PORT="''${1:-8080}"
          exec python3 wasm/serve-coop.py "$PORT" build-wasm
        '';

        serve-assets = mkApp "serve-assets" ''
          GAME="''${1:-ra}"
          PORT="''${2:-9090}"
          if [ "$GAME" = "ra" ]; then
            exec python3 wasm/serve-assets.py "$RA_ASSETS" "$PORT"
          else
            exec python3 wasm/serve-assets.py "$TD_ASSETS" "$PORT"
          fi
        '';

        serve = mkApp "serve-both" ''
          WASM_PORT="''${1:-8080}"
          ASSET_PORT="''${2:-9090}"
          nix run .#serve-wasm "$WASM_PORT" &
          nix run .#serve-assets ra "$ASSET_PORT" &
          echo "WASM:   http://localhost:$WASM_PORT"
          echo "Assets: http://localhost:$ASSET_PORT"
          wait
        '';

        test-t1 = mkApp "test-t1" ''
          exec bash scripts/skill-run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
        '';

        test-t2 = mkApp "test-t2" ''
          exec bash scripts/skill-run-e2e.sh e2e/regression/T2-td-wasm-boot.spec.ts
        '';

        test = mkApp "run-e2e" ''
          if [ $# -eq 0 ]; then
            echo "Usage: nix run .#test -- <spec>"
            echo "  e.g. nix run .#test -- e2e/regression/T1-ra-wasm-boot.spec.ts"
            exit 1
          fi
          exec bash scripts/skill-run-e2e.sh "$@"
        '';

        screenshot = mkApp "screenshot" ''
          GAME="''${1:-ra}"
          python3 wasm/serve-coop.py 8080 build-wasm &
          if [ "$GAME" = "ra" ]; then
            python3 wasm/serve-assets.py "$RA_ASSETS" 9090 &
          else
            python3 wasm/serve-assets.py "$TD_ASSETS" 9090 &
          fi
          sleep 2
          npx playwright test e2e/wasm-smoke.spec.ts --grep "$GAME"
          kill %1 %2 2>/dev/null || true
        '';

        capture-wine = mkApp "capture-wine" ''
          GAME="''${1:-ra}"
          if [ "$GAME" = "ra" ]; then
            exec bash scripts/wine-ra.sh
          else
            exec bash scripts/wine-td.sh
          fi
        '';

        verify = mkApp "verify-data" ''
          DIR="''${1:-$RA_ASSETS}"
          exec python3 scripts/ra-data-verify.py "$DIR"
        '';

        compare = mkApp "parity-compare" ''
          if [ $# -lt 2 ]; then
            echo "Usage: nix run .#compare -- <imageA> <imageB> [threshold]"
            exit 1
          fi
          A="$1"; shift
          B="$1"; shift
          THRESH="''${1:-0.90}"
          exec python3 scripts/parity-compare.py "$A" "$B" \
            --label manual --threshold-ssim "$THRESH"
        '';

        vqa-check = mkApp "vqa-check" ''
          exec python3 scripts/vqa-pixel-diff.py \
            e2e/goldens/vqa/test.vqa --frames 0,1,2 --threshold 5
        '';

        vqa-cinematic = mkApp "vqa-cinematic" ''
          MIX="''${1:-$RA_ASSETS/MAIN.MIX}"
          THRESH="''${2:-8}"
          exec python3 scripts/cinematic-compare.py "$MIX" --threshold "$THRESH"
        '';

        ci = mkApp "ci-local" ''
          MODE="''${1:-all}"
          FLAG=""
          [ "$MODE" = "wasm-only" ] && FLAG="--wasm-only"
          [ "$MODE" = "native-only" ] && FLAG="--native-only"
          exec bash scripts/ci-local.sh $FLAG
        '';

        smoke-ra = mkApp "smoke-ra" ''
          exec bash scripts/first-run-pass-94.sh
        '';

        smoke-td = mkApp "smoke-td" ''
          exec bash scripts/run-td-cheat.sh
        '';

        capture-native = mkApp "capture-native" ''
          if [ $# -eq 0 ]; then
            echo "Usage: nix run .#capture-native -- <mission>"
            echo "  e.g. nix run .#capture-native -- allied-l1"
            exit 1
          fi
          exec bash scripts/native-capture.sh "$1"
        '';

        vqa-golden = mkApp "vqa-golden" ''
          if [ $# -lt 1 ]; then
            echo "Usage: nix run .#vqa-golden -- <vqa-file> [num-frames]"
            exit 1
          fi
          VQA="$1"; shift
          N="''${1:-4}"
          exec python3 scripts/gen-vqa-golden.py "$VQA" "$N"
        '';

        regression = mkApp "regression-suite" ''
          TIER="''${1:-ci}"
          exec env REGRESSION_TIER="$TIER" bash scripts/regression-suite.sh
        '';

        report = mkApp "parity-report" ''
          if [ $# -lt 1 ]; then
            echo "Usage: nix run .#report -- <scene> [mode] [targets]"
            echo "  e.g. nix run .#report -- ENGLISH --mode vqa --targets wine,wasm"
            exit 1
          fi
          SCENE="$1"; shift
          MODE="''${1:-vqa}"
          TARGETS="''${2:-wine,wasm,native}"
          exec bash scripts/parity-report.sh --mode "$MODE" --targets "$TARGETS" "$SCENE"
        '';

        # ── Iteration loop shorthands ──────────────────────────────────────

        edit-loop = mkApp "edit-loop" ''
          set -e
          echo "=== edit loop: shim → lint → build → smoke ==="
          nix run .#shim 2>/dev/null || true
          nix run .#lint 2>/dev/null || true
          nix run .#build-native
          nix run .#test -- e2e/regression/T1-ra-wasm-boot.spec.ts
        '';

        wasm-loop = mkApp "wasm-loop" ''
          set -e
          echo "=== WASM loop: build → validate → smoke ==="
          nix run .#build-wasm
          nix run .#validate-wasm
          nix run .#ci-wasm-smoke
        '';

        # ── CI Job Apps ────────────────────────────────────────────────────
        # These reproduce the GitHub Actions CI jobs.  Run locally with:
        #   nix run .#ci-build-native -- <gcc|clang>
        #   nix run .#ci-vqa
        #   nix run .#ci-wasm-smoke
        #
        # The GitHub Actions workflows in .github/workflows/ call these same
        # apps, making CI identical to local and trivially reproducible.
        # ------------------------------------------------------------------

        ci-build-native = mkApp "ci-build-native" ''
          set -e
          export CC=clang CXX=clang++
          cmake --preset linux-native
          cmake --build build --target ra --parallel
          cmake --build build --target td --parallel
          for bin in ra td; do
            path="build/$bin"
            if ! file "$path" 2>/dev/null | grep -q "ELF 64-bit"; then
              echo "ERROR: $bin: invalid or missing at $path"
              exit 1
            fi
            echo "$bin: $(stat -c%s "$path") bytes, ELF 64-bit"
          done
        '';

        ci-vqa = mkApp "ci-vqa-pixel-diff" ''
          set -e
          python3 scripts/gen_test_vqa.py e2e/goldens/vqa/test.vqa.new
          diff -q e2e/goldens/vqa/test.vqa e2e/goldens/vqa/test.vqa.new || {
            echo "ERROR: committed test.vqa differs from generator output"
            echo "Run: python3 scripts/gen_test_vqa.py e2e/goldens/vqa/test.vqa"
            exit 1
          }
          rm e2e/goldens/vqa/test.vqa.new
          python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa \
            --frames 0,1,2 --threshold 5
          if [ -f "build/run-172/MAIN.MIX" ]; then
            python3 scripts/vqa-pixel-diff.py build/run-172/MAIN.MIX \
              --frames 0,29,59 --threshold 5 --quiet
          else
            echo "SKIP: game VQA data absent"
          fi
        '';

        ci-wasm-smoke = mkApp "ci-wasm-smoke" ''
          set -e
          Xvfb :99 -screen 0 1280x1024x24 &
          XVFB_PID=$!
          sleep 2
          python3 wasm/serve-coop.py 8080 build-wasm &
          SERVER_PID=$!
          sleep 2
          DISPLAY=:99 npx playwright test \
            e2e/regression/T1-ra-wasm-boot.spec.ts \
            e2e/regression/T2-td-wasm-boot.spec.ts
          SMOKE_EXIT=$?
          kill $SERVER_PID 2>/dev/null || true
          kill $XVFB_PID 2>/dev/null || true
          exit $SMOKE_EXIT
        '';

        ci-build-wasm = mkApp "ci-build-wasm" ''
          set -e
          emcmake cmake --preset wasm
          cmake --build build-wasm --target ra --parallel
          cmake --build build-wasm --target td --parallel
          python3 -c "
import os, struct
MIN_SIZE = 1_000_000
for name in ('build-wasm/ra.wasm', 'build-wasm/td.wasm'):
    with open(name, 'rb') as f:
        magic = f.read(4)
    assert magic == b'\\x00asm', name + ': bad magic'
    size = os.path.getsize(name)
    assert size > MIN_SIZE, name + ': too small (' + str(size) + ' bytes < ' + str(MIN_SIZE) + ')'
    print(name + ': ' + str(size // 1024) + ' KB OK')
"
          nix run .#ci-wasm-smoke
        '';

        ci-clang-tidy = mkApp "ci-clang-tidy" ''
          set -e
          cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
          find REDALERT TIBERIANDAWN -type f \
            \! -path '*/WIN32LIB/*' \
            \( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
            | xargs -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 \
            | tee clang-tidy-report.txt
          echo "$(grep -c 'warning:\|error:' clang-tidy-report.txt 2>/dev/null || echo 0) finding(s)"
        '';

        ci-cppcheck = mkApp "ci-cppcheck" ''
          set -e
          cppcheck --enable=warning,performance,portability,information \
            --suppress=missingIncludeSystem \
            --suppress=unmatchedSuppression \
            --inline-suppr --error-exitcode=0 \
            -j "$(nproc)" --quiet \
            -I REDALERT -I REDALERT/WIN32LIB \
            -I TIBERIANDAWN -I TIBERIANDAWN/WIN32LIB \
            -I linux/win32-stubs \
            REDALERT TIBERIANDAWN 2>&1 | tee cppcheck-report.txt
          echo "$(grep -c 'error:\|warning:' cppcheck-report.txt 2>/dev/null || echo 0) finding(s)"
        '';
      };
    };
}
