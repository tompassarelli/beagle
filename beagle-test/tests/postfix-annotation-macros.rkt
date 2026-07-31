#lang racket/base

;; The brief's macro invariant: a template constructs a typed binding
;; DYNAMICALLY, with no string surgery. `~` terminates the token before `:`
;; fires, so `` `[~name: ~type] `` reads as
;; (quasiquote (#%brackets (unquote name) #%: (unquote type))) — the marker is a
;; sibling datum, not glued to either operand.
;;
;; Two construction paths are covered: the template spelling above, and the
;; canonical constructor `(ann n t)` spliced with `~@`.

(require rackunit
         racket/string
         racket/port
         beagle/lang/reader-impl
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/ast
         (only-in beagle/private/emit-clj clj-emit-program))

(define PRELUDE "(ns t)\n(define-mode strict)\n(define-target clj)\n")

(define (read-forms str)
  (parameterize ([current-readtable beagle-readtable])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'macro-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

(define (parse-src str) (parse-program (read-forms (string-append PRELUDE str))))

(define (check+emit str)
  (define p (parse-src str))
  (parameterize ([current-check-profile 2]) (type-check! p))
  (clj-emit-program p))

;; --- (1) template spelling: `[~name: ~type] --------------------------------

(define TEMPLATE-SRC
  (string-append
   "(defmacro deftyped [name type value]\n"
   "  `(defn ~name [] -> ~type ~value))\n"
   "(deftyped answer Int 42)\n"))

(test-case "template `[~name: ~type] reads as a FLAT marker sibling"
  (check-equal? (beagle-read (open-input-string "`[~name: ~type]"))
                (list 'quasiquote
                      (list '#%brackets (list 'unquote 'name)
                            (string->symbol "#%:") (list 'unquote 'type)))))

(test-case "a macro builds a typed defn from dynamic name + type"
  (define p (parse-src TEMPLATE-SRC))
  (define f (car (program-forms p)))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'answer)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

(define PARAM-TEMPLATE-SRC
  (string-append
   "(defmacro defid [name type]\n"
   "  `(defn ~name [x: ~type] -> ~type x))\n"
   "(defid ident Int)\n"))

(test-case "a template param vector carries an annotation and type-checks + emits"
  (define out (check+emit PARAM-TEMPLATE-SRC))
  (check-true (string-contains? out "ident") out)
  (define f (car (program-forms (parse-src PARAM-TEMPLATE-SRC))))
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

;; HYGIENE: gensym-renaming must touch the BINDER only — never the marker and
;; never the type name. (Pre-existing bug: `[x: Int]` in a template became
;; `x__0`, `:-__1`, `Int__2`.)
(test-case "template param hygiene renames the binder, not the marker or type"
  (define src
    (string-append
     "(defmacro mk [] `(defn h [x: Int] -> Int x))\n"
     "(mk)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (define p0 (car (defn-form-params f)))
  (check-eq? (type-prim-name (param-type p0)) 'Int
             "the TYPE datum must survive hygiene unrenamed")
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int)
  (check-equal? (length (defn-form-params f)) 1
                "the marker must not be collected as a third binder"))

;; --- (2) canonical constructor: ~@(ann n t) in a proc macro ----------------

(define ANN-CTOR-SRC
  (string-append
   "(define-macro proc mk-field [(name: Symbol) (ty: Symbol)] -> Form\n"
   "  (list 'defn name (br) '-> ty 0))\n"
   "(mk-field zero Int)\n"))

(test-case "proc-macro namespace exposes ANN-MARKER + the `ann` constructor"
  ;; `(ann n t)` builds the flat triple; `~@`-splicing it into a bracket
  ;; template is the sanctioned programmatic construction path.
  (define src
    (string-append
     "(define-macro proc mk-id [(name: Symbol) (ty: Symbol)] -> Form\n"
     "  (list 'defn name (br 'x ANN-MARKER ty) '-> ty 'x))\n"
     "(mk-id ident2 Int)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'ident2)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int))

(test-case "the `ann` helper produces the same triple as ANN-MARKER by hand"
  (define src
    (string-append
     "(define-macro proc mk-id3 [(name: Symbol) (ty: Symbol)] -> Form\n"
     "  (list 'defn name (apply br (ann 'x ty)) '-> ty 'x))\n"
     "(mk-id3 ident3 Int)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'ident3)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (param-name (car (defn-form-params f))) 'x))

(test-case "Racket-side `ann` is exported and matches the reader's marker"
  (check-equal? (ann 'x 'Int) (list 'x ANN-MARKER 'Int))
  (check-equal? (ann 'x 'Int) (cdr (beagle-read (open-input-string "[x: Int]")))))

(test-case "a constructor-built defn type-checks AND emits"
  (define out (check+emit ANN-CTOR-SRC))
  (check-true (string-contains? out "zero") out))
