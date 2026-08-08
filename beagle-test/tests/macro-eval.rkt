#lang racket/base

;; `macro-eval` runs a `(define-macro beagle ...)` body at expansion time. Its
;; job is to BUILD a datum, so quasiquote and the typed-binding constructors
;; must produce exactly the shapes the parser accepts.

(require rackunit
         (only-in beagle/private/tags ANN-MARKER)
         beagle/private/macro-eval)

(define (ev expr) (macro-eval expr (make-macro-env)))

;; `let` is macro-eval's only binder, so a test seeds values by wrapping.
(define (ev-let bindings expr)
  (macro-eval `(let ,(apply append
                            (map (lambda (p) (list (car p) (list 'quote (cdr p))))
                                 bindings))
                 ,expr)
              (make-macro-env)))

;; --- quasiquote --------------------------------------------------------------

(test-case "quasiquote returns its template literally"
  (check-equal? (ev '(quasiquote (defn f [] -> Float 1.0)))
                '(defn f [] -> Float 1.0)))

(test-case "unquote evaluates in place"
  (check-equal? (ev-let '((x . 42)) '(quasiquote (+ (unquote x) 1)))
                '(+ 42 1)))

(test-case "unquote splices a computed symbol into a definition head"
  (check-equal? (ev-let '((base . speed))
                        '(quasiquote (defn (unquote (format-symbol "~a-get" base)) [] -> Float 1.0)))
                '(defn speed-get [] -> Float 1.0)))

(test-case "unquote-splicing flattens a list into the surrounding form"
  (check-equal? (ev-let '((xs . (1.0 2.0 3.0))) '(quasiquote (+ (unquote-splicing xs))))
                '(+ 1.0 2.0 3.0)))

(test-case "unquote-splicing composes with literal neighbours"
  (check-equal? (ev-let '((xs . (2 3))) '(quasiquote (f 1 (unquote-splicing xs) 4)))
                '(f 1 2 3 4)))

(test-case "quasiquote nests through sub-forms"
  (check-equal? (ev-let '((n . x)) '(quasiquote (do (a (unquote n)) (b (unquote n)))))
                '(do (a x) (b x))))

(test-case "unquote-splicing rejects a non-list"
  (check-exn #rx"expected a list"
             (lambda () (ev-let '((v . 7)) '(quasiquote (+ (unquote-splicing v)))))))

(test-case "unquote outside a template is an error, not a silent call"
  (check-exn #rx"outside a quasiquote"
             (lambda () (ev '(unquote x)))))

;; --- typed bindings are FLAT in their vector ---------------------------------

(test-case "vec splices a param into the flat shape the parser accepts"
  ;; `[v: Float]` is three items in the vector, never a nested triple:
  ;; a nested `(v #%: Float)` is the retired parenthesized spelling.
  (check-equal? (ev '(vec (make-param (quote v) (quote Float))))
                (list 'v ANN-MARKER 'Float)))

(test-case "vec splices several params, staying flat"
  (check-equal? (ev '(vec (make-param (quote a) (quote Float))
                          (make-param (quote b) (quote Int))))
                (list 'a ANN-MARKER 'Float 'b ANN-MARKER 'Int)))

(test-case "vec splices record fields the same way"
  (check-equal? (ev '(vec (make-field (quote x) (quote Float))))
                (list 'x ANN-MARKER 'Float)))

(test-case "vec leaves ordinary values alone"
  (check-equal? (ev '(vec 1 2 3)) '(1 2 3)))

(test-case "vec does not splice a same-shaped list that is not an annotation"
  (check-equal? (ev '(vec (list 1 2 3))) '((1 2 3))))

(test-case "make-defn with a spliced param vector parses as a typed signature"
  (check-equal? (ev '(make-defn (quote f)
                                (vec (make-param (quote v) (quote Float)))
                                (quote Float)
                                (quote v)))
                (list 'defn 'f (list 'v ANN-MARKER 'Float) '-> 'Float 'v)))
