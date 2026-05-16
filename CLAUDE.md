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
  `defrecord`, `defprotocol`, `defmulti`/`defmethod`, `deftype`,
  `extend-type`, constructor calls (`ClassName.`), keyword-as-function
  (`(:key map)`), call, vector literal, map literal (`{}`), set literal
  (`#{}`), quote, threading (`->`, `->>`)
- Meta: `ns`, `define-mode`, `require`, `declare-extern`, `define-macro`,
  `import`, `unsafe` (top-level AND in expression position)
- Param syntax: **wrapped only** — `(name : Type)`. Plus `{:keys [a b c]}`
  map destructuring and `[a b & rest]` sequential destructuring in params
  and let bindings.
- Types: primitives (`String`, `Long`, `Double`, `Boolean`, `Keyword`,
  `Symbol`, `Nil`, `Any` — no aliases), user-defined record types,
  function types (variadic with `& T`), parametric (`Vec`, `Map`, `Set`,
  `List`), union (`U`), polymorphic (`forall`)
- Type narrowing: flow-sensitive in `if`/`cond`/`when` via `nil?`, `some?`,
  `string?`, `=`, `not` etc. Threads through cond clauses.
- Keyword field inference: `(:name person)` returns the field type when
  target is a known typed record
- Macros: safe (gensym-hygienic) / unsafe with `&rest` and `(splice ...)`
- Stdlib catalog: ~607 Clojure functions pre-typed (full typeable surface), key HOFs polymorphic
- Cross-file type import: `(require module)` / `(require module :as alias)`
  resolves source at compile time, imports typed defs/defns/externs/macros
- Validation: type checks, arity (incl. variadic), undefined refs, hints
- Lint pass: untyped def/defn, unsafe usage, shadowed bindings, unused externs
- Structured error output: `BEAGLE_ERROR_FORMAT=json` for agent consumption
- Java interop: `.method`, `Class/static`, `*dynamic-vars*`, constructors,
  `import`; ~30 common methods/statics pre-typed in stdlib
- Source mapping: `^{:line N :file "path"}` metadata on every emitted compound form (expression-level)
- Cross-module defrecord import: `(require module)` imports record types,
  constructors, accessors, and keyword-access field types
- 298 tests passing
- Empirical benchmarks: 40 tasks, 3 variants, head-to-head against raw Clojure,
  refactoring and bug-detection experiments — 5 real bugs caught
- Type-system query tools: beagle-sig, beagle-fields, beagle-callers,
  beagle-provides, beagle-impact (with clojure analogs for fair experiments)
- v2 experiment framework: 5-module inventory system (1651 LOC), 444 verify
  assertions, 12 injected bugs (9 caught by beagle at compile time)
- E4 scaled experiment: 13-module system (8570 LOC), 484 assertions, 35
  injected bugs — first correctness divergence (beagle 3/3, clojure 0/3)

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
- `private/stdlib-types.rkt` — pre-typed Clojure stdlib catalog (~607 functions).
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
- `private/query.rkt` — type-system query engine for `beagle-sig`,
  `beagle-fields`, `beagle-callers`, `beagle-provides`, `beagle-impact`.
- `private/check-all.rkt` — batch type-checker (10x vs sequential `beagle-check`).
- `private/build-all.rkt` — batch compiler (9x vs sequential `beagle-build`).
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
- `bin/beagle-build-all FILE-OR-DIR... [--out DIR]` — batch compile in a single process (9x vs sequential)
- `bin/beagle-check SOURCE.rkt` — type-check without emitting Clojure
- `bin/beagle-check-all FILE-OR-DIR...` — batch type-check in a single process (10x vs sequential)
- `bin/beagle-expand SOURCE.rkt` — print source after macro expansion
- `bin/beagle-sig FN-NAME FILE-OR-DIR...` — print a function's typed signature
- `bin/beagle-fields RECORD FILE-OR-DIR...` — print record fields, types, and accessors
- `bin/beagle-callers FN-NAME FILE-OR-DIR...` — find all call sites of a function
- `bin/beagle-provides FILE-OR-DIR...` — list all exports with types from a module
- `bin/beagle-impact FN-NAME FILE-OR-DIR...` — show callers and impact of changing a signature
- `raco test tests/` — test suite
- `experiments/` — benchmark framework (see `experiments/README.md`)

### Query tools for LLM agents

The `beagle-sig`, `beagle-fields`, `beagle-callers`, `beagle-provides`,
and `beagle-impact` tools expose the type system as a query interface.
Instead of reading source files to understand a codebase, agents can ask
the type system directly:

```bash
# "What does inv/can-fulfill? expect?"
bin/beagle-sig can-fulfill? path/to/inventory.rkt
# → can-fulfill? : [(Vec StockLevel) Long Long -> Boolean]

# "What fields does an Invoice have?"
bin/beagle-fields Invoice path/to/billing.rkt
# → Invoice
#   id : Long          accessor: invoice-id
#   order-id : Long    accessor: invoice-order-id
#   ...

# "What does the billing module export?"
bin/beagle-provides path/to/billing.rkt
# → records: Invoice, Payment, CreditNote ...
#   functions: create-invoice : [...], invoice-balance : [...] ...

# "Who calls create-invoice and with what arity?"
bin/beagle-callers create-invoice path/to/
# → (create-invoice id order customer ...)  in audit-order (audit.rkt)

# "If I change create-invoice's signature, what breaks?"
bin/beagle-impact create-invoice path/to/
# → callers with current arg counts
```

Clojure-analog tools (`bin/clj-sig`, `bin/clj-fields`, `bin/clj-callers`,
`bin/clj-provides`) provide the same interface but without type information.
These exist so experiments can give both tracks the same structural query
tools, ensuring beagle's advantage comes from types, not tool availability.

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
