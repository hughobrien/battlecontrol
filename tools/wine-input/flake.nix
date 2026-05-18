{
  description = "SendInput-based input injection helpers for Wine RA/TD harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = rec {
        ra-sendinput = pkgs.stdenv.mkDerivation {
          pname = "ra-sendinput";
          version = "unstable-2026-05-16";
          src = ./ra-sendinput.c;
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];
          buildPhase = ''
            cp "$src" ra-sendinput.c
            i686-w64-mingw32-gcc -o ra-sendinput.exe ra-sendinput.c -luser32
          '';
          installPhase = ''
            mkdir -p "$out/bin"
            install -m755 ra-sendinput.exe "$out/bin/"
          '';
        };

        ra-screenshot = pkgs.stdenv.mkDerivation {
          pname = "ra-screenshot";
          version = "unstable-2026-05-16";
          src = ./ra-screenshot.c;
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];
          buildPhase = ''
            cp "$src" ra-screenshot.c
            i686-w64-mingw32-gcc -o ra-screenshot.exe ra-screenshot.c -lgdi32
          '';
          installPhase = ''
            mkdir -p "$out/bin"
            install -m755 ra-screenshot.exe "$out/bin/"
          '';
        };

        td-sendinput = pkgs.stdenv.mkDerivation {
          pname = "td-sendinput";
          version = "unstable-2026-05-16";
          src = ./td-sendinput.c;
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];
          buildPhase = ''
            cp "$src" td-sendinput.c
            i686-w64-mingw32-gcc -o td-sendinput.exe td-sendinput.c -luser32
          '';
          installPhase = ''
            mkdir -p "$out/bin"
            install -m755 td-sendinput.exe "$out/bin/"
          '';
        };

        td-screenshot = pkgs.stdenv.mkDerivation {
          pname = "td-screenshot";
          version = "unstable-2026-05-16";
          src = ./td-screenshot.c;
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.pkgsCross.mingw32.buildPackages.gcc ];
          buildPhase = ''
            cp "$src" td-screenshot.c
            i686-w64-mingw32-gcc -o td-screenshot.exe td-screenshot.c -lgdi32
          '';
          installPhase = ''
            mkdir -p "$out/bin"
            install -m755 td-screenshot.exe "$out/bin/"
          '';
        };

        default = ra-sendinput;
      };
    };
}
