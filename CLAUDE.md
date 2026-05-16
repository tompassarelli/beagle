# beagle — session anchor

A typed authoring layer that compiles to Clojure. Racket frontend with
custom `#lang`, macros (safe/unsafe boundaries), static type checking; emits
plain Clojure source for runtime.

**LLM authoring is a first-class concern.** Rich types, explicit forms, low
syntactic surface area, structured errors. One canonical idiom per concept.

**Quick reference:** `docs/cheatsheet.md` is the single-page language
summary designed to be loaded as system context for LLM workflows. Treat
it as canonical when explaining the language.


## Status

`#lang beagle` v0 — end-to-end working, empirically validated:

- Forms: `def`, `defn`, `fn`, `let`, `if`, `cond`, `when`, `do`, `loop`,
  `recur`, `for` (with `:when`), `doseq`, `try`/`catch`/`finally`, `case`,
  `defrecord`, `defprotocol`, `defmulti`/`defmethod`, constructor calls
  (`ClassName.`), keyword-as-function (`(:key map)`), call, vector literal,
  map literal (`{}`), set literal (`#{}`), quote
- Meta: `ns`, `define-mode`, `require`, `declare-extern`, `define-macro`,
  `import`, `unsafe` (top-level AND in expression position)
- Param syntax: **wrapped only** — `(name : Type)`. Plus `{:keys [a b c]}`
  map destructuring in params and let bindings.
- Types: primitives (`String`, `Long`, `Double`, `Boolean`, `Keyword`,
  `Symbol`, `Nil`, `Any` — no aliases), user-defined record types,
  function types (variadic with `& T`), parametric (`Vec`, `Map`, `Set`,
  `List`), union (`U`), polymorphic (`forall`)
- Type narrowing: flow-sensitive in `if`/`cond`/`when` via `nil?`, `some?`,
  `string?`, `=`, `not` etc. Threads through cond clauses.
- Keyword field inference: `(:name person)` returns the field type when
  target is a known typed record
- Macros: safe (gensym-hygienic) / unsafe with `&rest` and `(splice ...)`
- Stdlib catalog: ~110 common Clojure functions pre-typed, key HOFs polymorphic
- Cross-file type import: `(require module)` / `(require module :as alias)`
  resolves source at compile time, imports typed defs/defns/externs/macros
- Validation: type checks, arity (incl. variadic), undefined refs, hints
- Lint pass: untyped def/defn, unsafe usage, shadowed bindings, unused externs
- Structured error output: `BEAGLE_ERROR_FORMAT=json` for agent consumption
- Java interop: `.method`, `Class/static`, `*dynamic-vars*`, constructors,
  `import`; ~30 common methods/statics pre-typed in stdlib
- 258 tests passing
- Empirical benchmarks: 40 tasks, 3 variants, head-to-head against raw Clojure,
  refactoring and bug-detection experiments — 5 real bugs caught

## Architecture

```
parse → check → emit
(all expand-time, inside our custom #%module-begin)
```

- `lang/reader.rkt` — custom reader preserving `[]` vs `()` via
  `#%brackets` tag. Intercepts `{}` (map literals), `#{}` (set literals),
  `#"..."` (regex) via `MAP-TAG`/`SET-TAG`/`#%regex`.
- `private/types.rkt` — type AST, parser, compatibility checker.
  `MAP-TAG`/`SET-TAG` are well-known symbols (`#%map`/`#%set`), not gensyms.
- `private/stdlib-types.rkt` — pre-typed Clojure stdlib catalog (~110 functions).
- `private/macros.rkt` — macro registry, naive substitution, depth-capped
  recursive expansion, safe/unsafe boundary.
- `private/parse.rkt` — source → AST. Two passes: meta-form collection
  (mode, ns, macros, externs, requires, imports) then expr parsing with
  macro expansion.
- `private/check.rkt` — best-effort type checking against annotations and
  the built-in env. Record field registry for keyword-access type inference.
  Skipped in dynamic mode.
- `private/emit.rkt` — AST → Clojure source string.
- `private/expand-tool.rkt` — backend for `bin/beagle-expand`.
- `main.rkt` — language module; `#%module-begin` runs the pipeline,
  embeds resulting string, runtime `(display)`s it.

## Adding a new form (the pattern)

1. **Struct** in `parse.rkt` — new AST node
2. **Parse case** in `parse-list-form` — pattern-match the source
3. **Emit case** in `emit-expr` or `emit-form` — produce Clojure
4. **Infer case** in `infer-expr` — return type (or `ANY`)
5. **Lint traversal** in `lint.rkt` — `check-shadow` and `collect-symbols`
6. **Provide** the struct in parse.rkt's provide list
7. **Tests** in parse/emit/check test files

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
| s-expressions, AST-based | non-negotiable foundation |
| Custom reader preserves `[]` vs `()` | Clojure cares (vectors); beagle needs to know |
| `(ns ...)` for namespace | universal Clojure idiom, in LLM training data |
| Wrapped `(x : T)` not inline | unambiguous parse, no lookahead, AI-friendly |
| Stdlib extern catalog | biggest single leverage point for AI type-safety |
| Safe / unsafe macro distinction | controlled boundary for "what the checker re-validates" |
| Macro expansion is inspectable | `beagle-expand` lets the LLM audit its own macros |
| Strict mode default | dynamic is escape-hatch for humans; AI should stay strict |
| Subset-of-Clojure, not full mimic | take Lisp universals + Clojure's good ideas; develop own for typed semantics |
| `:` as only annotation marker | `:-` removed; no measured benefit in 6-variant benchmark |
| Wrapped params only | inline removed; no measured benefit, less unambiguous parse |
| No type aliases | `Long`/`Double`/`Boolean` only — zero ambiguity for LLMs |

### Cargo-cult — deliberately NOT added

Clojure idioms whose cost > benefit for beagle's goals:

- **`#(...)` anonymous fn shorthand** — alternate idiom for `fn`, more
  LLM confusion than value
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; use `unsafe`
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific

## Setup (one-time)

```
raco pkg install --link --auto /home/tom/code/beagle
```

## Reference

- `experiments/README.md` — benchmark framework for design decisions.
- `docs/forms.md` — canonical form catalog.
- `docs/cheatsheet.md` — single-page LLM grounding reference.
- `docs/todo.md` — roadmap and completed work.
