{
  description = "Linux port of Command & Conquer: Red Alert (EA open-source release)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};
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

        default = redalert;
      };

      # -----------------------------------------------------------------------
      # devShells.default  —  nix develop
      # -----------------------------------------------------------------------
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = with pkgs; [
          cmake
          gnumake
          ninja
          gcc
          clang
          python3
          pkg-config
          emscripten  # WASM builds: emcmake cmake --preset wasm && cmake --build build-wasm --target ra
        ];

        buildInputs = with pkgs; [
          SDL2
          SDL2.dev
          openal
          xorg.libX11
        ];

        shellHook = ''
          echo "C&C Red Alert — dev shell"
          echo "  cmake -S . -B build && cmake --build build -j\$(nproc)"
          echo "  emcmake cmake --preset wasm && cmake --build build-wasm --target ra  # WASM"
          echo "  bash scripts/first-run-pass-94.sh   # full RA build + smoke test"
        '';
      };

      # -----------------------------------------------------------------------
      # apps.redalert  —  nix run
      #
      # Run from your game-data directory, or set RA_DATA_DIR:
      #   cd /path/to/red-alert-data && nix run github:hughobrien/battlecontrol
      #   RA_DATA_DIR=/path/to/data   nix run github:hughobrien/battlecontrol
      # -----------------------------------------------------------------------
      apps.${system} = rec {
        redalert = {
          type    = "app";
          program = toString (pkgs.writeShellScript "run-redalert" ''
            set -e
            DATA_DIR="''${RA_DATA_DIR:-$PWD}"
            if [ ! -f "$DATA_DIR/MAIN.MIX" ] && [ ! -f "$DATA_DIR/main.mix" ]; then
              echo "ERROR: MAIN.MIX not found in $DATA_DIR"
              echo "  cd /path/to/red-alert-data && nix run"
              echo "  or set RA_DATA_DIR=/path/to/red-alert-data"
              exit 1
            fi
            cd "$DATA_DIR"
            exec ${self.packages.${system}.redalert}/bin/redalert "$@"
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
      };
    };
}
