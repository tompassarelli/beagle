# beagle

A language where the compiler does the debugging.

Beagle is an agent-native language: a typed authoring layer targeting
Clojure/ClojureScript, designed to minimize agent repair distance.
Racket frontend, custom `#lang`, static type checking — emits plain
`.clj` / `.cljs` for runtime.

Mechanical bugs should not require cognition. They should compile into
patches. Types catch shape errors at compile time. A repair compiler
turns runtime failures into ranked, machine-actionable fix candidates.
Zero reasoning tokens on mechanical fixes; the agent's budget is spent
entirely on semantic bugs that require judgment.

## Experiments

15 experiments, 3 language tracks (Beagle, Clojure, Python), same tasks.

| | Beagle | Clojure | Python + mypy |
|---|---|---|---|
| Correctness (E4, 35 bugs) | 3/3 | 0/3 | 3/3 |
| Best wall time | 287s | 365s | 255s |
| Per-bug time | 8.2s | 10.4s | 8.5s |

The correctness gap is a static-typing result, not a beagle-specific
one. Beagle's advantage over Python is workflow: reactive daemon,
structured repair queue, per-bug speed.

[Full methodology and results](experiments/report.md)

## A program

```racket
#lang beagle
(ns inventory.core)
(define-mode strict)
(require catalog :as cat)

(defrecord StockLevel [(product-id : Long)
                       (quantity   : Long)
                       (min-qty   : Long)])

(defn understocked? [(s : StockLevel)] : Boolean
  (< (stocklevel-quantity s) (stocklevel-min-qty s)))

(defn reorder-quantity [(s : StockLevel)] : Long
  (if (understocked? s)
      (- (stocklevel-min-qty s) (stocklevel-quantity s))
      0))
```

## Architecture

```
source.rkt → parse → check → emit → output.clj
                       ↑
             repair compiler (blame, trace, specfix, cascade)
                       ↑
                 daemon (persistent AST cache, 45× query speedup)
```

Plain `#lang racket/base` throughout — beagle implements its own type
system rather than using Typed Racket.

## Setup

Requires [Racket](https://racket-lang.org/) and
[Babashka](https://babashka.org/).

```
raco pkg install --link --auto /path/to/beagle
raco test tests/   # 466 tests
```

## Documentation

**Scribble docs** (language reference, all forms, types, tools):

```
raco docs beagle
```

Or build standalone HTML: `raco scribble --html scribblings/beagle.scrbl`

**Other references:**

- [`docs/cheatsheet.md`](docs/cheatsheet.md) — single-page language summary (LLM system context)
- [`docs/agent-workflow.md`](docs/agent-workflow.md) — repair tool routing decision tree
- [`docs/prompts/`](docs/prompts/) — pre-built agent system prompts (consumer + contributor)
- [`docs/devlog/`](docs/devlog/) — development journal
- [`experiments/report.md`](experiments/report.md) — E1–E15 methodology and results
