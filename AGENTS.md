# beagle — agent instructions

## What this is

A multi-target typed authoring IR. `#lang beagle` source files compile to
Clojure, ClojureScript, JavaScript, Nix, or SQL. Pipeline: parse → check →
emit-dispatch, all at Racket expand-time.

## Package layout

```
beagle-lib/     # Core: compiler, stdlib, runtime (collection "beagle")
beagle-test/    # Tests (collection "beagle", deps: beagle-lib rackunit-lib)
beagle-doc/     # Scribble docs (collection "beagle", deps: beagle-lib scribble-lib)
beagle/         # Aggregate (multi-collection, implies lib + doc)
```

## How to test

```
raco test beagle-test/tests/              # full suite (1221 tests)
raco test beagle-test/tests/parse.rkt     # just parser
raco test beagle-test/tests/emit.rkt      # just Clojure emitter
raco test beagle-test/tests/emit-js.rkt   # just JS emitter
raco test beagle-test/tests/emit-nix.rkt  # just Nix emitter
raco test beagle-test/tests/check.rkt     # just type checker
```

End-to-end compile test (writes to stdout):
```
racket /path/to/file.rkt
```

## How to add a new form

Seven steps — every form follows this pattern:

1. **Struct** in `beagle-lib/private/parse.rkt` — define a new `(struct name (fields) #:transparent)`
2. **Parse case** in `parse-list-form` or `parse-expr` — pattern-match source into the struct
3. **Emit case** in `beagle-lib/private/emit-clj.rkt` AND `beagle-lib/private/emit-js.rkt` — produce target source
4. **Infer case** in `beagle-lib/private/check.rkt` — `infer-expr` returns a type (use `ANY` if unknown)
5. **Lint traversal** in `beagle-lib/private/lint.rkt` — add to both `check-shadow` and `collect-symbols`
6. **Provide** the struct in parse.rkt's `(provide ...)` block at the bottom
7. **Tests** in `beagle-test/tests/parse.rkt`, `beagle-test/tests/emit.rkt`, `beagle-test/tests/check.rkt`

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
| `beagle-lib/lang/reader.rkt` | Custom reader: `[]`, `{}`, `#{}`, `#"..."` |
| `beagle-lib/private/parse.rkt` | Source → AST (structs). All form detection here |
| `beagle-lib/private/check.rkt` | Type inference + checking. `RECORD-FIELDS` for keyword access |
| `beagle-lib/private/emit-clj.rkt` | AST → Clojure/ClojureScript source string |
| `beagle-lib/private/emit-js.rkt` | AST → JavaScript source string |
| `beagle-lib/private/emit-nix.rkt` | AST → Nix source string |
| `beagle-lib/private/emit-sql.rkt` | AST → SQL source string |
| `beagle-lib/private/types.rkt` | Type AST, `MAP-TAG`/`SET-TAG` symbols, compatibility |
| `beagle-lib/private/stdlib-types.rkt` | ~696 pre-typed stdlib entries |
| `beagle-lib/private/lint.rkt` | Shadow detection, unused externs, untyped warnings |
| `beagle-lib/private/macros.rkt` | Macro registry, expansion, safe/unsafe boundary |
| `beagle-lib/private/expand-tool.rkt` | Backend for `beagle-expand` (datum-level, pre-parse) |
| `beagle-lib/main.rkt` | `#%module-begin` — runs the full pipeline |

## Important conventions

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
