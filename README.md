# Beagle

Beagle is a typed authoring layer for agent-written software.

Agents write compact source. Beagle expands it, checks it, and emits ordinary target code. The types exist at authoring time and disappear at runtime.

```text
.bclj/.bjs/.bnix/.bpy → parse → check → emit → .clj / .js / .nix / .py
                               ↑
                  expansion, checking, emission
                  share one AST + diagnostic path
```

This is an architectural consequence of being a transpiler, not a design goal we started with. We discovered it while building procedural macros and confirmed it experimentally (E18, E19). It means generated code is checked the same way as hand-written code — procedural macros get typed input/output contracts for free.

```text
target language  =  deployment format
Beagle AST       =  authoring format
CNF graph        =  reasoning format
```

Beagle emits code for runtimes. It also emits [claims](https://github.com/tompassarelli/claim-normal-form) for agents. The same program can be executed by ordinary tools and reasoned about structurally by agent tools.

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

## Procedural macros

Compile-time code generation with typed AST contracts. Macro bodies are written in Beagle using syntax constructors — no context-switch to Racket. Inputs and outputs are contract-checked; the expansion goes through the full checking pipeline.

```racket
#lang beagle
(define-macro beagle defentity
  [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
  (let [record (make-defrecord name
                 (map (fn [(f : Syntax)]
                   (make-field (syntax-name f) (syntax-type f)))
                   fields))
        getters (map (fn [(f : Syntax)]
                   (make-defn
                     (format-symbol "~a-~a" name (syntax-name f))
                     (list (make-param 'r name))
                     (syntax-type f)
                     (make-get 'r (make-keyword (syntax-name f)))))
                  fields)]
    (cons record getters)))

(defentity User ((name : String) (email : String) (age : Int)))
;; → defrecord User + typed getters User-name, User-email, User-age
```

Proc macros compress 2-3× at realistic scale when you have enough instances to amortize the definition cost (crossover at 2-4 instances). Below that, hand-written code is shorter. Beagle's template macros can't express these patterns — they can't iterate over data to generate variable numbers of forms.

## Targets

**Primary**

| Target | `#lang` | Stdlib | Verified with |
|--------|---------|--------|---------------|
| Clojure | `beagle/clj` | 414 entries | Babashka |
| JavaScript | `beagle/js` | 55 native + 28 typed `js/*` forms | Node / Bun |
| Python | `beagle/py` | 151 entries | Python 3 |
| Nix | `beagle/nix` | 111 entries | nix eval |

**Experimental / verification**

| Target | `#lang` | Notes |
|--------|---------|-------|
| ClojureScript | `beagle/cljs` | 86 stdlib entries, compile-only |
| SQL | `beagle/sql` | 54 stdlib entries, DDL, DML, schema validation |
| Typed Racket | `beagle/rkt` | Oracle — `raco make` independently validates type promises |

319 portable stdlib entries shared across all targets (~1190 total).

## Self-hosting

Beagle compiles itself. 12 `.bjs` components (reader, parser, type checker, 5 emitters, AST, macros, lint, types) are written in Beagle targeting JavaScript. The Racket compiler compiles them to JS, producing a standalone `compiler.cjs` that runs on Bun — then that bundle compiles the same `.bjs` sources and produces identical output (bootstrap fixed-point proven).

The self-hosted compiler is the primary path for [Heist](https://github.com/tompassarelli/heist), a full-stack app framework dogfooding Beagle.

## Raw strings

`#r"..."` literals pass through without escape processing. Delimiter escalation with `#` characters for strings containing quotes:

```racket
#r"no escapes needed"
#r#"contains "quotes" freely"#
#r##"contains "# sequences"##
```

Useful for embedding JS/SQL/HTML templates, regex patterns, and `fmt` interpolation templates.

## Experiments

### E16: Does the type checker make agents faster?

4 features built by Claude Sonnet agents — one group with no type checker, one with Beagle's structural checker (n=4, treat as directional):

| | No types | With types | |
|---|---:|---:|---|
| Avg build time | 362s | **274s** | **24% faster** |
| Correctness | 8/8 | 8/8 | identical |
| Hardest feature | 600s | **328s** | **45% faster** |

Types didn't move correctness at this scale — they moved how fast the agent got there, with the gap widening on features with more coordination complexity.

The load-bearing finding is about *integration*, not the checker itself: the same checker, poorly wired into the agent loop (noisy output, wrong workflow position, vague framing), imposed a 76% penalty. Three non-code fixes swung the outcome by 100 percentage points. The contribution is as much *how* the checker reaches the agent as the checker.

[Results](https://github.com/tompassarelli/beagle-lab/blob/main/e16-workflow-scheduler/results/type/RESULTS.md) · [Devlog](docs/devlog/018-e16-type-surface.md)

### E18–E19: Procedural macros

E18 measured compression: proc macros compress 2-3× at realistic scale. Beagle's template macros can't express any of the three test patterns.

E19 tested whether agents can write proc macros. A prompted agent (with docs) wrote a working macro in 2 iterations / 271s. An unprompted agent (no proc macro docs) independently invented runtime data dispatch in 1 iteration / 117s — faster and simpler, but without compile-time type coverage of the generated code. Proc macro docs are load-bearing for discoverability; without them, agents default to runtime patterns.

[E18 Results](https://github.com/tompassarelli/beagle-lab/blob/main/e18-macro-compression/results/RESULTS.md) · [E19 Results](https://github.com/tompassarelli/beagle-lab/blob/main/e19-agent-macro-authoring/results/RESULTS.md)

### E1–E15: Cross-language comparison

| Metric                    | Beagle | Clojure | Python + mypy |
| ------------------------- | -----: | ------: | ------------: |
| Correctness (E4, 35 bugs) |    3/3 |     0/3 |           3/3 |
| Best wall time            |   287s |    365s |          255s |

Beagle matches the typed baseline (mypy) on correctness and beats the untyped one (Clojure). mypy edges wall time — the trade Beagle makes is one typed surface across multiple backends, not single-language speed.

[Full methodology](https://github.com/tompassarelli/beagle-lab)

## Things we had to prove

- ~~**Proc macro body language.**~~ Resolved: `define-macro beagle` evaluates macro bodies as Beagle using syntax constructors. No context-switch to Racket.
- ~~**Cross-target macro verification.**~~ Resolved (E22): same proc macro compiles and runs identically on all 6 non-SQL targets.
- ~~**CNF visibility.**~~ Resolved (E20): query tools expand macros before extracting definitions.

## Setup

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
raco pkg install beagle
```

Or from source:

```sh
raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
raco test beagle-test/tests/   # 1222 tests
```

## Agent integration

```sh
beagle init --claude-code
beagle-daemon start --watch .
```

Generates a PostToolUse hook, settings, `CLAUDE.md`, and language context. The daemon re-checks within ~100ms of each save.

## Tooling

- **LSP server** — hover, diagnostics, symbols, jump-to-definition, completion
- **Typed REPL** — persistent environment, parse → check → emit per input
- **Reactive daemon** — AST cache, inotify file watching, ~100ms re-check
- **Repair compiler** — blame, specfix, trace, cascade analysis
- **Property testing** — record generators, return-type inference, differential testing

## Documentation

- [`docs/cheatsheet.md`](docs/cheatsheet.md) — language summary
- [`docs/agent-workflow.md`](docs/agent-workflow.md) — repair tool routing
- [`docs/tool-reference.md`](docs/tool-reference.md) — CLI and tool catalog
- [`docs/devlog/`](docs/devlog/) — development journal (23 entries)
- [`beagle-lab`](https://github.com/tompassarelli/beagle-lab) — research journal: experiment tasks, results, methodology (E0–E22)

