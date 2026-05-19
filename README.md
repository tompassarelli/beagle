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

**S-expressions as structural compression.** Source is close to an AST. That collapses the distance between source and compiler representation, which means repair tooling can be cheap and structural rather than expensive and string-based. Less syntax to hallucinate, less grammar to repair.

**Explicit mutation.** Agents over-explore mutation-coupled programs because purity isn't legible locally — you can't tell what's safe to move, reorder, or memoize without re-deriving the whole effect structure. Beagle marks mutation explicitly, making that structure cheap to query and collapsing the reasoning search space.

**Authoring-time types.** Types catch mechanical errors during generation — wrong fields, wrong argument shapes, missing cases, invalid interop. Then they disappear. The emitted artifact is ordinary dynamic code.

**Dynamic runtimes as targets.** Clojure stays Clojure. JavaScript stays JavaScript. Nix stays Nix. The authoring layer gives agents one typed structural surface. The emitters translate it into the languages real systems already use.

**Agent-efficiency network effects.** Even a model that rarely hallucinates is cheaper to deploy against a surface where the residual errors are caught at 100ms latency by a checker than one where they survive to runtime. That cost advantage compounds: faster feedback loops, less context burned on string-level fixups, cheaper repair. A typed Lisp over dynamic targets has the right shape — familiar enough to bootstrap, structural enough to tool, small enough to improve through self-hosting.

## Targets

- `#lang beagle/clj` — Clojure
- `#lang beagle/cljs` — ClojureScript
- `#lang beagle/js` — JavaScript
- `#lang beagle/nix` — Nix
- `#lang beagle/sql` — SQL

Same types, same checker, same repair compiler — different backends. The unification is at the type-system and tooling level: one checker, one repair queue, one query interface across targets. Portable programs can switch `#lang` and re-emit, but most real code uses target-specific forms (`await` for JS, `fn-set`/`inh`/`with-do` for Nix, Java interop for CLJ).

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

The correctness gap is a static-typing result, not a Beagle-specific one. The per-bug times are noise at this scale. Beagle's real advantage over Python+mypy is the integrated toolchain — reactive daemon, AST cache, structured repair queue, blame and cascade analysis — a substrate advantage that compounds in ways that bolting types onto an existing language doesn't.

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
