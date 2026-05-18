---
role: contributor source — canonical reference for CLAUDE.md and AGENTS.md
---

# Beagle contributor reference

Racket-to-Clojure transpiler. `#lang beagle` source files compile to
`.clj` output. Pipeline: parse → check → emit, all at Racket expand-time.

## Testing

```
raco test tests/         # full suite
raco test tests/parse.rkt  # just parser
raco test tests/emit.rkt   # just emitter
raco test tests/check.rkt  # just type checker
```

End-to-end compile test (writes to stdout):
```
racket /path/to/file.rkt
```

## Adding a new form

Seven steps — every form follows this pattern:

1. **Struct** in `private/parse.rkt` — define a new `(struct name (fields) #:transparent)`
2. **Parse case** in `parse-list-form` or `parse-expr` — pattern-match source into the struct
3. **Emit case** in `private/emit.rkt` — `emit-expr` or `emit-form` produces Clojure string
4. **Infer case** in `private/check.rkt` — `infer-expr` returns a type (use `ANY` if unknown)
5. **Lint traversal** in `private/lint.rkt` — add to both `check-shadow` and `collect-symbols`
6. **Provide** the struct in parse.rkt's `(provide ...)` block at the bottom
7. **Tests** in `tests/parse.rkt`, `tests/emit.rkt`, `tests/check.rkt`

## Test helpers

Tests can't use `[...]` or `{...}` syntax directly (Racket reader collapses
them). Use these helpers:

```racket
(define (br . xs) (cons BRACKET-TAG xs))   ; simulates [...]
(define (mp . xs) (cons MAP-TAG xs))       ; simulates {...}
```

Example: `(defn foo [(x : Int)] (+ x 1))` in test form:
```racket
(parse-one `(defn foo ,(br '(x : Int)) (+ x 1)))
```

## Key file map

| file | role |
|---|---|
| `lang/reader.rkt` | Custom reader: `[]`, `{}`, `#{}`, `#"..."` |
| `private/parse.rkt` | Source → AST (structs). All form detection here |
| `private/check.rkt` | Type inference + checking. `RECORD-FIELDS` for keyword access |
| `private/emit.rkt` | AST → Clojure source string |
| `private/types.rkt` | Type AST, `MAP-TAG`/`SET-TAG` symbols, compatibility |
| `private/stdlib-types.rkt` | Pre-typed Clojure stdlib catalog |
| `private/lint.rkt` | Shadow detection, unused externs, untyped warnings |
| `private/macros.rkt` | Macro registry, expansion, safe/unsafe boundary |
| `private/expand-tool.rkt` | Backend for `beagle-expand` (datum-level, pre-parse) |
| `private/query.rkt` | Type-system query engine (sig, fields, callers, provides, impact) |
| `private/blame.rkt` | Semantic property rules + static suspicion analysis |
| `private/daemon.rkt` | TCP server, AST cache with mtime invalidation |
| `private/lsp.rkt` | LSP server (JSON-RPC 2.0, hover/diagnostics/symbols/definition) |
| `private/repl.rkt` | Typed REPL with persistent environment |
| `main.rkt` | `#%module-begin` — runs the full pipeline |

## Conventions

- `ANY` is `(type-prim 'Any)` — the universal escape type
- Params can be `param`, `map-destructure`, or `seq-destructure` structs — always check with `(map-destructure? p)` / `(seq-destructure? p)` before calling `(param-name p)`
- `MAP-TAG` and `SET-TAG` are `'#%map` and `'#%set` (well-known symbols, NOT gensyms — gensyms break across Racket phase boundaries)
- The reader runs at phase 0, the parser at phase 1 (inside `define-syntax`) — shared symbols must be phase-stable
- `emit-form` handles top-level forms (def, defn, defrecord, defenum, defprotocol, defmulti, defmethod, deftype, extend-type); `emit-expr` handles everything else (including `with-form`)
- `check-form` does top-level type checking; `infer-expr` does expression-level inference
- `with-form` in check.rkt validates field existence and type against `RECORD-FIELDS`; `ENUM-VALUES` tracks defenum declarations
- Exhaustive match checking runs after `infer-expr` on `match-form` — warns when record patterns are present without wildcard/var fallback

## What NOT to do

- Don't add type aliases (e.g. `Long` for `Int`) — removed by design
- Don't add `#(...)` fn shorthand — cargo-culted out
- Don't use gensyms for reader tags — they break across phases
- Don't skip lint traversal when adding forms — shadow detection will miss the new form's subtrees

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
- `private/stdlib-types.rkt` — pre-typed Clojure stdlib catalog.
- `private/macros.rkt` — macro registry, naive substitution, depth-capped
  recursive expansion, safe/unsafe boundary.
- `private/parse.rkt` — source → AST. Two passes: meta-form collection
  (mode, ns, macros, externs, requires, imports) then expr parsing with
  macro expansion.
- `private/check.rkt` — best-effort type checking against annotations and
  the built-in env. Record field registry for keyword-access type inference.
  Skipped in dynamic mode.
- `private/emit.rkt` — AST → Clojure source string.
- `main.rkt` — language module; `#%module-begin` runs the pipeline,
  embeds resulting string, runtime `(display)`s it.

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
| No type aliases | `Int`/`Float`/`Bool` only — zero ambiguity for LLMs |

### Cargo-cult — deliberately NOT added

- **`#(...)` anonymous fn shorthand** — alternate idiom for `fn`, more LLM confusion than value
- **`@deref`, `#'var-quote`** — Clojure-runtime concepts; use `unsafe`
- **Exotic reader macros (`#=`, `#_`, `#?`)** — Clojure-reader-specific
