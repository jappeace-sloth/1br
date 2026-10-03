# THC's JVM runtime (the Truffle interpreter/JIT and its launcher), built
# by Gradle inside the sandbox. Gradle's Maven downloads are recorded in
# thc-runtime-deps.json; refresh it after changing the revision with
#   $(nix-build thc/nix/thc-runtime.nix -A mitmCache.updateScript)
#
# Decision: only the JVM half lives here. THC's Haskell half (Core
# plugin, driver, thc-interface) stays a cabal build in a THC checkout:
# the driver rebuilds and publishes the plugin under
# <thc-root>/build/compiler while it runs, and all of it must be built by
# the complete-Core GHC from ../build-ghc.sh, which lives outside the
# store. The driver takes this launcher through `--runtime`.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
let
  inherit (pkgs) lib fetchFromGitHub;
  graalvm = pkgs.graalvmPackages.graalvm-ce;
  # nixpkgs' gradle_9 is the 9.7.1 that THC's wrapper pins.
  gradle = pkgs.gradle_9;
  llvm = pkgs.llvmPackages_18;

  rev = "0ae57cbfe6a4fde15efbc17ffb1852694307e617";

  # THC's git submodules, fetched without their own submodules exactly
  # as THC's CI checks them out.
  pinned = {
    "ghc-9.14.1" = fetchFromGitHub {
      owner = "ghc";
      repo = "ghc";
      rev = "902339d332fb4ce2b3c87dcac1ee6495d41ad886";
      sha256 = "00hkvqkivsl62ahqqmcmgrwp6zknl5di9s2qsb1yl00jykgy15hc";
    };
    "bytestring-0.12.2.0" = fetchFromGitHub {
      owner = "haskell";
      repo = "bytestring";
      rev = "d984ad00644c0157bad04900434b9d36f23633c5";
      sha256 = "0jk3sqmg09qhv5ypga3h7ls99s8ild615xmsy86n68j42yfdv2l8";
    };
    "text-2.1.3" = fetchFromGitHub {
      owner = "haskell";
      repo = "text";
      rev = "5f343f668f421bfb30cead594e52d0ac6206ff67";
      sha256 = "01pgpsky26khd8kkfvjd1wvrqf1gx32pgzswsywv7kliylzclci0";
    };
    "zlib-1.2.11" = fetchFromGitHub {
      owner = "madler";
      repo = "zlib";
      rev = "cacf7f1d4e3d44d871b605da3b647f07d718623f";
      sha256 = "037v8a9cxpd8mn40bjd9q6pxmhznyqpg7biagkrxmkmm91mgm5lg";
    };
  };
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "thc-runtime";
  version = "0.1-experiment-${lib.substring 0 9 rev}";

  src = fetchFromGitHub {
    owner = "ekmett";
    repo = "thc";
    inherit rev;
    sha256 = "1b82ly0bf4azb35ak8zxyr18cxk1p7svcd99d9sawxrv0jgga53w";
  };

  postUnpack = lib.concatStrings (lib.mapAttrsToList
    (name: source: ''
      rm -rf "$sourceRoot/nih/pinned/${name}"
      cp -r ${source} "$sourceRoot/nih/pinned/${name}"
      chmod -R u+w "$sourceRoot/nih/pinned/${name}"
    '')
    pinned);

  nativeBuildInputs = [
    gradle
    graalvm
    pkgs.python3
    # THC patches downloaded Truffle sources with `git apply --no-index`.
    pkgs.git
    llvm.clang
    llvm.llvm
    # The runtime's cbits build reads HsFFI.h, HsBaseConfig.h and
    # HsUnix.h from a GHC 9.14.1 libdir. Those headers do not depend on
    # how the libraries' Core was retained, so stock GHC serves.
    pkgs.haskell.compiler.ghc9141
    pkgs.makeWrapper
  ];
  buildInputs = [ pkgs.gmp ];

  # The runtime's cbits are compiled to bitcode for Sulong. Keep that
  # bitcode free of nixpkgs hardening: fortify rewrites libc calls into
  # __*_chk variants and the stack protector adds __stack_chk_fail calls.
  hardeningDisable = [ "all" ];

  mitmCache = gradle.fetchDeps {
    pkg = finalAttrs.finalPackage;
    data = ./thc-runtime-deps.json;
  };

  JAVA_HOME = graalvm;
  gradleFlags = [ "-Dorg.gradle.java.home=${graalvm}" ];
  gradleBuildTask = "installDist";
  # The default nixDownloadDeps resolves configurations but skips the
  # Truffle sources archives that THC fetches and patches during the
  # build, so record a real build instead.
  gradleUpdateTask = "installDist";

  installPhase = ''
    runHook preInstall
    cp -r build/install/thc $out
    rm $out/bin/thc.bat
    # Gradle's start script shells out to xargs, sed, tr, uname and ls.
    wrapProgram $out/bin/thc --set JAVA_HOME ${graalvm} \
      --prefix PATH : ${lib.makeBinPath [ pkgs.findutils pkgs.gnused pkgs.coreutils ]}
    runHook postInstall
  '';
})
