#lang racket/base

;; AST struct definitions and shared utilities for beagle's parse pipeline.
;; Extracted from parse.rkt to reduce module size and allow direct struct imports.

(require racket/set
         racket/string
         "types.rkt")

;; --- tag aliases -----------------------------------------------------------
(define BT BRACKET-TAG)
(define MT MAP-TAG)
(define ST SET-TAG)

(define (bracketed? d)        (and (pair? d) (eq? (car d) BT)))
(define (bracket-body d)      (cdr d))

(define (map-tagged? d)       (and (pair? d) (eq? (car d) MT)))
(define (map-body d)          (cdr d))

(define (set-tagged? d)       (and (pair? d) (eq? (car d) ST)))
(define (set-body d)          (cdr d))

(define (bracket-items form what)
  (define d (->datum form))
  (cond
    [(bracketed? d) (bracket-body d)]
    ;; Tests and compiler-internal rewrites may supply an unlocated raw datum.
    ;; It has no source delimiter to validate. Real reader syntax always keeps
    ;; the #%brackets tag, so a located ordinary list is unambiguously `(...)`
    ;; and is rejected below.
    [(and (list? d)
          (or (not (syntax? form))
              (not (syntax-source form))))
     d]
    [else (error 'beagle "expected ~a in `[...]`, got: ~v" what d)]))

(define (bracket-stxs psubs d)
  (and psubs
       (if (bracketed? d) (cdr psubs) psubs)))

;; --- identifier safety -----------------------------------------------------
(define unsafe-ident-rx #rx"[;'\"` \t\n\r(){}\\[\\]\\\\,]")

(define (validate-identifier! sym [context "identifier"])
  (when (symbol? sym)
    (define s (symbol->string sym))
    (when (for/or ([segment (in-list (string-split s "/"))])
            (or (string-prefix? segment "$beagle$")
                (string-prefix? segment "bgl____")))
      (error 'beagle
             "~a '~a' uses a reserved compiler identifier prefix"
             context s))
    (when (regexp-match? unsafe-ident-rx s)
      (error 'beagle
             "~a '~a' contains characters that would inject code in target output"
             context s))))

;; A leading `@` is allowed exactly once, matching npm's scoped-package
;; specifier shape (`@scope/pkg`, `@scope/pkg/sub`) — emit-js.rkt's
;; `emit-module-header` already special-cases an `@`-prefixed namespace
;; (passes it through verbatim as the JS import specifier), so this validator
;; must accept what that emission path already handles. `@` is restricted to
;; the first character only; the character class for the remainder is
;; unchanged, so this stays exactly as strict against injection as before.
(define valid-module-path-rx #rx"^@?[a-zA-Z0-9._/-]+$")
(define (validate-module-path! sym)
  (when (symbol? sym)
    (define s (symbol->string sym))
    (unless (regexp-match? valid-module-path-rx s)
      (error 'beagle
             "require namespace '~a' contains invalid characters"
             s))
    (when (regexp-match? #rx"(^|[./])\\.\\.($|[./])" s)
      (error 'beagle
             "require namespace '~a' contains '..' path traversal"
             s))))

;; --- source locations ------------------------------------------------------
;; A position carries line/col/source PLUS an origin tag and a canonical
;; flag, mirroring Lean's SourceInfo (original / synthetic(canonical?) /
;; none). `origin` is one of:
;;   'original  — built straight from the author's syntax object.
;;   'synthetic — produced by a desugar/macro expansion (generated code).
;;   'none      — no real position.
;; `canonical` only matters for synthetic positions: when #t, the position
;; is to be trusted for blame *as if the user wrote it* (Lean's `canonical`
;; flag), so canonical-aware blame can skip incidental synthetic glue while
;; still pointing at a synthetic-but-trustworthy spot (e.g. a macro call
;; site that a generated node should be blamed on). Original positions are
;; always blamable; canonical synthetic ones are too.
;;
;; `pos` is the 1-based absolute CHARACTER offset (syntax-position). Unlike
;; `col` (syntax-column, which expands tabs to tab-stops and so is NOT a
;; codepoint index), `pos` is a true codepoint offset and is the right thing
;; for slicing/injecting into source text. #f when unavailable.
;; `span` (syntax-span, char count) added for #33 typed-AST facts: the (pos,span)
;; pair is the join key between check's per-node types and the datum facts (pos
;; alone collides — a node + its first child share a start pos). #f when unknown.
(struct src-loc (line col source origin canonical pos span) #:transparent)

(define (stx->src-loc s)
  (and (syntax? s)
       (let ([line (syntax-line s)]
             [src  (syntax-source s)])
         (and line (src-loc line (syntax-column s) src 'original #f
                            (syntax-position s) (syntax-span s))))))

;; Derive a synthetic position from a base (a src-loc or a syntax object),
;; optionally flagged canonical. This is the analog of Lean's
;; `SourceInfo.fromRef … (canonical := …)`: a generated node borrows a real
;; span but records that it is generated. Returns #f if no base position.
(define (synthetic-src-loc base #:canonical? [canonical? #f])
  (define l (cond [(src-loc? base) base]
                  [(syntax? base) (stx->src-loc base)]
                  [else #f]))
  (and l (src-loc (src-loc-line l) (src-loc-col l) (src-loc-source l)
                  'synthetic canonical? (src-loc-pos l) (src-loc-span l))))

;; Blame predicate for canonical-aware lookup: an original position, or a
;; synthetic one explicitly marked canonical, is trustworthy to blame.
;; Non-canonical synthetic glue is not. (Lean's `canonicalOnly` lookup.)
(define (loc-blamable? loc)
  (and (src-loc? loc)
       (or (eq? (src-loc-origin loc) 'original)
           (src-loc-canonical loc))))

;; --- syntax objects ---------------------------------------------------------
;;
;; The reader and parser still exchange Racket syntax objects because the
;; parser's source-location machinery is built around them.  Macro expansion
;; crosses a narrower, immutable membrane: one of the syntax-* values below.
;; `beagle-syntax->datum` is intentionally lossy and is used only by the legacy
;; parser/evaluator adapters.  Quoted data is never recursively classified as
;; identifiers.

(struct reader-metadata (source-bytes delimiter) #:transparent)
(struct structural-name (qualifier leaf provider-id) #:transparent)
(struct expansion-origin (macro-id call-span parent) #:transparent)

(struct syntax-atom (datum span scopes origin properties) #:transparent)
(struct syntax-ident (name span scopes origin properties) #:transparent)
(struct syntax-list (children span scopes origin properties) #:transparent)
(struct syntax-vector (children span scopes origin properties) #:transparent)
(struct syntax-quote (datum span scopes origin properties) #:transparent)
(struct syntax-unquote (child splicing? span scopes origin properties) #:transparent)

(define empty-scope-set (set))

(define (ensure-syntax-span who value)
  (unless (or (src-loc? value) (not value))
    (raise-argument-error who "(or/c src-loc? #f)" value)))

(define (ensure-syntax-scopes who value)
  (unless (and (set? value) (not (set-mutable? value)))
    (raise-argument-error who "immutable-set?" value)))

(define (ensure-syntax-origin who value)
  (unless (or (expansion-origin? value) (not value))
    (raise-argument-error who "(or/c expansion-origin? #f)" value)))

(define (ensure-syntax-properties who value)
  (unless (and (hash? value) (immutable? value))
    (raise-argument-error who "immutable-hash?" value)))

(define (ensure-syntax-context who span scopes origin properties)
  (ensure-syntax-span who span)
  (ensure-syntax-scopes who scopes)
  (ensure-syntax-origin who origin)
  (ensure-syntax-properties who properties))

(define (make-structural-name qualifier leaf [provider-id #f])
  (unless (or (symbol? qualifier) (not qualifier))
    (raise-argument-error 'make-structural-name "(or/c symbol? #f)" qualifier))
  (unless (symbol? leaf)
    (raise-argument-error 'make-structural-name "symbol?" leaf))
  (structural-name qualifier leaf provider-id))

(define (structural-name->symbol name)
  (unless (structural-name? name)
    (raise-argument-error 'structural-name->symbol "structural-name?" name))
  (if (structural-name-qualifier name)
      (string->symbol
       (string-append
        (symbol->string (structural-name-qualifier name))
        "/"
        (symbol->string (structural-name-leaf name))))
      (structural-name-leaf name)))

(define (qualified-ref->structural-name ref)
  (unless (qualified-ref? ref)
    (raise-argument-error
     'qualified-ref->structural-name "qualified-ref?" ref))
  (make-structural-name
   (qualified-ref-qualifier ref)
   (qualified-ref-name ref)
   (qualified-ref-provider-id ref)))

(define (structural-name->qualified-ref name)
  (unless (structural-name? name)
    (raise-argument-error
     'structural-name->qualified-ref "structural-name?" name))
  (qualified-ref
   (structural-name-qualifier name)
   (structural-name-leaf name)
   (structural-name-provider-id name)))

(define (symbol->structural-name symbol)
  (unless (symbol? symbol)
    (raise-argument-error 'symbol->structural-name "symbol?" symbol))
  (define spelling (symbol->string symbol))
  (define slash (regexp-match-positions #rx"/" spelling))
  (if (and slash
           (positive? (caar slash))
           (< (cdar slash) (string-length spelling)))
      (make-structural-name
       (string->symbol (substring spelling 0 (caar slash)))
       (string->symbol (substring spelling (cdar slash))))
      (make-structural-name #f symbol)))

(define (make-expansion-origin macro-id call-span [parent #f])
  (unless (or (symbol? macro-id) (string? macro-id))
    (raise-argument-error
     'make-expansion-origin "(or/c symbol? string?)" macro-id))
  (ensure-syntax-span 'make-expansion-origin call-span)
  (unless (or (expansion-origin? parent) (not parent))
    (raise-argument-error
     'make-expansion-origin "(or/c expansion-origin? #f)" parent))
  (expansion-origin macro-id call-span parent))

(define (make-syntax-atom datum span
                          [scopes empty-scope-set]
                          [origin #f]
                          [properties #hasheq()])
  (ensure-syntax-context 'make-syntax-atom span scopes origin properties)
  (syntax-atom datum span scopes origin properties))

(define (make-syntax-ident name span
                           [scopes empty-scope-set]
                           [origin #f]
                           [properties #hasheq()])
  (unless (structural-name? name)
    (raise-argument-error 'make-syntax-ident "structural-name?" name))
  (ensure-syntax-context 'make-syntax-ident span scopes origin properties)
  (syntax-ident name span scopes origin properties))

(define (ensure-syntax-children who children)
  (unless (and (list? children) (andmap beagle-syntax? children))
    (raise-argument-error who "(listof beagle-syntax?)" children)))

(define (make-syntax-list children span
                          [scopes empty-scope-set]
                          [origin #f]
                          [properties #hasheq()])
  (ensure-syntax-children 'make-syntax-list children)
  (ensure-syntax-context 'make-syntax-list span scopes origin properties)
  (syntax-list children span scopes origin properties))

(define (make-syntax-vector children span
                            [scopes empty-scope-set]
                            [origin #f]
                            [properties #hasheq()])
  (ensure-syntax-children 'make-syntax-vector children)
  (ensure-syntax-context 'make-syntax-vector span scopes origin properties)
  (syntax-vector children span scopes origin properties))

(define (make-syntax-quote datum span
                           [scopes empty-scope-set]
                           [origin #f]
                           [properties #hasheq()])
  (ensure-syntax-context 'make-syntax-quote span scopes origin properties)
  (syntax-quote datum span scopes origin properties))

(define (make-syntax-unquote child span
                             [scopes empty-scope-set]
                             [origin #f]
                             [properties #hasheq()]
                             #:splicing? [splicing? #f])
  (unless (beagle-syntax? child)
    (raise-argument-error 'make-syntax-unquote "beagle-syntax?" child))
  (ensure-syntax-context 'make-syntax-unquote span scopes origin properties)
  (syntax-unquote child splicing? span scopes origin properties))

(define (beagle-syntax? value)
  (or (syntax-atom? value)
      (syntax-ident? value)
      (syntax-list? value)
      (syntax-vector? value)
      (syntax-quote? value)
      (syntax-unquote? value)))

(define (beagle-syntax-span value)
  (cond
    [(syntax-atom? value) (syntax-atom-span value)]
    [(syntax-ident? value) (syntax-ident-span value)]
    [(syntax-list? value) (syntax-list-span value)]
    [(syntax-vector? value) (syntax-vector-span value)]
    [(syntax-quote? value) (syntax-quote-span value)]
    [(syntax-unquote? value) (syntax-unquote-span value)]
    [else
     (raise-argument-error 'beagle-syntax-span "beagle-syntax?" value)]))

(define (beagle-syntax-scopes value)
  (cond
    [(syntax-atom? value) (syntax-atom-scopes value)]
    [(syntax-ident? value) (syntax-ident-scopes value)]
    [(syntax-list? value) (syntax-list-scopes value)]
    [(syntax-vector? value) (syntax-vector-scopes value)]
    [(syntax-quote? value) (syntax-quote-scopes value)]
    [(syntax-unquote? value) (syntax-unquote-scopes value)]
    [else
     (raise-argument-error 'beagle-syntax-scopes "beagle-syntax?" value)]))

(define (beagle-syntax-origin value)
  (cond
    [(syntax-atom? value) (syntax-atom-origin value)]
    [(syntax-ident? value) (syntax-ident-origin value)]
    [(syntax-list? value) (syntax-list-origin value)]
    [(syntax-vector? value) (syntax-vector-origin value)]
    [(syntax-quote? value) (syntax-quote-origin value)]
    [(syntax-unquote? value) (syntax-unquote-origin value)]
    [else
     (raise-argument-error 'beagle-syntax-origin "beagle-syntax?" value)]))

(define (beagle-syntax-properties value)
  (cond
    [(syntax-atom? value) (syntax-atom-properties value)]
    [(syntax-ident? value) (syntax-ident-properties value)]
    [(syntax-list? value) (syntax-list-properties value)]
    [(syntax-vector? value) (syntax-vector-properties value)]
    [(syntax-quote? value) (syntax-quote-properties value)]
    [(syntax-unquote? value) (syntax-unquote-properties value)]
    [else
     (raise-argument-error 'beagle-syntax-properties "beagle-syntax?" value)]))

(define (beagle-syntax-property value key [default #f])
  (hash-ref (beagle-syntax-properties value) key default))

(define (beagle-syntax-reader-metadata value)
  (beagle-syntax-property value 'reader #f))

(define (syntax-keyword-symbol? value)
  (and (symbol? value)
       (let ([text (symbol->string value)])
         (and (positive? (string-length text))
              (char=? (string-ref text 0) #\:)))))

(define (datum->beagle-syntax datum span
                              [scopes empty-scope-set]
                              [origin #f]
                              [properties #hasheq()])
  (cond
    [(beagle-syntax? datum) datum]
    [(and (symbol? datum) (not (syntax-keyword-symbol? datum)))
     (make-syntax-ident
      (symbol->structural-name datum) span scopes origin properties)]
    [(and (list? datum)
          (= (length datum) 2)
          (eq? (car datum) 'quote))
     (make-syntax-quote (cadr datum) span scopes origin properties)]
    [(and (list? datum)
          (= (length datum) 2)
          (memq (car datum) '(unquote unquote-splicing)))
     (make-syntax-unquote
      (datum->beagle-syntax (cadr datum) span scopes origin properties)
      span scopes origin properties
      #:splicing? (eq? (car datum) 'unquote-splicing))]
    [(bracketed? datum)
     (make-syntax-vector
      (map (lambda (child)
             (datum->beagle-syntax child span scopes origin properties))
           (bracket-body datum))
      span scopes origin properties)]
    [(list? datum)
     (make-syntax-list
      (map (lambda (child)
             (datum->beagle-syntax child span scopes origin properties))
           datum)
      span scopes origin properties)]
    [(vector? datum)
     (make-syntax-vector
      (map (lambda (child)
             (datum->beagle-syntax child span scopes origin properties))
           (vector->list datum))
      span scopes origin properties)]
    [else (make-syntax-atom datum span scopes origin properties)]))

(define (beagle-syntax->datum value)
  (cond
    [(syntax-atom? value) (syntax-atom-datum value)]
    [(syntax-ident? value)
     (structural-name->symbol (syntax-ident-name value))]
    [(syntax-list? value)
     (map beagle-syntax->datum (syntax-list-children value))]
    [(syntax-vector? value)
     (cons BRACKET-TAG
           (map beagle-syntax->datum (syntax-vector-children value)))]
    [(syntax-quote? value) (list 'quote (syntax-quote-datum value))]
    [(syntax-unquote? value)
     (list (if (syntax-unquote-splicing? value)
               'unquote-splicing
               'unquote)
           (beagle-syntax->datum (syntax-unquote-child value)))]
    [else
     (raise-argument-error
      'beagle-syntax->datum "beagle-syntax?" value)]))

(define (syntax-delimiter datum)
  (cond
    [(bracketed? datum) 'bracket]
    [(map-tagged? datum) 'brace]
    [(set-tagged? datum) 'set]
    [(and (list? datum) (pair? datum) (eq? (car datum) 'quote)) 'quote]
    [(and (list? datum) (pair? datum) (eq? (car datum) 'quasiquote))
     'quasiquote]
    [(and (list? datum) (pair? datum) (eq? (car datum) 'unquote-splicing))
     'unquote-splicing]
    [(and (list? datum) (pair? datum) (eq? (car datum) 'unquote)) 'unquote]
    [(list? datum) 'paren]
    [else #f]))

(define (syntax-source-slice source-bytes stx)
  (and source-bytes
       (syntax-position stx)
       (syntax-span stx)
       (let* ([source-text (bytes->string/utf-8 source-bytes)]
              [start (sub1 (syntax-position stx))]
              [end (+ start (syntax-span stx))])
         (and (<= 0 start end (string-length source-text))
              (string->bytes/utf-8 (substring source-text start end))))))

(define (reader-properties stx datum source-bytes)
  (hasheq
   'reader
   (reader-metadata
    (or (syntax-source-slice source-bytes stx) #"")
    (syntax-delimiter datum))))

(define (racket-syntax->beagle-syntax stx [source-bytes #f])
  (unless (syntax? stx)
    (raise-argument-error
     'racket-syntax->beagle-syntax "syntax?" stx))
  (define datum (syntax->datum stx))
  (define span (stx->src-loc stx))
  (define properties (reader-properties stx datum source-bytes))
  (define children (syntax->list stx))
  (cond
    [(and (symbol? datum) (not (syntax-keyword-symbol? datum)))
     (make-syntax-ident
      (symbol->structural-name datum) span empty-scope-set #f properties)]
    [(and (list? datum) (= (length datum) 2) (eq? (car datum) 'quote))
     (make-syntax-quote
      (cadr datum) span empty-scope-set #f properties)]
    [(and (list? datum)
          (= (length datum) 2)
          (memq (car datum) '(unquote unquote-splicing)))
     (make-syntax-unquote
      (if (and children (= (length children) 2))
          (racket-syntax->beagle-syntax (cadr children) source-bytes)
          (datum->beagle-syntax (cadr datum) span))
      span empty-scope-set #f properties
      #:splicing? (eq? (car datum) 'unquote-splicing))]
    [(bracketed? datum)
     (make-syntax-vector
      (if children
          (map (lambda (child)
                 (racket-syntax->beagle-syntax child source-bytes))
               (cdr children))
          (map (lambda (child) (datum->beagle-syntax child span))
               (bracket-body datum)))
      span empty-scope-set #f properties)]
    [(list? datum)
     (make-syntax-list
      (if children
          (map (lambda (child)
                 (racket-syntax->beagle-syntax child source-bytes))
               children)
          (map (lambda (child) (datum->beagle-syntax child span)) datum))
      span empty-scope-set #f properties)]
    [else
     (make-syntax-atom datum span empty-scope-set #f properties)]))

(define (src-loc->syntax-source loc)
  (and loc
       (vector (src-loc-source loc)
               (src-loc-line loc)
               (src-loc-col loc)
               (src-loc-pos loc)
               (src-loc-span loc))))

(define (beagle-syntax->racket-syntax value)
  (unless (beagle-syntax? value)
    (raise-argument-error
     'beagle-syntax->racket-syntax "beagle-syntax?" value))
  (define source (src-loc->syntax-source (beagle-syntax-span value)))
  (define datum
    (cond
      [(syntax-atom? value) (syntax-atom-datum value)]
      [(syntax-ident? value)
       (structural-name->symbol (syntax-ident-name value))]
      [(syntax-list? value)
       (map beagle-syntax->racket-syntax (syntax-list-children value))]
      [(syntax-vector? value)
       (cons BRACKET-TAG
             (map beagle-syntax->racket-syntax
                  (syntax-vector-children value)))]
      [(syntax-quote? value) (list 'quote (syntax-quote-datum value))]
      [(syntax-unquote? value)
       (list (if (syntax-unquote-splicing? value)
                 'unquote-splicing
                 'unquote)
             (beagle-syntax->racket-syntax
              (syntax-unquote-child value)))]))
  (datum->syntax #f datum source))

(define (->datum x) (if (syntax? x) (syntax->datum x) x))
(define (stx-subs x) (and (syntax? x) (syntax->list x)))
(define (stx-ref subs n) (and subs (> (length subs) n) (list-ref subs n)))
(define (stx-tail subs n) (and subs (>= (length subs) n) (list-tail subs n)))

(define current-registry (make-parameter #f))
(define current-source-bytes (make-parameter #f))
(define current-src-table (make-parameter #f))
;; Side-table mapping the eq?-identity of a body list (e.g. defn-form's
;; body) to a parallel list of src-loc for each body element. Populated by
;; parse-body. Lets diagnostics that fire on bare-symbol body elements
;; (where src-for returns #f because symbols can't be stored in src-table)
;; recover positional srcloc. See store-src! comment for the underlying
;; symbol-storage limitation this side-table works around.
(define current-body-locs-table (make-parameter #f))

;; Look up the src-loc of an AST node, falling back to body-list positional
;; metadata when the node is a bare symbol/literal that store-src! refuses.
;; BODY-LIST + POS form a positional anchor recoverable from any code that
;; holds the list and an index — see check.rkt's return-type diag.
(define (body-loc-at body-list pos)
  (define tbl (current-body-locs-table))
  (and tbl (let ([locs (hash-ref tbl body-list #f)])
             (and locs (>= pos 0) (< pos (length locs))
                  (list-ref locs pos)))))

;; Cross-pass storage for the body-locs-table, keyed by program identity.
;; parse.rkt populates this after parse-program completes; check.rkt
;; recovers it via program-body-locs-table to keep current-body-locs-table
;; set during the type-check pass (where the parse-time parameter is no
;; longer in scope).
(define PROGRAM->BODY-LOCS (make-weak-hasheq))
(define (register-program-body-locs-table! prog tbl)
  (hash-set! PROGRAM->BODY-LOCS prog tbl))
(define (program-body-locs-table prog)
  (hash-ref PROGRAM->BODY-LOCS prog #f))

(define (store-src! node loc)
  ;; Only the FIRST write for a node wins. Parse-time rewrites
  ;; (when/->/-if-let/...) call (parse-expr synthesized-syntax) from
  ;; inside the surface form's parse-expr frame; the inner parse-expr
  ;; populates the table with the synthesized form's srcloc (which is
  ;; the operative blame position), and the outer parse-expr's
  ;; store-src! must NOT clobber it with the surface sugar's loc.
  ;; The `hash-has-key?` guard preserves this innermost-wins invariant.
  ;;
  ;; Symbols, strings, booleans, and numbers are EXCLUDED — they're
  ;; interned/shared, so storing per occurrence would cross-pollute
  ;; (the same `'x` symbol appears in many positions; the FIRST
  ;; occurrence's loc would shadow all others). The downside: when a
  ;; diagnostic fires on a bare-symbol AST leaf (e.g. defn body =
  ;; just `x`), src-for returns #f and the diagnostic falls back to
  ;; the parent form's loc. That's a known limitation tracked in
  ;; sourcemap-fidelity.rkt — closing it requires either (a) symbol
  ;; uninterning at parse time, (b) a position-keyed side-table, or
  ;; (c) syntax-walking inside check.rkt's return-type diag.
  (when (and loc (current-src-table)
             (not (string? node)) (not (boolean? node))
             (not (number? node)) (not (symbol? node))
             (not (hash-has-key? (current-src-table) node)))
    (hash-set! (current-src-table) node loc))
  node)

;; --- per-node inferred-type capture (the delaborator's input) ----------------
;; Mirrors the src-table: the checker records each expression node's INFERRED
;; type here, so a renderer (types-as-view / beagle-explain-type) can PROJECT
;; "doubled: (Vec Int)" with no type living in the source. This is the
;; anti-reification half of types-as-view — a pure side-channel derived from
;; the check pass, never stored in or drifting from the program. Same
;; interned-leaf exclusion as store-src! (bare symbols/literals are shared,
;; so they can't be keyed by identity); non-leaf nodes (call-form, …) are
;; captured. Populated at the infer-expr choke point in check.rkt.
(define current-type-table (make-parameter #f))

(define (store-type! node ty)
  ;; Last-write-wins: a node may be inferred more than once (and/or args,
  ;; narrowed branches) but its type is stable, so overwriting is harmless.
  (when (and ty (current-type-table)
             (not (string? node)) (not (boolean? node))
             (not (number? node)) (not (symbol? node)))
    (hash-set! (current-type-table) node ty))
  ty)

;; Cross-pass storage for the type-table, keyed by program identity (mirrors
;; PROGRAM->BODY-LOCS): type-check-with-locs! registers the populated table so
;; tools can read per-node inferred types after the check pass completes.
(define PROGRAM->TYPES (make-weak-hasheq))
(define (register-program-type-table! prog tbl)
  (hash-set! PROGRAM->TYPES prog tbl))
(define (program-type-table prog)
  (hash-ref PROGRAM->TYPES prog #f))

;; Checked lexical binder types are a cross-pass side table.  Parameter and
;; destructuring ASTs retain authored syntax; emitters read this table to make
;; representation decisions for every name projected out of an aggregate.
(define PROGRAM->BINDER-TYPES (make-weak-hasheq))
(define current-binder-type-table (make-parameter #f))
(define (register-program-binder-type-table! prog tbl)
  (hash-set! PROGRAM->BINDER-TYPES prog tbl))
(define (program-binder-type-table prog)
  (hash-ref PROGRAM->BINDER-TYPES prog #f))
(define (store-binder-type! binding name ty)
  (when (and ty (current-binder-type-table))
    (define by-name
      (hash-ref! (current-binder-type-table) binding make-hasheq))
    (hash-set! by-name name ty))
  ty)
(define (binding-projected-types prog binding)
  (define tbl (program-binder-type-table prog))
  (and tbl (hash-ref tbl binding #f)))

;; Definition-local inference derives effective types without rewriting the
;; authored AST.  The checker registers its finalized result here so every
;; downstream publication boundary reads one shared, program-identity-scoped
;; source of truth for values and callables alike.
(define PROGRAM->EFFECTIVE-DEFINITION-TYPES (make-weak-hasheq))
(define (register-program-effective-definition-types! prog table)
  (hash-set! PROGRAM->EFFECTIVE-DEFINITION-TYPES prog table))
(define (program-effective-definition-types prog)
  (hash-ref PROGRAM->EFFECTIVE-DEFINITION-TYPES prog #f))
(define (program-effective-definition-type prog name [fallback #f])
  (define table (program-effective-definition-types prog))
  (if table (hash-ref table name fallback) fallback))

;; Callable synchronization effects are inferred transitively without
;; rewriting authored function signatures. Module-interface publication and
;; binding-constraint proof both read this program-identity-scoped authority.
(define PROGRAM->CALLABLE-SYNCHRONOUS (make-weak-hasheq))
(define (register-program-callable-synchronous! prog table)
  (hash-set! PROGRAM->CALLABLE-SYNCHRONOUS prog table))
(define (program-callable-synchronous-table prog)
  (hash-ref PROGRAM->CALLABLE-SYNCHRONOUS prog #f))
(define (program-callable-synchronous? prog name [fallback #f])
  (define table (program-callable-synchronous-table prog))
  (if table (hash-ref table name fallback) fallback))

;; Distinct from executing a callable synchronously: this proves that invoking
;; it returns a callable whose own invocation is synchronous on every path.
;; Binding constraints need this effect when their predicate is call-produced.
(define PROGRAM->RETURNS-SYNCHRONOUS-CALLABLE (make-weak-hasheq))
(define (register-program-returns-synchronous-callable! prog table)
  (hash-set! PROGRAM->RETURNS-SYNCHRONOUS-CALLABLE prog table))
(define (program-returns-synchronous-callable-table prog)
  (hash-ref PROGRAM->RETURNS-SYNCHRONOUS-CALLABLE prog #f))
(define (program-returns-synchronous-callable? prog name [fallback #f])
  (define table (program-returns-synchronous-callable-table prog))
  (if table (hash-ref table name fallback) fallback))

;; --- qualified references -------------------------------------------------

;; Authored qualification stays distinct from resolver identity: QUALIFIER is
;; the source spelling, NAME is the leaf, and PROVIDER-ID is #f until the
;; resolver attaches the canonical provider identity.
(struct qualified-ref (qualifier name provider-id) #:transparent)

;; --- symbol predicates -----------------------------------------------------
(define (dot-method-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\.)))))

(define (static-method-ref? ref)
  (and (qualified-ref? ref)
       (let ([qualifier (symbol->string (qualified-ref-qualifier ref))])
         (and (positive? (string-length qualifier))
              (or (char-upper-case? (string-ref qualifier 0))
                  (string=? qualifier "js"))))))

(define (dynamic-var-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (>= (string-length s) 3)
              (char=? (string-ref s 0) #\*)
              (char=? (string-ref s (- (string-length s) 1)) #\*)))))

(define (constructor-sym? sym)
  ;; `Foo.` (bare) or `java.io.FileOutputStream.` (FQCN). A trailing `.`, and the
  ;; CLASS segment (last dotted segment before the trailing dot) is capitalized —
  ;; so an FQCN ctor (lowercase package prefix) is recognized too, while a plain
  ;; lowercase dotted name (x.foo.) is not.
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s (- (string-length s) 1)) #\.)
              (let* ([body (substring s 0 (- (string-length s) 1))]
                     [cls-start
                      (let loop ([i (- (string-length body) 1)])
                        (cond [(< i 0) 0]
                              [(char=? (string-ref body i) #\.) (+ i 1)]
                              [else (loop (- i 1))]))])
                (and (< cls-start (string-length body))
                     (char-upper-case? (string-ref body cls-start))))))))

(define (keyword-sym? sym)
  (and (symbol? sym)
       (let ([s (symbol->string sym)])
         (and (> (string-length s) 1)
              (char=? (string-ref s 0) #\:)))))

;; --- parse-expr / parse-params injection -----------------------------------
(define current-parse-expr (make-parameter #f))
(define current-parse-params (make-parameter #f))

;; --- AST -------------------------------------------------------------------

(struct ns-decl     (name)                                  #:transparent)
;; doc: optional docstring (String or #f). Real Clojure surface — carried
;; through to clj emit; ignored by nix emit and the checker.
;; dynamic?: #t when defined `(def ^:dynamic *x* …)` — a dynamic (rebindable)
;; var. Drives the `^:dynamic` metadata in clj emit and gates `binding`
;; targets in the checker. #f for ordinary defs.
(struct def-form    (name type value doc dynamic?)          #:transparent)
(struct defn-form   (name params rest-param return-type body private? raises doc) #:transparent)
(struct defn-multi  (name arities private? doc)               #:transparent)
(struct arity-clause (params rest-param return-type body)    #:transparent)
(struct fn-form     (params rest-param return-type body)    #:transparent)
(struct let-form    (bindings body)                         #:transparent)
;; binding-form: Clojure `(binding [*x* v …] body…)` — dynamic-extent
;; rebinding of dynamic vars. bindings is a list of let-binding (type #f);
;; each name must reference a `^:dynamic` var (enforced in check). Distinct
;; from let-form: targets are existing dynamic vars, not new lexical locals.
(struct binding-form (bindings body)                        #:transparent)
(struct if-form     (cond-expr then-expr else-expr)         #:transparent)
(struct cond-form   (clauses)                               #:transparent)
(struct cond-clause (test body)                             #:transparent)
(struct when-form   (cond-expr body)                        #:transparent)
(struct do-form     (body)                                  #:transparent)
(struct call-form   (fn args)                               #:transparent)
(struct vec-form    (items)                                 #:transparent)
(struct quoted      (datum)                                 #:transparent)
(struct regex-lit  (pattern)                                #:transparent)
(struct loop-form  (bindings body)                          #:transparent)
(struct recur-form (args)                                   #:transparent)
(struct for-form   (clauses body)                           #:transparent)
(struct for-binding (name expr type constraint)             #:transparent)
(struct for-when   (test)                                   #:transparent)
(struct record-form (name fields)                           #:transparent)
(struct method-call (method-name target args)               #:transparent)
(struct static-call (class+method args)                     #:transparent)
(struct dynamic-var (name)                                  #:transparent)
(struct map-form   (pairs)                                  #:transparent)
(struct set-form   (items)                                  #:transparent)
(struct kw-access  (kw target default)                       #:transparent)
(struct try-form    (body catches finally-body)             #:transparent)
(struct catch-clause (exception-type name body)            #:transparent)
(struct doseq-form  (clauses body)                         #:transparent)
(struct case-form   (test clauses default)                 #:transparent)
(struct case-clause (value body)                           #:transparent)
(struct new-form    (class-name args)                      #:transparent)
(struct protocol-form (name methods)                       #:transparent)
(struct protocol-method (name params rest-param return-type) #:transparent)
(struct defmulti-form (name dispatch-fn)                   #:transparent)
(struct defmethod-form (name dispatch-val params body)     #:transparent)

(struct with-form   (target updates)                          #:transparent)
(struct with-update (field-kw value)                          #:transparent)
(struct defenum-form (name values)                            #:transparent)
(struct defunion-form (name members type-params member-fields) #:transparent)
(struct deferror-form (name members member-fields)            #:transparent)
(struct defscalar-form (name backing-type predicates)         #:transparent)
(struct scalar-predicate (op value)                           #:transparent)

(struct match-form  (target clauses)                         #:transparent)
(struct match-clause (pattern body)                          #:transparent)
(struct pat-wildcard ()                                      #:transparent)
(struct pat-literal  (value)                                 #:transparent)
(struct pat-record   (type-name bindings)                    #:transparent)
(struct pat-map      (entries)                               #:transparent)
(struct pat-var      (name)                                  #:transparent)
;; Pattern combinators. pat-or holds a list of alternative sub-patterns;
;; matches if any alternative matches. Designed as a combinator (sub-pattern
;; list) so future operators (pat-and, pat-not, pat-guard) slot in as
;; sibling structs without restructuring the match parser or evaluator.
(struct pat-or       (alternatives)                          #:transparent)

(struct check-expr  (expr)                                   #:transparent)
(struct rescue-form (expr fallback err-name)                 #:transparent)
(struct target-case-form (cases)                             #:transparent)

(struct with-meta   (metadata expr)                          #:transparent)
;; threading-marker: a transparent wrapper produced by the threading-family
;; parse-time rewrites (->, ->>, as->, cond->, cond->>, some->, some->>).
;; KIND is the surface symbol (e.g. '->); ORIG-ARGS is the list of parsed
;; surface arg AST nodes; DESUGARED is the rewritten AST that downstream
;; passes (check, emit-nix) walk through. emit-clj recognizes the marker
;; and emits the surface threading form instead of the desugared call chain.
(struct threading-marker (kind orig-args desugared)           #:transparent)
(struct when-let-form  (name expr body)                      #:transparent)
(struct if-let-form    (name expr then-body else-body)       #:transparent)
(struct when-some-form (name expr body)                      #:transparent)
(struct if-some-form   (name expr then-body else-body)       #:transparent)
(struct with-open-form (bindings body)                       #:transparent)
(struct doto-form      (target forms)                        #:transparent)
(struct for-let        (bindings)                            #:transparent)
(struct dotimes-form   (name count-expr body)                #:transparent)
(struct condp-form     (pred-fn test-expr clauses default)   #:transparent)
(struct defonce-form   (name type value doc)                 #:transparent)
(struct await-form    (expr)                                 #:transparent)
(struct set!-form    (target value)                           #:transparent)
(struct letfn-form   (fns body)                              #:transparent)
(struct letfn-fn     (name params rest-param return-type body) #:transparent)

;; --- Generic block string --------------------------------------------------
(struct block-string (text tag) #:transparent)

;; --- Nix-specific AST nodes ------------------------------------------------
(struct nix-inherit        (names)                            #:transparent)
(struct nix-inherit-from   (ns-expr names)                    #:transparent)
(struct nix-with           (ns-expr body)                     #:transparent)
(struct nix-rec-attrs      (pairs)                            #:transparent)
(struct nix-assert         (cond-expr body)                   #:transparent)
(struct nix-get-or         (base-expr path default)           #:transparent)
(struct nix-has-attr       (base-expr path)                   #:transparent)
(struct nix-search-path    (name)                             #:transparent)
(struct nix-interpolated-string (parts)                       #:transparent)
(struct nix-multiline-string (lines)                          #:transparent)
(struct nix-path           (path-string)                      #:transparent)
(struct nix-fn-set         (formals rest? at-name body)       #:transparent)
(struct nix-fn-set-formal  (name default)                     #:transparent)
(struct nix-derivation     (attrs)                            #:transparent)
(struct nix-flake          (attrs)                            #:transparent)
(struct nix-with-cfg       (path body)                        #:transparent)

;; --- JS/quote AST nodes ---------------------------------------------------
(struct js-quote-form    (body)                               #:transparent)

(struct js-ast-block     (stmts)                              #:transparent)
(struct js-ast-const     (name value)                         #:transparent)
(struct js-ast-let       (name value)                         #:transparent)
(struct js-ast-assign    (target value)                       #:transparent)
(struct js-ast-return    (expr)                               #:transparent)
(struct js-ast-if        (test then else-branch)              #:transparent)
(struct js-ast-for-of    (binding iterable body)              #:transparent)
(struct js-ast-while     (test body)                          #:transparent)
(struct js-ast-throw     (expr)                               #:transparent)
(struct js-ast-try       (body catch-name catch-body finally-body) #:transparent)
(struct js-ast-expr-stmt (expr)                               #:transparent)

(struct js-ast-function  (name params body async? export?)    #:transparent)
(struct js-ast-class     (name extends-expr methods)          #:transparent)
(struct js-ast-method    (name params body static? async? kind) #:transparent)

(struct js-ast-call      (callee args)                        #:transparent)
(struct js-ast-member    (object property computed?)          #:transparent)
(struct js-ast-index     (object index-expr)                  #:transparent)
(struct js-ast-arrow     (params body)                        #:transparent)
(struct js-ast-ternary   (test then else-expr)                #:transparent)
(struct js-ast-binary    (op left right)                      #:transparent)
(struct js-ast-unary     (op expr prefix?)                    #:transparent)
(struct js-ast-template  (parts)                              #:transparent)
(struct js-ast-array     (items)                              #:transparent)
(struct js-ast-object    (pairs)                              #:transparent)
(struct js-ast-spread    (expr)                               #:transparent)
(struct js-ast-await     (expr)                               #:transparent)
(struct js-ast-new       (callee args)                        #:transparent)
(struct js-ast-typeof    (expr)                               #:transparent)
(struct js-ast-ident     (name)                               #:transparent)
(struct js-ast-literal   (value)                              #:transparent)
(struct js-ast-splice-expr (beagle-expr)                      #:transparent)
(struct js-ast-splice-stmts (beagle-expr)                     #:transparent)
(struct js-ast-splice-json (beagle-expr)                      #:transparent)

;; --- Typed JS target AST (js/* forms) — minimal set -------------------------
;; Only forms with no core beagle equivalent.
(struct jst-return   (expr)                                       #:transparent)
(struct jst-class    (name extends methods export?)               #:transparent)
(struct jst-method   (name params rest-param return-type body static? async? kind) #:transparent)
(struct jst-dot      (object property)                            #:transparent)
(struct jst-selector (name)                                       #:transparent)
(struct jst-get      (receiver key)                               #:transparent)
(struct jst-call     (receiver key args)                          #:transparent)
(struct jst-set      (receiver key value)                         #:transparent)
(struct jst-new      (callee args)                                #:transparent)
(struct jst-delete   (receiver key)                               #:transparent)
(struct jst-in       (receiver key)                               #:transparent)
(struct jst-spread   (expr)                                       #:transparent)
(struct jst-typeof   (expr)                                       #:transparent)
(struct jst-template (parts)                                      #:transparent)
(struct jst-binary   (op left right)                              #:transparent)
(struct jst-unary    (op expr)                                    #:transparent)
(struct jst-export   (form)                                       #:transparent)
(struct jst-export-default (form)                                 #:transparent)
(struct jst-import-meta ()                                        #:transparent)

;; Metadata and export markers wrap a definition without changing what it
;; defines: any pass dispatching on definition shape must unwrap first, or a
;; wrapped definition silently leaves that pass's table.
(define (unwrap-definition-form form)
  (cond
    [(with-meta? form) (unwrap-definition-form (with-meta-expr form))]
    [(jst-export? form) (unwrap-definition-form (jst-export-form form))]
    [(jst-export-default? form)
     (unwrap-definition-form (jst-export-default-form form))]
    [else form]))

;; --- Shared utility structs ------------------------------------------------
(struct param       (name type constraint)                  #:transparent)
;; NAME is the parsed binding form, not necessarily an identifier.  Simple
;; binders store a symbol; typed destructuring stores a map-destructure or
;; seq-destructure and TYPE describes the incoming aggregate value. CONSTRAINT
;; is #f or a predicate expression applied to that aggregate before projection.
;; or-defaults: alist of (key-sym . default-AST) from {:keys [...] :or {...}};
;; '() when absent. keys/as-name as before. seq-destructure names may contain
;; nested map-destructure/seq-destructure structs (Clojure nested binding).
(struct map-destructure (keys as-name or-defaults)          #:transparent)

;; All symbols bound by a destructure pattern, flattened through nesting.
;; The canonical walk for scope/binding consumers (check, lint, emit-scope).
(define (destructure-bound-names p)
  (cond
    [(map-destructure? p)
     (append (map-destructure-keys p)
             (if (map-destructure-as-name p)
                 (list (map-destructure-as-name p))
                 '()))]
    [(seq-destructure? p)
     (append
      (apply append
             (for/list ([n (in-list (seq-destructure-names p))])
               (if (symbol? n) (list n) (destructure-bound-names n))))
      (if (seq-destructure-rest-name p)
          (list (seq-destructure-rest-name p))
          '()))]
    [else '()]))

;; All :or default expression ASTs in a destructure pattern, recursively.
;; Consumers infer/lint these so errors inside defaults surface normally.
(define (destructure-or-default-exprs p)
  (cond
    [(map-destructure? p)
     (map cdr (map-destructure-or-defaults p))]
    [(seq-destructure? p)
     (apply append
            (for/list ([n (in-list (seq-destructure-names p))])
              (if (symbol? n) '() (destructure-or-default-exprs n))))]
    [else '()]))
(struct seq-destructure (names rest-name)                    #:transparent)

;; Normalize the binding-bearing AST variants for downstream passes.  A param
;; wraps its target to retain an optional annotation; local binding nodes store
;; the target directly.
(define (param-binding-target p)
  (if (param? p) (param-name p) p))

(define (binding-target-bound-names target)
  (define unwrapped (param-binding-target target))
  (if (symbol? unwrapped)
      (list unwrapped)
      (destructure-bound-names unwrapped)))
;; deftype surface removed (2026-05). The canonical decomposition is defrecord
;; (data shape) + extend-type (protocol impls); parse.rkt rejects deftype at the
;; surface.
(struct extend-type-form (type-name impls)                   #:transparent)
(struct flake-input-form (input-name namespace path-segments) #:transparent)

;; `claim-form` removed. The (claim NAME TYPE) surface was deleted under
;; the Zero-users rule — the parser now rejects it with a pointed error
;; naming typed definitions as the replacement. There is no AST node
;; for claim; downstream consumers must not pattern-match on one.

(struct type-impl    (protocol-name methods)                 #:transparent)
(struct impl-method  (name params rest-param return-type body) #:transparent)
(struct let-binding (name type constraint value)            #:transparent)
(struct require-entry (ns alias refer) #:transparent)

;; --- program structure -----------------------------------------------------
(struct regex-contract (pattern-source match-type unit) #:transparent)
(struct dynamic-contract (alternatives tag-abi) #:transparent)
(struct collection-contract
  (kind key-type value-type equality hashing order layout)
  #:transparent)
(struct allocation-contract (region failure) #:transparent)
(struct error-contract (error-type payload-layout mode) #:transparent)
(struct error-payload-key-contract (keyword) #:transparent)
(struct binding-constraint-contract (synchronous? provider) #:transparent)
;; Checked representation fact for `(:field target)`. RECORD-NAME is the
;; nominal record or record-union type whose fields use Beagle's target-name
;; mangling. Emitters must not infer this from target syntax or symbol spelling.
(struct record-field-access-contract (record-name) #:transparent)
;; Checked metadata for a typed `(with record ...)` update. RECORD-NAME is the
;; exact nominal identity accepted by the checker. VALIDATOR-SYMBOL is #f for
;; an explicitly unconstrained record or the conceptual provider-owned
;; `$beagle$record$Name$validate` binding (qualified at imported use sites).
;; FIELD-ORDER is the declaration-order keyword list. Emitters require this
;; contract rather than guessing ownership from an interned symbol target.
(struct record-update-contract (record-name validator-symbol field-order)
  #:transparent)

(struct program (namespace
                 forms
                 macros
                 declared-macros
                 externs
                 declared-externs
                 requires
                 imports
                 form-stxs
                 src-table
                 semantic-contracts
                 declared-type-aliases
                 imported-type-names
                 imported-record-fields
                 imported-record-field-order
                 imported-record-ns
                 imported-scalar-fns
                 imported-scalar-preds
                 imported-symbol-ns
                 imported-union-members
                 imported-parametric-unions
                 imported-enums
                 imported-dynamic-vars
                 imported-module-interfaces
                 target
                 gen-class?)
  #:transparent)

(define DEFAULT-TARGET    'clj)
(define DEFAULT-NAMESPACE 'beagle.user)

;; --- provide ---------------------------------------------------------------
(provide
 ;; Tag utilities
 bracketed? bracket-body map-tagged? map-body set-tagged? set-body
 bracket-items bracket-stxs
 ;; Identifier safety
 validate-identifier! unsafe-ident-rx validate-module-path! valid-module-path-rx
 ;; Source locations
 (struct-out src-loc) stx->src-loc synthetic-src-loc loc-blamable?
 ->datum stx-subs stx-ref stx-tail
 ;; Macro-facing immutable syntax objects
 (struct-out reader-metadata)
 (struct-out structural-name)
 (struct-out expansion-origin)
 (struct-out syntax-atom)
 (struct-out syntax-ident)
 (struct-out syntax-list)
 (struct-out syntax-vector)
 (struct-out syntax-quote)
 (struct-out syntax-unquote)
 empty-scope-set
 make-structural-name structural-name->symbol symbol->structural-name
 qualified-ref->structural-name structural-name->qualified-ref
 make-expansion-origin
 make-syntax-atom make-syntax-ident make-syntax-list make-syntax-vector
 make-syntax-quote make-syntax-unquote
 beagle-syntax? beagle-syntax-span beagle-syntax-scopes
 beagle-syntax-origin beagle-syntax-properties beagle-syntax-property
 beagle-syntax-reader-metadata
 datum->beagle-syntax beagle-syntax->datum
 racket-syntax->beagle-syntax beagle-syntax->racket-syntax
 current-registry current-source-bytes current-src-table store-src!
 current-body-locs-table body-loc-at
 register-program-body-locs-table! program-body-locs-table
 current-type-table store-type!
 register-program-type-table! program-type-table
 current-binder-type-table store-binder-type!
 register-program-binder-type-table! program-binder-type-table
 binding-projected-types
 register-program-effective-definition-types!
 program-effective-definition-types
 program-effective-definition-type
 register-program-callable-synchronous!
 program-callable-synchronous-table
 program-callable-synchronous?
 register-program-returns-synchronous-callable!
 program-returns-synchronous-callable-table
 program-returns-synchronous-callable?
 ;; Symbol predicates
 dot-method-sym? static-method-ref? dynamic-var-sym? constructor-sym? keyword-sym?
 ;; Parse injection
 current-parse-expr current-parse-params
 ;; Constants
 DEFAULT-TARGET DEFAULT-NAMESPACE
 ;; Core AST
 (struct-out qualified-ref)
 (struct-out ns-decl)
 (struct-out def-form) (struct-out defn-form) (struct-out fn-form)
 (struct-out let-form) (struct-out binding-form) (struct-out if-form) (struct-out cond-form) (struct-out cond-clause)
 (struct-out when-form) (struct-out do-form) (struct-out call-form) (struct-out vec-form)
 (struct-out quoted) (struct-out regex-lit)
 (struct-out loop-form) (struct-out recur-form)
 (struct-out for-form) (struct-out for-binding) (struct-out for-when)
 (struct-out record-form) (struct-out method-call) (struct-out static-call)
 (struct-out dynamic-var) (struct-out map-form) (struct-out set-form)
 (struct-out kw-access) (struct-out try-form) (struct-out catch-clause)
 (struct-out doseq-form) (struct-out case-form) (struct-out case-clause)
 (struct-out new-form) (struct-out protocol-form) (struct-out protocol-method)
 (struct-out defmulti-form) (struct-out defmethod-form)
 (struct-out with-form) (struct-out with-update)
 (struct-out defenum-form) (struct-out defunion-form) (struct-out deferror-form)
 (struct-out defscalar-form) (struct-out scalar-predicate)
 (struct-out match-form) (struct-out match-clause)
 (struct-out pat-wildcard) (struct-out pat-literal) (struct-out pat-record)
 (struct-out pat-map) (struct-out pat-var) (struct-out pat-or)
 (struct-out check-expr) (struct-out rescue-form) (struct-out target-case-form)
 (struct-out with-meta)
 (struct-out threading-marker)
 (struct-out when-let-form) (struct-out if-let-form)
 (struct-out when-some-form) (struct-out if-some-form)
 (struct-out with-open-form) (struct-out doto-form) (struct-out for-let)
 (struct-out dotimes-form) (struct-out condp-form) (struct-out defonce-form)
 (struct-out await-form) (struct-out set!-form)
 (struct-out letfn-form) (struct-out letfn-fn)
 (struct-out block-string)
 (struct-out defn-multi) (struct-out arity-clause)
 ;; Shared utility structs
 (struct-out param) (struct-out map-destructure) (struct-out seq-destructure)
 param-binding-target binding-target-bound-names
 destructure-bound-names destructure-or-default-exprs
 (struct-out extend-type-form)
 (struct-out type-impl) (struct-out impl-method)
 (struct-out let-binding) (struct-out require-entry)
 ;; Program
 (struct-out regex-contract)
 (struct-out dynamic-contract)
 (struct-out collection-contract)
 (struct-out allocation-contract)
 (struct-out error-contract)
 (struct-out error-payload-key-contract)
 (struct-out binding-constraint-contract)
 (struct-out record-field-access-contract)
 (struct-out record-update-contract)
 (struct-out program)
 ;; Nix AST
 (struct-out nix-inherit) (struct-out nix-inherit-from) (struct-out nix-with)
 (struct-out nix-rec-attrs) (struct-out nix-assert) (struct-out nix-get-or)
 (struct-out nix-has-attr) (struct-out nix-search-path)
 (struct-out nix-interpolated-string) (struct-out nix-multiline-string)
 (struct-out nix-path)
 (struct-out nix-fn-set) (struct-out nix-fn-set-formal)
 (struct-out nix-derivation) (struct-out nix-flake)
 (struct-out nix-with-cfg)
 (struct-out flake-input-form)
 ;; JS/quote AST
 (struct-out js-quote-form)
 (struct-out js-ast-block) (struct-out js-ast-const) (struct-out js-ast-let)
 (struct-out js-ast-assign) (struct-out js-ast-return) (struct-out js-ast-if)
 (struct-out js-ast-for-of) (struct-out js-ast-while) (struct-out js-ast-throw)
 (struct-out js-ast-try) (struct-out js-ast-expr-stmt)
 (struct-out js-ast-function) (struct-out js-ast-class) (struct-out js-ast-method)
 (struct-out js-ast-call) (struct-out js-ast-member) (struct-out js-ast-index)
 (struct-out js-ast-arrow) (struct-out js-ast-ternary)
 (struct-out js-ast-binary) (struct-out js-ast-unary) (struct-out js-ast-template)
 (struct-out js-ast-array) (struct-out js-ast-object) (struct-out js-ast-spread)
 (struct-out js-ast-await) (struct-out js-ast-new) (struct-out js-ast-typeof)
 (struct-out js-ast-ident) (struct-out js-ast-literal)
 (struct-out js-ast-splice-expr) (struct-out js-ast-splice-stmts) (struct-out js-ast-splice-json)
 ;; Typed JS AST (minimal set)
 (struct-out jst-return) (struct-out jst-class) (struct-out jst-method)
 (struct-out jst-dot) (struct-out jst-selector)
 (struct-out jst-get) (struct-out jst-call) (struct-out jst-set)
 (struct-out jst-new) (struct-out jst-delete) (struct-out jst-in)
 (struct-out jst-spread) (struct-out jst-typeof)
 (struct-out jst-template) (struct-out jst-binary) (struct-out jst-unary)
 (struct-out jst-export) (struct-out jst-export-default)
 (struct-out jst-import-meta)
 unwrap-definition-form)
