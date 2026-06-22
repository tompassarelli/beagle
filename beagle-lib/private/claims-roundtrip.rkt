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
         "parse.rkt"
         ;; #33 typed-AST (slice-3): check captures per-node types; join to the
         ;; datum claims by (pos,span) to emit derived `[node "type" T]` claims.
         (only-in "check.rkt" type-check-with-locs!)
         (only-in "ast.rkt" program-type-table program-src-table
                  src-loc? src-loc-pos src-loc-span)
         (only-in "types.rkt" type->string))

(provide datum->claims claims->datum datum->src datum->pretty edn-triples->datum read-edn-triples
         datum->edn-lines stx->edn-lines stx->claims edn-triples->syntax
         emit-edn-typed-file)

;; --- datum -> claims --------------------------------------------------------
(define (split-improper d)            ; pair -> (values proper-prefix tail) ; tail='() if proper
  (let loop ([d d] [acc '()])
    (cond
      [(null? d) (values (reverse acc) '())]
      [(pair? d) (loop (cdr d) (cons (car d) acc))]
      [else      (values (reverse acc) d)])))

;; --- #36 CRDT order keys: a child slot is "f<path>~<tie>", not just "fN" -----
;; fram's chartroom verbs (insert-form / upsert-form) position children with a
;; logoot order key: pred "f<path>~<tie>", path = dot-separated ints (dense — a key
;; strictly between any two always exists), tie = the child node's atomic id (so
;; concurrent same-gap inserts get distinct keys → both land → commute). The legacy
;; emit-claims spelling "fN" is the same family at ((N+1)*ORD-STEP, tie 0). A dump
;; mixes both (seed forms "fN", verb forms "f<path>~<tie>"). We MUST parse the dual
;; spelling and sort children by (path, tie) — matching resolve.bclj's ord-parse /
;; ord-cmp exactly — or every verb-positioned form silently vanishes (the sequential
;; f0/f1/… loop stops at the first gap). Source of truth: fram-lease resolve.bclj.
(define ORD-STEP 65536)
(define (parse-fN-slot p)             ; pred string -> {path:(listof int) tie:int} | #f
  (and (string? p)
       (let ([m (regexp-match #rx"^f([0-9]+(?:\\.[0-9]+)*)~([0-9]+)$" p)])
         (cond
           [m (cons (map string->number (regexp-split #rx"\\." (cadr m)))
                    (string->number (caddr m)))]
           [(regexp-match #rx"^f([0-9]+)$" p)
            => (lambda (m2) (cons (list (* (add1 (string->number (cadr m2))) ORD-STEP)) 0))]
           [else #f]))))
(define (fN-slot? p) (and (parse-fN-slot p) #t))
(define (slot-key<? a b)              ; (path . tie) order: lexicographic path, then tie
  (let loop ([pa (car a)] [pb (car b)])
    (cond
      [(and (null? pa) (null? pb)) (< (cdr a) (cdr b))]   ; equal path → tie-break
      [(null? pa) #t]                                     ; shorter prefix sorts first
      [(null? pb) #f]
      [(< (car pa) (car pb)) #t]
      [(> (car pa) (car pb)) #f]
      [else (loop (cdr pa) (cdr pb))])))
;; a node's ordered child ids: ALL fN slots (legacy + CRDT) by (path,tie). props
;; here is a node's pred->obj hash. Used by every EDN-side reconstruction path.
(define (ordered-slot-children h)
  (map cdr
       (sort (for/list ([(p o) (in-hash h)] #:when (fN-slot? p)) (cons (parse-fN-slot p) o))
             slot-key<? #:key car)))

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

;; --- #33 slice-2: syntax-walking claims (datum->claims + per-node srcloc) -----
;; Same structure/ids as datum->claims, but walks the SYNTAX so each node also
;; carries line/col/pos/span claims (the load-bearing one is `pos`). Source is
;; the module's @file header, NOT per-node. All four are OPTIONAL: a node missing
;; a field (synthetic syntax, e.g. the (beagle-file …) wrapper) emits none, and
;; the build side degrades to #f — so a srcloc-free dump still builds (slice-1).
(define (stx->claims top-stx)
  (define out '())
  (define n 0)
  (define (fresh!) (set! n (add1 n)) n)
  (define (emit! s p o) (set! out (cons (list s p o) out)))
  (define (srcloc! id stx)
    (when (syntax? stx)
      (let ([ln (syntax-line stx)] [cl (syntax-column stx)]
            [ps (syntax-position stx)] [sp (syntax-span stx)])
        (when ln (emit! id "line" ln))
        (when cl (emit! id "col" cl))
        (when ps (emit! id "pos" ps))
        (when sp (emit! id "span" sp)))))
  (define (leaf k v stx) (define id (fresh!)) (emit! id "kind" k) (emit! id "v" v) (srcloc! id stx) id)
  (define (seq! k kid-stxs tail-stx stx)
    (define id (fresh!))
    (emit! id "kind" k)
    (for ([x (in-list kid-stxs)] [i (in-naturals)])
      (define cid (walk x))
      (emit! id (string-append "f" (number->string i)) cid)
      (emit! id "child" cid))
    (when tail-stx
      (define tid (walk tail-stx))
      (emit! id "tail" tid)
      (emit! id "child" tid))
    (srcloc! id stx)
    id)
  (define (walk stx)
    (define e (if (syntax? stx) (syntax-e stx) stx))
    (cond
      [(null? e)    (define id (fresh!)) (emit! id "kind" "nil") (srcloc! id stx) id]
      [(pair? e)
       (define kids (syntax->list stx))         ; proper list → child stxs, else #f
       (if kids
           (seq! "list" kids #f stx)
           (let collect ([s e] [acc '()])       ; improper: proper prefix + tail
             (if (pair? s)
                 (collect (let ([d (cdr s)]) (if (syntax? d) (syntax-e d) d)) (cons (car s) acc))
                 (seq! "list" (reverse acc) s stx))))]
      [(vector? e) (seq! "vector" (vector->list e) #f stx)]
      [(symbol? e)  (leaf "symbol" e stx)]
      [(string? e)  (leaf "string" e stx)]
      [(keyword? e) (leaf "keyword" e stx)]
      [(boolean? e) (leaf "bool" e stx)]
      [(char? e)    (leaf "char" e stx)]
      [(number? e)  (leaf "number" e stx)]
      [else         (leaf "other" (format "~s" e) stx)]))
  (define root (walk top-stx))
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
       (define elems (map build (ordered-slot-children h)))
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

;; emit the EDN triple lines for a precomputed triple list (leaves' `v` encoded)
(define (triples->edn-lines triples)
  ;; kind per subject, so we know how to encode each `v`
  (define kind-of (make-hash))
  (for ([t (in-list triples)]) (when (equal? (cadr t) "kind") (hash-set! kind-of (car t) (caddr t))))
  (for/list ([t (in-list triples)])
    (define s (car t)) (define p (cadr t)) (define o (caddr t))
    (cond
      [(equal? p "kind") (format "[~a \"kind\" ~a]" s (edn-string o))]
      [(equal? p "v")    (format "[~a \"v\" ~a]" s (edn-string (encode-leaf (hash-ref kind-of s) o)))]
      [else              (format "[~a ~a ~a]" s (edn-string p) o)])))   ; fN/child/tail -> int ref
(define (datum->edn-lines d)
  (define-values (root triples) (datum->claims d))
  (triples->edn-lines triples))
;; #33 slice-2: serialize a SYNTAX tree to EDN lines (with srcloc claims).
(define (stx->edn-lines stx)
  (define-values (root triples) (stx->claims stx))
  (triples->edn-lines triples))

;; shared triple helpers (used by both emit and render paths) -----------------
(define (triples->props triples)        ; subj -> (mutable hash pred -> obj)
  (define props (make-hash))
  (for ([t (in-list triples)])
    (hash-update! props (car t) (lambda (h) (hash-set! h (cadr t) (caddr t)) h) (lambda () (make-hash))))
  props)
(define (ordered-fN props id)           ; node ids of fN children, in (path,tie) order
  (ordered-slot-children (hash-ref props id (make-hash))))
;; Largest NODE id, so comment/segment ids can be allocated beyond it. Consider
;; ONLY subjects (car): every minted node is the subject of its own kind claim, so
;; subjects cover all node ids — while objects (caddr) may be LEAF VALUES, and an
;; integer-valued float value (e.g. 2.0, 16.0; Racket's `integer?` is #t for those)
;; would otherwise make the allocated ids FLOATS, which downstream node-ref tests
;; mis-store as values. `exact-integer?` admits only real node ids.
(define (max-id triples)
  (for/fold ([m 0]) ([t (in-list triples)])
    (max m (if (exact-integer? (car t)) (car t) 0))))

;; reconstruct a datum from EDN triples (each a list (subj pred obj)) ---------
;; root = the one subject never referenced as a child — robust even after Fram
;; re-mints all ids on its way through the store.
;; A predicate naming a STRUCTURAL child edge (fN / child / tail) — the only
;; numeric-valued claims that are node REFS. srcloc claims (line/col/pos/span) are
;; ALSO numeric but are NOT refs; ref-detection must exclude them or it mistakes a
;; `pos`/`line` value for a child node id (#33 slice-2).
(define (ref-pred? p)
  (or (equal? p "child") (equal? p "tail") (fN-slot? p)))   ; fN-slot? covers fN AND f<path>~<tie>

(define (edn-root props)                  ; the structural wrapper (subject never referenced)
  (define refs (make-hash))
  (for ([(s h) (in-hash props)])
    (for ([(p o) (in-hash h)]) (when (and (number? o) (ref-pred? p)) (hash-set! refs o #t))))
  (define cands (for/list ([s (in-list (hash-keys props))] #:unless (hash-ref refs s #f)) s))
  ;; prefer the list/vector wrapper over any stray orphan, so reconstruction is
  ;; robust even if an edge was mis-stored (don't depend on hash-key order).
  (or (for/first ([s (in-list cands)]
                  #:when (member (hash-ref (hash-ref props s (make-hash)) "kind" #f) '("list" "vector")))
        s)
      (and (pair? cands) (car cands))))
(define (make-edn-build props)            ; id -> datum (follows fN/tail only; ignores comment*/seg*)
  (define (build id)
    (define h (hash-ref props id))
    (define k (hash-ref h "kind"))
    (cond
      [(member k '("symbol" "string" "keyword" "bool" "char" "number" "other")) (decode-leaf k (hash-ref h "v"))]
      [(equal? k "nil") '()]
      [(or (equal? k "list") (equal? k "vector"))
       (define elems (map build (ordered-slot-children h)))
       (define tail (if (hash-has-key? h "tail") (build (hash-ref h "tail")) '()))
       (define lst (foldr cons tail elems))
       (if (equal? k "vector") (list->vector lst) lst)]
      [else (error 'edn->datum "unknown kind ~a" k)]))
  build)
(define (edn-triples->datum triples)
  (define props (triples->props triples))
  ((make-edn-build props) (edn-root props)))

;; #33 slice-2: like edn-triples->datum but returns SYNTAX, attaching each node's
;; line/col/pos/span claims as its srcloc (source = the module @file, passed in).
;; A node with no srcloc claims gets #f srcloc — so srcloc-free dumps still build
;; (graceful slice-1 behavior). datum->syntax preserves inner-node srclocs, so the
;; whole tree carries positions → --build-edn restores blame + ^{:line} emit.
(define (edn-triples->syntax triples [src #f])
  (define props (triples->props triples))
  (define (num h k) (let ([v (hash-ref h k #f)]) (and (number? v) v)))
  (define (loc-of h)
    (define ps (num h "pos")) (define ln (num h "line"))
    (and (or ps ln) (vector src ln (num h "col") ps (num h "span"))))
  (define (build id)
    (define h (hash-ref props id))
    (define k (hash-ref h "kind"))
    (define loc (loc-of h))
    (cond
      [(member k '("symbol" "string" "keyword" "bool" "char" "number" "other"))
       (datum->syntax #f (decode-leaf k (hash-ref h "v")) loc)]
      [(equal? k "nil") (datum->syntax #f '() loc)]
      [(or (equal? k "list") (equal? k "vector"))
       (define elems (map build (ordered-slot-children h)))
       (define tail (if (hash-has-key? h "tail") (build (hash-ref h "tail")) '()))
       (define lst (foldr cons tail elems))   ; list of syntax (inner srclocs preserved)
       (datum->syntax #f (if (equal? k "vector") (list->vector lst) lst) loc)]
      [else (error 'edn->syntax "unknown kind ~a" k)]))
  (define root (edn-root props))
  (and root (build root)))

;; --- Turtle #6: read comment claims back off the triples (render side) ------
(define (comment-text props cid)          ; concatenate seg0,seg1,... `v`s -> the comment lexeme
  (define h (hash-ref props cid))
  (apply string-append
    (let loop ([j 0] [acc '()])
      (define key (string-append "seg" (number->string j)))
      (if (hash-has-key? h key)
          (loop (add1 j) (cons (hash-ref (hash-ref props (hash-ref h key)) "v") acc))
          (reverse acc)))))
(define (comments-of props id)            ; (listof (cons placement text)) in comment order
  (define h (hash-ref props id (make-hash)))
  (let loop ([k 0] [acc '()])
    (define key (string-append "comment" (number->string k)))
    (if (hash-has-key? h key)
        (let ([cid (hash-ref h key)])
          (loop (add1 k) (cons (cons (hash-ref (hash-ref props cid) "placement") (comment-text props cid)) acc)))
        (reverse acc))))

;; datum -> idiomatic beagle source text. Inverts the reader's desugaring
;; (`[...]` -> (#%brackets ...), `{...}` -> (#%map ...)) so the rendering
;; re-reads to the identical program — proving text is a faithful VIEW.
;; Render a symbol so it RE-READS to the same symbol. A name containing
;; whitespace / delimiters / quote / escape chars, or an EMPTY name, must be
;; pipe-quoted (|name|, escaping \ and |) — bare symbol->string silently corrupts
;; such symbols (round-trip hole found by adversarial verification: |foo bar| ->
;; two symbols, \\ -> unreadable, || -> vanished value). Normal beagle identifiers
;; (-, ?, !, <, >, *, +, /, =, ., :, &, %, $, alphanumerics) never need bars.
(define (symbol-needs-bars? s)
  (or (= (string-length s) 0)
      (regexp-match? #rx"[][ \t\r\n(){}\"|;\\\\,`']" s)))
(define (symbol->src d)
  (define s (symbol->string d))
  (cond
    ;; Beagle's reader: |...| is a LITERAL run with NO internal escaping (can't
    ;; carry \ or |), but OUTSIDE bars `\X` escapes any char (\\ -> \, a\ b -> "a b").
    ;; So backslash-escape each unsafe char per-char; only the empty symbol needs ||.
    [(= (string-length s) 0) "||"]
    [(symbol-needs-bars? s)
     (apply string-append
            (for/list ([c (in-string s)])
              (if (or (char-whitespace? c)
                      (memv c '(#\( #\) #\[ #\] #\{ #\} #\" #\| #\; #\\ #\, #\` #\')))
                  (string #\\ c)
                  (string c))))]
    [else s]))

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
    [(symbol? d)  (symbol->src d)]
    [(boolean? d) (if d "true" "false")]
    [(keyword? d) (string-append ":" (keyword->string d))]
    [(char? d)    (format "\\~a" d)]
    [else (format "~a" d)]))                ; numbers

;; --- byte-stable pretty-printer (move 2) ------------------------------------
;; datum->src renders one line — fine for round-trip identity, but it collapses a
;; whole top-level form onto one line, so a one-token change rewrites the entire
;; line: a file-wide diff for a local edit. datum->pretty is the DETERMINISTIC,
;; LOCAL formatter: fits-in-width stays inline, over-width breaks structurally so a
;; changed subexpression touches only its own line(s).
;;
;; Three properties (the move-2 gate):
;;   * idempotent fixed-point — pretty(parse(pretty(x))) == pretty(x). FOLLOWS from
;;     purity (output depends only on the datum + width) + the proven round-trip.
;;   * locality — a small semantic change yields a small, local diff (each element
;;     owns its line when expanded).
;;   * round-trip preserved — only whitespace is inserted between tokens datum->src
;;     already separates, and the reader is whitespace-insensitive, so it re-reads
;;     to the identical datum.
(define PP-WIDTH 80)

(define (pp-seq-parts d)        ; -> (values open close elems) or (values #f #f #f)
  (cond
    [(and (pair? d) (eq? (car d) %brackets)) (values "[" "]" (cdr d))]
    [(and (pair? d) (eq? (car d) %map))      (values "{" "}" (cdr d))]
    [(and (pair? d) (eq? (car d) %set))      (values "#{" "}" (cdr d))]
    [(and (pair? d) (eq? (car d) %regex))    (values #f #f #f)]   ; never break a regex
    [(pair? d) (let-values ([(elems tail) (split-improper d)])
                 (if (null? tail) (values "(" ")" elems) (values #f #f #f)))] ; not dotted pairs
    [(vector? d) (values "[" "]" (vector->list d))]
    [else (values #f #f #f)]))

(define BODY-INDENT 2)
(define DASH (string->symbol ":-"))

;; How many post-head elements stay on the opening line (the "signature") before
;; the body breaks onto BODY-INDENT-indented lines. Keeps defn/let/if heads intact
;; so output is idiomatic AND a body edit stays local to the body lines.
(define (head-keep head after)
  (define na (length after))
  (define (dash-at? i) (and (> na i) (eq? (list-ref after i) DASH)))
  (cond
    [(memq head '(defn defn-))                  ; name + params [+ :- ret]
     (cond [(< na 2) na] [(dash-at? 2) 4] [else 2])]
    [(memq head '(def defonce))                 ; name [+ :- type]; value breaks
     (cond [(< na 1) na] [(dash-at? 1) 3] [else 1])]
    [(eq? head 'fn)                             ; [name] params [+ :- ret]
     (let* ([named? (and (pair? after) (symbol? (car after)))]
            [base (if named? 2 1)])
       (if (dash-at? base) (+ base 2) base))]
    [(memq head '(defrecord deftype)) (min 2 na)]              ; name + field vec
    [(memq head '(let loop letfn binding for doseq with-open with-local-vars
                  when-let if-let when-some if-some)) (min 1 na)]
    [(memq head '(if when when-not when-first while if-not match doto
                  defprotocol defunion extend-type)) (min 1 na)]
    [(memq head '(condp as->)) (min 2 na)]                     ; pred+expr / init+binding
    [(memq head '(do try cond)) 0]
    [else (min 1 na)]))   ; generic call + threading (-> ->> some-> cond->): head + first

(define (datum->pretty d [col 0])
  (define oneline (datum->src d))
  (define-values (open close elems) (pp-seq-parts d))
  (cond
    [(or (not open) (<= (+ col (string-length oneline)) PP-WIDTH)) oneline]   ; inline
    [(null? elems) (string-append open close)]
    [(and (string=? open "(") (symbol? (car elems)))
     ;; list with a symbol head: keep head + signature on line 1; break the body
     ;; onto BODY-INDENT-indented lines (idiomatic AND a body edit stays local).
     (define head (car elems))
     (define after (cdr elems))
     (define keep (min (head-keep head after) (length after)))
     (define body-pad (make-string (+ col BODY-INDENT) #\space))
     (string-append
      open (datum->src head)
      (apply string-append (for/list ([e (in-list (take after keep))])
                             (string-append " " (datum->src e))))
      (apply string-append (for/list ([e (in-list (drop after keep))])
                             (string-append "\n" body-pad (datum->pretty e (+ col BODY-INDENT)))))
      close)]
    [else
     ;; collection ([ ] { } #{}) or list with non-symbol head: break elements,
     ;; aligned one column past the opener; close attaches to the last element.
     (define inner-col (+ col (string-length open)))
     (define pad (make-string inner-col #\space))
     (string-append
      open (datum->pretty (car elems) inner-col)
      (apply string-append
             (for/list ([e (in-list (cdr elems))])
               (string-append "\n" pad (datum->pretty e inner-col))))
      close)]))

(define (read-edn-triples path)
  (for/list ([line (in-list (file->lines path))]
             #:when (and (> (string-length line) 0) (char=? (string-ref line 0) #\[)))
    (read (open-input-string line))))

;; ============================================================================
;; Turtle #6 — comments as resolved references (LINE comments, top level).
;; The reader DROPS comments, so we recover them from the source TEXT by srcloc:
;; a `;` outside every form's span is a top-level comment. Each is tokenized into
;; text + symbol-candidate SEGMENTS and attached to the FOLLOWING form (leading)
;; / the PRECEDING form on the same line (trailing) / the file wrapper. A symbol
;; segment can carry refers_to and rename like code; text renders verbatim — so a
;; doc comment's identifier mentions follow a rename, while substrings and quoted
;; "strings" do not. SCOPE: line comments only (block #| |# is a follow-up);
;; comments INSIDE a form are not yet captured; layout reflows (text+placement).
;; ============================================================================
(define (sym-char? c)                   ; a char that may constitute a beagle identifier
  (and (or (char-alphabetic? c) (char-numeric? c)
           (memv c '(#\- #\_ #\* #\+ #\! #\? #\< #\> #\= #\/ #\. #\& #\% #\$))) #t))
(define (make-line-of src)              ; 0-based offset -> 1-based line number
  (define starts
    (let loop ([i 0] [acc '(0)])
      (cond [(>= i (string-length src)) (list->vector (reverse acc))]
            [(char=? (string-ref src i) #\newline) (loop (add1 i) (cons (add1 i) acc))]
            [else (loop (add1 i) acc)])))
  (lambda (off)
    (let loop ([k (sub1 (vector-length starts))])
      (if (and (> k 0) (> (vector-ref starts k) off)) (loop (sub1 k)) (add1 k)))))
(define (src-lines src)                 ; (listof (cons line-start-offset line-text-without-newline))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(>= i (string-length src)) (reverse (cons (cons start (substring src start i)) acc))]
      [(char=? (string-ref src i) #\newline) (loop (add1 i) (add1 i) (cons (cons start (substring src start i)) acc))]
      [else (loop (add1 i) start acc)])))
;; syntax-position is file-relative when the file carries #lang (the usual case);
;; when it does NOT (e.g. a rendered intermediate leading with (define-target ...)),
;; the reader injects a synthetic #lang prefix and positions shift by its length.
;; Recover that shift by aligning the first form's port position with the first
;; form-starting char in the file (past leading whitespace / #lang / ; comments).
(define (port->file-shift src stxs)
  (define first-pos (for/or ([s (in-list stxs)] #:when (syntax-position s)) (syntax-position s)))
  (cond
    [(not first-pos) 0]
    [else
     (define n (string-length src))
     (define first-form-off
       (let loop ([i 0])
         (cond
           [(>= i n) i]
           [(char-whitespace? (string-ref src i)) (loop (add1 i))]
           [(or (char=? (string-ref src i) #\;)                              ; a ; comment ...
                (and (char=? (string-ref src i) #\#)                         ; ... or a #lang line
                     (regexp-match? #rx"^#lang" (substring src i (min n (+ i 5))))))
            (let eol ([j i]) (if (and (< j n) (not (char=? (string-ref src j) #\newline))) (eol (add1 j)) (loop j)))]
           [else i])))
     (- (sub1 first-pos) first-form-off)]))
(define (form-spans stxs shift)         ; (listof (list stx-index start end)) for forms WITH srcloc
  ;; a form can carry a position but a #f span (e.g. a top-level beagle/nix
  ;; brace-map) — guard both, else (+ start #f) crashes emit. A spanless form just
  ;; gets no comment attachment (graceful).
  (for/list ([s (in-list stxs)] [i (in-naturals)] #:when (and (syntax-position s) (syntax-span s)))
    (define start (- (sub1 (syntax-position s)) shift))
    (list i start (+ start (syntax-span s)))))
(define (in-any-span? off spans)
  (for/or ([sp (in-list spans)]) (and (>= off (cadr sp)) (< off (caddr sp)))))
(define (capture-comments src spans)    ; (listof (cons offset lexeme)) — first out-of-span `;`..EOL per line
  (for*/list ([ln (in-list (src-lines src))]
              [hit (in-value
                    (let ([start (car ln)] [text (cdr ln)])
                      (let scan ([j 0])
                        (cond
                          [(>= j (string-length text)) #f]
                          [(and (char=? (string-ref text j) #\;) (not (in-any-span? (+ start j) spans)))
                           (cons (+ start j) (string-trim (substring text j) #:left? #f))]
                          [else (scan (add1 j))]))))]
              #:when hit)
    hit))
(define (classify-comments comments spans src)  ; -> (listof (list placement anchor-spec lexeme))
  (define line-of (make-line-of src))
  (for/list ([c (in-list comments)])
    (define o (car c)) (define lex (cdr c))
    (define preceding (for/fold ([b #f]) ([sp (in-list spans)])
                        (if (and (<= (caddr sp) o) (or (not b) (> (caddr sp) (caddr b)))) sp b)))
    (define following (for/fold ([b #f]) ([sp (in-list spans)])
                        (if (and (>= (cadr sp) o) (or (not b) (< (cadr sp) (cadr b)))) sp b)))
    (cond
      [(and preceding (= (line-of (sub1 (caddr preceding))) (line-of o))) (list "trailing" (car preceding) lex)]
      [following (list "leading" (car following) lex)]
      [else (list "trailing" 'file lex)])))            ; own-line comment after the last form -> file footer
(define (tokenize-comment lex)          ; (listof (cons 'text|'symbol string)), text-runs merged
  (define n (string-length lex))
  (define raw
    (let loop ([i 0] [out '()])
      (cond
        [(>= i n) (reverse out)]
        [(sym-char? (string-ref lex i))
         (let run ([j i])
           (if (and (< j n) (sym-char? (string-ref lex j))) (run (add1 j))
               (let ([quoted? (and (> i 0) (char=? (string-ref lex (sub1 i)) #\")
                                   (< j n) (char=? (string-ref lex j) #\"))])
                 (loop j (cons (cons (if quoted? 'text 'symbol) (substring lex i j)) out)))))]
        [else
         (let run ([j i])
           (if (and (< j n) (not (sym-char? (string-ref lex j)))) (run (add1 j))
               (loop j (cons (cons 'text (substring lex i j)) out))))])))
  (let merge ([s raw] [out '()])        ; merge adjacent text chunks (incl. quote-demoted symbols)
    (cond
      [(null? s) (reverse out)]
      [(and (pair? out) (eq? (caar out) 'text) (eq? (caar s) 'text))
       (merge (cdr s) (cons (cons 'text (string-append (cdar out) (cdar s))) (cdr out)))]
      [else (merge (cdr s) (cons (car s) out))])))
(define (format-claim s p o)            ; one EDN triple; obj int=node-ref, string=literal
  (if (integer? o) (format "[~a ~a ~a]" s (edn-string p) o)
      (format "[~a ~a ~a]" s (edn-string p) (edn-string o))))
(define (comment-edn-lines comments form-node root fresh!)
  (define lines '())
  (define (add! s p o) (set! lines (cons (format-claim s p o) lines)))
  (define cidx (make-hash))             ; anchor node -> next comment index
  (for ([c (in-list comments)])
    (define placement (first c)) (define spec (second c)) (define lex (third c))
    (define anchor (if (eq? spec 'file) root (form-node spec)))
    (define k (hash-ref cidx anchor 0)) (hash-set! cidx anchor (add1 k))
    (define cid (fresh!))
    (add! cid "kind" "comment") (add! cid "style" "line") (add! cid "placement" placement)
    (add! anchor (string-append "comment" (number->string k)) cid)
    (for ([seg (in-list (tokenize-comment lex))] [j (in-naturals)])
      (define sid (fresh!))
      (add! sid "kind" (if (eq? (car seg) 'symbol) "symbol" "text"))
      (add! sid "v" (cdr seg))
      (add! cid (string-append "seg" (number->string j)) sid)))
  (reverse lines))

;; --- modes ------------------------------------------------------------------
;; the slice-2 lossless projection of ONE file as EDN lines: datum claims (each
;; node carries line/col/pos/span — we walk the SYNTAX, not syntax->datum) THEN
;; comment claims (Turtle #6) attached to form nodes by srcloc. The (beagle-file …)
;; wrapper + its head symbol are synthetic (no srcloc); form stxs keep theirs
;; (datum->syntax preserves inner syntax). ONE id space — emit-edn-typed's type
;; overlay keys directly off these datum node-ids (comment ids are minted ABOVE
;; max datum id, so type subjects never collide). Returns the bindings the typed
;; path also needs so it doesn't re-walk: (values stxs root triples props lines).
(define (file->datum-projection path)
  (define stxs (read-beagle-syntax path))
  (define src (file->string path))
  (define-values (root triples) (stx->claims (datum->syntax #f (cons 'beagle-file stxs))))
  (define props (triples->props triples))
  (define root-kids (ordered-fN props root))      ; [beagle-file-sym, form0-node, form1-node, ...]
  (define (form-node i) (list-ref root-kids (add1 i)))
  (define spans (form-spans stxs (port->file-shift src stxs)))
  (define comments (classify-comments (capture-comments src spans) spans src))
  (define next (box (add1 (max-id triples))))
  (define (fresh!) (define v (unbox next)) (set-box! next (add1 v)) v)
  (define clines (comment-edn-lines comments form-node root fresh!))
  (values stxs root triples props (append (triples->edn-lines triples) clines)))

(define (emit-edn-file path)
  (define-values (_stxs _root _triples _props lines) (file->datum-projection path))
  (printf "@file ~a\n" path)
  (for ([l (in-list lines)]) (displayln l)))

;; #33 slice-3: a strict SUPERSET of --emit-edn — the full slice-2 datum+comment
;; projection PLUS the TYPED layer: each checked node's inferred type as a DERIVED
;; `[node "type" T]` claim. Same id space, so the type subjects ARE the durable
;; datum node-ids and fram just extracts the [id "type" T] lines for its warm
;; overlay (no re-join fram-side). The join key is (pos,span): check's type-table
;; is keyed by AST-node, the datum claims by int node-id, and both carry a source
;; (pos,span) — so a type attaches to the datum node sharing its span. Types are
;; ADDITIVE + DERIVED (re-derive == re-check, zero staleness) — the build path
;; ignores them (string-valued, not fN/child/tail), so a typed dump still builds
;; byte-identically (consume = re-check, per fram-2 Q4).
(define (emit-edn-typed-file path)
  (define-values (stxs _root _triples props lines) (file->datum-projection path))
  ;; (pos . span) -> datum node-id; pos-precedence on exact-span collision
  ;; (lowest id = minted first = outermost, matching the delaborator).
  (define key->id (make-hash))
  (for ([(id h) (in-hash props)])
    (define p (hash-ref h "pos" #f)) (define sp (hash-ref h "span" #f))
    (when (and (number? p) (number? sp))
      (hash-update! key->id (cons p sp) (lambda (cur) (min cur id)) id)))
  ;; check with type capture, then join AST-node types onto datum nodes by (pos,span)
  (define prog (parse-program stxs #:source-path path))
  (type-check-with-locs! prog (lambda (e s) (void)) #:capture-types? #t)
  (define tt (program-type-table prog))
  (define st (program-src-table prog))
  (define typed (make-hash))   ; datum node-id -> type string
  (when (and tt st)
    (for ([(node ty) (in-hash tt)])
      (define loc (hash-ref st node #f))
      (when (and (src-loc? loc) (src-loc-pos loc) (src-loc-span loc))
        (define id (hash-ref key->id (cons (src-loc-pos loc) (src-loc-span loc)) #f))
        (when id (hash-set! typed id (type->string ty))))))
  (printf "@file ~a\n" path)
  (for ([l (in-list lines)]) (displayln l))
  ;; type value is a STRING → quote it (the fN/child/tail else-branch emits raw ints)
  (for ([id (in-list (sort (hash-keys typed) <))])
    (displayln (format "[~a \"type\" ~a]" id (edn-string (hash-ref typed id))))))

;; render: reconstruct from EDN reader-claims and print idiomatic source. The EDN
;; may have come straight out of a (mutated) Fram store — this is the "project
;; source from the graph" half of graph-native authoring.
(define (render-edn edn-path)
  (define props (triples->props (read-edn-triples edn-path)))
  (define root (edn-root props))
  (define build (make-edn-build props))
  (define wrapped?                                  ; root is the (beagle-file ...) wrapper?
    (and root (let ([h (hash-ref props root)])
                (and (hash-has-key? h "f0")
                     (equal? (hash-ref (hash-ref props (hash-ref h "f0")) "v" #f) "beagle-file")))))
  (define form-ids (if wrapped? (cdr (ordered-fN props root)) (list root)))
  (define (lead cs)  (filter (lambda (c) (equal? (car c) "leading"))  cs))
  (define (trail cs) (filter (lambda (c) (equal? (car c) "trailing")) cs))
  (define (block fid)                               ; leading comments (own lines) + form + trailing (same line)
    (define cs (comments-of props fid))
    (string-append
      (apply string-append (map (lambda (c) (string-append (cdr c) "\n")) (lead cs)))
      (datum->pretty (build fid) 0)
      (apply string-append (map (lambda (c) (string-append " " (cdr c))) (trail cs)))))
  (define file-cs (if wrapped? (comments-of props root) '()))   ; file header/footer comments
  ;; #17: a leading (define-target X) form is how read-beagle-syntax canonicalizes
  ;; `#lang beagle/X`. Render it BACK as the `#lang` header line (the absolute
  ;; first line of the file) so the regenerated .bclj is a real #lang module — not
  ;; a (define-target …)-leading file that `bin/beagle check`'s module loader
  ;; rejects ("expected a `module' declaration"). Round-trips faithfully:
  ;; read-beagle-syntax re-canonicalizes `#lang` → (define-target X), so the form
  ;; set is unchanged through the graph.
  (define first-built (and (pair? form-ids) (build (car form-ids))))
  (define lang-line
    (and (pair? first-built) (eq? (car first-built) 'define-target) (pair? (cdr first-built))
         (format "#lang beagle/~a" (cadr first-built))))
  (define body-ids (if lang-line (cdr form-ids) form-ids))
  (define rendered (string-join
                     (append (map cdr (lead file-cs)) (map block body-ids) (map cdr (trail file-cs)))
                     "\n\n"))
  (display (if lang-line (string-append lang-line "\n\n" rendered) rendered))
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

;; --- move-2 pretty-printer modes -------------------------------------------
(define (pretty-file path)             ; render a file's forms via the byte-stable formatter
  (define ds (map syntax->datum (read-beagle-syntax path)))
  (display (string-join (map (lambda (d) (datum->pretty d 0)) ds) "\n\n"))
  (newline))

(define (pretty-gate args)             ; idempotent fixed-point + round-trip over a corpus
  (define files (expand-paths args))
  (define n 0) (define fp 0) (define rt 0) (define bad '()) (define skipped '())
  (for ([f (in-list files)])
    (define stxs (with-handlers ([exn:fail? (lambda (_) #f)]) (read-beagle-syntax f)))
    (cond
      ;; A file the reader can't parse is NEITHER pass nor fail under the old code —
      ;; a silent blind spot (adversarial verification's finding). Count + report it,
      ;; and fail the gate: a skip is not a pass.
      [(not stxs) (set! skipped (cons (path->string f) skipped))]
      [else
       (set! n (add1 n))
       (define ds (map syntax->datum stxs))
       (define text1 (string-join (map (lambda (d) (datum->pretty d 0)) ds) "\n\n"))
       (define tmp (make-temporary-file "ppgate-~a.bjs"))
       (with-output-to-file tmp #:exists 'replace (lambda () (display text1)))
       (define ds2 (with-handlers ([exn:fail? (lambda (_) #f)]) (map syntax->datum (read-beagle-syntax tmp))))
       (delete-file tmp)
       (define rt-ok (and ds2 (equal? ds2 ds)))
       (define text2 (and ds2 (string-join (map (lambda (d) (datum->pretty d 0)) ds2) "\n\n")))
       (define fp-ok (and text2 (string=? text1 text2)))
       (when rt-ok (set! rt (add1 rt)))
       (when fp-ok (set! fp (add1 fp)))
       (when (and (not (and rt-ok fp-ok)) (< (length bad) 3))
         (set! bad (cons (path->string f) bad)))]))
  (printf "================ move-2 — byte-stable emit gate ================\n")
  (printf "files: ~a   round-trip identical: ~a/~a   pretty fixed-point: ~a/~a   skipped(unparseable): ~a\n"
          n rt n fp n (length skipped))
  (unless (null? skipped)
    (printf "  SKIPPED (not gated — a skip is not a pass):\n")
    (for ([s (in-list skipped)]) (printf "    ~a\n" s)))
  (cond
    [(and (= rt n) (= fp n) (> n 0) (null? skipped))
     (printf "GATE: PASS — pretty emit round-trips and is an idempotent fixed-point.\n")]
    [else
     (printf "GATE: FAIL\n")
     (for ([r (in-list bad)]) (printf "  ~a\n" r))
     (exit 1)]))

(module+ main
  (define argv (vector->list (current-command-line-arguments)))
  (cond
    [(and (pair? argv) (equal? (car argv) "--emit-edn"))    (emit-edn-file (cadr argv))]
    [(and (pair? argv) (equal? (car argv) "--emit-edn-typed")) (emit-edn-typed-file (cadr argv))]
    [(and (pair? argv) (equal? (car argv) "--verify"))      (verify (cadr argv) (caddr argv))]
    [(and (pair? argv) (equal? (car argv) "--render"))      (render-edn (cadr argv))]
    [(and (pair? argv) (equal? (car argv) "--pretty"))      (pretty-file (cadr argv))]
    [(and (pair? argv) (equal? (car argv) "--pretty-gate")) (pretty-gate (cdr argv))]
    [else (run-gate argv)]))
