{ sources ? import ../npins
, pkgs ? import ./pkgs.nix { inherit sources; }
, hpkgs ? import ./hpkgs.nix { inherit pkgs; }
,
}:
let
  # The fileset filter on ../nix/hpkgs.nix already keeps the haskell
  # build from being invalidated by edits to .hlint.yaml, so we can
  # safely use the wider tree here without thrashing the cabal cache.
  src = builtins.path {
    path = ../.;
    name = "1br-src";
    filter = path: _type:
      let base = baseNameOf (toString path);
      in !(builtins.elem base [ "dist-newstyle" "dist" "result" ".git" ])
         # generated measurement files are gigabytes; hlint does not
         # need them and copying them into the store would be absurd
         && builtins.match "measurements.*[.]txt" base == null;
  };
  # The Rust comparison port (rust/main.rs) built the same way a
  # developer does: plain rustc, no crates. Bound here so the test
  # suite's ONEBR_RUST_BIN can reference it from the native build.
  rustBinary = pkgs.runCommand "1br-rust"
    {
      nativeBuildInputs = [ pkgs.rustc pkgs.gcc ];
    } ''
    mkdir -p $out/bin
    rustc -O --edition 2021 ${src}/rust/main.rs -o $out/bin/onebr-rust
  '';

  # The hand-tunable-IR build of the same port: hot loop emitted as
  # LLVM IR, lowered with llc, linked back in (see rust/README.md).
  # Building it in CI proves the pipeline keeps working; llc comes
  # from LLVM 20, which currently parses rustc 1.89's LLVM 21 IR.
  rustLlBinary = pkgs.runCommand "1br-rust-ll"
    {
      nativeBuildInputs = [ pkgs.rustc pkgs.gcc pkgs.llvmPackages_20.llvm ];
    } ''
    mkdir -p $out/bin
    rustc -O --edition 2021 --crate-type=lib --emit=llvm-ir \
      ${src}/rust/hot.rs -o hot.ll
    llc -O3 -relocation-model=pic -filetype=obj hot.ll -o hot.o
    rustc -O --edition 2021 --cfg hot_extern ${src}/rust/main.rs \
      -C link-arg=hot.o -o $out/bin/onebr-rust-ll
  '';
in
{
  # The cabal build / library / executable derivation — what
  # 'nix-build' has always built. Kept here so CI builds the project
  # /and/ the hlint pass with a single 'nix-build nix/ci.nix' rather
  # than two separate invocations. The test suite additionally runs
  # every official sample against the Rust port when ONEBR_RUST_BIN is
  # set, so CI proves both implementations against the same fixtures.
  native = pkgs.haskell.lib.compose.overrideCabal
    (drv: {
      preCheck = ''
        export ONEBR_RUST_BIN=${rustBinary}/bin/onebr-rust
        export ONEBR_RUST_LL_BIN=${rustLlBinary}/bin/onebr-rust-ll
      '';
    })
    (import ../default.nix { inherit hpkgs; });

  # The Rust comparison ports, exposed so CI archives them as outputs.
  rust = rustBinary;
  rust-ll = rustLlBinary;

  # Enforce .hlint.yaml across app/src/test as part of CI. Treating
  # hlint as a derivation lets the same 'nix-build nix/ci.nix' run
  # locally and in GitHub Actions, and keeps the hlint version pinned
  # to the same nixpkgs as the rest of the toolchain.
  hlint = pkgs.runCommand "ci-hlint"
    {
      nativeBuildInputs = [ pkgs.hlint ];
    } ''
    cd ${src}
    hlint -h .hlint.yaml app src test
    touch $out
  '';
}
