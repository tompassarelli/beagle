#lang scribble/manual

@title[#:tag "iteration"]{Iteration and Comprehensions}

Beagle supports Clojure's full iteration toolkit: list comprehensions,
side-effecting loops, counted iteration, and tail-recursive @tt{loop}/@tt{recur}.

@section[#:tag "for"]{for}

@defform[(for [name coll ... :when pred :let [name val ...]] body ...)]{
List comprehension. Binds each name to successive values from its collection.
Optional @tt{:when} clauses filter, @tt{:let} clauses bind intermediate
values. Destructuring works in bindings.

Returns @tt{(Vec BodyType)}.

@codeblock|{
(for [x (range 5) y (range x) :when (even? y)]
  [x y])

;; with :let
(for [item items :let [price (item-price item) tax (* price 0.1)]]
  (+ price tax))

;; with destructuring
(for [[eid name email] contacts]
  (->Contact eid name email))
}|}

@section[#:tag "doseq"]{doseq}

@defform[(doseq [name coll ...] body ...)]{
Side-effecting iteration. Same binding syntax as @tt{for} (multiple bindings,
@tt{:when} and @tt{:let} clauses). Returns @tt{nil}.

@codeblock|{
(doseq [x items :when (pos? x)]
  (println x))
}|}

@section[#:tag "dotimes"]{dotimes}

@defform[(dotimes [name count] body ...)]{
Counted iteration. Binds @racket[name] to @tt{0}, @tt{1}, ..., @tt{count-1}.
The binding is typed as @tt{Int}. Returns @tt{nil}.

@codeblock|{
(dotimes [i 10]
  (println (str "iteration " i)))
}|}

@section[#:tag "loop"]{loop / recur}

@defform[(loop [name init ...] body ...)]{
Tail-recursive loop. Bindings work like @tt{let}; @tt{recur} jumps back
with new values.

@codeblock|{
(loop [acc 1 n 5]
  (if (<= n 1) acc (recur (* acc n) (dec n))))
}|}

@section[#:tag "threading"]{Threading Macros}

@defform[(-> value forms ...)]{Thread-first: inserts value as first argument.}
@defform[(->> value forms ...)]{Thread-last: inserts value as last argument.}
@defform[(cond-> value test form ...)]{Conditional thread-first.}
@defform[(cond->> value test form ...)]{Conditional thread-last.}
@defform[(some-> value forms ...)]{Nil-safe thread-first (short-circuits on nil).}
@defform[(some->> value forms ...)]{Nil-safe thread-last.}
@defform[(as-> value name forms ...)]{Named thread: binds @racket[name] to the
intermediate value at each step.

@codeblock|{
(-> person :name (str/upper-case))
(->> items (filter even?) (map inc) (reduce +))

(cond-> order
  paid?     (assoc :status :paid)
  shipped?  (assoc :status :shipped))

(some-> user :address :city)

(as-> data $ (map inc $) (filter even? $) (reduce + $))
}|}
