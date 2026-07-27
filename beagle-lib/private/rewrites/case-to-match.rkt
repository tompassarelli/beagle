#lang racket/base

;; Mechanical migration for the removed `case` surface. Only keys accepted as
;; Beagle literal match patterns are rewritten; unsupported Clojure constants
;; leave the whole case untouched for manual review.

(require racket/list
         "../rewrite.rkt")

(define BRACKET-TAG '#%brackets)

(define (keyword-symbol? value)
  (and (symbol? value)
       (let ([text (symbol->string value)])
         (and (positive? (string-length text))
              (char=? (string-ref text 0) #\:)))))

(define (match-literal? value)
  (or (eq? value 'nil)
      (string? value)
      (boolean? value)
      (exact-integer? value)
      (real? value)
      (keyword-symbol? value)))

(define (case-key->pattern key)
  (cond
    [(and (list? key) (pair? key) (andmap match-literal? key))
     `(or . ,key)]
    [(match-literal? key) key]
    [else #f]))

(define (case-pairs->match-clauses pairs)
  (cond
    [(null? pairs) '()]
    [else
     (cons (list BRACKET-TAG
                 (case-key->pattern (first pairs))
                 (second pairs))
           (case-pairs->match-clauses (cddr pairs)))]))

(define (case-pair-keys pairs)
  (cond
    [(null? pairs) '()]
    [else (cons (first pairs) (case-pair-keys (cddr pairs)))]))

(define (case->match original target parts)
  (cond
    [(null? parts) original]
    [else
     (define has-default? (odd? (length parts)))
     (define pairs (if has-default? (drop-right parts 1) parts))
     (define keys (case-pair-keys pairs))
     (cond
       [(not (andmap case-key->pattern keys)) original]
       [else
        `(match ,target
           ,@(case-pairs->match-clauses pairs)
           ,@(if has-default?
                 (list (list BRACKET-TAG '_ (last parts)))
                 '()))])]))

(define-rewrite case-to-match
  "Replace literal-dispatch (case x k v ... default?) with match clauses; grouped constants become or-patterns."
  [(and original `(case ,target . ,parts))
   (case->match original target parts)])
