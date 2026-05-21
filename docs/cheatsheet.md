# beagle — one-page cheatsheet

Everything an LLM needs to ground on. Single canonical reference. Optimized
for being included as system context. Generated from Scribble docs —
edit `beagle-doc/scribblings/*.scrbl`, then run `bin/beagle-gen-cheatsheet`.

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

## Getting Started

### Installation

Install beagle as a linked Racket package:

`raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/`

If using Nix, the flake provides a dev shell:

`echo 'use flake' > .envrc && direnv allow`

### File Structure

A beagle source file uses the `#lang beagle` declaration:

```racket
#lang beagle                                                                
                                                                            
(ns example.demo)              ; namespace (default: beagle.user)           
(define-mode strict)           ; default; or dynamic to skip type checks    
(require some.module :as mod)  ; import types/fns from another beagle module
(declare-extern fn [A -> R])   ; only for Java interop or non-beagle fns    
(import java.io.File)          ; Java class import                          
                                                                            
;; definitions follow...                                                    
(def greeting : String "hello")                                             
                                                                            
(defn add [(x : Int) (y : Int)] : Int                                       
  (+ x y))                                                                  
```

Meta forms (`ns`, `define-mode`, `require`, `declare-extern`,
`define-macro`, `import`) can appear anywhere but conventionally go at
the top.

### Compiling and Checking

* `beagle check .` — type-check all files in the current directory

* `beagle build . –out .build/` — compile beagle to Clojure source

* `beagle fix –apply .` — auto-fix mechanical type errors

* `beagle sig fn-name .` — query a function’s type signature

* `beagle repl` — interactive REPL with type checking

* `beagle lsp` — LSP server for editor integration

### Cross-Module Imports

`(require module :as alias)` imports all typed definitions, records,
scalars, and macros from another beagle module. No `declare-extern` is
needed for cross-module beagle calls:

```racket
(require inventory :as inv)                                                 
                                                                            
;; Type checker knows: inv/can-fulfill? : [(Vec StockLevel) Int Int -> Bool]
(inv/can-fulfill? levels product-id qty)                                    
```

For non-beagle namespaces (Clojure libraries), use `declare-extern` for
type-checked calls, or accept `Any`-typed pass-through.

### Claude Code Integration

For a one-command setup with Claude Code (hooks, daemon, context):

`beagle init --claude-code`

This creates:

* `.claude/beagle-context.md` — language reference for system context

* `.claude/hooks/beagle-check.sh` — PostToolUse hook for instant type
  feedback

* `.claude/settings.json` — hook wiring

* `CLAUDE.md` — project instructions

Then start the daemon: `beagle-daemon start –watch .`

Without `–claude-code`, `beagle init` only creates the context file.

### Viewing Documentation

After installation, view these docs locally:

`raco docs beagle`

## Definitions

Top-level definitions bind names for use throughout a module. Type
annotations are optional but recommended — the checker infers types from
right-hand-side expressions when annotations are absent.

### def

```racket
(def name value)
```

Defines a top-level binding. The type is inferred from `value`.

```racket
(def name : Type value)
```

Defines a typed top-level binding. Raises a compile-time error if the
inferred type of `value` is not compatible with `Type`.

```racket
(def greeting : String "hello")
(def x 42)                     
```

### defonce

```racket
(defonce name value)
```

Like `def` but only binds if `name` is not already defined. Emits
Clojure’s `defonce`. Common for top-level state that should survive
namespace reloads.

```racket
(defonce db-conn : Any (create-connection config))
```

### defn

```racket
(defn name [params] body ...)
```

Defines a function with the given parameters and body. Parameters may be
bare names or typed with `(name : Type)`.

```racket
(defn name [params] : ReturnType body ...)
```

Defines a function with an explicit return type. The checker verifies
the body’s inferred type is compatible.

```racket
(defn add [(x : Int) (y : Int)] : Int
  (+ x y))                           
                                     
(defn id [x] x)                      
```

#### Multi-Arity

```racket
(defn name (clause ...) ...)
```

Multi-arity function. Each clause is `([params] : ReturnType body ...)`.

```racket
(defn greet                                   
  ([(name : String)] : String                 
    (str "Hello, " name))                     
  ([(name : String) (title : String)] : String
    (str "Hello, " title " " name)))          
```

### fn (anonymous function)

```racket
(fn [params] body ...)
```

Anonymous function.

```racket
(fn [(x : Int)] (+ x 1))
```

### let

```racket
(let [name value ...] body ...)
```

Local bindings. Types are inferred from right-hand-side expressions.
Explicit type annotations are optional and only needed when narrowing.

```racket
(let [x 1 y 2] (+ x y))                                
                                                       
;; Explicit annotation only when narrowing:            
(let [(area : Int) (* w h)] area)                      
                                                       
;; Destructuring:                                      
(let [{:keys [name age]} person] (str name " is " age))
(let [[x y & rest] coords] (+ x y))                    
```

## Types

### Primitives

| **Type** | **Matches** |
|---|---|
| `String` | strings |
| `Int` | integers |
| `Float` | floats |
| `Bool` | true/false |
| `Keyword` | :foo style keywords |
| `Symbol` | quoted symbols |
| `Nil` | nil |
| `Any` | anything (escape hatch) |
| `Number` | (U Int Float) — prefer Int or Float when known |

One canonical name per type. JVM names (`Long`, `Double`, `Boolean`) are
accepted as compatibility sugar in `#lang beagle/clj` but resolve to the
canonical names above.

### Function Types

* `[A B -> R]` — fixed-arity function taking `A` and `B`, returning `R`

* `[A & T -> R]` — variadic: one `A` then zero or more `T` args

* `[-> R]` — nullary function

### Parametric Types

* `(Vec T)` — vector of `T`

* `(List T)` — list of `T`

* `(Set T)` — set of `T`

* `(Map K V)` — map from `K` to `V`

* `(Promise T)` — promise resolving to `T`

### Union Types

`(U A B C)` — value is one of the alternatives.

### Nullable Sugar

`String?` is shorthand for `(U String Nil)`. Works with any type:
`Product?` means `(U Product Nil)`.

### Type Narrowing

Flow-sensitive narrowing in `if`/`cond`/`when` via predicates like
`nil?`, `some?`, `string?`, `=`, `not`.

```racket
(defn safe-name [(x : String?)] : String                                   
  (if (nil? x) "unknown" x))   ; x is narrowed to String in the then branch
```

### Polymorphic Types

`(forall [A] [A -> A])` introduces type variables for generic functions.

#### Bounded Polymorphism

Type variables can be constrained with upper bounds using `<:`:

```racket
(forall [(T <: HasName)] [T -> String])            
(forall [(T <: (U Circle Rectangle))] [T -> Float])
```

Without bounds, `T` accepts anything. With `<:`, the checker verifies
the inferred type satisfies the bound.

### Let Binding Inference

Let bindings infer types automatically from the right-hand side:

```racket
(let [x (get-product id)] ...)     ; x : Product (inferred)            
(let [{:keys [name]} product] ...) ; name : String (from record fields)
```

Explicit annotations are only needed when narrowing:

```racket
(let [(area : Int) (* w h)] area)
```

### Collection Type Inference

Collection literals infer element types from their contents:

```racket
[(->Product 1 "A") (->Product 2 "B")]  ; (Vec Product), not (Vec Any)
{:a 1 :b 2}                             ; (Map Keyword Int)          
#{:x :y :z}                             ; (Set Keyword)              
```

## Records, Scalars, and Enums

### defrecord

```racket
(defrecord Name [(field : Type) ...])
```

Defines a typed record. Generates a constructor, typed accessors, and
keyword-access support.

```racket
(defrecord Employee [(name : String) (rate : Int)])  
                                                     
(def alice (->Employee "Alice" 95))                  
(def n : String (employee-name alice))               
(:name alice)  ; returns String via keyword inference
```

Generated functions:

* Constructor: `->Employee` typed `[String Int -> Employee]`

* Accessors: `employee-name` typed `[Employee -> String]`,
  `employee-rate` typed `[Employee -> Int]`

* Keyword access: `(:name e)` infers field type when `e` is a known
  `Employee`

Compiles to Clojure `defrecord` plus generated accessor functions:

```racket
;; Generated Clojure:                              
(defrecord Employee [name rate])                   
(defn ->Employee [name rate] (Employee. name rate))
(defn employee-name [r] (:name r))                 
(defn employee-rate [r] (:rate r))                 
```

### with (record update)

```racket
(with record [:field value] ...)
```

Typed record update. Compiles to `(assoc record :field1 val1 ...)`. The
type checker verifies each field exists on the record type and the value
type matches the field’s declared type.

```racket
(defrecord Order [(status : String) (total : Int)])
(defn confirm [(o : Order)] : Order                
  (with o [:status "confirmed"]))                  
```

### defscalar (nominal types)

```racket
(defscalar Name BackingType)
```

Creates a nominal type wrapping a primitive. `Amount`, `Timestamp`, and
`AccountId` can all be `Int` at runtime but the type checker treats them
as incompatible.

```racket
(defscalar Amount Int)                       
(defscalar Email String)                     
                                             
(def total (->Amount 5000))     ; wrap       
(def n (amount-value total))    ; unwrap: Int
```

```racket
(defscalar Name BackingType :where (pred) ...)
```

Refinement predicates add compile-time literal checking and runtime
`:pre` conditions.

```racket
(defscalar Percentage Int :where (>= 0) (<= 100))               
(->Percentage 150)   ; compile-time error: 150 violates (<= 100)
```

### defenum

```racket
(defenum Name :value ...)
```

Declares an enum value set. Compiles to `(def Name-values #{:value1
...})`. Useful for constraining keyword fields to a known set of values.

```racket
(defenum OrderStatus :placed :confirmed :paid :shipped :delivered :cancelled)
```

### defunion (tagged unions)

```racket
(defunion Name Member ...)
```

Declares a tagged union. Each member is a `defrecord`. Combined with
exhaustive `match`, forgetting a case is a compile error.

```racket
(defrecord Circle [(radius : Float)])              
(defrecord Rect [(width : Float) (height : Float)])
(defunion Shape Circle Rect)                       
                                                   
(defn area [(s : Shape)] : Float                   
  (match s                                         
    [(Circle r) (* 3.14159 r r)]                   
    [(Rect w h) (* w h)]))                         
```

Members can be defined inline with field specs:

```racket
(defunion Shape                             
  (Circle [(radius : Float)])               
  (Rect [(width : Float) (height : Float)]))
```

#### Parametric defunion

```racket
(defunion (Name T ...) (Member [(field : Type)] ...) ...)
```

Type-parameterized unions. Type variables from the union name are
substituted into member fields:

```racket
(defunion (Result T E)                             
  (Ok [(value : T)])                               
  (Err [(error : E)]))                             
                                                   
(defn find-user [(id : Int)] : (Result User String)
  (if (valid? id)                                  
    (->Ok (load-user id))                          
    (->Err "not found")))                          
                                                   
;; Exhaustive match required:                      
(match (find-user 42)                              
  [(Ok user) (user-name user)]                     
  [(Err msg) (str "Error: " msg)])                 
```

### defprotocol

```racket
(defprotocol Name (method-name [params] : ReturnType) ...)
```

Defines a protocol with typed method signatures.

```racket
(defprotocol Greetable            
  (greet [(self : Any)] : String))
```

### deftype

```racket
(deftype Name [fields ...] ProtocolName (method [params] body ...) ...)
```

Defines a type implementing one or more protocols.

```racket
(deftype Counter [n]
  IDeref            
  (deref [this] n)) 
```

### extend-type

```racket
(extend-type TypeName ProtocolName (method [params] body ...) ...)
```

Extends an existing type with protocol implementations.

```racket
(extend-type String                   
  Greetable                           
  (greet [this] (str "Hello, " this)))
```

### defmulti / defmethod

```racket
(defmulti name dispatch-fn)
```

Defines a multimethod with the given dispatch function.

```racket
(defmethod name dispatch-val [params] body ...)
```

Adds an implementation for a dispatch value.

```racket
(defmulti area :shape)             
(defmethod area :circle [m]        
  (* 3.14 (:radius m) (:radius m)))
```

## Control Flow

### if

```racket
(if cond then else)
```

Conditional. Type narrows in branches when condition uses `nil?`,
`some?`, etc.

```racket
(if (> x 0) "positive" "non-positive")
```

```racket
(if cond then)
```

Without else branch, returns `Nil` when condition is false.

### if-not

```racket
(if-not cond then else)
```

Inverted conditional. Expands to `(if (not cond) then else)`.

```racket
(if-not (authorized? user) "denied" "allowed")
```

### cond

```racket
(cond [test body ...] ...)
```

Multi-branch conditional (bracketed style).

```racket
(cond                  
  [(< n 0) "negative"] 
  [(= n 0) "zero"]     
  [(> n 0) "positive"])
```

Also supports flat Clojure-style: `(cond test1 body1 test2 body2 :else
fallback)`.

### condp

```racket
(condp pred test value result ... default)
```

Predicate-based dispatch. Tests `(pred value test)` for each clause. An
odd trailing form is the default.

```racket
(condp = color 
  :red   "stop"
  :green "go"  
  "unknown")   
```

### when

```racket
(when cond body ...)
```

Evaluates body when condition is truthy. Returns `Nil` otherwise.

```racket
(when (> x 0)         
  (println "positive")
  x)                  
```

### when-not

```racket
(when-not cond body ...)
```

Evaluates body when condition is falsy. Expands to `(when (not cond)
body...)`.

```racket
(when-not (empty? items)
  (process items))      
```

### when-let

```racket
(when-let [name expr] body ...)
```

Binds `name` to the result of `expr`; evaluates body if truthy.

```racket
(when-let [user (find-user id)]
  (println (user-name user)))  
```

### if-let

```racket
(if-let [name expr] then else)
```

Binds `name` to the result of `expr`. If truthy, evaluates `then` with
the binding in scope. Otherwise evaluates `else`.

```racket
(if-let [user (find-user id)]
  (user-name user)           
  "anonymous")               
```

### when-some / if-some

```racket
(when-some [name expr] body ...)
```

Like `when-let` but tests for non-nil (not truthiness). `false` passes.

```racket
(when-some [val (get config :debug)]
  (enable-debugging val))           
```

```racket
(if-some [name expr] then else)
```

Like `if-let` but tests for non-nil.

```racket
(if-some [port (get config :port)]
  (start-server port)             
  (start-server 8080))            
```

### case

```racket
(case test value result ... default)
```

Constant-time dispatch. An odd trailing form is the default.

```racket
(case color    
  :red   "stop"
  :green "go"  
  "unknown")   
```

### match

```racket
(match expr [pattern body ...] ...)
```

Pattern matching with type narrowing.

Patterns:

* `(RecordName b1 b2 ...)` — type test + positional field destructuring

* `{:key1 pat1 :key2 pat2}` — map pattern

* `nil`, `"str"`, `42` — literals

* `name` — bind to variable

* `_` — wildcard

```racket
(defrecord Circle [(radius : Float)])              
(defrecord Rect [(width : Float) (height : Float)])
                                                   
(match shape                                       
  [(Circle r) (* 3.14159 r r)]                     
  [(Rect w h) (* w h)]                             
  [_ 0.0])                                         
```

### try / catch / finally

```racket
(try body ... (catch ExType name handler ...) (finally cleanup ...))
```

Exception handling. Multiple `catch` clauses allowed. `finally` is
optional.

```racket
(try                         
  (Long/parseLong s)         
  (catch Exception e         
    (println (.getMessage e))
    -1)                      
  (finally                   
    (println "done")))       
```

### do

```racket
(do body ...)
```

Sequences expressions; returns the last value. Used where a single
expression is expected but multiple side effects are needed.

```racket
(do                    
  (println "saving...")
  (save-record! rec)   
  (println "done")     
  rec)                 
```

### comment

```racket
(comment forms ...)
```

Ignores all forms and returns `nil`. Used for development-time scratch
code and inline examples. The forms are not evaluated or type-checked.

```racket
(comment                   
  (start-server 8080)      
  (run-tests)              
  (println "scratch area"))
```

## Iteration and Comprehensions

Beagle supports Clojure’s full iteration toolkit: list comprehensions,
side-effecting loops, counted iteration, and tail-recursive
`loop`/`recur`.

### for

```racket
(for [name coll ... :when pred :let [name val ...]] body ...)
```

List comprehension. Binds each name to successive values from its
collection. Optional `:when` clauses filter, `:let` clauses bind
intermediate values. Destructuring works in bindings.

Returns `(Vec BodyType)`.

```racket
(for [x (range 5) y (range x) :when (even? y)]                    
  [x y])                                                          
                                                                  
;; with :let                                                      
(for [item items :let [price (item-price item) tax (* price 0.1)]]
  (+ price tax))                                                  
                                                                  
;; with destructuring                                             
(for [[eid name email] contacts]                                  
  (->Contact eid name email))                                     
```

### doseq

```racket
(doseq [name coll ...] body ...)
```

Side-effecting iteration. Same binding syntax as `for` (multiple
bindings, `:when` and `:let` clauses). Returns `nil`.

```racket
(doseq [x items :when (pos? x)]
  (println x))                 
```

### dotimes

```racket
(dotimes [name count] body ...)
```

Counted iteration. Binds `name` to `0`, `1`, ..., `count-1`. The binding
is typed as `Int`. Returns `nil`.

```racket
(dotimes [i 10]                  
  (println (str "iteration " i)))
```

### loop / recur

```racket
(loop [name init ...] body ...)
```

Tail-recursive loop. Bindings work like `let`; `recur` jumps back with
new values.

```racket
(loop [acc 1 n 5]                             
  (if (<= n 1) acc (recur (* acc n) (dec n))))
```

### Threading Macros

```racket
(-> value forms ...)
```

Thread-first: inserts value as first argument.

```racket
(->> value forms ...)
```

Thread-last: inserts value as last argument.

```racket
(cond-> value test form ...)
```

Conditional thread-first.

```racket
(cond->> value test form ...)
```

Conditional thread-last.

```racket
(some-> value forms ...)
```

Nil-safe thread-first (short-circuits on nil).

```racket
(some->> value forms ...)
```

Nil-safe thread-last.

```racket
(as-> value name forms ...)
```

Named thread: binds `name` to the intermediate value at each step.

```racket
(-> person :name (str/upper-case))                     
(->> items (filter even?) (map inc) (reduce +))        
                                                       
(cond-> order                                          
  paid?     (assoc :status :paid)                      
  shipped?  (assoc :status :shipped))                  
                                                       
(some-> user :address :city)                           
                                                       
(as-> data $ (map inc $) (filter even? $) (reduce + $))
```

## Java Interop and Data Literals

### Instance Methods

```racket
(.method target args ...)
```

Java instance method call. The receiver is typed when declared via
`declare-extern` or the stdlib.

```racket
(.exists (io/file path)) 
(.startsWith name "http")
(.trim input)            
```

### Static Methods

```racket
(Class/staticMethod args ...)
```

Java static method call.

```racket
(System/getProperty "user.home")
(Long/parseLong "42")           
(Math/sqrt 2.0)                 
```

### Constructor Calls

```racket
(ClassName. args ...)
```

Java constructor. The trailing dot is the marker.

```racket
(java.io.File. "/tmp/test")
(StringBuilder. "init")    
```

### Dynamic Vars

Symbols wrapped in `*earmuffs*` are dynamic var references:

```racket
(first *command-line-args*)
```

### with-open

```racket
(with-open [name expr ...] body ...)
```

Binds resources, evaluates body, then closes all bindings (via
`java.io.Closeable`).

```racket
(with-open [rdr (clojure.java.io/reader "data.csv")]
  (doall (line-seq rdr)))                           
```

### doto

```racket
(doto target forms ...)
```

Evaluates `target`, threads it as first argument through each form,
returns the original target. Used for Java mutation chains.

```racket
(doto (java.util.HashMap.)
  (.put "a" 1)            
  (.put "b" 2))           
```

### import

```racket
(import Fully.Qualified.Class)
```

Emits `(:import [package ClassName])` in the generated ns form.

```racket
(import java.io.File)     
(import java.time.Instant)
```

### declare-extern

```racket
(declare-extern name TypeExpr)
```

Declares the type of a function not available via beagle source import.
**Only needed for** Java interop and non-beagle Clojure namespaces.
**Not needed for** cross-module beagle calls.

```racket
(declare-extern .getAbsolutePath [Any -> String])     
(declare-extern System/getProperty [String -> String])
```

### Vector Literals

```racket
[1 2 3]                                        
[(->Employee "Alice" 95) (->Employee "Bob" 80)]
```

Element types are inferred: `[(->Product 1 "A") ...]` gives `(Vec
Product)`.

### Map Literals

```racket
{:name "Tom" :age 30}
```

### Set Literals

```racket
#{1 2 3}   
#{:a :b :c}
```

### Keyword-as-Function

```racket
(:key target)
```

Keyword lookup. If `target` is a typed record, the checker infers the
field type.

```racket
(:key target default)
```

Keyword lookup with a default value.

```racket
(:name person)          ; String if person is typed record
(:age config "unknown") ; with default                    
```

### Regex Literals

`#"pattern"` — Clojure regex literal, emitted verbatim.

### Metadata

```racket
(^ map target)
```

Attaches Clojure metadata to the following form. `^:keyword` is sugar
for `^{:keyword true}`.

```racket
^{:key (str prefix "-" idx)} [item-view item]
^:private (def internal-state (atom {}))     
```

### Quote

Standard Lisp quoting. Quoted forms are not evaluated.

```racket
'(a b c)    ; quoted list  
'foo        ; quoted symbol
```

### unsafe

```racket
(unsafe "raw-clojure-source")
```

Emits the literal string verbatim into the Clojure output. Works at
top-level and in expression position. Typed as `Any`. Use sparingly —
this is the escape hatch for Clojure features beagle doesn’t cover.

```racket
(unsafe "(defn helper [x] (some-clj-thing x))")
```

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
resolution works identically.

## SQL target (`#lang beagle/sql`)

File extension: `.bsql`. Use `#lang beagle/sql`.

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

## Macros

Beagle has two macro systems: ​_template macros_​ for simple
substitution and ​_procedural macros_​ for computed code generation.
Both produce forms that go through the full type-checking pipeline.

**When to use which:** Template macro for fixed-shape substitution.
Procedural macro to iterate over data, compute names, or generate
multiple typed forms. Plain functions when runtime dispatch suffices —
proc macros are for when generated code must go through the type
checker.

### Template Macros

The `safe`/`unsafe` distinction controls whether expanded code is
re-validated by the type checker.

### define-macro

```racket
(define-macro safe name (params) template)
```

Defines a macro whose expansion is type-checked normally.

```racket
(define-macro unsafe name (params) template)
```

Defines a macro whose expansion is typed as `Any` (escape boundary).

```racket
(define-macro safe inc1 (x)            
  (+ x 1))                             
                                       
(define-macro safe call-with (f & args)
  (f (splice args)))                   
                                       
(define-macro unsafe debug-call (form) 
  (do (println "trace") form))         
```

* `safe`: expansion re-validated by type checker

* `unsafe`: expansion’s result type widened to `Any`

* `& rest-name` in params: collects remaining args into a list

* `(splice rest-name)` in template: inlines the list at that position

* `safe` macros use gensym-hygienic substitution; `unsafe` macros use
  naive substitution

### Procedural Macros

### define-macro beagle (recommended)

```racket
(define-macro beagle name        
[(param : Type) ...] : ReturnType
body)                            
```

Beagle-native macro body evaluated at compile time. The body is Beagle
code using syntax constructors — no Racket, no `car`/`cdr`/`quasiquote`.

Contract types: `Symbol`, `String`, `Int`, `Bool`, `Keyword`, `Expr`,
`Form`, `Syntax` (any), `(Vec T)`. Return `Form` for one top-level form,
`(Vec Form)` for multiple (spliced).

```racket
(define-macro beagle defentity                                     
  [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)           
  (let [record (make-defrecord name                                
                 (map (fn [(f : Syntax)]                           
                   (make-field (syntax-name f) (syntax-type f)))   
                   fields))                                        
        getters (map (fn [(f : Syntax)]                            
                   (make-defn                                      
                     (format-symbol "~a-~a" name (syntax-name f))  
                     (list (make-param 'r name))                   
                     (syntax-type f)                               
                     (make-get 'r (make-keyword (syntax-name f)))))
                  fields)]                                         
    (cons record getters)))                                        
                                                                   
(defentity User ((name : String) (email : String) (age : Int)))    
;; → defrecord User + typed getters User-name, User-email, User-age
```

Syntax constructors:

* `make-defrecord name fields` — `(defrecord Name ((f : T) ...))`

* `make-defn name params ret-type body` — `(defn name (params) : T
  body)`

* `make-param name type` — `(name : Type)`

* `make-field name type` — `(name : Type)`

* `make-get target field` — `(get target field)`

* `make-keyword sym` — `:sym`

* `format-symbol fmt args...` — builds a symbol from format string

* `syntax-name s` — first element of a `(name : Type)` syntax triple

* `syntax-type s` — type element of a `(name : Type)` syntax triple

Built-ins available in macro bodies: `let`, `fn`, `if`, `cond`, `map`,
`filter`, `cons`, `list`, `append`, `first`, `rest`, `str`, `format`,
`string->symbol`, `symbol->string`, `=`, `not`, `+`, `-`.

### define-macro proc (legacy)

```racket
(define-macro proc name          
[(param : Type) ...] : ReturnType
body)                            
```

Compile-time Racket function with typed AST contracts. Same contract
system as `define-macro beagle`, but the body is raw Racket
(`car`/`cdr`/quasiquote). Use `define-macro beagle` for new macros.

* Body has `racket/base`, `racket/list`, `racket/string`,
  `racket/format`, and `sym->kw` (symbol→keyword)

* Inputs are auto-cleaned: reader tags stripped before the body sees
  them — `(Vec Syntax)` args arrive as plain lists

* Output goes through the full parse → check → emit pipeline

* `beagle-expand` shows what the macro produces

## Tools

### Unified CLI

The `beagle` command wraps all common operations:

* `beagle check .` — batch type-check all files

* `beagle build . –out DIR` — batch compile to Clojure

* `beagle fix –dry-run|–apply .` — auto-fix type errors

* `beagle sig FN .` — query function signature

* `beagle lsp` — LSP server (stdio transport)

* `beagle repl` — typed REPL with persistent environment

* `beagle init` — bootstrap a new beagle project

### Reactive Daemon

The daemon caches ASTs and watches files for changes, providing
near-instant re-checking on every save:

* `beagle-daemon start –watch DIR` — file watcher, re-checks on every
  save (~100ms)

* `beagle-daemon query check-enriched DIR` — synchronous type check +
  enriched context

* `beagle-daemon query check-result FILE` — cached result (instant)

### Query Tools

Query tools expose the type system as an API. Instead of reading source
to understand a codebase, ask the type system directly:

* `beagle-sig FN FILE-OR-DIR` — function’s type signature

* `beagle-fields RECORD FILE-OR-DIR` — record fields + accessors

* `beagle-callers FN FILE-OR-DIR` — find all call sites

* `beagle-provides FILE-OR-DIR` — list module exports with types

* `beagle-impact FN FILE-OR-DIR` — callers + impact of signature change

### MCP Server

Exposes beagle’s type system as tools over the Model Context Protocol,
so any MCP-compatible agent gets type-aware code intelligence:

`beagle mcp`

Tools: `beagle_sig`, `beagle_fields`, `beagle_callers`,
`beagle_provides`, `beagle_impact`, `beagle_check`,
`beagle_check_enriched`, `beagle_build`, `beagle_expand`. Delegates to a
running daemon for speed; falls back to direct CLI invocation.

Requires the `mcp` Python package (`pip install mcp`).

### Repair Toolchain

Automated bug-finding and fixing tools that use oracle-based behavioral
comparison, tracing, and cross-evidence correlation:

* `beagle-repair SOURCE VERIFY [–auto] [–emit-patch]` — unified repair
  pipeline with cross-evidence correlation

* `beagle-trace BUILD VERIFY [–focus FN]` — instrumented tracing

* `beagle-specfix BUILD VERIFY` — oracle-guided speculative fix

* `beagle-cascade SOURCE VERIFY –from-failures` — root-cause analysis

* `beagle-blame BUILD VERIFY` — ratio-based fault hints

* `beagle-oracle GOLDEN [–diff MODIFIED]` — behavioral oracle synthesis

* `beagle-proptest SOURCE [–run] [–diff DIR]` — property + differential
  testing

### Other Tools

Individual tools for specific tasks, including batch compilation, syntax
checking, mutation testing, and distributed tracing:

* `beagle-build SOURCE.rkt [OUT.clj]` — single-file compile

* `beagle-build-all FILES [–out DIR]` — batch compile (9x vs sequential)

* `beagle-check SOURCE.rkt` — single-file type check

* `beagle-check-all FILES` — batch type check (10x vs sequential)

* `beagle-expand SOURCE.rkt` — show post-macro expansion

* `beagle-syntax FILES` — fast paren/bracket balance check (<200ms)

* `beagle-verify-enriched BUILD VERIFY` — verify + auto-diagnose

* `beagle-muttest BUILD VERIFY` — mutation testing

* `beagle-dtrace instrument|collect|view|blame|graph|cascade` —
  distributed tracing

* `beagle-smap extract|compose` — source map generation

* `beagle-docs-sync` — propagate mechanical facts across docs

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

## Empirical baseline

3 syntactic variants tested (A canonical, B required-types, C minimal),
multiple LLM samples per task, real Clojure behavior verification. 100%
behavior pass after empirically-driven bug fixes. See `experiments/report.md`.
