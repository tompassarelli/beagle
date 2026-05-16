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
(declare-extern foo [Long -> Long])   ; optional; can repeat
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

### `defn`

```racket
(defn NAME [PARAMS] BODY...)
(defn NAME [PARAMS] : ReturnType BODY...)
```

Where PARAMS is a list of `NAME` or `(NAME : Type)`.

Example:
```racket
(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn id [x] x)
```

### `fn` (anonymous function)

```racket
(fn [PARAMS] BODY...)
(fn [PARAMS] : ReturnType BODY...)
```

Example:
```racket
(fn [(x : Long)] (+ x 1))
```

### `let`

```racket
(let [NAME VALUE NAME VALUE ...] BODY...)
(let [NAME : Type VALUE ...] BODY...)
```

Example:
```racket
(let [x 1 y 2]
  (+ x y))

(let [area : Long (* w h)]
  area)
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

```racket
(cond
  [TEST BODY...]
  [TEST BODY...]
  ...)
```

Example:
```racket
(cond
  [(< n 0) "negative"]
  [(= n 0) "zero"]
  [(> n 0) "positive"])
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
(for [NAME COLL ... :when PRED] BODY...)
```

List comprehension. Binds each name to successive values from its
collection. Optional `:when` clauses filter. Example:
```racket
(for [x (range 5) y (range x) :when (even? y)]
  [x y])
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
(defrecord Employee [(name : String) (rate : Long)])

(def alice (->Employee "Alice" 95))
(def n : String (employee-name alice))

(defn total-cost [(e : Employee) (hours : Long)] : Long
  (* (employee-rate e) hours))
```

Emits:
```clojure
(defrecord Employee [name rate])
(defn employee-name [r] (:name r))
(defn employee-rate [r] (:rate r))
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

### `doseq`

```racket
(doseq [NAME COLL ...] BODY...)
```

Side-effecting iteration. Same binding syntax as `for` (multiple bindings,
`:when` clauses). Returns nil.

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
(-> VALUE FORMS...)
(->> VALUE FORMS...)
```

Pass-through to Clojure — emitted verbatim. Thread-first inserts the value
as the first argument of each form; thread-last inserts as the last.

Example:
```racket
(-> person :name (str/upper-case))
(->> items (filter even?) (map inc) (reduce +))
```

## Data

### Vector literal

```racket
[ITEMS...]
```

Example:
```racket
[1 2 3]
[(name : String) (age : Long)]    ; in param-list positions
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
(declare-extern .startsWith [String String -> Boolean])
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
(require clojure.string :as cstr)
```

Emits a `(:require ...)` clause in the generated `(ns ...)`. Does NOT
import types — pair with `declare-extern` for type info.

### `declare-extern`

```racket
(declare-extern NAME TypeExpr)
```

Declares the type of an external (Clojure-side) function so beagle can
type-check calls to it.

Example:
```racket
(declare-extern clojure.string/upper-case [String -> String])
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

Emits the literal string verbatim. Use for top-level Clojure that beagle
doesn't model.

Example:
```racket
(unsafe "(defn helper [x] (some-clj-thing x))")
```

## Types

### Primitives

`String`, `Long`, `Double`, `Boolean`, `Keyword`, `Symbol`, `Nil`, `Any`.

One canonical name per type. Former aliases (`Integer`, `Int`, `Float`,
`Bool`) were removed in the AI-optimization pass.

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

Beagle does NOT catch (yet):

- Parametric type inference (`(Vec T)` element types treated as Any)
- Macro hygiene (naive substitution)

## Tools

- `bin/beagle-build SOURCE.rkt [OUT.clj]` — compile one file
- `bin/beagle-build-all [DIR]` — compile every `.rkt` in a tree
- `bin/beagle-expand SOURCE.rkt` — print source post-macro-expansion
- `raco test tests/` — run beagle's own test suite
