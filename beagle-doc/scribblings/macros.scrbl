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

@section[#:tag "define-macro-proc"]{define-macro proc}

@defform[(define-macro proc name
  [(param : Type) ...] : ReturnType
  body)]{
Compile-time Racket function with typed AST contracts. Inputs are
contract-checked before the body runs; output is checked after.

Contract types: @tt{Symbol}, @tt{String}, @tt{Int}, @tt{Bool}, @tt{Keyword},
@tt{Expr}, @tt{Form}, @tt{Syntax} (any), @tt{(Vec T)}.
Return @tt{Form} for one top-level form, @tt{(Vec Form)} for multiple (spliced).

@codeblock|{
;; Generate a typed record + N accessor functions from a field list
(define-macro proc defentity
  [(name : Symbol) (fields : (Vec Syntax))] : (Vec Form)
  (let ((rec-name name)
        (field-specs (map (lambda (f) (list (car f) ': (caddr f))) fields)))
    (cons
      `(defrecord ,rec-name ,field-specs)
      (map (lambda (f)
             (let ((fname (car f)) (ftype (caddr f)))
               `(defn ,(string->symbol (format "~a-~a" name fname))
                  ((r : ,rec-name)) : ,ftype
                  (get r ,(string->symbol (format ":~a" fname))))))
           fields))))

(defentity User ((name : String) (email : String) (age : Int)))
;; Expands to: defrecord User + get-name, get-email, get-age
}|

@itemlist[
  @item{Body has @tt{racket/base}, @tt{racket/list}, @tt{racket/string},
        @tt{racket/format}, and @tt{sym->kw} (symbol→keyword)}
  @item{Inputs are auto-cleaned: reader tags stripped before the body sees
        them — @tt{(Vec Syntax)} args arrive as plain lists}
  @item{Output goes through the full parse → check → emit pipeline}
  @item{@tt{beagle-expand} shows what the macro produces}
]}
