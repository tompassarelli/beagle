#lang racket/base

;; AST-rewrite framework for beagle codemods.
;;
;; Operates at the s-expression level (post-read, pre-parse). Each rewrite
;; rule is a pattern→replacement pair (Racket `match` semantics). The
;; framework walks an expression tree bottom-up, applying the rule's
;; transform at each pair node.
;;
;; Rules are defined in beagle-lib/private/rewrites/*.rkt and registered
;; via define-rewrite. The CLI (bin/beagle-rewrite) loads rule files,
;; applies the requested rule to file(s) or directory, and either prints
;; the diff (default) or writes changes back (--apply).
;;
;; Design decision (Racket-side, not Beagle-native): the framework needs
;; to read beagle source via the beagle reader and walk Racket sexprs.
;; Bridging Racket-side sexpr operations to Beagle would add complexity
;; without proportionate value at this stage. Revisit when Cyclone
;; self-host work begins and Beagle AST values are exposed as Beagle data.

(require racket/match
         racket/list
         racket/file
         racket/port
         racket/format
         racket/string
         ;; THE single beagle readtable — no bespoke subset reader to drift
         ;; (#19/#32). Datum mode (plain read) yields container/reader tags as data.
         (only-in "../lang/reader-impl.rkt" beagle-readtable))

(provide rewrite-rule
         rewrite-rule?
         rewrite-rule-name
         rewrite-rule-doc
         define-rewrite
         get-rule
         all-rules
         apply-rewrite
         read-beagle-source
         write-beagle-source
         rewrite-file
         rewrite-text)

;; --- rule registry ---------------------------------------------------------

(struct rewrite-rule (name doc transform) #:transparent)

(define RULES (make-hash))

(define-syntax-rule (define-rewrite name doc-string clauses ...)
  (hash-set! RULES 'name
    (rewrite-rule 'name doc-string
      (lambda (expr)
        (match expr clauses ... [_ expr])))))

(define (get-rule name)
  (hash-ref RULES name
    (lambda ()
      (error 'beagle-rewrite "unknown rule: ~a. Known rules: ~a"
             name
             (string-join (map symbol->string (hash-keys RULES)) ", ")))))

(define (all-rules) (hash-values RULES))

;; --- bottom-up traversal ---------------------------------------------------

;; Walk an expression tree applying rule.transform at each pair node.
;; Bottom-up: rewrite children first, then the parent. This means an
;; inner rewrite is visible to an outer rewrite if patterns nest.
(define (apply-rewrite rule expr)
  (define t (rewrite-rule-transform rule))
  (cond
    [(pair? expr)
     (define rewritten-children
       (cons (apply-rewrite rule (car expr))
             (rule-walk-cdr rule (cdr expr))))
     (t rewritten-children)]
    [else expr]))

(define (rule-walk-cdr rule rest)
  ;; Walk a cdr (which may be a proper list, improper, or atom).
  (cond
    [(pair? rest)
     (cons (apply-rewrite rule (car rest))
           (rule-walk-cdr rule (cdr rest)))]
    [(null? rest) '()]
    [else rest]))

;; --- beagle source I/O -----------------------------------------------------

;; Beagle uses these well-known tags for non-paren delimiters:
;;   [a b c]    → (#%brackets a b c)   — vectors
;;   {:k v}     → (#%map :k v)         — maps
;;   #{a b c}   → (#%set a b c)        — sets
;;
;; The Racket reader with read-square-bracket-with-tag handles [] natively.
;; {} and #{} need a custom readtable. We install one matching the beagle
;; reader's behavior.

(define BRACKET-TAG '#%brackets)
(define MAP-TAG     '#%map)
(define SET-TAG     '#%set)

;; Read the optional `#lang ...` line at the top of a source file. Returns
;; the line as a string (without trailing newline) or #f if absent. Leaves
;; the port positioned at the start of the first form after the line.
(define (read-lang-line port)
  (define peek (peek-string 5 0 port))
  (cond
    [(and (string? peek) (string=? peek "#lang"))
     (read-line port 'any)]   ; consume "#lang ..." up to and including newline
    [else #f]))

(define (read-beagle-source path)
  (call-with-input-file path
    (lambda (port)
      (define lang-line (read-lang-line port))
      (parameterize ([current-readtable beagle-readtable])
        (define forms
          (let loop ([acc '()])
            (define x (read port))
            (if (eof-object? x) (reverse acc) (loop (cons x acc)))))
        (values lang-line forms)))))

;; --- writer ----------------------------------------------------------------

;; Write an s-expression back as beagle source. Handles the tag-back
;; conversion: (#%brackets a b c) → [a b c], (#%map :k v) → {:k v}, etc.
;; Pretty-prints with reasonable defaults. Does NOT preserve original
;; whitespace/comments — caller should review the diff before applying.
(define (write-beagle-source forms out)
  (for ([f (in-list forms)])
    (write-beagle-form f out 0)
    (display "\n\n" out)))

(define (write-beagle-form form out indent)
  (cond
    [(pair? form)
     (cond
       [(eq? (car form) BRACKET-TAG)
        (display "[" out)
        (write-items (cdr form) out (+ indent 1) " ")
        (display "]" out)]
       [(eq? (car form) MAP-TAG)
        (display "{" out)
        (write-items (cdr form) out (+ indent 1) " ")
        (display "}" out)]
       [(eq? (car form) SET-TAG)
        (display "#{" out)
        (write-items (cdr form) out (+ indent 2) " ")
        (display "}" out)]
       [(and (eq? (car form) '#%regex) (= (length form) 2) (string? (cadr form)))
        (display "#" out) (write (cadr form) out)]
       ;; #?(:tag form ...) / #?@(:tag form ...) — reader conditionals
       [(eq? (car form) 'reader-conditional)
        (display "#?(" out) (write-items (cdr form) out (+ indent 3) " ") (display ")" out)]
       [(eq? (car form) 'reader-conditional-splice)
        (display "#?@(" out) (write-items (cdr form) out (+ indent 4) " ") (display ")" out)]
       ;; ^meta form  (privacy / dynamic / metadata)
       [(and (eq? (car form) '#%meta) (= (length form) 3))
        (display "^" out) (write-beagle-form (cadr form) out indent)
        (display " " out) (write-beagle-form (caddr form) out indent)]
       ;; quote family → ' ` ~ ~@  (only the exact 2-element reader shape)
       [(and (pair? (cdr form)) (null? (cddr form))
             (memq (car form) '(quote quasiquote unquote unquote-splicing)))
        (display (case (car form)
                   [(quote) "'"] [(quasiquote) "`"]
                   [(unquote) "~"] [(unquote-splicing) "~@"]) out)
        (write-beagle-form (cadr form) out indent)]
       [else
        (display "(" out)
        (write-items form out (+ indent 1) " ")
        (display ")" out)])]
    [(null? form) (display "()" out)]
    [(string? form) (write form out)]
    [(symbol? form) (display form out)]
    [(boolean? form) (display (if form "true" "false") out)]
    [(eq? form 'nil) (display "nil" out)]
    [else (write form out)]))

(define (write-items items out indent sep)
  (cond
    [(null? items) (void)]
    [(pair? items)
     (write-beagle-form (car items) out indent)
     (cond
       [(null? (cdr items)) (void)]
       [(pair? (cdr items))
        (display sep out)
        (write-items (cdr items) out indent sep)]
       [else
        (display " . " out)
        (write-beagle-form (cdr items) out indent)])]
    [else
     (display " . " out)
     (write-beagle-form items out indent)]))

;; --- file-level operations -------------------------------------------------

(struct rewrite-result (path original rewritten changed?) #:transparent)
(provide (struct-out rewrite-result))

(define (rewrite-file rule path)
  (define-values (lang-line forms) (read-beagle-source path))
  (define rewritten (map (lambda (f) (apply-rewrite rule f)) forms))
  (define changed? (not (equal? forms rewritten)))
  (define out (open-output-string))
  (when lang-line
    (display lang-line out) (newline out) (newline out))
  (write-beagle-source rewritten out)
  (rewrite-result path forms (get-output-string out) changed?))

(define (rewrite-text rule text)
  (define forms
    (with-input-from-string text
      (lambda ()
        (parameterize ([current-readtable beagle-readtable])
          (let loop ([acc '()])
            (define x (read))
            (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))
  (define rewritten (map (lambda (f) (apply-rewrite rule f)) forms))
  (define changed? (not (equal? forms rewritten)))
  (define out (open-output-string))
  (write-beagle-source rewritten out)
  (rewrite-result #f forms (get-output-string out) changed?))
