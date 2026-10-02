# Toolchain for running 1br under THC (https://github.com/ekmett/thc),
# with the nix-built JVM runtime as $THC_RUNTIME. The complete-Core GHC
# that THC needs is not in here; build it with ../build-ghc.sh.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
let
  # THC's CI requires major version 18 of every LLVM tool it uses.
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
  # The THC driver compiles the C inside Haskell packages (cbits, CAPI
  # wrappers) to bitcode for Sulong. Keep that bitcode free of nixpkgs
  # hardening: fortify rewrites libc calls into __*_chk variants and
  # the stack protector adds __stack_chk_fail calls.
  hardeningDisable = [ "all" ];
  THC_RUNTIME = "${thcRuntime}/bin/thc";
}
