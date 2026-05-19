# beagle — one-page cheatsheet

Everything an LLM needs to ground on. Single canonical reference. Optimized
for being included as system context.

## File extensions

Each file declares its target via extension:

| Extension | Target | `#lang` |
|-----------|--------|---------|
| `.bclj` | Clojure | `#lang beagle` or `#lang beagle/clj` |
| `.bcljs` | ClojureScript | `#lang beagle/cljs` |
| `.bjs` | JavaScript | `#lang beagle/js` |
| `.bnix` | Nix | `#lang beagle/nix` |
| `.bsql` | SQL | `#lang beagle/sql` |
| `.rkt` | (legacy) | any |

Extension and `#lang` header must match. Mismatch is a hard compile error.

## File header

```racket
#lang beagle

(ns my.namespace)              ; canonical: matches Clojure (ns ...)
(define-mode strict)            ; default; or `dynamic` to skip type checks
(require some.module :as mod)   ; imports all types/fns from another beagle module
(declare-extern fn [Args -> Ret])  ; ONLY needed for Java interop or non-beagle fns
(import java.io.File)          ; Java class import
```

For the JavaScript target, use `#lang beagle/js` and `.bjs` file extension:

```racket
#lang beagle/js

(ns my.module)
(define-mode strict)
(require other.module :as mod)  ; → import * as mod from './other.module.js'
```

**NOTE:** `(require module :as alias)` imports all typed defs, defns, records,
scalars, and macros from the required beagle module. You do NOT need
`declare-extern` for cross-module beagle calls — the types are imported
automatically. Imported scalars give you both the constructor (`->Amount`)
and accessor (`amount-value`) with full type checking.

## Top-level forms

```racket
(def NAME VALUE)
(def NAME : Type VALUE)             ; typed
(defonce NAME VALUE)                ; only binds if not already defined

(defn NAME [PARAMS] BODY ...)
(defn NAME [PARAMS] : ReturnType BODY ...)

(define-macro safe   NAME (params) template)   ; expansion type-checked
(define-macro unsafe NAME (params) template)   ; expansion typed as Any

(defrecord Name [(field1 : Type) (field2 : Type)])  ; typed record

(unsafe "raw clojure source")       ; emits verbatim; top-level OR expression
```

### `defrecord`

```racket
(defrecord Employee [(name : String) (rate : Int)])
```

Emits Clojure `defrecord` plus generated typed accessors:
- Constructor: `(->Employee "Alice" 95)` — typed `[String Int -> Employee]`
- Accessors: `(employee-name e)`, `(employee-rate e)` — typed `[Employee -> String]` etc.

Field syntax reuses wrapped param form `(name : Type)`. All fields must be typed.

### `with` (record update)

```racket
(with record [:field1 new-value1] [:field2 new-value2])
```

Typed record update. Compiles to `(assoc record :field1 new-value1 :field2 new-value2)`.
Type checker validates: field exists on the record type, value matches field type.
Use instead of positional constructors when updating a few fields on an existing record.

### `defscalar` (nominal types)

```racket
(defscalar Amount Int)
(defscalar Timestamp Int)
(defscalar AccountId Int)
(defscalar Email String)
```

Creates a **nominal type** backed by a primitive. `Amount`, `Timestamp`, and
`AccountId` are all `Int` at runtime, but the type checker treats them as
incompatible — you cannot pass an `Amount` where a `Timestamp` is expected.

Generated functions:
- Constructor: `(->Amount 5000)` — typed `[Int -> Amount]`
- Accessor: `(amount-value x)` — typed `[Amount -> Int]`

Scalars are the primary defense against "same-type confusion" bugs where IDs,
monetary values, and timestamps are all Int underneath. The checker flags:
- Wrong scalar in constructor args: `(->Amount (timestamp-value ts))` — error
- Mixed scalar arithmetic: `(+ (amount-value x) (timestamp-value y))` — note
- Cross-scalar comparison: `(= (accountid-value a) (instrumentid-value b))` — note

**Usage pattern:**
```racket
(defscalar Price Int)
(defscalar Quantity Int)

(defn order-total [(price : Price) (qty : Quantity)] : Amount
  (->Amount (* (price-value price) (quantity-value qty))))
```

Cross-scalar multiplication (`price * qty = amount`) is valid — the checker
only flags additive mixing and constructor mismatches.

**Refinement predicates (opt-in):**
```racket
(defscalar Percentage Int :where (>= 0) (<= 100))
(defscalar PositiveAmount Int :where (> 0))
```

`:where` adds compile-time and runtime validation:
- **Compile-time:** `(->Percentage 150)` is a type error (literal violates `(<= 100)`)
- **Runtime:** constructor emits Clojure `:pre` conditions for dynamic values
- Predicates propagate across `require` boundaries
- Ops: `>=`, `<=`, `>`, `<`, `=`, `not=`

### `defenum`

```racket
(defenum OrderStatus :placed :confirmed :paid :shipped :delivered :cancelled)
```

Declares an enum value set. Compiles to `(def OrderStatus-values #{:placed ...})`.

## Expression forms

```racket
(if cond then else)
(if cond then)                      ; no else, returns nil
(cond [test1 body1] [test2 body2] [true fallback])
(cond test1 body1 test2 body2 :else fallback)  ; bare form (Clojure-style)
(when cond body...)
(when-not cond body...)             ; inverted when
(when-let [name expr] body...)      ; bind + truthy test
(if-let [name expr] then else)      ; bind + truthy branch
(when-some [name expr] body...)     ; bind + non-nil test
(if-some [name expr] then else)     ; bind + non-nil branch
(if-not cond then else)             ; inverted if
(do body1 body2 ... bodyN)          ; returns last
(let [name1 value1 name2 value2 ...] body...)
(loop [name1 init1 name2 init2 ...] body...)
(recur arg1 arg2 ...)               ; tail-recurse back to loop
(for [x coll :when pred :let [y (f x)]] body...)  ; list comprehension
(dotimes [i n] body...)             ; counted iteration (i = 0..n-1)
(condp pred test v1 r1 v2 r2 default)  ; predicate dispatch
(comment forms...)                  ; returns nil, forms not evaluated
(fn [PARAMS] body...)
(fn [PARAMS] : ReturnType body...)
(try body... (catch ExType e handler...) (finally cleanup...))
(doseq [x coll ...] body...)       ; side-effecting iteration
(case test val1 result1 val2 result2 default)
(with-open [name expr] body...)     ; resource management (auto-close)
(doto target (.method args) ...)    ; Java mutation chain
(ClassName. args...)                ; Java constructor
(:key map)                          ; keyword-as-function (map lookup)
(:key map default)                  ; keyword lookup with default
^{:key val} form                    ; metadata
'datum                              ; quote
[item1 item2 ...]                   ; vector literal
{k1 v1 k2 v2}                      ; map literal
#{item1 item2}                      ; set literal
(with record [:field value])        ; typed record update → assoc
(fn-name arg1 arg2 ...)             ; function call
```

## Pattern matching

```racket
(match expr
  [(RecordType f1 f2 ...) body...]     ; record type test + positional field destructuring
  [{:key1 p1 :key2 p2} body...]        ; map pattern
  [nil body...]                         ; nil literal
  ["string" body...]                    ; literal
  [42 body...]                          ; literal
  [var-name body...]                    ; bind to variable
  [_ body...])                          ; wildcard
```

Record patterns emit `instance?` checks + keyword field extraction. Bindings
are positional: `(Rect w h)` binds `w` to `:width`, `h` to `:height` in
declaration order.

## Multi-arity functions

```racket
(defn greet
  ([(name : String)] : String
    (str "Hello, " name))
  ([(name : String) (title : String)] : String
    (str "Hello, " title " " name)))
```

Each arity clause has its own params and return type. The checker validates
calls against all arities — wrong arity reports available options.

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
(cond-> x test1 (f) test2 (g))     ; conditional thread-first
(cond->> x test1 (f) test2 (g))    ; conditional thread-last
(some-> x (f) (g))                  ; nil-safe thread-first
(some->> x (f) (g))                 ; nil-safe thread-last
(as-> x $ (f $) (g $ 1))           ; named thread
```

## Parameter syntax — wrapped, bare, or destructured

```racket
[x y z]                             ; untyped (bare names)
[(x : Int) (y : Int)]                ; wrapped with type
[(x : Int) y]                        ; mix wrapped + bare
[{:keys [name age]}]                ; map destructuring
[{:keys [x y] :as point}]          ; destructure + bind whole map
[[a b & rest]]                      ; sequential destructuring
```

One canonical form: wrapped `(name : Type)`. The marker is `:` (single colon
with spaces). No alternate markers, no inline form. AI-optimization: one
idiom per concept.

## Let binding syntax

```racket
(let [x (some-fn arg)] ...)               ; type inferred from RHS (preferred)
(let [(x : Int) 1 (y : Int) 2] ...)        ; explicit type (only when narrowing)
(let [[a b] pair] ...)                     ; sequential destructuring
(let [{:keys [name age]} person] ...)      ; map destructuring
```

**Let bindings infer types automatically.** If `some-fn` returns `Int`, then
`x` has type `Int` without annotation. Only annotate when you want to narrow
(e.g., force a union to a specific branch).

## Types

| primitive | matches |
|---|---|
| `String` | strings |
| `Int` | integers |
| `Float` | floats |
| `Bool` | true/false |
| `Keyword` | `:foo` style |
| `Symbol` | quoted symbols |
| `Nil` | `nil` |
| `Any` | anything (escape) |

One canonical name per type. JVM names (`Long`, `Double`, `Boolean`) are
accepted as `#lang beagle/clj` sugar but resolve to `Int`, `Float`, `Bool`.

Function types:
- `[A B -> R]`                   fixed arity
- `[A & T -> R]`                 variadic (zero+ extra `T` args)
- `[-> R]`                       nullary

Parametric:
- `(Vec T)`, `(List T)`, `(Set T)`, `(Map K V)`

Union:
- `(U String Int)` — value is one of the alternatives

Nullable (sugar for `(U T Nil)`):
- `String?` — shorthand for `(U String Nil)`
- `Product?` — shorthand for `(U Product Nil)`

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
- `safe` macros use gensym-hygienic substitution; `unsafe` macros use naive substitution

## Pre-typed stdlib (~696 functions)

**Math** (variadic Any): `+`, `-`, `*`, `/`, `mod`, `quot`, `rem`, `inc`,
`dec`, `min`, `max`, `abs`

**Comparison**: `=`, `not=`, `<`, `>`, `<=`, `>=`, `identical?`, `compare`,
`zero?`, `pos?`, `neg?`, `even?`, `odd?`

**Bool**: `not`, `and`, `or`, `true?`, `false?`, `nil?`, `some?`

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

**Also typed** (~607 total): transducers (`map`/`filter`/`cat`/`halt-when`),
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

## JavaScript target (`#lang beagle/js`)

File extension: `.bjs`. Use `#lang beagle/js`.

### Form mapping (beagle → JS)

| beagle | JavaScript |
|---|---|
| `(defn name [params] body)` | `function name(params) { return body; }` |
| `(def name value)` | `const name = value;` |
| `(fn [params] body)` | `(params) => body` |
| `(let [x 1 y 2] body)` | IIFE: `(() => { const x = 1; const y = 2; return body; })()` |
| `(defrecord R [(f : T)])` | `Object.freeze({_tag: "R", f: ...})` |
| `(match expr ...)` | `_tag ===` checks |
| `(for [x coll] body)` | `coll.map(x => body)` / `.filter()` for `:when` |
| `(with rec [:f val])` | `Object.freeze({...rec, f: val})` |
| `nil` | `null` |
| `println` | `console.log` |

### Async/await

```racket
(defn fetch-data [(url : String)] : (Promise String)
  (await (http/get url)))
```

- `(await expr)` — emits `await expr`
- `(Promise T)` — typed promise; functions containing `await` are auto-detected as async
- No explicit `async` keyword needed — the emitter adds it when `await` is present

### Identifier mangling

Lisp identifiers are mangled to valid JS names:

| character | replacement |
|---|---|
| `-` | `_` |
| `?` | `_p` |
| `!` | `_bang` |

Example: `valid-email?` → `valid_email_p`, `reset!` → `reset_bang`

### Module imports

```racket
(require util :as u)           ; → import * as u from './util.js'
(require data.transform)       ; → import * as data_transform from './data.transform.js'
```

Emits ES module `import` statements. All beagle cross-module type
resolution works identically — `require` imports types, records, and
function signatures for the checker regardless of target.

## SQL target (`#lang beagle/sql`)

File extension: `.bgl`. Use `#lang beagle/sql` or `(define-target sql)`.

### Schema declarations

`deftable` declares a table schema for type checking (no SQL output):

```racket
(deftable products
  [(id    : Int    :primary-key)
   (name  : String :not-null)
   (price : Float  :not-null)
   (stock : Int    :default 0)])
```

### Query forms

```racket
;; SELECT with clauses
(select [p.id p.name (count o.id :as order_count)]
  (from products :as p)
  (left-join orders :as o (= o.product_id p.id))
  (where (> p.stock 0))
  (group-by p.id p.name)
  (order-by p.name :asc)
  (limit 10))

;; INSERT
(insert products [name price stock]
  (values ["Widget" 9.99 100]
          ["Gadget" 19.99 50]))

;; UPDATE
(update products
  (set [price (* price 0.9)]
       [stock (+ stock 10)])
  (where (= category "clearance")))

;; DELETE
(delete products
  (where (< total 0)))
```

### Type checking

- Table existence: `insert`/`update`/`delete` validates table is declared via `deftable`
- Column existence: column references (`p.id`) validated against declared schema
- Target gating: SQL forms rejected in non-SQL targets at compile time

### Aggregates

`count`, `sum`, `avg`, `min`, `max` with optional `:as alias`:

```racket
(select [(count id) (avg price :as avg_price)] (from products))
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
(declare-extern .exists [Any -> Bool])
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
| Static field access | `Math/PI` as bare symbol returns Any | `declare-extern Math/PI Float` works now |
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

## Errors and notes (compile-time diagnostics)

**Errors** fail the check. **Notes** are provenance warnings — each one
indicates a real bug with high confidence. Treat every note as actionable.

Set `BEAGLE_ERROR_FORMAT=json` for structured output. JSON fields:
`tool`, `kind`, `message`, `file`, `line`, `col`, `signature`,
`expected`, `actual`, `arg-position`, `arg-expr`, `arg-signature`,
`suggestions[]` (with `replace`/`with`/`signature`), `help`.

Error kinds: `arity`, `type-mismatch`, `return-type`, `def-type`,
`let-binding`, `compile-error`.

Human-readable output (default) uses Rust-style formatting:
```
error[E002]: call to <=: arg 1 expected Int, got String
  --> promotions.rkt:37
   |
37 |        (<= (campaign-name campaign) now)
   |
   = sig: <= : [Int Int -> Bool]
   = note: campaign-name : [Campaign -> String]
   = help: did you mean campaign-start-date? (campaign-start-date : [Campaign -> Int])
```

### Provenance notes (scalar lint)

These appear alongside type errors and indicate bugs with high precision:

```
note: scalar provenance: ->Amount receives value derived from Price
  --> orders.rkt:40
  = Amount wraps an Int backing value, but the argument originated from Price

note: cross-scalar comparison: InstrumentId vs AccountId
  --> trades.rkt:72
  = comparing values derived from incompatible scalar types

note: unused parameter 'fill-ts' in fill-order
  --> orders.rkt:54

note: unused let binding 'acct-id'
  --> trades.rkt:63

note: call to undefined function 'calculate-pnl'
  --> reports.rkt:89
```

Each note means: something is wrong at that location. Common fixes:
- **scalar provenance mismatch**: you're wrapping the wrong backing value —
  use the correct scalar accessor (e.g., `amount-value` not `price-value`)
- **cross-scalar comparison**: you're comparing IDs of different entity types —
  use the correct record accessor
- **unused parameter/binding**: the function should be using that value but isn't
- **undefined function**: typo or missing import

## Tools

### Reactive daemon
- `bin/beagle-daemon start --watch DIR` — start daemon + inotify watcher; re-checks every .rkt file within ~100ms of save. With the PostToolUse hook configured, enriched errors are injected after every edit.
- `bin/beagle-daemon query check-enriched DIR` — synchronous type check + enriched context (JSON)
- `bin/beagle-daemon query check-result FILE` — return cached result from watcher (instant)
- `bin/beagle-verify-enriched BUILD-DIR VERIFY` — run verify + auto-diagnose with trace/cascade

### Compile & check
- `bin/beagle-build SOURCE.rkt [OUT.clj]` — compile one file
- `bin/beagle-build-all FILE-OR-DIR... [--out DIR] [--warn]` — batch compile (9x faster); `--warn` emits despite type errors
- `bin/beagle-check SOURCE.rkt` — type-check only, no emit
- `bin/beagle-check-all FILE-OR-DIR...` — batch type-check (10x faster); daemon makes this redundant during edit loop
- `bin/beagle-expand SOURCE.rkt` — show post-macro source

### Query
- `bin/beagle-sig FN-NAME FILE-OR-DIR...` — print function's type signature
- `bin/beagle-fields RECORD FILE-OR-DIR...` — print record fields + accessors (daemon enrichment includes these)
- `bin/beagle-callers FN-NAME FILE-OR-DIR...` — find all call sites
- `bin/beagle-provides FILE-OR-DIR...` — list module exports with types
- `bin/beagle-impact FN-NAME FILE-OR-DIR...` — callers + impact of signature change

### Repair toolchain (use these to fix bugs efficiently)
- `bin/beagle-repair SOURCE-DIR VERIFY [--auto] [--emit-patch]` — **start here.** Runs the full pipeline and produces a ranked repair queue. `--emit-patch` outputs a unified diff to stdout (`git apply` compatible) — zero reasoning needed for mechanical fixes.
- `bin/beagle-trace BUILD-DIR VERIFY [--focus FN]` — when a logic bug isn't obvious, trace shows the exact arithmetic operation that diverged and its source line.
- `bin/beagle-specfix BUILD-DIR VERIFY` — generates candidate fixes from ratio analysis, verifies each against the oracle. Only reports fixes that pass with 0 regressions.
- `bin/beagle-cascade SOURCE-DIR VERIFY --from-failures` — when many assertions fail, this finds root causes. Fix the highest-cascade-score function first (one fix may resolve multiple downstream failures).
- `bin/beagle-blame BUILD-DIR VERIFY` — quick ratio hints (sign error, multiplier, boolean flip). Useful for fast triage.
- `bin/beagle-oracle GOLDEN-DIR [--diff MODIFIED-DIR]` — generates a verify script from golden code. Use `--diff` to find which functions produce different output.
- `bin/beagle-proptest SOURCE-DIR [--run]` — generates structural property tests from type info (record round-trips).

### Repair workflow (recommended order)

1. `beagle-daemon start --watch .` — reactive checking on every save
2. `beagle-fix --apply .` — auto-fix mechanical type errors
3. Fix remaining type errors (daemon hook shows errors after each edit)
4. `beagle-build-all *.rkt --out .build/` — compile
5. `beagle-verify-enriched .build/ verify.clj` — verify + auto-diagnose
6. Fix root causes first (highest cascade score), rerun oracle
7. Iterate until 0 failures

## Empirical baseline

3 syntactic variants tested (A canonical, B required-types, C minimal),
multiple LLM samples per task, real Clojure behavior verification. 100%
behavior pass after empirically-driven bug fixes. See `experiments/report.md`.
