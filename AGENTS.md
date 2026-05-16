# beagle — agent instructions

## What this is

A Racket-to-Clojure transpiler. `#lang beagle` source files compile to
`.clj` output. Pipeline: parse → check → emit, all at Racket expand-time.

## How to test

```
raco test tests/         # full suite (289 tests)
raco test tests/parse.rkt  # just parser
raco test tests/emit.rkt   # just emitter
raco test tests/check.rkt  # just type checker
```

End-to-end compile test (writes to stdout):
```
racket /path/to/file.rkt
```

## How to add a new form

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

Example: `(defn foo [(x : Long)] (+ x 1))` in test form:
```racket
(parse-one `(defn foo ,(br '(x : Long)) (+ x 1)))
```

## Key file map

| file | role |
|---|---|
| `lang/reader.rkt` | Custom reader: `[]`, `{}`, `#{}`, `#"..."` |
| `private/parse.rkt` | Source → AST (structs). All form detection here |
| `private/check.rkt` | Type inference + checking. `RECORD-FIELDS` for keyword access |
| `private/emit.rkt` | AST → Clojure source string |
| `private/types.rkt` | Type AST, `MAP-TAG`/`SET-TAG` symbols, compatibility |
| `private/stdlib-types.rkt` | ~607 pre-typed Clojure functions |
| `private/lint.rkt` | Shadow detection, unused externs, untyped warnings |
| `private/macros.rkt` | Macro registry, expansion, safe/unsafe boundary |
| `private/expand-tool.rkt` | Backend for `beagle-expand` (datum-level, pre-parse) |
| `main.rkt` | `#%module-begin` — runs the full pipeline |

## Important conventions

- `ANY` is `(type-prim 'Any)` — the universal escape type
- Params can be `param`, `map-destructure`, or `seq-destructure` structs — always check with `(map-destructure? p)` / `(seq-destructure? p)` before calling `(param-name p)`
- `MAP-TAG` and `SET-TAG` are `'#%map` and `'#%set` (well-known symbols, NOT gensyms — gensyms break across Racket phase boundaries)
- The reader runs at phase 0, the parser at phase 1 (inside `define-syntax`) — shared symbols must be phase-stable
- `emit-form` handles top-level forms (def, defn, defrecord, defprotocol, defmulti, defmethod, deftype, extend-type); `emit-expr` handles everything else
- `check-form` does top-level type checking; `infer-expr` does expression-level inference

## What NOT to do

- Don't add type aliases (e.g. `Int` for `Long`) — removed by design
- Don't add `#(...)` fn shorthand — cargo-culted out
- Don't use gensyms for reader tags — they break across phases
- Don't skip lint traversal when adding forms — shadow detection will miss the new form's subtrees
