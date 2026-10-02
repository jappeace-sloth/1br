#!/usr/bin/env bash
# Build GHC 9.14.1 with complete library Core for THC, keeping the
# configured source tree that `thc run --ghc-source` needs. Runs the
# phases of nix/ghc-complete-core.nix outside the sandbox; see the
# Decision there for why this is not a plain nix-build.
#
# usage: thc/build-ghc.sh TOOLCHAIN_DIR
# produces TOOLCHAIN_DIR/ghc (installation) and TOOLCHAIN_DIR/src (tree)
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 TOOLCHAIN_DIR" >&2
  exit 2
fi
mkdir -p "$1"
toolchain=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)

if [ -e "$toolchain/src" ] || [ -e "$toolchain/ghc" ]; then
  echo "$toolchain already holds a GHC build; remove src/ and ghc/ to rebuild" >&2
  exit 1
fi

exec nix-shell --max-jobs 4 "$here/nix/ghc-complete-core.nix" --run "
  set -euo pipefail
  export out='$toolchain/ghc' doc='$toolchain/ghc-doc'
  mkdir -p '$toolchain/src'
  cd '$toolchain/src'
  # runPhase, not the bare functions: the derivation overrides
  # buildPhase as a variable, which only runPhase evaluates. It also
  # enters the source root after unpacking.
  for phase in unpackPhase patchPhase configurePhase buildPhase installPhase; do
    runPhase \$phase
  done
"
