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
# Decision: pin GHC 9.12.2 instead of the nixpkgs default 9.10.3. The
# 9.12 native code generator emits measurably tighter code for the hot
# loop (171 versus 195 instructions per line under perf on identical
# source), which is the whole game in this repository.
pkgs.haskell.packages.ghc9122.override {
  overrides = hnew: hold: {
    "1br" = hnew.callCabal2nix "1br" src { };
  };
}
