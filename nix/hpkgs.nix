{ pkgs ? import ./pkgs.nix { }
,
}:
let
  # Decision: use lib.fileset.toSource for fine grained source filtering.
  # Alternatives considered: passing ../. directly (rebuilds on any nix/tooling
  # change), cleanSource (still includes too much). fileset.unions makes the
  # build inputs explicit so editing nix/, .github/, makefile, .hlint.yaml,
  # etc. does not invalidate the haskell build cache.
  src = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../app
      ../gen
      ../src
      ../test
      ../data
      ../1br.cabal
      ../LICENSE
      ../Readme.md
      ../Changelog.md
    ];
  };
in
# you can pin a specific ghc version with
# pkgs.haskell.packages.ghc984 for example.
# this allows you to create multiple compiler targets via nix.
pkgs.haskellPackages.override {
  overrides = hnew: hold: {
    "1br" = hnew.callCabal2nix "1br" src { };
  };
}
