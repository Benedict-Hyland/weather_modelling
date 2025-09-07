{
  description = "Dev flake for building wgrib2 from source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Define wgrib2 source
        wgrib2-src = pkgs.fetchFromGitHub {
          owner = "NOAA-EMC";
          repo = "wgrib2";
          rev = "v3.7.0";  # or latest stable
          sha256 = "0cyrxqflh59dg6rn9xibkzb2k4pxl2jjdhilqr832mvqsq19mgyf";
        };

        wgrib2 = pkgs.stdenv.mkDerivation {
          pname = "wgrib2";
          version = "3.7.0";

          src = wgrib2-src;

          nativeBuildInputs = with pkgs; [ cmake gcc gfortran ];

          # Optional dependencies
          buildInputs = with pkgs; [
            netcdf
            libaec
            jasper
            openjpeg
            libpng
            zlib
          ];

          cmakeFlags = [
            "-DCMAKE_INSTALL_PREFIX=$out"
            "-DUSE_NETCDF=ON"
            "-DUSE_AEC=ON"
            "-DUSE_JASPER=ON"
            "-DUSE_PNG=ON"
          ];

          installPhase = ''
            mkdir -p $out/bin
            cp wgrib2/wgrib2 $out/bin/
          '';
        };
      in {
        packages.default = wgrib2;

        devShells.default = pkgs.mkShell {
          packages = [
            wgrib2
            pkgs.eccodes
            pkgs.cdo
            pkgs.nco
            pkgs.curl
            pkgs.inotify-tools
          ];
          shellHook = ''
            echo "✅ wgrib2 dev shell ready"
            wgrib2 -v || echo "wgrib2 installed but no file given"
          '';
        };
      });
}
