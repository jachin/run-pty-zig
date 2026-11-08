{
  description = "Run several commands concurrently in PTYs with an interactive dashboard";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        run-pty = pkgs.callPackage ./default.nix {};
      in
      {
        packages.default = run-pty;
        packages.run-pty = run-pty;

        apps.default = flake-utils.lib.mkApp {
          drv = run-pty;
        };

        devShells.default = import ./shell.nix { inherit pkgs; };
      }
    );
}
