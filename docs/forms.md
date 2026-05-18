# beagle — form catalog

Canonical reference for every form beagle understands. One form, one shape,
one example each. Designed for LLMs to ground on.

## File structure

A beagle source file:

```racket
#lang beagle

(ns example.demo)             ; optional; default beagle.user
(define-mode strict)          ; optional; default strict

(require some.namespace)      ; optional; can repeat
(declare-extern foo [Int -> Int])      ; optional; can repeat
(define-macro safe inc1 (x) (+ x 1))  ; optional; can repeat

; ... bodies follow ...
```

Order: meta forms (ns, define-mode, require, declare-extern, define-macro)
can appear anywhere but conventionally go at the top.

## Bindings

### `def`

```racket
(def NAME VALUE)
(def NAME : Type VALUE)
```

Example:
```racket
(def greeting : String "hello")
(def x 42)
```

### `defonce`

```racket
(defonce NAME VALUE)
(defonce NAME : Type VALUE)
```

Like `def` but only binds the name if it is not already defined. Emits
Clojure's `defonce`. Common for top-level state that should survive
namespace reloads.

Example:
```racket
(defonce db-conn : Any (create-connection config))
```

### `defn`

```racket
(defn NAME [PARAMS] BODY...)
(defn NAME [PARAMS] : ReturnType BODY...)
```

Where PARAMS is a list of `NAME` or `(NAME : Type)`.

Example:
```racket
(defn add [(x : Int) (y : Int)] : Int
  (+ x y))

(defn id [x] x)
```

### `defn` (multi-arity)

```racket
(defn NAME
  ([PARAMS] : ReturnType BODY...)
  ([PARAMS] : ReturnType BODY...))
```

Each clause is a separate arity with its own params and return type.

Example:
```racket
(defn greet
  ([(name : String)] : String
    (str "Hello, " name))
  ([(name : String) (title : String)] : String
    (str "Hello, " title " " name)))
```

Emits Clojure's native multi-arity syntax. The checker validates calls
against all arities and reports available options on mismatch.

### `fn` (anonymous function)

```racket
(fn [PARAMS] BODY...)
(fn [PARAMS] : ReturnType BODY...)
```

Example:
```racket
(fn [(x : Int)] (+ x 1))
```

### `let`

```racket
(let [NAME VALUE NAME VALUE ...] BODY...)
(let [(NAME : Type) VALUE ...] BODY...)
```

Bindings infer their type from the right-hand side expression. Type
annotations are optional — only needed when narrowing a union or
overriding inference.

Example:
```racket
(let [x 1 y 2]
  (+ x y))

;; Type inferred: n is Int (strlen returns Int), doubled is Int (* returns Int)
(let [n (strlen name)
      doubled (* n 2)]
  (+ doubled 1))

;; Explicit annotation — only when you want to narrow or document:
(let [(area : Int) (* w h)]
  area)
```

Map and sequential destructuring in let:
```racket
(let [{:keys [name age]} person]
  (str name " is " age))

(let [[x y & rest] coords]
  (+ x y))
```

## Control flow

### `if`

```racket
(if COND THEN [ELSE])
```

Example:
```racket
(if (> x 0) "positive" "non-positive")
(if found? "yes")
```

### `cond`

Bracketed style:
```racket
(cond
  [TEST BODY...]
  [TEST BODY...]
  ...)
```

Flat style (Clojure-compatible):
```racket
(cond
  TEST1 BODY1
  TEST2 BODY2
  :else FALLBACK)
```

Example:
```racket
(cond
  [(< n 0) "negative"]
  [(= n 0) "zero"]
  [(> n 0) "positive"])

;; equivalent flat form
(cond
  (< n 0) "negative"
  (= n 0) "zero"
  (> n 0) "positive")
```

### `when`

```racket
(when COND BODY...)
```

Example:
```racket
(when (> x 0)
  (println "positive")
  x)
```

### `when-not`

```racket
(when-not COND BODY...)
```

Evaluates body when condition is falsy. Expands to `(when (not cond) body...)`.

Example:
```racket
(when-not (empty? items)
  (process items))
```

### `if-not`

```racket
(if-not COND THEN [ELSE])
```

Inverted conditional. Expands to `(if (not cond) then else)`.

Example:
```racket
(if-not (authorized? user) "denied" "allowed")
```

### `when-let`

```racket
(when-let [NAME EXPR] BODY...)
```

Binds `NAME` to the result of `EXPR`; if truthy, evaluates body in scope
with the binding. Returns `Nil` if falsy.

Example:
```racket
(when-let [user (find-user id)]
  (println (user-name user))
  user)
```

### `if-let`

```racket
(if-let [NAME EXPR] THEN-BODY ELSE-BODY)
```

Binds `NAME` to the result of `EXPR`. If truthy, evaluates `THEN-BODY`
with the binding in scope. Otherwise evaluates `ELSE-BODY` (without the binding).

Example:
```racket
(if-let [user (find-user id)]
  (user-name user)
  "anonymous")
```

### `when-some`

```racket
(when-some [NAME EXPR] BODY...)
```

Like `when-let` but tests for non-nil (not truthiness). `false` passes.

Example:
```racket
(when-some [val (get config :timeout)]
  (set-timeout! val))
```

### `if-some`

```racket
(if-some [NAME EXPR] THEN-BODY ELSE-BODY)
```

Like `if-let` but tests for non-nil. `false` passes.

Example:
```racket
(if-some [val (get config :debug)]
  (str "debug=" val)
  "no debug config")
```

### `do`

```racket
(do BODY...)
```

Sequences expressions; returns the last value. Example:
```racket
(do
  (println "side effect")
  42)
```

### `match`

```racket
(match EXPR
  [PATTERN BODY...]
  [PATTERN BODY...]
  ...)
```

Pattern matching with type narrowing. Patterns:
- `(RecordName b1 b2 ...)` — type test + positional field destructuring
- `{:key1 pat1 :key2 pat2}` — map pattern
- `nil`, `"str"`, `42` — literal
- `name` — bind to variable
- `_` — wildcard

Example:
```racket
(defrecord Circle [(radius : Float)])
(defrecord Rect [(width : Float) (height : Float)])

(match shape
  [(Circle r) (* 3.14159 r r)]
  [(Rect w h) (* w h)]
  [_ 0.0])
```

Emits Clojure `cond` with `instance?` checks. Record bindings are
positional: `(Rect w h)` binds `w` = `:width`, `h` = `:height`.

### `loop` / `recur`

```racket
(loop [NAME INIT ...] BODY...)
(recur ARG...)
```

Tail-recursive loop. Bindings work like `let`; `recur` jumps back to
`loop` with new values. Example:
```racket
(loop [acc 1 n 5]
  (if (<= n 1) acc (recur (* acc n) (dec n))))
```

### `for`

```racket
(for [NAME COLL ... :when PRED :let [NAME VAL ...]] BODY...)
```

List comprehension. Binds each name to successive values from its
collection. Optional `:when` clauses filter, `:let` clauses bind
intermediate values. Destructuring works in bindings.

Example:
```racket
(for [x (range 5) y (range x) :when (even? y)]
  [x y])

;; with :let clause
(for [item items :let [price (item-price item) tax (* price 0.1)]]
  (+ price tax))

;; with destructuring
(for [[eid name email] contacts]
  (->Contact eid name email))
```

## Records

### `defrecord`

```racket
(defrecord NAME [(FIELD : TYPE) ...])
```

Defines a Clojure record type with typed fields. Generates:
- A constructor `->NAME` with field types as args, returning `NAME`
- Accessors `lowername-field` for each field

All fields must have type annotations (wrapped form).

Example:
```racket
(defrecord Employee [(name : String) (rate : Int)])

(def alice (->Employee "Alice" 95))
(def n : String (employee-name alice))

(defn total-cost [(e : Employee) (hours : Int)] : Int
  (* (employee-rate e) hours))
```

Emits:
```clojure
(defrecord Employee [name rate])
(defn employee-name [r] (:name r))
(defn employee-rate [r] (:rate r))
```

### `with` (record update)

```racket
(with RECORD-EXPR [:FIELD1 VALUE1] [:FIELD2 VALUE2] ...)
```

Typed record update. Compiles to `(assoc record :field1 val1 :field2 val2 ...)`.

The type checker verifies that each field keyword exists on the target record type
and that the value type is compatible with the field's declared type. Returns the
same record type.

```racket
(defrecord Order [(status : String) (total : Int) (shipped-count : Int)])
(defn confirm [(o : Order)] : Order
  (with o [:status "confirmed"]))
```

If the target expression doesn't resolve to a known record type, `with` still
compiles (to `assoc`) but field validation is skipped.

### `defenum`

```racket
(defenum NAME :VALUE1 :VALUE2 ...)
```

Declares an enum value set. Compiles to `(def NAME-values #{:value1 :value2 ...})`.

```racket
(defenum OrderStatus :placed :confirmed :paid :shipped :delivered :cancelled)
;; → (def OrderStatus-values #{:placed :confirmed :paid :shipped :delivered :cancelled})
```

### `defscalar`

```racket
(defscalar NAME BASE-TYPE)
(defscalar NAME BASE-TYPE :where (PRED1) (PRED2) ...)
```

Nominal scalar (newtype). Creates a distinct type wrapping a base type.
Constructor `->Name`, accessor `name-value`.

```racket
(defscalar Amount Int)
;; (->Amount 500)       — wrap Int into Amount
;; (amount-value a)     — unwrap Amount back to Int

(defscalar Pct Int :where (>= 0) (<= 100))
;; compile-time literal checking + runtime :pre conditions
```

Amount ≠ Int at compile time. Unwrap before arithmetic, rewrap after:
```racket
(->Amount (+ (amount-value a) (amount-value b)))
```

### `defprotocol`

```racket
(defprotocol NAME
  (METHOD-NAME [PARAMS] : RETURN-TYPE)
  ...)
```

Protocol methods are registered with their types — calls are arity-checked.

Example:
```racket
(defprotocol Greetable
  (greet [(self : Any)] : String)
  (farewell [(self : Any)] : String))
```

### `defmulti` / `defmethod`

```racket
(defmulti NAME DISPATCH-FN)
(defmethod NAME DISPATCH-VAL [PARAMS] BODY...)
```

Multimethod dispatch. Dispatch function is any expression (commonly a keyword).

Example:
```racket
(defmulti area :shape)
(defmethod area :circle [m]
  (* 3.14 (:radius m) (:radius m)))
(defmethod area :rect [m]
  (* (:width m) (:height m)))
```

### `deftype`

```racket
(deftype NAME [FIELDS...]
  ProtocolName
  (method-name [PARAMS] BODY...)
  ...)
```

Defines a Java class implementing one or more protocols. Fields are bare
names (not typed params). Multiple protocol implementations allowed.

Example:
```racket
(deftype Counter [n]
  IDeref
  (deref [this] n)
  Printable
  (to-string [this] (str "Counter(" n ")")))
```

### `extend-type`

```racket
(extend-type TYPE-NAME
  ProtocolName
  (method-name [PARAMS] BODY...)
  ...)
```

Extends an existing type with protocol implementations. Same protocol/method
syntax as `deftype` but without fields.

Example:
```racket
(extend-type String
  Greetable
  (greet [this] (str "Hello, " this)))
```

### `try` / `catch` / `finally`

```racket
(try
  BODY...
  (catch ExceptionType name HANDLER-BODY...)
  (finally CLEANUP-BODY...))
```

Multiple `catch` clauses allowed. `finally` is optional.

Example:
```racket
(try
  (Long/parseLong s)
  (catch Exception e
    (println (.getMessage e))
    -1)
  (finally
    (println "done")))
```

### `with-open`

```racket
(with-open [NAME EXPR ...] BODY...)
```

Binds resources, evaluates body, then closes all bindings. Emits
Clojure's `with-open`. Each binding's value must implement `java.io.Closeable`.

Example:
```racket
(with-open [rdr (clojure.java.io/reader "data.csv")]
  (doall (line-seq rdr)))
```

### `doto`

```racket
(doto TARGET FORMS...)
```

Evaluates `TARGET`, threads it as the first argument through each form,
returns the original target. Used for Java mutation chains.

Example:
```racket
(doto (java.util.HashMap.)
  (.put "a" 1)
  (.put "b" 2))
```

### `dotimes`

```racket
(dotimes [NAME COUNT] BODY...)
```

Counted iteration. Binds `NAME` to 0, 1, ..., COUNT-1 and evaluates body
for each. Returns nil.

Example:
```racket
(dotimes [i 10]
  (println (str "iteration " i)))
```

### `condp`

```racket
(condp PRED TEST VALUE1 RESULT1 VALUE2 RESULT2 ... [DEFAULT])
```

Predicate-based dispatch. Tests `(PRED VALUE TEST)` for each clause.
An odd trailing form is the default.

Example:
```racket
(condp = color
  :red   "stop"
  :green "go"
  "unknown")

(condp > n
  10 "small"
  100 "medium"
  "large")
```

### `comment`

```racket
(comment FORMS...)
```

Ignores all forms and returns nil. Used for development-time code that
should not execute.

Example:
```racket
(comment
  (def debug-state (atom {}))
  (println "this is not evaluated"))
```

### `doseq`

```racket
(doseq [NAME COLL ...] BODY...)
```

Side-effecting iteration. Same binding syntax as `for` (multiple bindings,
`:when` and `:let` clauses). Returns nil.

Example:
```racket
(doseq [x items :when (pos? x)]
  (println x))
```

### `case`

```racket
(case TEST
  VALUE1 RESULT1
  VALUE2 RESULT2
  DEFAULT)
```

Constant-time dispatch. Clauses are value/result pairs. An odd trailing
form is the default (like Clojure).

Example:
```racket
(case color
  :red   "stop"
  :green "go"
  "unknown")
```

### Constructor call

```racket
(ClassName. ARGS...)
```

Java constructor. The trailing dot is the marker.

Example:
```racket
(java.io.File. "/tmp/test")
(StringBuilder. "init")
```

### Keyword-as-function

```racket
(:KEY TARGET)
(:KEY TARGET DEFAULT)
```

Keyword lookup on a map or record. If target is a typed record, the
checker infers the field type.

Example:
```racket
(:name person)                  ; returns String if person is typed record with name : String
(:age config "unknown")         ; with default value
(:db/ident schema)              ; namespaced keywords work
```

## Destructuring

### Map destructuring

```racket
{:keys [NAME ...]}
{:keys [NAME ...] :as WHOLE}
```

Works in `defn`, `fn`, and `let` parameter/binding positions. Extracts
keyword-keyed values from a map into local bindings.

Example:
```racket
(defn greet [{:keys [name age]}]
  (str "Hello " name ", age " age))

(let [{:keys [x y] :as point} (get-coords)]
  (println point)
  (+ x y))
```

### Sequential destructuring

```racket
[NAME NAME & REST-NAME]
```

Works in `defn`, `fn`, and `let` parameter/binding positions. Extracts
positional values from a sequential collection.

Example:
```racket
(defn first-two [[a b & rest]]
  (println a b (count rest)))

(let [[x y] pair]
  (+ x y))
```

### Threading macros

```racket
(-> VALUE FORMS...)                         ; thread-first
(->> VALUE FORMS...)                        ; thread-last
(cond-> VALUE TEST FORM TEST FORM ...)      ; conditional thread-first
(cond->> VALUE TEST FORM TEST FORM ...)     ; conditional thread-last
(some-> VALUE FORMS...)                     ; nil-safe thread-first
(some->> VALUE FORMS...)                    ; nil-safe thread-last
(as-> VALUE NAME FORMS...)                  ; named thread
```

`->` and `->>` emit verbatim. `cond->`, `cond->>`, `some->`, `some->>`,
and `as->` expand at parse time into `let`/`if`/`when-some` chains.

Example:
```racket
(-> person :name (str/upper-case))
(->> items (filter even?) (map inc) (reduce +))

(cond-> order
  paid?     (assoc :status :paid)
  shipped?  (assoc :status :shipped))

(some-> user :address :city)

(as-> data $ (map inc $) (filter even? $) (reduce + $))
```

## Metadata

### `^{...}` (metadata reader syntax)

```racket
^{:key value ...} TARGET
^:keyword TARGET
```

Attaches metadata to the following form. `^:keyword` is sugar for
`^{:keyword true}`. Emits Clojure's metadata syntax verbatim.

Example:
```racket
^{:key (str prefix "-" idx)} [item-view item]
^:private (def internal-state (atom {}))
```

## Data

### Vector literal

```racket
[ITEMS...]
```

Example:
```racket
[1 2 3]
[(name : String) (age : Int)]     ; in param-list positions
```

### Map literal

```racket
{KEY1 VALUE1 KEY2 VALUE2 ...}
```

Example:
```racket
{:name "Tom" :age 30}
{(keyword k) v}
```

### Set literal

```racket
#{ITEMS...}
```

Example:
```racket
#{1 2 3}
#{:a :b :c}
```

### Quote

```racket
'DATUM
```

Example:
```racket
'(a b c)        ; quoted list
'foo            ; quoted symbol
```

### Keyword literal (lexical convention, no special form)

```racket
:keyword-name
```

Symbols starting with `:` render in Clojure as keywords.

## Java interop

### Instance method call

```racket
(.method target args...)
```

Example:
```racket
(.exists (io/file path))
(.startsWith name "http")
(.trim input)
```

### Static method call

```racket
(Class/staticMethod args...)
```

Example:
```racket
(System/getProperty "user.home")
(Long/parseLong "42")
(Math/sqrt 2.0)
```

### Dynamic var access

```racket
*var-name*
```

Example:
```racket
(first *command-line-args*)
```

All three forms are type-checked when declared via `declare-extern`. The
receiver is the first parameter in method type signatures:
```racket
(declare-extern .startsWith [String String -> Bool])
(declare-extern System/getProperty [String -> String])
```

~30 common methods and statics are pre-typed in the stdlib.

## Calls

Any form starting with a symbol other than the built-in keywords above is a
function call.

```racket
(FN-NAME ARGS...)
```

Example:
```racket
(+ 1 2 3)
(println "hello")
(my-helper x y)
```

## Meta forms

### `ns`

```racket
(ns NAMESPACE-PATH)
```

Example:
```racket
(ns example.demo)
```

Defaults to `beagle.user` if omitted.

### `define-mode`

```racket
(define-mode strict)        ; default — full type check
(define-mode dynamic)       ; skip type checking
```

### `require`

```racket
(require NAMESPACE)
(require NAMESPACE :as ALIAS)
```

Example:
```racket
(require catalog :as cat)
(require clojure.string :as cstr)
```

Emits a `(:require ...)` clause in the generated `(ns ...)`.

**For beagle modules:** automatically imports all typed defs, defns,
records (constructors + accessors + keyword-field types), and macros.
Cross-module calls are fully type-checked without `declare-extern`:

```racket
(require inventory :as inv)

;; Type checker knows inv/can-fulfill? : [(Vec StockLevel) Int Int -> Bool]
;; No declare-extern needed — it was imported from inventory.rkt's source
(inv/can-fulfill? levels product-id qty)
```

**For Clojure namespaces** (e.g. `clojure.string`): emits the require
but cannot import types (no beagle source to read). Use `declare-extern`
for type-checked calls to these, or accept `Any`-typed pass-through.

### `declare-extern`

```racket
(declare-extern NAME TypeExpr)
```

Declares the type of a function not available via beagle source import.
**Only needed for:**
- Java interop methods/statics not in stdlib
- Clojure library functions (non-beagle namespaces)
- Dynamic vars

**NOT needed for** cross-module beagle calls — `(require module :as alias)`
imports types automatically.

Example:
```racket
;; Clojure library function (no beagle source):
(declare-extern clojure.string/upper-case [String -> String])

;; Java interop:
(declare-extern .getAbsolutePath [Any -> String])
```

Emits nothing in the output Clojure.

### `define-macro`

```racket
(define-macro safe NAME (PARAMS) TEMPLATE)
(define-macro unsafe NAME (PARAMS) TEMPLATE)
```

Macro params may include `&rest-name` to collect remaining args into a list.
Templates may use `(splice rest-name)` to inline that list.

- `safe` — expansion is type-checked normally
- `unsafe` — expansion is typed as `Any` (escape boundary)

Examples:
```racket
(define-macro safe inc1 (x)
  (+ x 1))

(define-macro safe call-with (f & args)
  (f (splice args)))

(define-macro unsafe debug-call (form)
  (do (println "trace") form))
```

### `import`

```racket
(import FULLY.QUALIFIED.CLASS)
```

Emits a `(:import [package ClassName])` clause in the generated ns form.

Example:
```racket
(import java.io.File)
(import java.time.Instant)
```

### `unsafe` (inline)

```racket
(unsafe "RAW-CLOJURE-SOURCE")
```

Emits the literal string verbatim. Works at top-level and in expression
position. Use for Clojure that beagle doesn't model. Typed as `Any`.

Example:
```racket
(unsafe "(defn helper [x] (some-clj-thing x))")
```

## Types

### Primitives

`String`, `Int`, `Float`, `Bool`, `Keyword`, `Symbol`, `Nil`, `Any`.

One canonical name per type. Former aliases (`Integer`, `Long`, `Double`,
`Boolean`) were removed in the AI-optimization pass.

User-defined types (from `defrecord`) are also valid in annotations:
`Employee`, `Config`, etc.

### Function types

```
[A B -> R]                 ; fixed-arity function: (A, B) → R
[A B & T -> R]             ; variadic: (A, B, T, T, ...) → R
[-> R]                     ; nullary: () → R
```

### Parametric

```
(Vec T)
(List T)
(Set T)
(Map K V)
```

### Union

```
(U A B C)
```

A value of type `(U A B C)` is one of A, B, or C.

## Compile-time validation

Beagle catches these at expand time (in strict mode):

- Unknown type names in annotations
- Field type mismatch in `def`/`defn`/`fn`/`let` annotated bindings (against
  inferable values like literals)
- Wrong arity in calls to declared functions
- Wrong arg types in calls to declared functions
- Variadic rest-type violations
- Unknown forms (anything not in this catalog)
- Reference to undefined macros

## Tools

See `CLAUDE.md` for the full tool list (~25 tools including repair, query,
LSP, REPL, proptest, oracle, dtrace, daemon, source maps, mutation testing).
