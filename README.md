# Beagle

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

**Typed Clojure with one canonical source shape, structured diagnostics, and a
compiler-backed authoring loop.**

Beagle is a typed Lisp designed for ordinary text editing and a short authoring
loop. The product is not a high target count: it is one source language whose
parser, checker, canonicalizer, and repair tools give people and agents the same
answer. A backend stays only when a real consumer makes its semantics testable.

There are two deliberate compilation paths. The source profile chooses between
them: `.bgl` with bare `#lang beagle` always targets Native Core and lowers to
an immutable Native World. The `.bgl` source is not target-neutral and does not
mean "no target selected"; the resulting Native World is backend-neutral so it
can be materialized as native code. C17 and QBE are the current materializers;
Wasm belongs at that same materializer layer rather than becoming another
source profile.

Hosted profiles emit source for a runtime or evaluator that remains part of the
system: `.bclj`, `.bjs`, and `.bnix` select Clojure, JavaScript, and Nix
respectively. The Native Core lowering tool may itself be implemented and run
as hosted `.bclj` during bootstrapping. That is an implementation detail of the
compiler, not an optional native path from `.bclj`. Fram stays Beagle source in
both cases.

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
  across the hosted backends, plus the Core build boundary.
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
#lang beagle/clj
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
For Core, author `.bgl` with bare `#lang beagle` and select the projection
separately: `beagle build --materializer c17|qbe --out DIR FILE.bgl`. The build
always writes `module.native-world` and its digest; only the selected C17 or QBE
artifact is projected beside it.
Run `beagle doctor --deep` before authoring to verify the complete diagnostic
path. `beagle check --agent FILE` is the fast compiler oracle; `beagle init
--hooks` makes a project invoke it on each edit.

## One canonical source shape

Zero-, one-, and two-entry parameter or typed-field vectors stay inline when
the complete signature fits within 80 columns:

```clojure
(defn zero [] -> Int 0)
(defn increment [(x : Int)] -> Int (+ x 1))
(defn add [(x : Int) (y : Int)] -> Int (+ x y))
```

Three or more entries always put the vector on the following line. An
over-width zero-, one-, or two-entry signature does too. A wrapped vector has
one logical entry per line and is never partially packed. Binding names start
in the same column; a typed entry is parenthesized `(name : Type)` with one
space on each side of `:`. Names and types are never padded into columns:

```clojure
(defn clamp
  [(long-name : Int)
   (minimum : Int)
   (maximum : Int)] -> Int
  ...)
```

The reader accepts either physical layout, and a flat `name: Type` entry still
parses. `beagle fmt --write .` performs the token-aware mechanical rewrite,
including folding a flat entry into `(name : Type)`; `beagle fmt --check .` gives people, CI, and
agents the same answer without making whitespace part of language validity.

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

Native Core is the `.bgl` lowering path, not another idiomatic source emitter:

```text
.bgl + #lang beagle  →  source world  →  typed world  →  Native World
                                                              ├─→ restricted C reference
                                                              ├─→ QBE IL → native object
                                                              └─→ Wasm (materializer)
```

The Native World owns typed operations, effects, regions, layouts, control
flow, capabilities, and ABI facts. Materializers are deliberately replaceable
projections of that same frozen program. They are judged by correct binaries and
independent agreement, not by whether a human would maintain the generated C or
QBE.

Fram's files remain Beagle; they are not rewritten as C or another systems
language. The Core path is `beagle build --materializer c17|qbe`: it accepts
canonical `.bgl`, freezes one Native World, and materializes only the selected
projection. The generated
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
| `core` | Beagle Native Core | `.bgl` | `#lang beagle` | frozen native program | live — native pipeline: frozen native program; select C17 or QBE materializer |
| `clj` | Clojure | `.bclj` | `#lang beagle/clj` | `.clj` | live — self-hosted, oracle-certified, fuzz-guarded |
| `js` | JavaScript | `.bjs` | `#lang beagle/js` | `.js` | live — self-hosted, oracle-certified, fuzz-guarded |
| `nix` | Nix | `.bnix` | `#lang beagle/nix` | `.nix` | live — self-hosted, oracle-certified, fuzz-guarded |

Four source profiles. Core produces the authoritative frozen native program; `--materializer c17|qbe` selects a projection. `facts` is not one of them — it is the compact, lossy projection of the parsed AST into CNF analysis facts, represented as three-slot vectors (`bin/beagle-facts`): a query surface, not an authoring language. The verbose, program-lossless source↔fact projection is `beagle facts-roundtrip`, where lossless means reader-datum identity, not byte identity.
<!-- /beagle:langs -->

Core is a source profile, not a direct source emitter; its row names the frozen
world build product while the materializer remains an explicit build option.
Profiles are removed rather than deprecated when they stop earning their place —
[`docs/target-policy.md`](docs/target-policy.md).

## Real codebases author against Beagle

- **[firn](https://github.com/tompassarelli/firn)** — a complete NixOS system,
  authored in `.bnix` and schema-typed end to end; builds from `flake.bnix`.
- **[gjoa](https://github.com/tompassarelli/gjoa)** — a Firefox fork tuned for
  power users, authored in `.bjs`.
- **[wake](https://github.com/tompassarelli/wake)** — an application compiler
  (entities, views, routes → direct-DOM JS), itself authored in `.bjs`.
- **[fram](https://github.com/Autonymy/fram)** — a slot-addressable,
  typed-triple substrate with stratified Datalog, authored in Native Core
  `.bgl`.
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
