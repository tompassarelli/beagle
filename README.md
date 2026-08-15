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
an immutable validated Native Core program. The `.bgl` source is not
target-neutral and does not mean "no target selected"; the resulting frozen
native program is backend-neutral so it can be materialized as native code.
C17, QBE, and a C17/WASI WebAssembly bootstrap are the current materializers.
The Wasm bootstrap is named as such and is not a direct emitter; a future
direct Wasm emitter replaces that projection behind the same frozen-program
seam rather than becoming another source profile.

Hosted profiles emit source for a runtime or evaluator that remains part of the
system: `.bclj`, `.bjs`, and `.bnix` select Clojure, JavaScript, and Nix
respectively. The Native Core lowering tool may itself be implemented and run
as hosted `.bclj` during bootstrapping. That is an implementation detail of the
compiler, not an optional native path from `.bclj`. Fram stays Beagle source in
both cases.

Types exist here for a specific job: making authoring, diagnostics, and
automated repair reliable. Static type information checks at compile time and
erases before emit. An explicitly authored binding constraint is different: it
is an ordinary predicate value and emits a local runtime guard. The point isn't
rejection for its own sake — it's to give an authoring loop exact facts: *what*
kind of mistake happened, *where* in the source, after *which* canonicalization,
against *which* target.

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
- [`docs/target-policy.md`](docs/target-policy.md) — the target registry and projection boundary.
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

(defn greet [(name String)] String
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
separately: `beagle build --materializer c17|qbe|wasm --out DIR FILE.bgl`. The
build always writes `module.native-program` and its digest; only explicitly
selected artifacts are projected beside it. Wasm requires `--abi wasm32` and
writes a reactor, digest, import/export seam inventory, deterministic report,
and environment-specific tool-path audit. With no `--entry`, that reactor is a
clearly named non-executable projection. Each repeated `--entry` names one
public, parameterless `Int` source function; every accepted entry earns its own
`beagle_wasm_entry_v1__<ns>__<name> : () -> i64` export and is invoked under
the resolved Wasmtime during the build. Entries whose lowered form takes the
generated arena/capability parameters run against one adapter-owned instance
arena constructed during `_initialize`; other callable shapes are refused by
the qualified entry name (`docs/cli.md` documents the v1 contract).
Run `beagle doctor --deep` before authoring to verify the complete diagnostic
path. `beagle check --agent FILE` is the fast compiler oracle; `beagle init
--hooks` makes a project invoke it on each edit.

## One canonical source shape

The outer `[...]` is only the collection of bindings. Each entry owns its own
type and optional constraint:

```text
binding := symbol
         | (binding-form Type)
         | (binding-form Type constraint)
```

A bare symbol requests inference. In a typed entry, `binding-form` may be a
symbol or an ordinary Clojure sequential or associative destructuring form; the
type annotates the entire binding operation:

```clojure
[a]                                    ; one inferred binding
[(a Point)]                            ; one typed binding
[a b]                                  ; two inferred bindings
[(a Point) (b Point)]                  ; two typed bindings
[a (b Point)]                          ; mixed: a inferred, b typed
[([x y] (HVec Float Float)) options]   ; typed destructure + inferred symbol
[({:keys [host port]} Config)]         ; typed map destructure
```

Each outer entry is interpreted independently; adjacent tokens are never
repartitioned into a declaration. A bare destructuring form in a strict typed
signature is rejected because there is no aggregate type to project; wrap the
pattern and aggregate type in one form. Explicit `(value Any)` remains
available for a deliberately dynamic boundary; omission does not silently mean
`Any`. The nesting is semantic structure, not visual decoration. Executable
signatures have a mandatory positional return type, so no annotation
punctuation is needed:

```clojure
(defrecord Point [(x Float) (y Float)])

(defn distance [(a Point) (b Point)] Float
  ...)

(defn point-x [({:keys [x y]} Point)] Float
  x)
```

The optional third element is a statically known, synchronous unary predicate
of type `[T -> Bool]`, where `T` is the declared binding type. Its signature may
not contain `Any`, take extra/rest arguments, return a non-`Bool`, or perform
asynchronous work. Call-produced predicates are accepted only when the callee
publishes an explicit positive returned-callable synchronization proof;
executing the factory synchronously is not sufficient:

```clojure
(defn positive? [(value Int)] Bool (> value 0))

(defn add-positive [(left Int positive?) (right Int positive?)] Int
  (+ left right))
```

At runtime the predicate receives the complete incoming value before the
binding target is installed or a destructuring pattern projects any names. A
false result raises a binding-constraint error; the body does not run. This
ordering also makes `([x y] Point2 valid-point?)` validate the `Point2` value,
not either projected coordinate.

Fields and other declaration DSLs obey the same structural ownership rule. A
complete constrained record field is `(id String character-id-wire?)`, so this
is valid:

```clojure
(defrecord Character
  [(id String character-id-wire?)
   (name String character-name-wire?)])
```

The flattened `[(id String) character-id-wire?]` is rejected in a field DSL;
the compiler never reconstructs declarations from adjacent entries. A DSL with
more field-local metadata likewise keeps its validator, encoder, and decoder in
the one declaration form that owns them, for example
`(name Type value-validator wire-validator encoder decoder)` or
`(name encoder-expression validator)`.

Procedural macros reject a particular caller declaration with
`(syntax-error-at collection index message ...)`, normally from
`map-indexed`. The index is zero-based over logical list/vector elements (the
vector reader tag is excluded), and `collection` must be the original macro
input collection or one of its `rest` tails. This preserves source identity so
the diagnostic reports the stray form's own line, column, and span.

Layout is driven only by the 80-column width. When the complete owner and
signature fit, they stay together. If the owner makes the line overflow but
the indented `[params] Return` unit fits, that whole unit moves to the next
line:

```clojure
(defn horizontal-ring-distance
  [(anchor WorldCoordinate) (coord WorldCoordinate)] Float
  ...)
```

Only when the indented signature unit itself exceeds the width does the vector
expand to one binding form per line, with the mandatory return type on its own
line:

```clojure
(defn complicated-distance
  [(anchor Coordinate)
   (coord Coordinate)
   (world WorldState)
   (options DistanceOptions)]
  Float
  ...)
```

If one declaration is itself too wide, it expands internally without alignment
whitespace pretending its parts are separate bindings:

```clojure
(defn validated-coordinate
  [(coordinate
    InternationalCoordinateReferenceSystem
    coordinate-inside-supported-world-boundaries?)]
  Float
  ...)
```

There is no parameter-count threshold and no partial packing. The reader
accepts any physical layout; `beagle fmt --write .` performs the token-aware
mechanical rewrite and `beagle fmt --check .` gives people, CI, and agents the
same answer without making whitespace part of language validity.

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
.bgl + #lang beagle  →  source stage  →  typed stage  →  frozen native program
                                                                   ├─→ restricted C reference
                                                                   ├─→ QBE IL → native object
                                                                   └─→ Wasm (C17/WASI bootstrap)
```

The frozen native program owns typed operations, effects, regions, layouts,
control flow, capabilities, and ABI facts. Materializers are deliberately replaceable
projections of that same frozen program. They are judged by correct binaries and
independent agreement, not by whether a human would maintain the generated C or
QBE.

Fram's files remain Beagle; they are not rewritten as C or another systems
language. The Core path is `beagle build --materializer c17|qbe|wasm`: it
accepts canonical `.bgl`, freezes one native program, and materializes only the
selected projection. The Wasm projection currently passes through Restricted
C17 and wasi-clang; it does not claim direct Native-Core-to-Wasm emission. Its
first executable contract is deliberately only one parameterless `Int` entry;
the materializer validates the source-to-lowered-to-generated-symbol chain
before exporting and invoking it. The generated
[`fram.fri-replay` report](native-core/validation/slice-strings/replay-report.txt)
is a concrete vertical slice: real Fram parser, mutation, outcome, and replay
bodies lower into one validated Native Core program and execute through the
reference materializer.

The default flake development shell also pins the WASI C compiler, `wasm-ld`,
and Wasmtime for the wasm32 ABI validation. Run
`direnv exec . bin/beagle-test --include-gated`; its wasm32 gate runs
instead of accepting a missing-toolchain skip. Outside that shell, invoking the
driver without the toolchain remains a named diagnostic skip.

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
| `core` | Beagle Native Core | `.bgl` | `#lang beagle` | frozen native program | live — native pipeline: frozen native program; select C17, QBE, or Wasm bootstrap materializer |
| `clj` | Clojure | `.bclj` | `#lang beagle/clj` | `.clj` | live — self-hosted, oracle-certified, fuzz-guarded |
| `js` | JavaScript | `.bjs` | `#lang beagle/js` | `.js` | live — self-hosted, oracle-certified, fuzz-guarded |
| `nix` | Nix | `.bnix` | `#lang beagle/nix` | `.nix` | live — self-hosted, oracle-certified, fuzz-guarded |

Four source profiles. Core produces the authoritative frozen native program; `--materializer c17|qbe|wasm` selects a projection. `facts` is not one of them — it is the compact, lossy projection of the parsed AST into CNF analysis facts, represented as three-slot vectors (`bin/beagle-facts`): a query surface, not an authoring language. The verbose, program-lossless source↔fact projection is `beagle facts-roundtrip`, where lossless means reader-datum identity, not byte identity.
<!-- /beagle:langs -->

`beagle ast FILE` is the canonical, versioned checked-program JSON projection
for deterministic external consumers; it strictly checks but never executes
the source. Source identities are relative to the containing Git checkout, or
canonical absolute paths for files outside one. `sourceSha256` binds the exact
source bytes; `projectionSha256` binds the canonical projection with only its
own field omitted. Schema version 4 preserves namespace imports as structural
`imports` entries, and checked programs are strictly checked.
`--profile 0` is the parser-only diagnostic profile, not a dynamic language
mode.

Core is a source profile, not a direct source emitter; its row names the frozen
native program build product while the materializer remains an explicit build
option.

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
byte-level fixpoint. Current compiler, property, mutation, and native semantic
checks cover the live surface — [`docs/self-hosting.md`](docs/self-hosting.md).

## What it isn't

- **Not a schema language or general validation framework** — static type
  information erases, and only an explicitly authored binding constraint emits
  its local predicate guard. There is no schema/spec registry or conforming
  runtime.
- **Not a new Lisp in spirit** — a strict typed subset of Clojure; divergence
  from Clojure must serve the type system or a backend, or it dies.
- **Not a universal idiomatic-native transpiler** — hosted emitters exist where
  generated source is a real interface; native code comes from one frozen
  native program and replaceable materializers.
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
