{
  description = "cnc-ddraw with scanline_double workaround for RA95 under Wine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};
    in {
      packages.${system} = rec {
        cnc-ddraw = pkgs.stdenv.mkDerivation {
          pname = "cnc-ddraw";
          version = "0-unstable-2026-05-16";

          src = builtins.fetchGit {
            url = "https://github.com/FunkyFr3sh/cnc-ddraw.git";
            rev = "a0b81b11553e1af358396f15ed7f30b9674c390e";
          };

          nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];

          patches = [ ./cnc-ddraw-tim740-scanline-double.patch ];

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

          meta = {
            description = "DirectDraw wrapper for classic games with scanline_double workaround";
            platforms = [ "x86_64-linux" ];
          };
        };

        default = cnc-ddraw;
      };
    };
}
