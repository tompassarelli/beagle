#lang scribble/manual

@title[#:tag "macros"]{Macros}

Beagle has two macro systems: @emph{template macros} for simple substitution
and @emph{procedural macros} for computed code generation. Both produce forms
that go through the full type-checking pipeline.

@section[#:tag "template-macros"]{Template Macros}

Template macros substitute parameters into a fixed template form.
The @tt{safe}/@tt{unsafe} distinction controls whether the expanded
code is re-validated by the type checker.

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

Procedural macros are compile-time functions that receive typed inputs and
return generated forms. Unlike template macros, they can iterate over data,
compute names, and produce variable numbers of output forms.

@section[#:tag "define-macro-proc"]{define-macro proc}

@defform[(define-macro proc name
  [(param : Type) ...] : ReturnType
  body)]{
Defines a procedural macro. The body is Racket code executed at compile time.
Inputs are contract-checked against their declared types before the body runs;
the output is checked against @tt{ReturnType} after.

Contract types: @tt{Symbol}, @tt{String}, @tt{Int}, @tt{Bool}, @tt{Keyword},
@tt{Expr} (single expression), @tt{Form} (top-level form), @tt{Syntax} (any datum),
@tt{(Vec T)} (list of T).

Return @tt{Form} for a single top-level form, or @tt{(Vec Form)} for multiple
forms (spliced into the module).

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
  @item{Body has access to @tt{racket/base}, @tt{racket/list}, @tt{racket/string},
        @tt{racket/format}, plus helpers: @tt{br} (bracket tag), @tt{mp} (map tag),
        @tt{st} (set tag), @tt{sym->kw} (symbol→keyword)}
  @item{Use quasiquote (@tt{`}) and unquote (@tt{,}) to build output forms}
  @item{@tt{(Vec Form)} output is spliced — each form becomes a separate top-level definition}
  @item{Input contracts reject bad arguments at expansion time with clear error messages}
  @item{Output goes through the full parse → check → emit pipeline (type-checked like hand-written code)}
  @item{Use @tt{beagle-expand} to inspect what a proc macro produces}
]}
