#lang racket/base

(require json
         racket/string
         racket/list
         "parse.rkt"
         "check.rkt"
         "error-format.rkt"
         "query.rkt"
         "blame.rkt"
         "lint.rkt"
         "extensions.rkt")

;; --- agent mode --------------------------------------------------------------
;; When BEAGLE_AGENT_MODE=1, suppress lint and show a clean error summary
;; designed for LLM agent consumption.

(define (agent-mode?)
  (and (getenv "BEAGLE_AGENT_MODE") #t))

;; --- source line cache ------------------------------------------------------

(define source-cache (make-hash))

(define (read-source-line file-path line-num)
  (define lines
    (hash-ref! source-cache file-path
      (lambda ()
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (define p (if (path? file-path) file-path (string->path file-path)))
          (call-with-input-file p
            (lambda (in)
              (let loop ([acc '()])
                (define line (read-line in))
                (if (eof-object? line)
                    (list->vector (reverse acc))
                    (loop (cons line acc))))))))))
  (and lines
       (> line-num 0)
       (<= line-num (vector-length lines))
       (vector-ref lines (sub1 line-num))))

;; --- fix-plan generator -----------------------------------------------------

(define (fix-plan-mode?)
  (and (getenv "BEAGLE_FIX_PLAN") #t))

(define (generate-fix-plan e src-line)
  (cond
    [(not (beagle-diagnostic? e)) #f]
    [else
     (define d (beagle-diagnostic-details e))
     (define kind (beagle-diagnostic-kind e))
     (cond
       ;; --- Arity: too few args (missing argument) ---
       [(and (eq? kind 'arity)
             (hash-ref d 'expected-arity #f)
             (< (hash-ref d 'actual-arity 0) (hash-ref d 'expected-arity 0)))
        (define fn-name (hash-ref d 'function ""))
        (define expected (hash-ref d 'expected-arity 0))
        (define actual (hash-ref d 'actual-arity 0))
        (define help (hash-ref d 'help ""))
        (hasheq 'confidence "high"
                'category "missing-argument"
                'fix-safety "local-behavior-change"
                'description (format "~a needs ~a arg(s), got ~a"
                                     fn-name expected actual)
                'fix-hint (format "Add the missing argument(s): ~a" help))]

       ;; --- Arity: too many args ---
       [(and (eq? kind 'arity)
             (hash-ref d 'expected-arity #f)
             (> (hash-ref d 'actual-arity 0) (hash-ref d 'expected-arity 0)))
        (define fn-name (hash-ref d 'function ""))
        (define expected (hash-ref d 'expected-arity 0))
        (define actual (hash-ref d 'actual-arity 0))
        (hasheq 'confidence "high"
                'category "extra-argument"
                'fix-safety "local-behavior-change"
                'description (format "~a takes ~a arg(s), got ~a — remove ~a arg(s)"
                                     fn-name expected actual (- actual expected))
                'fix-hint (format "Remove ~a extra argument(s) from the call"
                                  (- actual expected)))]

       ;; --- Structural reasoning over the typed details (MessageData) ---
       ;; The repair compiler reads the STRUCTURED expected/actual types, not
       ;; the prose: a same-constructor type whose type ARGUMENTS differ (e.g.
       ;; (Vec Int) vs (Vec String), or (Map String Int) vs (Map String Str))
       ;; is a precise, machine-actionable fix prose-matching could never
       ;; derive. Only fires when there's no more-specific accessor suggestion.
       [(and (memq kind '(type-mismatch return-type def-type let-binding))
             (null? (hash-ref d 'suggestions '()))
             (let ([et (hash-ref d 'expected-type #f)]
                   [at (hash-ref d 'actual-type #f)])
               (and (hash? et) (hash? at)
                    (equal? (hash-ref et 'kind #f) "app")
                    (equal? (hash-ref at 'kind #f) "app")
                    (equal? (hash-ref et 'ctor #f) (hash-ref at 'ctor #f))
                    (not (equal? (hash-ref et 'args #f) (hash-ref at 'args #f))))))
        (define et (hash-ref d 'expected-type))
        (define at (hash-ref d 'actual-type))
        (define ctor (hash-ref et 'ctor))
        (define (reprs j) (map (lambda (a) (hash-ref a 'repr "?")) (hash-ref j 'args '())))
        ;; The differing type-argument position(s) — NOT just the first arg, so
        ;; (Map String Int) vs (Map String String) blames the VALUE arg, not key.
        (define diffs
          (for/list ([e (in-list (reprs et))] [a (in-list (reprs at))]
                     #:unless (equal? e a))
            (cons e a)))
        (cond
          ;; Single type-argument differs AND the arg counts match — a clean
          ;; element conversion. (Differing arg counts are an arity mismatch on
          ;; the type ctor, not an element conversion; those fall to the else.)
          [(and (= (length (reprs et)) (length (reprs at)))
                (= 1 (length diffs)))
           (define exp-el (caar diffs)) (define act-el (cdar diffs))
           ;; index of the differing type argument (0-based)
           (define position
             (for/or ([e (in-list (reprs et))] [a (in-list (reprs at))] [i (in-naturals)]
                      #:unless (equal? e a))
               i))
           (hasheq 'confidence "medium"
                   'category "collection-element-type"
                   'fix-safety "type-directed"
                   'description (format "~a type argument differs: expected ~a, got ~a"
                                        ctor exp-el act-el)
                   'fix-hint (format "convert from ~a to ~a (e.g. map a ~a->~a conversion over the ~a)"
                                     act-el exp-el act-el exp-el ctor)
                   ;; structured, machine-consumable conversion data — agents and
                   ;; the out-of-process loop act on this directly instead of
                   ;; parsing the prose hint. from = what you have, to = what's
                   ;; needed, at type-argument `position` of `collection`.
                   'collection ctor
                   'position position
                   'from-type act-el
                   'to-type exp-el)]
          [else
           (hasheq 'confidence "medium"
                   'category "collection-type"
                   'fix-safety "type-directed"
                   'description (format "~a type arguments differ: expected ~a, got ~a"
                                        ctor (hash-ref et 'repr "?") (hash-ref at 'repr "?"))
                   'fix-hint (format "adjust so the ~a type matches ~a"
                                     ctor (hash-ref et 'repr "?"))
                   'collection ctor
                   ;; each differing position as {from = actual, to = expected}.
                   ;; No scalar from-type/to-type here: with multiple differing
                   ;; args there is no single conversion, so the consumer reads
                   ;; `diffs`, not a whole-type arrow.
                   'diffs (for/list ([d (in-list diffs)])
                            (hasheq 'from (cdr d) 'to (car d))))])]

       ;; --- Type mismatch with single "did you mean?" suggestion ---
       [(and (eq? kind 'type-mismatch)
             (pair? (hash-ref d 'suggestions '()))
             (= 1 (length (hash-ref d 'suggestions '()))))
        (define sugg (car (hash-ref d 'suggestions)))
        (define old (hash-ref sugg 'replace ""))
        (define new (hash-ref sugg 'with ""))
        (define new-sig (hash-ref sugg 'signature #f))
        (define before
          (and src-line (regexp-match (regexp-quote old) src-line)
               src-line))
        (define after
          (and before (string-replace before old new)))
        (hasheq 'confidence "high"
                'category "wrong-accessor"
                'fix-safety "type-directed"
                'description (format "Replace ~a with ~a" old new)
                'before (or before 'null)
                'after (or after 'null)
                'fix-hint (format "Replace `~a` with `~a`~a"
                                  old new
                                  (if new-sig (format " (~a)" new-sig) "")))]

       ;; --- Type mismatch with multiple suggestions ---
       [(and (eq? kind 'type-mismatch)
             (pair? (hash-ref d 'suggestions '()))
             (> (length (hash-ref d 'suggestions '())) 1))
        (define suggestions (hash-ref d 'suggestions))
        (define candidates
          (for/list ([s (in-list suggestions)])
            (format "~a (~a)"
                    (hash-ref s 'with "?")
                    (or (hash-ref s 'signature #f) "?"))))
        (hasheq 'confidence "medium"
                'category "wrong-accessor-multiple"
                'fix-safety "requires-human-review"
                'description "Multiple compatible replacements"
                'fix-hint (format "Replace with one of: ~a"
                                  (string-join candidates ", ")))]

       ;; --- Type mismatch with help text (constructor field swap, etc.) ---
       [(and (eq? kind 'type-mismatch)
             (hash-ref d 'help #f)
             (null? (hash-ref d 'suggestions '())))
        (define help-text (hash-ref d 'help ""))
        (define arg-sig (hash-ref d 'arg-signature #f))
        (hasheq 'confidence "medium"
                'category "type-mismatch"
                'fix-safety "requires-human-review"
                'description (exn-message e)
                'fix-hint help-text)]

       ;; --- Non-exhaustive match: the compiler already enumerated the exact
       ;; missing union cases AND their field arity (check.rkt raise site), so
       ;; it can hand back ready-to-insert clause skeletons. Throw-bodied
       ;; skeletons typecheck against any match result type, so this is
       ;; auto-applicable: insert the clauses, re-verify green, leaving
       ;; explicit unhandled-case throws for the agent to flesh out. ---
       [(and (eq? kind 'exhaustive-match)
             (pair? (hash-ref d 'fix-clauses '())))
        (define clauses (hash-ref d 'fix-clauses))
        (define missing (hash-ref d 'missing '()))
        (define union-name (hash-ref d 'union-name "?"))
        (hasheq 'confidence "high"
                'category "non-exhaustive-match"
                'fix-safety "adds-explicit-throw"
                'description (format "match on ~a is missing case(s): ~a"
                                     union-name (string-join missing ", "))
                'fix-hint (format "Insert ~a missing clause(s) before the match's closing paren: ~a"
                                  (length clauses) (string-join missing ", "))
                'clauses clauses
                'missing missing
                ;; the match form's line — the consumer balances parens from
                ;; here to find the insertion point (before the closing paren).
                'insert-line (or (hash-ref d 'error-line #f) 'null))]

       [else #f])]))

(define (format-fix-plan plan)
  (define out '())
  (define (emit s) (set! out (cons s out)))
  (define confidence (hash-ref plan 'confidence "?"))
  (define category (hash-ref plan 'category "?"))
  (define description (hash-ref plan 'description ""))
  (define fix-hint (hash-ref plan 'fix-hint ""))
  (define before (hash-ref plan 'before #f))
  (define after (hash-ref plan 'after #f))

  (emit (format "   fix [~a]: ~a" confidence fix-hint))
  (when (and before after
             (not (eq? before 'null))
             (not (eq? after 'null)))
    (emit (format "     before: ~a" (string-trim-right before)))
    (emit (format "     after:  ~a" (string-trim-right after))))
  (apply string-append
         (for/list ([ln (reverse out)])
           (string-append ln "\n"))))

;; --- Rust-style diagnostic formatter ----------------------------------------

(define (format-diagnostic e stx path)
  (define file (or (and stx
                        (let ([s (syntax-source stx)])
                          (cond [(path? s) (path->string s)]
                                [(string? s) s]
                                [else #f])))
                   path))
  (define stx-line (and stx (syntax-line stx)))

  (cond
    [(beagle-diagnostic? e)
     (define d (beagle-diagnostic-details e))
     (define kind (beagle-diagnostic-kind e))
     (define msg (exn-message e))

     ;; Prefer expression-level line/col from src-table over top-level form
     (define err-line (or (hash-ref d 'error-line #f) stx-line))
     (define err-col (hash-ref d 'error-col #f))
     (define err-file (or (hash-ref d 'error-file #f) file))

     (define code (hash-ref d 'error-code "E000"))

     (define out '())
     (define (emit s) (set! out (cons s out)))

     (emit (format "error[~a]: ~a" code msg))

     (when (and err-file err-line)
       (if err-col
           ;; rustc-style `-->` shows 1-based line AND column; src-loc-col is
           ;; 0-based (syntax-column), so add1 here. The JSON `col` stays
           ;; 0-based (its long-standing convention for tool consumers).
           (emit (format "  --> ~a:~a:~a" err-file err-line (add1 err-col)))
           (emit (format "  --> ~a:~a" err-file err-line)))
       (define src-line (read-source-line err-file err-line))
       (when src-line
         (define gw (string-length (number->string err-line)))
         (define pad (make-string gw #\space))
         (emit (format "~a |" pad))
         (emit (format "~a | ~a" err-line (string-trim-right src-line)))
         (emit (format "~a |" pad))))

     (define sig (hash-ref d 'signature #f))
     (when sig
       (emit (format "   = sig: ~a" sig)))

     (define arg-sig (hash-ref d 'arg-signature #f))
     (when (and arg-sig (not (eq? arg-sig 'null)))
       (emit (format "   = note: ~a" arg-sig)))

     (define suggestions (hash-ref d 'suggestions '()))
     (for ([s (in-list suggestions)])
       (define old (hash-ref s 'replace #f))
       (define new (hash-ref s 'with #f))
       (define new-sig (hash-ref s 'signature #f))
       (when (and old new)
         (if new-sig
             (emit (format "   = help: did you mean ~a? (~a)" new new-sig))
             (emit (format "   = help: did you mean ~a?" new)))))

     (define help (hash-ref d 'help #f))
     (when (and help (null? suggestions))
       (emit (format "   = help: ~a" help)))

     ;; Fix-plan output (when BEAGLE_FIX_PLAN is set)
     (when (fix-plan-mode?)
       (define src-line (and err-file err-line (read-source-line err-file err-line)))
       (define plan (generate-fix-plan e src-line))
       (when plan
         (emit (format-fix-plan plan))))

     (emit "")
     (apply string-append
            (for/list ([ln (reverse out)])
              (string-append ln "\n")))]

    [else
     (define loc
       (if (and file stx-line)
           (format "~a:~a" file stx-line)
           (or file path)))
     (format "  ~a: ~a\n" loc (exn-message e))]))

(define (string-trim-right s)
  (define len (string-length s))
  (let loop ([i len])
    (cond
      [(zero? i) ""]
      [(char-whitespace? (string-ref s (sub1 i))) (loop (sub1 i))]
      [else (substring s 0 i)])))

;; --- rich JSON formatter ----------------------------------------------------

(define (diagnostic->json e stx path)
  (define stx-file (or (and stx
                        (let ([s (syntax-source stx)])
                          (cond [(path? s) (path->string s)]
                                [(string? s) s]
                                [else #f])))
                   path))
  (define stx-line (and stx (syntax-line stx)))
  (define col (and stx (syntax-column stx)))

  (cond
    [(beagle-diagnostic? e)
     (define d (beagle-diagnostic-details e))
     (define error-line-raw (hash-ref d 'error-line #f))
     (define error-col-raw (hash-ref d 'error-col #f))
     (define error-file-raw (hash-ref d 'error-file #f))
     (define file (or error-file-raw stx-file))
     (define line (or error-line-raw stx-line))
     ;; Prefer the precise per-node column; fall back to whole-form col.
     (define ecol (or error-col-raw col))
     (define src-line (and file line (read-source-line file line)))
     (define base
       (hasheq 'schemaVersion 1
               'tool "beagle"
               'kind (symbol->string (beagle-diagnostic-kind e))
               'file (or file 'null)
               'line (or line 'null)
               'col (or ecol 'null)
               'message (exn-message e)
               'source_line (or src-line 'null)))
     (define with-details
       (for/fold ([h base]) ([(k v) (in-hash d)])
         (hash-set h (if (symbol? k) k (string->symbol k)) v)))
     (define plan (generate-fix-plan e src-line))
     (if plan
         (hash-set with-details 'fix_plan plan)
         with-details)]

    [(beagle-parse-error? e)
     ;; Structured parse-time rejection (raise-parse-error). Preserve its real
     ;; kind and fold its details — cause, phase, and crucially any
     ;; machine-applicable `suggestion` (e.g. replace-head) — into the JSON,
     ;; exactly as the beagle-diagnostic path does, so tools like beagle-repair
     ;; can auto-apply the fix instead of re-deriving it from prose. The bare
     ;; `else` below collapses these to a generic compile-error and drops both.
     (define d (beagle-parse-error-details e))
     (define src-line (and stx-file stx-line (read-source-line stx-file stx-line)))
     (define base
       (hasheq 'schemaVersion 1
               'tool "beagle"
               'kind (symbol->string (beagle-parse-error-kind e))
               'file (or stx-file 'null)
               'line (or stx-line 'null)
               'col (or col 'null)
               'message (exn-message e)
               'source_line (or src-line 'null)))
     (for/fold ([h base]) ([(k v) (in-hash d)])
       (hash-set h (if (symbol? k) k (string->symbol k)) v))]

    [else
     (define src-line (and stx-file stx-line (read-source-line stx-file stx-line)))
     (hasheq 'schemaVersion 1
             'tool "beagle"
             'kind "compile-error"
             'file (or stx-file 'null)
             'line (or stx-line 'null)
             'col (or col 'null)
             'message (exn-message e)
             'source_line (or src-line 'null))]))

;; --- batch checker ----------------------------------------------------------

;; An agent-error captures the essential fields for --agent summary output.
(struct agent-error (file line message) #:transparent)

(define (extract-agent-error e loc-stx path)
  (define file
    (or (and (beagle-diagnostic? e)
             (hash-ref (beagle-diagnostic-details e) 'error-file #f))
        (and loc-stx
             (let ([s (syntax-source loc-stx)])
               (cond [(path? s) (path->string s)]
                     [(string? s) s]
                     [else #f])))
        path))
  (define line
    (or (and (beagle-diagnostic? e)
             (hash-ref (beagle-diagnostic-details e) 'error-line #f))
        (and loc-stx (syntax-line loc-stx))))
  (define msg (exn-message e))
  ;; Strip the "beagle: " prefix for cleaner agent output
  (define clean-msg (regexp-replace #rx"^beagle: " msg ""))
  (agent-error file line clean-msg))

(define (basename path)
  (define parts (regexp-split #rx"/" path))
  (if (null? parts) path (last parts)))

(define (check-one-file path json?)
  (define agent? (agent-mode?))
  (define error-count 0)
  (define agent-errors '())
  (define lint-count 0)

  (define (report-error e loc-stx)
    (set! error-count (+ error-count 1))
    (cond
      [agent?
       (set! agent-errors (cons (extract-agent-error e loc-stx path) agent-errors))]
      [json?
       (write-json (diagnostic->json e loc-stx path) (current-error-port))
       (newline (current-error-port))
       (flush-output (current-error-port))]
      [else
       (display (format-diagnostic e loc-stx path) (current-error-port))]))

  (with-handlers
    ([exn:fail?
      (lambda (e) (report-error e #f))])
    (define stxs (read-beagle-syntax path))
    (define prog (parse-program stxs #:source-path path))

    ;; Extension/header mismatch check
    (define expected-tgt (expected-target-for-extension path))
    (when (and expected-tgt
               (not (eq? expected-tgt (program-target prog))))
      (define ext-str
        (car (findf (lambda (pair) (string-suffix? path (car pair)))
                    EXTENSION-TARGET-MAP)))
      (error (format "extension/header mismatch: ~a expects #lang beagle/~a, found #lang beagle/~a"
                     ext-str expected-tgt (program-target prog))))

    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (report-error e loc-stx)))

    ;; In agent mode, suppress notes/warnings from provenance and semantic
    ;; analysis — they go directly to stderr and would pollute agent output.
    ;; At profile 0 (parse only), skip all post-parse analysis.
    (when (>= (current-check-profile) 1)
      (if agent?
          (let ([sink (open-output-string)])
            (parameterize ([current-error-port sink])
              (check-scalar-provenance! prog)
              (run-semantic-analysis! prog #:file path))
            (set! lint-count (count-lint-warnings prog)))
          (begin
            (check-scalar-provenance! prog)
            (run-semantic-analysis! prog #:file path)))))

  (values error-count lint-count (reverse agent-errors)))

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? BEAGLE-FILE-RX a) (list a)]
          [else
           (eprintf "beagle-check-all: skipping non-beagle file: ~a\n" a)
           '()])))
    string<?))

(define (parse-profile-arg args)
  ;; Extract --profile N from args, return (values profile-level remaining-args).
  ;; Defaults to current-check-profile (which may be set via BEAGLE_CHECK_PROFILE env var).
  (let loop ([remaining args] [result '()] [profile (current-check-profile)])
    (cond
      [(null? remaining) (values profile (reverse result))]
      [(and (string=? (car remaining) "--profile")
            (pair? (cdr remaining)))
       (define n (string->number (cadr remaining)))
       (cond
         [(and n (exact-integer? n) (<= 0 n 3))
          (loop (cddr remaining) result n)]
         [else
          (eprintf "beagle-check-all: --profile must be 0, 1, 2, or 3\n")
          (exit 2)])]
      [else (loop (cdr remaining) (cons (car remaining) result) profile)])))

(define (run-check-all args)
  (when (null? args)
    (eprintf "usage: beagle-check-all [--profile 0|1|2|3] <file-or-dir> ...\n")
    (exit 2))

  (define-values (profile file-args) (parse-profile-arg args))
  (define files (expand-args file-args))

  (when (null? files)
    (eprintf "beagle-check-all: no beagle source files found\n")
    (exit 2))

  (define json? (json-error-mode?))
  (define agent? (agent-mode?))
  (define total-errors 0)
  (define total-lint 0)
  (define all-agent-errors '())

  (parameterize ([current-check-profile profile])
    (for ([f (in-list files)])
      (define-values (errs lints aerrs) (check-one-file f json?))
      (cond
        [(zero? errs)
         (unless (or json? agent?)
           (eprintf "  ~a ok\n" f))]
        [else
         (set! total-errors (+ total-errors errs))])
      (set! total-lint (+ total-lint lints))
      (set! all-agent-errors (append all-agent-errors aerrs))))

  (cond
    [agent?
     ;; Clean, minimal output for LLM agent consumption
     (define lint-note
       (if (> total-lint 0)
           (format " (~a lint warning~a hidden)"
                   total-lint (if (= total-lint 1) "" "s"))
           ""))
     (cond
       [(zero? total-errors)
        (eprintf "0 errors~a\n" lint-note)]
       [else
        (eprintf "~a error~a\n"
                 total-errors
                 (if (= total-errors 1) "" "s"))
        (for ([ae (in-list all-agent-errors)])
          (define loc
            (cond
              [(and (agent-error-file ae) (agent-error-line ae))
               (format "~a:~a" (basename (agent-error-file ae)) (agent-error-line ae))]
              [(agent-error-file ae) (basename (agent-error-file ae))]
              [else "?"]))
          (eprintf "- ~a ~a\n" loc (agent-error-message ae)))
        (when (> total-lint 0)
          (eprintf "\n~a lint warning~a hidden (run without --agent to see)\n"
                   total-lint
                   (if (= total-lint 1) "" "s")))])]
    [else
     (unless json?
       (eprintf "\n~a file(s), ~a error(s)\n" (length files) total-errors))])

  (exit (if (zero? total-errors) 0 1)))

(provide run-check-all generate-fix-plan diagnostic->json)
