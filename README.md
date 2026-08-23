# Beagle

[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT_OR_Apache--2.0-blue.svg)](LICENSE)

**Beagle is an independent statically typed Lisp derived from Clojure.**

Derived: Clojure's vocabulary and structural authoring model — its form
library, s-expressions, data literals, `defn`/`let`/destructuring/threading
ergonomics. Independent: types, effects, execution, and memory/data model.
Beagle's source and the checked AST are authoritative; Store is optional
durable tooling, not a second language authority.

The primary hosted profiles are Clojure, JavaScript, and Nix. They share one
parser, checker, canonicalizer, and diagnostic path and emit idiomatic source
for their declared runtime. Native Core is an experimental system-layer path:
bare `.bgl` freezes a checked native program before an explicitly selected C17,
QBE, or C17/WASI Wasm bootstrap materializer. It is not a hosted profile.

Beagle Store is an optional in-repo engine for recursive Terms and Triples,
durable occurrence history, queries and indexes, provenance records, and cache
tooling. Applications may consume those storage capabilities without adopting
the Beagle frontend; Store does not define Beagle's syntax, types, or program
semantics.

Design principle: "If Clojure already has a form whose semantics are correct
for Beagle, inherit it. If the semantics differ, name the difference."

Beagle preserves Clojure where preservation has semantic value, never for
compatibility's sake. It is one source language whose parser, checker,
canonicalizer, and repair tools give people and agents the same answer: what
went wrong, where it occurred, and what a valid next edit is.

Types exist to make that loop reliable. Static type information checks at
compile time and erases before emit; an explicitly authored binding constraint
is an ordinary predicate that remains as a local runtime guard. The deeper
thesis is recorded in [`docs/INFLUENCES.md`](docs/INFLUENCES.md): one typed
authoring IR can target real ecosystems while preserving idiomatic output.

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

For a new project, `beagle init --target TARGET DIR` creates an `AGENTS.md` and
a starter source file. For Native Core, author `.bgl` with bare `#lang beagle` and choose a
materializer explicitly with `beagle build --materializer ... --out DIR FILE`.
Use `beagle help` and `beagle langs` for the current command and target
surfaces.

## POINTERS

The README is a map, not a second compiler manual. The compiler and generated
artifacts below are the authoritative answers.

| Need | Go to |
|---|---|
| Full command list and current flags | `beagle help` |
| Current source profiles, extensions, domains, and pipeline | <!-- beagle:langs names -->Clojure, JavaScript, Nix, and Beagle Native Core (experimental)<!-- /beagle:langs -->; query `beagle langs` (or `beagle langs --json`) |
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
| Surface policy and contribution anchor | [`AGENTS.md`](AGENTS.md) |

## Status and license

Beagle is pre-1.0 and its surface may change through hard breaks. The
repository gates correctness, not speed, and publishes no performance numbers.

Dual-licensed under the [MIT License](LICENSE-MIT) or the [Apache License, Version 2.0](LICENSE-APACHE), at your option. See [`LICENSE`](LICENSE) for the
chooser.
