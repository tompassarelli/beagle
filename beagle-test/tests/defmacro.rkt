#lang racket/base

;; Tests for `defmacro` — the canonical macro definition form.
;;
;; `defmacro` is a thin sugar over `define-macro safe` whose body is
;; processed by the quasi-quote evaluator at expansion time. The reader
;; (Phase B) wraps `` `X ``, `,X`, `,@X` as `(quasiquote X)`,
;; `(unquote X)`, `(unquote-splicing X)`. Phase C wires those forms
;; through to template substitution + a final QQ-eval pass.

(require rackunit
         (for-syntax racket/base)
         beagle/private/parse
         beagle/private/types
         beagle/private/macros)

(define (parse-prog . forms)
  (parse-program (map (lambda (f) (datum->syntax #f f)) forms)))

(define (br . xs) (cons BRACKET-TAG xs))

;; --- (a) basic unquote ----------------------------------------------------

(test-case "defmacro: inc1 expands quasiquote+unquote"
  ;; (defmacro inc1 [x] `(+ ,x 1))
  ;; (inc1 5) → (+ 5 1)
  (define p (parse-prog
             `(defmacro inc1 ,(br 'x)
                (quasiquote (+ (unquote x) 1)))
             '(def y (inc1 5))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  (check-true (call-form? value))
  (check-eq? (call-form-fn value) '+)
  (check-equal? (call-form-args value) '(5 1)))

;; --- (b) unquote of a vector binding --------------------------------------

(test-case "defmacro: my-let unquotes a bracketed binding"
  ;; (defmacro my-let [bindings body] `(let ,bindings ,body))
  ;; (my-let [a 1] a) → (let [a 1] a)
  (define p (parse-prog
             `(defmacro my-let ,(br 'bindings 'body)
                (quasiquote (let (unquote bindings) (unquote body))))
             `(def y (my-let ,(br 'a 1) a))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  (check-true (let-form? value))
  (check-equal? (length (let-form-bindings value)) 1)
  (check-eq? (let-binding-name (car (let-form-bindings value))) 'a)
  (check-equal? (let-binding-value (car (let-form-bindings value))) 1))

;; --- (c) unquote-splicing into a do-block ---------------------------------

(test-case "defmacro: do-each splices a bracketed-vec into surrounding do"
  ;; (defmacro do-each [items body] `(do ,@items ,body))
  ;; (do-each [(println "a") (println "b")] (println "done"))
  ;;   → (do (println "a") (println "b") (println "done"))
  (define p (parse-prog
             `(defmacro do-each ,(br 'items 'body)
                (quasiquote (do (unquote-splicing items) (unquote body))))
             `(def y (do-each ,(br '(println "a") '(println "b"))
                              (println "done")))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (define value (def-form-value f))
  ;; do-form expected
  (check-true (do-form? value))
  (check-equal? (length (do-form-body value)) 3))

;; --- (d) nested quasi-quote -----------------------------------------------
;;
;; `(`(a ,,x b)) — only the inner `,,` reaches level 0. Reading top-down:
;;   level 0: outer quasiquote opens → level 1
;;   level 1: inner quasiquote opens → level 2
;;   level 2: first unquote → level 1 (stays as data)
;;   level 1: second unquote → level 0 (fires; emits x's value)
;; Result: `(a ,VAL b) = (quasiquote (a (unquote VAL) b))
;;
;; We register the macro and inspect its expansion via expand-fully on a
;; raw registry to avoid downstream parse semantics for stray
;; quasiquote/unquote.

(test-case "defmacro: nested quasiquote — only one level unquotes"
  (define reg (make-macro-registry))
  ;; (defmacro outer [x] `(`(a ,,x b)))
  (register-macro! reg 'outer 'defmacro '(x)
                   '(quasiquote
                     (quasiquote
                      (a (unquote (unquote x)) b))))
  (define expanded (expand-fully reg '(outer 99)))
  ;; Expect (quasiquote (a (unquote 99) b))
  (check-equal? expanded '(quasiquote (a (unquote 99) b))))

;; --- (e) hygiene: gensym-protected template binder ------------------------

(test-case "defmacro: swap renames template-introduced tmp to avoid capture"
  ;; (defmacro swap [a b] `(let [tmp ,a] (set! ,a ,b) (set! ,b tmp)))
  ;; If hygiene works, `tmp` is gensym'd in both binder and reference
  ;; positions — the resulting let-binding name is not the literal symbol
  ;; `tmp`.
  (define reg (make-macro-registry))
  (register-macro! reg 'swap 'defmacro '(a b)
                   (list 'quasiquote
                         (list 'let
                               (cons BRACKET-TAG
                                     (list 'tmp (list 'unquote 'a)))
                               (list 'set! (list 'unquote 'a) (list 'unquote 'b))
                               (list 'set! (list 'unquote 'b) 'tmp))))
  (define expanded (expand-fully reg '(swap foo bar)))
  ;; expanded ≈ (let [G tmp-gensym foo] (set! foo bar) (set! bar tmp-gensym))
  (check-true (pair? expanded))
  (check-eq? (car expanded) 'let)
  (define bindings (cadr expanded))
  ;; bindings should be a bracketed-vec
  (check-true (and (pair? bindings) (eq? (car bindings) BRACKET-TAG)))
  (define binder-name (cadr bindings))
  ;; gensym means the binder is NOT the literal symbol `tmp`
  (check-false (eq? binder-name 'tmp))
  ;; The binding value is the substituted parameter
  (check-eq? (caddr bindings) 'foo)
  ;; The trailing `tmp` reference is renamed to the SAME gensym
  (define trailing-set! (cadddr expanded))
  (check-eq? (caddr trailing-set!) binder-name))

;; --- (f) arity error ------------------------------------------------------

(test-case "defmacro: arity mismatch errors"
  (check-exn #rx"expected 2 arg"
    (lambda ()
      (parse-prog
       `(defmacro pair ,(br 'x 'y) (quasiquote ((unquote x) (unquote y))))
       '(def z (pair 1))))))

;; --- additional sanity: defmacro without quasiquote ----------------------

(test-case "defmacro: literal body (no quasiquote) behaves like safe template"
  ;; (defmacro id [x] x) — no quasiquote, just direct substitution.
  (define p (parse-prog
             `(defmacro id ,(br 'x) x)
             '(def y (id 42))))
  (define f (car (program-forms p)))
  (check-true (def-form? f))
  (check-equal? (def-form-value f) 42))

;; --- additional sanity: defmacro duplicate registration errors ------------

(test-case "defmacro: duplicate definition errors"
  (check-exn exn:fail?
    (lambda ()
      (parse-prog
       `(defmacro dup ,(br 'x) (quasiquote (unquote x)))
       `(defmacro dup ,(br 'y) (quasiquote (unquote y)))))))

;; --- Phase D edge cases ---------------------------------------------------
;;
;; Coverage for splice-position, container-position, and stray-form
;; behavior that Phase C's six spec deliverables didn't directly hit.

(define MAP-T '#%map)

(test-case "defmacro: splice in middle of list"
  ;; (defmacro middle [xs] `(a ,@xs b))
  ;; (middle [1 2]) → (a 1 2 b)
  (define reg (make-macro-registry))
  (register-macro! reg 'middle 'defmacro '(xs)
                   '(quasiquote (a (unquote-splicing xs) b)))
  (check-equal? (expand-fully reg `(middle ,(br 1 2)))
                '(a 1 2 b)))

(test-case "defmacro: empty splice collapses cleanly"
  ;; (defmacro maybe [xs] `(do ,@xs done))
  ;; (maybe []) → (do done)
  (define reg (make-macro-registry))
  (register-macro! reg 'maybe 'defmacro '(xs)
                   '(quasiquote (do (unquote-splicing xs) done)))
  (check-equal? (expand-fully reg `(maybe ,(br)))
                '(do done)))

(test-case "defmacro: splice in vec preserves bracket tag"
  ;; (defmacro vec-it [xs] `[head ,@xs tail])
  ;; (vec-it [1 2]) → [head 1 2 tail] (preserving #%brackets tag)
  (define reg (make-macro-registry))
  (register-macro! reg 'vec-it 'defmacro '(xs)
                   (list 'quasiquote
                         (list BRACKET-TAG 'head
                               (list 'unquote-splicing 'xs)
                               'tail)))
  (check-equal? (expand-fully reg `(vec-it ,(br 1 2)))
                (cons BRACKET-TAG '(head 1 2 tail))))

(test-case "defmacro: splice in map preserves map tag"
  ;; (defmacro map-it [pairs] `{:a 1 ,@pairs :z 99})
  ;; The reader emits `{…}` as (#%map …). qq-walk-list walks any pair head,
  ;; including #%map, so splicing inside a map literal is supported. The
  ;; key/value pairing inside the map remains the user's responsibility.
  (define reg (make-macro-registry))
  (register-macro! reg 'map-it 'defmacro '(pairs)
                   ;; Build the template structurally — Racket's own QQ would
                   ;; mis-treat the nested (quasiquote (,MAP-T ...)) as level-2.
                   (list 'quasiquote
                         (list MAP-T ':a 1
                               (list 'unquote-splicing 'pairs)
                               ':z 99)))
  (check-equal? (expand-fully reg `(map-it ,(br ':k1 ':v1)))
                (list MAP-T ':a 1 ':k1 ':v1 ':z 99)))

(test-case "defmacro: unquote in map key position"
  ;; (defmacro keyed [k v] `{,k ,v})
  ;; qq-walk treats map elements as a flat list — both key and value
  ;; positions are unquotable. The keyword-key constraint is a downstream
  ;; (parse-time) check on the post-expansion map literal, not a QQ-eval
  ;; concern: macro expansion produces (#%map :foo 42); parse-map-literal
  ;; then validates :foo as a keyword key.
  (define reg (make-macro-registry))
  (register-macro! reg 'keyed 'defmacro '(k v)
                   (list 'quasiquote
                         (list MAP-T
                               (list 'unquote 'k)
                               (list 'unquote 'v))))
  (check-equal? (expand-fully reg '(keyed :foo 42))
                (list MAP-T ':foo 42)))

(test-case "defmacro: stray unquote at top level errors"
  ;; `(def x ,y)` outside any quasiquote must surface a clear error.
  (check-exn #rx"unquote.*outside quasiquote"
    (lambda ()
      (parse-prog
       '(def y 1)
       '(def x (unquote y))))))

(test-case "defmacro: stray unquote-splicing at top level errors"
  (check-exn #rx"unquote-splicing.*outside quasiquote"
    (lambda ()
      (parse-prog
       '(def ys (vector 1 2))
       '(def x (unquote-splicing ys))))))

(test-case "defmacro: stray quasiquote at top level errors"
  ;; `(def x `(a ,b c))` — beagle's quasiquote is macro-template-only;
  ;; using it at the top level for data construction is rejected with
  ;; a clear pointer toward `'(…)` / `'[…]` / `'{…}` inert containers.
  (check-exn #rx"quasiquote.*outside defmacro body"
    (lambda ()
      (parse-prog
       '(def b 99)
       '(def x (quasiquote (a (unquote b) c)))))))
