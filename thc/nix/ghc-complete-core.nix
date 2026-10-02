# GHC 9.14.1 whose libraries keep their complete simplified Core in the
# interface files. THC executes those bodies, so a stock installation
# (which only ships inlinable unfoldings) cannot run base's IO code.
# See https://github.com/ekmett/thc/blob/main/docs/ghc-core.md
#
# Decision: build this derivation's phases out of the sandbox with
# build-ghc.sh instead of `nix-build`. THC's --ghc-source check
# canonicalises the build directory recorded in each library's
# setup-config and refuses a tree that moved, and a sandbox build
# records /build/..., which is gone once the derivation finishes.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
let
  stockGhc = pkgs.haskell.compiler.ghc9141;
  # Decision: build hadrian with GHC 9.14.1 and its bundled Cabal
  # 3.16.0.0 instead of nixpkgs' default (the 9.10 bootstrap set with
  # Cabal 3.14.2). Hadrian writes each library's setup-config, and
  # Cabal only reads a config written by the same Cabal and GHC version
  # as the reader, here THC's driver. This matches THC's own recipe,
  # which bootstraps 9.14.1 with 9.14.1. Upstream UserSettings.hs
  # replaces nixpkgs' one; it differs only in the default flavour and
  # colours, and we always pass --flavour.
  hadrian = (import "${pkgs.path}/pkgs/development/tools/haskell/hadrian/make-hadrian.nix"
    {
      bootPkgs = pkgs.haskell.packages.ghc9141;
      inherit (pkgs) lib;
    }
    {
      # The patched GHC source tree; nixpkgs builds hadrian and GHC from it.
      ghcSrc = stockGhc.passthru.hadrian.src;
      ghcVersion = stockGhc.version;
    }).override {
    # null selects the Cabal installed with GHC 9.14.1.
    Cabal = null;
  };
in
(stockGhc.override {
  # Decision: perf, THC's documented flavour, instead of nixpkgs'
  # release. Release adds no_self_recomp, which drops the source hash
  # and usage list from every interface, and THC's --ghc-source check
  # verifies the configured tree against exactly that record.
  ghcFlavour = "perf+no_profiled_libs+split_sections";
  # Neither is used by THC; skipping them saves a large share of the build.
  enableDocs = false;
  enableProfiledLibs = false;
  inherit hadrian;
}).overrideAttrs (old: {
  hadrianFlags = old.hadrianFlags ++ [
    "*.*.ghc.hs.opts += -fwrite-if-simplified-core"
  ];
  # Decision: let the cc wrapper's -isystem/-L find gmp instead of
  # passing its store paths to configure. Hadrian copies those paths
  # into ghc-internal's include-dirs, and THC's --ghc-source check only
  # admits the library's own include directory, as on distributions
  # with gmp.h in /usr/include. Programs built with this GHC therefore
  # need gmp in their environment; ./shell.nix provides it.
  configureFlags = builtins.filter
    (flag: !(pkgs.lib.hasPrefix "--with-gmp-" flag))
    old.configureFlags;
})
