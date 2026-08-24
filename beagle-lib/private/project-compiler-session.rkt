#lang racket/base

;; One transactional compiler authority for an exact-byte project snapshot.
;; The session owns checked Programs and incremental reuse. A request publishes
;; a successor cache/result only after the complete overlay validates and every
;; requested artifact has been emitted in memory.

(require json
         openssl/sha1
         racket/list
         racket/path
         racket/port
         racket/set
         racket/string
         "check.rkt"
         "emit.rkt"
         (only-in "emit-js.rkt"
                  current-js-export-names
                  js-emit-program-with-source-map)
         (only-in "emit-nix.rkt" current-nix-module-omit-attrs)
         "extensions.rkt"
         "lint.rkt"
         "module-overlay-check.rkt"
         "parse.rkt"
         "targets.rkt")

(struct project-source-v1 (source-id bytes target-override) #:transparent)
(struct project-compile-profile-v1
  (check-profile lint? nix-module-omit-attrs)
  #:transparent)
(struct project-compile-request-v1 (sources profile emit-source-ids)
  #:transparent)
(struct project-artifact-v1 (source-id target relative-path bytes)
  #:transparent)
(struct project-compile-counters-v1
  (json-decodes source-decodes source-reads parses
                cache-hits cache-misses rechecks emits)
  #:transparent)
(struct project-compile-observation-v1 (mode counters) #:transparent)
(struct project-compile-result
  (ok? snapshot-digest modules artifacts diagnostics observation)
  #:transparent)
(struct project-compiler-session
  (lock cache accepted-request-bytes accepted-result last-observation emitter)
  #:mutable)

(define (make-project-compiler-session #:emitter [emitter emit-project-module])
  (unless (procedure? emitter)
    (raise-argument-error
     'make-project-compiler-session "procedure?" emitter))
  (project-compiler-session
   (make-semaphore 1)
   (make-incremental-module-check-cache)
   #f
   #f
   #f
   emitter))

(define (sha256-prefixed bytes)
  (string-append "sha256:" (bytes->hex-string (sha256-bytes bytes))))

(define (datum-digest datum)
  (sha256-prefixed
   (call-with-output-bytes
    (lambda (out)
      (parameterize ([current-output-port out])
        (write datum))))))

(define (source-id-string value)
  (cond
    [(string? value) value]
    [(path? value) (path->string value)]
    [(symbol? value) (symbol->string value)]
    [else (format "~a" value)]))

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

(define (normalize-profile profile)
  (unless (project-compile-profile-v1? profile)
    (raise-argument-error
     'project-compiler-session-compile!
     "project-compile-profile-v1?"
     profile))
  (define check-profile
    (project-compile-profile-v1-check-profile profile))
  (unless (and (exact-integer? check-profile) (<= 0 check-profile 3))
    (error
     'project-compiler-session-compile!
     "check profile must be 0, 1, 2, or 3, got ~v"
     check-profile))
  (unless (boolean? (project-compile-profile-v1-lint? profile))
    (error
     'project-compiler-session-compile!
     "lint? must be a boolean"))
  (define omit-attrs
    (project-compile-profile-v1-nix-module-omit-attrs profile))
  (unless (and (list? omit-attrs) (andmap symbol? omit-attrs))
    (error
     'project-compiler-session-compile!
     "nix-module-omit-attrs must be a list of symbols"))
  (project-compile-profile-v1
   check-profile
   (project-compile-profile-v1-lint? profile)
   (sort (remove-duplicates omit-attrs eq?) symbol<?)))

(define (normalize-request request)
  (unless (project-compile-request-v1? request)
    (raise-argument-error
     'project-compiler-session-compile!
     "project-compile-request-v1?"
     request))
  (define raw-sources (project-compile-request-v1-sources request))
  (unless (and (list? raw-sources) (pair? raw-sources)
               (andmap project-source-v1? raw-sources))
    (error
     'project-compiler-session-compile!
     "sources must be a non-empty list of project-source-v1 values"))
  (define sources
    (sort
     (for/list ([source (in-list raw-sources)])
       (define raw-source-id (project-source-v1-source-id source))
       (unless (canonical-source-id? raw-source-id)
         (error
          'project-compiler-session-compile!
          "source id is not a canonical relative Beagle source id: ~v"
          raw-source-id))
       (define source-id (string->immutable-string raw-source-id))
       (define bytes (project-source-v1-bytes source))
       (unless (bytes? bytes)
         (error
          'project-compiler-session-compile!
          "source ~a bytes must be bytes"
          source-id))
       (define target-override
         (project-source-v1-target-override source))
       (unless
           (or
            (not target-override)
            (and (symbol? target-override)
                 (member target-override (source-profile-ids))))
         (error
          'project-compiler-session-compile!
          "source ~a target override must be #f or one of ~a"
          source-id
          (source-profile-ids)))
       (project-source-v1
        source-id (bytes->immutable-bytes bytes) target-override))
     string<?
     #:key project-source-v1-source-id))
  (define duplicate-source
    (check-duplicates sources string=? #:key project-source-v1-source-id))
  (when duplicate-source
    (error
     'project-compiler-session-compile!
     "duplicate source id ~a"
     (project-source-v1-source-id duplicate-source)))
  (define source-ids (map project-source-v1-source-id sources))
  (define raw-emit-source-ids
    (project-compile-request-v1-emit-source-ids request))
  (unless (and (list? raw-emit-source-ids)
               (andmap string? raw-emit-source-ids))
    (error
     'project-compiler-session-compile!
     "emit-source-ids must be a list of strings"))
  (define duplicate-emit-source-id
    (check-duplicates raw-emit-source-ids string=?))
  (when duplicate-emit-source-id
    (error
     'project-compiler-session-compile!
     "duplicate emitted source id ~a"
     duplicate-emit-source-id))
  (define emit-source-ids
    (sort (map string->immutable-string raw-emit-source-ids) string<?))
  (for ([source-id (in-list emit-source-ids)])
    (unless (member source-id source-ids)
      (error
       'project-compiler-session-compile!
       "emitted source is absent from the snapshot: ~a"
       source-id)))
  (project-compile-request-v1
   sources
   (normalize-profile (project-compile-request-v1-profile request))
   emit-source-ids))

(define (snapshot-digest sources)
  (datum-digest
   `(beagle-project-snapshot-v1
     ,@(for/list ([source (in-list sources)])
         (list
          (project-source-v1-source-id source)
          (project-source-v1-target-override source)
          (project-source-v1-bytes source))))))

(define (project-source-digest source)
  ;; The incremental checker groups Core and Nix under the same semantic
  ;; profile. Keep an explicit target choice in the source identity so a
  ;; retained Program from one route cannot satisfy the other.
  (datum-digest
   `(beagle-project-source-v1
     ,(project-source-v1-target-override source)
     ,(project-source-v1-bytes source))))

(define (datum-bytes datum)
  (call-with-output-bytes
   (lambda (out)
     (parameterize ([current-output-port out])
       (write datum)))))

(define (source->module-source source)
  (define source-id (project-source-v1-source-id source))
  (define declared
    (read-beagle-syntax/bytes
     source-id
     (project-source-v1-bytes source)
     #:source-id source-id))
  (define target-override (project-source-v1-target-override source))
  (stxs->module-source
   (if target-override
       (retarget-beagle-syntax declared target-override)
       declared)
   source-id))

(define (extension-for-target target)
  (case target
    [(js) ".js"]
    [(py) ".py"]
    [(nix) ".nix"]
    [else ".clj"]))

(define (namespace-relative-path namespace target)
  (define namespace-text (symbol->string namespace))
  (define file-namespace
    (if (eq? target 'clj)
        (regexp-replace* #rx"-" namespace-text "_")
        namespace-text))
  (string-append
   (regexp-replace* #rx"\\." file-namespace "/")
   (extension-for-target target)))

(define (source-map-source-id source-id)
  (path->string (file-name-from-path (string->path source-id))))

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
       (error
        'project-compiler-session-compile!
        "ambient Beagle source access is forbidden: ~a"
        path)))
   (lambda (_who _host _port _mode) (void))))

(define (programs->export-plan programs)
  (for/fold ([plan (hash)])
            ([prog (in-list programs)])
    (for/fold ([next plan])
              ([required (in-list (program-requires prog))])
      (define namespace (require-entry-ns required))
      (define requested
        (if (require-entry-refer required)
            (list->set (require-entry-refer required))
            (set '*)))
      (hash-update
       next
       namespace
       (lambda (prior) (set-union prior requested))
       (set)))))

(define (json-bytes value)
  (define out (open-output-bytes))
  (write-json value out)
  (newline out)
  (get-output-bytes out))

(define (emit-project-module module source export-plan omit-attrs)
  (define source-id (project-source-v1-source-id source))
  (define prog (checked-overlay-module-program module))
  (define target (program-target prog))
  (define relative-path
    (namespace-relative-path (program-namespace prog) target))
  (define emitted
    (parameterize
        ([current-js-export-names
          (and
           (eq? target 'js)
           (hash-ref export-plan (program-namespace prog) (set)))]
         [current-nix-module-omit-attrs omit-attrs])
      (emit-program prog)))
  (cond
    [(eq? target 'js)
     (define js-name
       (path->string (file-name-from-path (string->path relative-path))))
     (define-values (mapped-source document)
       (js-emit-program-with-source-map
        prog
        (source-map-source-id source-id)
        (bytes->string/utf-8 (project-source-v1-bytes source) #f)
        js-name))
     (unless (string=? emitted mapped-source)
       (error
        'project-compiler-session-compile!
        "source-map annotation changed JavaScript bytes for ~a"
        source-id))
     (define map-relative-path (string-append relative-path ".map"))
     (define map-name
       (path->string
        (file-name-from-path (string->path map-relative-path))))
     (values
      emitted
      (list
       (project-artifact-v1
        source-id
        target
        relative-path
        (string->bytes/utf-8
         (string-append
          emitted
          (if (string-suffix? emitted "\n") "" "\n")
          "//# sourceMappingURL=" map-name "\n")))
       (project-artifact-v1
        source-id target map-relative-path (json-bytes document))))]
    [else
     (values
      emitted
      (list
       (project-artifact-v1
        source-id target relative-path (string->bytes/utf-8 emitted))))]))

(define (make-diagnostic source phase value)
  (overlay-diagnostic
   source
   phase
   (if (exn? value) (exn-message value) (format "~a" value))))

(define (freeze-artifact artifact)
  (struct-copy
   project-artifact-v1
   artifact
   [source-id
    (string->immutable-string (project-artifact-v1-source-id artifact))]
   [relative-path
    (string->immutable-string (project-artifact-v1-relative-path artifact))]
   [bytes (bytes->immutable-bytes (project-artifact-v1-bytes artifact))]))

(define (failure-result snapshot-id diagnostics observation)
  (project-compile-result
   #f snapshot-id '() '() diagnostics observation))

(define (project-request-key request)
  (datum-bytes (list 'beagle-project-compile-request-v1 request)))

(define (project-compiler-session-compile/locked!
         session
         exact-request-bytes
         request-thunk
         json-decodes
         diagnostic-sink)
  (let/ec abort
    (define snapshot-id #f)
    (define source-decodes 0)
    (define source-reads 0)
    (define parses 0)
    (define cache-counters (incremental-check-counters 0 0 0))
    (define emits 0)
    (define (current-counters)
      (project-compile-counters-v1
       json-decodes
       source-decodes
       source-reads
       parses
       (incremental-check-counters-hits cache-counters)
       (incremental-check-counters-misses cache-counters)
       (incremental-check-counters-rechecks cache-counters)
       emits))
    (define (observe mode)
      (project-compile-observation-v1 mode (current-counters)))
    (define (finish-failure diagnostics [mode 'failed])
      (define observation (observe mode))
      (set-project-compiler-session-last-observation! session observation)
      (abort
       (failure-result snapshot-id diagnostics observation)))
    (define (fail source phase value)
      (diagnostic-sink source phase value #f)
      (finish-failure (list (make-diagnostic source phase value))))

    ;; The exact accepted request bytes are compared under the session lock
    ;; before the request thunk can decode JSON/base64 or read/parse source.
    (define accepted (project-compiler-session-accepted-result session))
    (when
        (and accepted
             (bytes=?
              exact-request-bytes
              (project-compiler-session-accepted-request-bytes session)))
      (define exact-observation
        (project-compile-observation-v1
         'exact-hit
         (project-compile-counters-v1 0 0 0 0 0 0 0 0)))
      (set-project-compiler-session-last-observation!
       session exact-observation)
      (abort
       (struct-copy
        project-compile-result
        accepted
        [observation exact-observation])))

    (define request
      (with-handlers
          ([(lambda (_value) #t)
            (lambda (value) (fail #f 'request value))])
        (request-thunk)))
    (define normalized
      (with-handlers
          ([(lambda (_value) #t)
            (lambda (value) (fail #f 'request value))])
        (normalize-request request)))
    (define sources (project-compile-request-v1-sources normalized))
    (when (positive? json-decodes)
      (set! source-decodes (length sources)))
    (set! snapshot-id (snapshot-digest sources))
    (define source-index
      (for/hash ([source (in-list sources)])
        (values (project-source-v1-source-id source) source)))
    (define module-sources
      (for/list ([source (in-list sources)])
        (set! source-reads (add1 source-reads))
        (with-handlers
            ([(lambda (_value) #t)
              (lambda (value)
                (fail (project-source-v1-source-id source) 'read value))])
          (source->module-source source))))
    (define (parse-exact source resolver)
      (set! parses (add1 parses))
      (define source-id
        (source-id-string (module-source-source-id source)))
      (define submitted
        (hash-ref
         source-index
         source-id
         (lambda ()
           (error
            'project-compiler-session-compile!
            "internal source lookup failed for ~a"
            source-id))))
      (parse-program/bytes
       (project-source-v1-bytes submitted)
       #:source-path source-id
       #:source-id source-id
       #:target-override (project-source-v1-target-override submitted)
       #:module-resolver resolver))
    (define incremental
      (with-handlers
          ([(lambda (_value) #t)
            (lambda (value) (fail #f 'check value))])
        (parameterize ([current-security-guard
                        (closed-source-security-guard)])
          (check-module-overlay/incremental
           module-sources
           (project-compiler-session-cache session)
           #:check-profile
           (project-compile-profile-v1-check-profile
            (project-compile-request-v1-profile normalized))
           #:capture-types? #t
           #:closed? #t
           #:source-digest
           (lambda (source)
             (project-source-digest
              (hash-ref
               source-index
               (source-id-string (module-source-source-id source)))))
           #:diagnostic-sink diagnostic-sink
           #:parse-source parse-exact))))
    (set!
     cache-counters
     (incremental-overlay-check-result-counters incremental))
    (define checked
      (incremental-overlay-check-result-check-result incremental))
    (unless (overlay-check-result-ok? checked)
      (finish-failure
       (overlay-check-result-diagnostics checked)
       'incremental-failed))
    (define modules (overlay-check-result-modules checked))
    (define profile (project-compile-request-v1-profile normalized))
    (for ([module (in-list modules)])
      (define source-id
        (source-id-string (checked-overlay-module-source module)))
      (with-handlers
          ([(lambda (_value) #t)
            (lambda (value) (fail source-id 'validate value))])
        (define prog (checked-overlay-module-program module))
        (define expected-target (expected-target-for-extension source-id))
        (unless (and expected-target
                     (eq? expected-target (program-target prog)))
          (error
           'project-compiler-session-compile!
           "source ~a extension requires #lang ~a, got #lang ~a"
           source-id
           (and expected-target (lang-for-target-id expected-target))
           (lang-for-target-id (program-target prog))))
        (parameterize
            ([current-check-profile
              (project-compile-profile-v1-check-profile profile)])
          (check-scalar-provenance! prog))
        (when (project-compile-profile-v1-lint? profile)
          (lint-program! prog))))
    (define export-plan
      (programs->export-plan
       (map checked-overlay-module-program modules)))
    (define emit-source-set
      (list->set
       (project-compile-request-v1-emit-source-ids normalized)))
    (define emitted-by-source (make-hash))
    (define artifacts
      (append-map
       (lambda (module)
         (define source-id
           (source-id-string (checked-overlay-module-source module)))
         (cond
           [(set-member? emit-source-set source-id)
            (set! emits (add1 emits))
            (define-values (emitted module-artifacts)
              (with-handlers
                  ([(lambda (_value) #t)
                    (lambda (value) (fail source-id 'emit value))])
                ((project-compiler-session-emitter session)
                 module
                 (hash-ref source-index source-id)
                 export-plan
                 (project-compile-profile-v1-nix-module-omit-attrs profile))))
            (unless (string? emitted)
              (fail source-id 'emit "emitter returned a non-string module"))
            (unless
                (and (list? module-artifacts)
                     (andmap project-artifact-v1? module-artifacts)
                     (andmap
                      (lambda (artifact)
                        (and
                         (string? (project-artifact-v1-source-id artifact))
                         (string? (project-artifact-v1-relative-path artifact))
                         (bytes? (project-artifact-v1-bytes artifact))))
                      module-artifacts))
              (fail source-id 'emit "emitter returned malformed artifacts"))
            (hash-set!
             emitted-by-source source-id (string->immutable-string emitted))
            (map freeze-artifact module-artifacts)]
           [else '()]))
       modules))
    (define duplicate-artifact
      (check-duplicates
       artifacts
       string=?
       #:key project-artifact-v1-relative-path))
    (when duplicate-artifact
      (fail
       (project-artifact-v1-source-id duplicate-artifact)
       'emit
       (format
        "duplicate compiler-owned artifact path ~a"
        (project-artifact-v1-relative-path duplicate-artifact))))
    (define result-modules
      (for/list ([module (in-list modules)])
        (define source-id
          (source-id-string (checked-overlay-module-source module)))
        (if (hash-has-key? emitted-by-source source-id)
            (struct-copy
             checked-overlay-module
             module
             [emitted (hash-ref emitted-by-source source-id)])
            module)))
    (define observation (observe 'incremental))
    (define result
      (project-compile-result
       #t snapshot-id result-modules artifacts '() observation))

    ;; This is the only semantic publication point. Candidate cache entries,
    ;; checked Programs, and artifacts remain local until every phase succeeds.
    (set-project-compiler-session-cache!
     session
     (incremental-overlay-check-result-cache incremental))
    (set-project-compiler-session-accepted-request-bytes!
     session exact-request-bytes)
    (set-project-compiler-session-accepted-result! session result)
    (set-project-compiler-session-last-observation! session observation)
    result))

(define (project-compiler-session-compile!
         session
         request
         #:diagnostic-sink [diagnostic-sink void])
  (unless (project-compiler-session? session)
    (raise-argument-error
     'project-compiler-session-compile!
     "project-compiler-session?"
     session))
  (define exact-request-bytes
    (bytes->immutable-bytes (project-request-key request)))
  (call-with-semaphore
   (project-compiler-session-lock session)
   (lambda ()
     (project-compiler-session-compile/locked!
      session exact-request-bytes (lambda () request) 0 diagnostic-sink))))

(define (project-compiler-session-compile/encoded!
         session
         exact-request-bytes
         decode-request
         #:diagnostic-sink [diagnostic-sink void])
  (unless (project-compiler-session? session)
    (raise-argument-error
     'project-compiler-session-compile/encoded!
     "project-compiler-session?"
     session))
  (unless (bytes? exact-request-bytes)
    (raise-argument-error
     'project-compiler-session-compile/encoded!
     "bytes?"
     exact-request-bytes))
  (unless (procedure? decode-request)
    (raise-argument-error
     'project-compiler-session-compile/encoded!
     "procedure?"
     decode-request))
  (define request-bytes
    (bytes->immutable-bytes exact-request-bytes))
  (call-with-semaphore
   (project-compiler-session-lock session)
   (lambda ()
     (project-compiler-session-compile/locked!
      session
      request-bytes
      (lambda () (decode-request request-bytes))
      1
      diagnostic-sink))))

(provide
 (struct-out project-source-v1)
 (struct-out project-compile-profile-v1)
 (struct-out project-compile-request-v1)
 (struct-out project-artifact-v1)
 (struct-out project-compile-counters-v1)
 (struct-out project-compile-observation-v1)
 (struct-out project-compile-result)
 make-project-compiler-session
 project-compiler-session?
 project-compiler-session-last-observation
 project-compiler-session-compile!
 project-compiler-session-compile/encoded!
 emit-project-module)
