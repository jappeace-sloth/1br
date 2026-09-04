[![https://jappie.me](https://img.shields.io/badge/blog-jappie.me-lightgrey)](https://jappie.me/tag/haskell.html)
[![Github actions build status](https://img.shields.io/github/actions/workflow/status/jappeace/1br/ci.yaml?branch=master)](https://github.com/jappeace/1br/actions)
[![Jappiejappie](https://img.shields.io/badge/discord-jappiejappie-black?logo=discord)](https://discord.gg/Hp4agqy)

> Speed is the essence of war.

The [one billion row challenge](https://github.com/gunnarmorling/1brc)
in Haskell: aggregate the minimum, mean and maximum temperature per
weather station out of a billion `name;temperature` lines, as fast as
possible.

## Results

On an AMD Ryzen AI 7 350 (8 cores, 16 threads, laptop class), one
billion rows, file in page cache. The chip thermal-throttles after a
few sustained seconds, so honest numbers are cold single shots with
cooldowns in between:

| implementation | best cold shot | sustained |
|----------------|----------------|-----------|
| Haskell (this repo) | 1.27s | 1.3s - 1.5s |
| Rust port ([rust/](rust/)) | 1.05s | 1.1s - 1.2s |

The Rust port mirrors the algorithm constant-for-constant and passes
the identical test suite; the ~20% gap is GHC's pinned-register
calling convention made visible (122 versus 178 instructions per line
at identical IPC; details in [rust/README.md](rust/README.md), which
also documents the hand-tunable LLVM IR build that established rustc's
output already sits on the machine's floor for this source shape).

### MicroHs footnote

There is also a [MicroHs](https://github.com/augustss/MicroHs)
implementation in [mhs/](mhs/), correctness-tested by the same suite
but benchmarked on 10 million rows only: it needs 362s for those
(byte-identical output), extrapolating to roughly ten hours for the
billion. MicroHs compiles to combinators run by a small C evaluator
and misses everything this challenge feeds on: no unboxed primops or
native code generation, no threads for the fan-out, no containers
package, and its ByteString file input decodes UTF-8 into byte cells,
truncating non-Latin-1 station names, so the implementation is plain
String folding into a hand-rolled tree. Speed factor versus the GHC
implementation: about 25000x. Combinator self-optimization, it turns
out, does not extend to register allocation.

The official 1brc winners clock 1.5s on eight dedicated EPYC 7502P
(Zen2) cores; their code remains a few percent more cycle-efficient,
this machine's newer cores make up the difference.

The design notes live as `Decision:` comments in
[src/Aggregate.hs](src/Aggregate.hs). The short version: workers pread
chunks of the file into reusable padded buffers (plain reads beat mmap
here: the kernel's copy from page cache parallelizes better than its
page faults), claiming chunks off a work-stealing counter, and per
worker run two interleaved line cursors through a branchless SWAR
parser (semicolon search, temperature parse and name masking all
happen in 64-bit words) into an open-addressing hash table of unboxed
Ints whose slots are exactly one aligned cache line. Station names are
copied to a per-worker arena on first sight so the reused buffers can
be overwritten freely. The hot loop allocates nothing.

## Usage

Enter the nix shell and build:

```
nix-shell
cabal build all
```

Generate a measurements file (413 official stations, fixed seed):

```
cabal run generate -- 1000000000 measurements.txt
```

Aggregate it:

```
cabal run exe -- measurements.txt
```

`exe` defaults to `./measurements.txt` when no path is given.

## Tests

```
cabal test
```

The suite runs every sample pair shipped with the upstream 1brc
repository (rounding, boundaries, multi-byte UTF-8 names, the 10 000
unique key stress case) against the real pipeline, plus a
generator/aggregator round trip.
