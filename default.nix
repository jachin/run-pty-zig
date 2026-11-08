{
  pkgs ? (
    let
      nixpkgs = builtins.tryEval <nixpkgs>;
    in
    if nixpkgs.success
    then import nixpkgs.value {}
    else import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {}
  ),
  lib ? pkgs.lib,
  stdenv ? pkgs.stdenv,
  zig ? pkgs.zig,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "run-pty";
  version = "0.1.3";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [ zig.hook ];

  meta = with lib; {
    description = "Run several commands concurrently in PTYs with an interactive dashboard";
    homepage = "https://github.com/jachin/run-pty-zig";
    license = licenses.mit;
    mainProgram = "run-pty";
    platforms = platforms.unix;
  };
})
