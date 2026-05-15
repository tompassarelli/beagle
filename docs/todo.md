# beagle — todo

## Next

Architecture supports adding these without API breaks.

- ~~**More lint rules.**~~ Done — shadowed binding detection and unused
  extern detection added. v0 lints: untyped def/defn, unsafe escape,
  shadowed bindings, unused externs.
- ~~**Per-statement source locations.**~~ Done — type-check errors now point
  at the specific form (line:col), not the module. Both `raise-syntax-error`
  and JSON error format carry per-form positions.
- ~~**Hygienic macros.**~~ Done — gensym-based hygiene for safe macros.
  Template-introduced binders (let/fn/defn) renamed to prevent capture.
  Unsafe macros keep naive substitution by design.
- ~~**Type narrowing in `if`/`cond`.**~~ Done — flow-sensitive narrowing
  via `nil?`, `some?`, `string?`, `=`, `not` etc. Threads through cond clauses.
- ~~**Cross-file type info.**~~ Done — `(require other.module)` resolves
  the source file at compile time, imports typed defs/defns/externs/macros
  with namespace prefix (`module/name`). `:as` alias supported. Missing
  modules silently skip (types default to Any).
- ~~**Polymorphic / parametric function types.**~~ Done — `forall` types
  with type variable inference at call sites. `map`, `mapv`, `filter`,
  `filterv`, `identity` etc. properly polymorphic in stdlib catalog.
- ~~**`raco beagle ...` subcommand registration.**~~ Done — `raco beagle build`,
  `raco beagle check`, `raco beagle expand` registered via info.rkt.

## ~~Milestone: beagle vs raw Clojure head-to-head~~

Done — all three phases complete:
- Phase 1: 5 reference implementations, 10/10 behavior pass
- Phase 2: 3 LLM-generated programs (P6-P8, 35-85 functions, up to 710
  lines), parallel isolated agents, both pass first try
- Phase 3: refactoring experiment (arity cascade) + bug detection (5
  injected bugs). Neither showed measurable type-system advantage.

Key finding: types don't help at this scale because the data model uses
untyped vectors. To change the equation: typed records, multi-file
refactoring, or scale beyond ~1000 lines.

See `experiments/head-to-head/results.md`.

## Someday

Speculative; no commitment.

- **`#lang beaglelog`** — the graph-DB DSL built as macros on top of
  `#lang beagle`. Compiles through beagle to Clojure using Datascript /
  Datomic.
- **Local AI prose → beagle layer.** Take natural-language descriptions
  and translate them to beagle source. Local model so data stays private.
- **`#lang beagle/cljs`** — ClojureScript-targeted variant for browser
  / local-first apps.
- **Source maps proper.** `.clj.map` files so Clojure runtime errors
  point back at originating beagle source.
- **LSP / editor integration.** Type-aware completion, jump-to-def, etc.
- **Typed REPL.** Connect to a live Clojure socket-repl, evaluate
  beagle forms with full type checking before sending.

## Done in v0

- All forms (def, defn, fn, let, if, cond, when, do, call, vector, quote)
- Meta: ns, define-mode, require, declare-extern, define-macro, unsafe
- Types: primitives, function types (incl. variadic), parametric, union, polymorphic (forall), Any
- Macros: safe (gensym-hygienic) / unsafe with &rest and splice
- Custom reader preserving `[]`/`()`
- Stdlib extern catalog (~100 functions)
- `bin/beagle-build`, `bin/beagle-build-all`, `bin/beagle-expand`
- 149-test suite (incl. loop/recur, for comprehension, sort-by)
- `experiments/` benchmark framework (40 tasks × 3 variants, gen-prompts + score + verify-behavior)
- Head-to-head benchmark (8 programs, beagle vs raw Clojure, 16/16 pass)
- Refactoring experiment (overhead-pct cascade, 2/2 pass)
- Bug detection experiment (5 injected bugs, 2/2 pass)
- loop/recur, for (with :when), sort-by language forms
- Wrapped let-binding form: `(let [(name : Type) value ...] ...)`
- Lint pass: untyped def/defn, return-type missing, unsafe escape warnings
- Empirical benchmark: 88 responses, 5 real bugs caught + fixed, 100% behavior pass
- Structured error output (`BEAGLE_ERROR_FORMAT=json`, hints, `beagle-check`)
- `docs/findings.md` empirical log
- Form catalog (`docs/forms.md`)
- Flow-sensitive type narrowing in if/cond/when
- Cross-file type import via `(require module)` / `(require module :as alias)`
- Polymorphic stdlib (map, filter, identity etc.)
- `raco beagle build|check|expand` subcommands
