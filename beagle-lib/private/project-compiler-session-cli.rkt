#lang racket/base

;; Persistent JSON-lines transport for one exact-byte project compiler session.
;; Every input line receives one response; a malformed candidate never ends the
;; process or replaces the previously accepted compiler state.

(require json
         net/base64
         racket/list
         racket/port
         racket/string
         "module-overlay-check.rkt"
         "project-compiler-session.rkt"
         (only-in "semantic-index.rkt" write-canonical-json))

(define SCHEMA-VERSION 1)
(define REQUEST-KIND "beagle.project-session.request")
(define RESPONSE-KIND "beagle.project-session.response")

(define (json-key-string key)
  (cond
    [(symbol? key) (symbol->string key)]
    [(string? key) key]
    [else (format "~v" key)]))

(define (require-exact-object value expected label)
  (unless (hash? value)
    (error 'beagle-project-session "~a must be a JSON object" label))
  (define actual
    (sort (map json-key-string (hash-keys value)) string<?))
  (define wanted
    (sort (map symbol->string expected) string<?))
  (unless (equal? actual wanted)
    (error
     'beagle-project-session
     "~a keys must be exactly ~a, got ~a"
     label
     wanted
     actual))
  value)

(define (field object key label)
  (hash-ref
   object
   key
   (lambda ()
     (error 'beagle-project-session "~a is missing ~a" label key))))

(define (decode-base64 value source-id)
  (unless (string? value)
    (error
     'beagle-project-session
     "source ~a bytesBase64 must be a string"
     source-id))
  (unless
      (and
       (zero? (modulo (string-length value) 4))
       (regexp-match?
        #px"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"
        value))
    (error
     'beagle-project-session
     "source ~a bytesBase64 is not canonical base64"
     source-id))
  (define bytes
    (with-handlers
        ([exn:fail?
          (lambda (_error)
            (error
             'beagle-project-session
             "source ~a bytesBase64 is invalid"
             source-id))])
      (base64-decode (string->bytes/latin-1 value))))
  (unless
      (string=?
       value
       (bytes->string/latin-1 (base64-encode bytes #"")))
    (error
     'beagle-project-session
     "source ~a bytesBase64 is not canonical base64"
     source-id))
  (with-handlers
      ([exn:fail?
        (lambda (_error)
          (error
           'beagle-project-session
           "source ~a bytes are not strict UTF-8"
           source-id))])
    (bytes->string/utf-8 bytes #f))
  (bytes->immutable-bytes bytes))

(define (decode-request value)
  (require-exact-object
   value
   '(kind schemaVersion sources profile emitSourceIds)
   "request")
  (unless (equal? (field value 'kind "request") REQUEST-KIND)
    (error
     'beagle-project-session
     "request kind must be ~a"
     REQUEST-KIND))
  (unless (equal? (field value 'schemaVersion "request") SCHEMA-VERSION)
    (error
     'beagle-project-session
     "request schemaVersion must be ~a"
     SCHEMA-VERSION))
  (define source-values (field value 'sources "request"))
  (unless (and (list? source-values) (pair? source-values))
    (error
     'beagle-project-session
     "request sources must be a non-empty array"))
  (define sources
    (for/list ([source-value (in-list source-values)]
               [index (in-naturals)])
      (define label (format "sources[~a]" index))
      (require-exact-object
       source-value
       '(sourceId bytesBase64 targetOverride)
       label)
      (define source-id (field source-value 'sourceId label))
      (unless (string? source-id)
        (error
         'beagle-project-session
         "~a sourceId must be a string"
         label))
      (define override (field source-value 'targetOverride label))
      (project-source-v1
       source-id
       (decode-base64
        (field source-value 'bytesBase64 label)
        source-id)
       (cond
         [(eq? override 'null) #f]
         [(string? override) (string->symbol override)]
         [else
          (error
           'beagle-project-session
           "~a targetOverride must be null or a target string"
           label)]))))
  (define profile-value (field value 'profile "request"))
  (require-exact-object
   profile-value
   '(checkProfile lint nixModuleOmitAttrs)
   "profile")
  (define check-profile
    (field profile-value 'checkProfile "profile"))
  (define lint?
    (field profile-value 'lint "profile"))
  (unless (boolean? lint?)
    (error 'beagle-project-session "profile lint must be a boolean"))
  (define omit-values
    (field profile-value 'nixModuleOmitAttrs "profile"))
  (unless (and (list? omit-values) (andmap string? omit-values))
    (error
     'beagle-project-session
     "profile nixModuleOmitAttrs must be an array of strings"))
  (define emit-values (field value 'emitSourceIds "request"))
  (unless (and (list? emit-values) (andmap string? emit-values))
    (error
     'beagle-project-session
     "emitSourceIds must be an array of strings"))
  (project-compile-request-v1
   sources
   (project-compile-profile-v1
    check-profile lint? (map string->symbol omit-values))
   emit-values))

(define (decode-request-bytes bytes)
  (define text
    (with-handlers
        ([exn:fail?
          (lambda (_error)
            (error
             'beagle-project-session
             "request line is not strict UTF-8"))])
      (bytes->string/utf-8 bytes #f)))
  (define in (open-input-string text))
  (define value (read-json in))
  (when (eof-object? value)
    (error 'beagle-project-session "request line contains no JSON value"))
  (unless (regexp-match? #px"^\\s*$" (port->string in))
    (error
     'beagle-project-session
     "request line contains trailing content after its JSON value"))
  (decode-request value))

(define (diagnostic->json diagnostic)
  (hasheq
   'sourceId (or (overlay-diagnostic-source diagnostic) 'null)
   'phase (symbol->string (overlay-diagnostic-phase diagnostic))
   'message (overlay-diagnostic-message diagnostic)))

(define (counters->json observation)
  (define counters
    (project-compile-observation-v1-counters observation))
  (hasheq
   'mode (symbol->string (project-compile-observation-v1-mode observation))
   'jsonDecodes (project-compile-counters-v1-json-decodes counters)
   'sourceDecodes (project-compile-counters-v1-source-decodes counters)
   'sourceReads (project-compile-counters-v1-source-reads counters)
   'parses (project-compile-counters-v1-parses counters)
   'cacheHits (project-compile-counters-v1-cache-hits counters)
   'cacheMisses (project-compile-counters-v1-cache-misses counters)
   'rechecks (project-compile-counters-v1-rechecks counters)
   'recheckedSourceIds
   (project-compile-observation-v1-rechecked-source-ids observation)
   'emits (project-compile-counters-v1-emits counters)))

(define (result->json result)
  (hasheq
   'kind RESPONSE-KIND
   'schemaVersion SCHEMA-VERSION
   'ok (project-compile-result-ok? result)
   'snapshotDigest
   (or (project-compile-result-snapshot-digest result) 'null)
   'artifacts
   (for/list ([artifact
               (in-list (project-compile-result-artifacts result))])
     (hasheq
      'sourceId (project-artifact-v1-source-id artifact)
      'target (symbol->string (project-artifact-v1-target artifact))
      'relativePath (project-artifact-v1-relative-path artifact)
      'bytesBase64
      (bytes->string/latin-1
       (base64-encode (project-artifact-v1-bytes artifact) #""))))
   'diagnostics
   (map diagnostic->json (project-compile-result-diagnostics result))
   'counters
   (counters->json (project-compile-result-observation result))))

(define (write-response value [out (current-output-port)])
  (write-canonical-json value out)
  (newline out)
  (flush-output out))

(define (run-project-compiler-session-cli
         [in (current-input-port)]
         [out (current-output-port)])
  (unless (zero? (vector-length (current-command-line-arguments)))
    (error
     'beagle-project-session
     "usage: beagle project-session < requests.jsonl"))
  (define session (make-project-compiler-session))
  (let loop ()
    (define line (read-bytes-line in 'any))
    (unless (eof-object? line)
      (define result
        (project-compiler-session-compile/encoded!
         session
         line
         decode-request-bytes))
      (write-response (result->json result) out)
      (loop))))

(module+ main
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (eprintf "beagle project-session: ~a\n" (exn-message error))
          (exit 1))])
    (run-project-compiler-session-cli)))

(provide
 SCHEMA-VERSION
 REQUEST-KIND
 RESPONSE-KIND
 decode-request
 decode-request-bytes
 result->json
 run-project-compiler-session-cli)
