# beagle — language reference (consumer)

Beagle is a typed language that compiles to Clojure or JavaScript. This
reference covers everything needed to write beagle code. Errors are caught
at compile time.

## File header

```racket
#lang beagle

(ns my.namespace)
(define-mode strict)                   ; default; or `dynamic` to skip checks
(require other.module :as mod)         ; imports all types/fns from beagle module
(declare-extern fn-name [Args -> Ret]) ; ONLY for Java interop / non-beagle fns
(import java.io.File)                  ; Java class import
```

File extensions: `.bclj` (Clojure), `.bcljs` (CLJS), `.bjs` (JS), `.bnix` (Nix). Extension must match `#lang`.

`(require module :as alias)` imports everything — types, records, functions,
macros. You do NOT need `declare-extern` for cross-module beagle calls.

## Definitions

```racket
(def NAME VALUE)
(def NAME : Type VALUE)
(defonce NAME VALUE)                   ; only binds if not already defined

(defn NAME [PARAMS] BODY ...)
(defn NAME [PARAMS] : ReturnType BODY ...)

(defrecord Name [(field1 : Type) (field2 : Type)])

(defscalar Amount Int)                 ; nominal type (Amount ≠ Int at compile time)

(defenum Status :active :inactive)     ; enum value set
```

### Records

```racket
(defrecord Employee [(name : String) (rate : Int)])
```

Generates:
- Constructor: `(->Employee "Alice" 95)` — typed `[String Int -> Employee]`
- Accessors: `(employee-name e)`, `(employee-rate e)`
- Keyword access: `(:name e)` returns `String` when `e` is `Employee`
- Update: `(with e [:rate 100])` — compile-time field + type validation

## Expressions

```racket
(if cond then else)
(cond [test1 body1] [test2 body2] [true fallback])
(cond test1 body1 test2 body2 :else fallback)  ; flat (Clojure-style)
(when cond body...)
(when-not cond body...)               ; inverted when
(when-let [name expr] body...)        ; bind + truthy test
(if-let [name expr] then else)        ; bind + truthy branch
(when-some [name expr] body...)       ; bind + non-nil test
(if-some [name expr] then else)       ; bind + non-nil branch
(if-not cond then else)               ; inverted if
(do body1 body2 ... bodyN)
(let [name1 value1 name2 value2 ...] body...)
(loop [name1 init1 ...] body...)
(recur arg1 arg2 ...)
(for [x coll :when pred :let [y (f x)]] body...)  ; returns (Vec BodyType)
(doseq [x coll] body...)              ; side-effecting, returns nil
(dotimes [i n] body...)               ; counted iteration
(condp pred test v1 r1 default)       ; predicate dispatch
(comment forms...)                    ; returns nil
(fn [PARAMS] body...)
(try body... (catch ExType e handler...) (finally cleanup...))
(case test val1 result1 val2 result2 default)
(match expr [pattern body...] ...)
(-> x (f) (g))                        ; thread-first
(->> x (f) (g))                       ; thread-last
(cond-> x test (f) test (g))          ; conditional thread
(some-> x (f) (g))                    ; nil-safe thread
(as-> x $ (f $) (g $ 1))             ; named thread
(with-open [r (io/reader f)] body...) ; resource management
(doto target (.method args) ...)      ; Java mutation chain
^{:key val} form                      ; metadata
(:key map)                            ; keyword lookup
[item1 item2 ...]                     ; vector literal
{k1 v1 k2 v2}                        ; map literal
#{item1 item2}                        ; set literal
(unsafe "raw clojure")                ; escape hatch (typed Any)
```

## Parameters

```racket
[(x : Int) (y : String)]              ; typed (canonical form)
[x y z]                               ; untyped
[{:keys [name age]}]                  ; map destructuring
[{:keys [x y] :as point}]            ; destructure + bind whole
[[a b & rest]]                        ; sequential destructuring
```

## Types

| Type | Matches |
|------|---------|
| `String` | strings |
| `Int` | integers |
| `Float` | floats |
| `Bool` | true/false |
| `Keyword` | `:foo` |
| `Nil` | `nil` |
| `Any` | anything (escape) |

```
[A B -> R]            ; function type
[A & T -> R]          ; variadic
(Vec T)               ; vector of T
(Map K V)             ; map
(Set T)               ; set
(U String Int)        ; union
String?               ; nullable (= (U String Nil))
```

## Let bindings infer types

```racket
(let [x (get-product id)] ...)     ; x : Product (inferred from return type)
(let [{:keys [name]} product] ...) ; name : String (inferred from record fields)
```

Only annotate when narrowing: `(let [(x : Product) (find-product id)] ...)`.

## Pattern matching

```racket
(match expr
  [(RecordType f1 f2) body...]    ; type test + positional destructure
  [{:key1 p1} body...]            ; map pattern
  [nil body...]                   ; literal
  [var body...]                   ; bind
  [_ body...])                    ; wildcard
```

## Multi-arity

```racket
(defn greet
  ([(name : String)] : String (str "Hello, " name))
  ([(name : String) (title : String)] : String (str "Hello, " title " " name)))
```

## What the checker catches

- Wrong type passed to function or constructor
- Wrong number of arguments (reports available arities)
- Wrong record field in `with` update
- Collection element type mismatches (`(Vec Product)` vs `(Vec Customer)`)
- Destructured field type mismatches
- Nullable return when non-nullable declared
- Undefined function references
- Cross-module contract violations

## JavaScript target

Use `#lang beagle/js` (file extension `.bjs`). Forms emit JS: `defn` →
`function`, `def` → `const`, `fn` → arrow, `defrecord` → `Object.freeze`,
`nil` → `null`. Async support: `(await expr)` with `(Promise T)` type;
functions containing `await` are auto-async. Identifiers mangled: `-` → `_`,
`?` → `_p`, `!` → `_bang`. All type checking works identically.

## Build & check

```bash
beagle-daemon start --watch .          # reactive: re-checks on every file save
beagle fix --apply .                   # auto-fix mechanical type errors
beagle check .                         # type-check all files (manual; daemon does this automatically)
beagle build . --out .build/           # compile to Clojure
beagle sig fn-name .                   # query function signature
beagle fields RecordName .             # query record fields
beagle-verify-enriched .build/ VERIFY  # verify + auto-diagnose failures
```
