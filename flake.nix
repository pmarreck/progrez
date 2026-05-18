{
  description = "progrez - unified progress indication library for CLI tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";

        progrez = pkgs.stdenv.mkDerivation {
          pname = "progrez";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ];
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build --prefix $out -Doptimize=ReleaseFast
          '';

          dontInstall = true;
        };
      in {
        packages.default = progrez;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "progrez-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            # Zig with link_libc bakes /lib64/ld-linux-x86-64.so.2 as the
            # dynamic linker, which does not exist in the Nix build sandbox.
            # Compile the test binary first, patchelf it, then run the test.
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            zig build test-compile
            DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
            for d in .zig-cache zig-out; do
              [ -d "$d" ] || continue
              for f in $(find "$d" -type f -perm -u+x); do
                patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
              done
            done
            ''}
            zig build test
          '';

          installPhase = ''
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig
            pkgs.hyperfine
          ];

          shellHook = ''
            echo "progrez dev shell"
            echo "  zig: $(zig version)"
          '';
        };
      }
    );
}
