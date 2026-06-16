#lang racket/base

;; claims-roundtrip: the source-of-truth gate.
;;
;; Turtle #2's emit-claims is a LOSSY query projection (overlays drop types/params;
;; reconstruction needs an AST unparser that doesn't exist). Losslessness lives one
;; layer down — at the READER DATUM tree, where type annotations (`:- Int`) are just
;; tokens. This proves `datum -> claims -> datum` is the identity over a real corpus:
;; the claim graph is a faithful, regenerable representation of the program source.
;;
;;   racket beagle-lib/private/claims-roundtrip.rkt <file-or-dir> ...
;;
;; Every datum node is minted (leaves carry kind+value; lists/vectors carry ordered
;; fN children + a uniform `child` edge + an optional improper `tail`). That is the
;; deliberate trade: this projection is VERBOSE but LOSSLESS, where the query
;; projection is COMPACT but lossy — two views of one source, like Fram's claim vs
;; markdown views of a thread.

(require racket/list
         racket/file
         racket/string
         racket/format
         "parse.rkt")

(provide datum->claims claims->datum datum->src edn-triples->datum read-edn-triples)

;; --- datum -> claims --------------------------------------------------------
(define (split-improper d)            ; pair -> (values proper-prefix tail) ; tail='() if proper
  (let loop ([d d] [acc '()])
    (cond
      [(null? d) (values (reverse acc) '())]
      [(pair? d) (loop (cdr d) (cons (car d) acc))]
      [else      (values (reverse acc) d)])))

(define (datum->claims d)             ; -> (values root-id (listof (list subj pred obj)))
  (define out '())
  (define n 0)
  (define (fresh!) (set! n (add1 n)) n)
  (define (emit! s p o) (set! out (cons (list s p o) out)))
  (define (leaf k v) (define id (fresh!)) (emit! id "kind" k) (emit! id "v" v) id)
  (define (seq! k elems tail)
    (define id (fresh!))
    (emit! id "kind" k)
    (for ([x (in-list elems)] [i (in-naturals)])
      (define cid (walk x))
      (emit! id (string-append "f" (number->string i)) cid)
      (emit! id "child" cid))
    (unless (null? tail)
      (define tid (walk tail))
      (emit! id "tail" tid)
      (emit! id "child" tid))
    id)
  (define (walk d)
    (cond
      [(null? d)    (define id (fresh!)) (emit! id "kind" "nil") id]
      [(pair? d)    (let-values ([(elems tail) (split-improper d)]) (seq! "list" elems tail))]
      [(vector? d)  (seq! "vector" (vector->list d) '())]
      [(symbol? d)  (leaf "symbol" d)]
      [(string? d)  (leaf "string" d)]
      [(keyword? d) (leaf "keyword" d)]
      [(boolean? d) (leaf "bool" d)]
      [(char? d)    (leaf "char" d)]
      [(number? d)  (leaf "number" d)]
      [else         (leaf "other" (format "~s" d))]))
  (define root (walk d))
  (values root (reverse out)))

;; --- claims -> datum (the reverse path that did not exist) ------------------
(define (claims->datum root triples)
  (define props (make-hash))          ; subj -> (mutable hash pred->obj)
  (for ([t (in-list triples)])
    (define s (car t)) (define p (cadr t)) (define o (caddr t))
    (hash-update! props s (lambda (h) (hash-set! h p o) h) (lambda () (make-hash))))
  (define (build id)
    (define h (hash-ref props id))
    (define k (hash-ref h "kind"))
    (cond
      [(member k '("symbol" "string" "keyword" "bool" "char" "number" "other")) (hash-ref h "v")]
      [(equal? k "nil") '()]
      [(or (equal? k "list") (equal? k "vector"))
       (define elems
         (let loop ([i 0] [acc '()])
           (define key (string-append "f" (number->string i)))
           (if (hash-has-key? h key)
               (loop (add1 i) (cons (build (hash-ref h key)) acc))
               (reverse acc))))
       (define tail (if (hash-has-key? h "tail") (build (hash-ref h "tail")) '()))
       (define lst (foldr cons tail elems))
       (if (equal? k "vector") (list->vector lst) lst)]
      [else (error 'claims->datum "unknown kind ~a" k)]))
  (build root))

;; --- gate runner ------------------------------------------------------------
(define (beagle-file? p)
  (regexp-match? #rx"\\.(bjs|bclj|bcljs|bnix)$" (if (path? p) (path->string p) p)))

(define (expand-paths args)
  (append-map (lambda (p)
                (cond [(directory-exists? p) (find-files beagle-file? p)]
                      [else (list (string->path p))]))
              args))

;; --- EDN serialization (universal-safe: every obj is an int node-ref OR a
;; quoted string; NO bool/keyword/nil/char literals, so Racket `read` and
;; Clojure `edn/read` parse it identically; leaf type lives in the `kind` claim) -
(define (edn-string s)                ; Racket string -> a quoted literal both readers accept
  (define o (open-output-string))
  (write-char #\" o)
  (for ([c (in-string s)])
    (define n (char->integer c))
    (cond
      [(char=? c #\") (write-string "\\\"" o)]
      [(char=? c #\\) (write-string "\\\\" o)]
      [(char=? c #\newline) (write-string "\\n" o)]
      [(char=? c #\return) (write-string "\\r" o)]
      [(char=? c #\tab) (write-string "\\t" o)]
      [(or (< n 32) (= n 127)) (write-string (format "\\u~a" (~r n #:base 16 #:min-width 4 #:pad-string "0")) o)]
      [else (write-char c o)]))
  (write-char #\" o)
  (get-output-string o))

(define (encode-leaf k v)             ; (kind, racket value) -> the string stored in `v`
  (cond [(equal? k "symbol")  (symbol->string v)]
        [(equal? k "keyword") (keyword->string v)]
        [(equal? k "char")    (string v)]
        [(equal? k "number")  (number->string v)]
        [(equal? k "bool")    (if v "true" "false")]
        [else v]))                    ; string / other (already a string)

(define (decode-leaf k v)             ; (kind, stored string) -> racket value
  (cond [(equal? k "symbol")  (string->symbol v)]
        [(equal? k "keyword") (string->keyword v)]
        [(equal? k "char")    (string-ref v 0)]
        [(equal? k "number")  (string->number v)]
        [(equal? k "bool")    (string=? v "true")]
        [else v]))

;; emit the EDN triple lines for one datum (leaves' `v` encoded as a safe string)
(define (datum->edn-lines d)
  (define-values (root triples) (datum->claims d))
  ;; kind per subject, so we know how to encode each `v`
  (define kind-of (make-hash))
  (for ([t (in-list triples)]) (when (equal? (cadr t) "kind") (hash-set! kind-of (car t) (caddr t))))
  (for/list ([t (in-list triples)])
    (define s (car t)) (define p (cadr t)) (define o (caddr t))
    (cond
      [(equal? p "kind") (format "[~a \"kind\" ~a]" s (edn-string o))]
      [(equal? p "v")    (format "[~a \"v\" ~a]" s (edn-string (encode-leaf (hash-ref kind-of s) o)))]
      [else              (format "[~a ~a ~a]" s (edn-string p) o)])))   ; fN/child/tail -> int ref

;; reconstruct a datum from EDN triples (each a list (subj pred obj)) ---------
;; root = the one subject never referenced as a child — robust even after Fram
;; re-mints all ids on its way through the store.
(define (edn-triples->datum triples)
  (define props (make-hash))
  (define refs (make-hash))                 ; ids referenced as a child (fN/child/tail)
  (for ([t (in-list triples)])
    (define s (first t)) (define p (second t)) (define o (third t))
    (when (integer? o) (hash-set! refs o #t))
    (hash-update! props s (lambda (h) (hash-set! h p o) h) (lambda () (make-hash))))
  (define root (for/first ([s (in-list (hash-keys props))] #:unless (hash-ref refs s #f)) s))
  (define (build id)
    (define h (hash-ref props id))
    (define k (hash-ref h "kind"))
    (cond
      [(member k '("symbol" "string" "keyword" "bool" "char" "number" "other")) (decode-leaf k (hash-ref h "v"))]
      [(equal? k "nil") '()]
      [(or (equal? k "list") (equal? k "vector"))
       (define elems
         (let loop ([i 0] [acc '()])
           (define key (string-append "f" (number->string i)))
           (if (hash-has-key? h key) (loop (add1 i) (cons (build (hash-ref h key)) acc)) (reverse acc))))
       (define tail (if (hash-has-key? h "tail") (build (hash-ref h "tail")) '()))
       (define lst (foldr cons tail elems))
       (if (equal? k "vector") (list->vector lst) lst)]
      [else (error 'edn->datum "unknown kind ~a" k)]))
  (build root))

;; datum -> idiomatic beagle source text. Inverts the reader's desugaring
;; (`[...]` -> (#%brackets ...), `{...}` -> (#%map ...)) so the rendering
;; re-reads to the identical program — proving text is a faithful VIEW.
(define %brackets (string->symbol "#%brackets"))
(define %map      (string->symbol "#%map"))
(define %set      (string->symbol "#%set"))
(define %regex    (string->symbol "#%regex"))
(define (datum->src d)
  (cond
    [(null? d) "()"]
    [(and (pair? d) (eq? (car d) %brackets)) (format "[~a]" (string-join (map datum->src (cdr d)) " "))]
    [(and (pair? d) (eq? (car d) %map))      (format "{~a}" (string-join (map datum->src (cdr d)) " "))]
    [(and (pair? d) (eq? (car d) %set))      (format "#{~a}" (string-join (map datum->src (cdr d)) " "))]
    [(and (pair? d) (eq? (car d) %regex) (pair? (cdr d)) (string? (cadr d))) (format "#\"~a\"" (cadr d))]
    [(pair? d)
     (let-values ([(elems tail) (split-improper d)])
       (if (null? tail)
           (format "(~a)" (string-join (map datum->src elems) " "))
           (format "(~a . ~a)" (string-join (map datum->src elems) " ") (datum->src tail))))]
    [(vector? d) (format "[~a]" (string-join (map datum->src (vector->list d)) " "))]
    [(string? d)  (format "~s" d)]
    [(symbol? d)  (symbol->string d)]
    [(boolean? d) (if d "true" "false")]
    [(keyword? d) (string-append ":" (keyword->string d))]
    [(char? d)    (format "\\~a" d)]
    [else (format "~a" d)]))                ; numbers

(define (read-edn-triples path)
  (for/list ([line (in-list (file->lines path))]
             #:when (and (> (string-length line) 0) (char=? (string-ref line 0) #\[)))
    (read (open-input-string line))))

;; --- modes ------------------------------------------------------------------
;; emit one file's whole form-list as a single wrapped datum -> one id space.
(define (emit-edn-file path)
  (define forms (map syntax->datum (read-beagle-syntax path)))
  (printf "@file ~a\n" path)
  (for ([l (in-list (datum->edn-lines (cons 'beagle-file forms)))]) (displayln l)))

;; render: reconstruct from EDN reader-claims and print idiomatic source. The EDN
;; may have come straight out of a (mutated) Fram store — this is the "project
;; source from the graph" half of graph-native authoring.
(define (render-edn edn-path)
  (define wrapped (edn-triples->datum (read-edn-triples edn-path)))
  (define forms (if (and (pair? wrapped) (eq? (car wrapped) 'beagle-file)) (cdr wrapped) (list wrapped)))
  (display (string-join (map datum->src forms) "\n\n"))
  (newline))

;; verify: reconstruct from (post-Fram) EDN, compare to the original source.
(define (verify edn-path orig-path)
  (define wrapped (edn-triples->datum (read-edn-triples edn-path)))
  (define forms (cdr wrapped))
  (define orig (map syntax->datum (read-beagle-syntax orig-path)))
  (define same (equal? forms orig))
  (printf "================ TURTLE #3 — round-trip THROUGH a Fram store ================\n")
  (printf "source: ~a\n" orig-path)
  (printf "forms reconstructed from Fram: ~a   original: ~a\n" (length forms) (length orig))
  (printf "DATUM IDENTITY through the persisted claim store: ~a\n"
          (if same "PASS — program reconstructs datum-identically" "FAIL"))
  ;; render the Fram-sourced program back to text and re-read it (text is a view).
  ;; the `#lang` line round-trips as the leading (define-target ...) form already in
  ;; `forms`, so we do NOT re-prepend it (that would double the target declaration).
  (define txt (string-join (map datum->src forms) "\n\n"))
  (define tmp (make-temporary-file "chartroom-regen-~a.bjs"))
  (with-output-to-file tmp #:exists 'replace (lambda () (display txt)))
  (define reread (with-handlers ([exn:fail? (lambda (_) #f)])
                   (map syntax->datum (read-beagle-syntax tmp))))
  (printf "claims -> rendered beagle text -> re-read: ~a\n"
          (cond [(not reread) "render produced unreadable text"]
                [(equal? reread orig) "PASS — re-reads to the identical program"]
                [else "re-read diverged"]))
  (printf "rendered program written to: ~a\n" tmp)
  (unless same (printf "  first divergence:\n   orig=~.s\n   fram=~.s\n"
                       (for/first ([a orig] [b forms] #:unless (equal? a b)) a)
                       (for/first ([a orig] [b forms] #:unless (equal? a b)) b))))

;; gate: datum -> claims -> datum identity over a corpus.
(define (run-gate args)
  (define files (expand-paths args))
  (define forms 0) (define ok 0) (define tris 0) (define res '()) (define skipped '())
  (for ([f (in-list files)])
    (define stxs (with-handlers ([exn:fail? (lambda (_) #f)]) (read-beagle-syntax f)))
    (if (not stxs)
        (set! skipped (cons (path->string f) skipped))   ; unreadable -> count it, don't let it pass silently
        (for ([stx (in-list stxs)])
          (define d (syntax->datum stx))
          (define-values (root triples) (datum->claims d))
          (define d2 (claims->datum root triples))
          (set! forms (add1 forms))
          (set! tris (+ tris (length triples)))
          (if (equal? d d2)
              (set! ok (add1 ok))
              (when (< (length res) 3) (set! res (cons (list (path->string f) d d2) res)))))))
  (printf "================ TURTLE #3 — source-of-truth gate ================\n")
  (printf "files: ~a (~a read, ~a UNREADABLE/skipped)   top-level forms: ~a\n"
          (length files) (- (length files) (length skipped)) (length skipped) forms)
  (unless (null? skipped)
    (printf "  skipped (did not parse): ~a\n" (string-join (map (lambda (p) (last (string-split p "/"))) skipped) ", ")))
  (printf "claims -> datum IDENTICAL: ~a / ~a   (~a%)\n"
          ok forms (real->decimal-string (* 100.0 (/ ok (max 1 forms))) 2))
  (printf "claim triples emitted: ~a   (~a per form avg)\n"
          tris (real->decimal-string (/ tris (max 1 forms)) 1))
  (if (= ok forms)
      (printf "GATE: PASS — every form regenerates claim-identically from its claims.\n")
      (begin
        (printf "GATE: ~a residual form(s) (showing up to 3):\n" (- forms ok))
        (for ([r (in-list res)])
          (printf "  in ~a\n    A=~.s\n    B=~.s\n" (car r) (cadr r) (caddr r)))))
  ;; corpus-scale "text is a view": render each file's reconstructed datums back to
  ;; idiomatic source and re-read it — must be the identical program.
  (define rt-ok 0) (define rt-files 0)
  (for ([f (in-list files)])
    (define stxs (with-handlers ([exn:fail? (lambda (_) #f)]) (read-beagle-syntax f)))
    (when stxs
      (set! rt-files (add1 rt-files))
      (define ds (map syntax->datum stxs))
      (define tmp (make-temporary-file "ctgate-~a.bjs"))
      (with-output-to-file tmp #:exists 'replace (lambda () (display (string-join (map datum->src ds) "\n\n"))))
      (define re (with-handlers ([exn:fail? (lambda (_) #f)]) (map syntax->datum (read-beagle-syntax tmp))))
      (delete-file tmp)
      (when (and re (equal? re ds)) (set! rt-ok (add1 rt-ok)))))
  (printf "text-is-a-view (claims -> source -> re-read identical): ~a / ~a files ~a\n"
          rt-ok rt-files (if (= rt-ok rt-files) "PASS" "")))

(module+ main
  (define argv (vector->list (current-command-line-arguments)))
  (cond
    [(and (pair? argv) (equal? (car argv) "--emit-edn")) (emit-edn-file (cadr argv))]
    [(and (pair? argv) (equal? (car argv) "--verify"))   (verify (cadr argv) (caddr argv))]
    [(and (pair? argv) (equal? (car argv) "--render"))   (render-edn (cadr argv))]
    [else (run-gate argv)]))
