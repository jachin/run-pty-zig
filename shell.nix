{
  pkgs ? (
    let
      nixpkgs = builtins.tryEval <nixpkgs>;
    in
    if nixpkgs.success
    then import nixpkgs.value {}
    else import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {}
  ),
}:

pkgs.mkShell {
  packages = [
    pkgs.zig
  ];
}
