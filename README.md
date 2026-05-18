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

## Evidence

Fifteen experiments (E1–E15) across three language tracks (Beagle,
Clojure, Python), head-to-head on the same tasks.

**E4** (13 modules, 8570 LOC, 35 injected bugs): beagle 3/3
correctness vs clojure 0/3. First reproducible divergence — but this
is a static-typing result, not a beagle result: Python + mypy also
achieves 3/3.

**E13** (reactive daemon): 287s avg — variance collapsed from 142s
range to 59s. Per-bug faster than Python + mypy (8.2s vs 8.5s). The
best single-agent configuration. Within Clojure: 21% faster than the
best clj-kondo configuration (365s).

Full methodology and results: [`experiments/report.md`](experiments/report.md)

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
