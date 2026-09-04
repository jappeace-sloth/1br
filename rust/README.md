# Rust comparison port

The same algorithm as `src/Aggregate.hs`, mirrored
constant-for-constant, to price GHC's pinned-register calling
convention: GHC reserves ten x86-64 general-purpose registers for the
STG machine, rustc/LLVM allocates the full file. Identical IPC on this
machine (~3.2), but 118 instructions per line against Haskell's 178
(122 before the pointer-cursor change described under Findings). Note
the ~50% instruction gap shows up as ~40% in core cycles but only ~20%
in wall time: both implementations share the kernel pread-copy floor,
and SMT (16 threads on 8 cores) absorbs part of the extra cycle load,
so the whole-program wall clock understates the codegen difference.

## Layout

- `slot.rs`: the table slot layout and status codes, shared by both
  build modes.
- `hot.rs`: the per-line hot loop behind a C ABI (`parse_chunk`),
  core-only, no allocation, failures as status codes.
- `main.rs`: orchestration (threads, pread chunk claiming, merge,
  formatting).

## Building

Normal build (hot loop compiled as a module):

```
rustc -O --edition 2021 rust/main.rs -o onebr-rust
```

Hand-tunable IR build (emit the hot loop as LLVM IR, optionally edit
it, lower with llc, link back):

```
rustc -O --edition 2021 --crate-type=lib --emit=llvm-ir rust/hot.rs -o hot.ll
# edit hot.ll if you think you can beat the scheduler
llc -O3 -relocation-model=pic -filetype=obj hot.ll -o hot.o
rustc -O --edition 2021 --cfg hot_extern rust/main.rs -C link-arg=hot.o -o onebr-rust-ll
```

llc must be from an LLVM able to parse rustc's IR (rustc 1.89 emits
LLVM 21 IR; LLVM 20's llc parses it today, check before upgrading).

## Findings

Measured on the repo's AMD Ryzen AI 7 350 container: the module build,
the llc -O3 rebuild and an llc -mcpu=znver4 rebuild are statistically
identical on the billion-row file, and the emitted IR contains no
panic or bounds-check branches to hand-remove. rustc -O already sits
on the floor for this source shape.

Hand-reading the emitted assembly did pay once, at the source level:
index-based cursors kept the buffer base spilled and reloaded for a
base+index computation on every line, so the cursors became raw
pointers (118 instructions per line, down from 122, ~3% fewer
cycles). A literal hand-edit of the remaining assembly found nothing
safe to take: every register is live, LLVM already re-materializes
the SWAR constants where that helps, the frequently-reloaded stack
slots hold rotating per-iteration values rather than invariants, and
Zen 5's memory renaming makes the surviving stack reloads close to
free anyway, which is how the loop sustains IPC 3.2 despite them.

## Testing

Both builds run the exact test suite the Haskell does: point
`ONEBR_RUST_BIN` / `ONEBR_RUST_LL_BIN` at the binaries and run
`cabal test` (nix/ci.nix does this on every CI run, 39 tests).
