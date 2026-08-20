# Beagle

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

**Beagle is a durable programming system driven through semantic
computation.**

Beagle has five distinct surfaces that share one checked semantic core:

- a typed Lisp authoring surface derived from Clojure;
- Beagle Store, the durable semantic substrate;
- a compiler that checks programs and records dependency and provenance;
- replaceable target materializations with explicit capability envelopes; and
- an effect and observation boundary between pure computation and external
  reality.

The system thesis is:

> Pure software artifacts are reproducible projections of durable semantic
> worlds; external reality is connected through explicit observations and
> capability-controlled effects.

Beagle has one durable identity, explanation, dependency, and provenance
model. That does not mean one key or one machine. Content, assertion
occurrences, semantic revisions, compiler rules, and artifacts keep distinct
identities. Many versioned branches and roots, physical Stores, execution
domains, trust domains, failure domains, and materializations can participate
without being collapsed. Matching content establishes identity, not trust,
authority, co-location, or transaction scope.

A program world (`WORLD`) is the broad semantic snapshot concept: a versioned
selection of facts, judgments, rules, plans, and provenance. It is not a Store
branch. A branch or named root selects durable semantic history; several may
contribute to, or be projected from, a world without becoming the same thing.
Pure artifacts are reproducible projections of named durable branches or
worlds. External reality can participate in the same typed fact system through
observations and receipts, but is never assumed pure.

Beagle keeps two classifications separate. `Declared`, `Derived`, and
`Observed` are epistemic origins: how a fact entered an explanation. Acting on
the outside world follows an action protocol of `Intent`, `Authorization`,
`Attempt`, and `EffectReceipt`. Desired deployment state and plans may be
derived purely; execution requires a capability, and produces receipts and
later observations rather than retroactively making the plan an observation.

**Beagle Store** supplies durable terms, assertion occurrences, transaction
history, identity, provenance, and query. Inside Beagle it is the cohesive
semantic substrate, not a bolted-on database product. Existing systems may
still consume it through database-, storage-, or cache-shaped capability
interfaces without adopting the language frontend; see the
[brownfield capability guide](store/docs/isolation-and-deployment.md#capability-profiles).

Targets are replaceable materializations of the shared checked core, with
target-specific capabilities explicit. Bare `.bgl` lowers deliberately to
Native Core rather than JVM Clojure semantics. A `.bclj` capsule targets the
Java/Clojure runtime and may use JVM Clojure features admitted by that profile;
Native Core's constraints are not a categorical statement about every Beagle
profile.

Incremental reuse has a measurable invariant. A reusable-result key is judged
by completeness, narrowness, identification cost, stability, and compiler-rule
identity. Warm work must be proportional to the invalidated semantic region
plus bounded identification and authentication overhead, and a warm result
must equal a clean result. The repository publishes no benchmark claim from
that invariant alone.

Design principle: "If Clojure already has a form whose semantics are correct
for Beagle, inherit it. If the semantics differ, name the difference."

Beagle preserves Clojure where preservation has semantic value. It is one
source language whose parser, checker, canonicalizer, and repair tools give
people and agents the same answer: what went wrong, where it occurred, and what
a valid next edit is.

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
