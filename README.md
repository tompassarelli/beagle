# Beagle

A typed Lisp authoring layer for agent-written dynamic code.

The language used to author software does not need to be the same language used to run it. Dynamic languages are excellent runtime targets — Clojure, JavaScript, Nix, SQL — but weak surfaces for code-generation agents. Too many mechanical errors survive until runtime: wrong fields, wrong arities, malformed branches, broken delimiters, implicit mutation.

Beagle separates the authoring surface from the runtime artifact. Agents write typed, structural source. Beagle checks it, queries it, repairs it, and emits ordinary target code.

**The types are scaffolding. The emitted code is the building.**

```text
source.bclj/.bjs/.bnix → parse → check → emit → output.clj / .js / .nix
                       ↑
              repair compiler
                       ↑
                daemon + AST cache
```

## Core ideas

**S-expressions as structural compression.** Source is close to an AST. Less syntax to hallucinate, less grammar to repair, less distance between source and compiler representation. Structural tools become easier because the source is already structural.

**Explicit mutation.** Mutation expands the reasoning search space. Beagle keeps it visible. Pure code can be reasoned about locally. Mutable state and target escape hatches are marked clearly enough that an agent can find the dangerous parts.

**Authoring-time types.** Types catch mechanical errors during generation — wrong fields, wrong argument shapes, missing cases, invalid interop. Then they disappear. The emitted artifact is ordinary dynamic code.

**Dynamic runtimes as targets.** Clojure stays Clojure. JavaScript stays JavaScript. Nix stays Nix. The authoring layer gives agents one typed structural surface. The emitters translate it into the languages real systems already use.

**Agent-efficiency network effects.** The winning authoring surfaces will be easy to parse, easy to query, easy to repair, compact in context, and familiar enough that current models can already write them. A typed Lisp over dynamic targets has the right shape: familiar enough to bootstrap, structural enough to tool, small enough to improve through self-hosting.

## Targets

- `#lang beagle/clj` — Clojure
- `#lang beagle/cljs` — ClojureScript
- `#lang beagle/js` — JavaScript
- `#lang beagle/nix` — Nix
- `#lang beagle/sql` — SQL

Same types, same checker, same repair compiler — different backends. Change `#lang beagle/js` to `#lang beagle/clj` and the same program emits Clojure. Target-specific `#lang`s expose target-specific forms (`await` for JS, `fn-set`/`inh`/`with-do` for Nix, Java interop for CLJ).

## A program

```racket
#lang beagle/js
(ns inventory.core)
(define-mode strict)

(defrecord StockLevel [(product-id : Int)
                       (quantity   : Int)
                       (min-qty    : Int)])

(defn understocked? [(s : StockLevel)] : Bool
  (< (stocklevel-quantity s) (stocklevel-min-qty s)))

(defn reorder-quantity [(s : StockLevel)] : Int
  (if (understocked? s)
      (- (stocklevel-min-qty s) (stocklevel-quantity s))
      0))
```

## Experiments

15 experiments, 3 language tracks, same tasks:

| Metric                    | Beagle | Clojure | Python + mypy |
| ------------------------- | -----: | ------: | ------------: |
| Correctness (E4, 35 bugs) |    3/3 |     0/3 |           3/3 |
| Best wall time            |   287s |    365s |          255s |
| Per-bug time              |   8.2s |   10.4s |          8.5s |

The correctness gap is a static-typing result, not a Beagle-specific one. Beagle's advantage over Python is workflow: reactive daemon, structured repair queue, per-bug speed.

[Full methodology and results](experiments/report.md)

## Setup

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
raco pkg install beagle
```

Or from source:

```sh
raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
raco test beagle-test/tests/   # 773 tests
```

## Agent integration

```sh
beagle init --claude-code
beagle-daemon start --watch .
```

Generates a PostToolUse hook, settings, `CLAUDE.md`, and language context. The daemon gives instant type feedback on every beagle source edit and re-checks within ~100ms of each save.

## Tooling

- **LSP server** — hover, diagnostics, symbols, jump-to-definition, completion
- **Typed REPL** — persistent environment, parse → check → emit per input
- **Reactive daemon** — AST cache, inotify file watching, ~100ms re-check
- **Repair compiler** — blame, specfix, trace, cascade analysis
- **Property testing** — record generators, return-type inference, differential testing
- **Distributed tracing** — instrument, collect, view, blame across services

See [`docs/tool-reference.md`](docs/tool-reference.md) for the full CLI catalog.

## Documentation

- [`docs/cheatsheet.md`](docs/cheatsheet.md) — single-page language summary for agent context
- [`docs/agent-workflow.md`](docs/agent-workflow.md) — repair tool routing decision tree
- [`docs/tool-reference.md`](docs/tool-reference.md) — complete CLI tool catalog
- [`docs/devlog/`](docs/devlog/) — development journal
- [`experiments/report.md`](experiments/report.md) — E1–E15 methodology and results
