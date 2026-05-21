#lang scribble/manual

@title[#:tag "macros"]{Macros}

Beagle has two macro systems: @emph{template macros} for simple substitution
and @emph{procedural macros} for computed code generation. Both produce forms
that go through the full type-checking pipeline.

@bold{When to use which:} Template macro for fixed-shape substitution.
Procedural macro to iterate over data, compute names, or generate multiple
typed forms. Plain functions when runtime dispatch suffices — proc macros are
for when generated code must go through the type checker.

@section[#:tag "template-macros"]{Template Macros}

The @tt{safe}/@tt{unsafe} distinction controls whether expanded code is
re-validated by the type checker.

@section[#:tag "define-macro"]{define-macro}

@defform[(define-macro safe name (params) template)]{
Defines a macro whose expansion is type-checked normally.}

@defform[#:id define-macro-unsafe (define-macro unsafe name (params) template)]{
Defines a macro whose expansion is typed as @tt{Any} (escape boundary).

@codeblock|{
(define-macro safe inc1 (x)
  (+ x 1))

(define-macro safe call-with (f & args)
  (f (splice args)))

(define-macro unsafe debug-call (form)
  (do (println "trace") form))
}|

@itemlist[
  @item{@tt{safe}: expansion re-validated by type checker}
  @item{@tt{unsafe}: expansion's result type widened to @tt{Any}}
  @item{@tt{& rest-name} in params: collects remaining args into a list}
  @item{@tt{(splice rest-name)} in template: inlines the list at that position}
  @item{@tt{safe} macros use gensym-hygienic substitution; @tt{unsafe} macros
        use naive substitution}
]}

@section[#:tag "procedural-macros"]{Procedural Macros}

@section[#:tag "define-macro-beagle"]{define-macro beagle}

@defform[(define-macro beagle name
  [(param : Type) ...] : ReturnType
  body)]{
Beagle-native macro body evaluated at compile time. The body is Beagle code
using syntax constructors.

Contract types: @tt{Symbol}, @tt{String}, @tt{Int}, @tt{Bool}, @tt{Keyword},
@tt{Expr}, @tt{Form}, @tt{Syntax} (any), @tt{(Vec T)}.
Return @tt{Form} for one top-level form, @tt{(Vec Form)} for multiple (spliced).

@codeblock|{
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
}|

Syntax constructors:
@itemlist[
  @item{@tt{make-defrecord name fields} — @tt{(defrecord Name ((f : T) ...))}}
  @item{@tt{make-defn name params ret-type body} — @tt{(defn name (params) : T body)}}
  @item{@tt{make-param name type} — @tt{(name : Type)}}
  @item{@tt{make-field name type} — @tt{(name : Type)}}
  @item{@tt{make-get target field} — @tt{(get target field)}}
  @item{@tt{make-keyword sym} — @tt{:sym}}
  @item{@tt{format-symbol fmt args...} — builds a symbol from format string}
  @item{@tt{syntax-name s} — first element of a @tt{(name : Type)} syntax triple}
  @item{@tt{syntax-type s} — type element of a @tt{(name : Type)} syntax triple}
]

Built-ins available in macro bodies: @tt{let}, @tt{fn}, @tt{if}, @tt{cond},
@tt{map}, @tt{filter}, @tt{cons}, @tt{list}, @tt{append}, @tt{first},
@tt{rest}, @tt{str}, @tt{format}, @tt{string->symbol}, @tt{symbol->string},
@tt{=}, @tt{not}, @tt{+}, @tt{-}.
}

