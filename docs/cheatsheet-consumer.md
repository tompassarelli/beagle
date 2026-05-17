# beagle — language reference (consumer)

Beagle is a typed language that compiles to Clojure. This reference covers
everything needed to write beagle code. Errors are caught at compile time.

## File header

```racket
#lang beagle

(ns my.namespace)
(define-mode strict)                   ; default; or `dynamic` to skip checks
(require other.module :as mod)         ; imports all types/fns from beagle module
(declare-extern fn-name [Args -> Ret]) ; ONLY for Java interop / non-beagle fns
(import java.io.File)                  ; Java class import
```

`(require module :as alias)` imports everything — types, records, functions,
macros. You do NOT need `declare-extern` for cross-module beagle calls.

## Definitions

```racket
(def NAME VALUE)
(def NAME : Type VALUE)

(defn NAME [PARAMS] BODY ...)
(defn NAME [PARAMS] : ReturnType BODY ...)

(defrecord Name [(field1 : Type) (field2 : Type)])

(defscalar Amount Long)                ; nominal type (Amount ≠ Long at compile time)

(defenum Status :active :inactive)     ; enum value set
```

### Records

```racket
(defrecord Employee [(name : String) (rate : Long)])
```

Generates:
- Constructor: `(->Employee "Alice" 95)` — typed `[String Long -> Employee]`
- Accessors: `(employee-name e)`, `(employee-rate e)`
- Keyword access: `(:name e)` returns `String` when `e` is `Employee`
- Update: `(with e [:rate 100])` — compile-time field + type validation

## Expressions

```racket
(if cond then else)
(cond [test1 body1] [test2 body2] [true fallback])
(when cond body...)
(do body1 body2 ... bodyN)
(let [name1 value1 name2 value2 ...] body...)
(loop [name1 init1 ...] body...)
(recur arg1 arg2 ...)
(for [x coll :when pred] body...)      ; returns (Vec BodyType)
(doseq [x coll] body...)              ; side-effecting, returns nil
(fn [PARAMS] body...)
(try body... (catch ExType e handler...) (finally cleanup...))
(case test val1 result1 val2 result2 default)
(match expr [pattern body...] ...)
(-> x (f) (g))                        ; thread-first
(->> x (f) (g))                       ; thread-last
(:key map)                            ; keyword lookup
[item1 item2 ...]                     ; vector literal
{k1 v1 k2 v2}                        ; map literal
#{item1 item2}                        ; set literal
(unsafe "raw clojure")                ; escape hatch (typed Any)
```

## Parameters

```racket
[(x : Long) (y : String)]             ; typed (canonical form)
[x y z]                               ; untyped
[{:keys [name age]}]                  ; map destructuring
[{:keys [x y] :as point}]            ; destructure + bind whole
[[a b & rest]]                        ; sequential destructuring
```

## Types

| Type | Matches |
|------|---------|
| `String` | strings |
| `Long` | integers |
| `Double` | floats |
| `Boolean` | true/false |
| `Keyword` | `:foo` |
| `Nil` | `nil` |
| `Any` | anything (escape) |

```
[A B -> R]            ; function type
[A & T -> R]          ; variadic
(Vec T)               ; vector of T
(Map K V)             ; map
(Set T)               ; set
(U String Long)       ; union
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

## Build & check

```bash
beagle check .                         # type-check all files
beagle build . --out .build/           # compile to Clojure
beagle fix --dry-run .                 # preview auto-fixes
beagle fix --apply .                   # apply auto-fixes
beagle sig fn-name .                   # query function signature
beagle fields RecordName .             # query record fields
```
