#lang racket/base

;; types-as-view: project the checker's knowledge back into beagle surface.
;;
;; The clean view is literally your source (proving the anti-reification point
;; — nothing is stored). The `inferred` and `all` views take that same source
;; and TEXT-INJECT `:- T` / `^T` annotations at precise positions recovered
;; from the src-table + the per-node inferred types captured during checking
;; (ast.rkt current-type-table). No type lives in the source; the view is a
;; pure function of the checked program. This is beagle's delaborator — the
;; inverse of elaboration (cf. Lean's PrettyPrinter/Delaborator).
;;
;; CLI:  beagle-explain-type FILE [NAME] [--level clean|inferred|all]

(require racket/list
         racket/string
         racket/file
         "parse.rkt"
         "check.rkt"
         "types.rkt"
         "ast.rkt")

(provide explain-type)

;; --- generic AST walk (transparent structs) ---------------------------------

;; Field list of a transparent struct instance, or #f for non-structs.
(define (struct-fields x)
  (with-handlers ([exn:fail? (lambda _ #f)])
    (define v (struct->vector x))
    (and (> (vector-length v) 0)
         (symbol? (vector-ref v 0))
         (regexp-match? #rx"^struct:" (symbol->string (vector-ref v 0)))
         (cdr (vector->list v)))))

;; All nodes in x (and its substructure) satisfying pred, in document order.
;; A visited set guards against cycles AND shared substructure (e.g.
;; threading-marker holds both orig-args and desugared, which share nodes —
;; naive recursion would be exponential).
(define (deep-collect pred x)
  (define out '())
  (define seen (make-hasheq))
  (let go ([x x])
    (cond
      [(or (string? x) (symbol? x) (number? x) (boolean? x) (null? x)) (void)]
      [(and (or (pair? x) (struct-fields x)) (hash-ref seen x #f)) (void)]
      [else
       (when (or (pair? x) (struct-fields x)) (hash-set! seen x #t))
       (when (pred x) (set! out (cons x out)))
       (cond
         [(pair? x) (go (car x)) (go (cdr x))]
         [(struct-fields x) => (lambda (fs) (for-each go fs))]
         [else (void)])]))
  (reverse out))

;; --- offsets ----------------------------------------------------------------

;; 0-based codepoint offset of a node's start, from src-loc-pos (syntax-
;; position). We use `pos`, NOT line/col: syntax-column expands tabs to
;; tab-stops, so it is not a codepoint index and would mis-place injections
;; on tab-indented lines. syntax-position is a true codepoint offset (tabs
;; count as one char), and after CRLF->LF normalization of the text it lines
;; up exactly with substring indices (Racket counts a CRLF as one position).
(define (loc-offset loc)
  (and (src-loc? loc) (src-loc-pos loc) (sub1 (src-loc-pos loc))))

;; Apply (offset . insert-string) edits to text, right-to-left so earlier
;; offsets stay valid. Sorted by offset desc then string, so the output is
;; deterministic even when two nodes share an offset.
(define (apply-edits text edits)
  (define ordered
    (sort edits (lambda (a b)
                  (or (> (car a) (car b))
                      (and (= (car a) (car b)) (string<? (cdr a) (cdr b)))))))
  (for/fold ([t text]) ([e (in-list ordered)])
    (string-append (substring t 0 (car e)) (cdr e) (substring t (car e)))))

;; --- form lookup ------------------------------------------------------------

(define (form-name f)
  (cond [(defn-form? f)  (defn-form-name f)]
        [(def-form? f)   (def-form-name f)]
        [(defonce-form? f) (defonce-form-name f)]
        [(defn-multi? f) (defn-multi-name f)]
        [else #f]))

;; Returns (values form form-stx) for NAME, or (values #f #f).
(define (find-form prog name)
  (let loop ([fs (program-forms prog)] [ss (program-form-stxs prog)])
    (cond
      [(or (null? fs) (null? ss)) (values #f #f)]
      [(equal? (form-name (car fs)) name) (values (car fs) (car ss))]
      [else (loop (cdr fs) (cdr ss))])))

;; --- view construction ------------------------------------------------------

;; 0-based start / end codepoint offsets of a top-level form, from its syntax
;; position+span. (text is CRLF-normalized upstream so these align.)
(define (form-bounds form-stx text)
  (define pos (syntax-position form-stx))
  (define span (syntax-span form-stx))
  (values (if pos (sub1 pos) 0)
          (if (and pos span) (min (string-length text) (+ (sub1 pos) span))
              (string-length text))))

(define (form-source text form-stx)
  (define-values (start end) (form-bounds form-stx text))
  (substring text start end))

;; inferred: inject `:- T` before each un-annotated, symbol-named let-binding
;; value whose type was captured. Destructuring-pattern bindings are skipped
;; (a single `:- Any` on a whole pattern is unhelpful). Offsets are relative
;; to the form substring. Reports to stderr when some eligible bindings could
;; not be annotated (no recorded position/type — e.g. literal/leaf values or
;; multi-arity bodies), so the gap is never silent.
(define (annotate-inferred text form form-stx src-tbl ty-tbl)
  (define-values (base _end) (form-bounds form-stx text))
  (define candidates
    (for/list ([b (in-list (deep-collect let-binding? form))]
               #:when (and (not (let-binding-type b))
                           (symbol? (let-binding-name b))))
      b))
  (define edits
    (for*/list ([b (in-list candidates)]
                [v (in-value (let-binding-value b))]
                [loc (in-value (hash-ref src-tbl v #f))]
                [ty (in-value (hash-ref ty-tbl v #f))]
                [abs (in-value (loc-offset loc))]
                #:when (and abs ty))
      (cons (- abs base) (string-append ":- " (type->string ty) " "))))
  (when (< (length edits) (length candidates))
    (eprintf "note: annotated ~a of ~a let-binding(s); the rest have no recorded type/position (literal/leaf values, or a multi-arity body)\n"
             (length edits) (length candidates)))
  (apply-edits (form-source text form-stx) edits))

;; all (pp.all): a DEBUG projection — prefix every typed+positioned node in
;; the form with `^T`. Unlike clean/inferred this does NOT round-trip (the
;; reader treats `^T` as metadata); it is for reading, not re-parsing.
(define (annotate-all text form form-stx src-tbl ty-tbl)
  (define-values (start end) (form-bounds form-stx text))
  (define edits
    (for*/list ([(node ty) (in-hash ty-tbl)]
                [loc (in-value (hash-ref src-tbl node #f))]
                [abs (in-value (loc-offset loc))]
                #:when (and abs (>= abs start) (< abs end)))
      (cons (- abs start) (string-append "^" (type->string ty) " "))))
  (apply-edits (form-source text form-stx) edits))

;; --- entry ------------------------------------------------------------------

;; Returns a string (the rendered view) or raises a user error.
(define (explain-type path #:name [name #f] #:level [level "clean"] #:write? [write? #f])
  ;; Normalize CRLF->LF so substring offsets align with syntax-position
  ;; (Racket counts a CRLF as a single position). LF files are unchanged.
  (define text (regexp-replace* #rx"\r\n" (file->string path) "\n"))
  (define stxs (read-beagle-syntax path))
  (define prog (parse-program stxs #:source-path path))
  ;; check WITH type capture (opt-in) to populate the per-node type table.
  ;; Errors are tolerated — a file with a type error still yields partial
  ;; inferred types.
  (type-check-with-locs! prog (lambda (e stx) (void)) #:capture-types? #t)
  (define src-tbl (or (program-src-table prog) (make-hasheq)))
  (define ty-tbl  (or (program-type-table prog) (make-hasheq)))
  (define-values (form form-stx)
    (if name (find-form prog (string->symbol name)) (values #f #f)))
  (when (and name (not form))
    (error 'beagle-explain-type "no top-level definition named `~a` in ~a" name path))
  (define rendered
    (cond
      [(not form) text]   ; no NAME: clean view of the whole file
      [(string=? level "clean")    (form-source text form-stx)]
      [(string=? level "inferred") (annotate-inferred text form form-stx src-tbl ty-tbl)]
      [(string=? level "all")      (annotate-all text form form-stx src-tbl ty-tbl)]
      [else (error 'beagle-explain-type "unknown --level ~a (use clean|inferred|all)" level)]))
  (cond
    [(not write?) rendered]
    ;; promote: splice the rendered form back into the file in place. Only
    ;; the inferred level (which round-trips) may be written — `all` is a
    ;; non-reparseable debug view. Reversible: re-running clean (or hand-
    ;; deleting the `:- T`) recovers the original; promoting is idempotent.
    [(not form) (error 'beagle-explain-type "--write needs a NAME (the definition to promote)")]
    [(not (string=? level "inferred"))
     (error 'beagle-explain-type "--write supports only --level inferred (got ~a)" level)]
    [else
     (define-values (start end) (form-bounds form-stx text))
     (define new-text (string-append (substring text 0 start) rendered (substring text end)))
     (call-with-output-file path (lambda (o) (display new-text o)) #:exists 'truncate/replace)
     (format "promoted inferred types into `~a` (~a)" name path)]))

;; --- CLI --------------------------------------------------------------------

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  ;; manual parse so --level works in any position
  (define level
    (let loop ([a args])
      (cond [(null? a) "clean"]
            [(and (string=? (car a) "--level") (pair? (cdr a))) (cadr a)]
            [else (loop (cdr a))])))
  (define write? (and (member "--write" args) #t))
  (define positional
    (let strip ([a args])
      (cond [(null? a) '()]
            [(string=? (car a) "--level") (strip (cddr a))]
            [(string=? (car a) "--write") (strip (cdr a))]
            [else (cons (car a) (strip (cdr a)))])))
  ;; --write promotes inferred types in place; it implies --level inferred
  ;; unless the user explicitly asked for another level (which then errors).
  (define eff-level (if (and write? (string=? level "clean")) "inferred" level))
  (cond
    [(null? positional)
     (eprintf "usage: beagle-explain-type FILE [NAME] [--level clean|inferred|all] [--write]\n")
     (exit 2)]
    [else
     (define file (car positional))
     (define name (and (pair? (cdr positional)) (cadr positional)))
     (with-handlers ([exn:fail? (lambda (e) (eprintf "~a\n" (exn-message e)) (exit 1))])
       (display (explain-type file #:name name #:level eff-level #:write? write?))
       (newline))]))
