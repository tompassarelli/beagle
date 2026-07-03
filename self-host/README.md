# self-host — Beagle's self-hosted compiler

This directory contains a compiler for Beagle's `clj` target written in Beagle
itself, plus the **seed** that makes it runnable without any prior Beagle
toolchain.

## Layout

- `src/selfhost/*.bclj` — the compiler sources (reader → parse → check →
  emit-clj, a driver, and supporting modules), written in `#lang beagle/clj`.
- `src/selfhost/rt.clj` — a small hand-written runtime shim (host IO: file
  reads, JSON, exit codes). Never compiled; copied verbatim into the seed.
- `seed/selfhost/*.clj` — **the blessed seed**: the compiler's own emitted
  output, checked in. [babashka](https://babashka.org) runs these files
  directly, so the seed *is* a working compiler with no bootstrap dependency
  on Racket.
- `fixtures/` — tracked regression fixtures for the parity harness.
- `verify-selfhost.sh` — the oracle ladder: module self-tests, stage-isolated
  emit parity, AST parity, and full-chain byte parity against the Racket
  compiler over a corpus of real modules.

## The bootstrap loop

Emission is deterministic, so the seed is held to a byte-level fixpoint: the
seed compiler, compiling the compiler's own sources, must reproduce the seed
exactly.

```sh
bin/beagle-remint            # gate: selfhost-emit(src) == seed, byte-for-byte
bin/beagle-remint --oracle   # + Racket emission of the same sources == seed
bin/beagle-remint --promote  # bless fresh output as the new seed (see below)
```

The default gate needs only `bb` on PATH. `--oracle` additionally runs the
Racket compiler over the same sources and requires three-way agreement:
`seed == selfhost-emitted == racket-emitted`. CI runs both; any byte
divergence fails the build.

## Running the seed compiler

```sh
bb -cp self-host/seed -m selfhost.main emit  FILE.bclj   # compile to stdout
bb -cp self-host/seed -m selfhost.main check FILE.bclj
bb -cp self-host/seed -m selfhost.main ast   FILE.bclj   # typed-AST JSON
```

## Changing the compiler

1. Edit `src/selfhost/*.bclj` (or `src/selfhost/rt.clj`).
2. Run `bin/beagle-remint --promote`. Promotion is gated on **convergence** —
   the freshly emitted compiler must recompile the sources to byte-identical
   output (generation 1 == generation 2) — and on the module self-tests
   passing. Add `--oracle` to also require Racket agreement.
3. Commit the updated `seed/` together with the source change. The plain
   `bin/beagle-remint` gate then holds the pair honest from that point on.

Seed emission is normalized: source-location metadata is off
(`BEAGLE_EMIT_SRCLOC=0` on the Racket side), so seed files never embed
absolute checkout paths and remain byte-stable across machines.

## Known gaps (vs the Racket compiler)

- **Module resolution / externs** — CLOSED. The driver (`main.bclj`) now
  resolves each `(require ...)` to a sibling beagle source (mirroring
  `parse.rkt` `resolve-module-path`: ns-segments → path, source-dir then
  parent walk, `BEAGLE-EXTENSIONS`), reads + parses it (pure), and imports
  its typed surface via `parse.bclj` `import-module-surface` — a port of
  `import-module-types!` `reg!`: alias-qualified externs for declare-extern,
  `defrecord` ctor/accessors, `defscalar`, `defunion`, typed `def`/`defonce`,
  `^:dynamic` vars, and `defn` signatures (`:refer` also binds bare). These
  merge into `prog.externs` before `check`, so `k/x` refs type against real
  signatures and cross-module type errors are caught like the oracle. The
  `check.rkt` unresolved-alias diagnostic is ported too (`check.bclj`
  `check-qualified-resolution!`: a qualified ref whose prefix was never
  required → exit 1). The parse stage stays PURE — all IO lives in the
  driver (`selfhost.rt` `file-exists?`/`slurp-file`/`abs-path`). Verified by
  `verify-selfhost.sh` rungs 6/7 and the fram corpus (byte-identical emit +
  externs parity). Externs are compared as a SET: `ast-json.rkt` serializes
  the oracle's externs in hash order, so byte order is not reproducible.
  Remaining sub-gaps (none exercised by any current corpus): cross-module
  MACRO import (qualified `defmacro`/`define-macro` — surfaced to the macro
  registry by the oracle, not ported here; ast-json externs carry none),
  keyword field access on an imported record (needs the oracle's
  per-record field table, not the flat externs), and parametric-union
  member ctors/accessors (only the union name is imported).
- **Source locations** — the chain carries none; seed emission is
  srcloc-free by construction, so this cannot affect seed bytes.
- **Non-clj targets** — the chain emits the `clj` target only (no nix
  reader macros / `nix-*` forms, no js/cljs/odin emitters).

## Native distribution binary

`native/` builds a self-contained GraalVM native-image of the seed compiler
(the same emitted `.clj` babashka runs — the seed is also real JVM Clojure):

```sh
nix shell nixpkgs#graalvmPackages.graalvm-ce -c self-host/native/build.sh
self-host/native/beagle-selfhost emit FILE.bclj     # ast | check | emit-from-ast too
```

Zero reflection config (one Jackson `--initialize-at-build-time` class-init
flag only — see `native/build.sh`). Parity gate:

```sh
self-host/native/verify-native.sh   # native == bb == Racket oracle, byte-for-byte
```
