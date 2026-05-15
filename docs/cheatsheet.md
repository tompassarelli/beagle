# beagle — one-page cheatsheet

Everything an LLM needs to ground on. Single canonical reference. Optimized
for being included as system context.

## File header

```racket
#lang beagle

(ns my.namespace)              ; canonical: matches Clojure (ns ...)
(define-mode strict)            ; default; or `dynamic` to skip type checks
(require some.clojure.ns)       ; or (require some.ns :as alias)
(declare-extern fn [Args -> Ret])  ; type a Clojure function from elsewhere
```

## Top-level forms

```racket
(def NAME VALUE)
(def NAME : Type VALUE)             ; typed

(defn NAME [PARAMS] BODY ...)
(defn NAME [PARAMS] : ReturnType BODY ...)

(define-macro safe   NAME (params) template)   ; expansion type-checked
(define-macro unsafe NAME (params) template)   ; expansion typed as Any

(unsafe "raw clojure source")       ; emits verbatim; top-level OR expression
```

## Expression forms

```racket
(if cond then else)
(if cond then)                      ; no else, returns nil
(cond [test1 body1] [test2 body2] [true fallback])
(cond test1 body1 test2 body2 :else fallback)  ; bare form (Clojure-style)
(when cond body...)
(do body1 body2 ... bodyN)          ; returns last
(let [name1 value1 name2 value2 ...] body...)
(fn [PARAMS] body...)
(fn [PARAMS] : ReturnType body...)
'datum                              ; quote
[item1 item2 ...]                   ; vector literal
(fn-name arg1 arg2 ...)             ; function call
```

## Parameter syntax — wrapped only

```racket
[x y z]                             ; untyped (bare names)
[(x : Long) (y : Long)]             ; wrapped with type
[(x : Long) y]                      ; mix wrapped + bare
```

One canonical form: wrapped `(name : Type)`. The marker is `:` (single colon
with spaces). No alternate markers, no inline form. AI-optimization: one
idiom per concept.

## Let binding syntax

```racket
(let [x 1 y 2] ...)                       ; untyped
(let [(x : Long) 1 (y : Long) 2] ...)     ; typed (wrapped — same shape as params)
(let [(x : Long) 1 y 2] ...)              ; mix
```

## Types

| primitive | matches |
|---|---|
| `String` | strings |
| `Long` | integers |
| `Double` | floats |
| `Boolean` | true/false |
| `Keyword` | `:foo` style |
| `Symbol` | quoted symbols |
| `Nil` | `nil` |
| `Any` | anything (escape) |

One canonical name per type. No `Integer`, `Int`, `Float`, `Bool` aliases —
AI-optimization removed them.

Function types:
- `[A B -> R]`                   fixed arity
- `[A & T -> R]`                 variadic (zero+ extra `T` args)
- `[-> R]`                       nullary

Parametric:
- `(Vec T)`, `(List T)`, `(Set T)`, `(Map K V)`

Union:
- `(U String Nil)` — value is one of the alternatives

## Macros

```racket
(define-macro safe inc1 (x)
  (+ x 1))

(define-macro safe call-with (f & args)
  (f (splice args)))               ; (splice rest) inlines the &rest list

(define-macro unsafe wild (form)
  (do (println "trace") form))     ; expansion typed Any
```

- `safe`: expansion re-validated by checker
- `unsafe`: expansion's result type widened to `Any` (boundary)
- `&rest-name` in params: collects remaining args into a list
- `(splice rest-name)` in template: inlines the list at that position
- Naive substitution (no hygiene): avoid binder-name clashes with caller

## Pre-typed stdlib (~100 functions)

**Math** (variadic Any): `+`, `-`, `*`, `/`, `mod`, `quot`, `rem`, `inc`,
`dec`, `min`, `max`, `abs`

**Comparison**: `=`, `not=`, `<`, `>`, `<=`, `>=`, `identical?`, `compare`,
`zero?`, `pos?`, `neg?`, `even?`, `odd?`

**Boolean**: `not`, `and`, `or`, `true?`, `false?`, `nil?`, `some?`

**Collections**: `first`, `second`, `last`, `rest`, `next`, `nth`, `get`,
`get-in`, `count`, `empty?`, `seq`, `conj`, `cons`, `concat`, `reverse`,
`distinct`, `sort`, `into`, `vec`, `vector`, `list`, `hash-map`, `set`,
`hash-set`, `keys`, `vals`, `assoc`, `dissoc`, `update`, `merge`,
`contains?`, `find`

**Higher-order**: `map`, `mapv`, `filter`, `filterv`, `remove`, `reduce`,
`apply`, `comp`, `partial`, `every?`, `some`

**Sequence gen**: `range`, `repeat`, `iterate`, `take`, `drop`, `take-while`,
`drop-while`, `partition`, `interpose`

**Strings**: `str`, `name`, `keyword`, `symbol`, `subs`, `pr-str`

**Predicates**: `string?`, `number?`, `integer?`, `keyword?`, `symbol?`,
`map?`, `vector?`, `list?`, `set?`, `coll?`, `sequential?`, `fn?`

**IO**: `println`, `print`, `pr`, `prn`, `newline`

**Errors**: `ex-info`, `ex-data`, `throw`

**Misc**: `identity`, `constantly`

For everything else, use `(declare-extern name TypeExpr)`.

## Escape hatches

| level | how | when |
|---|---|---|
| inline | `(unsafe "raw clojure")` | drop into Clojure for one expression |
| macro | `(define-macro unsafe ...)` | mark a whole macro's output as Any |
| module | hand-written `.clj` file under `runtime/src/` | full Clojure freedom |
| file | `(define-mode dynamic)` | skip all type checking in this file |

## Lint warnings (printed on stderr, never fail compile)

- `untyped def NAME` — `(def x 42)` without `: Type`
- `defn NAME has no return type annotation`
- `defn NAME has untyped parameter(s): names`
- `(unsafe "...") inline escape — beagle cannot type-check this code`

## Errors (compile-time, fail with hint)

Set `BEAGLE_ERROR_FORMAT=json` to emit single-line JSON with fields:
`tool`, `kind`, `message`, `hint`, `file`, `line`, `col`.

Error kinds include: `unknown-type`, `unknown-form`, `type-mismatch`,
`arity-mismatch`, `arity-too-few`, `duplicate-definition`, `macro-arity`,
`syntax`, `unknown-mode`.

## Tools

- `bin/beagle-build SOURCE.rkt [OUT.clj]` — compile one file
- `bin/beagle-build-all [DIR]` — compile every `.rkt` in tree
- `bin/beagle-check SOURCE.rkt`        — type-check only, no emit
- `bin/beagle-expand SOURCE.rkt`       — show post-macro source

## Empirical baseline

3 syntactic variants tested (A canonical, B required-types, C minimal),
multiple LLM samples per task, real Clojure behavior verification. 100%
behavior pass after empirically-driven bug fixes. See `docs/findings.md`.
