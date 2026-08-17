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
                  reader-metadata
                  scope-set
                  scope-set-member?
                  src-loc
                  structural-name-leaf
                  syntax-ident?
                  syntax-ident-name
                  syntax-list-children
                  syntax-vector-children))

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (br . xs) (cons BRACKET-TAG xs))

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
               (br 'tmp 1)
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
   (list 'quasiquote (list 'let (br 'tmp 1) 'tmp)))
  (check-equal?
   (expand-fully reg '(with-tmp))
   (list 'let (br 'tmp 1) 'tmp)))

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
              "depth-0 frame must be in the chain (root-cause anchor)")
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
