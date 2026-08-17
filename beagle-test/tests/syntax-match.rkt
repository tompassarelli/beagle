#lang racket/base

;; W5c acceptance tests: structural syntax matching over the existing pure
;; macro evaluator. These are intentionally red until W5c lands.
;;
;; Contract frozen by this fixture:
;;   (syntax-match subject [pattern body] ...)
;;
;; A pattern keeps the subject's Syntax values as bindings. Ordinary list,
;; bracket-vector, and #%map shapes select the structural category. The
;; explicit `(literal x)`, `(identifier name)`, `(capture name)`, and
;; `(tail-splice name)` forms avoid confusing literals with captures. A tail
;; splice is legal only as the final element of a list/vector pattern.

(require rackunit
         racket/file
         (only-in beagle/private/ast
                  beagle-syntax-span
                  datum->beagle-syntax
                  empty-scope-set
                  make-expansion-origin
                  make-syntax-ident
                  syntax-ident?
                  syntax-ident-name
                  structural-name-qualifier
                  structural-name-leaf
                  make-syntax-list
                  make-syntax-vector
                  make-structural-name
                  reader-metadata
                  src-loc)
         (only-in beagle/private/tags BRACKET-TAG MAP-TAG)
         beagle/private/macro-eval
         beagle/private/parse
         beagle/private/check
         beagle/private/types)

(define (with-bindings bindings)
  (for/fold ([env (make-macro-env)])
            ([binding (in-list bindings)])
    (hash-set env (car binding) (cdr binding))))

(define (ev expr [bindings '()])
  (macro-eval expr (with-bindings bindings)))

(define (capture name) (list 'capture name))
(define (literal value) (list 'literal value))
(define (identifier name) (list 'identifier (capture name)))
(define (tail-splice name) (list 'tail-splice name))
(define (clause pattern body) (list BRACKET-TAG pattern body))

(define caller-span (src-loc 12 8 'w5c-matcher 'original #f 240 18))
(define caller-origin (make-expansion-origin 'when caller-span))

(define caller-test
  (make-syntax-list
   (list (datum->beagle-syntax '+ caller-span)
         (datum->beagle-syntax 1 caller-span)
         (datum->beagle-syntax 2 caller-span))
   caller-span empty-scope-set caller-origin
   (hasheq 'reader (reader-metadata #"(+ 1 2)" 'paren))))

(define body-one (datum->beagle-syntax 10 caller-span))
(define body-two (datum->beagle-syntax 20 caller-span))

(test-case "syntax-match captures a list identifier/literal and preserves tail identity"
  (define subject
    (make-syntax-list
     (list (datum->beagle-syntax 'when caller-span)
           caller-test body-one body-two)
     caller-span empty-scope-set caller-origin))
  (define result
    (ev
     (list 'syntax-match 'form
           (clause
            (list (literal 'when) (capture 'test) (tail-splice 'body))
            (list 'list 'test 'body)))
     (list (cons 'form subject))))
  (check-eq? (car result) caller-test)
  (check-eq? (car (cadr result)) body-one)
  (check-eq? (cadr (cadr result)) body-two)
  (check-equal? (beagle-syntax-span (car result)) caller-span))

(test-case "syntax-match distinguishes vector shape and keeps deterministic clause order"
  (define subject
    (make-syntax-vector (list caller-test body-one)
                        caller-span empty-scope-set caller-origin))
  (define result
    (ev
     (list 'syntax-match 'form
           ;; The list clause cannot match this vector. The first vector
           ;; clause must win over the later equally applicable clause.
           (clause (list (capture 'not-a-vector)) (list 'quote 'wrong))
           (clause (list BRACKET-TAG (capture 'test) (capture 'body))
                   (list 'quote 'first))
           (clause (list BRACKET-TAG (capture 'test) (capture 'body))
                   (list 'quote 'second)))
     (list (cons 'form subject))))
  (check-eq? result 'first))

(test-case "syntax-match matches map shape and identifier category"
  (define subject
    (datum->beagle-syntax
     (list MAP-TAG ':name caller-test)
     caller-span empty-scope-set caller-origin))
  (define map-result
    (ev
     (list 'syntax-match 'form
           (clause
            (list MAP-TAG (literal ':name) (capture 'value))
            'value))
     (list (cons 'form subject))))
  (check-eq? map-result caller-test)
  (define ident
    (make-syntax-ident
     (make-structural-name 'demo 'value 'provider-1)
     caller-span empty-scope-set caller-origin))
  (define ident-result
    (ev
     (list 'syntax-match 'form
           (clause (identifier 'name) 'name))
     (list (cons 'form ident))))
  (check-true (syntax-ident? ident-result))
  (check-eq? (structural-name-qualifier (syntax-ident-name ident-result))
             'demo)
  (check-eq? (structural-name-leaf (syntax-ident-name ident-result)) 'value))

(test-case "syntax-match rejects an unknown category at the pattern span"
  (define subject (datum->beagle-syntax '(value) caller-span))
  (check-exn #rx"syntax-match.*pattern|invalid.*pattern.*category"
             (lambda ()
               (ev
                (list 'syntax-match 'form
                      (clause (list 'record-pattern (capture 'x)) 'x))
                (list (cons 'form subject))))))

(test-case "syntax-match rejects a non-final tail splice at the pattern span"
  (define subject (datum->beagle-syntax '(value) caller-span))
  (check-exn #rx"tail-splice.*last|last.*tail-splice|pattern"
             (lambda ()
               (ev
                (list 'syntax-match 'form
                      (clause (list (tail-splice 'xs) (capture 'after))
                              'xs))
                (list (cons 'form subject))))))

(define (parse-source source)
  (define tmp (make-temporary-file "beagle-w5c-match-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (out) (display source out))
       #:exists 'truncate/replace)
     (parse-program (read-beagle-syntax tmp) #:source-path tmp))
   (lambda () (delete-file tmp))))

(test-case "when-shaped syntax-match expansion produces a typed checked expression"
  (define program
    (parse-source
     (string-append
      "#lang beagle/clj\n"
      "(ns w5c.acceptance)\n"
      "(defmacro when [test & body]\n"
      "  (syntax-match (cons test body)\n"
      "    [(list (capture test) (tail-splice body))\n"
      "     (list 'if test (cons 'do body))]))\n"
      "(defn answer [] Int (when true 42))\n")))
  (parameterize ([current-check-profile 2])
    (check-not-exn (lambda () (type-check! program))))
  (check-equal? (length (program-forms program)) 2))
