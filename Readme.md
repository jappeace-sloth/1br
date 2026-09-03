[![https://jappieklooster.nl](https://img.shields.io/badge/blog-jappieklooster.nl-lightgrey)](https://jappieklooster.nl/tag/haskell.html)
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

| run | wall time |
|-----|-----------|
| best (cold single shot, idle host) | 1.27s |
| typical cold shot | 1.27s - 1.31s |
| sustained repeats under load | ~1.3s - 1.5s |

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
