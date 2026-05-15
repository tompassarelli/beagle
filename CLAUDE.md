# beagle — session anchor

A typed authoring layer that compiles to Clojure. Racket frontend with
custom `#lang`, macros (safe/unsafe boundaries), static type checking; emits
plain Clojure source for runtime.

**Primary author: LLMs.** Beagle's design optimizes for AI generation: rich
types, explicit forms, low syntactic surface area, structured errors. Human
ergonomics is a secondary constraint.

## What this is — and what it isn't

Beagle is a **general typed Clojure DSL** optimized for LLM authoring. It
is NOT a graph-database tool. The substrate POC (claims, identifiers,
reification) at `~/code/beagle-rkt-poc` is conceptual reference for a future
`#lang beaglelog` layer built **on top of** beagle, not as beagle primitives.

Earlier iterations that conflated the two are archived at
`~/code/beagle-iter-2-graph-dsl`. Not the direction.

## Status

`#lang beagle` v0 works end-to-end:
- Forms: `def`, `defn`, `fn`, `let`, `if`, `cond`, `when`, `do`, call,
  vector literal, quote
- Meta: `ns`, `define-mode`, `require`, `declare-extern`, `define-macro`,
  inline `unsafe`
- Types: primitives, function types (incl. variadic), parametric (`Vec`,
  `Map`, etc.), union (`U`)
- Macros: safe / unsafe with `&rest` and `(splice ...)`
- Stdlib catalog: ~60 common Clojure functions pre-typed (see
  `private/stdlib-types.rkt`)
- Compile-time validation: type checks, arity, variadic rest, undefined refs
- 91/91 tests passing

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

### Provisional (subject to benchmark experiments in `experiments/`)

| decision | predicted result | how to test |
|---|---|---|
| **`:` vs `:-` for type annotation** | `:` wins on familiarity (math/ML/TR have more training data than Schema) | Requires adding `:-` support; then variant comparison |
| **Wrapped `(x : T)` vs inline `[x : T y : T]`** | Wrapped wins on parsing simplicity + LLM consistency | Requires adding inline support; variant comparison |
| **Optional vs required types** | Required wins on AI-generation safety (more compile-time catches) | Variants A and B already set up — run the bench |
| **Including/excluding `&rest`, `(splice ...)`, etc.** | Including helps for variadic patterns | Already in v0; could ablate |

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

## Hard scope cap

If a month in we are deep in compiler infrastructure with no real Clojure
projects authored in beagle, **stop**. The whole point is authoring. Not
building a compiler for its own sake.

## Setup (one-time)

```
raco pkg install --link --auto /home/tom/code/beagle
```

## Reference

- `~/code/beagle-rkt-poc/` — original substrate POC. Future `#lang beaglelog`
  reference.
- `~/code/beagle-iter-2-graph-dsl/` — wrong-direction archive.
- Typed Racket — type-system pattern beagle follows.
- `experiments/README.md` — benchmark framework for design decisions.
- `docs/forms.md` — canonical form catalog.
- `docs/todo.md` — deferred + speculative work.
