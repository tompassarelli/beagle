#!/usr/bin/env racket
#lang racket/base
;; migrate-annotations.rkt — layout-preserving rewrite of beagle's inline
;; annotation markers (`:-`/legacy `:`) to `NAME: TYPE` / `-> RET`, built on
;; the repo's own tokenizer/CST so keywords/strings/comments are never touched.
;; Host files (.rkt/.py/.rktd/.edn) with embedded beagle-source string
;; literals are scanned and REPORTED only, never auto-rewritten inside a
;; string — cross-language escape round-tripping is out of scope this pass.

(require racket/string
         racket/list
         racket/port
         racket/path
         racket/format
         "../beagle-lib/private/syntax/tokenize.rkt"
         "../beagle-lib/private/syntax/cst.rkt"
         "../beagle-lib/private/syntax/scan.rkt")

;; migrate-embedded.rkt reuses the classifier over string-literal payloads,
;; which are fragments — hence #:require-balanced?.
(provide migrate-source-text migrate-mode (struct-out edit) (struct-out refusal))

;; 'source fuses `NAME :- T` into surface text `NAME: T`; 'datum leaves layout
;; alone and writes the reader tag `#%:` the beagle reader itself produces,
;; which is what a Racket-quoted test datum has to spell.
(define migrate-mode (make-parameter 'source))

;; ---------------------------------------------------------------------------
;; CLI
;; ---------------------------------------------------------------------------

(define (usage)
  (displayln "usage: migrate-annotations.rkt [--check] [--verbose] PATH...")
  (displayln "")
  (displayln "  --check     dry run: report planned edits, write nothing")
  (displayln "  --verbose   also print accepted (non-refused) edits in --check mode")
  (displayln "  --help      this message")
  (displayln "")
  (displayln "Rewrites the old `NAME :- TYPE` / legacy `NAME : TYPE` binder marker to")
  (displayln "`NAME: TYPE`, and the old `[params] :- RET` / legacy `[params] : RET`")
  (displayln "return marker to `[params] -> RET`, in beagle source files.")
  (displayln "")
  (displayln "Host files (.rkt/.py/.rktd/.edn holding embedded beagle source in string")
  (displayln "literals) are only SCANNED for candidate embedded regions and reported —")
  (displayln "never auto-rewritten inside a string literal.")
  (exit 0))

(define beagle-source-exts '("bgl" "bclj" "bnix" "bjs" "bsc" "bzig"))
(define host-scan-exts '("rkt" "py" "rktd" "edn"))

(define (path-ext p)
  (define-values (base name dir?) (split-path p))
  (define s (if (path? name) (path->string name) ""))
  (define m (regexp-match #rx"\\.([a-zA-Z0-9]+)$" s))
  (and m (string-downcase (cadr m))))

(define (walk-paths paths)
  ;; Returns list of file paths (strings), recursing into directories.
  (append-map
   (lambda (p)
     (cond
       [(directory-exists? p)
        (for/list ([f (in-directory p)]
                   #:when (and (file-exists? f)
                                (let ([e (path-ext f)])
                                  (and e (or (member e beagle-source-exts)
                                             (member e host-scan-exts))))))
          (path->string f))]
       [(file-exists? p) (list p)]
       [else
        (eprintf "warning: not found, skipping: ~a\n" p)
        '()]))
   paths))

;; ---------------------------------------------------------------------------
;; Edit / refusal records
;; ---------------------------------------------------------------------------

;; edit: start/end are 0-based char offsets into the file's full text;
;; replacement is the literal new text for that span.
(struct edit (start end replacement) #:transparent)

;; report: display-only occurrence record for --check (wider context than
;; the raw sub-edits so `BEFORE -> AFTER` reads as the whole name/type span).
(struct report (line before after) #:transparent)

;; refusal: reported to stderr / --check output, never applied.
(struct refusal (line col before reason) #:transparent)

;; ---------------------------------------------------------------------------
;; Core classifier: walk a CST, find marker atoms (`:` or `:-`), classify by
;; structural position, and emit edits or refusals.
;; ---------------------------------------------------------------------------

(define (marker-text? s)
  (or (string=? s ":") (string=? s ":-")))

(define (node-start n)
  (cond
    [(cst-atom? n) (token-offset (cst-atom-tok n))]
    [(cst-list? n) (token-offset (cst-list-opener n))]
    [(cst-comment? n) (token-offset (cst-comment-tok n))]
    [(cst-ws? n) (token-offset (cst-ws-tok n))]
    [else #f]))

(define (node-end n)
  (cond
    [(cst-atom? n)
     (define tok (cst-atom-tok n))
     (+ (token-offset tok) (string-length (token-text tok)))]
    [(cst-list? n)
     (cond
       [(cst-list-closer n)
        (define tok (cst-list-closer n))
        (+ (token-offset tok) (string-length (token-text tok)))]
       [(pair? (cst-list-children n))
        (node-end (last (cst-list-children n)))]
       [else
        (define tok (cst-list-opener n))
        (+ (token-offset tok) (string-length (token-text tok)))])]
    [(cst-comment? n)
     (define tok (cst-comment-tok n))
     (+ (token-offset tok) (string-length (token-text tok)))]
    [(cst-ws? n)
     (define tok (cst-ws-tok n))
     (+ (token-offset tok) (string-length (token-text tok)))]
    [else #f]))

(define (node-line n)
  (cond
    [(cst-atom? n) (token-line (cst-atom-tok n))]
    [(cst-list? n) (token-line (cst-list-opener n))]
    [else #f]))

(define (node-col n)
  (cond
    [(cst-atom? n) (token-col (cst-atom-tok n))]
    [(cst-list? n) (token-col (cst-list-opener n))]
    [else #f]))

(define (open-bracket-list? n)
  (and (cst-list? n)
       (eq? (token-type (cst-list-opener n)) 'open-bracket)))

;; Any cst-comment strictly between raw indices lo..hi (exclusive) of children?
(define (comment-between? children lo hi)
  (for/or ([i (in-range (add1 lo) hi)])
    (cst-comment? (list-ref children i))))

(define (atom-text n)
  (and (cst-atom? n) (token-text (cst-atom-tok n))))

(define (prefix-atom? n)
  (and (member (atom-text n) '("'" "`" "," ",@" "#'")) #t))

;; Datum mode only: a marker whose neighbours are Racket constructor calls or
;; quote prefixes rather than beagle brackets. `def`/`defonce` is the one head
;; whose paren-list child is a binder target ((def (#%meta …) :- T v)); every
;; other paren list in that slot is a param vector, so the marker is a return.
(define (datum-classify prev-node head-text prev-unquoted?)
  (cond
    [(open-bracket-list? prev-node) 'return]
    ;; `(defn f ,params :- R …)` — an unquoted param vector, not a binder name.
    [(and prev-unquoted? (member head-text '("defn" "defn-" "fn" "letfn"))) 'return]
    [(cst-atom? prev-node) 'binder]
    [(cst-list? prev-node) (if (member head-text '("def" "defonce")) 'binder 'return)]
    [else #f]))

;; Walk one list's raw `children` (a list of cst nodes), classifying every
;; marker atom that is a direct content-child, and recursing into nested
;; lists. Appends to the boxes `edits` and `refusals`.
(define (scan-children! children source edits refusals reports [head-text #f])
  (define cv (list->vector children))
  (define n (vector-length cv))
  ;; raw indices of content children (atoms/lists), in order
  (define content-idxs
    (for/list ([i (in-range n)]
               #:when (or (cst-atom? (vector-ref cv i))
                          (cst-list? (vector-ref cv i))))
      i))
  (define civ (list->vector content-idxs))
  (define cn (vector-length civ))

  ;; head of THIS list, skipping reader prefixes — the datum classifier's tie-break
  (define own-head
    (for/first ([p (in-range cn)]
                #:unless (prefix-atom? (vector-ref cv (vector-ref civ p))))
      (atom-text (vector-ref cv (vector-ref civ p)))))

  ;; walk back from content position `pos` over reader-prefix atoms
  (define (content-back pos)
    (let loop ([p (sub1 pos)])
      (cond [(< p 0) #f]
            [(prefix-atom? (vector-ref cv (vector-ref civ p))) (loop (sub1 p))]
            [else p])))

  (for ([pos (in-range cn)])
    (define i (vector-ref civ pos))
    (define node (vector-ref cv i))
    (cond
      [(cst-list? node)
       ;; Recurse into nested list regardless of whether it holds markers.
       (scan-children! (cst-list-children node) source edits refusals reports own-head)]
      [(and (cst-atom? node) (marker-text? (token-text (cst-atom-tok node))))
       (define marker-line (node-line node))
       (define marker-col (node-col node))
       (define marker-start (node-start node))
       (define marker-end (node-end node))
       (define before-ctx
         (substring source (max 0 (- marker-start 24)) (min (string-length source) (+ marker-end 24))))
       (define (refuse! reason)
         (set-box! refusals (cons (refusal marker-line marker-col before-ctx reason)
                                   (unbox refusals))))
       (cond
         [(= pos 0)
          (refuse! "marker has no preceding token in this list — cannot classify binder-vs-return")]
         [else
          (define prev-i (vector-ref civ (sub1 pos)))
          (define prev-node (vector-ref cv prev-i))
          (define next-i (and (< (add1 pos) cn) (vector-ref civ (add1 pos))))
          (define next-node (and next-i (vector-ref cv next-i)))
          (cond
            ;; DATUM mode owns its own classification end-to-end: Racket-quoted
            ;; beagle datums have no bracket tags and wear reader prefixes.
            [(eq? (migrate-mode) 'datum)
             (define back (content-back pos))
             (define real-prev (and back (vector-ref cv (vector-ref civ back))))
             (define pfx? (prefix-atom? prev-node))
             (define prev-unquoted?
               (and back
                    (let ([j (vector-ref civ back)])
                      (and (> j 0)
                           (member (atom-text (vector-ref cv (sub1 j))) '("," ",@"))
                           #t))))
             (define kind (and real-prev (datum-classify real-prev own-head prev-unquoted?)))
             (define start (if pfx? (node-start prev-node) marker-start))
             (cond
               [(not next-node) (refuse! "marker with no following type")]
               [(not kind) (refuse! "cannot classify binder-vs-return in datum mode")]
               [else
                (define replacement
                  (case kind
                    [(return) (if pfx? "'->" "->")]
                    ;; evaluated (quoted) binder site: name the export, not the tag
                    [else (if pfx? "ANN-MARKER" "#%:")]))
                (set-box! edits (cons (edit start marker-end replacement) (unbox edits)))
                (define ctx-start (node-start real-prev))
                (define ctx-end (node-end next-node))
                (set-box! reports
                          (cons (report marker-line
                                        (substring source ctx-start ctx-end)
                                        (string-append (substring source ctx-start start)
                                                       replacement
                                                       (substring source marker-end ctx-end)))
                                (unbox reports)))])]
            ;; RETURN position: previous content sibling is a closed `[...]`
            ;; vector (a param list / binder list) — becomes `->`.
            [(open-bracket-list? prev-node)
             (cond
               [(not next-node)
                (refuse! "return-position marker with no following return type")]
               [else
                (set-box! edits (cons (edit marker-start marker-end "->") (unbox edits)))
                (define ctx-start (node-start prev-node))
                (define ctx-end (node-end next-node))
                (define before (substring source ctx-start ctx-end))
                (define after (string-append (substring source ctx-start marker-start)
                                              "->"
                                              (substring source marker-end ctx-end)))
                (set-box! reports (cons (report marker-line before after) (unbox reports)))])]
            ;; BINDER position: previous content sibling is a bare atom (a name)
            ;; — becomes a fused trailing colon `NAME:`.
            [(cst-atom? prev-node)
             (define prev-text (token-text (cst-atom-tok prev-node)))
             (cond
               [(marker-text? prev-text)
                (refuse! "back-to-back markers — malformed or unrecognized construct")]
               [(member prev-text '("'" "`" "," ",@"))
                (refuse! "marker preceded by a quote/unquote reader-prefix atom, not a name — likely a quoted keyword datum, not an annotation site")]
               [(not next-node)
                (refuse! "binder-position marker with no following type")]
               [(comment-between? children prev-i i)
                (refuse! "comment between name and marker — cannot safely collapse whitespace")]
               [(comment-between? children i next-i)
                (refuse! "comment between marker and type — cannot safely collapse whitespace")]
               [else
                (define name-end (node-end prev-node))
                ;; Fuse the name to the marker: delete any whitespace between
                ;; name and marker, replace marker text with a bare `:`.
                (set-box! edits (cons (edit name-end marker-end ":") (unbox edits)))
                ;; Normalize whitespace between marker and type to exactly one
                ;; space (only if it differs — keeps the edit list minimal).
                (define ws-start marker-end)
                (define ws-end (node-start next-node))
                (define existing-ws (substring source ws-start ws-end))
                (unless (string=? existing-ws " ")
                  (set-box! edits (cons (edit ws-start ws-end " ") (unbox edits))))
                (define ctx-start (node-start prev-node))
                (define ctx-end (node-end next-node))
                (define before (substring source ctx-start ctx-end))
                (define after (string-append prev-text ": " (substring source ws-end ctx-end)))
                (set-box! reports (cons (report marker-line before after) (unbox reports)))])]
            [else
             (refuse! (format "marker follows an unrecognized construct (~a) — cannot classify binder-vs-return"
                               (cond [(cst-list? prev-node) "non-bracket list"]
                                     [else "unknown node"])))])])])))

;; ---------------------------------------------------------------------------
;; Apply edits to source text
;; ---------------------------------------------------------------------------

(define (apply-edits source edits)
  (define sorted (sort edits < #:key edit-start))
  ;; Assert non-overlap (defensive — should never trip given the classifier).
  (for/fold ([prev-end 0]) ([e (in-list sorted)])
    (when (< (edit-start e) prev-end)
      (error 'migrate-annotations "overlapping edits at offset ~a" (edit-start e)))
    (edit-end e))
  (define out (open-output-string))
  (for/fold ([pos 0]) ([e (in-list sorted)])
    (write-string (substring source pos (edit-start e)) out)
    (write-string (edit-replacement e) out)
    (edit-end e))
  (define last-end (if (null? sorted) 0 (edit-end (last sorted))))
  (write-string (substring source last-end (string-length source)) out)
  (get-output-string out))

;; ---------------------------------------------------------------------------
;; File-mode migration (beagle source files)
;; ---------------------------------------------------------------------------

(define (migrate-source-text source #:require-balanced? [require-balanced? #t])
  ;; Returns (values new-text edits refusals reports) in source order.
  (define toks (tokenize source))
  (define cst (build-cst toks))
  ;; Round-trip sanity: cst->string must reproduce source exactly before we
  ;; trust offsets computed from it.
  (define rebuilt (cst->string cst))
  (unless (string=? rebuilt source)
    (error 'migrate-annotations
           "CST round-trip mismatch before any edits — refusing to touch this file (tokenizer/CST bug or unbalanced delimiters)"))
  (define edits (box '()))
  (define refusals (box '()))
  (define reports (box '()))
  (scan-children! (cst-root-children cst) source edits refusals reports)
  (define sorted-edits (sort (unbox edits) < #:key edit-start))
  (define sorted-refusals (sort (unbox refusals) < #:key refusal-line))
  (define sorted-reports (sort (unbox reports) < #:key report-line))
  (define new-text (apply-edits source sorted-edits))
  ;; Output round-trip proxy: balanced + CST re-serializes byte-identically.
  (unless (null? sorted-edits)
    (define out-toks (tokenize new-text))
    (when require-balanced?
      (define problems (scan-result-problems (scan-delimiters out-toks)))
      (unless (null? problems)
        (error 'migrate-annotations "output fails delimiter balance check — aborting write")))
    (define out-cst (build-cst out-toks))
    (unless (string=? (cst->string out-cst) new-text)
      (error 'migrate-annotations "output CST round-trip mismatch — aborting write")))
  (values new-text sorted-edits sorted-refusals sorted-reports))

;; ---------------------------------------------------------------------------
;; Embedded-string detection (host files) — REPORT ONLY, never rewritten.
;; Scope cut: cross-language escape round-tripping (Racket/Python/EDN/shell)
;; is unverified this pass, so candidates are flagged for hand migration.
;; ---------------------------------------------------------------------------

(define (looks-like-beagle-source? s)
  (and (regexp-match? #rx"\\(def" s)
       (regexp-match? #rx"(:-|[^:]:[ \t])" s)))

(define (scan-embedded-rkt path source)
  ;; Tokenize the whole host .rkt file; any 'string or 'block-comment-adjacent
  ;; token whose raw text looks like beagle source is a candidate.
  (define toks (tokenize source))
  (for/list ([tok (in-list toks)]
             #:when (and (memq (token-type tok) '(string))
                          (looks-like-beagle-source? (token-text tok))))
    (refusal (token-line tok) (token-col tok)
             (~a (substring (token-text tok) 0 (min 60 (string-length (token-text tok)))) "...")
             "embedded beagle-source string literal in host .rkt file — needs hand migration (tool reports, does not rewrite strings)")))

(define (scan-embedded-generic path source)
  ;; .py/.rktd/.edn: line-oriented heuristic — any line containing a beagle
  ;; marker-shaped substring inside quotes/triple-quotes.
  (define lines (string-split source "\n" #:trim? #f))
  (for/fold ([acc '()] #:result (reverse acc)) ([line (in-list lines)] [ln (in-naturals 1)])
    (if (and (regexp-match? #rx"\\(defn?" line)
             (regexp-match? #rx"(:-|[a-zA-Z0-9?!*+_-]: )" line))
        (cons (refusal ln 0 line
                        "line looks like it contains embedded beagle source with an annotation marker — needs hand migration")
              acc)
        acc)))

;; ---------------------------------------------------------------------------
;; Per-file driver
;; ---------------------------------------------------------------------------

(define (process-file! path check? verbose?)
  (define ext (path-ext path))
  (cond
    [(member ext beagle-source-exts)
     (define source (call-with-input-file path port->string))
     (define-values (new-text edits refusals reports)
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "~a: ERROR ~a — file left untouched\n" path (exn-message e))
                          (values source '() '() '()))])
         (migrate-source-text source)))
     (for ([r (in-list refusals)])
       (eprintf "~a:~a: REFUSED (~a): ~a\n" path (refusal-line r) (refusal-reason r) (refusal-before r)))
     (cond
       [(null? edits)
        (values 0 (length refusals))]
       [check?
        (for ([r (in-list reports)])
          (printf "~a:~a: ~s -> ~s\n" path (report-line r) (report-before r) (report-after r)))
        (values (length edits) (length refusals))]
       [else
        (call-with-output-file path #:exists 'truncate/replace
          (lambda (out) (write-string new-text out)))
        (printf "~a: rewrote ~a edit(s)\n" path (length edits))
        (values (length edits) (length refusals))])]
    [(member ext host-scan-exts)
     (define source (call-with-input-file path port->string))
     (define candidates
       (if (equal? ext "rkt")
           (scan-embedded-rkt path source)
           (scan-embedded-generic path source)))
     (for ([r (in-list candidates)])
       (eprintf "~a:~a: RESIDUAL (~a): ~a\n" path (refusal-line r) (refusal-reason r) (refusal-before r)))
     (values 0 (length candidates))]
    [else (values 0 0)]))

(define (offset->line source offset)
  (add1 (for/sum ([i (in-range (min offset (string-length source)))])
          (if (char=? (string-ref source i) #\newline) 1 0))))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(module+ main
  (define check? #f)
  (define verbose? #f)
  (define paths '())
  (for ([a (in-list (vector->list (current-command-line-arguments)))])
    (cond
      [(equal? a "--check") (set! check? #t)]
      [(equal? a "--verbose") (set! verbose? #t)]
      [(or (equal? a "--help") (equal? a "-h")) (usage)]
      [else (set! paths (cons a paths))]))
  (set! paths (reverse paths))
  (when (null? paths)
    (eprintf "error: no PATH given\n\n")
    (usage))

  (define files (walk-paths paths))
  (define total-edits 0)
  (define total-refusals 0)
  (for ([f (in-list files)])
    (define-values (e r) (process-file! f check? verbose?))
    (set! total-edits (+ total-edits e))
    (set! total-refusals (+ total-refusals r)))

  (printf "\n~a file(s) scanned, ~a planned/applied edit(s), ~a refused/residual site(s)\n"
          (length files) total-edits total-refusals)
  (when (> total-refusals 0)
    (exit 1)))
