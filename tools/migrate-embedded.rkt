#!/usr/bin/env racket
#lang racket/base
;; migrate-embedded.rkt — migrate beagle source that lives INSIDE host string
;; literals (.rkt / .py / .edn / .rktd) to the postfix annotation surface.
;;
;; Edits are computed on the DECODED payload and mapped back through a
;; per-char offset map onto the raw escaped span, so nothing is re-encoded;
;; each literal is then re-decoded and the whole file re-`read` as datums,
;; where the only permitted change is a string leaf equal to migrate(old).

(require racket/string
         racket/list
         racket/port
         racket/format
         "migrate-annotations.rkt")

;; ---------------------------------------------------------------------------
;; Decoded payload + offset map
;; ---------------------------------------------------------------------------

;; content : string (decoded)
;; map     : vector of raw offsets, length (add1 (string-length content));
;;           map[i] = raw offset where decoded char i begins, map[n] = raw end.
(struct decoded (content map) #:transparent)

(define simple-escapes
  (hash #\n #\newline #\t #\tab #\r #\return #\\ #\\ #\" #\"
        #\' #\' #\a #\u7 #\b #\backspace #\f #\page #\v #\vtab #\e #\u1B))

;; Decode a string-literal BODY span [start,end) of `raw`; #f when an escape
;; outside `simple-escapes` appears (\x \u \U octal \<newline> are refused,
;; never guessed).
(define (decode-body raw start end)
  (define out (open-output-string))
  (define offs (make-vector (add1 (- end start)) 0))
  (let loop ([i start] [n 0])
    (cond
      [(>= i end)
       (vector-set! offs n end)
       (decoded (get-output-string out)
                (for/vector ([k (in-range (add1 n))]) (vector-ref offs k)))]
      [(char=? (string-ref raw i) #\\)
       (define c (and (< (add1 i) end)
                      (hash-ref simple-escapes (string-ref raw (add1 i)) #f)))
       (cond
         [c (vector-set! offs n i)
            (write-char c out)
            (loop (+ i 2) (add1 n))]
         [else #f])]
      [else
       (vector-set! offs n i)
       (write-char (string-ref raw i) out)
       (loop (add1 i) (add1 n))])))

;; Shell heredoc bodies are raw: no host escaping layer at all.
(define (decode-raw-body raw start end)
  (decoded (substring raw start end)
           (for/vector ([i (in-range start (add1 end))]) i)))

;; ---------------------------------------------------------------------------
;; String-literal location — host-language scanners
;; ---------------------------------------------------------------------------

;; lit: body span [start,end) inside `raw`, plus the decoder for that host syntax.
(struct lit (start end [decode #:auto #:mutable]) #:transparent)
(define (lit* start end dec)
  (define l (lit start end)) (set-lit-decode! l dec) l)

;; Racket source scanner: skips ; line comments, #| |# block comments (nested),
;; #\c character literals (including #\"), and #<<HEREDOC bodies.
(define (racket-literals raw)
  (define n (string-length raw))
  (define acc '())
  (let loop ([i 0])
    (when (< i n)
      (define c (string-ref raw i))
      (cond
        [(char=? c #\;)
         (let skip ([j i])
           (cond [(or (>= j n) (char=? (string-ref raw j) #\newline)) (loop (add1 j))]
                 [else (skip (add1 j))]))]
        [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref raw (add1 i)) #\|))
         (let skip ([j (+ i 2)] [depth 1])
           (cond
             [(>= j n) (loop j)]
             [(and (< (add1 j) n) (char=? (string-ref raw j) #\#) (char=? (string-ref raw (add1 j)) #\|))
              (skip (+ j 2) (add1 depth))]
             [(and (< (add1 j) n) (char=? (string-ref raw j) #\|) (char=? (string-ref raw (add1 j)) #\#))
              (if (= depth 1) (loop (+ j 2)) (skip (+ j 2) (sub1 depth)))]
             [else (skip (add1 j) depth)]))]
        [(and (char=? c #\#) (< (add1 i) n) (char=? (string-ref raw (add1 i)) #\\))
         ;; #\c or #\newline etc. — consume the backslash and at least one char,
         ;; then any following alphabetic run (named characters).
         (let skip ([j (+ i 3)])
           (cond [(and (< j n) (char-alphabetic? (string-ref raw j))) (skip (add1 j))]
                 [else (loop j)]))]
        [(and (char=? c #\#) (< (+ i 2) n)
              (char=? (string-ref raw (add1 i)) #\<) (char=? (string-ref raw (+ i 2)) #\<))
         ;; here-string: #<<TAG\n ... \nTAG\n — payload is not a normal literal.
         (define nl (or (for/first ([j (in-range (+ i 3) n)]
                                    #:when (char=? (string-ref raw j) #\newline)) j)
                        n))
         (define tag (substring raw (+ i 3) nl))
         (define close (regexp-match-positions (regexp (string-append "\n" (regexp-quote tag) "\n"))
                                               raw nl))
         (loop (if close (cdar close) n))]
        [(char=? c #\")
         (let scan ([j (add1 i)])
           (cond
             [(>= j n) (loop j)]
             [(char=? (string-ref raw j) #\\) (scan (+ j 2))]
             [(char=? (string-ref raw j) #\") (set! acc (cons (lit (add1 i) j) acc)) (loop (add1 j))]
             [else (scan (add1 j))]))]
        [else (loop (add1 i))])))
  (reverse acc))

;; EDN / .rktd: same shape as Racket minus here-strings; reuse the Racket scanner
;; (`;` comments and `\"` escapes match; `#\c` is also valid Clojure/EDN).
(define edn-literals racket-literals)

;; Python: ''' """ ... """ and '...' "..." with # line comments.
(define (python-literals raw)
  (define n (string-length raw))
  (define acc '())
  (let loop ([i 0])
    (when (< i n)
      (define c (string-ref raw i))
      (cond
        [(char=? c #\#)
         (let skip ([j i])
           (cond [(or (>= j n) (char=? (string-ref raw j) #\newline)) (loop (add1 j))]
                 [else (skip (add1 j))]))]
        [(or (char=? c #\") (char=? c #\'))
         (define triple? (and (< (+ i 2) n)
                              (char=? (string-ref raw (add1 i)) c)
                              (char=? (string-ref raw (+ i 2)) c)))
         (define qlen (if triple? 3 1))
         (define body-start (+ i qlen))
         (let scan ([j body-start])
           (cond
             [(>= j n) (loop j)]
             [(char=? (string-ref raw j) #\\) (scan (+ j 2))]
             [(and (char=? (string-ref raw j) c)
                   (or (not triple?)
                       (and (< (+ j 2) n)
                            (char=? (string-ref raw (add1 j)) c)
                            (char=? (string-ref raw (+ j 2)) c))))
              (set! acc (cons (lit body-start j) acc))
              (loop (+ j qlen))]
             [else (scan (add1 j))]))]
        [else (loop (add1 i))])))
  (reverse acc))

;; Shell heredoc bodies: `<<TAG` / `<<'TAG'` / `<<-TAG` to a line holding only
;; TAG. The body is raw text, so the offset map is the identity.
(define (shell-heredoc-spans raw)
  (for/list ([m (in-list (regexp-match-positions*
                          #px"<<-?[ ]*'?([A-Za-z_][A-Za-z0-9_]*)'?[ \t]*\r?\n"
                          raw
                          #:match-select values))]
             #:when #t
             #:do [(define body-start (cdar m))
                   (define tag (substring raw (car (cadr m)) (cdr (cadr m))))
                   (define close (regexp-match-positions
                                  (pregexp (string-append "\n[ \t]*" (regexp-quote tag) "[ \t]*\r?\n"))
                                  raw body-start))]
             #:when close)
    (cons body-start (caar close))))

;; Shell: heredoc bodies (raw) plus the single-quoted payload of `printf` and
;; of a `VAR=\'…\'` assignment. Anchoring on those two producers instead of
;; scanning every quote keeps one stray apostrophe from inverting the phase.
(define (group-spans rx raw)
  (for/list ([m (in-list (regexp-match-positions* rx raw #:match-select values))])
    (cadr m)))

(define (shell-literals raw)
  (define heredocs (shell-heredoc-spans raw))
  (define (in-heredoc? i)
    (for/or ([h (in-list heredocs)]) (and (>= i (car h)) (< i (cdr h)))))
  (append
   (for/list ([h (in-list heredocs)]) (lit* (car h) (cdr h) decode-raw-body))
   (for/list ([g (in-list (group-spans #px"printf[ \t]+'([^']*)'" raw))]
              #:unless (in-heredoc? (car g)))
     (lit* (car g) (cdr g) decode-body))
   (for/list ([g (in-list (group-spans #px"[A-Za-z_][A-Za-z0-9_]*='([^']*)'" raw))]
              #:unless (in-heredoc? (car g)))
     (lit* (car g) (cdr g) decode-raw-body))))

;; ---------------------------------------------------------------------------
;; Candidate filter + per-literal migration
;; ---------------------------------------------------------------------------

;; A marker is a FREESTANDING `:-`/`:` token; `:kw` and nix `x:` never match.
(define (has-marker? s)
  (regexp-match? #px"(^|[\\s(\\[{])(:-|:)([\\s)\\]}]|$)" s))

(define (beagle-payload? s)
  (and (has-marker? s)
       (regexp-match? #px"\\((defn?-?|defonce|defrecord|defunion|defprotocol|ns|let|loop|fn|extend-type|extend-protocol|reify|letfn|defmacro)[\\s(\\[]" s)))

;; Returns (values raw-edits note) — raw-edits are `edit` structs over the whole
;; file; note is #f on success or a string explaining the refusal.
(define (migrate-literal raw l decode)
  (define d (decode raw (lit-start l) (lit-end l)))
  (cond
    [(not d) (values '() "unhandled escape sequence in literal")]
    [(not (beagle-payload? (decoded-content d))) (values '() #f)]
    [else
     (define content (decoded-content d))
     (define-values (new-content edits refusals reports)
       (with-handlers ([exn:fail? (lambda (e) (values #f '() '() '()))])
         (migrate-source-text content #:require-balanced? #f)))
     (cond
       [(not new-content) (values '() "CST round-trip failed on decoded payload")]
       [(pair? refusals)
        (values '() (format "classifier refused ~a site(s): ~a"
                            (length refusals) (refusal-reason (car refusals))))]
       [(null? edits) (values '() #f)]
       [else
        (define m (decoded-map d))
        (define raw-edits
          (for/list ([e (in-list edits)])
            (edit (vector-ref m (edit-start e))
                  (vector-ref m (edit-end e))
                  (edit-replacement e))))
        ;; Local proof: re-decode the rewritten raw span, require it to equal
        ;; the migrated payload byte-for-byte.
        (define spliced (splice raw raw-edits))
        (define delta (- (string-length spliced) (string-length raw)))
        (define d2 (decode spliced (lit-start l) (+ (lit-end l) delta)))
        (cond
          [(and d2 (string=? (decoded-content d2) new-content))
           (values raw-edits #f)]
          [else (values '() "re-decode of rewritten literal did not match")])])]))

(define (splice source edits)
  (define sorted (sort edits < #:key edit-start))
  (define out (open-output-string))
  (define pos
    (for/fold ([pos 0]) ([e (in-list sorted)])
      (when (< (edit-start e) pos)
        (error 'migrate-embedded "overlapping edits at ~a" (edit-start e)))
      (write-string (substring source pos (edit-start e)) out)
      (write-string (edit-replacement e) out)
      (edit-end e)))
  (write-string (substring source pos) out)
  (get-output-string out))

;; ---------------------------------------------------------------------------
;; Whole-file datum-level verification (Racket / .rktd only)
;; ---------------------------------------------------------------------------

(define (read-all-datums text)
  (parameterize ([read-accept-reader #t]
                 [read-accept-lang #t])
    (define in (open-input-string text))
    (let loop ([acc '()])
      (define d (read in))
      (if (eof-object? d) (reverse acc) (loop (cons d acc))))))

;; Walk two datum trees; shape must be identical, differing ATOMIC leaves are
;; collected as (old . new). 'structural-mismatch when the shape moved at all.
(define (datum-leaf-diffs a b [node-rewrite? (lambda (a b) #f)])
  (define diffs '())
  (define ok?
    (let walk ([a a] [b b])
      (cond
        [(node-rewrite? a b) (set! diffs (cons (cons a b) diffs)) #t]
        [(and (pair? a) (pair? b)) (and (walk (car a) (car b)) (walk (cdr a) (cdr b)))]
        [(and (vector? a) (vector? b) (= (vector-length a) (vector-length b)))
         (for/and ([x (in-vector a)] [y (in-vector b)]) (walk x y))]
        [(and (box? a) (box? b)) (walk (unbox a) (unbox b))]
        [(or (pair? a) (pair? b) (vector? a) (vector? b) (box? a) (box? b)) #f]
        [else (unless (equal? a b) (set! diffs (cons (cons a b) diffs))) #t])))
  (if ok? (reverse diffs) 'structural-mismatch))

(define (with-read-datums old new k [node-rewrite? (lambda (a b) #f)])
  ;; k : diffs -> (or #f explanation); returns an explanation string or #f.
  (define d
    (with-handlers ([exn:fail? (lambda (e) (cons 'unreadable (exn-message e)))])
      (datum-leaf-diffs (read-all-datums old) (read-all-datums new) node-rewrite?)))
  (cond
    [(and (pair? d) (eq? (car d) 'unreadable))
     (format "datum verification failed: ~a" (cdr d))]
    [(eq? d 'structural-mismatch) "datum tree shape changed"]
    [else (k d)]))

(define (verify-file-datums old new)
  ;; String-payload mode: only string leaves may move, each to its migration.
  (with-read-datums old new
    (lambda (d)
      (define bad
        (for/list ([p (in-list d)]
                   #:unless (and (string? (car p)) (string? (cdr p))
                                 (let-values ([(nc _e _r _rp)
                                               (with-handlers ([exn:fail? (lambda (e) (values #f '() '() '()))])
                                                 (migrate-source-text (car p) #:require-balanced? #f))])
                                   (and nc (string=? nc (cdr p))))))
          p))
      (and (pair? bad)
           (format "~a changed leaf(s) are not the migration of the original; first: ~s -> ~s"
                   (length bad) (car (first bad)) (cdr (first bad)))))))

(define ANN-TAG (string->symbol "#%:"))

;; `':-` in evaluated position becomes the identifier ANN-MARKER — a node
;; rewrite, not a leaf rewrite, so the walker needs it whitelisted by shape.
(define (quoted-marker->ann-marker? a b)
  (and (pair? a) (eq? (car a) 'quote) (pair? (cdr a)) (null? (cddr a))
       (memq (cadr a) '(:- :))
       (eq? b 'ANN-MARKER)))

(define (verify-file-datum-markers old new expected-count)
  ;; Datum mode: only the marker symbols may move, and only to the reader tag
  ;; or `->`; the count must match the edits the classifier planned.
  (with-read-datums old new
    (lambda (d)
      (define bad
        (for/list ([p (in-list d)]
                   #:unless (or (quoted-marker->ann-marker? (car p) (cdr p))
                                (and (memq (car p) '(:- :))
                                     (memq (cdr p) (list '-> ANN-TAG)))))
          p))
      (cond
        [(pair? bad)
         (format "~a changed leaf(s) are not a marker migration; first: ~s -> ~s"
                 (length bad) (car (first bad)) (cdr (first bad)))]
        [(not (= (length d) expected-count))
         (format "planned ~a edit(s) but ~a datum leaf(s) moved" expected-count (length d))]
        [else #f]))
    quoted-marker->ann-marker?))

;; ---------------------------------------------------------------------------
;; Driver
;; ---------------------------------------------------------------------------

(define (path-ext p)
  (define m (regexp-match #rx"\\.([a-zA-Z0-9]+)$" (if (path? p) (path->string p) p)))
  (and m (string-downcase (cadr m))))

(define (literal-finder ext)
  (case ext
    [("rkt") (cons racket-literals decode-body)]
    [("rktd" "edn") (cons edn-literals decode-body)]
    [("py") (cons python-literals decode-body)]
    [("sh" "bash") (cons shell-literals #f)]
    [else #f]))

(define (process! path check?)
  (define ext (path-ext path))
  (define find (literal-finder ext))
  (unless find (error 'migrate-embedded "unsupported extension: ~a" path))
  (define raw (call-with-input-file path port->string))
  (define lits ((car find) raw))
  (define all-edits '())
  (define notes '())
  (for ([l (in-list lits)])
    (define-values (es note) (migrate-literal raw l (or (lit-decode l) (cdr find))))
    (when note
      (set! notes (cons (cons l note) notes)))
    (set! all-edits (append es all-edits)))
  (define new (if (null? all-edits) raw (splice raw all-edits)))
  (define problem (and (not (null? all-edits))
                       (memq (string->symbol (or ext "")) '(rkt rktd edn))
                       (verify-file-datums raw new)))
  (for ([n (in-list (reverse notes))])
    (eprintf "~a: SKIPPED literal at offset ~a: ~a\n" path (lit-start (car n)) (cdr n)))
  (cond
    [problem
     (eprintf "~a: VERIFY FAILED: ~a — nothing written\n" path problem)
     (values 0 1)]
    [(null? all-edits) (printf "~a: no embedded edits\n" path) (values 0 (length notes))]
    [check?
     (printf "~a: ~a embedded edit(s) planned (verified)\n" path (length all-edits))
     (values (length all-edits) (length notes))]
    [else
     (call-with-output-file path #:exists 'truncate/replace
       (lambda (o) (write-string new o)))
     (printf "~a: rewrote ~a embedded edit(s) (verified)\n" path (length all-edits))
     (values (length all-edits) (length notes))]))

;; Racket-quoted beagle datums in a host .rkt file: `'(def x :- Int 42)` →
;; `'(def x #%: Int 42)`. The classifier runs over the whole host file (the
;; beagle CST is a superset of the s-expression shape it needs); every claim it
;; makes is then re-checked at the Racket datum level, so a tokenizer that
;; mis-read a Racket-only lexeme fails the file instead of corrupting it.
(define (process-datums! path check?)
  (define raw (call-with-input-file path port->string))
  (define-values (new edits refusals reports)
    (with-handlers ([exn:fail? (lambda (e) (values #f '() '() '()))])
      (parameterize ([migrate-mode 'datum])
        (migrate-source-text raw #:require-balanced? #t))))
  (for ([r (in-list refusals)])
    (eprintf "~a:~a: REFUSED (~a): ~a\n" path (refusal-line r) (refusal-reason r) (refusal-before r)))
  (cond
    [(not new)
     (eprintf "~a: classifier aborted (CST round-trip or balance) — nothing written\n" path)
     (values 0 1)]
    [(null? edits) (printf "~a: no datum edits\n" path) (values 0 (length refusals))]
    [else
     (define problem (verify-file-datum-markers raw new (length edits)))
     (cond
       [problem
        (eprintf "~a: VERIFY FAILED: ~a — nothing written\n" path problem)
        (values 0 1)]
       [check?
        (printf "~a: ~a datum edit(s) planned (verified)\n" path (length edits))
        (values (length edits) (length refusals))]
       [else
        (call-with-output-file path #:exists 'truncate/replace
          (lambda (o) (write-string new o)))
        (printf "~a: rewrote ~a datum edit(s) (verified)\n" path (length edits))
        (values (length edits) (length refusals))])]))

(module+ main
  (define check? #f)
  (define datums? #f)
  (define paths '())
  (for ([a (in-list (vector->list (current-command-line-arguments)))])
    (cond [(equal? a "--check") (set! check? #t)]
          [(equal? a "--datums") (set! datums? #t)]
          [else (set! paths (cons a paths))]))
  (define fails 0)
  (for ([p (in-list (reverse paths))])
    (define-values (e n) (if datums? (process-datums! p check?) (process! p check?)))
    (set! fails (+ fails n)))
  (when (> fails 0)
    (eprintf "\n~a literal(s) skipped or failed verification\n" fails)))
