# Beagle

Beagle is a typed authoring IR for agent-written programs.

Agents write compact typed source. Beagle catches mechanical mistakes — wrong fields, missing cases, invalid interop, bad generated forms — then emits ordinary Clojure, JavaScript, Python, or Nix. The types exist at authoring time and disappear at runtime.

Beagle's unusual property is that expansion, checking, and emission share one AST and one diagnostic path. Generated forms are checked the same way as hand-written forms, so procedural macros can have typed input/output contracts and still emit ordinary target code.

```text
.bclj/.bjs/.bnix/.bpy → parse → check → emit → .clj / .js / .nix / .py
                               ↑
                  expansion, checking, emission
                  share one AST + diagnostic path
```

This is an architectural consequence of being a transpiler, not a design goal we started with. We discovered it while building procedural macros and confirmed it experimentally (E18, E19).

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

Compile-time code generation with typed AST contracts. The macro body is Racket (not Beagle — this is an impedance mismatch we haven't closed yet). Inputs and outputs are contract-checked; the expansion goes through the full checking pipeline.

```racket
#lang beagle
(define-macro proc defentity
  [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
  (cons
    `(defrecord ,name ,(map (lambda (f) (list (car f) ': (caddr f))) fields))
    (map (lambda (f)
           `(defn ,(string->symbol (format "~a-~a" name (car f)))
              ((r : ,name)) : ,(caddr f)
              (get r ,(string->symbol (format ":~a" (car f))))))
         fields)))

(defentity User ((name : String) (email : String) (age : Int)))
;; → defrecord User + typed getters User-name, User-email, User-age
```

Proc macros compress 2-3× at realistic scale when you have enough instances to amortize the definition cost (crossover at 2-4 instances). Below that, hand-written code is shorter. Beagle's template macros can't express these patterns — they can't iterate over data to generate variable numbers of forms.

## Targets

**Primary**

| Target | `#lang` | Stdlib | Verified with |
|--------|---------|--------|---------------|
| Clojure | `beagle/clj` | 352 entries | Babashka |
| JavaScript | `beagle/js` | 38 native + 28 typed `js/*` forms | Node |
| Python | `beagle/py` | 131 entries | Python 3 |
| Nix | `beagle/nix` | 120 entries | nix eval |

**Experimental / verification**

| Target | `#lang` | Notes |
|--------|---------|-------|
| ClojureScript | `beagle/cljs` | 75 stdlib entries, compile-only |
| SQL | `beagle/sql` | DDL, DML, schema validation |
| Typed Racket | `beagle/rkt` | Oracle — `raco make` independently validates type promises |

269 portable stdlib entries shared across all targets.

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

[Results](experiments/e16-workflow-scheduler/results/type/RESULTS.md) · [Devlog](docs/devlog/018-e16-type-surface.md)

### E18–E19: Procedural macros

E18 measured compression: proc macros compress 2-3× at realistic scale. Beagle's template macros can't express any of the three test patterns.

E19 tested whether agents can write proc macros. A prompted agent (with docs) wrote a working macro in 2 iterations / 271s. An unprompted agent (no proc macro docs) independently invented runtime data dispatch in 1 iteration / 117s — faster and simpler, but without compile-time type coverage of the generated code. Proc macro docs are load-bearing for discoverability; without them, agents default to runtime patterns.

[E18 Results](experiments/e18-macro-compression/results/RESULTS.md) · [E19 Results](experiments/e19-agent-macro-authoring/results/RESULTS.md)

### E1–E15: Cross-language comparison

| Metric                    | Beagle | Clojure | Python + mypy |
| ------------------------- | -----: | ------: | ------------: |
| Correctness (E4, 35 bugs) |    3/3 |     0/3 |           3/3 |
| Best wall time            |   287s |    365s |          255s |

Beagle matches the typed baseline (mypy) on correctness and beats the untyped one (Clojure). mypy edges wall time — the trade Beagle makes is one typed surface across multiple backends, not single-language speed.

[Full methodology](experiments/report.md)

## Known gaps

- **Proc macro body language.** Macro bodies are Racket, not Beagle. This means macro authors need `car`/`cdr`/quasiquote — E19 showed agents can learn this from docs, but the impedance mismatch is real.
- **Cross-target macro verification.** Proc macros are tested on Clojure and JS. E22 (scoped, not yet run) will verify all 7 targets.
- **CNF visibility.** E20 (scoped) will test whether query tools see through macro expansions. If they can't, macros create black boxes in multi-agent workflows.

## Setup

Requires [Racket](https://racket-lang.org/) 8.x+.

```sh
raco pkg install beagle
```

Or from source:

```sh
raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
raco test beagle-test/tests/   # 1221 tests
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
- [`docs/devlog/`](docs/devlog/) — development journal (21 entries)
- [`experiments/report.md`](experiments/report.md) — E1–E15 results

## How Beagle relates to CNF

Beagle is the typed authoring layer. [Claim Normal Form](https://github.com/tompassarelli/claim-normal-form) is the semantic graph layer. A Beagle program can emit ordinary source code, but its typed forms also map into CNF claims so agents can query, validate, and eventually execute program structure directly.
