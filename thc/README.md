# 1br on THC

[THC](https://github.com/ekmett/thc), the Turbo Haskell Compiler, takes
the Core that GHC produces after optimisation and runs it on
Truffle/GraalVM, where Graal partially evaluates the interpreter into
machine code for whatever runs hot
([announcement](https://comonad.com/reader/2026/turbo-haskell/)). It is
the missing half of GHCi this repository's Readme talks about: an
interpreter that profiles itself and compiles what it finds. So the
question is how far that half gets on the same unmodified
[src/Aggregate.hs](../src/Aggregate.hs).

## Results

Same laptop as the scoreboard (Ryzen AI 7 350, 8 cores, 16 threads),
GHC 9.14.1 as the frontend for everything except the first row, THC at
revision `6610dc01`. The host is shared with other containers, so the
load average sat around 6 to 9 during these runs. Every number below
produced byte-identical output.

| implementation | 10M rows | 100M rows | 1B extrapolated |
|----------------|----------|-----------|-----------------|
| native -O2, GHC 9.12.2 (the repository's pin) | 0.042 s | 0.146 s | 1.27 s measured |
| native -O2, GHC 9.14.1 | 0.040 s | 0.149 s | |
| THC as published | 38.7 s | 245.6 s | ~39 min |
| THC, graph budget raised to 400 000 | 20.7 s | 181.2 s | ~29 min |
| GHCi bytecode, 16 capabilities | 69.8 s | | ~1.9 hours |
| GHCi bytecode, 1 capability | 124.5 s | | ~3.5 hours |

THC rows are wall time of the whole process: three hyperfine runs at
10M, a single run at 100M. Starting the JVM and loading the Core of
base, bytestring, containers and friends costs 10.8 s on its own (the
same launch on a 72-row file), so the extrapolation to a billion uses
the 100M throughput plus that start-up once. GHCi rows are the `:set +s`
time of `Aggregate.main` with `-ignore-dot-ghci -fbyte-code
-fforce-recomp`, which excludes loading the modules. With GHC 9.12.2
the single-capability run took 114.0 s here; the Readme's 75.8 s came
from an earlier session on a less busy host.

At a billion rows THC would finish about 3x sooner than GHCi on equal
cores and 5x sooner than GHCi's default single capability. At 10M rows
its start-up eats most of that and the lead over 16-capability GHCi is
1.8x. Native GHC finishes about 1800x sooner than THC. The win is wall
time, not efficiency: THC used 3 319 s of user CPU time on 100M rows,
where single-capability GHCi, at 124.5 s per 10M on one core, would
need about 1 245.

## Why the hot loop stays interpreted

Run with `JAVA_OPTS=-Dthc.traceCompilation=true` and Graal reports this
for the worker lambda that walks a chunk:

```
GraphTooBigBailoutException: Graph too big to safely compile.
  Node count: 93289. Graph Size: 100004. Limit: 100000.
```

THC's launcher fixes `compiler.MaximumGraalGraphSize` at 100 000
(`src/main/java/thc/Main.java`), and the parse loop with
`stepLine`/`scanValue`/`finishLine` inlined lands a few nodes over it
(100 001 to 100 011 across runs).
The loop therefore runs in THC's bytecode interpreter for the whole
file. The "graph budget raised" row is a runtime built with that one
option read from a system property instead. Then the lambda compiles
(7.6 s of compile time, 522 KB of machine code) and 10M rows take
20.7 s instead of 38.7 s. Its on-stack-replacement variant still fails
code installation ("code is too large"), so a chunk already running
when the compile lands cannot switch to it. At 100M the gain shrinks
to 181 s against 246 s. I have not pinned down why; the trace shows
some recompilation, and these were single runs on a laptop that
throttles.

## Reproduce

Building GHC with complete Core takes about half an hour; everything
else is minutes.

```sh
thc/build-ghc.sh ~/thc-toolchain              # GHC 9.14.1, complete Core
thc/acquire.sh ~/thc-toolchain ~/thc-checkout # THC driver + 1br's Core
~/thc-toolchain/bin/onebr-thc measurements.txt
ONEBR_THC_BIN=~/thc-toolchain/bin/onebr-thc cabal test
```

The test suite then runs every official sample and a generated file
through THC as well; all 13 cases pass. CI does not, since it would
have to build GHC from source.

Getting here took these changes, recorded as `Decision:` comments
where they live:

- THC's JVM runtime is a nix build ([nix/thc-runtime.nix](nix/thc-runtime.nix)),
  Gradle's Maven downloads locked through `gradle.fetchDeps`.
- THC validates the configured GHC source tree it regenerates foreign
  declarations from, so nixpkgs' GHC needed three changes
  ([nix/ghc-complete-core.nix](nix/ghc-complete-core.nix)): hadrian
  built by 9.14.1 with Cabal 3.16, the perf flavour instead of release,
  and no `--with-gmp-includes`.
- primitive is built as a local package
  ([cabal.project.thc](../cabal.project.thc)), because THC compiles C
  adapters for its cbits in a store package's temporary unpack
  directory after Cabal has deleted it.
