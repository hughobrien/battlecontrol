{
  description = "Linux port of Command & Conquer: Red Alert (EA open-source release)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    wine-input.url = "path:./tools/wine-input";

    # Upstream: cnc-ddraw — DirectDraw wrapper for old Win32 games under Wine.
    # Source: https://github.com/FunkyFr3sh/cnc-ddraw
    # Built as a Win32 DLL (MinGW) in packages.${system}.cnc-ddraw
    cnc-ddraw = {
      url = "github:FunkyFr3sh/cnc-ddraw";
      flake = false;
    };

    # Allied CD ISO from archive.org — single source for all game assets.
    # Files are extracted via unar at build time.
    redalert-iso = {
      url = "https://archive.org/download/cnc-red-alert/redalert_allied.iso";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,

      wine-input,
      cnc-ddraw,
      redalert-iso,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkApp = name: script: rec {
        type = "app";
        program = toString (pkgs.writeShellScript name script);
      };
    in
    {
      # -----------------------------------------------------------------------
      # packages.redalert  —  builds the redalert binary
      # -----------------------------------------------------------------------
      packages.${system} =
        let
          p = self.packages.${system};
        in
        {
          redalert = pkgs.stdenv.mkDerivation {
            pname = "cnc-redalert";
            version = "unstable-2026-05-09";

            src = ./.;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              python3
              pkg-config
            ];
            buildInputs = with pkgs; [
              SDL2
              SDL2.dev
            ];

            buildPhase = ''
              runHook preBuild
              cmake -S . -B build-ra -G Ninja \
                -DCMAKE_BUILD_TYPE=RelWithDebInfo \
                -DCMAKE_CXX_FLAGS="-w"
              cmake --build build-ra --target ra --parallel
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 build-ra/ra "$out/bin/redalert"
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Command & Conquer: Red Alert — native Linux port";
              longDescription = ''
                Native Linux port of Command & Conquer: Red Alert built from the
                EA GPL open-source release. Requires legally-acquired game data to run.
                See README for data setup instructions.
              '';
              license = licenses.gpl3Plus;
              platforms = [ "x86_64-linux" ];
              mainProgram = "redalert";
            };
          };

          tiberiandawn = pkgs.stdenv.mkDerivation {
            pname = "cnc-tiberiandawn";
            version = "unstable-2026-05-09";

            src = ./.;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              python3
              pkg-config
            ];
            buildInputs = with pkgs; [
              SDL2
              SDL2.dev
              openal
              libx11
            ];

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
              description = "Command & Conquer: Tiberian Dawn — native Linux port";
              license = licenses.gpl3Plus;
              platforms = [ "x86_64-linux" ];
              mainProgram = "tiberiandawn";
            };
          };

          # ── ISO extraction packages ────────────────────────────────────────
          # All extracted from the redalert-iso flake input via unar.

          ra-patched-exe =
            pkgs.runCommand "ra-patched-exe"
              {
                src = redalert-iso;
                nativeBuildInputs = [
                  pkgs.unar
                  pkgs.python3
                ];
              }
              ''
                unar -q -o "$(pwd)" -D "$src" INSTALL/RA95.EXE 2>/dev/null
                cp INSTALL/RA95.EXE "$out"
                chmod +w "$out"
                python3 ${./scripts/ra/ra-nocd-patch.py} "$out"
                python3 ${./scripts/ra/ra-ddscl-patch.py} "$out"
                # cdlabel: zero the first byte of the "CD1" volume label string
                printf '\x00' | dd of="$out" bs=1 seek=$((0x1BFCB7)) conv=notrunc 2>/dev/null
              '';

          ra-data =
            pkgs.runCommand "ra-data"
              {
                src = redalert-iso;
                nativeBuildInputs = [ pkgs.unar ];
              }
              ''
                mkdir -p "$out"
                unar -q -o "$out" -D "$src" MAIN.MIX 2>/dev/null
                unar -q -o "$out" -D "$src" INSTALL/REDALERT.MIX 2>/dev/null
                if [ -d "$out/INSTALL" ]; then
                  mv "$out/INSTALL"/* "$out/"
                  rmdir "$out/INSTALL"
                fi
                # Case-insensitive symlinks for the game's lowercase file lookups
                ln -sf MAIN.MIX "$out/main.mix"
                ln -sf REDALERT.MIX "$out/redalert.mix"
              '';

          ra-thipx32-dll =
            pkgs.runCommand "ra-thipx32-dll"
              {
                src = redalert-iso;
                nativeBuildInputs = [ pkgs.unar ];
              }
              ''
                unar -q -o "$(pwd)" -D "$src" INSTALL/THIPX32.DLL 2>/dev/null
                cp INSTALL/THIPX32.DLL "$out"
              '';

          ra-thipx16-dll =
            pkgs.runCommand "ra-thipx16-dll"
              {
                src = redalert-iso;
                nativeBuildInputs = [ pkgs.unar ];
              }
              ''
                unar -q -o "$(pwd)" -D "$src" INSTALL/THIPX16.DLL 2>/dev/null
                cp INSTALL/THIPX16.DLL "$out"
              '';

          # cnc-ddraw — Win32 DirectDraw wrapper that replaces wined3d with GDI.
          # Built from upstream GitHub source with MinGW.
          # nix build .#cnc-ddraw  →  result/bin/ddraw.dll
          cnc-ddraw = pkgs.stdenv.mkDerivation {
            pname = "cnc-ddraw";
            version = "unstable-2026-05-16";
            src = cnc-ddraw;
            nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];
            buildPhase = ''
              runHook preBuild
              make -j"$(nproc)"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/bin"
              install -m755 ddraw.dll "$out/bin/ddraw.dll"
              runHook postInstall
            '';
            meta = with pkgs.lib; {
              description = "cnc-ddraw — DirectDraw wrapper for old Win32 games under Wine";
              homepage = "https://github.com/FunkyFr3sh/cnc-ddraw";
              platforms = [ "x86_64-linux" ];
            };
          };

          default = p.redalert;

          # ── vqa-dump — standalone VQA decoder (C++) ─────────────────────
          vqa-dump = pkgs.stdenv.mkDerivation {
            pname = "vqa-dump";
            version = "unstable-2026-05-18";
            src = pkgs.runCommandLocal "vqa-dump-src" { } ''
              mkdir -p $out/tools/vqa_dump
              cp ${./tools/vqa_dump/vqa_dump.cpp} $out/tools/vqa_dump/vqa_dump.cpp
            '';
            buildPhase = ''
              g++ -std=c++17 -O2 -o vqa_dump tools/vqa_dump/vqa_dump.cpp
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp vqa_dump $out/bin/
            '';
          };
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
          (python3.withPackages (
            ps: with ps; [
              numpy
              pillow
              scikit-image
            ]
          ))
          pkg-config
          emscripten # WASM builds: emcmake cmake --preset wasm && cmake --build build-wasm --target ra
          # CI deps
          xvfb
          xvfb-run
          playwright-test # Playwright CLI + browsers via Nix
          ffmpeg-headless
          ccache
          gh
          clang-tools
          cppcheck
          # Mingw-w64 cross-compiler (for stub THIPX32.DLL)
          pkgs.pkgsCross.mingw32.buildPackages.gcc
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
          mono
          curl
          pkgs.wineWow64Packages.stableFull
        ];

        shellHook = ''
                    export RA_ASSETS="''${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
                    export TD_ASSETS="''${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"



                    # Install git pre-commit hook calling the lint tier
                    REPO_ROOT="''$(git rev-parse --show-toplevel 2>/dev/null || true)"
                    if [ -n "$REPO_ROOT" ] && [ ! -f "$REPO_ROOT/.git/hooks/pre-commit" ]; then
                      HOOK="$REPO_ROOT/.git/hooks/pre-commit"
                      cat > "$HOOK" << 'PREHOOK'
          #!/usr/bin/env bash
          set -euo pipefail
          if [[ -z "''${IN_NIX_SHELL:-}" ]]; then
            echo "pre-commit: must be run inside nix develop" >&2
            exit 1
          fi
          nix run .#lint
          PREHOOK
                      chmod +x "$HOOK"
                      echo "Installed git pre-commit hook: nix run .#lint"
                    fi

                    echo "C&C Red Alert — dev shell"
                    echo "  nix flake show   to list available apps and packages"
        '';
      };

      # -----------------------------------------------------------------------
      # apps.redalert  —  nix run
      #
      # Run from your game-data directory, or set RA_ASSETS:
      #   cd /path/to/red-alert-data && nix run github:hughobrien/battlecontrol
      #   RA_ASSETS=/path/to/data   nix run github:hughobrien/battlecontrol
      # Default: .#ra (run Red Alert)
      # -----------------------------------------------------------------------
      apps.${system} = rec {
        ra = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "run-redalert" ''
              set -e
              DATA_DIR="''${RA_ASSETS:-$PWD}"
              if [ ! -f "$DATA_DIR/MAIN.MIX" ] && [ ! -f "$DATA_DIR/main.mix" ]; then
                echo "ERROR: MAIN.MIX not found in $DATA_DIR"
                echo "  cd /path/to/red-alert-data && nix run .#ra"
                echo "  or set RA_ASSETS=/path/to/red-alert-data"
                exit 1
              fi
              cd "$DATA_DIR"
              exec ${self.packages.${system}.redalert}/bin/redalert "$@"
            ''
          );
        };

        td = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "run-tiberiandawn" ''
              set -e
              DATA_DIR="''${TD_ASSETS:-$PWD}"
              if [ ! -f "$DATA_DIR/CONQUER.MIX" ] && [ ! -f "$DATA_DIR/conquer.mix" ]; then
                echo "ERROR: CONQUER.MIX not found in $DATA_DIR"
                echo "  cd /path/to/tiberian-dawn-data && nix run .#td"
                echo "  or set TD_ASSETS=/path/to/tiberian-dawn-data"
                exit 1
              fi
              cd "$DATA_DIR"
              exec ${self.packages.${system}.tiberiandawn}/bin/tiberiandawn "$@"
            ''
          );
        };

        default = ra;

        # ── Developer workflow apps ────────────────────────────────────────
        # nix run .#<name> [args...]  from the repo root.

        # ── Lint ───────────────────────────────────────────────────────────
        # nix run .#lint — fast static analysis and format checks (<10s). Heavy: nix run .#check
        lint = mkApp "lint" ''
          exec bash scripts/lint.sh
        '';

        release = mkApp "release" ''
          set -e
          echo "=== Building RA native ==="
          RA_STORE=$(nix build .#redalert -L --no-link --print-out-paths 2>/dev/null)
          cp "$RA_STORE/bin/redalert" redalert
          strip redalert
          tar czf redalert-linux-x86_64.tar.gz redalert
          echo "  redalert-linux-x86_64.tar.gz: $(stat -c%s redalert-linux-x86_64.tar.gz) bytes"
          echo ""
          echo "=== Building TD native ==="
          TD_STORE=$(nix build .#tiberiandawn -L --no-link --print-out-paths 2>/dev/null)
          cp "$TD_STORE/bin/tiberiandawn" td
          strip td
          tar czf td-linux-x86_64.tar.gz td
          echo "  td-linux-x86_64.tar.gz: $(stat -c%s td-linux-x86_64.tar.gz) bytes"
          echo ""
          echo "=== Release artifacts ==="
          ls -lh redalert-linux-x86_64.tar.gz td-linux-x86_64.tar.gz
        '';
        serve = mkApp "serve-both" ''
          WASM_PORT="''${1:-8080}"
          ASSET_PORT="''${2:-9090}"
          python3 wasm/serve-coop.py "$WASM_PORT" build-wasm &
          WASM_PID=$!
          python3 wasm/serve-assets.py "$RA_ASSETS" "$ASSET_PORT" &
          ASSET_PID=$!
          echo "WASM:   http://localhost:$WASM_PORT"
          echo "Assets: http://localhost:$ASSET_PORT"
          wait
          kill $WASM_PID $ASSET_PID 2>/dev/null || true
        '';

        # ── Four-tier workflow: lint → build → test → regression ──────────
        # Each tier calls the one before it. All support --all and --base REF.
        build = mkApp "build" ''
          exec bash scripts/build.sh "$@"
        '';

        test = mkApp "test" ''
          exec bash scripts/test.sh "$@"
        '';

        regression = mkApp "regression" ''
          exec bash scripts/regression.sh "$@"
        '';

        # ── Heavy static analysis (on-demand). Fast lint: nix run .#lint ──
        check = mkApp "check" ''
          exec bash scripts/check.sh
        '';

        parity = mkApp "parity" ''
          exec bash scripts/parity.sh "$@"
        '';

        # ── CI Job Apps ────────────────────────────────────────────────────
        # The GitHub Actions workflows in .github/workflows/ call these same
        # apps, making CI identical to local and trivially reproducible.
        # ------------------------------------------------------------------

      };
    };
}
