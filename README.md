# beagle

A language where the compiler does the debugging.

Beagle is a typed authoring layer that currently targets
Clojure and ClojureScript. Racket frontend, custom `#lang`, static
type checking — emits plain `.clj` / `.cljs` for runtime. Built for LLM agents: rich types, explicit forms, low
syntactic surface area, structured errors. One canonical idiom per
concept.

## Thesis

Beagle does not maximize type purity. Beagle minimizes *repair
distance* — the work between "here is a bug" and "here is the fix."

Types catch shape errors at compile time. A repair compiler turns
runtime failures into ranked, machine-actionable fix candidates. The
compiler annotates problems — it doesn't block execution.

## Evidence

Nine experiments (E1–E9) across 48 hours, head-to-head against raw
Clojure on the same tasks with the same model (Opus 4.6).

**E4** (13 modules, 8570 LOC, 35 injected bugs): beagle 3/3
correctness vs clojure 0/3 — first reproducible divergence where
types produce measurably better outcomes.

**E9** (same system + repair toolchain, 3 runs each): beagle averages
77 turns / 421s / 21.6K tokens vs clojure 88 turns / 595s / 33.9K
tokens. **29% faster, 36% fewer tokens, lower variance.** Both
tracks 3/3 correctness — the advantage is efficiency.

## Architecture

```
source.rkt → parse → check → emit → output.clj
                       ↑
             repair compiler (blame, trace, specfix, cascade)
                       ↑
                 daemon (persistent AST cache, 45× query speedup)
```

- `lang/reader.rkt` — custom reader preserving `[]` vs `()`
- `private/parse.rkt` — source → AST (two-pass: meta collection, then exprs)
- `private/check.rkt` — type checking, record fields, flow narrowing
- `private/emit.rkt` — AST → qualified Clojure source with source maps
- `private/daemon.rkt` — TCP server, AST cache with mtime invalidation

Plain `#lang racket/base` throughout — beagle implements its own type
system rather than using Typed Racket.

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

## Language

**Forms:** `def`, `defn` (single + multi-arity, varargs with `&`),
`fn`, `let`, `if`, `cond`, `when`, `do`, `match`, `loop`/`recur`,
`for`/`doseq`, `try`/`catch`, `case`, `defrecord`, `with` (typed
record update), `defenum`, `defprotocol`, `defmulti`/`defmethod`,
`deftype`, `extend-type`, `defscalar`, threading (`->`, `->>`),
map/set literals, keyword-as-function, destructuring

**Types:** primitives (`String`, `Long`, `Double`, `Boolean`,
`Keyword`, `Symbol`, `Nil`, `Any`), function types (variadic),
parametric (`Vec`, `Map`, `Set`), union (`U`), nullable (`String?`),
polymorphic (`forall`), user records, nominal scalars

**Cross-module:** `(require module :as alias)` imports types, records,
constructors, accessors, macros — all validated at call sites

**Stdlib:** ~607 Clojure functions pre-typed, key HOFs polymorphic

**Diagnostics:** Rust-style errors with source lines, signatures,
"did you mean?" suggestions; JSON mode for programmatic consumption

## Repair compiler

The repair compiler closes the loop: agent writes code → evidence
system produces a ranked repair queue → agent applies fixes → done.

| Tool | What it does |
|------|-------------|
| `beagle-repair` | Unified pipeline: type errors + blame + specfix → ranked queue |
| `beagle-trace` | Per-assertion arithmetic trace — exact divergence point |
| `beagle-specfix` | Oracle-guided candidate fixes (verified, not suggested) |
| `beagle-cascade` | Call graph impact — find root causes, not symptoms |
| `beagle-blame` | Ratio analysis: sign error, wrong operator, missing term |
| `beagle-oracle` | Behavioral oracle from golden code (golden = test spec) |

## Query tools

The type system is a query interface, not just a proof obligation.
With daemon running: 10ms per query (vs 450ms cold).

```bash
beagle-sig order-total .           # [Order -> Amount]
beagle-fields Invoice .            # typed fields + accessors
beagle-callers order-total .       # all call sites + arg counts
beagle-provides billing.rkt        # full module export list
beagle-impact order-total .        # callers + downstream effects
```

```bash
beagle-daemon start     # persistent TCP server, ephemeral port
beagle-daemon status    # cached file count, uptime
beagle-daemon stop      # graceful shutdown
```

## Build & check

```bash
beagle-build-all *.rkt --out .build/   # batch compile (9×)
beagle-check-all .                     # batch type-check (10×)
beagle-build source.rkt [out.clj]      # single file
beagle-check source.rkt                # type-check only
beagle-expand source.rkt               # post-macro expansion
```

Oracle runs use Babashka for 12× speedup over JVM Clojure.

## Escape hatches

1. `(unsafe "raw clojure")` — literal Clojure, top-level or expression
2. `(define-macro unsafe ...)` — macro expansion typed as `Any`
3. `(define-mode dynamic)` — skip type checking for a file
4. `--warn` flag — emit despite type errors (annotate, don't block)

## Setup

Requires [Racket](https://racket-lang.org/) and
[Babashka](https://babashka.org/).

```
raco pkg install --link --auto /path/to/beagle
raco test tests/   # 338 tests
```

## Reference

- `docs/cheatsheet.md` — single-page language reference (LLM context)
- `docs/agent-workflow.md` — repair tool routing decision tree
- `docs/forms.md` — canonical form catalog
- `docs/devlog/` — development journal, 13 entries over 48 hours
- `experiments/` — E1–E9 benchmark framework + trial data
