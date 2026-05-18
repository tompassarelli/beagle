# Beagle

A language where mechanical bugs compile into patches.

Beagle is an agent-native typed authoring layer for
Clojure/ClojureScript: it gives coding agents a compiler, repair queue,
and structural query tools, then emits plain `.clj` / `.cljs`.

The thesis is simple: mechanical bugs should not require cognition.
Shape errors should be caught by types. Runtime failures should become
ranked, machine-actionable repair candidates. The goal is to spend zero
reasoning tokens on mechanical fixes — the agent's budget goes to
semantic bugs that actually require judgment.

```
source.rkt → parse → check → emit → output.clj
                       ↑
             repair compiler
                       ↑
                 daemon + AST cache
```

The runtime target stays normal Clojure. If you stop using Beagle, you
keep the emitted `.clj` / `.cljs`.

## Experiments

The point was not to prove Beagle is "smarter" than Clojure or Python.
The point was to measure repair distance: how much work an agent has to
do after a bug is introduced.

15 experiments, 3 language tracks, same tasks:

| | Beagle | Clojure | Python + mypy |
|---|---|---|---|
| Correctness (E4, 35 bugs) | 3/3 | 0/3 | 3/3 |
| Best wall time | 287s | 365s | 255s |
| Per-bug time | 8.2s | 10.4s | 8.5s |

The correctness gap is a static-typing result, not a Beagle-specific
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

## Setup

Requires [Racket](https://racket-lang.org/) and
[Babashka](https://babashka.org/).

```
raco pkg install --link --auto /path/to/beagle
raco test tests/
```

## Agent integration

**Claude Code** (one command):

```
beagle init --claude-code
beagle-daemon start --watch .
```

Generates PostToolUse hook (instant type feedback on every `.rkt` edit),
settings, CLAUDE.md, and language context. The daemon re-checks within
~100ms of each save.

**MCP** (any agent framework):

```
beagle mcp
```

9 tools over stdio: `sig`, `fields`, `callers`, `provides`, `impact`,
`check`, `check_enriched`, `build`, `expand`. Daemon-first, CLI fallback.

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
