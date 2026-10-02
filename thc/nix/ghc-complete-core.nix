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
{ pkgs ? import (import ../../npins).nixpkgs-thc { }
,
}:
(pkgs.haskell.compiler.ghc9141.override {
  # Neither is used by THC; skipping them saves a large share of the build.
  enableDocs = false;
  enableProfiledLibs = false;
}).overrideAttrs (old: {
  hadrianFlags = old.hadrianFlags ++ [
    "*.*.ghc.hs.opts += -fwrite-if-simplified-core"
  ];
})
