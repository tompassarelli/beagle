# Beagle

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

**Beagle is a durable programming system driven through semantic
computation.**

The system thesis is:

> Pure software artifacts are reproducible projections of durable semantic
> worlds; external reality is connected through explicit observations and
> capability-controlled effects.

Beagle has one durable identity and explanation model. A program world
(`WORLD`) is a versioned semantic explanation: facts, judgments, provenance,
and plans from which pure, reproducible artifacts are projected. It distinguishes
what was declared, derived, observed, and effect-recorded. Desired state is not
observed state; an authorized effect returns a receipt and new observations,
which can then support claims about external reality.

Content, an assertion occurrence, a world revision, and a produced artifact
have distinct identities. Hashes identify records, while authority, evidence,
freshness, and policy determine what a record justifies. Content identity is
not trust.

The language is a typed Lisp with a Clojure-derived core. Its compiler and
runtime operate through this semantic model. **Beagle Store** is the integrated
durable identity, provenance, transaction-history, and query subsystem—not a
separate database product. One model can support many versioned worlds,
materializations, and execution domains without merging their physical or
security boundaries.

External execution is capability-controlled. JavaScript, Clojure, Nix, C17,
and Wasm are replaceable materializations with explicit target capabilities;
shared content identity never grants permission to execute. See the
[system architecture](docs/architecture.md#one-semantic-substrate). An existing
system can also adopt Store through a bounded capability interface without
adopting the language frontend; see the
[brownfield capability guide](store/docs/isolation-and-deployment.md#capability-profiles).

Derived: Clojure's vocabulary and structural authoring model — its form
library, s-expressions, data literals, `defn`/`let`/destructuring/threading
ergonomics. Beagle owns static types, effects, and checked semantic
identity/provenance. Execution and memory semantics belong to each profile: the
Clojure-targeted region/profile retains the Clojure runtime facilities supplied
by its execution runtime, including lazy sequences, dynamic vars, and
GC-backed persistent collections; Native Core lowering alone rejects JVM
dependence and uses Store-backed durability, arenas/regions, and explicit
native capabilities. JavaScript and Nix profiles likewise expose admitted host
semantics, not one shared runtime.

Design principle: "If Clojure already has a form whose semantics are correct
for Beagle, inherit it. If the semantics differ, name the difference."

Beagle preserves Clojure where preservation has semantic value, never for
compatibility's sake. It is one source language whose parser, checker,
canonicalizer, and repair tools give people and agents the same answer: what
went wrong, where it occurred, and what a valid next edit is.

Types exist to make that loop reliable. Static type information checks at
compile time and erases before emit; an explicitly authored binding constraint
is an ordinary predicate that remains as a local runtime guard. The deeper
thesis is recorded in [`docs/INFLUENCES.md`](docs/INFLUENCES.md): Beagle's proven portable
semantic core targets admitted ecosystems with idiomatic output within each profile envelope;
regime-bound code is accepted only by its declared profile and is never cross-emitted.

Beagle has a Native Core path and explicit hosted source profiles. The live
profiles, extensions, form set, and materializers are compiler-owned: query
`beagle langs`, `beagle syntax`, `beagle sig`, and `beagle fields` instead of
copying a list that can drift.

## Quickstart

Inside the flake's devshell (`direnv allow`), `bin/beagle` is the `beagle`
command used below. No database or coordinator is required.

```console
$ mkdir -p src build
$ cat src/main.bclj
#lang beagle/clj
(ns main)

(defn greet [name String] String
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

For a new project, `beagle init --hooks --target TARGET DIR` installs the edit
loop. For Native Core, author `.bgl` with bare `#lang beagle` and choose a
materializer explicitly with `beagle build --materializer ... --out DIR FILE`.
Use `beagle help` and `beagle langs` for the current command and target
surfaces.

## POINTERS

The README is a map, not a second compiler manual. The compiler and generated
artifacts below are the authoritative answers.

| Need | Go to |
|---|---|
| Full command list and current flags | `beagle help` |
| Current source profiles, extensions, domains, and pipeline | <!-- beagle:langs names -->Beagle Native Core, Clojure, JavaScript, and Nix<!-- /beagle:langs -->; query `beagle langs` (or `beagle langs --json`) |
| Parse, form, and syntax questions | `beagle syntax FILE`; [`docs/CHEATSHEET.md`](docs/CHEATSHEET.md) |
| A function's signature or a record's fields | `beagle sig NAME FILE...`; `beagle fields RECORD FILE` |
| Callers, exports, and change impact | `beagle callers FN FILE...`; `beagle provides FILE`; `beagle impact FN FILE...` |
| Surface details not enumerated by the generated cheatsheet | [`docs/surface.md`](docs/surface.md) |
| CLI, authoring loop, build outputs, and Wasm contract | [`docs/cli.md`](docs/cli.md) |
| Compiler pipeline and where to change it | [`docs/architecture.md`](docs/architecture.md) |
| Hosted targets versus Native Core examples | [`docs/targets-by-example.md`](docs/targets-by-example.md) |
| Target registry and deliberately non-target projections | [`docs/target-policy.md`](docs/target-policy.md) |
| Why the compiler's correctness claims hold | [`docs/self-hosting.md`](docs/self-hosting.md) |
| Authoring-loop vocabulary and composition | [`docs/authoring-loops.md`](docs/authoring-loops.md) |
| Value semantics and type-driven representation selection | [`docs/value-semantics-ownership.md`](docs/value-semantics-ownership.md) |
| Distilled lineage and thesis | [`docs/INFLUENCES.md`](docs/INFLUENCES.md) |
| Stable product boundaries | [`docs/design-rationale.md`](docs/design-rationale.md) |
| Historical dogfood findings | [`docs/dogfood-codegen-findings.md`](docs/dogfood-codegen-findings.md) |
| Beagle Store and brownfield capability examples | [`store/README.md`](store/README.md) |
| Surface policy and contribution anchor | [`CLAUDE.md`](CLAUDE.md) |

## Status and license

Beagle is pre-1.0 and its surface may change through hard breaks. The
repository gates correctness, not speed, and publishes no performance numbers.

Dual-licensed under the [MIT License](LICENSE-MIT) or the [Apache License, Version 2.0](LICENSE-APACHE), at your option. See [`LICENSE`](LICENSE) for the
chooser.
