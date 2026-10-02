# Toolchain for running 1br under THC (https://github.com/ekmett/thc).
# The JVM runtime comes prebuilt from thc-runtime.nix as $THC_RUNTIME.
# GHC itself is not in here: THC needs the complete-Core build from
# ../build-ghc.sh, which run.sh puts on PATH.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
let
  # THC's CI checks every LLVM tool is major version 18; Sulong in
  # GraalVM 25 consumes bitcode from that release.
  llvm = pkgs.llvmPackages_18;
  thcRuntime = import ./thc-runtime.nix { inherit pkgs; };
in
pkgs.mkShell {
  packages = [
    pkgs.cabal-install
    pkgs.python3
    pkgs.git
    pkgs.gmp
    llvm.clang
    llvm.llvm
    pkgs.hyperfine
  ];
  # Package C is compiled to bitcode for Sulong; fortify and stack
  # protector rewrite libc calls into __*_chk variants that the
  # bitcode then has to resolve as well.
  hardeningDisable = [ "all" ];
  THC_RUNTIME = "${thcRuntime}/bin/thc";
}
