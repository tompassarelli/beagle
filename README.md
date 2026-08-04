# Beagle

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

**Typed Clojure with one canonical source shape, structured diagnostics, and a
compiler-backed authoring loop.**

Beagle is a typed Lisp designed for ordinary text editing and a short authoring
loop. The product is not a high target count: it is one source language whose
parser, checker, canonicalizer, and repair tools give people and agents the same
answer. A backend stays only when a real consumer makes its semantics testable.

There are two deliberate compilation paths. Hosted targets emit source for a
runtime or evaluator that remains part of the system; Native Core lowers
system-layer code into an immutable, target-neutral Native World and then
materializes that world as native code. Fram stays Beagle source in both cases.

Types exist here for a specific job: making authoring, diagnostics, and
automated repair reliable. They check at compile time and erase before emit. The
point isn't rejection for its own sake — it's to give an authoring loop exact
facts: *what* kind of mistake happened, *where* in the source, after *which*
canonicalization, against *which* target.

## Documentation

- [`docs/CHEATSHEET.md`](docs/CHEATSHEET.md) — the language surface, generated
  from the compiler; every example is parse- and type-checked by the suite.
- [`docs/surface.md`](docs/surface.md) — what the cheatsheet does not
  enumerate: canonical layout, macros, threading, reader conditionals,
  sourcemap fidelity.
- [`docs/targets-by-example.md`](docs/targets-by-example.md) — one source body
  across three backends, and a NixOS module typed against the option schema.
- [`docs/cli.md`](docs/cli.md) — the CLI and the authoring loop.
- [`docs/architecture.md`](docs/architecture.md) — pipeline, layout, where to change what.
- [`docs/self-hosting.md`](docs/self-hosting.md) — how the compiler is held correct.
- [`docs/target-policy.md`](docs/target-policy.md) — why targets get removed, not deprecated.
- [`docs/INFLUENCES.md`](docs/INFLUENCES.md) — lineage and thesis.

Static reference stays thin on purpose — the compiler answers instead: `beagle
help`, `beagle langs`, `beagle sig`, `beagle fields`.

## Quickstart

The flake pins the compiler and its toolchain. Inside the devshell (`direnv
allow`), the binary is `bin/beagle` — written `beagle` below. Using the compiler
requires no database or coordinator:

```console
$ cat src/main.bclj
#lang beagle
(ns main)

(defn greet [name: String] -> String
  (str "hello " name))

(println (greet "from Beagle"))

$ beagle doctor --deep
Authoring loop: ok

$ beagle check --agent src/main.bclj
0 errors

$ beagle build src/main.bclj build/main.clj
src/main.bclj -> build/main.clj
$ bb build/main.clj
hello from Beagle
```

`beagle init --target TARGET DIR` scaffolds a project for any live target;
`beagle build FILE OUT` writes the target's source instead of linking a binary.
Run `beagle doctor --deep` before authoring to verify the complete diagnostic
path. `beagle check --agent FILE` is the fast compiler oracle; `beagle init
--hooks` makes a project invoke it on each edit.

## One canonical source shape

Zero- and one-entry parameter or typed-field vectors stay inline:

```clojure
(defn zero [] -> Int 0)
(defn increment [x: Int] -> Int (+ x 1))
```

Two or more entries put the vector on the following line. Binding names start
in the same column; `:` attaches to the name and has exactly one following
space. Names and types are never padded into columns:

```clojure
(defn add
  [long-name: Int
   x: Int] -> Int
  (+ long-name x))
```

The parser hard-rejects other physical layouts and carries an exact
source-range repair when changing the range cannot alter a comment. This gives
people, formatters, and agents the same answer instead of a style choice.

## Two compilation paths

Hosted emission is for domains where the host source and runtime are part of the
product:

```text
.bclj / .bjs / .bnix  →  parse  →  check  →  emit  →  .clj / .js / .nix
```

The Nix path is exactly this kind of hosted path. A `.bnix` file becomes a Nix
expression and is evaluated by Nix. It does not enter the native pipeline. This
is useful because Beagle can type a NixOS option against the real option schema:
assigning a `String` to `services.openssh.enable` fails before
`nixos-rebuild`.

Native Core is a lowering path, not another idiomatic source emitter:

```text
Beagle source  →  source world  →  typed world  →  Native World
                                                    ├─→ restricted C reference
                                                    └─→ QBE IL → native object
```

The Native World owns typed operations, effects, regions, layouts, control
flow, capabilities, and ABI facts. Materializers are deliberately replaceable
projections of that same sealed program. They are judged by correct binaries and
independent agreement, not by whether a human would maintain the generated C or
QBE.

Fram's files remain Beagle; they are not rewritten as C, Zig, or another systems
language. The current native path is exercised by the `native-core/validation`
drivers while the general CLI profile is being finished. The generated
[`fram.fri-replay` report](native-core/validation/slice-strings/replay-report.txt)
is a concrete vertical slice: real Fram parser, mutation, outcome, and replay
bodies lower into one validated Native World and execute through the reference
materializer.

## Targets

The table below is the compiler's live direct-emitter inventory, not a strategic
promise that every current row will remain. Each admitted target must have a real
consumer and an executable semantic oracle.

The table is generated from `beagle-lib/private/targets.rkt` by `beagle
doc-fill`; query it live with `beagle langs` (`--view domains` for what each
target is *for*).

<!-- beagle:langs table -->
| target | language | source | `#lang` | output | status |
|---|---|---|---|---|---|
| `clj` | Clojure | `.bclj` | `#lang beagle` | `.clj` | live — self-hosted, oracle-certified, fuzz-guarded |
| `js` | JavaScript | `.bjs` | `#lang beagle/js` | `.js` | live — self-hosted, oracle-certified, fuzz-guarded |
| `nix` | Nix | `.bnix` | `#lang beagle/nix` | `.nix` | live — self-hosted, oracle-certified, fuzz-guarded |
| `odin` | Odin | `.bodin` | `#lang beagle/odin` | `.odin` | live — Racket emitter; self-host port pending conformance goldens |
| `zig` | Zig | `.bzig` | `#lang beagle/zig` | `.zig` | live — Racket emitter with restored structural goldens |

Five language targets. `facts` is not one of them — it is the compact, lossy projection of the parsed AST into CNF analysis facts, represented as three-slot vectors (`bin/beagle-facts`): a query surface, not an authoring language. The verbose, program-lossless source↔fact projection is `beagle facts-roundtrip`, where lossless means reader-datum identity, not byte identity.
<!-- /beagle:langs -->

Native Core is not a seventh row in this table: it is a target-neutral lowering
profile below the shared parser and checker. Targets are removed rather than
deprecated when they stop earning their place —
[`docs/target-policy.md`](docs/target-policy.md).

## Real codebases author against Beagle

- **[firn](https://github.com/tompassarelli/firn)** — a complete NixOS system,
  authored in `.bnix` and schema-typed end to end; builds from `flake.bnix`.
- **[gjoa](https://github.com/tompassarelli/gjoa)** — a Firefox fork tuned for
  power users, authored in `.bjs`.
- **[wake](https://github.com/tompassarelli/wake)** — an application compiler
  (entities, views, routes → direct-DOM JS), itself authored in `.bjs`.
- **[fram](https://github.com/Autonymy/fram)** — a slot-addressable,
  typed-triple substrate with stratified Datalog, authored in `.bclj`; its replay
  path is the current Native Core vertical slice.
- **[north](https://github.com/tompassarelli/north)** — a work tracker and
  agent orchestrator over one triple graph, authored in `.bclj` and built on
  Fram.

## How it is held correct

The `clj`-target compiler is written in Beagle and compiles itself to a
byte-level fixpoint, with the original Racket compiler as a conformance oracle
and a nightly differential fuzz campaign holding the two to byte-exact agreement
on an empty exemption list — [`docs/self-hosting.md`](docs/self-hosting.md).

## What it isn't

- **Not a schema language, not a validation runtime** — types check at compile
  time, then erase.
- **Not a new Lisp in spirit** — a strict typed subset of Clojure; divergence
  from Clojure must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one Native World
  and replaceable materializers.
- **Not stable.** Pre-1.0, the surface still moves, and removals are hard breaks:
  there is no deprecation path.
- **Not benchmarked.** The repository gates correctness, not speed, and publishes
  no performance numbers.

## Contributing

Read [`CLAUDE.md`](CLAUDE.md) first — its three-statement generative spec is the
canonical anchor for any surface question.

## License

Dual-licensed under the [MIT License](LICENSE-MIT) or the
[Apache License, Version 2.0](LICENSE-APACHE), at your option. See
[`LICENSE`](LICENSE) for the chooser.
