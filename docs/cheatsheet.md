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
(import java.io.File)          ; Java class import
```

## Top-level forms

```racket
(def NAME VALUE)
(def NAME : Type VALUE)             ; typed

(defn NAME [PARAMS] BODY ...)
(defn NAME [PARAMS] : ReturnType BODY ...)

(define-macro safe   NAME (params) template)   ; expansion type-checked
(define-macro unsafe NAME (params) template)   ; expansion typed as Any

(defrecord Name [(field1 : Type) (field2 : Type)])  ; typed record

(unsafe "raw clojure source")       ; emits verbatim; top-level OR expression
```

### `defrecord`

```racket
(defrecord Employee [(name : String) (rate : Long)])
```

Emits Clojure `defrecord` plus generated typed accessors:
- Constructor: `(->Employee "Alice" 95)` — typed `[String Long -> Employee]`
- Accessors: `(employee-name e)`, `(employee-rate e)` — typed `[Employee -> String]` etc.

Field syntax reuses wrapped param form `(name : Type)`. All fields must be typed.

## Expression forms

```racket
(if cond then else)
(if cond then)                      ; no else, returns nil
(cond [test1 body1] [test2 body2] [true fallback])
(cond test1 body1 test2 body2 :else fallback)  ; bare form (Clojure-style)
(when cond body...)
(do body1 body2 ... bodyN)          ; returns last
(let [name1 value1 name2 value2 ...] body...)
(loop [name1 init1 name2 init2 ...] body...)
(recur arg1 arg2 ...)               ; tail-recurse back to loop
(for [x coll1 y coll2 :when pred] body...)  ; list comprehension
(fn [PARAMS] body...)
(fn [PARAMS] : ReturnType body...)
(try body... (catch ExType e handler...) (finally cleanup...))
(doseq [x coll ...] body...)       ; side-effecting iteration
(case test val1 result1 val2 result2 default)
(ClassName. args...)                ; Java constructor
(:key map)                          ; keyword-as-function (map lookup)
(:key map default)                  ; keyword lookup with default
'datum                              ; quote
[item1 item2 ...]                   ; vector literal
{k1 v1 k2 v2}                      ; map literal
#{item1 item2}                      ; set literal
(fn-name arg1 arg2 ...)             ; function call
```

## Top-level: protocols, multimethods, and type implementations

```racket
(defprotocol Name
  (method-name [params] : ReturnType)
  (other-method [params]))

(defmulti name dispatch-fn)
(defmethod name dispatch-val [params] body...)

(deftype Name [field1 field2]
  ProtocolName
  (method [this arg] body...))

(extend-type TypeName
  ProtocolName
  (method [this arg] body...))

(-> x (f) (g))                      ; thread-first
(->> x (f) (g))                     ; thread-last
```

## Parameter syntax — wrapped, bare, or destructured

```racket
[x y z]                             ; untyped (bare names)
[(x : Long) (y : Long)]             ; wrapped with type
[(x : Long) y]                      ; mix wrapped + bare
[{:keys [name age]}]                ; map destructuring
[{:keys [x y] :as point}]          ; destructure + bind whole map
[[a b & rest]]                      ; sequential destructuring
```

One canonical form: wrapped `(name : Type)`. The marker is `:` (single colon
with spaces). No alternate markers, no inline form. AI-optimization: one
idiom per concept.

## Let binding syntax

```racket
(let [x 1 y 2] ...)                       ; untyped
(let [(x : Long) 1 (y : Long) 2] ...)     ; typed (wrapped — same shape as params)
(let [(x : Long) 1 y 2] ...)              ; mix
(let [[a b] pair] ...)                     ; sequential destructuring
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

## Pre-typed stdlib (~607 functions)

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

**Also typed** (435 total): transducers (`map`/`filter`/`cat`/`halt-when`),
atoms (`atom`/`swap!`/`reset!`/`deref`), `clojure.string/*`,
`clojure.set/*`, `clojure.walk/*`, `clojure.edn/read-string`,
regex (`re-find`/`re-matches`/`re-seq`/`re-pattern`), type coercion
(`int`/`long`/`double`/`float`/`char`/`boolean`/`bigint`/`bigdec`),
30+ type predicates, array ops, 20+ Java instance/static methods, and more.

**Intentionally omitted** (~400 clojure.core functions not typed):

| category | why excluded |
|---|---|
| Agents (`agent`, `send`, `send-off`, `await`, ...) | Concurrency primitives — side-effectful, runtime-only |
| Refs/STM (`ref`, `dosync`, `alter`, `commute`, ...) | Transaction machinery — no static model |
| Vars (`binding`, `alter-var-root`, `with-redefs`, ...) | Dynamic rebinding — breaks static assumptions |
| Namespaces (`ns-resolve`, `find-ns`, `intern`, ...) | Metaprogramming — runtime reflection |
| Classloading (`gen-class`, `gen-interface`, `compile`, ...) | JVM internals — not relevant to application code |
| Eval/read (`eval`, `read`, `load-string`, ...) | Dynamic code execution — untypeable |
| Concurrency (`locking`, `pmap`, `seque`, ...) | Threading primitives — use `(unsafe ...)` |
| Auto-promote variants (`+'`, `*'`, `incN`, ...) | Overflow-safe math — redundant with `+`, `*` |

These are deliberate omissions, not coverage gaps. `bin/gen-stdlib-types`
generates zero new entries — the typeable surface is fully covered.

For anything omitted, use `(declare-extern name TypeExpr)` or `(unsafe "...")`.

## Clojure namespace interop

`(require clojure.string :as str)` works for any Clojure namespace — emits
`(:require [clojure.string :as str])` in the Clojure ns form. Then call
functions as `str/split`, `str/trim`, etc. Type checker treats these as Any.

```racket
(require clojure.string :as str)
(require clojure.set :as cset)

(str/split text #"\s+")       ; regex literal supported natively
(str/trim s)
(str/lower-case s)
(str/upper-case s)
(str/join ", " coll)
(cset/intersection a b)
```

## Regex literals

`#"pattern"` — Clojure regex literal. Emits as `#"pattern"` in output.
Supported natively in beagle source. Common patterns:

```racket
#"\s+"        ; whitespace
#"\|"         ; pipe
#","          ; comma
#"\d+"        ; digits
```

## Java interop

```racket
(.method target args...)              ; instance method
(Class/staticMethod args...)          ; static method
*dynamic-var*                         ; Clojure dynamic var
```

Type these with `declare-extern` (receiver is first param for methods):
```racket
(declare-extern .exists [Any -> Boolean])
(declare-extern System/getProperty [String -> String])
(declare-extern *command-line-args* (Vec String))
```

Pre-typed in stdlib: `.exists`, `.trim`, `.startsWith`, `.endsWith`,
`.contains`, `.toLowerCase`, `.toUpperCase`, `.mkdirs`, `.getParent`,
`.getParentFile`, `.getName`, `.getPath`, `.length`, `.toString`,
`System/getProperty`, `System/getenv`, `System/currentTimeMillis`,
`Math/abs`, `Math/pow`, `Math/sqrt`, `Math/floor`, `Math/ceil`,
`Integer/parseInt`, `Long/parseLong`, `Double/parseDouble`,
`*command-line-args*`.

### Coverage gaps (known, not yet implemented)

| Gap | What breaks | Future fix |
|---|---|---|
| Method overloading | Only one signature per `.method`; second overload needs separate `declare-extern` | Union of function types |
| Receiver type dispatch | `.exists` typed globally, not per-class | `File/.exists` syntax (Clojure 1.12+) |
| Static field access | `Math/PI` as bare symbol returns Any | `declare-extern Math/PI Double` works now |
| Generic type params | `(.get (HashMap) key)` can't track value type | Java generics model |
| Overload resolution | Multiple Java methods with same name, different types | Essentially javac |
| Reflection / dynamic dispatch | Runtime-only class resolution | Impossible statically |

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
