#lang scribble/manual

@title[#:tag "types"]{Types}

@section{Primitives}

@tabular[#:sep @hspace[2]
  (list (list @bold{Type} @bold{Matches})
        (list @tt{String}  "strings")
        (list @tt{Int}     "integers")
        (list @tt{Float}   "floats")
        (list @tt{Bool}    "true/false")
        (list @tt{Keyword} ":foo style keywords")
        (list @tt{Symbol}  "quoted symbols")
        (list @tt{Nil}     "nil")
        (list @tt{Any}     "anything (escape hatch)")
        (list @tt{Number}  "(U Int Float) — prefer Int or Float when known"))]

One canonical name per type. JVM names (@tt{Long}, @tt{Double}, @tt{Boolean})
are accepted as compatibility sugar in @tt{#lang beagle/clj} but resolve to
the canonical names above.

@section{Function Types}

@itemlist[
  @item{@tt{[A B -> R]} --- fixed-arity function taking @tt{A} and @tt{B}, returning @tt{R}}
  @item{@tt{[A & T -> R]} --- variadic: one @tt{A} then zero or more @tt{T} args}
  @item{@tt{[-> R]} --- nullary function}
]

@section{Parametric Types}

@itemlist[
  @item{@tt{(Vec T)} --- vector of @tt{T}}
  @item{@tt{(List T)} --- list of @tt{T}}
  @item{@tt{(Set T)} --- set of @tt{T}}
  @item{@tt{(Map K V)} --- map from @tt{K} to @tt{V}}
  @item{@tt{(Promise T)} --- promise resolving to @tt{T}}
]

@section{Union Types}

@tt{(U A B C)} --- value is one of the alternatives.

@section{Nullable Sugar}

@tt{String?} is shorthand for @tt{(U String Nil)}. Works with any type:
@tt{Product?} means @tt{(U Product Nil)}.

@section{Type Narrowing}

Flow-sensitive narrowing in @tt{if}/@tt{cond}/@tt{when} via predicates
like @tt{nil?}, @tt{some?}, @tt{string?}, @tt{=}, @tt{not}.

@codeblock|{
(defn safe-name [(x : String?)] : String
  (if (nil? x) "unknown" x))   ; x is narrowed to String in the then branch
}|

@section{Polymorphic Types}

@tt{(forall [A] [A -> A])} introduces type variables for generic functions.

@subsection{Bounded Polymorphism}

Type variables can be constrained with upper bounds using @tt{<:}:

@codeblock|{
(forall [(T <: HasName)] [T -> String])
(forall [(T <: (U Circle Rectangle))] [T -> Float])
}|

Without bounds, @tt{T} accepts anything. With @tt{<:}, the checker verifies
the inferred type satisfies the bound.

@section{Let Binding Inference}

Let bindings infer types automatically from the right-hand side:

@codeblock|{
(let [x (get-product id)] ...)     ; x : Product (inferred)
(let [{:keys [name]} product] ...) ; name : String (from record fields)
}|

Explicit annotations are only needed when narrowing:

@codeblock|{
(let [(area : Int) (* w h)] area)
}|

@section{Collection Type Inference}

Collection literals infer element types from their contents:

@codeblock|{
[(->Product 1 "A") (->Product 2 "B")]  ; (Vec Product), not (Vec Any)
{:a 1 :b 2}                             ; (Map Keyword Int)
#{:x :y :z}                             ; (Set Keyword)
}|
