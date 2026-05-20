# Type system reference

## Primitives

`String`, `Int`, `Float`, `Bool`, `Keyword`, `Symbol`, `Nil`, `Any`

`Number` is a built-in alias for `(U Int Float)`.

## Function types

```
[A -> R]           ;; one arg
[A B -> R]         ;; two args
[A B & T -> R]     ;; variadic: two fixed + rest of type T
[-> R]             ;; nullary
```

## Parametric types

```
(Vec T)            ;; vector of T
(List T)           ;; linked list of T
(Set T)            ;; set of T
(Map K V)          ;; map from K to V
(Promise T)        ;; JS promise of T
```

## Union types

```
(U String Int)     ;; either String or Int
String?            ;; sugar for (U String Nil) — nullable
```

## Polymorphism

```racket
;; Unbounded
(forall [T] [T -> T])

;; Bounded
(forall [(T <: Number)] [T -> T])
```

## User-defined types

```racket
;; Records (product types)
(defrecord Point [(x : Float) (y : Float)])

;; Tagged unions (sum types)
(defunion Shape
  (Circle [(radius : Float)])
  (Square [(side : Float)]))

;; Parametric unions
(defunion (Result T E)
  (Ok [(value : T)])
  (Err [(error : E)]))

;; Enums (keyword sets)
(defenum Status #{:active :inactive :pending})

;; Nominal scalars
(defscalar Percentage Int :where [(>= 0) (<= 100)])
```

## Type annotations

```racket
;; Definitions
(def name : String "Tom")
(defn greet [(name : String)] : String (str "Hi " name))

;; Let bindings
(let [(x : Int) 42] x)

;; Parameters — always wrapped
(name : String)    ;; not name : String (inline removed)
```

## Pattern matching

```racket
(match shape
  [(Circle r) (* 3.14 r r)]
  [(Square s) (* s s)])
```

Exhaustive matching on defunion is enforced — missing cases are hard errors.

## Flow-sensitive narrowing

```racket
(if (nil? x)
  "was nil"           ;; x : Nil here
  (str "got: " x))    ;; x : non-nil here
```

Predicates: `nil?`, `some?`, `string?`, `number?`, `integer?`, `keyword?`, `symbol?`, `boolean?`
