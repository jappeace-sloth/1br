#!/usr/bin/env bash
# Prepare 1br's exe for THC and write a launcher for it.
#
# usage: thc/acquire.sh TOOLCHAIN_DIR THC_CHECKOUT
#
# TOOLCHAIN_DIR must hold the complete-Core GHC from thc/build-ghc.sh.
# THC_CHECKOUT is cloned at the revision thc/nix/thc-runtime.nix pins
# when missing; THC's Core plugin and driver are built there because
# the driver republishes the plugin under <thc-root>/build/compiler.
#
# Produces TOOLCHAIN_DIR/thc-guest/packages.json (1br's acquired Core)
# and TOOLCHAIN_DIR/bin/onebr-thc, which takes exe's arguments and runs
# that Core on the nix-built THC runtime without Cabal. The test suite
# accepts it as ONEBR_THC_BIN.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 TOOLCHAIN_DIR THC_CHECKOUT" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
repository=$(dirname "$here")
toolchain=$(cd "$1" && pwd)
checkout=$2

# Re-enter through the toolchain shell (cabal, LLVM 18, $THC_RUNTIME).
if [ -z "${THC_RUNTIME:-}" ]; then
  exec nix-shell --max-jobs 4 "$here/nix/shell.nix" \
    --run "$(printf '%q ' "$0" "$toolchain" "$checkout")"
fi

ghc=$toolchain/ghc/bin/ghc
ghc_pkg=$toolchain/ghc/bin/ghc-pkg
ghc_source=$toolchain/src/ghc-9.14.1-source
if [ ! -x "$ghc" ] || [ ! -d "$ghc_source/_build" ]; then
  echo "$toolchain has no complete-Core GHC; run thc/build-ghc.sh $toolchain first" >&2
  exit 1
fi
export PATH="$toolchain/ghc/bin:$PATH"

revision=$(nix-instantiate --eval --raw -E "(import $here/nix/thc-runtime.nix { }).src.rev")
if [ ! -d "$checkout" ]; then
  git clone https://github.com/ekmett/thc "$checkout"
  git -C "$checkout" checkout --quiet "$revision"
  git -C "$checkout" -c core.autocrlf=false submodule update --init --depth 1
fi
checkout=$(cd "$checkout" && pwd)
actual=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual" != "$revision" ]; then
  echo "$checkout is at $actual, but the THC runtime is built from $revision" >&2
  exit 1
fi

# primitive must be a local package; see the Decision in cabal.project.thc.
if [ ! -d "$repository/thc/vendor/primitive-0.9.1.0" ]; then
  (cd "$repository" && cabal get primitive-0.9.1.0 --destdir thc/vendor)
fi

make -C "$checkout" haskell GHC="$ghc" CABAL_FLAGS=-j8
driver=$(cd "$checkout" && cabal list-bin exe:thc --with-compiler="$ghc")

"$driver" acquire 1br:exe:exe \
  --project-file "$repository/cabal.project.thc" \
  --thc-root "$checkout" --dist-dir "$toolchain/thc-guest" \
  --with-ghc "$ghc" --with-ghc-pkg "$ghc_pkg" \
  --installed-core required --ghc-source "$ghc_source"

mkdir -p "$toolchain/bin"
# @FILE names a Core package manifest. The entry and shutdown pair is
# what `thc run` launches for a Cabal executable: GHC's generated main
# wrapper, then the Handle flush.
cat > "$toolchain/bin/onebr-thc" <<EOF
#!/bin/sh
exec $THC_RUNTIME --run-executable @$toolchain/thc-guest/packages.json \\
  main::Main.main ghc-internal:GHC.Internal.TopHandler.flushStdHandles -- exe "\$@"
EOF
chmod +x "$toolchain/bin/onebr-thc"
echo "launcher: $toolchain/bin/onebr-thc"
