# beagle — session anchor

A typed authoring layer that compiles to Clojure. Racket frontend with
custom `#lang`, macros (safe/unsafe boundaries), static type checking; emits
plain Clojure source for runtime.

**LLM authoring is a first-class concern.** Beagle's design treats AI
generation as a primary use case: rich types, explicit forms, low syntactic
surface area, structured errors. Human ergonomics is not sacrificed — but
when there's tension, AI-friendliness wins.

**Quick reference:** `docs/cheatsheet.md` is the single-page language
summary designed to be loaded as system context for LLM workflows. Treat
it as canonical when explaining the language.

## What this is — and what it isn't

Beagle is a **general typed Clojure DSL** with LLM authoring as a first-class concern. It
is NOT a graph-database tool. A future `#lang beaglelog` layer for graph-DB
work would be built **on top of** beagle, not as beagle primitives.

## Status

`#lang beagle` v0 — end-to-end working, empirically validated:

- Forms: `def`, `defn`, `fn`, `let`, `if`, `cond`, `when`, `do`, `loop`,
  `recur`, `for` (with `:when`), call, vector literal, quote
- Meta: `ns`, `define-mode`, `require`, `declare-extern`, `define-macro`,
  `unsafe` (top-level AND in expression position)
- Param syntax: **wrapped only** — `(name : Type)`. Single canonical marker `:`.
  Inline annotations and `:-` marker were removed in the AI-optimization
  pass (one idiom per concept).
- Types: primitives (`String`, `Long`, `Double`, `Boolean`, `Keyword`,
  `Symbol`, `Nil`, `Any` — no aliases), function types (variadic with `& T`),
  parametric (`Vec`, `Map`, `Set`, `List`), union (`U`), polymorphic (`forall`)
- Type narrowing: flow-sensitive in `if`/`cond`/`when` via `nil?`, `some?`,
  `string?`, `=`, `not` etc. Threads through cond clauses.
- Macros: safe (gensym-hygienic) / unsafe with `&rest` and `(splice ...)`
- Stdlib catalog: ~100 common Clojure functions pre-typed, key HOFs polymorphic
- Cross-file type import: `(require module)` / `(require module :as alias)`
  resolves source at compile time, imports typed defs/defns/externs/macros
- Validation: type checks, arity (incl. variadic), undefined refs, hints
- Lint pass: untyped def/defn, unsafe usage, shadowed bindings, unused externs
- Structured error output: `BEAGLE_ERROR_FORMAT=json` for agent consumption
- 3 benchmark variants (A canonical, B required-types, C minimal)
- 149 tests passing
- 40 benchmark tasks with real Clojure behavior verification
- 8 head-to-head programs (beagle vs raw Clojure), 16/16 behavior pass
- Refactoring + bug-detection experiments (arity cascade, injected bugs)
- Validated by empirical agent benchmarks — 5 real bugs caught and fixed, 88 behavior verifications passing

## Architecture

```
parse → check → emit
(all expand-time, inside our custom #%module-begin)
```

- `lang/reader.rkt` — custom reader preserving `[]` vs `()` via
  `#%brackets` tag (`read-square-bracket-with-tag`).
- `private/types.rkt` — type AST, parser, compatibility checker.
- `private/stdlib-types.rkt` — pre-typed Clojure stdlib catalog (single
  biggest leverage point for AI safety net).
- `private/macros.rkt` — macro registry, naive substitution, depth-capped
  recursive expansion, safe/unsafe boundary.
- `private/parse.rkt` — source → AST. Two passes: meta-form collection
  (mode, ns, macros, externs, requires) then expr parsing with macro expansion.
- `private/check.rkt` — best-effort type checking against annotations and
  the built-in env. Skipped in dynamic mode.
- `private/emit.rkt` — AST → Clojure source string.
- `private/expand-tool.rkt` — backend for `bin/beagle-expand`.
- `main.rkt` — language module; `#%module-begin` runs the pipeline,
  embeds resulting string, runtime `(display)`s it.

## Tools

- `bin/beagle-build SOURCE.rkt [OUT.clj]` — single-file compile
- `bin/beagle-build-all [DIR]` — directory walker
- `bin/beagle-expand SOURCE.rkt` — print source after macro expansion
- `raco test tests/` — test suite
- `experiments/` — benchmark framework (see `experiments/README.md`)

## Lint warnings

Beagle prints lint warnings to stderr during compile (strict mode only):

- `untyped def NAME` — `(def x 42)` without type annotation
- `defn NAME has no return type annotation` — missing `: Ret`
- `defn NAME has untyped parameter(s): ...` — missing `(name : Type)`
- `(unsafe "...") inline escape` — beagle can't validate that code
- `let binding X shadows outer binding` — let/fn rebinds a name from enclosing scope
- `unused declare-extern: X` — extern declared but never referenced

Suppress with `BEAGLE_NO_LINT=1`. Warnings don't fail compile. Dynamic
mode skips lint (types are optional there by definition).

## Design decisions

### Confident (committed, well-reasoned)

| decision | reasoning |
|---|---|
| **s-expressions, AST-based** | non-negotiable foundation |
| **Custom reader preserves `[]` vs `()`** | Clojure cares (vectors); beagle needs to know |
| **`(ns ...)` for namespace** | universal Clojure idiom, in LLM training data |
| **Wrapped `(x : T)` not inline** | unambiguous parse, no lookahead, AI-friendly |
| **Stdlib extern catalog** | biggest single leverage point for AI type-safety |
| **Safe / unsafe macro distinction** | controlled boundary for "what the checker re-validates" |
| **Macro expansion is inspectable** | `beagle-expand` lets the LLM audit its own macros |
| **Strict mode default** | dynamic is escape-hatch for humans; AI should stay strict |
| **Subset-of-Clojure, not full mimic** | take Lisp universals + Clojure's good ideas; develop own for typed semantics |

### Resolved by benchmark and cleanup pass

| decision | resolution |
|---|---|
| `:` vs `:-` for annotation marker | **`:`** — `:-` removed; no measured benefit in 6-variant benchmark |
| Wrapped `(x : T)` vs inline `[x : T y : T]` | **Wrapped** — inline removed; no measured benefit, less unambiguous parse |
| Type aliases `Integer`/`Int`/`Float`/`Bool` | **Removed** — pure redundancy with `Long`/`Double`/`Boolean` |
| Optional vs required types | **Either, with annotation lint** — variants A (optional) and B (required) both work; A is the canonical baseline |

### Cargo-cult — deliberately NOT added

Clojure idioms whose cost > benefit for beagle's goals:

- **`#(...)` anonymous fn shorthand** — alternate idiom for `fn`, more
  LLM confusion than value
- **`{:keys [...]}` destructuring** — non-trivial parsing, real LLM-error
  surface
- **Threading macros `->`, `->>`** — they're just macros; users can add as
  needed. Not built-in.
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; use `unsafe`
- **`{}` map literals** — defer; use `(hash-map ...)` or `unsafe` for now
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific

## AI-optimization features in v0

- **Type-rich stdlib catalog** (`private/stdlib-types.rkt`) — ~60 common
  Clojure functions pre-typed. Every call to a known function gets arity
  and arg-type checking.
- **Inspectable macro expansion** (`bin/beagle-expand`) — LLM can audit
  what its macros do without compiling.
- **Form catalog** (`docs/forms.md`) — one canonical reference for every
  form, designed for LLM grounding.
- **Single canonical idiom per concept** — no `#(...)` alongside `fn`, no
  threading alongside nesting. One way to do each thing.

## Benchmark findings (running log)

Empirical results from running variants through the LLM live in
`docs/findings.md`. First sample (2026-05-15, 17 agent calls) caught two
real design bugs and validated:
- High self-consistency on simple tasks (byte-identical output across runs)
- Variants don't discriminate at low task complexity
- Hard tasks surface variant-specific gaps fast

The benchmark fixed two beagle issues that argument would have missed:
- Let bindings now accept wrapped typed form `(name : Type) value`
  (consistent with param syntax — LLMs expected this)
- Math operators (`+`, `-`, `*`, `/`) loosened from `[Long Long -> Long]`
  to variadic Any (Clojure's math is polymorphic; narrow typing blocked
  real FP work)

## Hard scope cap

If a month in we are deep in compiler infrastructure with no real Clojure
projects authored in beagle, **stop**. The whole point is authoring. Not
building a compiler for its own sake.

## Setup (one-time)

```
raco pkg install --link --auto /home/tom/code/beagle
```

## Reference

- `experiments/README.md` — benchmark framework for design decisions.
- `docs/forms.md` — canonical form catalog.
- `docs/todo.md` — deferred + speculative work.
