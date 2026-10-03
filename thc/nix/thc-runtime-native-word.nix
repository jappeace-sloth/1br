# Prototype runtime: patches/native-word-read.patch reads a word from malloc'd
# memory with one borrow and one load instead of eight borrowed byte reads.
# For measurements in ../PERFORMANCE.md only, not an upstream proposal.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
(import ./thc-runtime-tunable.nix { inherit pkgs; }).overrideAttrs (old: {
  pname = "thc-runtime-native-word";
  patches = (old.patches or [ ]) ++ [ ./patches/native-word-read.patch ];
})
