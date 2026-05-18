# Beagle

Beagle is an agent-native typed authoring layer for dynamic languages. It gives coding agents a compiler, repair queue, and structural query tools, then emits ordinary source in the target language.

Currently supported targets:

- `#lang beagle/clj` — Clojure
- `#lang beagle/cljs` — ClojureScript
- `#lang beagle/js` — JavaScript

Same types, same checker, same repair compiler — different backends.

The thesis is simple: **mechanical bugs should not require cognition.**

Shape errors should be caught by types. Checker failures become ranked, machine-actionable repair candidates. Runtime failures can be routed into the same repair workflow. The goal is to spend zero reasoning tokens on mechanical fixes — the agent's budget goes to semantic bugs that actually require judgment.

```text
source.bgl → parse → check → emit → output.clj / .cljs / .js
                       ↑
              repair compiler
                       ↑
                daemon + AST cache
```

The runtime stays ordinary target code. If you stop using Beagle, you keep the emitted source.

## Why this syntax

Beagle's surface language is Clojure-shaped. That is deliberate: syntax is part of the repair surface.

**S-expressions make structure explicit.** The reader produces nested structure directly instead of reconstructing it from precedence rules, semicolon insertion, and ambiguous statement grammar. That makes Beagle easier to parse, easier to transform, and easier to repair. The common complaint that Lisp syntax is "hard to read" is mostly familiarity cost; the structural complexity is lower, not higher.

**Clojure's brackets and braces remove real ambiguity.** `[x y]` is a vector. `(f x y)` is a call. `{:a 1 :b 2}` is a map literal, not a block. Scheme-style pure parens blur data and computation visually; Clojure fixes that with lightweight structural punctuation. Beagle inherits that choice because it helps both human readers and language models.

**Immutability by default reduces the search space.** `def` produces a constant. `defrecord` produces frozen data. `with` returns a new value. Mutation exists only through explicit escape hatches: atoms, interop, or target-specific forms. That means most Beagle code can be reasoned about locally without tracking hidden assignment.

**Clojure has useful training data.** LLMs can bootstrap from existing Clojure forms, idioms, and naming conventions. Beagle then narrows the surface: one parameter syntax, one annotation marker, one canonical idiom per concept, and no reader-macro zoo. Fewer valid interpretations means less ambiguity during generation and repair.

## A program

```racket
#lang beagle/js
(ns inventory.core)
(define-mode strict)

(defrecord StockLevel [(product-id : Int)
                       (quantity   : Int)
                       (min-qty   : Int)])

(defn understocked? [(s : StockLevel)] : Bool
  (< (stocklevel-quantity s) (stocklevel-min-qty s)))

(defn reorder-quantity [(s : StockLevel)] : Int
  (if (understocked? s)
      (- (stocklevel-min-qty s) (stocklevel-quantity s))
      0))
```

Portable Beagle source can emit to any supported target — change `#lang beagle/js` to `#lang beagle/clj` and the same program emits Clojure. Target-specific `#lang`s expose target-specific forms (`await` for JS, Java interop for CLJ).

## Experiments

Agents repair code faster when mechanical failures are surfaced as structured compiler feedback instead of runtime archaeology. 15 experiments, 3 language tracks, same tasks:

| Metric                    | Beagle | Clojure | Python + mypy |
| ------------------------- | -----: | ------: | ------------: |
| Correctness (E4, 35 bugs) |    3/3 |     0/3 |           3/3 |
| Best wall time            |   287s |    365s |          255s |
| Per-bug time              |   8.2s |   10.4s |          8.5s |

The correctness gap is a static-typing result, not a Beagle-specific one. Beagle's advantage over Python is workflow: reactive daemon, structured repair queue, per-bug speed.

[Full methodology and results](experiments/report.md)

## Setup

Requires [Racket](https://racket-lang.org/) and [Babashka](https://babashka.org/).

```sh
raco pkg install --link --auto /path/to/beagle
raco test tests/   # 500+ tests
```

## Agent integration

Claude Code:

```sh
beagle init --claude-code
beagle-daemon start --watch .
```

Generates a PostToolUse hook, settings, `CLAUDE.md`, and language context. The daemon gives instant type feedback on every `.bgl`/`.rkt` edit and re-checks within ~100ms of each save.

MCP:

```sh
beagle mcp
```

9 tools over stdio: `sig`, `fields`, `callers`, `provides`, `impact`, `check`, `check_enriched`, `build`, `expand`.

Daemon-first, CLI fallback.

## Documentation

Scribble docs:

```sh
raco docs beagle
```

Standalone HTML:

```sh
raco scribble --html scribblings/beagle.scrbl
```

Other references:

- [`docs/cheatsheet.md`](docs/cheatsheet.md) — single-page language summary for agent context
- [`docs/agent-workflow.md`](docs/agent-workflow.md) — repair tool routing decision tree
- [`docs/prompts/`](docs/prompts/) — pre-built agent system prompts
- [`docs/devlog/`](docs/devlog/) — development journal
- [`experiments/report.md`](experiments/report.md) — E1–E15 methodology and results
