#lang scribble/manual

@title[#:tag "forms"]{Definitions}

Top-level definitions bind names for use throughout a module. Type
annotations are optional but recommended --- the checker infers types
from right-hand-side expressions when annotations are absent.

@section[#:tag "def"]{def}

@defform[#:id def-untyped (def name value)]{
Defines a top-level binding. The type is inferred from @racket[value].}

@defform[(def name : Type value)]{
Defines a typed top-level binding. Raises a compile-time error if the inferred
type of @racket[value] is not compatible with @racket[Type].

@codeblock|{
(def greeting : String "hello")
(def x 42)
}|}

@section[#:tag "defonce"]{defonce}

@defform[(defonce name value)]{
Like @tt{def} but only binds if @racket[name] is not already defined. Emits
Clojure's @tt{defonce}. Common for top-level state that should survive
namespace reloads.

@codeblock|{
(defonce db-conn : Any (create-connection config))
}|}

@section[#:tag "defn"]{defn}

@defform[#:id defn-untyped (defn name [params] body ...)]{
Defines a function with the given parameters and body. Parameters may be
bare names or typed with @tt{(name : Type)}.}

@defform[(defn name [params] : ReturnType body ...)]{
Defines a function with an explicit return type. The checker verifies
the body's inferred type is compatible.

@codeblock|{
(defn add [(x : Int) (y : Int)] : Int
  (+ x y))

(defn id [x] x)
}|}

@subsection[#:tag "defn-multi"]{Multi-Arity}

@defform[#:id defn-multi (defn name (clause ...) ...)]{
Multi-arity function. Each clause is @tt{([params] : ReturnType body ...)}.

@codeblock|{
(defn greet
  ([(name : String)] : String
    (str "Hello, " name))
  ([(name : String) (title : String)] : String
    (str "Hello, " title " " name)))
}|}

@section[#:tag "fn"]{fn (anonymous function)}

@defform[(fn [params] body ...)]{
Anonymous function.

@codeblock|{
(fn [(x : Int)] (+ x 1))
}|}

@section[#:tag "let"]{let}

@defform[(let [name value ...] body ...)]{
Local bindings. Types are inferred from right-hand-side expressions.
Explicit type annotations are optional and only needed when narrowing.

@codeblock|{
(let [x 1 y 2] (+ x y))

;; Explicit annotation only when narrowing:
(let [(area : Int) (* w h)] area)

;; Destructuring:
(let [{:keys [name age]} person] (str name " is " age))
(let [[x y & rest] coords] (+ x y))
}|}
