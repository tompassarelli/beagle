#lang racket/base

;; A template constructs a typed binding dynamically, with no string surgery.
;; Two construction paths are covered: direct structural syntax and `ann`.

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

;; --- (1) structural template spelling ---------------------------------------

(define TEMPLATE-SRC
  (string-append
   "(defmacro deftyped [name type value]\n"
   "  `(defn ~name [] ~type ~value))\n"
   "(deftyped answer Int 42)\n"))

(test-case "template `[(~name ~type)] reads as one structural binding"
  (check-equal? (beagle-read (open-input-string "`[(~name ~type)]"))
                (list 'quasiquote
                      (list '#%brackets
                            (list (list 'unquote 'name) (list 'unquote 'type))))))

(test-case "a macro builds a typed defn from dynamic name + type"
  (define p (parse-src TEMPLATE-SRC))
  (define f (car (program-forms p)))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'answer)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

(define PARAM-TEMPLATE-SRC
  (string-append
   "(defmacro defid [name type]\n"
   "  `(defn ~name [(x ~type)] ~type x))\n"
   "(defid ident Int)\n"))

(test-case "a template param vector carries an annotation and type-checks + emits"
  (define out (check+emit PARAM-TEMPLATE-SRC))
  (check-true (string-contains? out "ident") out)
  (define f (car (program-forms (parse-src PARAM-TEMPLATE-SRC))))
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int))

;; HYGIENE: gensym-renaming must touch the binder only, never the type name.
(test-case "template param hygiene renames the binder, not the type"
  (define src
    (string-append
     "(defmacro mk [] `(defn h [(x Int)] Int x))\n"
     "(mk)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (define p0 (car (defn-form-params f)))
  (check-eq? (type-prim-name (param-type p0)) 'Int
             "the TYPE datum must survive hygiene unrenamed")
  (check-eq? (type-prim-name (defn-form-return-type f)) 'Int)
  (check-equal? (length (defn-form-params f)) 1))

(test-case "template hygiene recursively renames typed destructuring binders"
  (define src
    (string-append
     "(defrecord Config [(host String) (port Int)])\n"
     "(defmacro mk []\n"
     "  `(defn connect [([[left right] {:keys [host port] :as cfg}]\n"
     "                   (HVec (HVec Int Int) Config))]\n"
     "     String\n"
     "     host))\n"
     "(mk)\n"))
  (define f (cadr (program-forms (parse-src src))))
  (define target (param-name (car (defn-form-params f))))
  (define nested-seq (car (seq-destructure-names target)))
  (define nested-map (cadr (seq-destructure-names target)))
  (define left-name (car (seq-destructure-names nested-seq)))
  (define host-name (car (map-destructure-keys nested-map)))
  (check-false (eq? left-name 'left))
  (check-false (eq? host-name 'host))
  (check-false (eq? (map-destructure-as-name nested-map) 'cfg))
  (check-eq? (type-app-ctor (param-type (car (defn-form-params f)))) 'HVec))

;; --- (2) canonical constructor: ann in a procedural defmacro ----------------

(define ANN-CTOR-SRC
  (string-append
   "(defmacro mk-field [name ty]\n"
   "  (list 'defn name (vec) ty 0))\n"
   "(mk-field zero Int)\n"))

(test-case "defmacro exposes the typed-binding constructor"
  (define src
    (string-append
     "(defmacro mk-id [name ty]\n"
     "  (list 'defn name (vec (ann 'x ty)) ty 'x))\n"
     "(mk-id ident2 Int)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'ident2)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int))

(test-case "the `ann` helper composes inside a generated parameter vector"
  (define src
    (string-append
     "(defmacro mk-id3 [name ty]\n"
     "  (list 'defn name (vec (ann 'x ty)) ty 'x))\n"
     "(mk-id3 ident3 Int)\n"))
  (define f (car (program-forms (parse-src src))))
  (check-true (defn-form? f))
  (check-eq? (defn-form-name f) 'ident3)
  (check-eq? (type-prim-name (param-type (car (defn-form-params f)))) 'Int)
  (check-eq? (param-name (car (defn-form-params f))) 'x))

(test-case "Racket-side `ann` is exported and matches structural source"
  (check-equal? (ann 'x 'Int) '(x Int))
  (check-equal? (ann 'x 'Int)
                (cadr (beagle-read (open-input-string "[(x Int)]")))))

(test-case "a constructor-built defn type-checks AND emits"
  (define out (check+emit ANN-CTOR-SRC))
  (check-true (string-contains? out "zero") out))
