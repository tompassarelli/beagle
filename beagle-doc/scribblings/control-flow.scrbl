#lang scribble/manual

@title[#:tag "control-flow"]{Control Flow}

@section[#:tag "if"]{if}

@defform[(if cond then else)]{
Conditional. Type narrows in branches when condition uses @tt{nil?}, @tt{some?}, etc.

@codeblock|{
(if (> x 0) "positive" "non-positive")
}|}

@defform[#:id if-no-else (if cond then)]{
Without else branch, returns @tt{Nil} when condition is false.}

@section[#:tag "if-not"]{if-not}

@defform[(if-not cond then else)]{
Inverted conditional. Expands to @tt{(if (not cond) then else)}.

@codeblock|{
(if-not (authorized? user) "denied" "allowed")
}|}

@section[#:tag "cond"]{cond}

@defform[(cond [test body ...] ...)]{
Multi-branch conditional (bracketed style).

@codeblock|{
(cond
  [(< n 0) "negative"]
  [(= n 0) "zero"]
  [(> n 0) "positive"])
}|}

Also supports flat Clojure-style: @tt{(cond test1 body1 test2 body2 :else fallback)}.

@section[#:tag "condp"]{condp}

@defform[(condp pred test value result ... default)]{
Predicate-based dispatch. Tests @tt{(pred value test)} for each clause.
An odd trailing form is the default.

@codeblock|{
(condp = color
  :red   "stop"
  :green "go"
  "unknown")
}|}

@section[#:tag "when"]{when}

@defform[(when cond body ...)]{
Evaluates body when condition is truthy. Returns @tt{Nil} otherwise.

@codeblock|{
(when (> x 0)
  (println "positive")
  x)
}|}

@section[#:tag "when-not"]{when-not}

@defform[(when-not cond body ...)]{
Evaluates body when condition is falsy. Expands to @tt{(when (not cond) body...)}.

@codeblock|{
(when-not (empty? items)
  (process items))
}|}

@section[#:tag "when-let"]{when-let}

@defform[(when-let [name expr] body ...)]{
Binds @racket[name] to the result of @racket[expr]; evaluates body if truthy.

@codeblock|{
(when-let [user (find-user id)]
  (println (user-name user)))
}|}

@section[#:tag "if-let"]{if-let}

@defform[(if-let [name expr] then else)]{
Binds @racket[name] to the result of @racket[expr]. If truthy, evaluates
@racket[then] with the binding in scope. Otherwise evaluates @racket[else].

@codeblock|{
(if-let [user (find-user id)]
  (user-name user)
  "anonymous")
}|}

@section[#:tag "when-some"]{when-some / if-some}

@defform[(when-some [name expr] body ...)]{
Like @tt{when-let} but tests for non-nil (not truthiness). @tt{false} passes.

@codeblock|{
(when-some [val (get config :debug)]
  (enable-debugging val))
}|}

@defform[(if-some [name expr] then else)]{
Like @tt{if-let} but tests for non-nil.

@codeblock|{
(if-some [port (get config :port)]
  (start-server port)
  (start-server 8080))
}|}

@section[#:tag "case"]{case}

@defform[(case test value result ... default)]{
Constant-time dispatch. An odd trailing form is the default.

@codeblock|{
(case color
  :red   "stop"
  :green "go"
  "unknown")
}|}

@section[#:tag "match"]{match}

@defform[(match expr [pattern body ...] ...)]{
Pattern matching with type narrowing.

Patterns:
@itemlist[
  @item{@tt{(RecordName b1 b2 ...)} --- type test + positional field destructuring}
  @item{@tt|{{:key1 pat1 :key2 pat2}}| --- map pattern}
  @item{@tt{nil}, @tt{"str"}, @tt{42} --- literals}
  @item{@tt{name} --- bind to variable}
  @item{@tt{_} --- wildcard}
]

@codeblock|{
(defrecord Circle [(radius : Float)])
(defrecord Rect [(width : Float) (height : Float)])

(match shape
  [(Circle r) (* 3.14159 r r)]
  [(Rect w h) (* w h)]
  [_ 0.0])
}|}

@section[#:tag "try"]{try / catch / finally}

@defform[(try body ... (catch ExType name handler ...) (finally cleanup ...))]{
Exception handling. Multiple @tt{catch} clauses allowed. @tt{finally} is optional.

@codeblock|{
(try
  (Long/parseLong s)
  (catch Exception e
    (println (.getMessage e))
    -1)
  (finally
    (println "done")))
}|}

@section[#:tag "do"]{do}

@defform[(do body ...)]{
Sequences expressions; returns the last value. Used where a single expression
is expected but multiple side effects are needed.

@codeblock|{
(do
  (println "saving...")
  (save-record! rec)
  (println "done")
  rec)
}|}

@section[#:tag "comment"]{comment}

@defform[(comment forms ...)]{
Ignores all forms and returns @tt{nil}. Used for development-time scratch
code and inline examples. The forms are not evaluated or type-checked.

@codeblock|{
(comment
  (start-server 8080)
  (run-tests)
  (println "scratch area"))
}|}
