#lang racket/base

;; Parse beagle source into structured AST nodes. Macros are expanded in
;; pass 2. Meta forms (namespace, declare-extern, require, defmacro)
;; are pulled out separately and don't appear in `forms`.

(require racket/match
         racket/file
         racket/list
         racket/string
         racket/set
         "types.rkt"
         "macros.rkt"
         "scope-resolve.rkt"
         "extensions.rkt"
         "targets.rkt"
         ;; The typed stdlib catalog is the authority on which required
         ;; namespaces belong to the HOST runtime rather than to beagle
         ;; source, so an unresolvable require can be rejected without
         ;; rejecting `clojure.string` and friends.
         (only-in "stdlib-types.rkt" stdlib-for-target)
         "ast.rkt"
         "module-interface.rkt"
         "parse-jst.rkt"
         "parse-js-quote.rkt"
         "diagnostic-kind.rkt"
         "syntax/tokenize.rkt"
         ;; THE single beagle readtable lives in reader-impl.rkt (the #lang
         ;; reader). read-beagle-syntax / read-beagle-datums (the --agent / build
         ;; / repair / hook path) parse with the SAME table — no second copy to
         ;; drift out of sync (#19; the #18 dynamic-var divergence was a symptom).
         (only-in "../lang/reader-impl.rkt"
                  fn-shorthand->fn reading-fn-shorthand? beagle-readtable)
         (only-in "tags.rkt" ann))

;; --- structured parse errors ------------------------------------------------
;;
;; The bulk of (error 'beagle ...) call sites in this file are untagged —
;; they raise plain exn:fail:user without a kind/cause-class. The Phase 0
;; instrumentation (see thread 20260530160000) tags the high-traffic
;; subset (~30 sites) with a structured beagle-parse-error so downstream
;; consumers (error-format.rkt JSON path, beagle-rejection-stats) can
;; bucket them by cause-class. Other (~80) deep-nested sites stay on
;; plain `error` and get heuristically classified via
;; error-format.rkt extract-kind.

(struct beagle-parse-error exn:fail (
  kind        ; symbol — see parse-error-kind->cause-class in diagnostic-kind.rkt
  details     ; hasheq with structured data (cause, form, etc.)
) #:transparent)

(define current-macro-output-origin-chain (make-parameter #f))

(define (expansion-context-chain ctx)
  (let loop ([current ctx] [names '()])
    (if current
        (loop (expansion-ctx-parent current)
              (cons (expansion-ctx-macro-name current) names))
        names)))

(define (source-text-at-span location)
  (define source-bytes (current-source-bytes))
  (and source-bytes
       location
       (src-loc-pos location)
       (src-loc-span location)
       (let* ([source (bytes->string/utf-8 source-bytes)]
              [start (sub1 (src-loc-pos location))]
              [end (+ start (src-loc-span location))])
         (and (<= 0 start end (string-length source))
              (substring source start end)))))

;; A machine-applicable suggestion attached to a pointed-replacement error so
;; tools (beagle-repair --emit-patch) can auto-apply the fix instead of
;; re-deriving it from the prose message. This is the Lean Suggestion/TryThis
;; split: semantic intent -> applicable edit, carried as structured data
;; alongside the human message. "replace-head" renames the offending form's
;; head symbol; the value is JSON-serializable so it rides the error stream.
(define (replace-head-suggestion from to)
  (hasheq 'type "replace-head"
          'from (format "~a" from)
          'to (format "~a" to)
          'label (format "Replace `~a` with `~a`" from to)))

(define (raise-parse-error kind fmt
                           #:suggestion [suggestion #f]
                           #:details [extra-details (hasheq)]
                           . args)
  (define msg (apply format fmt args))
  ;; When we're currently parsing the output of a macro expansion
  ;; (current-macro-expansion-ctx non-#f), rebucket the rejection as
  ;; 'macro-expansion-parse-error so Phase 0 telemetry attributes the
  ;; failure to "macro produced unparseable output" rather than the
  ;; underlying kind (which describes the symptom on the expansion
  ;; result, not the original surface form the author wrote).
  (define ctx (current-macro-expansion-ctx))
  (define effective-kind
    (if ctx 'macro-expansion-parse-error kind))
  (define base-details
    (hasheq 'cause (symbol->string (parse-error-kind->cause-class effective-kind))
            'phase "parse"))
  (define details0
    (cond
      [ctx
       (define origin-chain
         (or (current-macro-output-origin-chain)
             (expansion-context-chain ctx)))
       (define call-span (expansion-ctx-call-span ctx))
       (define call-syntax (expansion-ctx-call-syntax ctx))
       (define macro-details
         (hash-set* base-details
                    'original-kind (symbol->string kind)
                    'macro-name (symbol->string (expansion-ctx-macro-name ctx))
                    'macro-depth (expansion-ctx-depth ctx)
                    'semantic-error-id "BEAGLE-MACRO-OUTPUT-ERROR"
                    'origin-chain (map symbol->string origin-chain)
                    'blame-form
                    (or (source-text-at-span call-span)
                        (and call-syntax
                             (binding-datum->src
                              (beagle-syntax->datum call-syntax))))))
       (if call-span
           (hash-set* macro-details
                      'error-file (let ([source (src-loc-source call-span)])
                                    (cond
                                      [(path? source) (path->string source)]
                                      [(string? source) source]
                                      [else #f]))
                      'error-line (src-loc-line call-span)
                      'error-col (src-loc-col call-span)
                      'error-pos (src-loc-pos call-span)
                      'error-span (src-loc-span call-span))
           macro-details)]
      [else base-details]))
  (define details1
    (for/fold ([details details0]) ([(key value) (in-hash extra-details)])
      (hash-set details key value)))
  (define details
    (if suggestion (hash-set details1 'suggestion suggestion) details1))
  (raise (beagle-parse-error
          (format "beagle: ~a~a"
                  (if ctx "BEAGLE-MACRO-OUTPUT-ERROR: " "")
                  msg)
          (current-continuation-marks)
          effective-kind
          details)))

;; Legacy raw-datum callers still need a bridge back to the parallel Racket
;; reader tree. The real compiler path carries Beagle Syntax directly, while
;; this suffix map lets the adapter resolve a zero-based logical element without
;; flattening or reconstructing declaration groups.
(define (macro-call-source-suffixes call-datum call-stx)
  (define suffixes (make-hasheq))
  (define (walk datum stx)
    (when (and (pair? datum) (syntax? stx))
      (define children (syntax->list stx))
      (when children
        (let loop ([tail datum] [child-tail children])
          (when (and (pair? tail) (pair? child-tail))
            (hash-set! suffixes tail child-tail)
            (walk (car tail) (car child-tail))
            (loop (cdr tail) (cdr child-tail)))))))
  (walk call-datum call-stx)
  suffixes)

(define (macro-source-error-stx error call-datum call-stx)
  (cond
    [(beagle-syntax? (exn:fail:macro-source-form error))
     (beagle-syntax->racket-syntax (exn:fail:macro-source-form error))]
    [(syntax? call-stx)
       (let* ([collection (exn:fail:macro-source-collection error)]
              [suffixes (macro-call-source-suffixes call-datum call-stx)]
              [children (and (pair? collection)
                             (hash-ref suffixes collection #f))]
              [logical-children
               (and children
                    (if (and (pair? collection)
                             (eq? (car collection) BRACKET-TAG))
                        (and (pair? children) (cdr children))
                        children))]
              [index (exn:fail:macro-source-index error)])
         (and logical-children
              (exact-nonnegative-integer? index)
              (< index (length logical-children))
              (list-ref logical-children index)))]
    [else #f]))

(define (source-detail-path stx)
  (define source (and (syntax? stx) (syntax-source stx)))
  (cond
    [(path? source) (path->string source)]
    [(string? source) source]
    [else #f]))

(define (source-error-details stx datum)
  (if (syntax? stx)
      (hasheq 'error-file (source-detail-path stx)
              'error-line (syntax-line stx)
              'error-col (syntax-column stx)
              'error-pos (syntax-position stx)
              'error-span (syntax-span stx)
              'stray-form (binding-datum->src datum))
      (hasheq 'stray-form (binding-datum->src datum))))

(define (raise-macro-source-error error call-datum call-stx)
  (define stray-stx (macro-source-error-stx error call-datum call-stx))
  (define base-details
    (hasheq 'stray-form
            (binding-datum->src
             (let ([form (exn:fail:macro-source-form error)])
               (if (beagle-syntax? form)
                   (beagle-syntax->datum form)
                   form)))))
  (define details
    (if stray-stx
        (hash-set* base-details
                   'error-file (source-detail-path stray-stx)
                   'error-line (syntax-line stray-stx)
                   'error-col (syntax-column stray-stx)
                   'error-pos (syntax-position stray-stx)
                   'error-span (syntax-span stray-stx))
        base-details))
  (define ctx
    (or (exn:fail:macro-source-context error)
        (and (pair? call-datum)
             (symbol? (car call-datum))
             (make-root-ctx (car call-datum)))))
  (parameterize ([current-macro-expansion-ctx ctx])
    (raise-parse-error
     'macro-source-error
     "~a"
     #:details details
     (exn-message error))))

(define (expand-fully/at-source registry datum stx)
  (with-handlers
      ([exn:fail:macro-source?
        (lambda (error)
          (raise-macro-source-error error datum stx))])
    (expand-fully
     registry
     (if (syntax? stx)
         (racket-syntax->beagle-syntax stx (current-source-bytes))
         (datum->beagle-syntax datum #f)))))

;; The beagle readtable (regex / raw-string / #(...) fn-shorthand / #? reader
;; conditionals / quote / quasiquote / unquote / [ ] { } #{ } containers) is
;; imported from reader-impl.rkt — see the require above. There is exactly ONE
;; table; read-beagle-syntax / read-beagle-datums below parameterize on it.

;; --- cross-file type import ------------------------------------------------

(define (split-ns-segments ns-sym)
  (define s (symbol->string ns-sym))
  (define len (string-length s))
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i len) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) #\.)
       (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(define (last-of xs)
  (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))

;; A required namespace that resolves to no beagle source is either a mistake
;; or a HOST runtime namespace the target loads for itself. The typed stdlib
;; catalog already distinguishes them: a host namespace owns `ns/member` keys.
;; `clojure.*` and `babashka.*` are exempt catalog-or-not — the clj runtime
;; auto-loads them and the catalog is deliberately partial (see the
;; qualified-call tiers in check.rkt).
(define host-namespace-cache (make-hasheq))

(define (host-namespace-set-for target)
  (hash-ref!
   host-namespace-cache target
   (lambda ()
     (for/fold ([names (set)])
               ([key (in-hash-keys (stdlib-for-target target))])
       (cond
         [(qualified-ref? key)
          (set-add names
                   (symbol->string (qualified-ref-qualifier key)))]
         [(symbol? key)
          (define text (symbol->string key))
          (define slash
            (let loop ([i 0])
              (cond
                [(= i (string-length text)) #f]
                [(char=? (string-ref text i) #\/) i]
                [else (loop (+ i 1))])))
          (if (and slash (> slash 0))
              (set-add names (substring text 0 slash))
              names)]
         [else names])))))

(define (host-namespace? ns-sym target)
  (define text (symbol->string ns-sym))
  (or (string-prefix? text "clojure.")
      (string-prefix? text "babashka.")
      (set-member? (host-namespace-set-for target) text)))

(define (qualify-name prefix-sym name-sym)
  (string->symbol
   (string-append (symbol->string prefix-sym) "/" (symbol->string name-sym))))

;; The sole source-token decomposition for semantic qualified references.
;; Reader data remains ordinary symbols so quote and macro data stay literal;
;; expression/type/pattern parsing calls this at the first semantic boundary.
(define (lower-qualified-reference sym)
  (and (symbol? sym)
       (not (keyword-sym? sym))
       (let* ([spelling (symbol->string sym)]
              [slash (regexp-match-positions #rx"/" spelling)])
         (and slash
              (positive? (caar slash))
              (< (cdar slash) (string-length spelling))
              (qualified-ref
               (string->symbol (substring spelling 0 (caar slash)))
               (string->symbol (substring spelling (cdar slash)))
               #f)))))

(define (strip-target-export d)
  (match d
    [(list (or 'js/export 'js/export-default) inner) (strip-target-export inner)]
    [_ d]))

;; Project one portable source snapshot onto a hosted target without rewriting
;; its bytes. Module-source closures use this for rooted .bgl providers; batch
;; compilation uses the same operation for explicit --target builds.
(define (retarget-beagle-syntax stxs target)
  (define (target-declaration? stx)
    (define datum (syntax->datum stx))
    (and (pair? datum) (eq? (car datum) 'define-target)))
  (define declaration-count
    (for/sum ([stx (in-list stxs)])
      (if (target-declaration? stx) 1 0)))
  (unless (= declaration-count 1)
    (error 'retarget-beagle-syntax
           "expected exactly one define-target declaration, found ~a"
           declaration-count))
  (for/list ([stx (in-list stxs)])
    (if (target-declaration? stx)
        (datum->syntax stx `(define-target ,target) stx stx)
        stx)))

(define (read-beagle-datums path)
  (require-beagle-source-extension! path 'read-beagle-datums)
  (with-input-from-file path
    (lambda ()
      (define first-line (read-line))
      (unless (and (string? first-line) (regexp-match? #rx"^#lang " first-line))
        (file-position (current-input-port) 0))
      (parameterize ([current-readtable beagle-readtable])
        (let loop ([acc '()])
          (define d (read))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

(define (lang-line->target lang-line)
  (cond
    [(regexp-match? #rx"beagle/nix"    lang-line) 'nix]
    [(regexp-match? #rx"beagle/clj"    lang-line) 'clj]
    [(regexp-match? #rx"beagle/js"     lang-line) 'js]
    [(regexp-match? #rx"^#lang[ ]+beagle[ ]*$" lang-line) 'core]
    [else #f]))

(define (read-syntax/with-unicode-diagnostic src in)
  (with-handlers
      ([exn:fail:read?
        (lambda (error)
          (if (regexp-match? #rx"bad or incomplete surrogate-style encoding"
                             (exn-message error))
              (raise-parse-error
               'invalid-symbol
               "BEAGLE-INVALID-SYMBOL: invalid Unicode scalar value")
              (raise error)))])
    (read-syntax src in)))

(define (canonical-source-path path)
  (simplify-path
   (path->complete-path (if (path? path) path (string->path path)))))

(define (read-beagle-syntax/bytes path source-bytes
                                  #:source-id [source-id #f])
  (unless (bytes? source-bytes)
    (raise-argument-error 'read-beagle-syntax/bytes "bytes?" source-bytes))
  (define src (or source-id (canonical-source-path path)))
  (define src-text (if (path? src) (path->string src) (format "~a" src)))
  (define snapshot (bytes->immutable-bytes source-bytes))
  (define in (open-input-bytes snapshot))
  (dynamic-wind
    void
    (lambda ()
      (port-count-lines! in)
      (define first-line (read-line in))
      (define has-lang? (and (string? first-line)
                             (regexp-match? #rx"^#lang " first-line)))
      (define target (and has-lang? (lang-line->target first-line)))
      (unless has-lang?
        (file-position in 0)
        ;; Rewinding bytes does not rewind Racket's line/position counter.
        ;; Reset it explicitly so source-less-header files retain true spans.
        (set-port-next-location! in 1 0 1))
      ;; Target-specific readtable for surface forms the base reader
      ;; doesn't know about. Notably: nix's `~"…"` / `~''…''` reader
      ;; macros. Without this, beagle-build-all (and any other caller
      ;; that goes through read-beagle-syntax) sees `~''…''` as bare
      ;; chars and fails on the first '}', '|', '#', etc. inside the
      ;; body. bin/beagle-build hits the #lang reader directly via
      ;; module load, so it always worked there.
      (define target-readtable
        (case target
          [(nix) (dynamic-require 'beagle/nix/lang/reader-impl
                                  'beagle-nix-readtable)]
          [else beagle-readtable]))
      (parameterize ([current-readtable target-readtable])
        (define forms
          (let loop ([acc '()])
            (define d (read-syntax/with-unicode-diagnostic src in))
            (if (eof-object? d) (reverse acc) (loop (cons d acc)))))
        (cond
          [target
           (cons (datum->syntax #f (list 'define-target target)) forms)]
          [has-lang?
           (define has-define-target?
             (for/or ([f (in-list forms)])
               (define d (syntax->datum f))
               (and (pair? d) (eq? (car d) 'define-target))))
           (cond
             [has-define-target? forms]
             [(expected-target-for-extension src-text)
              => (lambda (ext-tgt)
                   (cons (datum->syntax #f (list 'define-target ext-tgt)) forms))]
             [else
              (error 'beagle
                     "~a: unknown Beagle language header — use #lang beagle for Core or an explicit hosted language such as #lang beagle/clj"
                     src-text)])]
          [else forms])))
    (lambda () (close-input-port in))))

(define (read-beagle-syntax path)
  (define src (canonical-source-path path))
  (require-beagle-source-extension! src 'read-beagle-syntax)
  (read-beagle-syntax/bytes src (file->bytes src)))

;; --- canonical parameter / field layout -----------------------------------

(define SIGNATURE-LINE-WIDTH 80)

;; Physical layout is formatter policy, not language validity. The reader
;; syntax positions and tokenizer still live here so the formatter can reuse
;; the compiler's exact grammar-site discovery without reparsing source text.
(struct layout-edit (path line col role offset before replacement safe? refusal)
  #:transparent)

(define current-layout-edits (make-parameter '()))

(define layout-trivia-types
  '(whitespace newline line-comment block-comment))

(define (layout-trivia? tok)
  (memq (token-type tok) layout-trivia-types))

(define (token-end tok)
  (+ (token-offset tok) (string-length (token-text tok))))

(define (token-at-offset tokens offset [type #f])
  (for/first ([tok (in-list tokens)]
              #:when (and (= (token-offset tok) offset)
                          (or (not type) (eq? (token-type tok) type))))
    tok))

(define (matching-token tokens opener)
  (define opener-offset (token-offset opener))
  (let loop ([rest tokens] [stack '()] [started? #f])
    (cond
      [(null? rest) #f]
      [else
       (define tok (car rest))
       (cond
         [(and (not started?) (< (token-offset tok) opener-offset))
          (loop (cdr rest) stack #f)]
         [(not started?)
          (and (= (token-offset tok) opener-offset)
               (loop rest stack #t))]
         [(opener? tok)
          (loop (cdr rest) (cons (token-type tok) stack) #t)]
         [(closer? tok)
          (cond
            [(null? stack) #f]
            [(eq? (token-type tok) (matching-closer-type (car stack)))
             (if (null? (cdr stack))
                 tok
                 (loop (cdr rest) (cdr stack) #t))]
            [else #f])]
         [else (loop (cdr rest) stack #t)])])))

(define (syntax-start-offset stx)
  (and (syntax? stx)
       (syntax-position stx)
       (sub1 (syntax-position stx))))

(define (syntax-start-token stx tokens)
  (define start (syntax-start-offset stx))
  (and start (token-at-offset tokens start)))

(define (physical-syntax-line stx tokens)
  (or (syntax-line stx)
      (let ([tok (syntax-start-token stx tokens)])
        (and tok (token-line tok)))))

(define (physical-syntax-column stx tokens)
  (or (syntax-column stx)
      (let ([tok (syntax-start-token stx tokens)])
        (and tok (token-col tok)))))

(define (syntax-end-offset stx tokens)
  (define start (syntax-start-offset stx))
  (and start
       (cond
         [(syntax-span stx) (+ start (syntax-span stx))]
         [else
          (define tok (token-at-offset tokens start))
          (cond
            [(and tok (opener? tok))
             (define close (matching-token tokens tok))
             (and close (token-end close))]
            [tok (token-end tok)]
            [else #f])])))

(define (spanning-entry stxs datum style)
  (define first-stx (car stxs))
  (define last-stx (last stxs))
  (define start (syntax-position first-stx))
  (define last-start (syntax-position last-stx))
  (define last-span (syntax-span last-stx))
  (define span (and start last-start last-span (- (+ last-start last-span) start)))
  (syntax-property
   (syntax-property
    (datum->syntax
     #f datum
     (vector (syntax-source first-stx)
             (syntax-line first-stx)
             (syntax-column first-stx)
             start span))
    'beagle-binding-entry-style style)
   'beagle-binding-entry-source-stxs stxs))

(define (logical-entry-stxs vector-stx)
  (define subs (stx-subs vector-stx))
  (define items (and subs (cdr subs)))
  (and items
       (let* ([legacy? (and (pair? items)
                            (structured-binding? (->datum (car items))))]
              [flat? (and (not legacy?)
                          (pair? items)
                          (pair? (cdr items))
                          (type-expression-datum? (->datum (cadr items))))])
         (and (or legacy? flat?)
         (let loop ([rest items] [acc '()])
           (cond
             [(null? rest) (reverse acc)]
             [legacy?
              (cond
                [(and (eq? (->datum (car rest)) '&) (pair? (cdr rest)))
                 (reverse
                  (cons (spanning-entry
                         (take rest 2)
                         (list '& (->datum (cadr rest)))
                         'legacy-rest)
                        acc))]
                [else
                 (loop (cdr rest)
                       (cons (syntax-property
                              (car rest) 'beagle-binding-entry-style 'legacy)
                             acc))])]
             [(eq? (->datum (car rest)) '&)
              (and (>= (length rest) 3)
                   (reverse
                    (cons (spanning-entry
                           (take rest 3)
                           (map ->datum (take rest 3))
                           'flat)
                          acc)))]
             [else
              (and (>= (length rest) 2)
                   (loop (cddr rest)
                         (cons (spanning-entry
                                (take rest 2)
                                (map ->datum (take rest 2))
                                'flat)
                               acc)))]))))))

(define (logical-local-entry-stxs vector-stx)
  ;; Formatting runs before module interfaces have registered qualified nominal
  ;; types. Probe their structure by replacing only capitalized qualified type
  ;; atoms with `Any`, while leaving the compound constructor and arity checks
  ;; to the real type parser.
  (define (layout-type-expression-datum? datum)
    (define (qualified-type-atom? value)
      (and (symbol? value)
           (regexp-match? #rx"/[A-Z][A-Za-z0-9_-]*$"
                          (symbol->string value))))
    (define (probe value)
      (cond
        [(qualified-type-atom? value) 'Any]
        [(list? value) (map probe value)]
        [else value]))
    (or (type-expression-datum? datum)
        (type-expression-datum? (probe datum))))
  (define subs (stx-subs vector-stx))
  (define items (and subs (cdr subs)))
  (and items
       (let ([flat? (and (pair? items)
                         (pair? (cdr items))
                         (layout-type-expression-datum?
                          (->datum (cadr items))))])
         (let loop ([rest items] [acc '()])
           (cond
             [(null? rest) (reverse acc)]
             [(not flat?)
              (and (>= (length rest) 2)
                   (loop (cddr rest)
                         (cons (spanning-entry
                                (take rest 2)
                                (map ->datum (take rest 2))
                                'legacy-triple)
                               acc)))]
             [else
              (and (>= (length rest) 3)
                   (loop (cdddr rest)
                         (cons (spanning-entry
                                (take rest 3)
                                (map ->datum (take rest 3))
                                'flat-triple)
                               acc)))])))))

;; Each binding is one source datum, so layout never has to infer logical
;; boundaries from alternating marker tokens.
(define (fragment->inline tokens start end)
  (define out (open-output-string))
  (define pending-space? #f)
  (define previous-type #f)
  (define wrote? #f)
  (define (emit! text type)
    (when (and pending-space? wrote?
               (not (memq type '(close-paren close-bracket close-brace)))
               (not (memq previous-type
                          '(open-paren open-bracket open-brace hash-open-brace))))
      (display " " out))
    (display text out)
    (set! wrote? #t)
    (set! pending-space? #f)
    (set! previous-type type))
  (for ([tok (in-list tokens)]
        #:when (and (>= (token-offset tok) start)
                    (<= (token-end tok) end)))
    (cond
      [(memq (token-type tok) '(whitespace newline))
       (set! pending-space? #t)]
      [(eq? (token-type tok) 'line-comment)
       (emit! (token-text tok) 'line-comment)
       (set! pending-space? #t)]
      [else (emit! (token-text tok) (token-type tok))]))
  (string-trim (get-output-string out)))

(define (fragment->source tokens start end)
  (apply string-append
         (for/list ([tok (in-list tokens)]
                    #:when (and (>= (token-offset tok) start)
                                (<= (token-end tok) end)))
           (token-text tok))))

(define (line-comment-in-range? tokens start end)
  (for/or ([tok (in-list tokens)])
    (and (eq? (token-type tok) 'line-comment)
         (>= (token-offset tok) start)
         (<= (token-end tok) end))))

(define (comment-in-range? tokens start end)
  (for/or ([tok (in-list tokens)])
    (and (memq (token-type tok) '(line-comment block-comment))
         (>= (token-offset tok) start)
         (<= (token-end tok) end))))

(define (next-significant-token tokens offset)
  (for/first ([tok (in-list tokens)]
              #:when (and (>= (token-offset tok) offset)
                          (not (layout-trivia? tok))))
    tok))

(define (previous-significant-token tokens offset)
  (for/fold ([found #f]) ([tok (in-list tokens)]
                          #:when (and (<= (token-end tok) offset)
                                      (not (layout-trivia? tok))))
    tok))

;; A declaration is one datum. When that datum alone crosses the width limit,
;; expand its own children rather than treating its type and constraint as
;; adjacent vector entries. Nested containers use the same delimiter-relative
;; indentation, so a long predicate expression can expand without alignment
;; whitespace pretending that separate declarations are one table.
(define (layout-child-stxs stx)
  (define subs (stx-subs stx))
  (if (and subs (pair? subs)
           (memq (->datum (car subs)) (list BRACKET-TAG MAP-TAG SET-TAG)))
      (cdr subs)
      subs))

(define (nested-layout-text tokens stx col [suffix-width 0])
  (define start (syntax-start-offset stx))
  (define end (and start (syntax-end-offset stx tokens)))
  (define inline (and start end (fragment->inline tokens start end)))
  (define open (and start (token-at-offset tokens start)))
  (define close (and open (opener? open) (matching-token tokens open)))
  (define children (and close (layout-child-stxs stx)))
  (cond
    [(or (not inline)
         (<= (+ col (string-length inline) suffix-width)
             SIGNATURE-LINE-WIDTH)
         (not children)
         (null? children)
         (comment-in-range? tokens start end))
     (or inline "")]
    [else
     (define inner-col (+ col (string-length (token-text open))))
     (define pad (make-string inner-col #\space))
     (define last-index (sub1 (length children)))
     (string-append
      (token-text open)
      (nested-layout-text tokens (car children) inner-col
                          (if (zero? last-index)
                              (+ suffix-width (string-length (token-text close)))
                              0))
      (apply string-append
             (for/list ([child (in-list (cdr children))]
                        [index (in-naturals 1)])
               (string-append "\n" pad
                              (nested-layout-text
                               tokens child inner-col
                               (if (= index last-index)
                                   (+ suffix-width
                                      (string-length (token-text close)))
                                   0)))))
      (token-text close))]))

(define (legacy-declaration-text tokens declaration)
  (define children (stx-subs declaration))
  (define rendered
    (for/list ([child (in-list children)])
      (fragment->inline tokens
                        (syntax-start-offset child)
                        (syntax-end-offset child tokens))))
  (if (= (length rendered) 3)
      (format "~a (~a where ~a)" (car rendered) (cadr rendered) (caddr rendered))
      (string-join rendered " ")))

(define (legacy-constrained-entry? entry)
  (define style (syntax-property entry 'beagle-binding-entry-style))
  (define datum (->datum entry))
  (case style
    [(legacy) (= (length datum) 3)]
    [(legacy-rest) (= (length (cadr datum)) 3)]
    [(legacy-triple)
     (and (list? (car datum)) (= (length (car datum)) 3))]
    [else #f]))

(define (canonical-entry-text tokens entry start end col [suffix-width 0])
  (define inline (fragment->inline tokens start end))
  (define datum (->datum entry))
  (case (syntax-property entry 'beagle-binding-entry-style)
    [(legacy) (legacy-declaration-text tokens entry)]
    [(legacy-rest)
     (define source-stxs
       (syntax-property entry 'beagle-binding-entry-source-stxs))
     (string-append "& " (legacy-declaration-text tokens (cadr source-stxs)))]
    [(legacy-triple)
     (define source-stxs
       (syntax-property entry 'beagle-binding-entry-source-stxs))
     (define declaration (car source-stxs))
     (string-append
      (if (structured-binding? (->datum declaration))
          (legacy-declaration-text tokens declaration)
          (fragment->inline tokens
                            (syntax-start-offset declaration)
                            (syntax-end-offset declaration tokens)))
      " "
      (fragment->source tokens
                        (syntax-start-offset (cadr source-stxs))
                        (syntax-end-offset (cadr source-stxs) tokens)))]
    [(flat-triple)
     (define source-stxs
       (syntax-property entry 'beagle-binding-entry-source-stxs))
     (string-append
      (fragment->inline tokens
                        (syntax-start-offset (car source-stxs))
                        (syntax-end-offset (car source-stxs) tokens))
      " "
      (fragment->inline tokens
                        (syntax-start-offset (cadr source-stxs))
                        (syntax-end-offset (cadr source-stxs) tokens))
      " "
      (fragment->source tokens
                        (syntax-start-offset (caddr source-stxs))
                        (syntax-end-offset (caddr source-stxs) tokens)))]
    [else inline]))

(define (canonical-vector-text tokens open close entries continuation-col
                               vertical?)
  (define open-end (token-end open))
  (define close-start (token-offset close))
  (define starts (map syntax-start-offset entries))
  (cond
    [(null? starts) "[]"]
    [else
     (define fragments
       (for/list ([entry (in-list entries)]
                  [index (in-naturals)])
         (canonical-entry-text
          tokens entry (syntax-start-offset entry)
          (syntax-end-offset entry tokens) continuation-col
          (if (= index (sub1 (length entries)))
              (string-length (token-text close))
              0))))
     (if vertical?
         (string-append
          "[" (car fragments)
          (apply string-append
                 (for/list ([fragment (in-list (cdr fragments))])
                   (string-append "\n" (make-string continuation-col #\space) fragment)))
          "]")
         (string-append "[" (string-join fragments " ") "]"))]))

(define (expression-end-offset tokens tok)
  (cond
    [(and tok (opener? tok))
     (define close (matching-token tokens tok))
     (and close (token-end close))]
    [tok (token-end tok)]
    [else #f]))

(struct signature-tail (end fragments) #:transparent)

(define (where-clause-token? tokens tok)
  (and tok
       (eq? (token-type tok) 'open-paren)
       (let ([head (next-significant-token tokens (token-end tok))])
         (and head (string=? (token-text head) "where")))))

(define (signature-tail-info tokens close return-slot?)
  (cond
    [(not return-slot?) (signature-tail (token-end close) '())]
    [else
     (define return-token
       (next-significant-token tokens (token-end close)))
     (define return-end
       (or (expression-end-offset tokens return-token) (token-end close)))
     (define return-text
       (fragment->inline tokens (token-offset return-token) return-end))
     (define maybe-where (next-significant-token tokens return-end))
     (define-values (after-where fragments)
       (if (where-clause-token? tokens maybe-where)
           (let ([where-end (expression-end-offset tokens maybe-where)])
             (values where-end
                     (list return-text
                           (fragment->inline tokens
                                             (token-offset maybe-where)
                                             where-end))))
           (values return-end (list return-text))))
     (define maybe-raises (next-significant-token tokens after-where))
     (if (and maybe-raises (string=? (token-text maybe-raises) ":raises"))
         (let* ([error-type
                 (next-significant-token tokens (token-end maybe-raises))]
                [error-end
                 (or (expression-end-offset tokens error-type)
                     (token-end maybe-raises))])
           (signature-tail
            error-end
            (append fragments
                    (list (fragment->inline tokens
                                            (token-offset maybe-raises)
                                            error-end)))))
         (signature-tail after-where fragments))]))

(define (signature-continuation-col form-stx open placement tokens)
  (case placement
    [(owner) (+ (or (physical-syntax-column form-stx tokens) 0) 2)]
    [(clause)
     (define clause-open
       (previous-significant-token tokens (token-offset open)))
     (if clause-open (add1 (token-col clause-open)) (token-col open))]
    [else (token-col open)]))

(define (inline-signature-fits? tokens form-stx open signature-end placement)
  (define start
    (if (eq? placement 'bare)
        (token-offset open)
        (syntax-start-offset form-stx)))
  (define start-col
    (if (eq? placement 'bare)
        (token-col open)
        (or (physical-syntax-column form-stx tokens) 0)))
  (and start signature-end
       (<= (+ start-col
              (string-length
               (fragment->inline tokens start signature-end)))
           SIGNATURE-LINE-WIDTH)))

(define (signature-unit-fits? tokens open signature-end continuation-col)
  (<= (+ continuation-col
         (string-length
          (fragment->inline tokens (token-offset open) signature-end)))
      SIGNATURE-LINE-WIDTH))

(define (check-layout-vector! source tokens form-stx anchor vector-stx placement role
                              [return-slot? #t]
                              [entry-reader logical-entry-stxs])
  (define start (syntax-start-offset vector-stx))
  (define entries (and start (entry-reader vector-stx)))
  (define open (and start (token-at-offset tokens start 'open-bracket)))
  (define close (and open (matching-token tokens open)))
  (when (and entries open close anchor (syntax-start-offset anchor))
    (define anchor-end (and (eq? placement 'owner) (syntax-end-offset anchor tokens)))
    (define clause-open (previous-significant-token tokens (token-offset open)))
    (define region-start
      (case placement
        [(owner) anchor-end]
        [(clause) (if clause-open (token-end clause-open) (token-offset open))]
        [else (token-offset open)]))
    (define tail-info (signature-tail-info tokens close return-slot?))
    (define signature-end (signature-tail-end tail-info))
    (define gap
      (and (eq? placement 'owner)
           (fragment->inline tokens anchor-end (token-offset open))))
    (define continuation-col
      (signature-continuation-col form-stx open placement tokens))
    (define body-col
      (+ (or (physical-syntax-column form-stx tokens) 0) 2))
    (define expanded? (> (length entries) 1))
    (define layout (if expanded? 'expanded 'inline))
    (define vector-col
      (if (eq? layout 'inline) (token-col open) continuation-col))
    (define vector-text
      (canonical-vector-text tokens open close entries (add1 vector-col)
                             (eq? layout 'expanded)))
    (define tail-fragments (signature-tail-fragments tail-info))
    (define prefix-text
      (case placement
        [(owner)
         (if (eq? layout 'inline)
             (string-append " "
                            (if (string=? gap "") "" (string-append gap " ")))
             (string-append
              (if (string=? gap "") "" (string-append " " gap))
              "\n" (make-string vector-col #\space)))]
        [(clause)
         ;; The arity-clause opener is structural, not an owner/name. Keep it
         ;; attached to the vector; an over-width unit expands after `(`.
         ""]
        [else ""]))
    (define after-signature
      (next-significant-token tokens signature-end))
    (define body?
      (and after-signature (not (closer? after-signature))))
    (define region-end
      (if (and (eq? layout 'expanded) body?)
          (token-offset after-signature)
          signature-end))
    (define return-fragment
      (and return-slot? (pair? tail-fragments) (car tail-fragments)))
    (define qualification-fragments
      (if return-fragment (cdr tail-fragments) '()))
    (define replacement
      (string-append
       prefix-text
       vector-text
       (cond
         [(not return-slot?)
          (if (and (eq? layout 'expanded) body?)
              (string-append "\n" (make-string body-col #\space))
              "")]
         [else
          (string-append
           (if return-fragment (string-append " " return-fragment) "")
           (apply string-append
                  (for/list ([fragment (in-list qualification-fragments)])
                    (string-append "\n"
                                   (make-string continuation-col #\space)
                                   fragment)))
           (if (and body?
                    (or (eq? layout 'expanded)
                        (pair? qualification-fragments)))
               (string-append "\n" (make-string body-col #\space))
               ""))])))
    (define before (substring source region-start region-end))
    (unless (string=? before replacement)
      (define path
        (let ([src (syntax-source vector-stx)])
          (if (path? src) (path->string src) src)))
      (define legacy-constraint?
        (for/or ([entry (in-list entries)])
          (legacy-constrained-entry? entry)))
      (define comment-reach?
        (line-comment-in-range? tokens region-start region-end))
      (current-layout-edits
       (cons (layout-edit path
                          (physical-syntax-line vector-stx tokens)
                          (physical-syntax-column vector-stx tokens)
                          role region-start before replacement
                          (not (or legacy-constraint? comment-reach?))
                          (cond
                            [legacy-constraint? 'refinement-not-implemented]
                            [comment-reach? 'comment-reach]
                            [else #f]))
             (current-layout-edits))))))

(define (vector-stx? stx)
  (and (syntax? stx) (bracketed? (->datum stx))))

(define (inspect-named-form-vector! source tokens form-stx vector-index
                                    [anchor-index 0] [role "parameter"])
  (define subs (stx-subs form-stx))
  (define vector-stx (stx-ref subs vector-index))
  (define anchor (stx-ref subs anchor-index))
  (when (and (vector-stx? vector-stx) anchor)
    (check-layout-vector! source tokens form-stx anchor vector-stx 'owner role
                          #f)))

(define (inspect-local-binding-layout! source tokens form-stx role)
  (define subs (stx-subs form-stx))
  (define vector-stx (and subs (stx-ref subs 1)))
  (when (vector-stx? vector-stx)
    (check-layout-vector! source tokens form-stx vector-stx vector-stx 'bare role
                          #f logical-local-entry-stxs)))

(define (inspect-method-form! source tokens method-stx [role "method parameter"])
  (define subs (stx-subs method-stx))
  (when (and subs (>= (length subs) 2)
             (symbol? (->datum (car subs)))
             (vector-stx? (cadr subs)))
    (check-layout-vector! source tokens method-stx (car subs) (cadr subs) 'owner role)))

(define (inspect-fn-layout! source tokens form-stx)
  (define subs (stx-subs form-stx))
  (when (and subs (>= (length subs) 2))
    (cond
      [(vector-stx? (cadr subs))
       (check-layout-vector! source tokens form-stx (car subs) (cadr subs)
                             'owner "parameter")]
      [(and (>= (length subs) 3)
            (symbol? (->datum (cadr subs)))
            (vector-stx? (caddr subs)))
       (check-layout-vector! source tokens form-stx (cadr subs) (caddr subs)
                             'owner "parameter")]
      [else (void)])))

(define (inspect-defn-layout! source tokens form-stx)
  (define subs (stx-subs form-stx))
  (when (and subs (>= (length subs) 3))
    (define raw-name-stx (cadr subs))
    (define raw-name-subs (stx-subs raw-name-stx))
    (define name-stx
      (if (and raw-name-subs
               (pair? raw-name-subs)
               (eq? (->datum (car raw-name-subs)) '#%meta))
          (last raw-name-subs)
          raw-name-stx))
    (define tail0 (cddr subs))
    (define tail (if (and (pair? tail0) (string? (->datum (car tail0))))
                     (cdr tail0)
                     tail0))
    (define anchor (if (eq? tail tail0) name-stx (car tail0)))
    (cond
      [(and (pair? tail) (vector-stx? (car tail)))
       (check-layout-vector! source tokens form-stx anchor (car tail) 'owner
                             "parameter" #t)]
      [else
       (for ([clause (in-list tail)])
         (define clause-subs (stx-subs clause))
         (when (and clause-subs (pair? clause-subs)
                    (vector-stx? (car clause-subs)))
           (check-layout-vector! source tokens clause clause (car clause-subs) 'clause
                                 "multi-arity parameter" #t)))])))

(define (inspect-layout-form! source tokens form-stx)
  (define subs (stx-subs form-stx))
  (when (and subs (pair? subs))
    (define head (->datum (car subs)))
    (case head
      [(defn defn-) (inspect-defn-layout! source tokens form-stx)]
      [(fn) (inspect-fn-layout! source tokens form-stx)]
      [(let) (inspect-local-binding-layout! source tokens form-stx "let binding")]
      [(loop) (inspect-local-binding-layout! source tokens form-stx "loop binding")]
      [(defrecord) (inspect-named-form-vector! source tokens form-stx 2 1 "typed field")]
      [(letfn)
       (define fns (stx-ref subs 1))
       (define fsubs (and fns (stx-subs fns)))
       (for ([fn-stx (in-list (if fsubs (cdr fsubs) '()))])
         (inspect-method-form! source tokens fn-stx "letfn parameter"))]
      [(defprotocol)
       (for ([method-stx (in-list (cddr subs))])
         (inspect-method-form! source tokens method-stx "protocol parameter"))]
      [(extend-type)
       (for ([method-stx (in-list (cddr subs))]
             #:when (pair? (->datum method-stx)))
         (inspect-method-form! source tokens method-stx "implementation parameter"))]
      [(defunion)
       (for ([member-stx (in-list (cddr subs))]
             #:when (pair? (->datum member-stx)))
         (inspect-named-form-vector! source tokens member-stx 1 0
                                     "typed variant field"))]
      [else (void)])
    ;; Quoted/macro-template/commented datums are data, not physical grammar
    ;; sites. Macro parameter vectors above are still checked.
    (unless (memq head '(quote quasiquote defmacro comment))
      (for ([child (in-list subs)] #:when (pair? (->datum child)))
        (inspect-layout-form! source tokens child)))))

(define (signature-layout-edits/bytes source-path source-bytes)
  (define path
    (simplify-path
     (path->complete-path
      (if (path? source-path) source-path (string->path source-path)))))
  (unless (bytes? source-bytes)
    (raise-argument-error 'signature-layout-edits/bytes "bytes?" source-bytes))
  (define source (bytes->string/utf-8 source-bytes))
  (define tokens (tokenize source))
  (define stxs (read-beagle-syntax/bytes path source-bytes))
  (parameterize ([current-layout-edits '()])
    (for ([stx (in-list stxs)] #:when (syntax-position stx))
      (inspect-layout-form! source tokens stx))
    (sort (current-layout-edits) < #:key layout-edit-offset)))

(define (signature-layout-edits source-path)
  (define path
    (simplify-path
     (path->complete-path
      (if (path? source-path) source-path (string->path source-path)))))
  (signature-layout-edits/bytes path (file->bytes path)))

(define (apply-signature-layout-edits source edits)
  (define unsafe (filter (lambda (edit) (not (layout-edit-safe? edit))) edits))
  (when (pair? unsafe)
    (error 'apply-signature-layout-edits
           "refusing to move ~a comment-bearing signature region~a"
           (length unsafe) (if (= (length unsafe) 1) "" "s")))
  (for/fold ([out source])
            ([edit (in-list (sort edits > #:key layout-edit-offset))])
    (define start (layout-edit-offset edit))
    (define before (layout-edit-before edit))
    (define end (+ start (string-length before)))
    (unless (and (<= end (string-length out))
                 (string=? before (substring out start end)))
      (error 'apply-signature-layout-edits
             "source changed under formatter at byte offset ~a" start))
    (string-append (substring out 0 start)
                   (layout-edit-replacement edit)
                   (substring out end))))

(define (reject-reserved-type-name! name where)
  (when (eq? name 'Fn)
    (raise-parse-error
     'reserved-type-name
     "~a cannot declare `Fn`; Fn is the built-in function type constructor"
     where)))

(define (validate-reserved-type-declarations! datums)
  (define (reject-member! member where)
    (cond
      [(symbol? member) (reject-reserved-type-name! member where)]
      [(and (pair? member) (symbol? (car member)))
       (reject-reserved-type-name! (car member) where)]
      [else (void)]))
  (for ([datum (in-list datums)])
    (match datum
      [(list 'defalias (? symbol? name) _)
       (reject-reserved-type-name! name "defalias")]
      [(list 'defrecord (? symbol? name) _)
       (reject-reserved-type-name! name "defrecord")]
      [(list* 'defprotocol (? symbol? name) _)
       (reject-reserved-type-name! name "defprotocol")]
      [(list* 'defenum (? symbol? name) _)
       (reject-reserved-type-name! name "defenum")]
      [(list* 'defscalar (? symbol? name) _)
       (reject-reserved-type-name! name "defscalar")]
      [(list* 'defunion ':throwable (? symbol? name) members)
       (reject-reserved-type-name! name "defunion :throwable")
       (for ([member (in-list members)])
         (reject-member! member "defunion :throwable member"))]
      [(list* 'defunion (? symbol? name) members)
       (reject-reserved-type-name! name "defunion")
       (for ([member (in-list members)])
         (reject-member! member "defunion member"))]
      [(list* 'defunion (list (? symbol? name) type-vars ...) members)
       (reject-reserved-type-name! name "parametric defunion")
       (for ([type-var (in-list type-vars)])
         (when (symbol? type-var)
           (reject-reserved-type-name! type-var "defunion type parameter")))
       (for ([member (in-list members)])
         (reject-member! member "defunion member"))]
      [_ (void)])))

;; --- reader-conditional resolution ----------------------------------------
;;
;; The reader (beagle-lib/lang/reader-impl.rkt) reads #?(:tag form ...) as
;; (reader-conditional :tag form ...) and #?@(:tag form ...) as
;; (reader-conditional-splice :tag form ...). The reader doesn't know which
;; target is active — that's set by `define-target`, which is itself a datum.
;; So we resolve these markers here at parse time, after determining the
;; target from the datum stream.
;;
;; Branch selection rule: scan keyword/form pairs left-to-right, return the
;; first form whose `:tag` matches the current target; if none matches but
;; `:default` is present, return that. Otherwise raise
;; 'reader-conditional-no-match.
;;
;; Splice resolution: a (reader-conditional-splice :tag value ...) appearing
;; as a child of a list/bracket/map/set container splices its chosen value
;; (which must be a sequence — bare list, or #%brackets/#%map/#%set with the
;; head dropped) into the surrounding container in place of the marker.

;; Fast structural scan — returns #t iff the datum tree contains a
;; reader-conditional or reader-conditional-splice marker. The common case
;; (no reader conditionals anywhere in the program) lets parse-program
;; skip the full rewrite pass entirely and preserve the original syntax
;; objects (with their inner srclocs). Without this fast path, the
;; rewriter would `datum->syntax` every top-level form, flattening nested
;; syntax srclocs that emit-clj's expression-level metadata depends on.
(define (has-reader-conditional? d)
  (cond
    [(pair? d)
     (or (eq? (car d) 'reader-conditional)
         (eq? (car d) 'reader-conditional-splice)
         (ormap has-reader-conditional? d))]
    [else #f]))

(define (rc-pairs items)
  (let loop ([items items] [acc '()])
    (cond
      [(null? items) (reverse acc)]
      [(< (length items) 2)
       (raise-parse-error 'reader-conditional-no-match
                          "reader-conditional: trailing tag without a form: ~v" items)]
      [else
       (define kw (car items))
       (define form (cadr items))
       (unless (and (symbol? kw) (regexp-match? #rx"^:" (symbol->string kw)))
         (raise-parse-error 'reader-conditional-no-match
                            "reader-conditional: expected :tag, got ~v" kw))
       (define tag (string->symbol (substring (symbol->string kw) 1)))
       (loop (cddr items) (cons (cons tag form) acc))])))

(define (rc-select target pairs original)
  (define hit (assq target pairs))
  (cond
    [hit (cdr hit)]
    [else
     (define dflt (assq 'default pairs))
     (cond
       [dflt (cdr dflt)]
       [else
        (raise-parse-error 'reader-conditional-no-match
                           "reader-conditional: no branch matches target ~a (and no :default): ~v"
                           target original)])]))

(define (rc-splice-children target xs)
  ;; Walk a sequence of child datums, replacing (reader-conditional ...) by
  ;; the selected value (still a single child) and splicing
  ;; (reader-conditional-splice ...) chosen-sequence into the parent.
  (apply append
    (for/list ([x (in-list xs)])
      (cond
        [(and (pair? x) (eq? (car x) 'reader-conditional-splice))
         (define pairs (rc-pairs (cdr x)))
         (define chosen (rc-select target pairs x))
         (define seq
           (cond
             [(and (pair? chosen)
                   (memq (car chosen) '(#%brackets #%map #%set)))
              (cdr chosen)]
             [(list? chosen) chosen]
             [else
              (raise-parse-error 'reader-conditional-no-match
                                 "reader-conditional-splice: chosen branch is not a sequence: ~v"
                                 chosen)]))
         (map (lambda (e) (resolve-reader-conditionals e target)) seq)]
        [else
         (list (resolve-reader-conditionals x target))]))))

(define (resolve-reader-conditionals d target)
  (cond
    [(and (pair? d) (eq? (car d) 'reader-conditional))
     (define pairs (rc-pairs (cdr d)))
     (define chosen (rc-select target pairs d))
     (resolve-reader-conditionals chosen target)]
    [(and (pair? d) (eq? (car d) 'reader-conditional-splice))
     ;; A top-level reader-conditional-splice (not inside a container) — treat
     ;; as if its chosen value is the result. If chosen is a sequence, this
     ;; collapses to the bare sequence as a datum, which is almost certainly
     ;; not what the author wants — but we let the caller decide via the
     ;; splicing path. Resolve and return the chosen branch verbatim.
     (define pairs (rc-pairs (cdr d)))
     (define chosen (rc-select target pairs d))
     (resolve-reader-conditionals chosen target)]
    [(pair? d)
     (cond
       [(memq (car d) '(#%brackets #%map #%set))
        (cons (car d) (rc-splice-children target (cdr d)))]
       [else
        (rc-splice-children target d)])]
    [else d]))

;; --- entry point -----------------------------------------------------------

;; Authoritative candidate-overlay type namespaces.  Values are installed from a
;; module-interface during require registration, then consulted indirectly by
;; types.rkt's current-qualified-type-resolver at every annotation position.
;; External/non-overlay namespaces are deliberately absent and retain the
;; legacy nominal/JVM path.
(define current-candidate-type-bindings (make-parameter #f))
(define current-candidate-type-prefixes (make-parameter #f))
(define current-module-resolution-closed? (make-parameter #f))

(define INTERFACE-TYPE-EXPORT-KINDS
  '(record protocol enum union parametric-union union-member
    throwable-union throwable-member scalar alias))

(define (raise-invalid-interface-type-export interface name detail . args)
  (apply
   raise-parse-error
   'module-interface
   (string-append
    "required Beagle module ~a has invalid schema-v~a type export ~a: "
    detail)
   (module-interface-namespace interface)
   (module-interface-schema-version interface)
   name
   args))

(define (validate-interface-type-export! interface key export)
  (unless (interface-type-export? export)
    (raise-invalid-interface-type-export
     interface key "expected an interface-type-export, got ~v" export))
  (define name (interface-type-export-name export))
  (define kind (interface-type-export-kind export))
  (define arity (interface-type-export-arity export))
  (define expansion (interface-type-export-expansion export))
  (unless (and (symbol? key) (eq? key name))
    (raise-invalid-interface-type-export
     interface key "table key and declared name disagree (~v)" name))
  (unless (memq kind INTERFACE-TYPE-EXPORT-KINDS)
    (raise-invalid-interface-type-export
     interface name "unknown kind ~v" kind))
  (unless (exact-nonnegative-integer? arity)
    (raise-invalid-interface-type-export
     interface name
     "arity must be an exact nonnegative integer, got ~v"
     arity))
  (if (eq? kind 'parametric-union)
      (unless (positive? arity)
        (raise-invalid-interface-type-export
         interface name "parametric union arity must be positive, got ~v" arity))
      (unless (zero? arity)
        (raise-invalid-interface-type-export
         interface name "non-parametric type arity must be 0, got ~v" arity)))
  (if (eq? kind 'alias)
      (unless (type? expansion)
        (raise-invalid-interface-type-export
         interface name "alias expansion must be a canonical type, got ~v"
         expansion))
      (when expansion
        (raise-invalid-interface-type-export
         interface name "only aliases may carry an expansion, got ~v"
         expansion))))

(define (qualified-type-head datum)
  (cond
    [(symbol? datum) (lower-qualified-reference datum)]
    [(and (pair? datum) (symbol? (car datum)))
     (lower-qualified-reference (car datum))]
    [else #f]))

(define (qualified-type-name ref)
  (register-qualified-type-name!
   (qualify-name
    (qualified-ref-qualifier ref)
    (qualified-ref-name ref))
   (qualified-ref-name ref)))

(define (resolve-candidate-qualified-type datum)
  (define ref (qualified-type-head datum))
  (define prefix (and ref (qualified-ref-qualifier ref)))
  (define written-name (and ref (qualified-type-name ref)))
  (define bindings (current-candidate-type-bindings))
  (define prefixes (current-candidate-type-prefixes))
  (cond
    [(or (not ref) (not prefix) (not bindings) (not prefixes)) #f]
    [(hash-ref bindings ref #f)
     =>
     (lambda (entry)
       (define interface (car entry))
       (define export (cdr entry))
       (define arity (interface-type-export-arity export))
       (define canonical-ref
         (qualified-ref
          (module-interface-namespace interface)
          (interface-type-export-name export)
          (module-interface-namespace interface)))
       (define canonical-name (qualified-type-name canonical-ref))
       (cond
         [(symbol? datum)
          (when (positive? arity)
            (raise-parse-error
             'type-application
             "type ~a expects ~a argument~a, got 0"
             written-name
             arity
             (if (= arity 1) "" "s")))
          (or (interface-type-export-expansion export)
              (type-prim canonical-name))]
         [(pair? datum)
          (define args (cdr datum))
          (unless
              (eq? (interface-type-export-kind export) 'parametric-union)
            (raise-parse-error
             'type-application
             "type ~a exported by ~a is not parametric and cannot be applied"
             written-name
             (module-interface-namespace interface)))
          (unless
              (= (length args) arity)
            (raise-parse-error
             'type-application
             "type ~a expects ~a argument~a, got ~a"
             written-name
             arity
             (if (= arity 1) "" "s")
             (length args)))
          (type-app canonical-name (map parse-type args))]
         [else #f]))]
    [(hash-ref prefixes prefix #f)
     =>
     (lambda (provider)
       (cond
         [(module-interface? provider)
          (raise-parse-error
           'missing-type-export
           "required Beagle module ~a does not export type ~a (referenced as ~a); update the provider and consumer in the same candidate overlay, or fix the annotation"
           (module-interface-namespace provider)
           (qualified-ref-name ref)
           written-name)]
         [else
         ;; Bootstrap pass: the candidate namespace is known, but its
         ;; canonical interface is not built yet.  Admit an opaque shape so
         ;; every module can parse independent of overlay order; the
         ;; authoritative pass replaces PROVIDER with the interface and
         ;; proves the exact export before checking/emission.  Canonicalize
         ;; immediately to the provider namespace: otherwise a module that
         ;; re-exports `(defalias A (local/T ...))` leaks its private require
          ;; prefix into A's public expansion.
          (define canonical-name
            (qualified-type-name
             (qualified-ref provider (qualified-ref-name ref) provider)))
          (if (symbol? datum)
              (type-prim canonical-name)
              (type-app
               canonical-name
               (map parse-type (cdr datum))))]))]
    [else #f]))

;; Wrapper: fresh lowering-temp counter per program, so minted names
;; (cond-thread__N / some-thread__N / bind__N) depend
;; only on THIS module's content, never on what else the process parsed
;; before it (daemon, build-all, check-all). Byte-reproducible builds.
(define PROGRAM->SOURCE-BYTES (make-weak-hasheq))

(define (program-source-bytes prog)
  (hash-ref PROGRAM->SOURCE-BYTES prog #f))

(define (parse-program stxs*
                       #:source-path [source-path #f]
                       #:module-resolver [module-resolver #f])
  (parameterize ([lowering-counter (box 0)]
                 ;; Type aliases and parametric declaration names are
                 ;; program-local.  Freshening them here prevents one module
                 ;; parsed by a long-lived daemon/overlay gate from licensing an
                 ;; otherwise unknown type in the next module.
                 [current-user-parametric-arities (hasheq)]
                 [current-type-aliases (hasheq)]
                 [current-candidate-type-bindings (make-hash)]
                 [current-candidate-type-prefixes (make-hasheq)]
                 [current-qualified-type-resolver
                  resolve-candidate-qualified-type]
                 [current-type-surface-error
                  (lambda (kind fmt . args)
                    (apply raise-parse-error kind fmt args))])
    (parse-program* stxs*
                    #:source-path source-path
                    #:module-resolver module-resolver)))

(define (parse-program/bytes source-bytes
                             #:source-path source-path
                             #:source-id [source-id #f]
                             #:target-override [target-override #f]
                             #:module-resolver [module-resolver #f])
  (unless (bytes? source-bytes)
    (raise-argument-error 'parse-program/bytes "bytes?" source-bytes))
  (define snapshot (bytes->immutable-bytes source-bytes))
  (define prog
    (parameterize ([current-source-bytes snapshot])
      (parse-program
       (let ([stxs
              (read-beagle-syntax/bytes
               source-path snapshot #:source-id source-id)])
         (if target-override
             (retarget-beagle-syntax stxs target-override)
             stxs))
       #:source-path (or source-id source-path)
       #:module-resolver module-resolver)))
  (hash-set! PROGRAM->SOURCE-BYTES prog snapshot)
  prog)

(define (parse-program/file path
                            #:module-resolver [module-resolver #f])
  (define src (canonical-source-path path))
  (require-beagle-source-extension! src 'parse-program/file)
  (parse-program/bytes
   (file->bytes src)
   #:source-path src
   #:module-resolver module-resolver))

(define (parse-program* stxs*
                        #:source-path [source-path #f]
                        #:module-resolver [module-resolver #f])
  (define raw-datums (map syntax->datum stxs*))

  ;; A host namespace outside the typed target catalog is authority-bearing
  ;; only when this source explicitly declares one of its imported bindings.
  ;; Inspect the complete authored datum stream so declaration order never
  ;; changes whether the preceding require is authorized.
  (define declared-extern-names
    (for/set ([datum (in-list raw-datums)]
              #:when
              (match datum
                [(list* 'declare-extern (? symbol?) _) #t]
                [_ #f]))
      (cadr datum)))

  ;; Determine target up-front so reader-conditionals can be resolved before
  ;; any per-form parsing. `define-target` appears as a datum produced by the
  ;; lang loader (or written by hand under `#lang beagle`). The current-target
  ;; might also have been set by a wrapping context (e.g. validate-nix.rkt
  ;; injects (define-target nix)) — in either case, scanning the datum
  ;; stream is sufficient.
  (define pre-scan-target
    (let loop ([ds raw-datums])
      (cond
        [(null? ds) DEFAULT-TARGET]
        [(and (pair? (car ds))
              (eq? (caar ds) 'define-target)
              (pair? (cdar ds))
              (symbol? (cadar ds)))
         (cadar ds)]
        [else (loop (cdr ds))])))

  ;; Fast path: most programs have no reader-conditionals at all. Skip
  ;; the rewrite pass entirely so nested syntax srclocs (which the rewrite
  ;; would flatten via datum->syntax) survive untouched. Without this, the
  ;; emit-clj expression-level metadata pass loses its per-expression line
  ;; numbers (see beagle-test/tests/emit.rkt expression-level cases).
  (define needs-rewrite?
    (for/or ([d (in-list raw-datums)]) (has-reader-conditional? d)))

  ;; Resolve reader-conditionals on syntax objects so srclocs survive
  ;; on the rewritten subtrees. The rewriter rewraps resolved datums via
  ;; datum->syntax inheriting the original syntax's lexical context.
  ;; Top-level (reader-conditional-splice ...) markers can produce
  ;; zero-or-more program forms; we therefore produce a (Vec Syntax) by
  ;; flat-mapping over the input.
  (define stxs
    (cond
      [(not needs-rewrite?) stxs*]
      [else
       (apply append
         (for/list ([s (in-list stxs*)])
           (define d (syntax->datum s))
           (cond
             [(and (pair? d) (eq? (car d) 'reader-conditional-splice))
              (define pairs (rc-pairs (cdr d)))
              (define chosen (rc-select pre-scan-target pairs d))
              (define seq
                (cond
                  [(and (pair? chosen)
                        (memq (car chosen) '(#%brackets #%map #%set)))
                   (cdr chosen)]
                  [(list? chosen) chosen]
                  [else
                   (raise-parse-error 'reader-conditional-no-match
                                      "reader-conditional-splice: chosen branch is not a sequence: ~v"
                                      chosen)]))
              (for/list ([elt (in-list seq)])
                (datum->syntax s (resolve-reader-conditionals elt pre-scan-target) s))]
             [else
              (define resolved (resolve-reader-conditionals d pre-scan-target))
              (cond
                [(eq? resolved d) (list s)]
                [else (list (datum->syntax s resolved s))])])))]))

  (define datums (if needs-rewrite? (map syntax->datum stxs) raw-datums))
  (validate-reserved-type-declarations! datums)

  ;; Pass 1: pull meta forms out and register macros / externs / requires.
  (define target    DEFAULT-TARGET)
  (define target-set? #f)
  (define ns        DEFAULT-NAMESPACE)
  (define ns-set?   #f)
  (define gen-class? #f)
  (define registry  (make-macro-registry))
  (define declared-macros (make-hasheq))
  (define externs   (make-hash))
  (define declared-externs (make-hasheq))
  (define imp-rec-fields (make-hash))
  (define imp-rec-field-order (make-hash))
  (define imp-rec-ns (make-hash))
  (define imp-type-names (mutable-seteq))
  (define requires  '())
  (define imports   '())
  (define imp-scalar-fns (make-hash))
  (define imp-scalar-preds (make-hash))
  (define imp-symbol-ns (make-hash))
  (define imp-union-members (make-hash))
  (define imp-param-unions (make-hash))
  (define imp-enums (make-hash))
  (define imp-dyn-vars (mutable-seteq))  ; G-A: imported ^:dynamic vars (qualified)
  (define imp-module-interfaces '())
  (define declared-type-aliases (make-hasheq))
  (define declared-module-contract #f)
  (define declared-module-contract-source #f)

  (define (referred? refer-syms name)
    (and refer-syms (memq name refer-syms)))

  (define (interface-spellings interface prefix refer-syms name)
    (remove-duplicates
     (append
      (list (qualify-name prefix name)
            (qualify-name (module-interface-namespace interface) name))
      (if (referred? refer-syms name) (list name) '()))
     eq?))

  (define (validate-interface! interface)
    (unless
        (equal? (module-interface-schema-version interface)
                INTERFACE-SCHEMA-VERSION)
      (raise-parse-error
       'module-interface
       "required Beagle module ~a uses interface schema v~v; this compiler requires v~a"
       (module-interface-namespace interface)
       (module-interface-schema-version interface)
       INTERFACE-SCHEMA-VERSION))
    (unless (symbol? (module-interface-namespace interface))
      (raise-parse-error
       'module-interface
       "required Beagle interface schema v~a has invalid namespace ~v"
       INTERFACE-SCHEMA-VERSION
       (module-interface-namespace interface)))
    (for ([field (in-list
                  (list (module-interface-bindings interface)
                        (module-interface-macros interface)
                        (module-interface-type-declarations interface)
                        (module-interface-type-exports interface)
                        (module-interface-record-contracts interface)))])
      (unless (hash? field)
        (raise-parse-error
         'module-interface
         "required Beagle module ~a has a malformed schema-v~a interface table"
         (module-interface-namespace interface)
         INTERFACE-SCHEMA-VERSION)))
    (unless (set? (module-interface-dynamic-vars interface))
      (raise-parse-error
       'module-interface
       "required Beagle module ~a has a malformed schema-v~a dynamic-var set"
       (module-interface-namespace interface)
       INTERFACE-SCHEMA-VERSION)))

  (define (copy-type type)
    (cond
      [(type-prim? type) (type-prim (type-prim-name type))]
      [(type-var? type) (type-var (type-var-name type))]
      [(type-app? type)
       (type-app (type-app-ctor type) (map copy-type (type-app-args type)))]
      [(type-union? type)
       (type-union (map copy-type (type-union-alts type)))]
      [(type-fn? type)
       (type-fn (map copy-type (type-fn-params type))
                (and (type-fn-rest-type type)
                     (copy-type (type-fn-rest-type type)))
                (copy-type (type-fn-ret type)))]
      [(type-poly? type)
       (define bounds (type-poly-bounds type))
       (type-poly
        (type-poly-vars type)
        (copy-type (type-poly-body type))
        (and bounds
             (for/hasheq ([(name bound) (in-hash bounds)])
               (values name (copy-type bound)))))]
      [else type]))

  (define (register-interface-types! interface prefix refer-syms)
    (validate-interface! interface)
    (define namespace (module-interface-namespace interface))
    (define prefixes (current-candidate-type-prefixes))
    (define bindings (current-candidate-type-bindings))
    (hash-set! prefixes prefix interface)
    (hash-set! prefixes namespace interface)
    (for ([(name export)
           (in-hash (module-interface-type-exports interface))])
      (validate-interface-type-export! interface name export)
      (define visible-names
        (interface-spellings interface prefix refer-syms name))
      (for ([visible-name (in-list visible-names)])
        (define visible-ref (lower-qualified-reference visible-name))
        (when visible-ref (qualified-type-name visible-ref))
        (hash-set! bindings
                   (or visible-ref visible-name)
                   (cons interface export))
        (when (interface-type-export-expansion export)
          (current-type-aliases
           (hash-set (current-type-aliases)
                     visible-name
                     (register-type-alias-display!
                      (copy-type (interface-type-export-expansion export))
                      visible-name))))
        (when (eq? (interface-type-export-kind export) 'parametric-union)
          (current-user-parametric-arities
           (hash-set (current-user-parametric-arities)
                     visible-name
                     (interface-type-export-arity export)))))))

  (define (record-referred? refer-syms name)
    (or (referred? refer-syms name)
        (referred?
         refer-syms
         (string->symbol (format "->~a" name)))))

  (define (record-spellings interface prefix refer-syms name)
    (remove-duplicates
     (append
      (list (qualify-name prefix name)
            (qualify-name (module-interface-namespace interface) name))
      (if (record-referred? refer-syms name) (list name) '()))
     eq?))

  (define (interface-provider-names interface)
    (for/fold ([names (make-hasheq)])
              ([name (in-list
                      (append
                       (hash-keys (module-interface-bindings interface))
                       (hash-keys (module-interface-macros interface))
                       (hash-keys (module-interface-type-exports interface))))])
      (hash-set! names name #t)
      names))

  (define (import-interface-macros! interface prefix refer-syms)
    (define provider-names (interface-provider-names interface))
    (for ([(name macro) (in-hash (module-interface-macros interface))])
      (unless (and (interface-macro? macro)
                   (eq? name (interface-macro-name macro)))
        (raise-parse-error
         'module-interface
         "required Beagle module ~a has malformed macro export ~a"
         (module-interface-namespace interface)
         name))
      (define params
        (append
         (interface-macro-fixed-params macro)
         (if (interface-macro-rest-param macro)
             (list '& (interface-macro-rest-param macro))
             '())))
      (define template
        (qualify-imported-macro-template
         (interface-macro-template macro)
         params
         provider-names
         prefix))
      (define qualified-names
        (remove-duplicates
         (list (qualify-name prefix name)
               (qualify-name (module-interface-namespace interface) name))
         eq?))
      (for ([qualified-name (in-list qualified-names)])
        (register-macro!
         registry qualified-name (interface-macro-kind macro) params template))
      (when (and (referred? refer-syms name)
                 (not (hash-has-key? registry name)))
        (register-macro!
         registry name (interface-macro-kind macro) params template))))

  (define (import-interface-records! interface prefix refer-syms)
    (define namespace (module-interface-namespace interface))
    (for ([(name contract)
           (in-hash (module-interface-record-contracts interface))])
      (define fields (interface-record-contract-fields contract))
      (define field-map
        (for/hash ([field (in-list fields)])
          (values (string->symbol (format ":~a" (param-name field)))
                  (param-type field))))
      (define field-order
        (for/list ([field (in-list fields)])
          (symbol->string (param-name field))))
      (for ([spelling
             (in-list (record-spellings interface prefix refer-syms name))])
        (hash-set! imp-rec-fields spelling field-map)
        (hash-set! imp-rec-field-order spelling field-order)
        (hash-set! imp-rec-ns spelling namespace))))

  (define (interface-record-fields interface name)
    (define contract
      (module-interface-record-contract-ref interface name #f))
    (if contract (interface-record-contract-fields contract) '()))

  (define (qualified-union-members qualifier members)
    (for/list ([member (in-list members)])
      (qualify-name qualifier member)))

  (define (qualified-member-fields interface qualifier members)
    (for/hasheq ([member (in-list members)])
      (values (qualify-name qualifier member)
              (interface-record-fields interface member))))

  (define (register-interface-union! interface prefix refer-syms name
                                     type-params members)
    (define namespace (module-interface-namespace interface))
    (define bare? (referred? refer-syms name))
    (define (members-for qualifier)
      (if qualifier (qualified-union-members qualifier members) members))
    (define (member-fields-for qualifier)
      (if qualifier
          (qualified-member-fields interface qualifier members)
          (for/hasheq ([member (in-list members)])
            (values member (interface-record-fields interface member)))))
    (define (register-members! key qualifier)
      (hash-set! imp-union-members key (members-for qualifier)))
    (define (register-parametric! key qualifier)
      (hash-set!
       imp-param-unions
       key
       (hasheq 'params type-params
               'members (members-for qualifier)
               'member-fields (member-fields-for qualifier))))
    (register-members! (qualify-name prefix name) prefix)
    (register-members! (qualify-name namespace name) namespace)
    (when bare? (register-members! name #f))
    (unless (null? type-params)
      (register-parametric! (qualify-name prefix name) prefix)
      (register-parametric! (qualify-name namespace name) namespace)
      (when bare? (register-parametric! name #f))))

  (define (import-interface-type-contracts! interface prefix refer-syms)
    (define namespace (module-interface-namespace interface))
    (for ([(name declaration)
           (in-hash (module-interface-type-declarations interface))])
      (match (interface-type-declaration-details declaration)
        [`(type-params ,type-params members ,member-specs)
         (register-interface-union!
          interface prefix refer-syms name type-params (map car member-specs))]
        [`(members ,member-specs)
         (register-interface-union!
          interface prefix refer-syms name '() (map car member-specs))]
        [`(values ,_ ...)
         (for ([spelling
                (in-list (interface-spellings
                          interface prefix refer-syms name))])
           (hash-set! imp-enums spelling #t))]
        [`(backing ,_ predicates ,predicates)
         (define parsed-predicates
           (for/list ([predicate (in-list predicates)])
             (match predicate
               [(list op value) (scalar-predicate op value)])))
         (define name-string (symbol->string name))
         (define ctor (string->symbol (string-append "->" name-string)))
         (define accessor
           (string->symbol
            (string-append (string-downcase name-string) "-value")))
         (for ([runtime-name (in-list (list ctor accessor))])
           (for ([spelling
                  (in-list (interface-spellings
                            interface prefix refer-syms runtime-name))])
             (hash-set! imp-scalar-fns spelling #t)))
         (define scalar-referred?
           (or (referred? refer-syms name)
               (referred? refer-syms ctor)
               (referred? refer-syms accessor)))
         (define scalar-spellings
           (remove-duplicates
            (append
             (list (qualify-name prefix name)
                   (qualify-name namespace name))
             (if scalar-referred? (list name) '()))
            eq?))
         (when (pair? parsed-predicates)
           (for ([spelling (in-list scalar-spellings)])
             (hash-set! imp-scalar-preds spelling parsed-predicates)))]
        [_ (void)])))

  (define (import-interface! interface prefix refer-syms)
    (register-interface-types! interface prefix refer-syms)
    (define alias-exports
      (sort
       (for/list ([(name export)
                   (in-hash (module-interface-type-exports interface))]
                  #:when
                  (let ([expansion (interface-type-export-expansion export)])
                    (and expansion (dynamic-type? expansion))))
         (cons name export))
       symbol<? #:key car))
    (define (display-imported-aliases type)
      (define alias
        (for/first ([entry (in-list alias-exports)]
                    #:when
                    (equal? type
                            (interface-type-export-expansion (cdr entry))))
          entry))
      (cond
        [alias
         (define visible-name
           (car (interface-spellings
                 interface prefix refer-syms (car alias))))
         (register-type-alias-display! (copy-type type) visible-name)]
        [(type-app? type)
         (type-app (type-app-ctor type)
                   (map display-imported-aliases (type-app-args type)))]
        [(type-union? type)
         (type-union (map display-imported-aliases
                          (type-union-alts type)))]
        [(type-fn? type)
         (type-fn
          (map display-imported-aliases (type-fn-params type))
          (and (type-fn-rest-type type)
               (display-imported-aliases (type-fn-rest-type type)))
          (display-imported-aliases (type-fn-ret type)))]
        [(type-poly? type)
         (define bounds (type-poly-bounds type))
         (define copied
           (type-poly
            (type-poly-vars type)
            (display-imported-aliases (type-poly-body type))
            (and bounds
                 (for/hasheq ([(name bound) (in-hash bounds)])
                   (values name (display-imported-aliases bound))))))
         (set-type-poly-origin! copied (type-poly-origin type))
         copied]
        [else type]))
    (for ([name (in-list (or refer-syms '()))])
      (unless (or (module-interface-export? interface name)
                  (module-interface-type-export? interface name))
        (error 'beagle
               "required module ~a does not export referred name ~a"
               (module-interface-namespace interface)
               name)))
    (for ([(name binding) (in-hash (module-interface-bindings interface))]
           #:unless (eq? (interface-binding-kind binding) 'macro))
      (define binding-type
        (display-imported-aliases (interface-binding-type binding)))
      (for ([spelling
             (in-list (interface-spellings
                       interface prefix refer-syms name))])
        (unless (and (eq? spelling name) (hash-has-key? externs name))
          (hash-set! externs spelling binding-type)))
      (when (referred? refer-syms name)
        (hash-set! imp-symbol-ns name prefix)))
    (import-interface-macros! interface prefix refer-syms)
    (for ([name (in-hash-keys (module-interface-type-exports interface))])
      (for ([spelling
             (in-list (interface-spellings
                       interface prefix refer-syms name))])
        (set-add! imp-type-names spelling)))
    (import-interface-records! interface prefix refer-syms)
    (import-interface-type-contracts! interface prefix refer-syms)
    (for ([name (in-set (module-interface-dynamic-vars interface))])
      (for ([spelling
             (in-list (interface-spellings
                       interface prefix refer-syms name))])
        (set-add! imp-dyn-vars spelling)))
    (set! imp-module-interfaces
          (cons (module-import interface prefix refer-syms)
                imp-module-interfaces)))

  (define (candidate-for-require rn)
    (validate-module-path! rn)
    (define candidate
      (and module-resolver (module-resolver rn source-path)))
    (when (and candidate (not (module-source? candidate)))
      (error 'beagle
             "module resolver returned ~v for ~a; expected module-source or #f"
             candidate rn))
    (when (and candidate
               (not (eq? (module-source-namespace candidate) rn)))
      (error 'beagle
             "module resolver returned namespace ~a for required module ~a"
             (module-source-namespace candidate)
             rn))
    candidate)

  (define (pre-register-require-types! rn alias refer-syms)
    (define prefix
      (or alias (string->symbol (last-of (split-ns-segments rn)))))
    (define candidate (candidate-for-require rn))
    (define interface (and candidate (module-source-interface candidate)))
    (cond
      [interface
       (register-interface-types! interface prefix refer-syms)]
      [candidate
       ;; Bootstrap knows the namespace but has not minted its semantic
       ;; interface yet. Qualified types remain opaque until the next round.
       (define prefixes (current-candidate-type-prefixes))
       (hash-set! prefixes prefix rn)
       (hash-set! prefixes rn rn)]
      [else (void)]))

  (define (register-require! rn alias refer-syms)
    (define prefix
      (or alias (string->symbol (last-of (split-ns-segments rn)))))
    (define candidate (candidate-for-require rn))
    (define interface (and candidate (module-source-interface candidate)))
    (define (declared-extern? name)
      (set-member? declared-extern-names name))
    (define (qualified-extern? qualifier name)
      (declared-extern? (qualify-name qualifier name)))
    (define extern-authorized?
      (if (pair? refer-syms)
          (for/and ([name (in-list refer-syms)])
            (or (declared-extern? name)
                (qualified-extern? prefix name)
                (qualified-extern? rn name)))
          (for/or ([name (in-set declared-extern-names)])
            (define text (symbol->string name))
            (or (string-prefix? text
                                (string-append (symbol->string prefix) "/"))
                (string-prefix? text
                                (string-append (symbol->string rn) "/"))))))
    (cond
      [interface
       (import-interface! interface prefix refer-syms)]
      [candidate
       (define prefixes (current-candidate-type-prefixes))
       (hash-set! prefixes prefix rn)
       (hash-set! prefixes rn rn)
       ;; A parse-only bootstrap round may see referred values before their
       ;; interface exists. They are deliberately imprecise and never checked.
       (for ([name (in-list (or refer-syms '()))])
         (hash-set! externs name (type-prim 'Any))
         (hash-set! externs (qualify-name prefix name) (type-prim 'Any))
         (hash-set! imp-symbol-ns name prefix))]
      [(or (and (eq? target 'js)
                (let ([module-name (symbol->string rn)])
                  (or (not (string-contains? module-name "."))
                      (string-contains? module-name "/"))))
           (host-namespace? rn target)
           extern-authorized?)
       ;; Foreign package / host runtime refers are runtime bindings whose
       ;; types come from the catalog or from `declare-extern`, not from
       ;; beagle source.
       (for ([name (in-list (or refer-syms '()))])
         (hash-set! externs name (type-prim 'Any))
         (hash-set! externs (qualify-name prefix name) (type-prim 'Any))
         (hash-set! imp-symbol-ns name prefix))]
      ;; Nothing provides this namespace: not a candidate in this invocation
      ;; and not a catalog/extern-authorized host namespace. Accepting it would
      ;; register a phantom alias whose every
      ;; qualified call then types at an arbitrary type — silently.
      [else
       (error 'beagle
              (if (current-module-resolution-closed?)
                  "required namespace ~a is absent from the closed source bundle (required by ~a)"
                  "required namespace ~a could not be resolved (required by ~a); it is absent from this invocation and no declared module root provides it")
              rn
              (or source-path "<unknown source>"))])
    (set! requires (cons (require-entry rn alias refer-syms) requires)))

  (define current-require-registration
    (make-parameter register-require!))

  ;; One require libspec: lib, [lib], [lib :as a], [lib :refer [syms]],
  ;; [lib :as a :refer [syms]] — possibly quoted ('[lib :as a]). Anything
  ;; else is a pointed rejection, never a silent drop.
  (define (register-require-libspec! spec context)
    (define d0 (->datum spec))
    (define unq (if (and (pair? d0) (eq? (car d0) 'quote) (pair? (cdr d0))) (cadr d0) d0))
    (cond
      [(symbol? unq)
       ((current-require-registration) unq #f #f)]
      [(and (pair? unq) (eq? (car unq) BRACKET-TAG))
       (define items (cdr unq))
       (unless (and (pair? items) (symbol? (car items)))
         (raise-parse-error 'bad-meta-value
                            "~a: libspec must start with a namespace symbol, got: ~v" context unq))
       (define rn (car items))
       (let loop ([rest (cdr items)] [alias #f] [refer-syms #f])
         (cond
           [(null? rest)
            ((current-require-registration) rn alias refer-syms)]
           [(and (eq? (car rest) ':as) (pair? (cdr rest)) (symbol? (cadr rest)))
            (loop (cddr rest) (cadr rest) refer-syms)]
           [(and (eq? (car rest) ':refer) (pair? (cdr rest)))
            (define rd (->datum (cadr rest)))
            (cond
              [(eq? rd ':all)
               (raise-parse-error 'bad-meta-value
                                  "~a: (:refer :all) is not supported — name the symbols explicitly: [~a :refer [sym ...]]" context rn)]
              [(and (pair? rd) (eq? (car rd) BRACKET-TAG))
               (loop (cddr rest) alias (map ->datum (cdr rd)))]
              [else
               (raise-parse-error 'bad-meta-value
                                  "~a: :refer expects a vector of symbols: [~a :refer [sym ...]], got: ~v" context rn rd)])]
           [else
            (raise-parse-error 'bad-meta-value
                               "~a: unsupported libspec option ~v — supported: [lib], [lib :as alias], [lib :refer [syms]], [lib :as alias :refer [syms]]" context (car rest))]))]
      [else
       (raise-parse-error 'bad-meta-value
                          "~a: bad libspec ~v — expected a namespace symbol or [lib :as alias] / [lib :refer [syms]]" context unq)]))

  ;; One import spec: java.time.LocalDate, (java.time LocalDate Duration),
  ;; [java.time LocalDate] — possibly quoted.
  (define (register-import-spec! spec context)
    (define d0 (->datum spec))
    (define d (if (and (pair? d0) (eq? (car d0) 'quote) (pair? (cdr d0))) (cadr d0) d0))
    (cond
      [(symbol? d) (set! imports (cons d imports))]
      [(and (pair? d) (or (eq? (car d) BRACKET-TAG) (symbol? (car d))))
       (define items (if (eq? (car d) BRACKET-TAG) (cdr d) d))
       (unless (and (>= (length items) 2) (andmap symbol? items))
         (raise-parse-error 'bad-meta-value
                            "~a: import spec must be (package Class ...) with symbols, got: ~v" context d))
       (define pkg (symbol->string (car items)))
       (for ([cls (in-list (cdr items))])
         (set! imports (cons (string->symbol (string-append pkg "." (symbol->string cls))) imports)))]
      [else
       (raise-parse-error 'bad-meta-value
                          "~a: bad import spec ~v — expected ClassName symbol or (package Class1 Class2 ...)" context d)]))

  ;; Candidate type knowledge must precede alias expansion.  Full value/macro
  ;; import remains in the ordinary metadata pass below; this pre-pass only
  ;; installs the namespace/type boundary needed by parse-type.
  (parameterize
      ([current-require-registration pre-register-require-types!])
    (for ([d (in-list datums)])
      (match d
        [(list* 'ns (? symbol?) ns-rest)
         (for ([clause (in-list ns-rest)]
               #:when
               (and (pair? clause) (eq? (car clause) ':require)))
           (for ([spec (in-list (cdr clause))])
             (register-require-libspec! spec "ns :require")))]
        [(list* 'require specs)
         #:when (and (pair? specs) (symbol? (car specs)))
         (register-require-libspec!
          (cons BRACKET-TAG specs)
          "require")]
        [(list* 'require specs)
         #:when
         (and
          (pair? specs)
          (for/and ([spec (in-list specs)])
            (let ([datum (->datum spec)])
              (and
               (pair? datum)
               (memq (car datum) (list 'quote BRACKET-TAG))))))
         (for ([spec (in-list specs)])
           (register-require-libspec! spec "require"))]
        [_ (void)])))

  ;; Pre-scan: register parametric defunion names so parse-type can handle them
  (for ([d (in-list datums)])
    (match d
      [(list 'defunion (list (? symbol? name) type-vars ...) _ ...)
       #:when (pair? type-vars)
       (current-user-parametric-arities
        (hash-set
         (current-user-parametric-arities)
         name
         (length type-vars)))]
      [_ (void)]))

  ;; G1 — Pre-scan: register type aliases (defalias Name <type-expr>) in SOURCE
  ;; ORDER, so parse-type resolves an alias name to its expansion. The body is
  ;; parsed with the aliases collected SO FAR, so it may reference earlier aliases
  ;; (and primitives/ctors); a forward/self reference is simply not in the table
  ;; yet and falls through to the bare-name path.  Resolved local expansions are
  ;; retained on the program so the canonical module interface can export aliases
  ;; transparently without reparsing or depending on ambient parser state.
  (for ([d (in-list datums)])
    (match d
      [(list 'defalias (? symbol? name) type-expr)
       (define expansion (parse-type type-expr))
       (current-type-aliases
        (hash-set (current-type-aliases) name expansion))
       (hash-set! declared-type-aliases name expansion)]
      [(cons 'defalias _)
       (raise-parse-error 'bad-defalias
                          "defalias requires (defalias Name <type-expr>), got: ~v" d)]
      [_ (void)]))

  (for ([d (in-list datums)] [s (in-list stxs)])
    (match d
      [(list 'define-target (? symbol? t))
       (when target-set? (raise-parse-error 'duplicate-meta "duplicate define-target"))
      (unless (memq t (source-profile-ids))
        (raise-parse-error 'bad-meta-value
                            "unknown target: ~a (expected core, clj, js, or nix)" t))
       (set! target t)
       (set! target-set? #t)]

      ;; Full Clojure ns form: (ns name.space "doc"? (:require libspec...)
      ;; (:import spec...)). Clauses route through the same registration
      ;; machinery as top-level require/import. Unsupported clauses are
      ;; rejected with pointed errors — never silently dropped.
      [(list* 'ns (? symbol? n) ns-rest)
       (when ns-set? (raise-parse-error 'duplicate-meta "duplicate ns form"))
       (validate-identifier! n "namespace")
       (set! ns n)
       (set! ns-set? #t)
       (for ([clause (in-list ns-rest)])
         (cond
           [(string? clause) (void)] ; ns docstring — accepted, not carried
           [(and (pair? clause) (eq? (car clause) ':require))
            (for ([spec (in-list (cdr clause))])
              (register-require-libspec! spec "ns :require"))]
           [(and (pair? clause) (eq? (car clause) ':import))
            (for ([spec (in-list (cdr clause))])
              (register-import-spec! spec "ns :import"))]
           [(and (pair? clause) (eq? (car clause) ':use))
            (raise-parse-error 'bad-meta-value
                               "(ns ~a (:use ...)) — :use is not supported. Use (:require [lib :refer [sym ...]]) instead." n)]
           [(and (pair? clause) (eq? (car clause) ':gen-class))
            ;; (:gen-class) marks the ns as an AOT / GraalVM-native-image entry
            ;; point. clj-only: emit-clj emits it, babashka tolerates it as a
            ;; no-op, and other targets ignore it.
            (set! gen-class? #t)]
           [(and (pair? clause) (eq? (car clause) ':refer-clojure))
            (raise-parse-error 'bad-meta-value
                               "(ns ~a (:refer-clojure ...)) — :refer-clojure is not supported; clojure.core is always available unqualified." n)]
           [else
            (raise-parse-error 'bad-meta-value
                               "(ns ~a ...): unsupported ns clause ~v — supported: docstring, (:require libspec ...), (:import spec ...)" n clause)]))]

      [(list 'defmacro (? symbol? name) macro-params template)
       (validate-identifier! name "macro")
       (unless (bracketed? macro-params)
         (raise-parse-error 'bad-meta-value
                            "macro ~a: parameters must be written in `[...]`" name))
       (define ps (bracket-body macro-params))
       (define template-stx (stx-ref (stx-subs s) 3))
       (register-macro!
        registry
        name
        'defmacro
        ps
        template
        #:template-syntax
        (and template-stx
             (racket-syntax->beagle-syntax
              template-stx (current-source-bytes))))
       (hash-set! declared-macros name (hash-ref registry name))]

      [(list 'declare-extern (? bracketed? names-form) type-expr)
       (for ([name (in-list (bracket-body names-form))])
         (unless (symbol? name)
           (raise-parse-error 'bad-meta-value
             "declare-extern: each name in batch form must be a symbol, got: ~v" name))
         (validate-identifier! name "extern")
         (when (hash-has-key? externs name)
           (raise-parse-error 'duplicate-meta "duplicate declare-extern: ~a" name))
         (define type (parse-type type-expr))
         (hash-set! externs name type)
         (hash-set! declared-externs name type))]
      [(list 'declare-extern (? symbol? name) type-expr)
       (validate-identifier! name "extern")
       (when (hash-has-key? externs name)
         (raise-parse-error 'duplicate-meta "duplicate declare-extern: ~a" name))
       (define type (parse-type type-expr))
       (hash-set! externs name type)
       (hash-set! declared-externs name type)]

      ;; One complete declaration per export.  The vector is the exact public
      ;; name set; adjacent/flattened tokens are never paired implicitly.
      [(list 'defcontract (? bracketed? entries-form))
       (when declared-module-contract
         (raise-parse-error 'duplicate-meta "duplicate defcontract"))
       (define entries (bracket-body entries-form))
       (define contract
         (for/fold ([out (hasheq)]) ([entry (in-list entries)])
           (match entry
             [(list (? symbol? name) scheme-expr)
              (validate-identifier! name "contract export")
              (when (hash-has-key? out name)
                (raise-parse-error
                 'duplicate-meta
                 "defcontract: duplicate export declaration: ~a"
                 name))
              (hash-set out name (parse-type scheme-expr))]
             [_
              (raise-parse-error
               'bad-meta-value
               "defcontract: each export must be one complete (name Scheme) declaration, got: ~v"
               entry)])))
       (set! declared-module-contract contract)
       (set! declared-module-contract-source (stx->src-loc s))]

      ;; (require lib), (require lib :as a), (require lib :refer [syms]),
      ;; (require lib :as a :refer [syms]) — bare form, options trailing.
      ;; (require '[lib :as a] '[lib2 :refer [x]] 'lib3) — quoted libspecs,
      ;; one or more. Both families route through register-require-libspec!.
      [(list* 'require specs)
       #:when (and (pair? specs) (symbol? (car specs)))
       (register-require-libspec! (cons BRACKET-TAG specs) "require")]
      [(list* 'require specs)
       #:when (and (pair? specs)
                   (for/and ([s (in-list specs)])
                     (let ([sd (->datum s)])
                       (and (pair? sd)
                            (memq (car sd) (list 'quote BRACKET-TAG))))))
       (for ([spec (in-list specs)])
         (register-require-libspec! spec "require"))]

      ;; (import java.time.LocalDate), (import (java.time LocalDate Duration)),
      ;; quoted variants accepted.
      [(list* 'import import-specs)
       #:when (pair? import-specs)
       (for ([spec (in-list import-specs)])
         (register-import-spec! spec "import"))]

      ;; Malformed meta forms: pass 2 skips every meta-headed form, so any
      ;; shape pass 1 doesn't accept MUST raise here — a fallthrough would
      ;; be a silent drop (the ns-form bug class, found 2026-06-12).
      [(cons 'ns _)
       (raise-parse-error 'bad-meta-value
                          "malformed ns form — expected (ns name.space \"doc\"? (:require ...) (:import ...)), got: ~v" d)]
      [(cons 'require _)
       (raise-parse-error 'bad-meta-value
                          "malformed require — expected (require lib :as alias / :refer [syms]) or (require '[lib :as alias] ...), got: ~v" d)]
      [(cons 'import _)
       (raise-parse-error 'bad-meta-value
                          "malformed import — expected (import java.pkg.Class) or (import (java.pkg Class1 Class2)), got: ~v" d)]
      [(cons 'declare-extern _)
       (raise-parse-error 'bad-meta-value
                          "malformed declare-extern — expected (declare-extern name TYPE) or (declare-extern [name1 name2 ...] TYPE), got: ~v" d)]
      [(cons 'defcontract _)
       (raise-parse-error
        'bad-meta-value
        "malformed defcontract — expected (defcontract [(name Scheme) ...]), got: ~v"
        d)]
      [(cons 'defmacro _)
       (raise-parse-error 'bad-meta-value
                          "malformed defmacro — expected (defmacro NAME [params] template) with exactly one template form; wrap multiple forms in `(do ...)`, got: ~v" d)]
      [(cons 'define-target _)
       (raise-parse-error 'bad-meta-value
                          "malformed define-target — expected (define-target core|clj|js|nix), got: ~v" d)]
      [_ (void)]))

  ;; Expand macros and resolve lexical references before lowering to the AST.
  ;; Keeping expansion and scope introduction in one traversal is load-bearing:
  ;; generated syntax receives the macro's introduction scope, while exact
  ;; antiquoted caller syntax retains the caller scopes it arrived with.
  (define resolved-values
    (with-handlers
        ([exn:fail:duplicate-parameter?
          (lambda (failure)
            (raise-parse-error
             'duplicate
             "~a"
             (exn-message failure)))]
         [exn:fail:scope-resolution?
          (lambda (failure)
            (raise-parse-error
             'bad-form
             "~a"
             (exn-message failure)
             #:details
             (hasheq
              'binding-ids
              (for/list ([id (in-set
                              (exn:fail:scope-resolution-binding-ids failure))])
                (binding-id-stable id)))))])
      (parameterize
          ([current-scope-expansion-error-handler
            (lambda (failure call-syntax)
              (raise-macro-source-error
               failure
               (beagle-syntax->datum call-syntax)
               (beagle-syntax->racket-syntax call-syntax)))])
        (expand-and-resolve-program
         registry
         (for/list ([s (in-list stxs)])
           (racket-syntax->beagle-syntax s (current-source-bytes)))))))
  (define resolved-stxs (map beagle-syntax->racket-syntax resolved-values))

  ;; Pass 2: lower each resolved form from syntax objects.
  ;; Proc macros with (Vec Form) output are expanded here and spliced into the
  ;; top-level form list — their output goes through full parse/check/emit.
  ;;
  ;; macro-derived-table maps each top-level AST node that came out of a
  ;; macro expansion to the expansion-ctx that produced it. check.rkt
  ;; reads this to set current-macro-expansion-ctx during type-check,
  ;; which lets raise-diag rebucket post-expansion type errors as
  ;; 'macro-expansion-type-error.
  (define (canonical-macro-name raw-name)
    (define name
      (if (symbol? raw-name) raw-name (string->symbol (format "~a" raw-name))))
    (define parts (string-split (symbol->string name) "/"))
    (cond
      [(= (length parts) 2)
       (define prefix (string->symbol (car parts)))
       (define required
         (findf
          (lambda (entry)
            (or (eq? (require-entry-alias entry) prefix)
                (eq? (require-entry-ns entry) prefix)))
          requires))
       (if required
           (string->symbol
            (format "~a/~a" (require-entry-ns required) (cadr parts)))
           name)]
      [else name]))
  (define src-table (make-hasheq))
  (define macro-derived-table (make-hasheq))
  (define body-locs-table (make-hasheq))
  (define pairs
    (parameterize ([current-registry registry]
                   [current-src-table src-table]
                   [current-body-locs-table body-locs-table]
                   [current-macro-derived-table macro-derived-table]
                   [current-user-parametric-arities
                    (current-user-parametric-arities)]
                   [current-type-aliases (current-type-aliases)])
      (apply append
        (for/list ([d (in-list datums)]
                   [s (in-list stxs)]
                   [resolved (in-list resolved-values)]
                   [resolved-stx (in-list resolved-stxs)]
                   #:unless (meta-form? d))
          ;; Same unified resolver as parse-expr (head-meaning): the top-level
          ;; loop orders macro-first before parse-top -> parse-expr. The
          ;; #%splice-forms / parse-macro-output / blame-on-`s` handling below
          ;; is top-level-only and stays exactly as-is.
          (define from-macro?
            (and (pair? d) (eq? (head-meaning registry (car d)) 'macro)))
          (define expanded (and from-macro? resolved))
          (define expanded-datum
            (and expanded (beagle-syntax->datum expanded)))
          (define expanded-children
            (and (syntax-list? expanded) (syntax-list-children expanded)))
          (define (parse-macro-output form-syntax)
            ;; Blame the macro CALL SITE for everything the expansion
            ;; produces. Macro output is generated code with no source of its
            ;; own, so a parse/type error in the expansion should point at
            ;; where the author invoked the macro (`s`), not at the whole
            ;; enclosing top-level form. Tagging the expansion datum with `s`'s
            ;; srcloc gives every generated node the call-site position — the
            ;; analog of Lean's withRef / fromRef-canonical, where synthesized
            ;; nodes inherit the reference position. (When `s` has no srcloc,
            ;; e.g. structurally-built test input, this is a graceful no-op.)
            (define expansion-stx
              (if (beagle-syntax? form-syntax)
                  (beagle-syntax->racket-syntax form-syntax)
                  (datum->syntax #f form-syntax s)))
            ;; Set current-macro-expansion-ctx so that any raise-parse-error
            ;; triggered while parsing this macro output rebuckets to
            ;; 'macro-expansion-parse-error. Also record the resulting AST
            ;; node so check.rkt can do the same for type errors.
            (define ctx
              (make-root-ctx
               (car d)
               (racket-syntax->beagle-syntax s (current-source-bytes))))
            (define parsed-node
              (parameterize
                  ([current-macro-expansion-ctx ctx]
                   [current-macro-output-origin-chain
                    (map canonical-macro-name
                         (macro-origin-names expanded))])
                (parse-top expansion-stx)))
            (mark-macro-derived! parsed-node ctx)
            parsed-node)
          (cond
            [(and from-macro?
                  (pair? expanded-datum)
                  (eq? (car expanded-datum) 'do))
             (for/list ([form-syntax (in-list (cdr expanded-children))])
               (cons (parse-macro-output form-syntax) s))]
            [(and from-macro?
                  (pair? expanded-datum)
                  (eq? (car expanded-datum) '#%splice-forms))
             (for/list ([form-syntax (in-list (cdr expanded-children))])
               (cons (parse-macro-output form-syntax) s))]
            [(not from-macro?)
             (list (cons (parse-top resolved-stx) s))]
            [from-macro?
             (list (cons (parse-macro-output expanded) s))]
            [else (error 'beagle "unreachable macro expansion state")])))))
  (define parsed0 (map car pairs))
  (define form-stxs0 (map cdr pairs))
  (define parsed parsed0)
  (define form-stxs form-stxs0)

  (define prog
    (program ns parsed registry (hash-copy declared-macros)
             externs (hash-copy declared-externs)
             (reverse requires) (reverse imports)
             form-stxs src-table (make-hasheq)
             (hash-copy declared-type-aliases)
             imp-type-names
             imp-rec-fields imp-rec-field-order imp-rec-ns
             (hash-keys imp-scalar-fns) imp-scalar-preds imp-symbol-ns
             imp-union-members imp-param-unions imp-enums imp-dyn-vars
             (reverse imp-module-interfaces)
             target gen-class?))
  ;; Stash the macro-derived-table keyed by the program so check.rkt
  ;; can recover it via program-macro-derived-table after this call
  ;; returns and the parameterize unwinds.
  (when (positive? (hash-count macro-derived-table))
    (register-program-macro-table! prog macro-derived-table))
  ;; Same for the body-locs-table (parallel list of body element srclocs,
  ;; keyed by body list identity). check.rkt restores it via
  ;; program-body-locs-table during the type-check pass so the
  ;; return-type diag can recover positional srcloc for bare-symbol
  ;; body tails that store-src! refused to record.
  (when (positive? (hash-count body-locs-table))
    (register-program-body-locs-table! prog body-locs-table))
  (when declared-module-contract
    (register-program-declared-module-contract!
     prog declared-module-contract declared-module-contract-source))
  prog)

(define (meta-form? d)
  (and (pair? d)
       (memq (car d) '(ns
                       define-target
                       defmacro
                       declare-extern
                       defcontract
                       require
                       import
                       defalias))))   ; G1 — aliases erase at parse-type; no IR/emit


;; --- per-form parsing ------------------------------------------------------

;; (Bare-alias deprecation helpers `warn-deprecation!` and
;; `deprecation-hints-suppressed?` were removed when the bare Nix-namespaced
;; aliases — `assert`, `with-cfg`, Nix-scope `with` — were hard-rejected. The
;; canonical `nix/`-prefixed forms are the only accepted spellings; see the
;; `'bare-nix-form` rejection arms in parse-expr for the migration pointers.)

(define (parse-top x)
  (define d (->datum x))
  ;; Top-level names are consumed structurally by their combiners rather than
  ;; recursively by parse-expr's symbol arm. Validate them here so compiler
  ;; namespaces remain reserved at every declaration boundary.
  (match d
    [(list* 'defunion ':throwable (? symbol? name) _)
     (validate-identifier! name "throwable union")]
    [(list* 'defunion (list (? symbol? name) type-vars ...) _)
     (validate-identifier! name "parametric union")
     (for ([type-var (in-list type-vars)])
       (when (symbol? type-var)
         (validate-identifier! type-var "union type parameter")))]
    [(list* (or 'def 'defonce 'defn 'defn- 'defrecord 'defenum
                'defscalar 'defprotocol 'defunion 'defalias)
            raw-name _)
     (define name
       (match raw-name
         [(list '#%meta _ (? symbol? inner)) inner]
         [(? symbol? inner) inner]
         [_ #f]))
     (when name (validate-identifier! name "top-level declaration"))]
    [_ (void)])
  (cond
    [(and (pair? d) (memq (car d) '(unsafe unsafe-js unsafe-clj unsafe-py unsafe-rkt unsafe-nix)))
     (error 'beagle
            "(~a ...) escape hatches are not available. Beagle has no per-target escape by design — if the stdlib doesn't cover the function, add a one-line type signature to the appropriate stdlib-*.rkt; if you need raw target code, write a separate target-language file and import it."
            (car d))]
    [else (parse-expr x)]))

;; Parameter holding the original syntax object of the surface form
;; currently being parsed. Set in parse-expr immediately before dispatching
;; to parse-list-form. Used by parse-time rewrite arms (when/->/-if-let/...)
;; to tag synthesized datum with the original form's source location.
(define current-form-stx (make-parameter #f))

;; Wrap a synthesized datum in a syntax object whose source location is
;; the current surface form (current-form-stx). datum->syntax preserves
;; existing syntax objects embedded in the datum, so sub-forms (which are
;; recovered from stx-subs/stx-ref) keep their original srclocs. The new
;; outer container — and any bare leaves the rewrite inserted — get the
;; surface form's srcloc, which is the right blame line when the synthetic
;; container itself is the node a diagnostic fires on.
(define (rewrite-as datum)
  (let ([ctx (current-form-stx)])
    (if (syntax? ctx)
        (datum->syntax ctx datum ctx)
        datum)))

(define (syntax-binding-id value)
  (and (syntax? value)
       (syntax-property value 'beagle-binding-id)))

(define (lower-reference datum [source-syntax #f])
  (define lexical-id (syntax-binding-id source-syntax))
  (if lexical-id
      (resolved-ref (symbol->structural-name datum) lexical-id)
      (or (lower-qualified-reference datum) datum)))

(define (binder-target-syntax value)
  (define datum (->datum value))
  (define children (stx-subs value))
  (if (and children (structured-binding? datum))
      (stx-ref children 0)
      value))

(define (syntax-binder-identities value)
  (define target (binder-target-syntax value))
  (define (walk syntax-value identities)
    (define datum (->datum syntax-value))
    (define id (syntax-binding-id syntax-value))
    (define with-id
      (if (and id (symbol? datum) (not (eq? datum '&)))
          (hash-set identities datum id)
          identities))
    (for/fold ([result with-id])
              ([child (in-list (or (stx-subs syntax-value) '()))])
      (walk child result)))
  (walk target #hasheq()))

(define (register-syntax-binder! binder source-syntax)
  (register-binder-identities!
   binder
   (if source-syntax
       (syntax-binder-identities source-syntax)
       #hasheq())))

(define (expansion-origin->ctx origin)
  (define parent-origin (expansion-origin-parent origin))
  (define parent-ctx
    (and parent-origin (expansion-origin->ctx parent-origin)))
  (define raw-name (expansion-origin-macro-id origin))
  (define name (if (symbol? raw-name) raw-name (string->symbol raw-name)))
  (expansion-ctx
   name
   (if parent-ctx (add1 (expansion-ctx-depth parent-ctx)) 0)
   parent-ctx
   (expansion-origin-call-span origin)
   origin
   (current-source-bytes)
   #f))

(define (macro-origin-names value)
  (define seen (mutable-seteq))
  (define names '())
  (define (record-origin! origin)
    (when (expansion-origin? origin)
      (record-origin! (expansion-origin-parent origin))
      (define name (expansion-origin-macro-id origin))
      (unless (set-member? seen name)
        (set-add! seen name)
        (set! names (cons name names)))))
  (define (walk current)
    (when (beagle-syntax? current)
      (record-origin! (beagle-syntax-origin current))
      (cond
        [(syntax-list? current)
         (for ([child (in-list (syntax-list-children current))])
           (walk child))]
        [(syntax-vector? current)
         (for ([child (in-list (syntax-vector-children current))])
           (walk child))]
        [(syntax-unquote? current) (walk (syntax-unquote-child current))]
        [else (void)])))
  (walk value)
  (reverse names))

(define (parse-expr x)
  (define origin
    (and (syntax? x) (syntax-property x 'beagle-expansion-origin)))
  (define ctx (and (expansion-origin? origin) (expansion-origin->ctx origin)))
  (define parsed
    (if ctx
        (parameterize ([current-macro-expansion-ctx ctx])
          (parse-expr* x))
        (parse-expr* x)))
  (when ctx (mark-macro-derived! parsed ctx))
  parsed)

(define (parse-expr* x)
  (define loc (and (syntax? x) (stx->src-loc x)))
  (define d (->datum x))
  (define subs (stx-subs x))
  (store-src!
   (cond
    [(string? d)        d]
    [(boolean? d)       d]
    [(exact-integer? d) d]
    [(real? d)          d]
    ;; Clojure char literal (\z, \tab, \space, …) — the reader produces a
    ;; Racket char? value; pass it through to the emit layer unchanged.
    [(char? d)          d]
    [(and (symbol? d) (dynamic-var-sym? d))
     (validate-identifier! d "dynamic var")
     (dynamic-var d)]
    [(and (symbol? d)
          (let ([s (symbol->string d)])
            (and (> (string-length s) 1) (char=? (string-ref s 0) #\@))))
     ;; `@x` reader-deref sugar → (deref x). Racket's `read` has no `@`
     ;; readtable entry, so it leaves `@x` as a single symbol; desugar it
     ;; here. Only fires on symbols literally starting with `@`, which never
     ;; emit valid code otherwise, so this can't change any existing program.
     (parse-expr (list 'deref (string->symbol (substring (symbol->string d) 1))))]
    [(symbol? d)
     (validate-identifier! d)
     (lower-reference d x)]
    [(and (pair? d) (eq? (car d) '#%regex) (= (length d) 2) (string? (cadr d)))
     (regex-lit (cadr d))]
    [(bracketed? d)
     (vec-form (map parse-expr (or (stx-tail subs 1) (bracket-body d))))]
    [(map-tagged? d)
     (parse-map-literal (or (stx-tail subs 1) (map-body d)))]
    [(set-tagged? d)
     (set-form (map parse-expr (or (stx-tail subs 1) (set-body d))))]
    [(and (pair? d) (eq? (car d) 'quote) (= (length d) 2))
     ;; Quoted containers — '[…] / '{…} / '#{…} — parse as the
     ;; container itself. Containers always evaluate in beagle, so
     ;; stripping the quote prefix is meaning-preserving (identity).
     ;; Source can write either form; canonical form on disk drops
     ;; the quote.
     (let* ([inner (cadr d)]
            [inner-stx (stx-ref subs 1)]
            [inner-children (stx-subs inner-stx)])
       (cond
         [(bracketed? inner)
          (vec-form (map parse-expr
                         (or (and inner-children (stx-tail inner-children 1))
                             (bracket-body inner))))]
         [(map-tagged? inner)
          (parse-map-literal (or (and inner-children (stx-tail inner-children 1))
                                 (map-body inner)))]
         [(set-tagged? inner)
          (set-form (map parse-expr
                         (or (and inner-children (stx-tail inner-children 1))
                             (set-body inner))))]
         [else (quoted inner)]))]
    [(and (pair? d) (eq? (car d) '#%meta) (= (length d) 3))
     (with-meta (parse-expr (or (and subs (stx-ref subs 1)) (cadr d)))
                (parse-expr (or (and subs (stx-ref subs 2)) (caddr d))))]
    [(pair? d)
     (define reg (current-registry))
     (cond
       ;; Head dispatch goes through the unified resolver (head-meaning): macros
       ;; outrank built-in combiners outrank legacy. The macro branch below is
       ;; the same code that ran before step 5 — only the guard moved.
       [(eq? (head-meaning reg (car d)) 'macro)
        ;; Parse the expansion result with current-macro-expansion-ctx
        ;; set so that any parse rejection on the macro output is
        ;; bucketed as 'macro-expansion-parse-error. Also record the
        ;; resulting node in the macro-derived table so check.rkt
        ;; rebuckets later type errors as 'macro-expansion-type-error.
        (define call-syntax
          (if (syntax? x)
              (racket-syntax->beagle-syntax x (current-source-bytes))
              (datum->beagle-syntax d #f)))
        (define ctx (make-root-ctx (car d) call-syntax))
        (define parsed-node
          (parameterize ([current-macro-expansion-ctx ctx])
            ;; Blame the call site `x` for the expansion: tag the generated
            ;; datum with the macro-call's srcloc so diagnostics on the
            ;; expansion point where the author invoked the macro, not at the
            ;; enclosing top-level form. (Lean withRef / fromRef-canonical.)
            ;; parse-expr is dual-mode: `x` is a syntax object on the top-level
            ;; path but a RAW DATUM when parsing a sub-form (e.g. a macro call
            ;; nested inside another form). datum->syntax's srcloc arg accepts
            ;; only #f / syntax / srcloc — a raw datum crashes it — so blame the
            ;; call site only when `x` is real syntax, else #f (no srcloc, same
            ;; as the pre-blame behavior). Fixes a crash on nested macro calls.
            (parse-expr
             (beagle-syntax->racket-syntax
              (expand-fully/at-source reg d (and (syntax? x) x))))))
        (mark-macro-derived! parsed-node ctx)
        parsed-node]
       [else
        (parameterize ([current-form-stx x])
          (parse-list-form d subs))])]
    [else (error 'beagle "unsupported expression: ~v" d)])
   loc))

;; A typed binding is structural: `(binding-form Type [constraint])`. The
;; optional constraint is a predicate expression owned by the same binding.
;; The binding form is
;; either a name or an ordinary Clojure destructuring pattern.  Keeping the
;; pattern as one datum makes `(x Int)`, `([x y] (HVec Int Int))`, and
;; `({:keys [host port]} Config)` the same grammatical operation.
(define (binding-form-datum? item)
  (or (symbol? item)
      (bracketed? item)
      (map-destructure-form? item)))

;; A structured binding is written with PARENS — `(binding-form Type)` or
;; `(binding-form Type constraint)`. A bare `[x y]` or `{:keys [...]}` is a
;; reader-tagged 3-element list, so the tag must be excluded here or an
;; unannotated destructure would parse as a constrained binding whose type is
;; its own first pattern element.
(define (structured-binding? item)
  (and (list? item)
       (not (bracketed? item))
       (not (map-destructure-form? item))
       (memq (length item) '(2 3))
       (binding-form-datum? (car item))))

(define (parse-binding-form item where)
  (cond
    [(symbol? item)
     (validate-identifier! item where)
     (note-capitalized-binding! item where)
     item]
    [(bracketed? item) (parse-seq-destructure item)]
    [(map-destructure-form? item) (parse-map-destructure item)]
    [else
     (raise-parse-error
      'inline-type-annotation
      "bad ~a binding form `~a` — expected a name, [pattern ...], or {:keys [...]}"
      where
      (binding-datum->src item))]))

(define (parse-structured-binding item where [item-stx #f])
  (unless (structured-binding? item)
    (raise-parse-error
     'inline-type-annotation
     "bad typed ~a `~a` — write `(binding-form Type)` or `(binding-form Type constraint)`"
     where
     (binding-datum->src item)))
  (define item-subs (stx-subs item-stx))
  (define has-constraint? (= (length item) 3))
  (define constraint-datum (and has-constraint? (caddr item)))
  ;; `#f` is the AST's absence sentinel, so accepting the literal `false` here
  ;; would silently turn an explicitly written (and necessarily non-callable)
  ;; constraint into no constraint at all. Reject it at the owning form with a
  ;; targeted message instead of laundering it through the sentinel.
  (when (and has-constraint? (eq? constraint-datum #f))
    (raise-parse-error
     'inline-type-annotation
     "invalid ~a constraint `false` — a constraint must be a callable expression of type [~a -> Bool]"
     #:details (let ([constraint-stx (stx-ref item-subs 2)])
                 (if (syntax? constraint-stx)
                     (hasheq 'error-file (source-detail-path constraint-stx)
                             'error-line (or (syntax-line constraint-stx)
                                             (and (syntax? item-stx)
                                                  (syntax-line item-stx)))
                             'error-col (or (syntax-column constraint-stx)
                                            (and (syntax? item-stx)
                                                 (syntax-column item-stx))))
                     (hasheq)))
     where
     (binding-datum->src (cadr item))))
  (values (parse-binding-form (car item) where)
          (parse-type (cadr item))
          (and has-constraint?
               ;; Preserve the constraint expression's own source location.
               ;; The checker and target validators must point at the
               ;; predicate, not merely at the enclosing declaration.
               (parse-expr (or (stx-ref item-subs 2) constraint-datum)))))

;; A union's enclosing sequence contains complete member declarations. A
;; fielded member is exactly `(Name [fields...])`; no parser path may recover a
;; member from a prefix and silently ignore or repartition trailing metadata.
(define (union-member-declaration? datum)
  (or (symbol? datum)
      (and (list? datum)
           (= (length datum) 2)
           (symbol? (car datum))
           (bracketed? (cadr datum)))))

(define (union-member-error-details member-stx datum)
  (source-error-details member-stx datum))

(define (parse-union-member-declaration member where [type-vars '()])
  (define datum (->datum member))
  (unless (union-member-declaration? datum)
    (raise-parse-error
     'bad-defunion
     (string-append
      "Invalid union member declaration: ~a\n\n"
      "Each member must be one complete form:\n"
      "  Name\n"
      "  (Name [(field Type) (field Type validator) ...])")
     #:details (union-member-error-details member datum)
     (binding-datum->src datum)))
  (define fielded? (list? datum))
  (define name (if fielded? (car datum) datum))
  (validate-identifier! name (format "~a member" where))
  (reject-reserved-type-name! name (format "~a member" where))
  (define fields
    (if fielded?
        (let ([member-subs (stx-subs member)])
          (parameterize ([current-type-vars
                          (append type-vars (current-type-vars))])
            (parse-record-fields
             (or (stx-ref member-subs 1) (cadr datum)))))
        '()))
  (values name fields fielded?))

;; A capitalized bare binding is usually an accidentally unwrapped type name.
(define (note-capitalized-binding! name where)
  (define s (symbol->string name))
  (when (and (> (string-length s) 0) (char-upper-case? (string-ref s 0)))
    (eprintf "warning [capitalized-binding-name] `~a` bound as a ~a name — possible missing `(name Type)` wrapper?\n"
             name where)))

(define (multi-arity-form? d)
  (and (pair? d) (list? d)
       (let ([first-elem (car d)])
         (or (bracketed? first-elem)
             (and (pair? first-elem) (bracketed? (car first-elem)))))))

(define (signature-where-clause? datum)
  (and (list? datum) (= (length datum) 2) (eq? (car datum) 'where)))

(define (parse-signature-tail return-datum tail [tail-stxs #f]
                              #:raises? [raises-allowed? #t]
                              #:context [context "function"])
  (define parsed-return (parse-type return-datum))
  (define-values (effective-return after-where after-where-stxs)
    (if (and (pair? tail) (signature-where-clause? (car tail)))
        (values (type-refinement parsed-return (cadar tail) 'signature)
                (cdr tail)
                (and tail-stxs (cdr tail-stxs)))
        (values parsed-return tail tail-stxs)))
  (define-values (raises body body-stxs)
    (if (and raises-allowed? (pair? after-where) (eq? (car after-where) ':raises))
        (begin
          (when (< (length after-where) 3)
            (raise-parse-error
             'bad-form "~a :raises needs an error type and body" context))
          (values (parse-type (cadr after-where))
                  (cddr after-where)
                  (and after-where-stxs (cddr after-where-stxs))))
        (values #f after-where after-where-stxs)))
  (when (null? body)
    (raise-parse-error
     'bad-form "~a needs a return type and body" context))
  (values effective-return raises (parse-body (or body-stxs body))))

(define (parse-arity-clause clause)
  (define datum (->datum clause))
  (define subs (stx-subs clause))
  (unless (and (pair? datum) (list? datum))
    (error 'beagle "multi-arity clause must be ([params] ReturnType body...)"))
  (define params-form (car datum))
  (define rest (cdr datum))
  (define-values (parsed rest-p)
    (parse-params (or (stx-ref subs 0) params-form)))
  (when (< (length rest) 2)
    (raise-parse-error
     'bad-form
     "multi-arity clause needs a return type and body — write `([params] ReturnType body...)`"))
  (define-values (return-type _raises body)
    (parse-signature-tail (car rest) (cdr rest) (stx-tail subs 2)
                          #:raises? #f #:context "multi-arity clause"))
  (arity-clause parsed rest-p return-type body))

;; A second top-level parameter vector in a single-arity `defn` tail is the
;; retired flattened multi-arity spelling. Detect the stray declaration form
;; only to reject it; never partition or reconstruct adjacent tokens into
;; clauses. Canonical multi-arity syntax wraps every whole clause in a list.
(define (flattened-defn-arity-index datum)
  (define (parameter-entry? entry)
    (or (symbol? entry)
        (structured-binding? entry)))
  (define (parameter-vector? candidate)
    (and (bracketed? candidate)
         (let loop ([items (bracket-body candidate)])
           (cond
             [(null? items) #t]
             [(eq? (car items) '&)
              (and (= (length items) 2)
                   (parameter-entry? (cadr items)))]
             [else
              (and (parameter-entry? (car items))
                   (loop (cdr items)))]))))
  (and (list? datum)
       (>= (length datum) 8)
       (memq (car datum) '(defn defn-))
       (bracketed? (list-ref datum 2))
       (let* ([raises? (and (>= (length datum) 7)
                            (eq? (list-ref datum 4) ':raises))]
              [body-start (if raises? 6 4)])
         (for/first ([candidate (in-list datum)]
                     [index (in-naturals)]
                     #:when (and (> index body-start)
                                 (<= (+ index 2) (sub1 (length datum)))
                                 (parameter-vector? candidate)))
           index))))

(define (raise-flattened-defn-arity datum subs index)
  (define stray (list-ref datum index))
  (define stray-stx (stx-ref subs index))
  (raise-parse-error
   'bad-form
   (string-append
    "Invalid multi-arity declaration: ~a\n\n"
    "Each arity must be one complete form:\n"
    "  ([params] ReturnType body...)")
   #:details
   (source-error-details stray-stx stray)
   (binding-datum->src stray)))

;; Parse letfn function list: `[(f [params] Return body...) ...]`.
(define (parse-letfn-fns form)
  (define d (->datum form))
  (define items (bracket-items form "letfn function list"))
  (define item-stxs (bracket-stxs (stx-subs form) d))
  ;; Each item should be (name [params...] body...) or (name [params...] : RetType body...)
  (for/list ([item (in-list items)] [index (in-naturals)])
    (define item-stx (and item-stxs (list-ref item-stxs index)))
    (define item-subs (stx-subs item-stx))
    (unless (and (list? item) (>= (length item) 4) (symbol? (car item)))
      (error 'beagle "letfn: each function must be (name [params] ReturnType body...), got: ~v" item))
    (define name (car item))
    (validate-identifier! name "letfn function")
    (define params-form (cadr item))
    (define rest (cddr item))
    (define-values (parsed rest-p)
      (parse-params (or (stx-ref item-subs 1) params-form)))
    (register-syntax-binder!
     (letfn-fn name parsed rest-p
               (parse-type (car rest))
               (parse-body (or (stx-tail item-subs 3) (cdr rest))))
     (stx-ref item-subs 0))))

(define SCALAR-PRED-OPS '(>= <= > < = not=))

(define (parse-scalar-backing backing)
  (define parsed (parse-type backing))
  (unless (and (type-prim? parsed)
               (memq (type-prim-name parsed) PRIMITIVES))
    (raise-parse-error
     'bad-form
     "defscalar backing must resolve to one primitive type, got: ~v"
     backing))
  (type-prim-name parsed))

(define (parse-scalar-predicate p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (unless (and (list? d) (= (length d) 2)
               (memq (car d) SCALAR-PRED-OPS)
               (or (exact-integer? (cadr d)) (real? (cadr d))))
    (raise-parse-error
     'bad-form
     "defscalar :where predicate must be (op numeric-literal), got: ~v"
     #:details
     (if (syntax? p)
         (let ([source (syntax-source p)])
           (hasheq 'error-file
                   (cond [(path? source) (path->string source)]
                         [(string? source) source]
                         [else #f])
                   'error-line (syntax-line p)
                   'error-col (syntax-column p)))
         (hasheq))
     d))
  (store-src! (scalar-predicate (car d) (cadr d))
              (and (syntax? p) (stx->src-loc p))))

;; (fmt-* interpolation helpers removed with the `fmt` form, 2026-06-12 —
;; zero corpus hits; `str` / `format` are the Clojure spellings.)

;; threading macro expansion (parse-time rewrite → fully type-checked)
;;
;; The Clojure threading family is encoded as parse-time rewrites to ordinary
;; call-form / let-form / if-form composition. No new AST nodes — every
;; threading construct lowers to shapes the type checker already handles.
;;
;; Insert VAL into STEP at POSITION ('first or 'last). When STEP is a
;; syntax object, the resulting list is wrapped with `datum->syntax` using
;; STEP as the context — this propagates the threading-step's srcloc to
;; the synthesized call. Bare steps `f` wrap as `(f val)` (likewise tagged
;; with f's loc when available).
(define (thread-step-insert val step position)
  (define step-datum (->datum step))
  (define step-subs (and (syntax? step) (stx-subs step)))
  (define result-datum
    (cond
      [(pair? step-datum)
       (cond
         [(eq? position 'first)
          ;; (head val arg2 arg3 …)
          (cons (or (stx-ref step-subs 0) (car step-datum))
                (cons val (or (and step-subs (stx-tail step-subs 1))
                              (cdr step-datum))))]
         [else
          ;; (head arg1 arg2 … val)
          (append (or step-subs step-datum) (list val))])]
      [else
       ;; Bare step `f` — synthesize (f val) with f's syntax preserved.
       (list step val)]))
  ;; Tag the constructed list with STEP's srcloc when STEP is a syntax
  ;; object. This is the key fix for the threading-family benchmark
  ;; entries: the outer call after expansion blames the step's line.
  (if (syntax? step)
      (datum->syntax step result-datum step)
      result-datum))

;; (-> x f g h) → (h (g (f x))) ; bare step `f` wraps as (f x)
;; (-> x (f a b)) → (f x a b)   ; insert as FIRST arg of step
(define (expand-thread-first init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'first))
         init steps))

;; (->> x f g h) → (h (g (f x))) ; bare step `f` wraps as (f x)
;; (->> x (f a b)) → (f a b x)  ; insert as LAST arg of step
(define (expand-thread-last init steps)
  (foldl (lambda (step acc) (thread-step-insert acc step 'last))
         init steps))

;; A receiver-first JS operator is intentionally incomplete while it occupies
;; a thread-step slot: the threader supplies its receiver before the expanded
;; form reaches the real operator parser. Keep the marker's surface copy as a
;; generic call-shaped AST so parsing that non-authoritative copy cannot reject
;; before insertion. The expanded form below still passes through the exact
;; js/* arity parser and is the only form checked or emitted for JS.
(define JS-RECEIVER-THREAD-HEADS
  '(js/get js/call js/set! js/delete! js/in?))

(define (parse-thread-surface-expr form)
  (define d (->datum form))
  (define subs (stx-subs form))
  (if (and (pair? d) (memq (car d) JS-RECEIVER-THREAD-HEADS))
      (store-src!
       (call-form (or (lower-qualified-reference (car d)) (car d))
                  (map parse-expr (or (stx-tail subs 1) (cdr d))))
       (and (syntax? form) (stx->src-loc form)))
      (parse-expr form)))

;; (as-> init name s1 s2 …)
;;   → (let [name init] (let [name s1] (let [name s2] … name)))
;; The placeholder `name` is bound to each successive step's value. The
;; body of the innermost let is just `name` so the form's value is the
;; final step's value. Each `let` shadows the previous binding, mirroring
;; Clojure's semantics: each step sees `name` bound to the prior step's
;; value, regardless of where `name` appears (or whether it appears at all).
(define (expand-as-thread init name steps)
  (define (chain values)
    (cond
      [(null? values) name]
      [else
       (list 'let (list BRACKET-TAG name (car values))
             (chain (cdr values)))]))
  (chain (cons init steps)))

;; (cond-> x t1 s1 t2 s2 …)
;;   → (let [g0 x]
;;        (let [g1 (if t1 (thread-first g0 s1) g0)]
;;          (let [g2 (if t2 (thread-first g1 s2) g1)] g2)))
;; Each step is thread-first like `->`. If the test is falsy, the prior
;; value is preserved (NOT rethreaded). Uses minted temps to avoid capturing
;; user identifiers across the chain — a FRESH temp per step, never one temp
;; rebound: emit-js flattens nested lets into one block, where rebinding the
;; same name emitted a duplicate `const` (a JS SyntaxError).
;;
;; Type-preservation: each step's expansion must produce a value of the
;; same type as the threaded value, because the if-form's else-branch
;; returns the prior temp. The type checker enforces this naturally via
;; if-form type-merge — no special handling needed in parse.
(define (expand-cond-thread init clauses position)
  (unless (even? (length clauses))
    (error 'beagle
           "~a: expected pairs of (test step) after init; got ~a trailing form(s)"
           (if (eq? position 'first) 'cond-> 'cond->>)
           (length clauses)))
  (define g0 (fresh-lowered-sym 'cond-thread))
  (define pairs (let loop ([cs clauses] [acc '()])
                  (cond [(null? cs) (reverse acc)]
                        [else (loop (cddr cs) (cons (cons (car cs) (cadr cs)) acc))])))
  (cond
    [(null? pairs)
     ;; (cond-> x) with no clauses — degenerate; just bind & return.
     (list 'let (list BRACKET-TAG g0 init) g0)]
    [else
     (list 'let (list BRACKET-TAG g0 init)
           (let chain-loop ([qs pairs] [g g0])
             (cond
               [(null? qs) g]
               [else
                (define test (car (car qs)))
                (define step (cdr (car qs)))
                (define threaded (thread-step-insert g step position))
                (define g* (fresh-lowered-sym 'cond-thread))
                (list 'let (list BRACKET-TAG g* (list 'if test threaded g))
                      (chain-loop (cdr qs) g*))])))]))

;; (some-> x f g h)
;;   → (let [g0 x]
;;        (if (nil? g0) nil
;;            (let [g1 (thread-first g0 f)]
;;              (if (nil? g1) nil
;;                  (let [g2 (thread-first g1 g)]
;;                    (if (nil? g2) nil
;;                        (thread-first g2 h)))))))
;; Short-circuits to nil at the first nil intermediate. position selects
;; thread-first (some->) vs thread-last (some->>).
(define (expand-some-thread init steps position)
  (cond
    [(null? steps) init]
    [else
     (let loop ([rest steps] [prev init])
       (cond
         [(null? rest) prev]
         [else
          (define g (fresh-lowered-sym 'some-thread))
          (define threaded (thread-step-insert g (car rest) position))
          (list 'let (list BRACKET-TAG g prev)
                (list 'if (list 'nil? g)
                      'nil
                      (if (null? (cdr rest))
                          threaded
                          (loop (cdr rest) threaded))))]))]))

;; Lower Clojure binding-conditional macros (if-let / when-let / if-some /
;; when-some) to their canonical (let …) (if …) shape. Identity-preserving:
;; the synthesized datum re-parses to the same AST a hand-written equivalent
;; would produce. Called from parse-list-form's match arms.
;;
;; bindings-stx is the original `[name expr]` form (still wrapped in
;; BRACKET-TAG); rest is the post-binding tail (datum list) — for
;; if-let/if-some it's (list then else); for when-let/when-some it's the
;; body sequence. rest-stxs is the corresponding list of syntax objects
;; recovered from the surface form's stx-tail (or #f when unavailable);
;; embedding those preserves per-step srcloc in the synthesized output.
(define (lower-binding-cond head bindings-stx rest [rest-stxs #f])
  (define bdatum (->datum bindings-stx))
  (define bracketed? (and (pair? bdatum) (eq? (car bdatum) BRACKET-TAG)))
  (unless (or bracketed?
              (and (list? bdatum)
                   (or (not (syntax? bindings-stx))
                       (not (syntax-source bindings-stx)))))
    (error 'beagle "~a: bindings must be written in `[binder expr]`, got: ~v"
           head bdatum))
  (define items (if bracketed? (cdr bdatum) bdatum))
  (define binding-subs (stx-subs bindings-stx))
  (define item-stxs
    (and binding-subs
         (if bracketed? (cdr binding-subs) binding-subs)))
  (unless (>= (length items) 2)
    (error 'beagle
           "~a: bindings must be [binder expr], got: ~v" head bdatum))
  ;; value = last item; binder-part = everything before it (a name, one
  ;; structural `(binding-form Type)`, or one map/seq destructure datum).
  (define rev (reverse items))
  (define value (car rev))
  (define binder-part (reverse (cdr rev)))
  (define binder-part-source
    (if (and item-stxs (= (length item-stxs) (length items)))
        (take item-stxs (length binder-part))
        binder-part))
  ;; Recover the value's syntax (the LAST sub) so its srcloc survives.
  (define val-stx
    (let ([bsubs (stx-subs bindings-stx)]
          [idx (if bracketed? (length items) (sub1 (length items)))])
      (cond [bsubs (or (stx-ref bsubs idx) value)] [else value])))
  ;; Pick the syntax-preserving rest items where possible.
  (define rest-items
    (cond
      [(and rest-stxs (= (length rest-stxs) (length rest))) rest-stxs]
      [else rest]))
  (case head
    [(if-let if-some)
     (unless (= (length rest) 2)
       (error 'beagle "~a: expected (~a [binder expr] then else), got: ~v"
              head head (cons head (cons bdatum rest))))]
    [(when-let when-some)
     (when (null? rest)
       (error 'beagle "~a: expected at least one body expression after bindings"
              head))])
  (define (success-test v)
    (case head
      [(if-let when-let)   v]
      [(if-some when-some) (list 'not (list 'nil? v))]))
  (cond
    ;; Simple `[name expr]`: the bound NAME is the truth test (no temp). Keeps the
    ;; simple-case lowering byte-identical to the original.
    [(and (= (length binder-part) 1) (symbol? (car binder-part)))
     (define name (car binder-part))
     (define name-source (car binder-part-source))
     (define binding (list BRACKET-TAG name-source val-stx))
     (define test (success-test name-source))
     (case head
       [(if-let if-some)
        (list 'let binding (list 'if test (car rest-items) (cadr rest-items)))]
       [(when-let when-some)
        (list 'let binding (list 'if test (cons 'do rest-items)))])]
    ;; Typed `[(name Type) expr]` or destructuring `[{:keys […]} expr]` / `[[a b]
    ;; expr]`: bind a TEMP, test the temp, and bind the real binder inside the
    ;; SUCCESS branch only. The temp narrows non-nil in the then-branch, so a
    ;; the declared Type applies to the narrowed value (not the raw nullable),
    ;; and a destructure binder is out of scope on the false/else path (Clojure).
    [else
     (define g (fresh-lowered-sym 'bind))
     (define inner-binding
       (append (list BRACKET-TAG) binder-part-source (list g)))
     (define test (success-test g))
     (case head
       [(if-let if-some)
        (list 'let (list BRACKET-TAG g val-stx)
              (list 'if test
                    (list 'let inner-binding (car rest-items))
                    (cadr rest-items)))]
       [(when-let when-some)
        (list 'let (list BRACKET-TAG g val-stx)
              (list 'if test
                    (list 'let inner-binding (cons 'do rest-items))))])]))

;; expand-cond-thread, expand-some-thread, expand-as-thread are defined
;; above with the rest of the threading family. The Clojure threading
;; macros are the canonical replacement for the removed pipe family.

(define (parse-condp-form pred-stx test-stx clause-stxs)
  (define pred-expr (parse-expr pred-stx))
  (define test-expr (parse-expr test-stx))
  (define clauses-raw (map ->datum clause-stxs))
  (define-values (pairs default)
    (let loop ([cs clauses-raw] [acc '()])
      (cond
        [(null? cs) (values (reverse acc) #f)]
        [(null? (cdr cs)) (values (reverse acc) (parse-expr (car cs)))]
        [else (loop (cddr cs)
                    (cons (cons (parse-expr (car cs))
                                (parse-expr (cadr cs)))
                          acc))])))
  (condp-form pred-expr test-expr pairs default))

;; --- compile-time combiner registry ---------------------------------------
;; The seed of the unified front-end combiner layer (thread 20260615034227):
;; a head-symbol -> handler table consulted BEFORE the legacy hardcoded form
;; dispatch (parse-list-form*). Each handler takes (datum subs) and returns the
;; SAME typed-IR (AST) node the old match arm produced, so check/emit and the
;; emit goldens are byte-identical. Built-in special forms migrate here one at a
;; time; user macros fold into the same table later (thread step 5).
;; Invariant: a combiner produces a typed-IR node, never emitted code.
(define COMBINERS (make-hasheq))
(define (register-combiner! head handler) (hash-set! COMBINERS head handler))
(define (lookup-combiner head) (hash-ref COMBINERS head #f))

;; --- unified head resolver (thread 20260615034227, step 5) -----------------
;; `head-meaning` is the single authority on "what does this head mean?". It
;; names the precedence that is implicit across the two head sites today
;; (the macro arm in parse-expr, which runs BEFORE parse-list-form/COMBINERS):
;;
;;   'macro   — `reg` holds a user macro for this head; the macro path owns it.
;;   'builtin — a built-in special form lives in the global COMBINERS table.
;;   'legacy  — neither; falls through to the hardcoded parse-list-form* dispatch.
;;
;; Precedence is macro > builtin > legacy, so a user macro named like a built-in
;; (e.g. `if`) shadows the built-in — exactly as before this refactor.
;;
;; The two TABLES stay separate by design (see register-combiner! doc): COMBINERS
;; is a shared, process-global `hasheq`; the macro registry `reg` is a per-program
;; `make-hash` with qualified names. This resolver routes BOTH through one rule
;; without merging them — the macro branch's extra inputs (call-site syntax for
;; blame, per-call ctx, `reg`) are a superset of the `(d subs)` combiner contract,
;; so the unifying object is this function, not a merged table.
(define (head-meaning reg head)
  (cond
    [(and reg (symbol? head) (lookup-macro reg head)) 'macro]
    [(and (symbol? head) (lookup-combiner head))      'builtin]
    [else                                             'legacy]))

;; `do` — sequence; value is its last expression. (First form migrated.)
(register-combiner! 'do
  (lambda (d subs)
    (do-form (parse-body (or (stx-tail subs 1) (cdr d))))))

;; `(: expr Type)` is a compile-time ascription. Emitters erase the wrapper
;; after the checker proves the inner expression compatible with Type.
(register-combiner! ':
  (lambda (d subs)
    (match d
      [(list ': expr type-datum)
       (ascription (parse-expr (or (stx-ref subs 1) expr))
                    (parse-type type-datum))]
      [_ (raise-parse-error
          'bad-form
          "ascription requires exactly `(: expr Type)`, got: ~v" d)])))

;; `if` — conditional (2- and 3-arg). Any other arity falls back to the legacy
;; dispatch, so malformed `if` is handled exactly as before.
(register-combiner! 'if
  (lambda (d subs)
    (match d
      [(list 'if c t e)
       (if-form (parse-expr (or (stx-ref subs 1) c))
                (parse-expr (or (stx-ref subs 2) t))
                (parse-expr (or (stx-ref subs 3) e)))]
      [(list 'if c t)
       (if-form (parse-expr (or (stx-ref subs 1) c))
                (parse-expr (or (stx-ref subs 2) t))
                #f)]
      [_ (parse-list-form* d subs)])))

;; `let` — lexical binding block.
(register-combiner! 'let
  (lambda (d subs)
    (match d
      [(list 'let bindings-form body ...)
       (let-form (parse-local-bindings
                  (or (stx-ref subs 1) bindings-form) "let binding")
                 (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `letfn` — mutually-recursive local function block.
(register-combiner! 'letfn
  (lambda (d subs)
    (match d
      [(list 'letfn fns-form body ...)
       (letfn-form (parse-letfn-fns (or (stx-ref subs 1) fns-form))
                   (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `loop` — recur target with initial bindings.
(register-combiner! 'loop
  (lambda (d subs)
    (match d
      [(list 'loop bindings-form body ...)
       (loop-form (parse-local-bindings
                   (or (stx-ref subs 1) bindings-form) "loop binding")
                  (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `with-open` — resource-scoped binding block (auto-close on exit).
(register-combiner! 'with-open
  (lambda (d subs)
    (match d
      [(list 'with-open bindings-form body ...)
       (with-open-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                       (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `binding` — dynamic-extent rebinding of `^:dynamic` vars. Same binding-pair
;; surface as `let`, but the targets are existing dynamic vars (checked), not
;; new lexical locals. Reuses parse-let-bindings (types come from the var).
(register-combiner! 'binding
  (lambda (d subs)
    (match d
      [(list 'binding bindings-form body ...)
       (binding-form (parse-let-bindings (or (stx-ref subs 1) bindings-form))
                     (parse-body (or (stx-tail subs 2) body)))]
      [_ (raise-parse-error 'bad-form
                            "malformed binding — expected (binding [*var* val ...] body...); got: ~v" d)])))

;; `for` — list comprehension (clauses: bindings, :when, :let).
(register-combiner! 'for
  (lambda (d subs)
    (match d
      [(list 'for bindings-form body ...)
       (for-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                 (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `doseq` — side-effecting iteration (shares for-clause parsing with `for`).
(register-combiner! 'doseq
  (lambda (d subs)
    (match d
      [(list 'doseq bindings-form body ...)
       (doseq-form (parse-for-clauses (or (stx-ref subs 1) bindings-form))
                   (parse-body (or (stx-tail subs 2) body)))]
      [_ (parse-list-form* d subs)])))

;; `doto` — evaluate target, thread it through side-effecting forms, return it.
(register-combiner! 'doto
  (lambda (d subs)
    (match d
      [(list 'doto target forms ...)
       (doto-form (parse-expr (or (stx-ref subs 1) target))
                  (map parse-expr (or (stx-tail subs 2) forms)))]
      [_ (parse-list-form* d subs)])))

;; `unless` — removed surface (not Clojure). Pointed rejection naming when-not.
(register-combiner! 'unless
  (lambda (d subs)
    (raise-parse-error 'removed-form
                       "(unless c body...) — `unless` is not a Clojure form. Use `(when-not c body...)`.")))

;; `cond` — multi-clause conditional. Single arm; parse-cond-clauses owns all
;; clause-shape validation/errors.
(register-combiner! 'cond
  (lambda (d subs)
    (cond-form (parse-cond-clauses (or (stx-tail subs 1) (cdr d))))))

;; `case` — removed surface. Folded into `match`. Pointed rejection.
(register-combiner! 'case
  (lambda (d subs)
    (raise-parse-error 'removed-form
                       "case removed — use (match x [v1 body] [v2 body] [_ default]) or (match x [(or v1 v2) shared-body] [_ default]); literal-only matches case-fold to target-native dispatch in emit")))

;; `fn` — anonymous function with a fixed return-type slot.
(register-combiner! 'fn
  (lambda (d subs)
    (match d
      ;; Multi-arity anonymous fn — `(fn ([] x) ([a] y))`. Until `fn-multi`
      ;; lands across parse/check/emit, reject the structural clause form with
      ;; a pointed, actionable error.
      [(list 'fn first-clause rest-clauses ...)
       #:when (multi-arity-form? first-clause)
       (raise-parse-error 'bad-form
         "multi-arity anonymous `fn` is not yet supported — give it a name with `defn` (which supports multi-arity), or use a single arity.")]
      [(list 'fn params-form return-type body body-rest ...)
       (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
         (define-values (effective-return _raises parsed-body)
           (parse-signature-tail return-type (cons body body-rest)
                                 (stx-tail subs 3)
                                 #:raises? #f #:context "fn"))
         (fn-form parsed rest-p
                  effective-return
                  parsed-body))]
      [(list 'fn params-form _ ...)
       (raise-parse-error
        'bad-form
        "fn needs a return type and body — write `(fn [params] ReturnType body...)`")]
      [_ (parse-list-form* d subs)])))

;; `defonce` — once-only top-level binding; an optional type occupies its own
;; positional slot: `(defonce name Type value)`.
(register-combiner! 'defonce
  (lambda (d subs)
    (match d
      [(list 'defonce (? symbol? name) type-expr (? string? doc) value)
       (defonce-form name (parse-type type-expr)
                     (parse-expr (or (stx-ref subs 4) value))
                     doc)]
      [(list 'defonce (? symbol? name) (and type-expr (not (? string?))) value)
       (defonce-form name (parse-type type-expr)
                     (parse-expr (or (stx-ref subs 3) value))
                     #f)]
      [(list 'defonce (? symbol? name) (? string? doc) value)
       (defonce-form name #f (parse-expr (or (stx-ref subs 3) value)) doc)]
      [(list 'defonce (? symbol? name) value)
       (defonce-form name #f (parse-expr (or (stx-ref subs 2) value)) #f)]
      [(cons 'defonce _)
       (raise-parse-error 'bad-form
                          "malformed defonce — expected (defonce NAME VALUE), (defonce NAME \"doc\" VALUE), or (defonce NAME TYPE VALUE); got: ~v" d)]
      [_ (parse-list-form* d subs)])))

;; `set!` — mutable assignment.
(register-combiner! 'set!
  (lambda (d subs)
    (match d
      [(list 'set! target-expr val-expr)
       (set!-form (parse-expr (or (stx-ref subs 1) target-expr))
                  (parse-expr (or (stx-ref subs 2) val-expr)))]
      [_ (parse-list-form* d subs)])))

;; `defrecord` — typed record shape.
(register-combiner! 'defrecord
  (lambda (d subs)
    (match d
      [(list 'defrecord (? symbol? name) fields-form)
       (reject-reserved-type-name! name "defrecord")
       (record-form name (parse-record-fields (or (stx-ref subs 2) fields-form)))]
      [_ (parse-list-form* d subs)])))

;; `defenum` — keyword-variant enum.
(register-combiner! 'defenum
  (lambda (d subs)
    (match d
      [(list 'defenum (? symbol? name) values ...)
       (reject-reserved-type-name! name "defenum")
       (defenum-form name (map ->datum (or (stx-tail subs 2) values)))]
      [_ (parse-list-form* d subs)])))

;; `defscalar` — newtype-style scalar over a backing primitive, with optional
;; :where refinement predicates.
(register-combiner! 'defscalar
  (lambda (d subs)
    (match d
      [(list 'defscalar (? symbol? name) (? symbol? backing) ':where preds ...)
       (reject-reserved-type-name! name "defscalar")
       (defscalar-form name
                       (parse-scalar-backing (->datum backing))
                       (map parse-scalar-predicate
                            (or (stx-tail subs 4) preds)))]
      [(list 'defscalar (? symbol? name) (? symbol? backing))
       (reject-reserved-type-name! name "defscalar")
       (defscalar-form name (parse-scalar-backing (->datum backing)) '())]
      [_ (parse-list-form* d subs)])))

;; `deftype` — removed form; pointed rejection pointing at defrecord + extend-type.
(register-combiner! 'deftype
  (lambda (d subs)
    (match d
      [(list 'deftype _ ...)
       (raise-parse-error 'removed-form
                          "deftype removed — use (defrecord Name [fields]) for the data shape and (extend-type Name Protocol (method ...)) for protocol impls")]
      [_ (parse-list-form* d subs)])))

;; `extend-type` — attach protocol implementations to a type.
(register-combiner! 'extend-type
  (lambda (d subs)
    (match d
      [(list 'extend-type (? symbol? type-name) rest ...)
       (extend-type-form type-name (parse-type-impls (or (stx-tail subs 2) rest)))]
      [_ (parse-list-form* d subs)])))

;; `comment` — Clojure (comment ...) reads-and-discards; value is nil.
(register-combiner! 'comment
  (lambda (d subs)
    'nil))

;; `target-case` — per-target branch selection; same AST as the legacy arm.
(register-combiner! 'target-case
  (lambda (d subs)
    (parse-target-case (or (stx-tail subs 1) (cdr d)))))

;; `try` — try/catch/finally; delegates to the unchanged parse-try-form.
(register-combiner! 'try
  (lambda (d subs)
    (parse-try-form (or (stx-tail subs 1) (cdr d)))))

;; `when` — Clojure conditional sugar; (when c body…) → (if c (do body…)).
;; Identity-preserving canonicalization (see the original arm's commentary).
;; Arity error (no body) re-uses the legacy rejection; anything else falls
;; through to parse-list-form* so e.g. bare `(when)` still reaches call-form.
(register-combiner! 'when
  (lambda (d subs)
    (match d
      [(list 'when c body ..1)
       (parse-expr (rewrite-as
                    (list 'if
                          (or (stx-ref subs 1) c)
                          (cons 'do (or (stx-tail subs 2) body)))))]
      [(list 'when _ ...)
       (raise-parse-error 'bad-form
                          "when requires at least one body expression: (when c body...)")]
      [_ (parse-list-form* d subs)])))

;; `when-not` — (when-not c body…) → (if (not c) (do body…)).
(register-combiner! 'when-not
  (lambda (d subs)
    (match d
      [(list 'when-not c body ..1)
       (parse-expr (rewrite-as
                    (list 'if
                          (list 'not (or (stx-ref subs 1) c))
                          (cons 'do (or (stx-tail subs 2) body)))))]
      [(list 'when-not _ ...)
       (raise-parse-error 'bad-form
                          "when-not requires at least one body expression: (when-not c body...)")]
      [_ (parse-list-form* d subs)])))

;; `if-not` — (if-not c t e) → (if c e t).
(register-combiner! 'if-not
  (lambda (d subs)
    (match d
      [(list 'if-not c then-expr else-expr)
       (parse-expr (rewrite-as
                    (list 'if
                          (or (stx-ref subs 1) c)
                          (or (stx-ref subs 3) else-expr)
                          (or (stx-ref subs 2) then-expr))))]
      [(list 'if-not _ ...)
       (raise-parse-error 'bad-form
                          "if-not expects (if-not c then else): three arguments required")]
      [_ (parse-list-form* d subs)])))

;; Clojure binding-conditional macros — accept-and-canonicalize to the
;; (let …) (if …) shape via lower-binding-cond. Identity-preserving; malformed
;; shapes fall through to parse-list-form* exactly as before.
;;   (if-let    [x v] t e)    → (let [x v] (if x t e))
;;   (when-let  [x v] body…)  → (let [x v] (if x (do body…)))
;;   (if-some   [x v] t e)    → (let [x v] (if (not (nil? x)) t e))
;;   (when-some [x v] body…)  → (let [x v] (if (not (nil? x)) (do body…)))
(register-combiner! 'if-let
  (lambda (d subs)
    (match d
      [(list 'if-let bindings then-expr else-expr)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'if-let
                                        (or (stx-ref subs 1) bindings)
                                        (list then-expr else-expr)
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'when-let
  (lambda (d subs)
    (match d
      [(list 'when-let bindings body ...)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'when-let
                                        (or (stx-ref subs 1) bindings)
                                        body
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'if-some
  (lambda (d subs)
    (match d
      [(list 'if-some bindings then-expr else-expr)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'if-some
                                        (or (stx-ref subs 1) bindings)
                                        (list then-expr else-expr)
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'when-some
  (lambda (d subs)
    (match d
      [(list 'when-some bindings body ...)
       (parse-expr (rewrite-as
                    (lower-binding-cond 'when-some
                                        (or (stx-ref subs 1) bindings)
                                        body
                                        (and subs (stx-tail subs 2)))))]
      [_ (parse-list-form* d subs)])))

;; --- def family migrated to the compile-time combiner registry ---

;; Detect `^:dynamic` on a def name. The reader yields the metadata value as
;; either the keyword-symbol `:dynamic` (`^:dynamic` shorthand) or a `#%map`
;; carrying `:dynamic true` (`^{:dynamic true}` longhand). Any other metadata
;; (e.g. `^:private`, `^:const`) is accepted and stripped — `:dynamic` is the
;; only def metadata beagle acts on.
(define (meta-dynamic? mv)
  (cond
    [(eq? mv ':dynamic) #t]
    [(and (pair? mv) (eq? (car mv) '#%map))
     (let loop ([kvs (cdr mv)])
       (cond
         [(or (null? kvs) (null? (cdr kvs))) #f]
         [(and (eq? (car kvs) ':dynamic) (eq? (cadr kvs) 'true)) #t]
         [else (loop (cddr kvs))]))]
    [else #f]))

;; `def` — top-level binding; positional `NAME TYPE VALUE`, optional docstring; optional
;; `^:dynamic` (and other) metadata on the name; any other def shape guarded
;; (no silent call-form bypass).
(register-combiner! 'def
  (lambda (d subs)
    (match d
      [(list 'def (? symbol? name) type-expr (? string? doc) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 4) value))
                 doc #f)]
      [(list 'def (? symbol? name) (and type-expr (not (? string?))) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 3) value))
                 #f #f)]
      [(list 'def (? symbol? name) (? string? doc) value)
       (def-form name #f (parse-expr (or (stx-ref subs 3) value)) doc #f)]
      [(list 'def (? symbol? name) value)
       (def-form name #f (parse-expr (or (stx-ref subs 2) value)) #f #f)]
      ;; `^:dynamic` (or any) metadata on the name. The metadata lives entirely
      ;; in slot 1, so later `subs` indices match the bare-name arms exactly.
      [(list 'def (list '#%meta mv (? symbol? name)) type-expr (? string? doc) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 4) value))
                 doc (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) (and type-expr (not (? string?))) value)
       (def-form name (parse-type type-expr)
                 (parse-expr (or (stx-ref subs 3) value))
                 #f (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) (? string? doc) value)
       (def-form name #f (parse-expr (or (stx-ref subs 3) value)) doc (meta-dynamic? mv))]
      [(list 'def (list '#%meta mv (? symbol? name)) value)
       (def-form name #f (parse-expr (or (stx-ref subs 2) value)) #f (meta-dynamic? mv))]
      ;; Any other def shape would fall through to the call-form passthrough
      ;; and silently bypass the type layer — guard it (bug class 2026-06-12).
      [(cons 'def _)
       (raise-parse-error 'bad-form
                          "malformed def — expected (def NAME VALUE), (def NAME \"doc\" VALUE), (def NAME TYPE VALUE), or (def NAME TYPE \"doc\" VALUE); got: ~v" d)]
      [_ (parse-list-form* d subs)])))

;; `defn` / `defn-` — function definition (public/private). These share several
;; (or 'defn 'defn-) arms, so both heads route to this ONE handler; the arms are
;; kept in source order (semantically significant), with defn-only and
;; defn--only arms interleaved exactly as in the legacy match.
(define (parse-single-defn name params-form return-datum tail subs private?)
  (let-values ([(parsed rest-p)
                (parse-params (or (stx-ref subs 2) params-form))])
    (define-values (return-type raises body)
      (parse-signature-tail return-datum tail (stx-tail subs 4)
                            #:context (format "defn ~a" name)))
    (defn-form name parsed rest-p return-type body private? raises #f)))

(define (parse-defn-form d subs)
  ;; Reserved-name guard: a function named after a built-in combiner head would be
  ;; defined as dead code while every (name ...) call site silently resolves to the
  ;; combiner instead — a clean-typing RUNTIME miscompile (the reported `check` bug).
  ;; Reject it loudly. Names arrive bare `(defn name ...)` or meta `(defn ^:private
  ;; name ...)` => (#%meta _ name); the docstring/attr arms re-dispatch through here,
  ;; so the guard still fires for those shapes.
  (let ([nm (match d
              [(list* (or 'defn 'defn-) (? symbol? n) _) n]
              [(list* (or 'defn 'defn-) (list '#%meta _ (? symbol? n)) _) n]
              [_ #f])])
    (when nm (validate-identifier! nm "function"))
    (when (and nm (lookup-combiner nm))
      (raise-parse-error 'bad-form
        "(defn ~a ...) — `~a` is a reserved built-in form name and cannot be redefined; calls to it would resolve to the built-in, not your function. Rename the function."
        nm nm)))
  (define flattened-index (flattened-defn-arity-index d))
  (when flattened-index
    (raise-flattened-defn-arity d subs flattened-index))
  (match d
    ;; Docstring on defn/defn- (real Clojure surface): strip it, re-dispatch
    ;; the remaining form through the ordinary arms, then attach the doc to
    ;; the resulting node. Covers single-arity, multi-arity, and ^:private
    ;; name shapes uniformly.
    [(list* (and head (or 'defn 'defn-)) name-form (? string? doc) rest)
     #:when (and (pair? rest)
                 (or (symbol? name-form)
                     (and (pair? name-form) (eq? (car name-form) '#%meta))))
     (define stripped-subs
       (and subs (>= (length subs) 4)
            (list* (list-ref subs 0) (list-ref subs 1) (list-tail subs 3))))
     (define parsed (parse-list-form (list* head name-form rest) stripped-subs))
     (cond
       [(defn-form? parsed) (struct-copy defn-form parsed [doc doc])]
       [(defn-multi? parsed) (struct-copy defn-multi parsed [doc doc])]
       [else parsed])]

    ;; Attr-map metadata on defn is not supported — docstrings are the
    ;; supported documentation surface.
    [(list* (or 'defn 'defn-) _ (? map-tagged? _) _)
     (raise-parse-error 'bad-form
                        "defn attr-map metadata is not supported — use a docstring: (defn name \"doc\" [params] body)")]

    [(list 'defn (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (or (stx-tail subs 2)
                               (cons first-clause rest-clauses))) #f #f)]

    [(list 'defn (? symbol? name) params-form return-type tail ...)
     (parse-single-defn name params-form return-type tail subs #f)]

    ;; defn with ^:private metadata on name
    [(list 'defn (list '#%meta _ (? symbol? name)) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (or (stx-tail subs 2)
                               (cons first-clause rest-clauses))) #t #f)]

    [(list 'defn (list '#%meta _ (? symbol? name)) params-form return-type tail ...)
     (parse-single-defn name params-form return-type tail subs #t)]

    ;; defn- (private defn)
    [(list 'defn- (? symbol? name) first-clause rest-clauses ...)
     #:when (multi-arity-form? first-clause)
     (defn-multi name (map parse-arity-clause
                           (or (stx-tail subs 2)
                               (cons first-clause rest-clauses))) #t #f)]

    [(list 'defn- (? symbol? name) params-form return-type tail ...)
     (parse-single-defn name params-form return-type tail subs #t)]

    ;; Any defn shape the arms above didn't accept must not reach the
    ;; call-form passthrough (silent type-layer bypass — bug class 2026-06-12).
    [(cons (and head (or 'defn 'defn-)) _)
     (raise-parse-error 'bad-form
                        "malformed ~a — expected (~a name \"doc\"? [params...] ReturnType body...) or multi-arity (~a name ([params] ReturnType body...) ...); got: ~v"
                        head head head d)]
    [_ (parse-list-form* d subs)]))
(register-combiner! 'defn parse-defn-form)
(register-combiner! 'defn- parse-defn-form)

;; `defprotocol` — protocol declaration with method signatures.
(register-combiner! 'defprotocol
  (lambda (d subs)
    (match d
      [(list 'defprotocol (? symbol? name) sigs ...)
       (reject-reserved-type-name! name "defprotocol")
       (protocol-form name (map parse-protocol-method (or (stx-tail subs 2) sigs)))]
      [_ (parse-list-form* d subs)])))

;; `defunion` — tagged union; `:throwable` variant routes to deferror-form,
;; parametric form to parse-parametric-defunion.
(register-combiner! 'defunion
  (lambda (d subs)
    (match d
      ;; (defunion :throwable Name ...) — throwable variant union.
      ;; Routes to deferror-form internally (same structural shape; throw/catch
      ;; semantics live in the type checker's union-as-error logic). Inlined
      ;; rather than calling parse-deferror because subs offset differs by 1.
      [(list 'defunion ':throwable (? symbol? name) member-defs ...)
       (reject-reserved-type-name! name "defunion :throwable")
       (define member-names '())
       (define mf-hash (make-hasheq))
       (for ([md (in-list (or (stx-tail subs 3) member-defs))])
         (define-values (mname fields _fielded?)
           (parse-union-member-declaration md "throwable defunion"))
         (set! member-names (cons mname member-names))
         (hash-set! mf-hash mname fields))
       (deferror-form name (reverse member-names) mf-hash)]

      [(list 'defunion (? symbol? name) members ...)
       (reject-reserved-type-name! name "defunion")
       (define member-forms (or (stx-tail subs 2) members))
       (define mnames '())
       (define mf-hash (make-hasheq))
       (for ([member-form (in-list member-forms)])
         (define-values (mname fields fielded?)
           (parse-union-member-declaration member-form "defunion"))
         (set! mnames (cons mname mnames))
         (when fielded?
           (hash-set! mf-hash mname fields)))
       (defunion-form name (reverse mnames) '()
                      (if (hash-empty? mf-hash) #f mf-hash))]

      [(list 'defunion (list (? symbol? name) type-vars ...) member-defs ...)
       (parse-parametric-defunion name type-vars member-defs subs)]
      [_ (parse-list-form* d subs)])))

;; `deferror` — removed form; pointed rejection naming defunion :throwable.
(register-combiner! 'deferror
  (lambda (d subs)
    (match d
      [(list 'deferror _ ...)
       (raise-parse-error 'removed-form
                          "deferror removed — use (defunion :throwable Name ...) instead")]
      [_ (parse-list-form* d subs)])))

;; `defmulti` — removed form; pointed rejection naming defprotocol + extend-type.
(register-combiner! 'defmulti
  (lambda (d subs)
    (match d
      [(list 'defmulti _ ...)
       (raise-parse-error 'removed-form
                          "defmulti removed — use defprotocol + extend-type for type-based dispatch")]
      [_ (parse-list-form* d subs)])))

;; `defmethod` — removed form; pointed rejection naming defprotocol + extend-type.
(register-combiner! 'defmethod
  (lambda (d subs)
    (match d
      [(list 'defmethod _ ...)
       (raise-parse-error 'removed-form
                          "defmethod removed — use defprotocol + extend-type for type-based dispatch")]
      [_ (parse-list-form* d subs)])))

;; --- control family migrated to the compile-time combiner registry ---

;; `match` — pattern-match dispatch.
(register-combiner! 'match
  (lambda (d subs)
    (match d
      [(list 'match target-expr clauses ...)
       (parse-match-form (or (stx-ref subs 1) target-expr)
                         (or (stx-tail subs 2) clauses))]
      [_ (parse-list-form* d subs)])))

;; `condp` — predicate-dispatch conditional.
(register-combiner! 'condp
  (lambda (d subs)
    (match d
      [(list 'condp pred-fn test-expr clauses ...)
       (parse-condp-form (or (stx-ref subs 1) pred-fn)
                         (or (stx-ref subs 2) test-expr)
                         (or (stx-tail subs 3) clauses))]
      [_ (parse-list-form* d subs)])))

;; `cond->` — conditional thread-first. Desugars to a let-chain / (if …) nodes,
;; wrapped in threading-marker so the clj emitter can reconstruct surface.
(register-combiner! 'cond->
  (lambda (d subs)
    (match d
      [(list 'cond-> init clauses ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init clauses)))
       (threading-marker
        'cond->
        (map parse-thread-surface-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-cond-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) clauses)
                                         'first))))]
      [_ (parse-list-form* d subs)])))

;; `cond->>` — conditional thread-last.
(register-combiner! 'cond->>
  (lambda (d subs)
    (match d
      [(list 'cond->> init clauses ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init clauses)))
       (threading-marker
        'cond->>
        (map parse-thread-surface-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-cond-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) clauses)
                                         'last))))]
      [_ (parse-list-form* d subs)])))

;; `as->` — named-binding threading. Success arm + symbol-placeholder rejection.
(register-combiner! 'as->
  (lambda (d subs)
    (match d
      [(list 'as-> init (? symbol? name) steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init (cons name steps))))
       (threading-marker
        'as->
        (map parse-thread-surface-expr orig-stxs)
        (parse-expr
         (or (and (syntax? (current-form-stx))
                  (syntax-property
                   (current-form-stx) 'beagle-as-thread-resolved))
             (rewrite-as
              (expand-as-thread (or (stx-ref subs 1) init)
                                name
                                (or (and subs (stx-tail subs 3)) steps))))))]
      [(list 'as-> _ _ _ ...)
       (raise-parse-error 'bad-form
                          "as-> expects a symbol placeholder: (as-> init name steps...)")]
      [_ (parse-list-form* d subs)])))

;; `some->` — short-circuit thread-first.
(register-combiner! 'some->
  (lambda (d subs)
    (match d
      [(list 'some-> init steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init steps)))
       (threading-marker
        'some->
        (map parse-thread-surface-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-some-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) steps)
                                         'first))))]
      [_ (parse-list-form* d subs)])))

;; `some->>` — short-circuit thread-last.
(register-combiner! 'some->>
  (lambda (d subs)
    (match d
      [(list 'some->> init steps ...)
       (define orig-stxs (or (and subs (stx-tail subs 1))
                             (cons init steps)))
       (threading-marker
        'some->>
        (map parse-thread-surface-expr orig-stxs)
        (parse-expr (rewrite-as
                     (expand-some-thread (or (stx-ref subs 1) init)
                                         (or (and subs (stx-tail subs 2)) steps)
                                         'last))))]
      [_ (parse-list-form* d subs)])))

;; `recur` — loop/fn tail recursion target.
(register-combiner! 'recur
  (lambda (d subs)
    (match d
      [(list 'recur args ...)
       (recur-form (map parse-expr (or (stx-tail subs 1) args)))]
      [_ (parse-list-form* d subs)])))

;; `get` — literal-key projection canonicalizes to kw-access (2- and 3-arg).
;; Dynamic-key form (non-literal key) falls through to call-form via legacy.
(register-combiner! 'get
  (lambda (d subs)
    (match d
      [(list 'get target (? keyword-sym? kw))
       (kw-access kw (parse-expr (or (stx-ref subs 1) target)) #f)]
      [(list 'get target (? keyword-sym? kw) default-expr)
       (kw-access kw
                  (parse-expr (or (stx-ref subs 1) target))
                  (parse-expr (or (stx-ref subs 3) default-expr)))]
      [_ (parse-list-form* d subs)])))

;; `get-or` — Nix attr access with default.
(register-combiner! 'get-or
  (lambda (d subs)
    (match d
      [(list 'get-or base path-expr default-expr)
       (nix-get-or (parse-expr (or (stx-ref subs 1) base))
                   (let ([d (->datum (or (stx-ref subs 2) path-expr))])
                     (cond
                       [(symbol? d) (symbol->string d)]
                       [(and (pair? d) (eq? (car d) 'quote) (pair? (cdr d)))
                        (symbol->string (cadr d))]
                       [else (format "~a" d)]))
                   (parse-expr (or (stx-ref subs 3) default-expr)))]
      [_ (parse-list-form* d subs)])))

;; `has` — removed 2026-06-12 (zero corpus hits). Pointed rejection at contains?.
(register-combiner! 'has
  (lambda (d subs)
    (match d
      [(list 'has _ _)
       (raise-parse-error 'removed-form
                          "(has m :k) — `has` is removed. Use `(contains? m :k)` (Clojure spelling; lowers to hasAttr on nix)."
                          #:suggestion (replace-head-suggestion 'has 'contains?))]
      [_ (parse-list-form* d subs)])))

;; `assert` — bare `assert` HARD-REJECTED; canonical Nix form is `nix/assert`.
(register-combiner! 'assert
  (lambda (d subs)
    (match d
      [(list 'assert _ _)
       (raise-parse-error 'bare-nix-form
                          "(assert ...) — bare `assert` is not supported. Beagle namespaces target-specific forms; use `(nix/assert COND BODY)`."
                          #:suggestion (replace-head-suggestion 'assert 'nix/assert))]
      [_ (parse-list-form* d subs)])))

;; `rescue` — error-handling expression; named-handler and fallback shapes.
(register-combiner! 'rescue
  (lambda (d subs)
    (match d
      [(list 'rescue expr (? symbol? err-name) handler)
       (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                    (parse-expr (or (stx-ref subs 3) handler))
                    err-name)]
      [(list 'rescue expr fallback)
       (rescue-form (parse-expr (or (stx-ref subs 1) expr))
                    (parse-expr (or (stx-ref subs 2) fallback))
                    #f)]
      [_ (parse-list-form* d subs)])))

;; `js/await` — JS-async await (namespaced).
(register-combiner! 'js/await
  (lambda (d subs)
    (match d
      [(list 'js/await inner)
       (await-form (parse-expr (or (stx-ref subs 1) inner)))]
      [_ (parse-list-form* d subs)])))

;; `await` — bare `await` rejected with a pointed migration message to js/await.
(register-combiner! 'await
  (lambda (d subs)
    (match d
      [(list 'await _)
       (raise-parse-error 'bare-js-form
                          "(await ...) — bare `await` is not supported. Beagle namespaces target-specific forms; use `(js/await EXPR)`."
                          #:suggestion (replace-head-suggestion 'await 'js/await))]
      [_ (parse-list-form* d subs)])))

;; `fmt` — removed 2026-06-12 (zero corpus hits; not Clojure). Pointed rejection.
(register-combiner! 'fmt
  (lambda (d subs)
    (match d
      [(list 'fmt _ ...)
       (raise-parse-error 'removed-form
                          "(fmt \"... ${x} ...\") — `fmt` is removed. Use `(str \"... \" x \" ...\")` or `(format \"... %s ...\" x)`.")]
      [_ (parse-list-form* d subs)])))

;; `ms` — Nix multi-line string.
(register-combiner! 'ms
  (lambda (d subs)
    (match d
      [(list 'ms lines ...)
       (nix-multiline-string
        (map (lambda (line)
               (define d (->datum line))
               (if (string? d) d (parse-expr line)))
             (or (stx-tail subs 1) lines)))]
      [_ (parse-list-form* d subs)])))

;; `check` — check-expr wrapper.
(register-combiner! 'check
  (lambda (d subs)
    (match d
      [(list 'check expr)
       (check-expr (parse-expr (or (stx-ref subs 1) expr)))]
      [_ (parse-list-form* d subs)])))

;; `claim` — HARD-REJECTED; declarations carry types inline.
(register-combiner! 'claim
  (lambda (d subs)
    (match d
      [(cons 'claim _)
       (raise-parse-error 'claim-form-removed
        (string-append
         "(claim NAME TYPE) — claim is not a form. Beagle's surface is typed "
         "Clojure + inference; use `(def NAME TYPE VALUE)` for a top-level "
         "binding or `(defn NAME [(param TYPE)] RETURN-TYPE body...)`."))]
      [_ (parse-list-form* d subs)])))

;; `dotimes` — removed; sugar for (doseq [i (range n)] body...). Pointed rejection.
(register-combiner! 'dotimes
  (lambda (d subs)
    (match d
      [(list 'dotimes _ ...)
       (raise-parse-error 'removed-form
                          "dotimes removed — use (doseq [i (range n)] body...)")]
      [_ (parse-list-form* d subs)])))

;; --- module family migrated to the compile-time combiner registry ---

;; `unsafe` (+ unsafe-js/-clj/-py/-rkt/-nix/-expr) — shared (or …) rejection arm
;; migrated to the compile-time combiner registry (see register-combiner!).
(define (unsafe-family-combiner d subs)
  (match d
    [(list (or 'unsafe 'unsafe-js 'unsafe-clj 'unsafe-py 'unsafe-rkt 'unsafe-nix 'unsafe-expr) _ ...)
     (error 'beagle
            "(~a ...) escape hatches are not available. Beagle has no per-target escape by design — add to stdlib-*.rkt or write a separate target-language file and import it."
            (car d))]
    [_ (parse-list-form* d subs)]))
(register-combiner! 'unsafe        unsafe-family-combiner)
(register-combiner! 'unsafe-js     unsafe-family-combiner)
(register-combiner! 'unsafe-clj    unsafe-family-combiner)
(register-combiner! 'unsafe-py     unsafe-family-combiner)
(register-combiner! 'unsafe-rkt    unsafe-family-combiner)
(register-combiner! 'unsafe-nix    unsafe-family-combiner)
(register-combiner! 'unsafe-expr   unsafe-family-combiner)

;; `inherit` — Nix `inherit name…` migrated to the combiner registry.
(register-combiner! 'inherit
  (lambda (d subs)
    (match d
      [(list 'inherit names ...)
       (nix-inherit (map (lambda (n)
                           (define d (->datum n))
                           (if (symbol? d) d (error 'beagle "inherit: expected symbol, got ~v" d)))
                         (or (stx-tail subs 1) names)))]
      [_ (parse-list-form* d subs)])))

;; `inherit-from` — Nix `inherit (ns) name…` migrated to the combiner registry.
(register-combiner! 'inherit-from
  (lambda (d subs)
    (match d
      [(list 'inherit-from ns-expr names ...)
       (nix-inherit-from (parse-expr (or (stx-ref subs 1) ns-expr))
                         (map (lambda (n)
                                (define d (->datum n))
                                (if (symbol? d) d (error 'beagle "inherit-from: expected symbol, got ~v" d)))
                              (or (stx-tail subs 2) names)))]
      [_ (parse-list-form* d subs)])))

;; `rec-attrs` — Nix recursive attrset migrated to the combiner registry.
(register-combiner! 'rec-attrs
  (lambda (d subs)
    (match d
      [(list 'rec-attrs pairs ...)
       (nix-rec-attrs (parse-nix-rec-pairs (or (stx-tail subs 1) pairs)))]
      [_ (parse-list-form* d subs)])))

;; `search-path` — Nix `<name>` search-path migrated to the combiner registry.
(register-combiner! 'search-path
  (lambda (d subs)
    (match d
      [(list 'search-path name-expr)
       (define d (->datum (or (stx-ref subs 1) name-expr)))
       (nix-search-path (cond
                          [(symbol? d) (symbol->string d)]
                          [(string? d) d]
                          [else (error 'beagle "search-path: expected symbol or string, got ~v" d)]))]
      [_ (parse-list-form* d subs)])))

;; `module` — bare `module` HARD-REJECT (use `nix/module`) migrated to the
;; combiner registry. NOTE: `nix/module` is a DIFFERENT head and stays put.
(register-combiner! 'module
  (lambda (d subs)
    (match d
      [(list 'module _ _)
       (raise-parse-error 'bare-nix-form
                          "(module ...) — bare `module` is not supported. Beagle namespaces target-specific forms; use `(nix/module FORMALS BODY)`."
                          #:suggestion (replace-head-suggestion 'module 'nix/module))]
      [_ (parse-list-form* d subs)])))

;; `unquote` — `,` outside quasiquote; HARD-REJECT. Migrated to the registry.
(register-combiner! 'unquote
  (lambda (d subs)
    (match d
      [(list 'unquote _ ...)
       (raise-parse-error 'unknown-form
                          "unquote (`,`) outside quasiquote — `,x` is only valid inside a `` `…`` template in a defmacro body")]
      [_ (parse-list-form* d subs)])))

;; `unquote-splicing` — `,@` outside quasiquote; HARD-REJECT. Migrated to registry.
(register-combiner! 'unquote-splicing
  (lambda (d subs)
    (match d
      [(list 'unquote-splicing _ ...)
       (raise-parse-error 'unknown-form
                          "unquote-splicing (`,@`) outside quasiquote — `,@x` is only valid inside a `` `…`` template in a defmacro body")]
      [_ (parse-list-form* d subs)])))

;; `quasiquote` — `` ` `` outside defmacro body; HARD-REJECT. Migrated to registry.
(register-combiner! 'quasiquote
  (lambda (d subs)
    (match d
      [(list 'quasiquote _ ...)
       (raise-parse-error 'unknown-form
                          "quasiquote (`` ` ``) outside defmacro body — beagle's quasiquote is macro-template-only; use literal data containers (`'[…]` / `'{…}` / `'(…)`) for inert data construction")]
      [_ (parse-list-form* d subs)])))

;; --- nix family migrated to the compile-time combiner registry ---

;; `flake-input` — typed access to flake-input attribute paths.
(register-combiner! 'flake-input
  (lambda (d subs)
    (match d
      [(list 'flake-input input-name namespace rest ...)
       (unless (keyword-sym? input-name)
         (error 'beagle
                "flake-input: input-name must be a keyword (e.g. :quickshell), got ~v"
                input-name))
       (unless (keyword-sym? namespace)
         (error 'beagle
                "flake-input: namespace must be a keyword (e.g. :packages or :legacyPackages), got ~v"
                namespace))
       ;; Use rest (raw datum from match destructuring) rather than stx-tail —
       ;; segments are bare symbols, no source-location preservation needed.
       (for ([s (in-list rest)])
         (unless (or (keyword-sym? s) (symbol? s))
           (error 'beagle
                  "flake-input: path segment must be keyword or symbol, got ~v" s)))
       (flake-input-form input-name namespace rest)]
      [_ (parse-list-form* d subs)])))

;; `nix/assert` — canonical Nix assertion form.
(register-combiner! 'nix/assert
  (lambda (d subs)
    (match d
      [(list 'nix/assert cond-expr body-expr)
       ;; Canonical Nix assertion form. Bare `(assert ...)` is HARD-REJECTED —
       ;; see the bare-`assert` arm below.
       (nix-assert (parse-expr (or (stx-ref subs 1) cond-expr))
                   (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `nix/with-cfg` — config-path scoped let-binding form.
(register-combiner! 'nix/with-cfg
  (lambda (d subs)
    (match d
      [(list 'nix/with-cfg path-expr body-expr)
       ;; (nix/with-cfg config.myConfig.modules.X BODY) → introduces `cfg = config...;`
       ;; let-binding and rewrites config.myConfig.modules.X.foo to cfg.foo in BODY.
       ;; Bare `(with-cfg ...)` is HARD-REJECTED — see the bare-`with-cfg` arm below.
       (nix-with-cfg (parse-expr (or (stx-ref subs 1) path-expr))
                     (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `with-cfg` — bare form HARD-REJECTED; point at `nix/with-cfg`.
(register-combiner! 'with-cfg
  (lambda (d subs)
    (match d
      [(list 'with-cfg _ _)
       (raise-parse-error 'bare-nix-form
                          "(with-cfg ...) — bare `with-cfg` is not supported. Beagle namespaces target-specific forms; use `(nix/with-cfg PATH BODY)`."
                          #:suggestion (replace-head-suggestion 'with-cfg 'nix/with-cfg))]
      [_ (parse-list-form* d subs)])))

;; `nix/fn-set` — attrset-destructuring lambda: { a, b }: body
(register-combiner! 'nix/fn-set
  (lambda (d subs)
    (match d
      [(list 'nix/fn-set formals body-expr)
       (define-values (fl at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (nix-fn-set fl #f at-name (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `fn-set` — bare form HARD-REJECTED; point at `nix/fn-set`.
(register-combiner! 'fn-set
  (lambda (d subs)
    (match d
      [(list 'fn-set _ _)
       (raise-parse-error 'bare-nix-form
                          "(fn-set ...) — bare `fn-set` is not supported. Beagle namespaces target-specific forms; use `(nix/fn-set FORMALS BODY)`."
                          #:suggestion (replace-head-suggestion 'fn-set 'nix/fn-set))]
      [_ (parse-list-form* d subs)])))

;; `nix/module` — NixOS module / open-attrs lambda: { a, b, ... }: body
(register-combiner! 'nix/module
  (lambda (d subs)
    (match d
      [(list 'nix/module formals body-expr)
       ;; NixOS module / open-attrs lambda: { a, b, ... }: body
       (define-values (fl at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (nix-fn-set fl #t at-name (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `nix/overlay` — final: prev: body (curried, NOT attrset-destructure).
(register-combiner! 'nix/overlay
  (lambda (d subs)
    (match d
      [(list 'nix/overlay formals body-expr)
       ;; Nix overlay: final: prev: body (curried — NOT attrset-destructure)
       ;; Emits as fn-form so the nix emitter produces `final: prev: body`.
       (define-values (f-list _at-name)
         (parse-nix-fn-set-formals (or (stx-ref subs 1) formals)))
       (unless (= (length f-list) 2)
         (error 'beagle "nix/overlay: expected exactly two formals [final prev], got ~a" (length f-list)))
       (define ps
         (for/list ([f (in-list f-list)])
           (param (nix-fn-set-formal-name f) #f #f)))
       (fn-form ps #f #f
                (list (parse-expr (or (stx-ref subs 2) body-expr))))]
      [_ (parse-list-form* d subs)])))

;; `overlay` — bare form HARD-REJECTED; point at `nix/overlay`.
(register-combiner! 'overlay
  (lambda (d subs)
    (match d
      [(list 'overlay _ _)
       (raise-parse-error 'bare-nix-form
                          "(overlay ...) — bare `overlay` is not supported. Beagle namespaces target-specific forms; use `(nix/overlay [final prev] BODY)`."
                          #:suggestion (replace-head-suggestion 'overlay 'nix/overlay))]
      [_ (parse-list-form* d subs)])))

;; `nix/derivation` — mkDerivation sugar.
(register-combiner! 'nix/derivation
  (lambda (d subs)
    (match d
      [(list 'nix/derivation attrs-expr)
       ;; mkDerivation sugar: (nix/derivation {:pname ... :version ... :src ...})
       ;; Emits as `(pkgs.stdenv.mkDerivation { ... })`. Use `:builder pkg` to
       ;; override the default stdenv (e.g. :builder pkgs.runCommand).
       (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
       (nix-derivation attrs)]
      [_ (parse-list-form* d subs)])))

;; `derivation` — bare form HARD-REJECTED; point at `nix/derivation`.
(register-combiner! 'derivation
  (lambda (d subs)
    (match d
      [(list 'derivation _)
       (raise-parse-error 'bare-nix-form
                          "(derivation ...) — bare `derivation` is not supported. Beagle namespaces target-specific forms; use `(nix/derivation ATTRS)`."
                          #:suggestion (replace-head-suggestion 'derivation 'nix/derivation))]
      [_ (parse-list-form* d subs)])))

;; `nix/flake` — flake.nix sugar.
(register-combiner! 'nix/flake
  (lambda (d subs)
    (match d
      [(list 'nix/flake attrs-expr)
       ;; flake.nix sugar: (nix/flake {:description ... :inputs {...} :outputs (nix/fn-set [self nixpkgs] ...)})
       (define attrs (parse-expr (or (stx-ref subs 1) attrs-expr)))
       (nix-flake attrs)]
      [_ (parse-list-form* d subs)])))

;; `flake` — bare form HARD-REJECTED; point at `nix/flake`.
(register-combiner! 'flake
  (lambda (d subs)
    (match d
      [(list 'flake _)
       (raise-parse-error 'bare-nix-form
                          "(flake ...) — bare `flake` is not supported. Beagle namespaces target-specific forms; use `(nix/flake ATTRS)`."
                          #:suggestion (replace-head-suggestion 'flake 'nix/flake))]
      [_ (parse-list-form* d subs)])))

;; `nix/with` — canonical Nix scope form.
(register-combiner! 'nix/with
  (lambda (d subs)
    (match d
      [(list 'nix/with ns-expr body-expr)
       ;; Canonical Nix scope form. Unambiguous (no record-update shape collision).
       ;; Bare `(with ns body)` Nix-scope shape is HARD-REJECTED — see the
       ;; bare-`with` arm below.
       (nix-with (parse-expr (or (stx-ref subs 1) ns-expr))
                 (parse-expr (or (stx-ref subs 2) body-expr)))]
      [_ (parse-list-form* d subs)])))

;; `with` — record update (with-form) STAYS bare; Nix-scope shape HARD-REJECTED.
(register-combiner! 'with
  (lambda (d subs)
    (match d
      [(list 'with target-expr updates ...)
       ;; (with target [:k v] [:k v] ...) — record update (with-form). STAYS bare;
       ;;   not a Clojure collision.
       ;; (with ns body) — Nix scope shape. HARD-REJECTED — point at `nix/with`.
       ;; Disambiguate by shape: the record-update form has every update as a
       ;; [:keyword value ...] bracket; anything else is the (removed) Nix-scope
       ;; shape and gets the migration pointer.
       (cond
         [(and (= (length updates) 1)
               (let ([d (->datum (car updates))])
                 (not (and (bracketed? d)
                           (>= (length (bracket-body d)) 2)
                           (let ([first (car (bracket-body d))])
                             (and (symbol? first) (keyword-sym? first)))))))
          ;; Bare `(with ns body)` Nix-scope shape — hard reject.
          (raise-parse-error 'bare-nix-form
                             "(with NS BODY) — bare Nix-scope `with` is not supported. Beagle namespaces target-specific forms; use `(nix/with NS BODY)`.")]
         [else
          (parse-with-form (or (stx-ref subs 1) target-expr)
                           (or (stx-tail subs 2) updates))])]
      [_ (parse-list-form* d subs)])))

;; `nix-ident` — removed form; pointed rejection at flake-input.
(register-combiner! 'nix-ident
  (lambda (d subs)
    (match d
      [(list 'nix-ident _ ...)
       (raise-parse-error 'removed-form
                          "nix-ident removed — use (flake-input :NAME :NAMESPACE :path ...) for flake-input access. nix-ident was an undocumented escape hatch that bypassed the type system.")]
      [_ (parse-list-form* d subs)])))

;; --- js family migrated to the compile-time combiner registry ---
;; NOTE: `js/await` was already registered by the control family; skipped here.

;; `js/quote` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/quote
  (lambda (d subs)
    (match d
      [(cons 'js/quote body)
       (js-quote-form (parse-js-ast-body (or (stx-tail subs 1) body)))]
      [_ (parse-list-form* d subs)])))

;; `js/return` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/return
  (lambda (d subs)
    (match d
      [(list 'js/return)
       (jst-return #f)]
      [(list 'js/return expr-form)
       (jst-return (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/class` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/class
  (lambda (d subs)
    (match d
      [(list* 'js/class name-form rest)
       (parse-jst-class name-form rest)]
      [_ (parse-list-form* d subs)])))

;; `js/template` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/template
  (lambda (d subs)
    (match d
      [(cons 'js/template parts)
       (jst-template (map (lambda (p)
                            (define v (->datum p))
                            (if (string? v) v (parse-expr p)))
                          (cdr d)))]
      [_ (parse-list-form* d subs)])))

;; `js/spread` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/spread
  (lambda (d subs)
    (match d
      [(list 'js/spread expr-form)
       (jst-spread (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/typeof` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/typeof
  (lambda (d subs)
    (match d
      [(list 'js/typeof expr-form)
       (jst-typeof (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

(register-combiner! 'js/get
  (lambda (d subs)
    (match d
      [(list 'js/get receiver key)
       (jst-get (parse-expr (or (stx-ref subs 1) receiver))
                (parse-jst-member-key (or (stx-ref subs 2) key)))]
      [_ (raise-parse-error 'bad-form
                            "js/get expects exactly a receiver and member key")])))

(register-combiner! 'js/call
  (lambda (d subs)
    (match d
      [(list* 'js/call receiver key args)
       (jst-call (parse-expr (or (stx-ref subs 1) receiver))
                 (parse-jst-member-key (or (stx-ref subs 2) key))
                 (map parse-expr (or (stx-tail subs 3) args)))]
      [_ (raise-parse-error 'bad-form
                            "js/call expects a receiver, member key, and optional arguments")])))

(register-combiner! 'js/set!
  (lambda (d subs)
    (match d
      [(list 'js/set! receiver key value)
       (jst-set (parse-expr (or (stx-ref subs 1) receiver))
                (parse-jst-member-key (or (stx-ref subs 2) key))
                (parse-expr (or (stx-ref subs 3) value)))]
      [_ (raise-parse-error 'bad-form
                            "js/set! expects exactly a receiver, member key, and value")])))

(register-combiner! 'js/new
  (lambda (d subs)
    (match d
      [(list* 'js/new callee args)
       (jst-new (parse-expr (or (stx-ref subs 1) callee))
                (map parse-expr (or (stx-tail subs 2) args)))]
      [_ (raise-parse-error 'bad-form
                            "js/new expects a constructor and optional arguments")])))

(register-combiner! 'js/delete!
  (lambda (d subs)
    (match d
      [(list 'js/delete! receiver key)
       (jst-delete (parse-expr (or (stx-ref subs 1) receiver))
                   (parse-jst-member-key (or (stx-ref subs 2) key)))]
      [_ (raise-parse-error 'bad-form
                            "js/delete! expects exactly a receiver and member key")])))

(register-combiner! 'js/in?
  (lambda (d subs)
    (match d
      [(list 'js/in? receiver key)
       (jst-in (parse-expr (or (stx-ref subs 1) receiver))
               (parse-jst-member-key (or (stx-ref subs 2) key)))]
      [_ (raise-parse-error 'bad-form
                            "js/in? expects exactly a receiver and member key")])))

;; `js/import-meta` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/import-meta
  (lambda (d subs)
    (match d
      [(list 'js/import-meta)
       (jst-import-meta)]
      [_ (parse-list-form* d subs)])))

;; `js/export` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/export
  (lambda (d subs)
    (match d
      [(list 'js/export inner-form)
       (define inner (parse-expr (or (stx-ref subs 1) inner-form)))
       (cond
         [(jst-class? inner) (struct-copy jst-class inner [export? #t])]
         [else (jst-export inner)])]
      [_ (parse-list-form* d subs)])))

;; `js/export-default` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/export-default
  (lambda (d subs)
    (match d
      [(list 'js/export-default inner-form)
       (jst-export-default (parse-expr (or (stx-ref subs 1) inner-form)))]
      [_ (parse-list-form* d subs)])))

;; `js/!` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/!
  (lambda (d subs)
    (match d
      [(list 'js/! expr-form)
       (jst-unary '! (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/void` migrated to the compile-time combiner registry (see register-combiner!).
(register-combiner! 'js/void
  (lambda (d subs)
    (match d
      [(list 'js/void expr-form)
       (jst-unary 'void (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

;; `js/-` and `js/+` share one arm (see register-combiner!): both register to this
;; handler, which keeps the (or 'js/- 'js/+) pattern. The shared arm is deleted once.
(register-combiner! 'js/-
  (lambda (d subs)
    (match d
      [(list (and op (or 'js/- 'js/+)) expr-form)
       (define js-op (if (eq? op 'js/-) '- '+))
       (jst-unary js-op (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))
(register-combiner! 'js/+
  (lambda (d subs)
    (match d
      [(list (and op (or 'js/- 'js/+)) expr-form)
       (define js-op (if (eq? op 'js/-) '- '+))
       (jst-unary js-op (parse-expr expr-form))]
      [_ (parse-list-form* d subs)])))

(define (parse-list-form d subs)
  ;; Invariant: macro heads are resolved in parse-expr (and the top-level loop)
  ;; BEFORE control reaches here, so a 'macro head must never arrive — if one
  ;; does, the resolver and the call sites have drifted out of sync. Fail loudly
  ;; rather than silently mis-dispatching to a built-in/legacy arm. On valid
  ;; input this arm never fires, so goldens are unaffected.
  (when (and (pair? d)
             (eq? (head-meaning (current-registry) (car d)) 'macro))
    (error 'beagle
           "internal: macro head ~a reached parse-list-form (should be handled in parse-expr)"
           (car d)))
  (cond
    [(and (pair? d) (symbol? (car d)) (lookup-combiner (car d)))
     => (lambda (handler) (handler d subs))]
    [else (parse-list-form* d subs)]))

(define (parse-list-form* d subs)
  (match d
    ;; `unsafe` family (unsafe/-js/-clj/-py/-rkt/-nix/-expr) migrated to the
    ;; compile-time combiner registry (see register-combiner!).

    ;; `def` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defonce` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defn` / `defn-` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `claim` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defrecord` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defprotocol` migrated to the compile-time combiner registry (see register-combiner!).

    ;; defmulti / defmethod removed — multimethods had ~zero usage in the
    ;; corpus (one fixture file). Use defprotocol + extend-type for
    ;; type-based dispatch instead.

    ;; deftype removed — bundled defrecord + protocol-impls into a single
    ;; form, but the decomposition is the canonical idiom. defrecord defines
    ;; the data shape; extend-type attaches protocol impls. Two distinct
    ;; concepts, two distinct forms.

    ;; `extend-type` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `flake-input` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `fn` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `let` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `letfn` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `loop` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `recur` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `js/await` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `await` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; --- Nix-specific forms --------------------------------------------------

    ;; `inherit` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `inherit-from` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `rec-attrs` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/assert` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `assert` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/with-cfg` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `with-cfg` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `get-or` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `has` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `search-path` migrated to the compile-time combiner registry (see register-combiner!).

    [(cons 's parts)
     (nix-interpolated-string
      (map (lambda (part)
             (define d (->datum part))
             (if (string? d) d (parse-expr part)))
           (or (stx-tail subs 1) (cdr d))))]

    ;; `ms` migrated to the compile-time combiner registry (see register-combiner!).

    [(list '#%block-string tag text)
     (block-string (->datum (or (stx-ref subs 2) text))
                   (->datum (or (stx-ref subs 1) tag)))]


    [(list 'p path-str)
     (define d (->datum (or (stx-ref subs 1) path-str)))
     (nix-path (cond
                 [(string? d) d]
                 [(symbol? d) (symbol->string d)]
                 [else (error 'beagle "p: expected string or symbol, got ~v" d)]))]

    ;; `nix/fn-set` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `fn-set` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/module` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `module` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/overlay` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `overlay` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/derivation` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `derivation` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; `nix/flake` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `flake` (bare) migrated to the compile-time combiner registry (see register-combiner!).

    ;; --- end Nix-specific forms ----------------------------------------------

    ;; --- JS-specific forms (js/*) ---------------------------------------------
    ;; js/quote, js/return, js/class, js/template, js/spread, js/typeof,
    ;; js/import-meta, js/export, js/export-default, js/!, js/void, js/-, js/+
    ;; migrated to the compile-time combiner registry (see register-combiner!).
    ;; The predicate-headed jst-binary-op arm below stays (no literal head).

    [(list (? jst-binary-op? op) left-form right-form)
     (jst-binary (hash-ref JST-BINARY-OPS op) (parse-expr left-form) (parse-expr right-form))]

    ;; --- end Typed JS target forms --------------------------------------------

    ;; --- end JS-specific forms ------------------------------------------------

    ;; `set!` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `for` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `if` migrated to the compile-time combiner registry (see register-combiner!).

    ;; when / when-not / if-not / unless — accept-and-canonicalize.
    ;; These Clojure conditional macros lower 1:1 to (if …) / (if … (do …)).
    ;; Lowering rules live at the dispatch site below; see the comment block
    ;; near the "Clojure conditional sugar" case. Identity-preserving: the
    ;; AST and emitted code are byte-equivalent to the hand-written canonical
    ;; form.

    ;; when-let / if-let / when-some / if-some — all four accepted and
    ;; canonicalized via lower-binding-cond (see the dispatch arms below).
    ;; They are real Clojure; the -some variants test (not (nil? x)) rather
    ;; than truthiness, exactly as in Clojure.

    ;; `with-open` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `doto` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `comment` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `do` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `cond` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `condp` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `try` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `check` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `rescue` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `target-case` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `doseq` migrated to the compile-time combiner registry (see register-combiner!).

    ;; dotimes removed — sugar for (doseq [i (range n)] body...).
    ;; No broader pattern reinforced; composition is transparent.

    ;; `nix/with` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `with` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defenum` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defunion` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `deferror` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `defscalar` migrated to the compile-time combiner registry (see register-combiner!).

    ;; `match` migrated to the compile-time combiner registry (see register-combiner!).

    ;; case removed — folded into match + or-pattern. The case-fold
    ;; optimization in emit-clj.rkt and emit-rkt.rkt lowers literal-only
    ;; or-patterns to target-native (case ...) for O(1) dispatch, so the
    ;; migration ships no perf regression.
    ;;
    ;; Migration:
    ;;   (case x 1 "one" 2 "two" :else "other")
    ;;   →
    ;;   (match x [(or 1) "one"] [(or 2) "two"] [_ "other"])
    ;; or more compactly:
    ;;   (match x [1 "one"] [2 "two"] [_ "other"])

    [(list (? constructor-sym? c) args ...)
     (new-form c (map parse-expr (or (stx-tail subs 1) args)))]

    ;; (:keyword target) — Clojure keyword-as-fn projection, re-adopted as
    ;; the typed field-projection surface. The checker resolves to the
    ;; declared field type when target has a known record type (via
    ;; lookup-kw-field-type / RECORD-FIELDS); falls back to Any otherwise.
    ;; emit-nix lowers to `target.field` (unquoted attrset access). For a
    ;; default-on-miss, use `(get m :k default)` — the primitive form.
    [(list (? keyword-sym? kw) target)
     (kw-access kw (parse-expr (or (stx-ref subs 1) target)) #f)]

    [(list (? dot-method-sym? m) target args ...)
     (method-call m (parse-expr (or (stx-ref subs 1) target))
                    (map parse-expr (or (stx-tail subs 2) args)))]

    ;; `fmt` migrated to the compile-time combiner registry (see register-combiner!).

    ;; Clojure threading family — all parse-time rewrites to ordinary
    ;; composition. `->` and `->>` are the canonical replacements for the
    ;; (removed) pipe family. The conditional/binding/short-circuit
    ;; threaders lower to let-chains and (if …) nodes.
    ;;
    ;; Each arm wraps its desugared output with `threading-marker` so the
    ;; clj emitter can reconstruct the surface form. The marker is
    ;; transparent to check.rkt and emit-nix.rkt (both walk the desugared
    ;; field). orig-args is the parsed list of surface arg AST nodes —
    ;; for `->` / `->>` / `some->` / `some->>` it's (init steps...); for
    ;; `as->` it's (init name steps...); for `cond-> / cond->>` it's the
    ;; (init test1 step1 test2 step2 …) sequence.
    [(list '-> init steps ...)
     (define orig-stxs (or (and subs (stx-tail subs 1))
                           (cons init steps)))
     (threading-marker
      '->
      (map parse-thread-surface-expr orig-stxs)
      (parse-expr (rewrite-as
                   (expand-thread-first (or (stx-ref subs 1) init)
                                        (or (and subs (stx-tail subs 2)) steps)))))]
    [(list '->> init steps ...)
     (define orig-stxs (or (and subs (stx-tail subs 1))
                           (cons init steps)))
     (threading-marker
      '->>
      (map parse-thread-surface-expr orig-stxs)
      (parse-expr (rewrite-as
                   (expand-thread-last (or (stx-ref subs 1) init)
                                       (or (and subs (stx-tail subs 2)) steps)))))]
    ;; `as->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `cond->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `cond->>` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `some->` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `some->>` migrated to the compile-time combiner registry (see register-combiner!).
    ;; Clojure conditional sugar — accept-and-canonicalize to (if …) / (if … (do …)).
    ;; Identity-preserving: same emitted code as the hand-written canonical
    ;; form. The lowerings mirror lower-binding-cond's shape — multi-body
    ;; bodies are always wrapped in (do …); single-body wrap is emit-equal
    ;; to bare-body because emit-body of a single expr is just the expr.
    ;;
    ;;   (when c body…)      → (if c (do body…))
    ;;   (when-not c body…)  → (if (not c) (do body…))
    ;;   (if-not c t e)      → (if c e t)
    ;;
    ;; (`unless` was removed 2026-06-12 — not Clojure; when-not is the
    ;; canonical spelling and the rejection arm points at it.)
    ;;
    ;; Like if-let/when-let, the surface sugar is welcome; the canonical AST
    ;; is what every downstream pass sees.
    ;; `when` / `when-not` / `if-not` migrated to the compile-time combiner
    ;; registry (see register-combiner!), success + arity-reject arms both.
    ;; `unless` is NOT Clojure (it's CL/Scheme/Ruby) — zero corpus hits,
    ;; removed 2026-06-12 per the zero-users rule. `when-not` is the
    ;; Clojure spelling.
    [(list 'unless _ ...)
     (raise-parse-error 'removed-form
                        "(unless c body...) — `unless` is not a Clojure form. Use `(when-not c body...)`.")]
    ;; `when` / `when-not` / `if-not` arity-reject arms migrated to the
    ;; compile-time combiner registry (see register-combiner!).
    ;; Clojure binding-conditional macros: accept-and-canonicalize.
    ;; These are lowered to the canonical (let …) (if …) shape — the AST that
    ;; results is byte-identical to what a hand-written equivalent would
    ;; produce. The lowerings are identity-preserving:
    ;;
    ;;   (if-let    [x v] t e)    → (let [x v] (if x t e))
    ;;   (when-let  [x v] body…)  → (let [x v] (if x (do body…)))
    ;;   (if-some   [x v] t e)    → (let [x v] (if (not (nil? x)) t e))
    ;;   (when-some [x v] body…)  → (let [x v] (if (not (nil? x)) (do body…)))
    ;;
    ;; The eventual typed nullable-narrowing form (provisional name TBD,
    ;; tracked in design-principle.md) will not reuse these names — the
    ;; typed form should be beagle-native, not Clojure-shaped. Until then
    ;; the sugar is welcome.
    ;; `if-let` / `when-let` / `if-some` / `when-some` migrated to the
    ;; compile-time combiner registry (see register-combiner!).
    ;; `dotimes` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `defmulti` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `defmethod` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `deftype` migrated to the compile-time combiner registry (see register-combiner!).
    ;; `nix-ident` migrated to the compile-time combiner registry (see register-combiner!).
    ;; inc / dec / not= live in stdlib-portable.rkt — no parse-time
     ;; rejection. They flow through the ordinary call-form arm below.
    ;; `case` migrated to the compile-time combiner registry (see register-combiner!).
    ;; Arity errors for the (:keyword target) form. The valid shape is
    ;; (:k target) — exactly one positional argument. (:k) is meaningless
    ;; (no target); (:k a b ...) was the deprecated default-on-miss form,
    ;; now spelled (get m :k default).
    [(list (? keyword-sym? kw))
     (raise-parse-error 'bad-form
                        "(:keyword) requires a target: (:keyword target); got: ~v" (list kw))]
    [(list (? keyword-sym? kw) _ _ _ ...)
     (raise-parse-error 'bad-form
                        "(:keyword target) takes one target — for a default-on-miss, use (get m :key default); got: ~v" kw)]

    ;; Stray quasiquote/unquote/unquote-splicing outside a defmacro body.
    ;; The reader produces these from `` ` ``, `,`, `,@` prefixes. They are
    ;; macro-template syntax only — beagle has no general data-construction
    ;; backquote (yet). Inside a `(defmacro …)` body they are handled by
    ;; the compile-time evaluator, so they never reach parse-list-form.
    ;; If we see them here, the user wrote `,x` or `` `(…) `` outside a
    ;; defmacro body.
    ;; `unquote` / `unquote-splicing` / `quasiquote` migrated to the
    ;; compile-time combiner registry (see register-combiner!).

    ;; Literal-key (get target :kw) and (get target :kw default) canonicalize
    ;; to kw-access — same AST as (:kw target). Identity-preserving: same
    ;; emitted Nix as the call-form path used to produce. Dynamic-key form
    ;; (where the key is a binding, not a literal keyword) stays call-form
    ;; via the catch-all below — emit-nix lowers that to `target.${expr}`.
    ;; `get` (literal-key) migrated to the compile-time combiner registry (see register-combiner!).
    ;; Dynamic-key (get target expr) falls through to the call-form arm below, as before.

    ;; `new` is a host special form, not Beagle's constructor surface. Letting
    ;; it fall through as a call emits `new$(...)` on JS and defers the mistake
    ;; to a runtime ReferenceError. Constructors use Clojure's `Class.` head.
    [(list 'new _ ...)
     (raise-parse-error 'bare-constructor-form
       "(`new` ...) is not a Beagle constructor call. Use `(X. args...)`, for example `(Set. xs)`."
       #:suggestion "(X. args...)")]

    ;; `%` is the anonymous-fn argument shorthand, only meaningful inside #(...).
    ;; The reader rewrites `%` -> `%1` inside #(), so a bare `%` at parse time can
    ;; only appear OUTSIDE a lambda — always an error, most often `%` written as
    ;; modulo, which silently emitted a call to undefined `_pct`. Reject loudly.
    [(list '% args ...)
     (raise-parse-error 'percent-not-modulo
       "`%` is the anonymous-function argument shorthand (only valid inside #(...)) and cannot be a function or call head. For modulo use `rem` (truncate toward zero) or `mod` (floored toward negative infinity)."
       #:suggestion "(rem a b) or (mod a b)")]

    [(list (? symbol? f) args ...)
     (validate-identifier! f "call target")
     (define head-syntax (stx-ref subs 0))
     (define ref (lower-reference f head-syntax))
     (define parsed-args (map parse-expr (or (stx-tail subs 1) args)))
     (if (and (qualified-ref? ref) (static-method-ref? ref))
         (static-call ref parsed-args)
         (call-form ref parsed-args))]

    ;; Higher-order call: function position is an expression, not a
    ;; bare symbol. Common in Nix where `(get target :attr)` returns
    ;; a function that's then applied: `((get foo :bar) arg)`.
    [(cons (? pair? fn-form) args)
     (call-form (parse-expr (or (stx-ref subs 0) fn-form))
                (map parse-expr (or (stx-tail subs 1) args)))]

    [_ (error 'beagle "unsupported form: ~v" d)]))

(define (parse-protocol-method sig)
  (define d (->datum sig))
  (match d
    [(list (? symbol? name) params-form return-type)
     (validate-identifier! name "protocol method")
     (let-values ([(parsed rest-p)
                   (parse-params (or (stx-ref (stx-subs sig) 1)
                                     params-form))])
       (protocol-method name parsed rest-p (parse-type return-type)))]
    [_ (error 'beagle "defprotocol method signature must be (name [params] ReturnType), got: ~v" d)]))

(define (parse-with-form target-stx updates)
  (define target (parse-expr target-stx))
  (define parsed-updates
    (for/list ([u (in-list updates)])
      (define d (->datum u))
      (define u-subs (stx-subs u))
      (cond
        [(and (bracketed? d) (>= (length (bracket-body d)) 2))
         (define items (or (stx-tail u-subs 1) (bracket-body d)))
         (define kw (->datum (car items)))
         (unless (keyword-sym? kw)
           (error 'beagle "with: field name must be a keyword, got: ~v" kw))
         (with-update kw (parse-expr (or (and u-subs (cadr items)) (cadr items))))]
        [else
         (error 'beagle "with: each update must be [:field value], got: ~v" d)])))
  (with-form target parsed-updates))

(define (parse-body forms)
  (when (null? forms)
    (error 'beagle "expected at least one body expression"))
  (define parsed (map parse-expr forms))
  ;; Record per-position srcloc of each surface form into a side-table
  ;; keyed by the result list's identity. The result list is fresh
  ;; (returned from map), so its eq?-identity is unique even when the
  ;; AST nodes are interned (e.g. bare symbols). Lets diagnostics that
  ;; fire on a specific body position (e.g. defn return-type uses the
  ;; last body expr) recover positional srcloc via body-loc-at when
  ;; src-for returns #f for the AST node itself.
  (define tbl (current-body-locs-table))
  (when tbl
    (define locs
      (for/list ([f (in-list forms)])
        (and (syntax? f) (stx->src-loc f))))
    (hash-set! tbl parsed locs))
  parsed)

(define (parse-map-literal items)
  ;; Items are normally key/value pairs (even count). To support Nix-style
  ;; `inherit` and `inherit-from` bindings inside an attrset literal, a
  ;; singleton `(inherit ...)` or `(inherit-from src ...)` item counts as
  ;; ONE entry (the parsed inherit expression becomes the key with a
  ;; sentinel value, picked up by emit-nix). The arity check happens after
  ;; classifying.
  (let loop ([rest items] [acc '()])
    (cond
      [(null? rest) (map-form (reverse acc))]
      [(let ([first-datum (->datum (car rest))])
         (and (pair? first-datum)
              (memq (car first-datum) '(inherit inherit-from))))
       ;; Singleton inherit binding; key is the parsed form, value is #f
       ;; (sentinel that emit-nix recognizes for inherit-style emission).
       (loop (cdr rest)
             (cons (cons (parse-expr (car rest)) #f) acc))]
      [(null? (cdr rest))
       (error 'beagle
              "map literal: odd number of forms (expected key/value pair after position ~a)"
              (length acc))]
      [else
       (loop (cddr rest)
             (cons (cons (parse-expr (car rest)) (parse-expr (cadr rest)))
                   acc))])))

;; A cond clause test of `:else` (Clojure idiom) or bare `else` is the
;; "always true" fallthrough. Canonicalize both to the symbol `'else` so
;; downstream emit machinery (e.g. emit-nix's emit-cond) sees one shape.
(define (else-marker-datum? d)
  (or (eq? d ':else) (eq? d 'else)))

(define (parse-cond-test test-stx test-datum)
  (cond
    [(else-marker-datum? test-datum) 'else]
    [else (parse-expr (or test-stx test-datum))]))

(define (parse-cond-clause c)
  (define d (->datum c))
  (define c-subs (stx-subs c))
  (cond
    [(bracketed? d)
     (define items (or (stx-tail c-subs 1) (bracket-body d)))
     (when (null? items) (error 'beagle "cond clause is empty"))
     (define test-datum (->datum (car items)))
     (cond-clause (parse-cond-test (car items) test-datum)
                  (parse-body (cdr items)))]
    [(and (pair? d) (pair? (cdr d)))
     (cond-clause (parse-cond-test #f (car d)) (parse-body (cdr d)))]
    [else (error 'beagle "cond clause must be a [test body ...] form, got: ~v" d)]))

(define (grouped-clause? d)
  (and (pair? d)
       (or (pair? (car d))
           (eq? (car d) 'else))))

;; Bracketed/grouped clauses ([t r] or wrapped (case t r)) and flat-pair
;; clauses ((cond t1 r1 t2 r2)) are both valid surface shapes — but
;; mixing them in one cond is ambiguous and almost always a typo. Detect
;; mixed shapes and raise rather than silently misparse.
(define (cond-clause-shape d)
  (cond
    [(bracketed? d)      'bracketed]
    [(grouped-clause? d) 'bracketed] ; (case t r) / (else r) — same shape family
    [else                'flat]))

(define (parse-cond-clauses clauses)
  (cond
    [(null? clauses) '()]
    [else
     (define first-shape (cond-clause-shape (->datum (car clauses))))
     (case first-shape
       [(bracketed)
        ;; Require ALL clauses to be bracketed/grouped — refuse mixed form.
        (for ([c (in-list (cdr clauses))]
              [i (in-naturals 1)])
          (define cd (->datum c))
          (unless (eq? (cond-clause-shape cd) 'bracketed)
            (error 'beagle
                   "cond clauses must be all bracketed or all flat pairs (mixed forms not allowed); clause ~a is flat: ~v"
                   i cd)))
        (map parse-cond-clause clauses)]
       [(flat)
        (unless (even? (length clauses))
          (error 'beagle
                 "cond with unbracketed clauses must have an even number of forms (test/body pairs)"))
        (let loop ([rest clauses] [acc '()])
          (cond
            [(null? rest) (reverse acc)]
            [else
             (define test-stx (car rest))
             (define test-datum (->datum test-stx))
             (loop (cddr rest)
                   (cons (cond-clause (parse-cond-test test-stx test-datum)
                                      (list (parse-expr (cadr rest))))
                         acc))]))])]))

;; --- Nix-specific parse helpers --------------------------------------------

(define (parse-nix-rec-pairs pairs)
  (let loop ([rest pairs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(< (length rest) 2)
       (error 'beagle "rec-att: expected key value pairs, got odd number of forms")]
      [else
       (define key (->datum (car rest)))
       (define val (parse-expr (cadr rest)))
       (loop (cddr rest)
             (cons (cons (if (symbol? key) key (error 'beagle "rec-att: key must be symbol, got ~v" key))
                         val)
                   acc))])))

(define (parse-nix-fn-set-formals formals-stx)
  ;; Returns (values formals at-name) where at-name is #f or a symbol
  ;; bound to the full formal-args attrset via Nix's `{ ... } @ name:`
  ;; capture (surface syntax: `:as name` at end of formals list).
  ;; This binding aliases ALL named formals plus whatever the rest-marker
  ;; (`...`) extends to, so the scope-tracker (when it lands) should
  ;; treat it as a single source of truth for "name X covers all-of-args."
  (define d (->datum formals-stx))
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(list? d) d]
      [else (error 'beagle "fn-set: expected list of formals, got ~v" d)]))
  (define-values (before-as at-name)
    (let loop ([rest items] [acc '()])
      (cond
        [(null? rest) (values (reverse acc) #f)]
        [(eq? (->datum (car rest)) ':as)
         (when (null? (cdr rest))
           (error 'beagle "fn-set/module: :as requires a name"))
         (define n (->datum (cadr rest)))
         (unless (symbol? n)
           (error 'beagle "fn-set/module: :as expects a symbol, got ~v" n))
         (unless (null? (cddr rest))
           (error 'beagle "fn-set/module: :as name must come last in formals"))
         (values (reverse acc) n)]
        [else (loop (cdr rest) (cons (car rest) acc))])))
  (define formals
    (for/list ([item (in-list before-as)]
               #:unless (eq? (->datum item) '...))
      (define id (->datum item))
      (cond
        [(symbol? id) (nix-fn-set-formal id #f)]
        [(and (list? id) (= (length id) 2))
         (nix-fn-set-formal (car id) (parse-expr (datum->syntax #f (cadr id))))]
        [(and (bracketed? id) (= (length (bracket-body id)) 2))
         (define body (bracket-body id))
         (nix-fn-set-formal (car body) (parse-expr (datum->syntax #f (cadr body))))]
        [else (error 'beagle "fn-set formal: expected name or (name default), got ~v" id)])))
  (values formals at-name))

;; --- try/catch/finally -----------------------------------------------------

(define (parse-try-form rest)
  (define-values (body-forms catch-forms finally-form)
    (let loop ([items rest] [body '()])
      (define first-d (and (pair? items) (->datum (car items))))
      (cond
        [(null? items)
         (values (reverse body) '() #f)]
        [(and (pair? first-d) (eq? (car first-d) 'catch))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [(and (pair? first-d) (eq? (car first-d) 'finally))
         (define-values (catches fin) (parse-catch-finally items))
         (values (reverse body) catches fin)]
        [else
         (loop (cdr items) (cons (car items) body))])))
  (when (null? body-forms)
    (error 'beagle "try requires at least one body expression"))
  (try-form (map parse-expr body-forms)
            catch-forms
            finally-form))

(define (parse-catch-finally items)
  (let loop ([rest items] [catches '()] [fin #f])
    (define first-d (and (pair? rest) (->datum (car rest))))
    (cond
      [(null? rest) (values (reverse catches) fin)]
      [(and (pair? first-d) (eq? (car first-d) 'catch))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 3)
         (error 'beagle "catch clause needs (catch (name ExType) body...)"))
       (define binding (cadr clause-d))
       (unless (and (structured-binding? binding)
                    (= (length binding) 2)
                    (symbol? (car binding)))
         (raise-parse-error
          'inline-type-annotation
          "catch binding must be `(name ExType)`, got: ~v"
          binding))
       (define name (car binding))
       (define ex-type (cadr binding))
       (parse-type ex-type)
       (define body (or (stx-tail clause-subs 2) (cddr clause-d)))
       (define parsed-catch
         (catch-clause ex-type name (map parse-expr body)))
       (register-syntax-binder!
        parsed-catch
        (stx-ref clause-subs 1))
       (loop (cdr rest)
             (cons parsed-catch catches)
             fin)]
      [(and (pair? first-d) (eq? (car first-d) 'finally))
       (define clause-d first-d)
       (define clause-subs (stx-subs (car rest)))
       (when (< (length clause-d) 2)
         (error 'beagle "finally clause needs at least one body expression"))
       (define body (or (stx-tail clause-subs 1) (cdr clause-d)))
       (loop (cdr rest) catches (map parse-expr body))]
      [else (error 'beagle "unexpected form after catch/finally: ~v" first-d)])))

;; (parse-case-form / parse-case-pairs removed 2026-06-12 — dead since the
;; `case` form was folded into `match`. The case-form AST node remains for
;; the match case-fold optimization in emit.)


;; --- match -----------------------------------------------------------------

(define (parse-match-form target clauses)
  (when (null? clauses)
    (error 'beagle "match requires at least one clause"))
  (match-form (parse-expr target)
              (map parse-match-clause clauses)))

(define (parse-match-clause c)
  (define d (->datum c))
  (define clause-subs (stx-subs c))
  (define items
    (cond
      [(bracketed? d) (bracket-body d)]
      [(and (pair? d) (pair? (cdr d))) d]
      [else (error 'beagle "match clause must be [pattern body...], got: ~v" d)]))
  (define item-stxs
    (and clause-subs
         (if (bracketed? d) (cdr clause-subs) clause-subs)))
  (when (< (length items) 2)
    (error 'beagle "match clause needs a pattern and at least one body expression"))
  (define pattern-source (or (and item-stxs (car item-stxs)) (car items)))
  (define parsed-pattern (parse-pattern pattern-source))
  (register-syntax-binder! parsed-pattern pattern-source)
  (define parsed-clause
    (match-clause
     parsed-pattern
     (map parse-expr (or (and item-stxs (cdr item-stxs)) (cdr items)))))
  (register-syntax-binder! parsed-clause pattern-source))

(define (record-pattern-name? value)
  (define name
    (cond
      [(qualified-ref? value) (qualified-ref-name value)]
      [(symbol? value) value]
      [else #f]))
  (and name
       (let ([spelling (symbol->string name)])
         (and (positive? (string-length spelling))
              (char-upper-case? (string-ref spelling 0))))))

(define (parse-pattern p)
  (define d (if (syntax? p) (syntax->datum p) p))
  (define record-head
    (and (pair? d)
         (symbol? (car d))
         (or (lower-qualified-reference (car d)) (car d))))
  (cond
    [(eq? d '_)         (pat-wildcard)]
    [(eq? d 'nil)       (pat-literal 'nil)]
    [(string? d)        (pat-literal d)]
    [(boolean? d)       (pat-literal d)]
    [(exact-integer? d) (pat-literal d)]
    [(real? d)          (pat-literal d)]
    [(keyword-sym? d)   (pat-literal d)]
    [(and (pair? d) (eq? (car d) MAP-TAG))
     (parse-map-pattern (cdr d))]
    ;; Pattern combinators. or-pattern: (or pat1 pat2 ...) matches if
    ;; any alternative matches. Designed as a combinator so future
    ;; operators (and, not, guards) slot in as sibling parse cases.
    [(and (pair? d) (eq? (car d) 'or))
     (when (null? (cdr d))
       (error 'beagle "or-pattern requires at least one alternative"))
     (pat-or (map parse-pattern (cdr d)))]
    [(and record-head (record-pattern-name? record-head))
     (pat-record record-head (cdr d))]
    [(symbol? d)        (pat-var d)]
    [else (error 'beagle "unsupported match pattern: ~v" d)]))

(define (parse-map-pattern entries)
  (unless (even? (length entries))
    (error 'beagle "map pattern must have even entries (key/pattern pairs)"))
  (let loop ([rest entries] [acc '()])
    (cond
      [(null? rest) (pat-map (reverse acc))]
      [else
       (define k (car rest))
       (unless (keyword-sym? k)
         (error 'beagle "map pattern key must be a keyword, got: ~v" k))
       (loop (cddr rest)
             (cons (cons k (parse-pattern (cadr rest))) acc))])))

;; --- params + bindings -----------------------------------------------------

(define (binding-style items)
  (cond
    [(null? items) #f]
    [(structured-binding? (car items)) 'legacy]
    [(and (pair? (cdr items))
          (type-expression-datum? (cadr items)))
     'flat]
    [else 'inferred]))

(define (flat-structured-binder items)
  (for/first ([item (in-list items)] [index (in-naturals)]
              #:when (and (even? index) (structured-binding? item)))
    item))

(define (raise-mixed-bindings context datum [source-stx #f])
  (raise-parse-error
   'mixed-typed-bindings
   "~a vector mixes legacy grouped declarations with flat binding/type pairs; use strict pairs all the way through"
   context
   #:details (source-error-details source-stx datum)))

(define (raise-missing-binding-type context binder [source-stx #f] #:hint [hint ""])
  (raise-parse-error
   'missing-binding-type
   (string-append "~a ~a has no following type" hint)
   context (binding-datum->src binder)
   #:details
   (hash-set (source-error-details source-stx binder)
             'binder (binding-datum->src binder))))

(define (raise-missing-binding-initializer context binder [source-stx #f])
  (raise-parse-error
   'bad-form
   "~a ~a has no following initializer"
   context (binding-datum->src binder)
   #:details
   (hash-set (source-error-details source-stx binder)
             'binder (binding-datum->src binder))))

;; Repair hints feed the automated repair loop, so every declaration-site
;; rejection spells the grammar it wants back. Record fields are pairs
;; (rule 4c) and a field-local validator is a refinement type (rule 3).
(define RECORD-FIELD-GRAMMAR-HINT
  (string-append "\n\n"
                 "Each field is one binding/type pair:\n"
                 "  name Type\n"
                 "  name (Type where validator)"))

;; A field declaration is complete only when its type slot really parses as a
;; type. `(wire-validator id)` has the shape of a grouped declaration but no
;; meaningful type, so in the slot after a complete field it is metadata that
;; was flattened out of the declaration it belongs to.
(define (complete-record-field-declaration? datum)
  (and (structured-binding? datum)
       (symbol? (car datum))
       (type-expression-datum? (cadr datum))))

(define (raise-flattened-record-field declaration stray stray-stx)
  (raise-parse-error
   'inline-type-annotation
   (string-append
    "Invalid field declaration: ~a"
    RECORD-FIELD-GRAMMAR-HINT
    "\n\n"
    "Did you mean:\n"
    "  ~a (~a where ~a)")
   #:details (source-error-details stray-stx stray)
   (binding-datum->src stray)
   (binding-datum->src (car declaration))
   (binding-datum->src (cadr declaration))
   (binding-datum->src stray)))

;; Executable signatures retain wholly inferred vectors. Typed vectors
;; dual-read the legacy grouped declaration and the new flat pair grammar. A
;; vector chooses one style at its first declaration and stays in that style
;; through the rest parameter.
(define (parse-params p)
  (define d (->datum p))
  (define items (bracket-items p "parameter list"))
  (define item-stxs (bracket-stxs (stx-subs p) d))
  (when (> (count (lambda (item) (eq? item '&)) items) 1)
    (raise-parse-error 'bad-form "parameter list may contain only one & marker"))
  (define amp-pos (index-of items '&))
  (define before-amp (if amp-pos (take items amp-pos) items))
  (define after-amp (and amp-pos (drop items (add1 amp-pos))))
  (when (and amp-pos (null? after-amp))
    (error 'beagle "& must be followed by a rest parameter"))
  (define before-amp-stxs
    (and item-stxs (if amp-pos (take item-stxs amp-pos) item-stxs)))
  (define after-amp-stxs
    (and item-stxs amp-pos (drop item-stxs (add1 amp-pos))))
  (define fixed-style (binding-style before-amp))
  (define rest-style (and after-amp (pair? after-amp) (binding-style after-amp)))
  (when (and fixed-style rest-style (not (eq? fixed-style rest-style))
             ;; In a typed vector, `& name` is the odd rest pair. Let the
             ;; style-specific branch name that binder as missing its type.
             (not (and (memq fixed-style '(legacy flat))
                       (eq? rest-style 'inferred)
                       (= (length after-amp) 1)
                       (symbol? (car after-amp)))))
    (raise-mixed-bindings "parameter" d p))
  (define style (or fixed-style rest-style 'inferred))
  (define fixed (parse-typed-params before-amp before-amp-stxs style))
  (define rest-p
    (and after-amp
         (case style
           [(inferred)
            (unless (and (= (length after-amp) 1)
                         (symbol? (car after-amp)))
              (raise-parse-error
               'bad-form
               "& must be followed by exactly one inferred parameter or one binding/type pair"))
            (define source-stx (and after-amp-stxs (car after-amp-stxs)))
            (define name (parse-binding-form (car after-amp) "rest parameter"))
            (register-syntax-binder!
             (store-src! (param name #f #f)
                         (and source-stx (stx->src-loc source-stx)))
             source-stx)]
           [(legacy)
            (when (and (= (length after-amp) 1)
                       (symbol? (car after-amp)))
              (raise-missing-binding-type
               "rest parameter" (car after-amp)
               (and after-amp-stxs (car after-amp-stxs))))
            (unless (and (= (length after-amp) 1)
                         (structured-binding? (car after-amp)))
              (raise-mixed-bindings "rest parameter" after-amp
                                    (and after-amp-stxs (car after-amp-stxs))))
            (define-values (name type constraint)
              (parse-structured-binding
               (car after-amp)
               "rest parameter"
               (and after-amp-stxs (car after-amp-stxs))))
            (unless (symbol? name)
              (raise-parse-error
               'inline-type-annotation
               "rest parameter must bind one name, not a destructuring pattern"))
            (define source-stx (and after-amp-stxs (car after-amp-stxs)))
            (register-syntax-binder!
             (store-src!
             (param name type constraint)
              (and source-stx (stx->src-loc source-stx)))
             source-stx)]
           [(flat)
            (when (= (length after-amp) 1)
              (raise-missing-binding-type
               "rest parameter" (car after-amp)
               (and after-amp-stxs (car after-amp-stxs))))
            (unless (= (length after-amp) 2)
              (raise-parse-error
               'bad-form
               "& must be followed by exactly one binding/type pair"))
            (define name
              (parse-binding-form (car after-amp) "rest parameter"))
            (unless (symbol? name)
              (raise-parse-error
               'inline-type-annotation
               "rest parameter must bind one name, not a destructuring pattern"))
            (define source-stx (and after-amp-stxs (car after-amp-stxs)))
            (register-syntax-binder!
             (store-src!
              (param name (parse-type (cadr after-amp)) #f)
              (and source-stx (stx->src-loc source-stx)))
             source-stx)])))
  (define all-bound
    (append (apply append (map binding-target-bound-names fixed))
            (if rest-p (binding-target-bound-names rest-p) '())))
  (define duplicate
    (for/fold ([seen (seteq)] [dup #f] #:result dup)
              ([name (in-list all-bound)])
      (values (set-add seen name)
              (or dup (and (set-member? seen name) name)))))
  (when duplicate
    (raise-parse-error
     'duplicate
     "parameter list binds `~a` more than once; every nested destructuring name and :as alias must be unique"
     duplicate))
  (values fixed rest-p))

;; Legacy declarations remain reader-compatible; flat declarations are strict
;; adjacent pairs. Both paths lower to the same param AST.
(define (parse-typed-params items [item-stxs #f] [style (binding-style items)])
  (case (or style 'inferred)
    [(inferred)
     (define stxs (or item-stxs (make-list (length items) #f)))
     (for/list ([item (in-list items)]
                [source-stx (in-list stxs)]
                [index (in-naturals)])
       ;; A grouped declaration inside an otherwise inferred vector makes the
       ;; vector typed, so the binder ahead of it is the one left without a
       ;; type. Rule 4a names that binder rather than the enclosing list.
       (when (structured-binding? item)
         (define untyped (max 0 (sub1 index)))
         (raise-missing-binding-type
          "parameter" (list-ref items untyped) (list-ref stxs untyped)))
       (when (or (bracketed? item) (map-destructure-form? item))
         (raise-missing-binding-type "parameter" item source-stx))
       (define name (parse-binding-form item "parameter"))
       (register-syntax-binder!
        (store-src! (param name #f #f)
                    (and source-stx (stx->src-loc source-stx)))
        source-stx))]
    [(legacy)
     (for/list ([item (in-list items)]
                [source-stx (in-list (or item-stxs (make-list (length items) #f)))])
       (unless (structured-binding? item)
         ;; A bare binder in a typed vector is an omitted type (Ruling 2), not
         ;; an unreadable list — name it.
         (if (binding-form-datum? item)
             (raise-missing-binding-type "parameter" item source-stx)
             (raise-mixed-bindings "parameter" item source-stx)))
       (define-values (name type constraint)
         (parse-structured-binding item "parameter" source-stx))
       (register-syntax-binder!
        (store-src! (param name type constraint)
                    (and source-stx (stx->src-loc source-stx)))
        source-stx))]
    [(flat)
     (define mixed (flat-structured-binder items))
     (when mixed
       (raise-mixed-bindings "parameter" mixed
                             (and item-stxs
                                  (list-ref item-stxs (index-of items mixed)))))
     (when (odd? (length items))
       (raise-missing-binding-type
        "parameter" (last items) (and item-stxs (last item-stxs))))
     (let loop ([rest items] [stxs item-stxs] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [else
          (define binder (car rest))
          (define type-datum (cadr rest))
          (define source-stx (and stxs (car stxs)))
          (when (structured-binding? binder)
            (raise-mixed-bindings "parameter" binder source-stx))
          (define name (parse-binding-form binder "parameter"))
          (define parsed
            (store-src! (param name (parse-type type-datum) #f)
                        (and source-stx (stx->src-loc source-stx))))
          (loop (cddr rest)
                (and stxs (cddr stxs))
                (cons (register-syntax-binder! parsed source-stx) acc))]))]))

(define (map-destructure-form? item)
  (and (map-tagged? item)
       (let ([body (map-body item)])
         (and (>= (length body) 2)
              (eq? (car body) ':keys)
              (bracketed? (cadr body))))))

;; Map destructure: {:keys [a b] :or {b 2} :as m}. All real-Clojure options
;; are either supported (:keys/:or/:as) or pointedly rejected (:strs/:syms,
;; {alias :key}) — never silently dropped (the :or bug class, 2026-06-12).
(define (parse-map-destructure item)
  (define d (->datum item))
  (define body (map-body d))
  (unless (and (>= (length body) 2)
               (eq? (car body) ':keys)
               (bracketed? (cadr body)))
    (error 'beagle
           "map destructure must start {:keys [names ...] ...}, got: ~v" d))
  (define key-names (bracket-body (cadr body)))
  (unless (andmap symbol? key-names)
    (error 'beagle "{:keys [...]} entries must be symbols, got: ~v" key-names))
  (for ([name (in-list key-names)])
    (validate-identifier! name "map destructuring binding"))
  (let loop ([rest (cddr body)] [as-name #f] [or-defaults '()])
    (cond
      [(null? rest)
       (map-destructure key-names as-name or-defaults)]
      [(and (eq? (car rest) ':as) (pair? (cdr rest)) (symbol? (cadr rest)))
       (validate-identifier! (cadr rest) "map destructuring :as binding")
       (loop (cddr rest) (cadr rest) or-defaults)]
      [(and (eq? (car rest) ':or) (pair? (cdr rest)) (map-tagged? (cadr rest)))
       (define entries (map-body (cadr rest)))
       (unless (even? (length entries))
         (error 'beagle ":or map must be name/default pairs, got: ~v" (cadr rest)))
       (define defaults
         (let dloop ([es entries] [acc '()])
           (cond
             [(null? es) (reverse acc)]
             [else
              (unless (and (symbol? (car es)) (memq (car es) key-names))
                (error 'beagle
                       ":or key ~v must be one of the :keys binding names ~v"
                       (car es) key-names))
              (dloop (cddr es)
                     (cons (cons (car es) (parse-expr (cadr es))) acc))])))
       (loop (cddr rest) as-name defaults)]
      [(memq (car rest) '(:strs :syms))
       (error 'beagle
              "map destructure ~a is not supported — use {:keys [names]} (convert string/symbol keys with keywordize-keys first)"
              (car rest))]
      [else
       (error 'beagle
              "map destructure: unsupported entry ~v — supported: {:keys [names] :or {name default} :as name}"
              (car rest))])))

(define (parse-flat-triple-bindings b context)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (bracket-items b (string-append context "s")))
  (define item-stxs (bracket-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(null? (cdr rest))
       (raise-missing-binding-type context (car rest) (and stxs (car stxs)))]
      [(null? (cddr rest))
       (raise-missing-binding-initializer context (car rest)
                                          (and stxs (car stxs)))]
      [else
       (define binder (car rest))
       (define binder-stx (and stxs (car stxs)))
       (define type-datum (cadr rest))
       (define value-stx (and stxs (caddr stxs)))
       (define name (parse-binding-form binder context))
       (define binding
         (store-src!
          (let-binding name (parse-type type-datum) #f
                       (parse-expr (or value-stx (caddr rest))))
          (and binder-stx (stx->src-loc binder-stx))))
       (loop (cdddr rest)
             (and stxs (cdddr stxs))
             (cons (register-syntax-binder! binding binder-stx) acc))])))

;; Ruling 22 deliberately stages the migration: local-binding vectors dual-read
;; until the corpus has authored every type, then the final migration commit
;; removes the legacy pair/grouped path. A type-shaped second slot selects the
;; new `binding Type initializer` grammar; all other vectors retain the current
;; pair reader during that bounded bridge.
(define (parse-local-bindings b context)
  (define items (bracket-items b (string-append context "s")))
  (cond
    [(null? items) (parse-let-bindings b)]
    [(null? (cdr items))
     (define item-stxs (bracket-stxs (stx-subs b) (->datum b)))
     (raise-missing-binding-type context (car items)
                                 (and item-stxs (car item-stxs)))]
    [(type-expression-datum? (cadr items))
     (parse-flat-triple-bindings b context)]
    [else (parse-let-bindings b)]))

(define (parse-let-bindings b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (bracket-items b "let bindings"))
  (define item-stxs (bracket-stxs psubs d))
  (define parsed
   (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      ;; Singleton (inherit ...) or (inherit-from src ...) binding.
      ;; Parsed as a let-binding with name = #f (sentinel), value =
      ;; the parsed inherit/inherit-from expression.
      [(and (pair? (car rest))
            (memq (car (car rest)) '(inherit inherit-from)))
       (loop (cdr rest)
             (and stxs (cdr stxs))
             (cons (let-binding #f #f #f (parse-expr (car (or (and stxs (list (car stxs))) (list (car rest)))))) acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define binder-stx (and stxs (car stxs)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (let-binding destr #f #f (parse-expr (or val-stx (cadr rest))))
                    binder-stx)
                   acc))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define binder-stx (and stxs (car stxs)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (let-binding destr #f #f (parse-expr (or val-stx (cadr rest))))
                    binder-stx)
                   acc))]
      [(and (>= (length rest) 2)
            (structured-binding? (car rest)))
       (define-values (name type constraint)
         (parse-structured-binding (car rest) "let binding"
                                   (and stxs (car stxs))))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (store-src!
                     (let-binding name type constraint
                                  (parse-expr (or val-stx (cadr rest))))
                     (and stxs (stx->src-loc (car stxs))))
                    (and stxs (car stxs)))
                   acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (note-capitalized-binding! (car rest) "let binding")
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (let-binding (car rest) #f #f
                                 (parse-expr (or val-stx (cadr rest))))
                    (and stxs (car stxs)))
                   acc))]
      [else (error 'beagle "bad let bindings: ~v" rest)])))
  parsed)

(define (parse-parametric-defunion name type-vars member-defs subs)
  (reject-reserved-type-name! name "parametric defunion")
  (validate-identifier! name "parametric union")
  (define tvars (map ->datum type-vars))
  (unless (andmap symbol? tvars)
    (error 'beagle "defunion type parameters must be symbols: ~v" tvars))
  (for ([type-var (in-list tvars)])
    (validate-identifier! type-var "union type parameter"))
  (when (null? tvars)
    (raise-parse-error
     'bad-defunion
     "parametric defunion ~a requires at least one type parameter; use (defunion ~a ...) for a non-parametric union"
     name
     name))
  (for ([type-var (in-list tvars)])
    (reject-reserved-type-name! type-var "defunion type parameter"))
  (current-user-parametric-arities
   (hash-set (current-user-parametric-arities) name (length tvars)))
  (define member-names '())
  (define mf-hash (make-hasheq))
  (for ([md (in-list (or (stx-tail subs 2) member-defs))])
    (define-values (mname fields _fielded?)
      (parse-union-member-declaration md "parametric defunion" tvars))
    (set! member-names (cons mname member-names))
    (hash-set! mf-hash mname fields))
  (defunion-form name (reverse member-names) tvars mf-hash))

(define (parse-deferror name member-defs subs)
  (define member-names '())
  (define mf-hash (make-hasheq))
  (for ([md (in-list (or (stx-tail subs 2) member-defs))])
    (define-values (mname fields _fielded?)
      (parse-union-member-declaration md "deferror"))
    (set! member-names (cons mname member-names))
    (hash-set! mf-hash mname fields))
  (deferror-form name (reverse member-names) mf-hash))

(define (parse-target-case rest)
  (define cases (make-hasheq))
  (define items (map ->datum rest))
  (let loop ([items items] [raw rest])
    (cond
      [(null? items) (void)]
      [(< (length items) 2)
       (error 'beagle "target-case: expected keyword-expression pairs, got trailing: ~v" items)]
      [else
       (define kw (car items))
       (define expr-raw (and (pair? raw) (pair? (cdr raw)) (cadr raw)))
       (unless (and (symbol? kw) (regexp-match? #rx"^:" (symbol->string kw)))
         (error 'beagle "target-case: expected target keyword, got: ~v" kw))
       (define target-name (string->symbol (substring (symbol->string kw) 1)))
       (hash-set! cases target-name (parse-expr (or expr-raw (cadr items))))
       (loop (cddr items) (if (and (pair? raw) (pair? (cdr raw))) (cddr raw) '()))]))
  (when (hash-empty? cases)
    (error 'beagle "target-case: no branches provided"))
  (target-case-form cases))

;; Record fields share the dual-read declaration grammar, but always require a
;; type. Legacy grouped constraints remain emission-compatible during this
;; enabling seam; the canonical printer rewrites them as refinement types.
(define (parse-record-fields f)
  (define d (->datum f))
  (define subs (stx-subs f))
  (define items (bracket-items f "record fields"))
  (define item-stxs (bracket-stxs subs d))
  (when (null? items)
    (error 'beagle "defrecord requires at least one field"))
  ;; Fields are always typed, so an otherwise inferred-looking sequence still
  ;; enters the strict flat-pair parser and receives a type diagnostic.
  (define style
    (let ([detected (binding-style items)])
      (if (eq? detected 'inferred) 'flat (or detected 'flat))))
  (define stxs (or item-stxs (make-list (length items) #f)))
  (case style
    [(legacy)
     ;; Metadata flattened out of a grouped declaration lands in the slot after
     ;; a complete field. Diagnose it there, with the flat-pair repair, before
     ;; the type slot of the bogus declaration reaches `parse-type` and reports
     ;; a far worse `unknown type` on a name the author never wrote as a type.
     (for ([item (in-list items)]
           [next (in-list (cdr items))]
           [next-stx (in-list (cdr stxs))])
       (when (and (structured-binding? item)
                  (= (length item) 2)
                  (not (complete-record-field-declaration? next)))
         (raise-flattened-record-field item next next-stx)))
     (for/list ([item (in-list items)]
                [source-stx (in-list stxs)])
       (unless (structured-binding? item)
         (if (binding-form-datum? item)
             (raise-missing-binding-type "record field" item source-stx
                                         #:hint RECORD-FIELD-GRAMMAR-HINT)
             (raise-mixed-bindings "record field" item source-stx)))
       (define-values (name type constraint)
         (parse-structured-binding item "record field" source-stx))
       (unless (symbol? name)
         (error 'beagle
                "defrecord field name must be a symbol, got destructuring pattern: ~v"
                item))
       (store-src! (param name type constraint)
                   (and source-stx (stx->src-loc source-stx))))]
    [(flat)
     (define mixed (flat-structured-binder items))
     (when mixed
       (raise-mixed-bindings "record field" mixed
                             (and item-stxs
                                  (list-ref item-stxs (index-of items mixed)))))
     (when (odd? (length items))
       (raise-missing-binding-type
        "record field" (last items) (and item-stxs (last item-stxs))
        #:hint RECORD-FIELD-GRAMMAR-HINT))
     (let loop ([rest items] [stxs item-stxs] [acc '()])
       (cond
         [(null? rest) (reverse acc)]
         [else
          (define binder (car rest))
          (define source-stx (and stxs (car stxs)))
          (when (structured-binding? binder)
            (raise-mixed-bindings "record field" binder source-stx))
          (define name (parse-binding-form binder "record field"))
          (unless (symbol? name)
            (error 'beagle
                   "defrecord field name must be a symbol, got destructuring pattern: ~v"
                   binder))
          (loop (cddr rest)
                (and stxs (cddr stxs))
                (cons (store-src! (param name (parse-type (cadr rest)) #f)
                                  (and source-stx (stx->src-loc source-stx)))
                      acc))]))]))

(define (parse-type-impls rest)
  (let loop ([items rest] [cur-proto #f] [cur-methods '()] [acc '()])
    (cond
      [(null? items)
       (if cur-proto
         (reverse (cons (type-impl cur-proto (reverse cur-methods)) acc))
         (reverse acc))]
      [else
       (define item-d (->datum (car items)))
       (cond
         [(symbol? item-d)
          (define new-acc
            (if cur-proto
              (cons (type-impl cur-proto (reverse cur-methods)) acc)
              acc))
          (loop (cdr items) item-d '() new-acc)]
         [(pair? item-d)
          (unless cur-proto
            (error 'beagle "deftype/extend-type: method before protocol name"))
          (loop (cdr items) cur-proto
                (cons (parse-impl-method (car items)) cur-methods) acc)]
         [else
          (error 'beagle "deftype/extend-type: unexpected form: ~v" item-d)])])))

(define (parse-impl-method x)
  (define d (->datum x))
  (define subs (stx-subs x))
  (match d
    [(list (? symbol? name) params-form return-type body body-rest ...)
     (validate-identifier! name "implementation method")
     (let-values ([(parsed rest-p) (parse-params (or (stx-ref subs 1) params-form))])
       (impl-method name parsed rest-p (parse-type return-type)
                    (parse-body (or (stx-tail subs 3) (cons body body-rest)))))]
    [_ (error 'beagle "bad method implementation — expected (name [params] ReturnType body...): ~v" d)]))

;; Render a reader-tagged binding datum back to its source spelling — pointed
;; messages only; unknown shapes fall back to `~a`.
(define (binding-datum->src d)
  (cond
    [(bracketed? d)  (format "[~a]" (string-join (map binding-datum->src (bracket-body d)) " "))]
    [(map-tagged? d) (format "{~a}" (string-join (map binding-datum->src (map-body d)) " "))]
    [(and (pair? d) (list? d)) (format "(~a)" (string-join (map binding-datum->src d) " "))]
    [else (format "~a" d)]))

;; Sequential destructure: [a b], [a [b c]], [{:keys [x]} y], [a & rest].
;; Nested patterns recurse (real Clojure); entries other than symbols and
;; nested patterns are rejected pointedly.
(define (parse-seq-destructure item)
  (define d (->datum item))
  (define body (bracket-body d))
  (define-values (names rest-name)
    (let loop ([items body] [acc '()])
      (cond
        [(null? items) (values (reverse acc) #f)]
        [(eq? (car items) '&)
         (unless (and (= (length (cdr items)) 1) (symbol? (cadr items)))
           (error 'beagle "sequential destructure: & must be followed by exactly one symbol"))
         (validate-identifier! (cadr items) "sequential destructuring rest binding")
         (values (reverse acc) (cadr items))]
        [(symbol? (car items))
         (validate-identifier! (car items) "sequential destructuring binding")
         (loop (cdr items) (cons (car items) acc))]
        [(bracketed? (car items))
         (loop (cdr items) (cons (parse-seq-destructure (car items)) acc))]
        [(map-destructure-form? (car items))
         (loop (cdr items) (cons (parse-map-destructure (car items)) acc))]
        [else
         (error 'beagle
                "sequential destructure: expected a symbol, nested [..] pattern, or {:keys [..]} pattern, got: ~v"
                (car items))])))
  (seq-destructure names rest-name))

(define (parse-for-clauses b)
  (define d (->datum b))
  (define psubs (stx-subs b))
  (define items (bracket-items b "for bindings"))
  (define item-stxs (bracket-stxs psubs d))
  (let loop ([rest items] [stxs item-stxs] [acc '()])
    (cond
      [(null? rest) (reverse acc)]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':when))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-when (parse-expr (or val-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 2)
            (eq? (car rest) ':let))
       (define let-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (for-let (parse-let-bindings (or let-stx (cadr rest)))) acc))]
      [(and (>= (length rest) 3)
            (binding-form-datum? (car rest))
            (type-expression-datum? (cadr rest)))
       (define binder-stx (and stxs (car stxs)))
       (define name (parse-binding-form (car rest) "for/doseq binding"))
       (define val-stx (and stxs (>= (length stxs) 3) (caddr stxs)))
       (loop (cdddr rest)
             (and stxs (>= (length stxs) 3) (cdddr stxs))
             (cons (register-syntax-binder!
                    (store-src!
                     (for-binding name
                                  (parse-expr (or val-stx (caddr rest)))
                                  (parse-type (cadr rest))
                                  #f)
                     (and binder-stx (stx->src-loc binder-stx)))
                    binder-stx)
                   acc))]
      [(and (= (length rest) 2)
            (binding-form-datum? (car rest))
            (type-expression-datum? (cadr rest)))
       (raise-missing-binding-initializer
        "for/doseq binding" (car rest) (and stxs (car stxs)))]
      [(and (>= (length rest) 2)
            (bracketed? (car rest)))
       (define destr (parse-seq-destructure (car rest)))
       (define binder-stx (and stxs (car stxs)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (for-binding destr (parse-expr (or val-stx (cadr rest))) #f #f)
                    binder-stx)
                   acc))]
      [(and (>= (length rest) 2)
            (map-destructure-form? (car rest)))
       (define destr (parse-map-destructure (car rest)))
       (define binder-stx (and stxs (car stxs)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (for-binding destr (parse-expr (or val-stx (cadr rest))) #f #f)
                    binder-stx)
                   acc))]
      [(and (>= (length rest) 2)
            (structured-binding? (car rest)))
       (define-values (name type constraint)
         (parse-structured-binding (car rest) "for/doseq binding"
                                   (and stxs (car stxs))))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (store-src!
                     (for-binding name (parse-expr (or val-stx (cadr rest))) type constraint)
                     (and stxs (stx->src-loc (car stxs))))
                    (and stxs (car stxs)))
                   acc))]
      [(and (>= (length rest) 2)
            (symbol? (car rest)))
       (define val-stx (and stxs (>= (length stxs) 2) (cadr stxs)))
       (loop (cddr rest)
             (and stxs (>= (length stxs) 2) (cddr stxs))
             (cons (register-syntax-binder!
                    (for-binding (car rest) (parse-expr (or val-stx (cadr rest))) #f #f)
                    (and stxs (car stxs)))
                   acc))]
      [else (error 'beagle "bad for clause: ~v" rest)])))


;; Wire up parse injection parameters for extracted modules
(current-parse-expr parse-expr)
(current-parse-params parse-params)

(provide
 (all-from-out "ast.rkt")
 (all-from-out "module-interface.rkt")
 (all-from-out "parse-jst.rkt")
 (all-from-out "parse-js-quote.rkt")
 parse-program
 parse-program/bytes
 parse-program/file
 program-source-bytes
 read-beagle-datums
 read-beagle-syntax
 read-beagle-syntax/bytes
 retarget-beagle-syntax
 current-module-resolution-closed?
 strip-target-export
 (struct-out layout-edit)
 signature-layout-edits
 signature-layout-edits/bytes
 apply-signature-layout-edits
 parse-params
 parse-record-fields
 beagle-parse-error
 beagle-parse-error?
 beagle-parse-error-kind
 beagle-parse-error-details
 raise-parse-error
 ann)
