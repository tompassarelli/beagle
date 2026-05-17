# 011 — Daemon + Babashka: collapsing the wall-time gap

**Date:** 2026-05-17

## Hypothesis

E9 showed beagle uses 63% fewer tokens but 73% more wall time than
clojure. The repair toolchain works — the bottleneck is tool startup
overhead. If we eliminate Racket restart (0.33s × 60 calls) and JVM
startup (0.33s + 1.6s parse per oracle), wall time should drop below
clojure.

## Experiment

Benchmarked two optimizations:

1. **beagle-daemon** — persistent Racket process, TCP server, AST cache
   with mtime invalidation. Query tools check for running daemon and
   route through it transparently.

2. **Babashka for oracle** — replace `clojure -Sdeps` with `bb -cp` for
   all verify/oracle invocations. Required fixing the emitter to not
   emit `:refer :all` (causes bb namespace collisions).

## Results

```
                        Cold (before)    With daemon     Improvement
Single query (sig)      0.45s            0.01s           45×
5 queries (mixed)       4.77s            0.12s           39×
10 queries (sig)        4.98s            0.12s           43×

                        JVM Clojure      Babashka        Improvement
Oracle (484 asserts)    2.14s            0.18s           12×
```

## Emitter fix required for bb compatibility

Babashka's SCI interpreter is stricter about namespace collisions than
JVM Clojure. `(:require [module :refer :all])` + local redefinition =
hard error on bb, silent overwrite on JVM.

Fix: removed `:refer :all` from emitter entirely. Added
`imported-symbol-ns` hash to the program struct so the emitter qualifies
all cross-module calls with their source alias. All 331 tests pass,
484/484 golden assertions pass on both JVM and bb.

## Projected E9 impact

```
Current E9-beagle pipeline:
  60 query calls × 0.45s     = 27s
  10 oracle runs × 2.14s     = 21s
  Tool overhead total:         48s of 376s (13%)

With daemon + bb:
  60 queries × 0.01s          = 0.6s
  10 oracle runs × 0.18s     = 1.8s
  Tool overhead total:         2.4s (95% reduction)
```

## Architectural decision: daemon vs alternatives

Considered Babashka for query tools (can't — beagle is Racket, not
Clojure) and GraalVM native-image (doesn't exist for Racket). The
daemon is the only viable approach for Racket query acceleration.

Babashka is perfect for the oracle side because the compiled output is
standard Clojure and the verify scripts use only core functions.

## Next question

Does the wall-time reduction actually materialize in E9 re-runs? The
projection says yes, but tool overhead is only part of the story — LLM
thinking time and network latency dominate. The real test: does faster
tool response reduce total turns (by giving the model less time to
"lose context" between queries)?
