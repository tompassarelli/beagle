#lang racket/base

;; Closed, exact-byte checked projection for multi-module consumers.

(require json
         net/base64
         openssl/sha1
         racket/list
         racket/match
         racket/path
         racket/port
         racket/set
         racket/string
         "ast-json.rkt"
         "extensions.rkt"
         "module-interface.rkt"
         "module-overlay-check.rkt"
         "parse.rkt"
         "semantic-index.rkt"
         "targets.rkt"
         (only-in "../lang/reader-impl.rkt" beagle-readtable)
         (only-in "../nix/lang/reader-impl.rkt" beagle-nix-readtable))

(define CHECKED-BUNDLE-SCHEMA-VERSION 4)
(define REQUEST-KIND "beagle.checked-bundle.request")
(define RESPONSE-KIND "beagle.checked-bundle")
(define ALLOWED-AUTHORITIES '("package" "trusted"))

(struct bundle-source (source-id bytes authority stxs namespace) #:transparent)

(define (fail fmt . args)
  (apply error 'beagle-ast-bundle fmt args))

(define (json-key-string key)
  (cond
    [(symbol? key) (symbol->string key)]
    [(string? key) key]
    [else (format "~v" key)]))

(define (require-exact-object value expected label)
  (unless (hash? value)
    (fail "~a must be a JSON object" label))
  (define actual (sort (map json-key-string (hash-keys value)) string<?))
  (define wanted (sort (map symbol->string expected) string<?))
  (unless (equal? actual wanted)
    (fail "~a keys must be exactly ~a, got ~a" label wanted actual))
  value)

(define (field object key label)
  (hash-ref
   object
   key
   (lambda () (fail "~a is missing ~a" label key))))

(define (canonical-source-id? value)
  (and
   (string? value)
   (positive? (string-length value))
   (string=? value (string-normalize-nfc value))
   (not (string-prefix? value "/"))
   (not (string-suffix? value "/"))
   (not (string-contains? value "\\"))
   (not
    (for/or ([character (in-string value)])
      (define scalar (char->integer character))
      (or (< scalar 32) (= scalar 127))))
   (for/and ([part (in-list (string-split value "/" #:trim? #f))])
     (and (positive? (string-length part))
          (not (member part '("." "..")))))
   (expected-target-for-extension value)))

(define (decode-source-bytes encoded source-id)
  (unless (string? encoded)
    (fail "source ~a bytesBase64 must be a string" source-id))
  (unless (and (zero? (modulo (string-length encoded) 4))
               (regexp-match? #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"
                              encoded))
    (fail "source ~a bytesBase64 is not canonical base64" source-id))
  (define decoded
    (with-handlers ([exn:fail?
                     (lambda (_error)
                       (fail "source ~a bytesBase64 is invalid" source-id))])
      (base64-decode (string->bytes/latin-1 encoded))))
  (unless (string=? encoded
                    (bytes->string/latin-1 (base64-encode decoded #"")))
    (fail "source ~a bytesBase64 is not canonical base64" source-id))
  (with-handlers ([exn:fail?
                   (lambda (_error)
                     (fail "source ~a is not strict UTF-8" source-id))])
    (bytes->string/utf-8 decoded #f))
  (bytes->immutable-bytes decoded))

(define (language-target lang)
  (for/first ([target (in-list (source-profile-ids))]
              #:when (equal? lang (lang-for-target-id target)))
    target))

(define (source-bytes->stxs source-id source-bytes)
  ;; This read is only for the module index and compatibility importer. The
  ;; checked program below is independently created by parse-program/bytes from
  ;; this same immutable snapshot.
  (define in (open-input-bytes source-bytes))
  (dynamic-wind
    void
    (lambda ()
      (port-count-lines! in)
      (define first-line (read-line in))
      (define lang-match
        (and (string? first-line)
             (regexp-match #px"^#lang[ ]+([^ ]+)[ ]*$" first-line)))
      (define header-target
        (and lang-match (language-target (cadr lang-match))))
      (define has-lang? (and lang-match #t))
      (unless has-lang?
        (file-position in 0)
        (set-port-next-location! in 1 0 1))
      (define target
        (or header-target (expected-target-for-extension source-id)))
      (define target-readtable
        (if (eq? target 'nix) beagle-nix-readtable beagle-readtable))
      (parameterize ([current-readtable target-readtable])
        (define forms
          (let loop ([forms '()])
            (define form (read-syntax source-id in))
            (if (eof-object? form)
                (reverse forms)
                (loop (cons form forms)))))
        (if header-target
            (cons (datum->syntax #f (list 'define-target header-target)) forms)
            forms)))
    (lambda () (close-input-port in))))

(define (declared-namespace stxs source-id)
  (define namespaces
    (for/list ([stx (in-list stxs)]
               #:do [(define datum (syntax->datum stx))]
               #:when
               (match datum
                 [(list* 'ns (? symbol?) _) #t]
                 [_ #f]))
      (cadr (syntax->datum stx))))
  (cond
    [(null? namespaces)
     (fail "source ~a must declare exactly one namespace" source-id)]
    [(pair? (cdr namespaces))
     (fail "source ~a declares multiple namespaces: ~a"
           source-id namespaces)]
    [else (car namespaces)]))

(define (decode-request request)
  (require-exact-object
   request
   '(kind schemaVersion entrySourceId sources)
   "request")
  (unless (equal? (field request 'kind "request") REQUEST-KIND)
    (fail "request kind must be ~a" REQUEST-KIND))
  (unless (equal? (field request 'schemaVersion "request")
                  CHECKED-BUNDLE-SCHEMA-VERSION)
    (fail "request schemaVersion must be ~a"
          CHECKED-BUNDLE-SCHEMA-VERSION))
  (define entry-source-id (field request 'entrySourceId "request"))
  (unless (canonical-source-id? entry-source-id)
    (fail "entrySourceId is not a canonical relative Beagle source id: ~v"
          entry-source-id))
  (define source-values (field request 'sources "request"))
  (unless (and (list? source-values) (pair? source-values))
    (fail "request sources must be a non-empty array"))
  (define sources
    (for/list ([value (in-list source-values)] [index (in-naturals)])
      (define label (format "sources[~a]" index))
      (require-exact-object
       value
       '(sourceId bytesBase64 authority)
       label)
      (define source-id (field value 'sourceId label))
      (unless (canonical-source-id? source-id)
        (fail "~a sourceId is not a canonical relative Beagle source id: ~v"
              label source-id))
      (define authority (field value 'authority label))
      (unless (member authority ALLOWED-AUTHORITIES)
        (fail "~a authority must be package or trusted, got ~v"
              label authority))
      (define bytes
        (decode-source-bytes (field value 'bytesBase64 label) source-id))
      (define stxs (source-bytes->stxs source-id bytes))
      (bundle-source
       source-id
       bytes
       authority
       stxs
       (declared-namespace stxs source-id))))
  (define by-source-id (make-hash))
  (define by-namespace (make-hasheq))
  (for ([source (in-list sources)])
    (define source-id (bundle-source-source-id source))
    (when (hash-has-key? by-source-id source-id)
      (fail "duplicate sourceId ~a" source-id))
    (hash-set! by-source-id source-id source)
    (define namespace (bundle-source-namespace source))
    (when (hash-has-key? by-namespace namespace)
      (define other (hash-ref by-namespace namespace))
      (fail
       "namespace ~a is ambiguous/shadowed by ~a (~a) and ~a (~a)"
       namespace
       (bundle-source-source-id other)
       (bundle-source-authority other)
       source-id
       (bundle-source-authority source)))
    (hash-set! by-namespace namespace source))
  (unless (hash-has-key? by-source-id entry-source-id)
    (fail "entrySourceId ~a is absent from sources" entry-source-id))
  (values entry-source-id sources by-source-id by-namespace))

(define (sha256-prefixed bytes)
  (string-append "sha256:"
                 (bytes->hex-string (sha256-bytes bytes))))

(define (canonical-json-bytes value)
  (define out (open-output-bytes))
  (write-canonical-json value out)
  (get-output-bytes out))

(define (profile-source-path? path)
  (define path-string
    (cond
      [(path? path) (path->string path)]
      [(string? path) path]
      [else #f]))
  (and path-string
       (for/or ([entry (in-list EXTENSION-TARGET-MAP)])
         (and (cdr entry)
              (string-suffix? path-string (car entry))))))

(define (closed-source-security-guard)
  (make-security-guard
   (current-security-guard)
   (lambda (_who path modes)
     (define actions (if (list? modes) modes (list modes)))
     (when (and (profile-source-path? path)
                (or (memq 'read actions) (memq 'exists actions)))
       (fail "ambient Beagle source access is forbidden: ~a" path)))
   (lambda (_who _host _port _mode) (void))))

(define (require-edge entry namespace-index)
  (define namespace (require-entry-ns entry))
  (define provider
    (hash-ref
     namespace-index
     namespace
     (lambda ()
       (fail "required namespace ~a is absent from the closed source bundle"
             namespace))))
  (hasheq
   'namespace (symbol->string namespace)
   'sourceId (bundle-source-source-id provider)))

(define (sorted-require-edges prog namespace-index)
  (sort
   (for/list ([entry (in-list (program-requires prog))])
     (require-edge entry namespace-index))
   string<?
   #:key (lambda (edge) (hash-ref edge 'namespace))))

(define (assert-complete-closure entry-source-id modules source-index namespace-index)
  (define module-index
    (for/hash ([module (in-list modules)])
      (values (format "~a" (checked-overlay-module-source module)) module)))
  (define reachable (mutable-set))
  (let visit ([source-id entry-source-id])
    (unless (set-member? reachable source-id)
      (set-add! reachable source-id)
      (define module (hash-ref module-index source-id))
      (for ([edge (in-list
                   (sorted-require-edges
                    (checked-overlay-module-program module)
                    namespace-index))])
        (visit (hash-ref edge 'sourceId)))))
  (define unreachable
    (sort
     (for/list ([source-id (in-hash-keys source-index)]
                #:unless (set-member? reachable source-id))
       source-id)
     string<?))
  (unless (null? unreachable)
    (fail "closed source bundle contains unreachable source~a: ~a"
          (if (= (length unreachable) 1) "" "s")
          (string-join unreachable ", ")))
  (for ([module (in-list modules)])
    (define source-id (format "~a" (checked-overlay-module-source module)))
    (define source (hash-ref source-index source-id))
    (when (equal? (bundle-source-authority source) "trusted")
      (for ([edge (in-list
                   (sorted-require-edges
                    (checked-overlay-module-program module)
                    namespace-index))])
        (define provider-id (hash-ref edge 'sourceId))
        (define provider (hash-ref source-index provider-id))
        (unless (equal? (bundle-source-authority provider) "trusted")
          (fail "trusted source ~a cannot require package source ~a"
                source-id provider-id))))))

(define (build-checked-bundle request)
  (define-values
    (entry-source-id sources source-index namespace-index)
    (decode-request request))
  (define module-sources
    (for/list ([source (in-list sources)])
      (module-source
       (bundle-source-namespace source)
       (bundle-source-source-id source)
       (bundle-source-stxs source)
       #f)))
  (define (parse-exact source resolver)
    (define source-id (format "~a" (module-source-source-id source)))
    (define submitted
      (hash-ref
       source-index
       source-id
       (lambda () (fail "internal source lookup failed for ~a" source-id))))
    (parse-program/bytes
     (bundle-source-bytes submitted)
     #:source-path source-id
     #:module-resolver resolver))
  (define result
    (parameterize ([current-security-guard
                    (closed-source-security-guard)])
      (check-module-overlay
       module-sources
       #:emit? #f
       #:capture-types? #t
       #:closed? #t
       #:parse-source parse-exact)))
  (unless (overlay-check-result-ok? result)
    (define diagnostics (overlay-check-result-diagnostics result))
    (if (pair? diagnostics)
        (let ([diagnostic (car diagnostics)])
          (fail "~a: ~a: ~a"
                (or (overlay-diagnostic-source diagnostic) "<bundle>")
                (overlay-diagnostic-phase diagnostic)
                (overlay-diagnostic-message diagnostic)))
        (fail "closed source bundle did not check")))
  (define modules (overlay-check-result-modules result))
  (for ([module (in-list modules)])
    (define source-id (format "~a" (checked-overlay-module-source module)))
    (define prog (checked-overlay-module-program module))
    (define expected-target (expected-target-for-extension source-id))
    (unless (eq? expected-target (program-target prog))
      (fail "source ~a extension requires #lang ~a, got #lang ~a"
            source-id
            (lang-for-target-id expected-target)
            (lang-for-target-id (program-target prog)))))
  (assert-complete-closure
   entry-source-id modules source-index namespace-index)
  (define module-index
    (for/hash ([module (in-list modules)])
      (values (format "~a" (checked-overlay-module-source module)) module)))
  (define entry-module (hash-ref module-index entry-source-id))
  (define entry-projection
    (checked-program->json
     (checked-overlay-module-program entry-module)
     #:source-id entry-source-id))
  (define module-receipts
    (sort
     (for/list ([module (in-list modules)])
       (define source-id (format "~a" (checked-overlay-module-source module)))
       (define source (hash-ref source-index source-id))
       (define interface (checked-overlay-module-interface module))
       (hasheq
        'authority (bundle-source-authority source)
        'sourceId source-id
        'namespace
        (symbol->string
         (program-namespace (checked-overlay-module-program module)))
        'sourceSha256 (sha256-prefixed (bundle-source-bytes source))
        'interfaceSha256 (module-interface-digest interface)
        'requires
        (sorted-require-edges
         (checked-overlay-module-program module)
         namespace-index)))
     string<?
     #:key (lambda (module) (hash-ref module 'sourceId))))
  (define closure-base
    (hasheq 'entrySourceId entry-source-id 'modules module-receipts))
  (define closure-sha256
    (sha256-prefixed (canonical-json-bytes closure-base)))
  (define response-base
    (hasheq
     'kind RESPONSE-KIND
     'schemaVersion CHECKED-BUNDLE-SCHEMA-VERSION
     'entrySourceId entry-source-id
     'entryProjection entry-projection
     'modules module-receipts))
  (define response-with-closure
    (hash-set response-base 'sourceClosureSha256 closure-sha256))
  (hash-set
   response-with-closure
   'checkedBundleSha256
   (sha256-prefixed (canonical-json-bytes response-with-closure))))

(provide
 CHECKED-BUNDLE-SCHEMA-VERSION
 build-checked-bundle)
