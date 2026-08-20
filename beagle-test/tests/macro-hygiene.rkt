#lang racket/base

;; Hygiene-capture fixtures for `defmacro`.
;;
;; Macro identity is scope-set identity.  The invocation boundary flips one
;; fresh introduction scope on transformer input and output: generated syntax
;; keeps it, while exact antiquoted caller syntax returns to its original scope
;; set and object identity.  Binder/occurrence resolution is tested below at
;; the real parser/checker boundary.

(require rackunit
         racket/set
         beagle/private/parse
         beagle/private/ast-json
         beagle/private/macros
         beagle/private/tags
         (only-in beagle/private/ast
                  beagle-syntax-origin
                  beagle-syntax-scopes
                  beagle-syntax-span
                  datum->beagle-syntax
                  empty-scope-set
                  expansion-origin-call-span
                  expansion-origin-macro-id
                  expansion-origin-parent
                  fresh-scope-id
                  make-syntax-list
                  racket-syntax->beagle-syntax
                  reader-metadata
                  scope-set
                  scope-set-member?
                  scope-set-subset?
                  src-loc
                  structural-name-leaf
                  syntax-ident?
                  syntax-ident-name
                  syntax-list-children
                  syntax-vector-children))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (parse-source-text source-id source)
  (parse-program/bytes (string->bytes/utf-8 source)
                       #:source-path source-id
                       #:source-id source-id))

(define (br . xs) (cons BRACKET-TAG xs))

(test-case "typed macro rest binder registers one variadic name"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'collect 'defmacro '(label Any & body (Vec Any))
   '(quasiquote (list (unquote label) (unquote-splicing body))))
  (check-equal? (expand-fully reg '(collect first second third))
                '(list first second third)))

(test-case "typed macro rest binder rejects trailing parameters"
  (check-exn
   #rx"macro params: `&` must be followed by exactly one rest-parameter name or binding/type pair"
   (lambda ()
     (register-macro!
      (make-macro-registry) 'bad-rest 'defmacro
      '(label Any & body (Vec Any) stray)
      '(quasiquote nil)))))

(define CAPTURE-MATRIX-SOURCE-ID "capture-matrix.bclj")

(define CAPTURE-MATRIX-SOURCE
  (string-append
   "#lang beagle/clj\n"
   "(ns capture.matrix)\n"
   "(defmacro around [body]\n"
   "  `(let [tmp Any 1]\n"
   "     (do tmp ~body)))\n"
   "(defn capture-matrix [tmp Int] Int\n"
   "  (around (do tmp (let [tmp Int 2] tmp))))\n"))

(define (capture-matrix)
  (define source-bytes (string->bytes/utf-8 CAPTURE-MATRIX-SOURCE))
  (define program
    (parse-source-text CAPTURE-MATRIX-SOURCE-ID CAPTURE-MATRIX-SOURCE))
  (define reader-forms
    (read-beagle-syntax/bytes
     CAPTURE-MATRIX-SOURCE-ID
     source-bytes
     #:source-id CAPTURE-MATRIX-SOURCE-ID))
  (define reader-function
    (for/first ([form (in-list reader-forms)]
                #:when (equal? (car (syntax->datum form)) 'defn))
      form))
  (define reader-call (stx-ref (stx-subs reader-function) 4))
  (define reader-call-syntax
    (racket-syntax->beagle-syntax reader-call source-bytes))
  (define caller-body (cadr (syntax-list-children reader-call-syntax)))
  (define expanded
    (expand-fully (program-macros program) reader-call-syntax))
  (define expanded-children (syntax-list-children expanded))
  (define expanded-binding-children
    (syntax-vector-children (cadr expanded-children)))
  (define introduced-syntax-binder (car expanded-binding-children))
  (define expanded-do (caddr expanded-children))
  (define expanded-do-children (syntax-list-children expanded-do))
  (define introduced-syntax-use (cadr expanded-do-children))
  (define antiquoted-caller (caddr expanded-do-children))
  (define function (car (program-forms program)))
  (define parameter (car (defn-form-params function)))
  (define introduced-let (car (defn-form-body function)))
  (define introduced-binding (car (let-form-bindings introduced-let)))
  (define introduced-do (car (let-form-body introduced-let)))
  (define introduced-use (car (do-form-body introduced-do)))
  (define caller-do (cadr (do-form-body introduced-do)))
  (define caller-use (car (do-form-body caller-do)))
  (define nested-let (cadr (do-form-body caller-do)))
  (define nested-binding (car (let-form-bindings nested-let)))
  (define nested-use (car (let-form-body nested-let)))
  (hasheq
   'caller-body caller-body
   'antiquoted-caller antiquoted-caller
   'introduced-syntax-binder introduced-syntax-binder
   'introduced-syntax-use introduced-syntax-use
   'function function
   'parameter-id (binder-binding-id parameter 'tmp)
   'introduced-id (binder-binding-id introduced-binding 'tmp)
   'nested-id (binder-binding-id nested-binding 'tmp)
   'introduced-use introduced-use
   'caller-use caller-use
   'nested-use nested-use))

(test-case "syntax membrane: nested expansion records call-site origin chain"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'inner 'defmacro '(x)
   '(quasiquote (+ (unquote x) 1)))
  (register-macro!
   reg 'outer 'defmacro '(x)
   '(quasiquote (inner (unquote x))))
  (define call-span (src-loc 9 4 'caller 'original #f 101 15))
  (define call
    (datum->beagle-syntax
     '(outer value)
     call-span
     empty-scope-set
     #f
     (hasheq 'reader (reader-metadata #"(outer value)" 'paren))))
  (define expanded (expand-fully reg call))
  (define inner-origin (beagle-syntax-origin expanded))
  (define outer-origin (expansion-origin-parent inner-origin))
  (check-eq? (expansion-origin-macro-id inner-origin) 'inner)
  (check-eq? (expansion-origin-macro-id outer-origin) 'outer)
  (check-equal? (expansion-origin-call-span inner-origin) call-span)
  (check-equal? (expansion-origin-call-span outer-origin) call-span)
  (check-equal? (beagle-syntax-span expanded) call-span))

(test-case "scope hygiene: introduced binder/use share one introduction scope"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'with-tmp 'defmacro '(body)
   (list 'quasiquote
         (list 'let
               (br 'tmp 'Any 1)
               'tmp
               (list 'unquote 'body))))
  (define caller-scope (fresh-scope-id 'caller-lexical))
  (define caller-child
    (datum->beagle-syntax
     'tmp
     (src-loc 4 20 'caller 'original #f 40 3)
     (scope-set caller-scope)))
  (define call
    (make-syntax-list
     (list (datum->beagle-syntax 'with-tmp #f) caller-child) #f))
  (define expanded (expand-fully reg call))
  (define children (syntax-list-children expanded))
  (define binding-children (syntax-vector-children (cadr children)))
  (define introduced-binder (car binding-children))
  (define introduced-use (caddr children))
  (define inserted-caller (cadddr children))
  (check-true (syntax-ident? introduced-binder))
  (check-true (syntax-ident? introduced-use))
  (check-eq? (structural-name-leaf (syntax-ident-name introduced-binder)) 'tmp)
  (check-eq? (structural-name-leaf (syntax-ident-name introduced-use)) 'tmp)
  (check-equal? (beagle-syntax-scopes introduced-binder)
                (beagle-syntax-scopes introduced-use))
  (check-equal? (set-count (beagle-syntax-scopes introduced-binder)) 1)
  (check-false
   (scope-set-member?
    (beagle-syntax-scopes introduced-binder) caller-scope))
  (check-eq? inserted-caller caller-child)
  (check-equal? (beagle-syntax-scopes inserted-caller)
                (scope-set caller-scope)))

(test-case "scope hygiene: raw adapter keeps authored names, never suffix identity"
  (define reg (make-macro-registry))
  (register-macro!
   reg 'with-tmp 'defmacro '()
   (list 'quasiquote (list 'let (br 'tmp 'Any 1) 'tmp)))
  (check-equal?
   (expand-fully reg '(with-tmp))
   (list 'let (br 'tmp 'Any 1) 'tmp)))

(test-case "scope hygiene: antiquoted caller identity and scopes cannot be captured"
  (define matrix (capture-matrix))
  (define caller-body (hash-ref matrix 'caller-body))
  (define antiquoted-caller (hash-ref matrix 'antiquoted-caller))
  (define introduced-syntax-binder
    (hash-ref matrix 'introduced-syntax-binder))
  (check-eq? antiquoted-caller caller-body)
  (check-true
   (scope-set-subset?
    (beagle-syntax-scopes antiquoted-caller)
    (beagle-syntax-scopes introduced-syntax-binder)))
  (check-not-equal? (beagle-syntax-scopes introduced-syntax-binder)
                    (beagle-syntax-scopes antiquoted-caller)))

(test-case "scope hygiene: caller tmp resolves to parameter BindingId"
  (define matrix (capture-matrix))
  (define parameter-id (hash-ref matrix 'parameter-id))
  (check-true (binding-id? parameter-id))
  (check-equal?
   (resolved-ref-binding-id (hash-ref matrix 'caller-use))
   parameter-id))

(test-case "scope hygiene: introduced tmp resolves to introduced BindingId"
  (define matrix (capture-matrix))
  (define introduced-id (hash-ref matrix 'introduced-id))
  (check-true (binding-id? introduced-id))
  (check-equal?
   (resolved-ref-binding-id (hash-ref matrix 'introduced-use))
   introduced-id))

(test-case "scope hygiene: nested tmp resolves to nested let BindingId"
  (define matrix (capture-matrix))
  (define nested-id (hash-ref matrix 'nested-id))
  (check-true (binding-id? nested-id))
  (check-equal?
   (resolved-ref-binding-id (hash-ref matrix 'nested-use))
   nested-id))

(test-case "scope hygiene: real source keeps caller, introduced, and nested tmp edges distinct"
  (define matrix (capture-matrix))
  (define caller-body (hash-ref matrix 'caller-body))
  (define antiquoted-caller (hash-ref matrix 'antiquoted-caller))
  (define introduced-syntax-binder
    (hash-ref matrix 'introduced-syntax-binder))
  (define introduced-syntax-use (hash-ref matrix 'introduced-syntax-use))
  (define function (hash-ref matrix 'function))
  (define parameter-id (hash-ref matrix 'parameter-id))
  (define introduced-id (hash-ref matrix 'introduced-id))
  (define nested-id (hash-ref matrix 'nested-id))
  (define introduced-use (hash-ref matrix 'introduced-use))
  (define caller-use (hash-ref matrix 'caller-use))
  (define nested-use (hash-ref matrix 'nested-use))
  (check-eq? antiquoted-caller caller-body)
  (check-equal? (beagle-syntax-scopes introduced-syntax-binder)
                (beagle-syntax-scopes introduced-syntax-use))
  (check-true
   (scope-set-subset?
    (beagle-syntax-scopes antiquoted-caller)
    (beagle-syntax-scopes introduced-syntax-binder)))
  (check-not-equal? (beagle-syntax-scopes introduced-syntax-binder)
                    (beagle-syntax-scopes antiquoted-caller))
  (check-true (and (binding-id? parameter-id)
                   (binding-id? introduced-id)
                   (binding-id? nested-id)))
  (check-equal? (set-count (set parameter-id introduced-id nested-id)) 3)
  (check-equal? (resolved-ref-binding-id introduced-use) introduced-id)
  (check-equal? (resolved-ref-binding-id caller-use) parameter-id)
  (check-equal? (resolved-ref-binding-id nested-use) nested-id)
  (define wire (expr->json function))
  (define parameter-wire (car (hash-ref wire 'params)))
  (define introduced-wire (car (hash-ref wire 'body)))
  (define introduced-binding-wire (car (hash-ref introduced-wire 'bindings)))
  (define introduced-do-wire (car (hash-ref introduced-wire 'body)))
  (define introduced-use-wire (car (hash-ref introduced-do-wire 'body)))
  (define caller-do-wire (cadr (hash-ref introduced-do-wire 'body)))
  (define caller-use-wire (car (hash-ref caller-do-wire 'body)))
  (define nested-wire (cadr (hash-ref caller-do-wire 'body)))
  (define nested-binding-wire (car (hash-ref nested-wire 'bindings)))
  (define nested-use-wire (car (hash-ref nested-wire 'body)))
  (check-equal? (hash-ref parameter-wire 'bindingId)
                (binding-id-stable parameter-id))
  (check-equal? (hash-ref introduced-binding-wire 'bindingId)
                (binding-id-stable introduced-id))
  (check-equal? (hash-ref introduced-use-wire 'refersTo)
                (binding-id-stable introduced-id))
  (check-equal? (hash-ref caller-use-wire 'refersTo)
                (binding-id-stable parameter-id))
  (check-equal? (hash-ref nested-binding-wire 'bindingId)
                (binding-id-stable nested-id))
  (check-equal? (hash-ref nested-use-wire 'refersTo)
                (binding-id-stable nested-id))
  (check-equal? (hash-ref introduced-use-wire 'providerId) 'null))

;; --- recursive macro depth-cap --------------------------------------------
;;
;; A macro that expands to a call of itself triggers infinite recursion.
;; The expander caps depth at 64 (MAX-EXPANSION-DEPTH in macros.rkt) and
;; reports an error including the macro name and a truncated expansion
;; chain.

(test-case "hygiene: recursive macro hits depth-64 cap with macro name in chain"
  (define reg (make-macro-registry))
  ;; (defmacro loop-forever [x] `(loop-forever ,x))
  (register-macro! reg 'loop-forever 'defmacro '(x)
                   (list 'quasiquote
                         (list 'loop-forever (list 'unquote 'x))))
  (define err-msg #f)
  (check-exn
    (lambda (e)
      (set! err-msg (exn-message e))
      (and (exn:fail? e)
           ;; "exceeded depth" — generic cap message
           (regexp-match? #rx"exceeded depth" (exn-message e))
           ;; macro name appears in the chain
           (regexp-match? #rx"loop-forever" (exn-message e))))
    (lambda () (expand-fully reg '(loop-forever 1))))
  ;; Chain truncates at the boundary (4 head, "... N more", 4 tail). Make
  ;; sure the truncation pattern is visible — confirms we get provenance,
  ;; not just a bare "too deep".
  (check-true (regexp-match? #rx"in macro: loop-forever \\(depth 0\\)" err-msg)
              "depth-0 expansion record must be in the chain (root-cause anchor)")
  (check-true (regexp-match? #rx"\\.\\.\\. \\([0-9]+ more\\)" err-msg)
              "truncation marker must appear (proves chain is real)"))

;; --- stray (unquote …) outside (quasiquote …) -----------------------------
;;
;; A defmacro body like `(defmacro bad [x] (unquote x))` has unquote OUTSIDE
;; any quasiquote. The compile-time evaluator rejects it directly.
;;
;; The check below confirms (a) registration succeeds silently (lazy),
;; (b) the first expansion through the parser surfaces the error, and
;; (c) the message names the offending form and the fix.

(test-case "hygiene: (unquote …) outside (quasiquote …) errors with clear message"
  ;; Build (unquote x) structurally; literal source would trip Racket's
  ;; own reader-level interpretation.
  (define bad-body (list 'unquote 'x))
  ;; Registration alone is fine — beagle doesn't eagerly validate
  ;; macro bodies until expansion.
  (define p1
    (parse-prog
     (list 'defmacro 'bad (br 'x) bad-body)))
  (check-true (program? p1)
              "stray unquote alone in a defmacro body should register without error")
  ;; First expansion surfaces the actionable evaluator error.
  (check-exn
    #rx"unquote.*outside.*quasiquote"
    (lambda ()
      (parse-prog
       (list 'defmacro 'bad (br 'x) bad-body)
       '(def z (bad 42))))))

;; --- bonus: stray (unquote-splicing …) at expansion site ------------------
;;
;; The companion case: a defmacro that emits a stray unquote-splicing
;; outside any list context.

(test-case "hygiene: (unquote-splicing …) at top of body errors during evaluation"
  (define reg (make-macro-registry))
  ;; (defmacro splat [xs] `,@xs) — quasiquote then immediate splice at level 1,
  ;; not in a list context. Evaluation rejects it.
  (register-macro! reg 'splat 'defmacro '(xs)
                   (list 'quasiquote
                         (list 'unquote-splicing 'xs)))
  (check-exn
    #rx"unquote-splicing.*(surrounding list|list context)"
    (lambda () (expand-fully reg `(splat ,(br 1 2 3))))))
