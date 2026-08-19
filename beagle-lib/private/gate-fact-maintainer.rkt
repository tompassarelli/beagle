#lang racket/base

;; Shadow-only maintenance and admission for the current Beagle gate.  The old
;; gate remains the execution oracle: coverage is reported, never used to skip.

(require (only-in file/sha1 bytes->hex-string)
         openssl/sha1
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         racket/vector
         "gate-fact-envelope-v1.rkt")

(define-runtime-path PRIVATE-DIRECTORY ".")
(define BEAGLE-ROOT
  (simplify-path (build-path PRIVATE-DIRECTORY 'up 'up)))
(define PREPARED-STATE-FILE "gate-fact-prepared-v1.rktd")

(struct adapter-failure (code message response) #:transparent)
(struct miss-plan (class claim observed-root observed-identities
                         fallback observation-id)
  #:transparent)
(struct coverage-analysis (coverage retained misses attempts) #:transparent)

(define (fail who message . fields)
  (apply raise-arguments-error who message fields))

(define (nonempty-string? value)
  (and (string? value) (not (string=? value ""))))

(define (require-string who label value)
  (unless (nonempty-string? value)
    (fail who "expected a nonempty string" "field" label "value" value))
  value)

(define (vector-map->vector procedure values)
  (list->vector (for/list ([value (in-vector values)]) (procedure value))))

(define (datum->vectors value)
  (cond
    [(vector? value) (vector-map->vector datum->vectors value)]
    [(list? value) (list->vector (map datum->vectors value))]
    [else value]))

(define (read-one-datum in who)
  (define value (read in))
  (when (eof-object? value)
    (raise-user-error who "expected one datum"))
  (unless (eof-object? (read in))
    (raise-user-error who "input contains trailing data"))
  (datum->vectors value))

(define (write-adapter-edn value [out (current-output-port)])
  (cond
    [(eq? value 'nil) (display "nil" out)]
    [(vector? value)
     (display "[" out)
     (for ([item (in-vector value)] [index (in-naturals)])
       (unless (zero? index) (display " " out))
       (write-adapter-edn item out))
     (display "]" out)]
    [(or (string? value) (exact-integer? value))
     (write-canonical-edn value out)]
    [else
     (raise-arguments-error
      'write-adapter-edn
      "value is outside the Store adapter EDN vocabulary"
      "value" value)]))

(define (canonical-adapter-edn-string value)
  (call-with-output-string (lambda (out) (write-adapter-edn value out))))

(define (command-tokens repository-root)
  (define configured (getenv "BEAGLE_GATE_FACT_STORE_COMMAND"))
  (if (and configured (not (string=? configured "")))
      (string-split configured)
      (list "bb"
            "-cp"
            (string-append
             (path->string (build-path BEAGLE-ROOT "store" "out"))
             ":"
             (path->string (build-path BEAGLE-ROOT "store")))
            "-m"
            "store.gate-facts")))

(define (invoke-adapter repository-root command request)
  (define tokens (command-tokens repository-root))
  (define executable
    (or (find-executable-path (car tokens))
        (and (absolute-path? (string->path (car tokens)))
             (string->path (car tokens)))
        (raise-user-error 'gate-fact-maintainer
                          "Store adapter executable is unavailable: ~a"
                          (car tokens))))
  (define environment (environment-variables-copy
                       (current-environment-variables)))
  (environment-variables-set! environment
                              #"BEAGLE_STORE_TELEMETRY_LOG" #f)
  (define-values (process stdout stdin stderr)
    (parameterize ([current-directory repository-root]
                   [current-environment-variables environment])
      (apply subprocess #f #f #f executable
             (append (cdr tokens) (list command)))))
  (display (canonical-adapter-edn-string request) stdin)
  (newline stdin)
  (close-output-port stdin)
  (define output (port->string stdout))
  (define error-output (port->string stderr))
  (close-input-port stdout)
  (close-input-port stderr)
  (subprocess-wait process)
  (define status (subprocess-status process))
  (define response
    (with-handlers ([exn:fail?
                     (lambda (_error)
                       (vector "store.gate-facts/error-v1"
                               "malformed-adapter-response"
                               (string-trim output)))])
      (read-one-datum (open-input-string output) 'gate-fact-store)))
  (if (zero? status)
      (begin
        (unless (and (vector? response)
                     (= (vector-length response) 7)
                     (equal? (vector-ref response 0)
                             "store.gate-facts/response-v1")
                     (equal? (vector-ref response 1) "ok"))
          (raise-user-error 'gate-fact-maintainer
                            "Store adapter returned malformed success: ~v"
                            response))
        response)
      (let ([code
             (if (and (vector? response)
                      (>= (vector-length response) 3)
                      (equal? (vector-ref response 0)
                              "store.gate-facts/error-v1"))
                 (format "~a" (vector-ref response 1))
                 "adapter-failed")]
            [message
             (if (and (vector? response) (>= (vector-length response) 3))
                 (format "~a" (vector-ref response 2))
                 (string-trim error-output))])
        (raise (adapter-failure code message response)))))

(define (adapter-request tag store-path base-commit candidate-root . tail)
  (list->vector (append (list tag store-path base-commit candidate-root) tail)))

(define (adapter-import repository-root store-path base-commit candidate-root
                        envelopes)
  (invoke-adapter
   repository-root
   "import"
   (adapter-request "store.gate-facts/import-v1"
                    store-path base-commit candidate-root
                    (list->vector (map gate-fact-entry-v1 envelopes)))))

(define (adapter-record-miss repository-root store-path base-commit
                             candidate-root miss-envelope)
  (invoke-adapter
   repository-root
   "record-miss"
   (adapter-request "store.gate-facts/record-miss-v1"
                    store-path base-commit candidate-root
                    (gate-fact-entry-v1 miss-envelope))))

(define (adapter-record-observation repository-root store-path base-commit
                                    candidate-root observation-envelope
                                    miss-fact-id)
  (invoke-adapter
   repository-root
   "record-observation"
   (adapter-request "store.gate-facts/record-observation-v1"
                    store-path base-commit candidate-root
                    (gate-fact-entry-v1 observation-envelope)
                    (or miss-fact-id 'nil))))

(define (adapter-finalize repository-root store-path base-commit candidate-root
                          verdict receipt miss-fact-links)
  (invoke-adapter
   repository-root
   "finalize"
   (adapter-request "store.gate-facts/finalize-v1"
                    store-path base-commit candidate-root
                    (gate-fact-entry-v1 verdict)
                    (gate-fact-entry-v1 receipt)
                    miss-fact-links)))

(define (adapter-cold-query repository-root store-path base-commit candidate-root)
  (invoke-adapter
   repository-root
   "cold-query"
   (adapter-request "store.gate-facts/cold-query-v1"
                    store-path base-commit candidate-root #())))

(define (run-command/bytes repository-root executable arguments)
  (define-values (process stdout stdin stderr)
    (parameterize ([current-directory repository-root])
      (apply subprocess #f #f #f executable arguments)))
  (close-output-port stdin)
  (define output (port->bytes stdout))
  (define error-output (port->string stderr))
  (close-input-port stdout)
  (close-input-port stderr)
  (subprocess-wait process)
  (unless (zero? (subprocess-status process))
    (raise-user-error 'gate-fact-maintainer
                      "command failed: ~a ~a: ~a"
                      executable
                      (string-join arguments " ")
                      (string-trim error-output)))
  output)

(define (git-output repository-root . arguments)
  (define git
    (or (find-executable-path "git")
        (raise-user-error 'gate-fact-maintainer "git is unavailable")))
  (run-command/bytes repository-root git arguments))

(define (sha256-bytes-prefixed value)
  (string-append "sha256:" (bytes->hex-string (sha256-bytes value))))

(define (source-entry repository-root logical-path)
  (define physical-path (build-path repository-root logical-path))
  (define content (file->bytes physical-path))
  (vector logical-path
          (bytes-length content)
          (sha256-bytes-prefixed content)))

(define (derive-candidate-v1 repository-root base-commit)
  (define who 'derive-candidate-v1)
  (unless (directory-exists? repository-root)
    (fail who "repository root is not a directory"
          "repository-root" repository-root))
  (define repository-revision
    (string-trim
     (bytes->string/utf-8
      (git-output repository-root "rev-parse" "HEAD"))))
  (define listed
    (bytes->string/utf-8 (git-output repository-root "ls-files" "-z")))
  (define logical-paths
    (sort
     (for/list ([path (in-list (string-split listed "\0" #:trim? #f))]
                #:when (and (not (string=? path ""))
                            (file-exists? (build-path repository-root path))))
       path)
     string<?))
  (define selected-files
    (list->vector
     (for/list ([path (in-list logical-paths)])
       (source-entry repository-root path))))
  (define byte-total
    (for/sum ([entry (in-vector selected-files)]) (vector-ref entry 1)))
  (define source-roots #("."))
  (define importer "git-tracked-gate-input-v1")
  (define profile "active-only-shadow-v1")
  (define candidate-root
    (sha256-string
     (canonical-edn-string
      (vector "GateCandidateIdentityV1"
              base-commit
              repository-revision
              importer
              profile
              source-roots
              selected-files
              (vector-length selected-files)
              byte-total))))
  (make-gate-candidate-v1
   candidate-root
   base-commit
   repository-revision
   importer
   profile
   source-roots
   selected-files
   (vector-length selected-files)
   byte-total))

(define (read-key/value-file path expected-version)
  (define lines (file->lines path))
  (unless (and (pair? lines) (equal? (car lines) expected-version))
    (raise-user-error 'gate-fact-maintainer
                      "~a has no ~a header" path expected-version))
  (for/hash ([line (in-list (cdr lines))])
    (define match (regexp-match #px"^([^=]+)=(.*)$" line))
    (unless match
      (raise-user-error 'gate-fact-maintainer
                        "~a contains malformed key/value line: ~a" path line))
    (values (cadr match) (caddr match))))

(define (hash-exact-keys who values wanted path)
  (define actual (sort (hash-keys values) string<?))
  (define expected (sort wanted string<?))
  (unless (equal? actual expected)
    (fail who "raw observation keys do not match the V1 contract"
          "path" path "expected" expected "actual" actual)))

(define (semantic-id label fields)
  (string-append label ":" (substring (sha256-string
                                        (canonical-edn-string fields))
                                       7)))

(define (phase-claim-from-file path candidate-root verifier policy)
  (define raw (read-key/value-file path "beagle-gate-phase-claim-v1"))
  (hash-exact-keys 'phase-claim-from-file raw
                   '("label" "deadline-seconds" "command-sha256") path)
  (define label (hash-ref raw "label"))
  (define command-sha256 (hash-ref raw "command-sha256"))
  (define deadline (hash-ref raw "deadline-seconds"))
  (unless (regexp-match? #px"^[0-9]+$" deadline)
    (raise-user-error 'gate-fact-maintainer
                      "~a has an invalid deadline-seconds" path))
  (define dependencies (vector (string-append "deadline-seconds:" deadline)))
  (define claim-id
    (semantic-id
     "claim-v1"
     (vector candidate-root "phase" label command-sha256 candidate-root
             verifier policy dependencies)))
  (make-gate-phase-claim-v1
   claim-id candidate-root "phase" label command-sha256 candidate-root
   verifier policy dependencies))

(define (read-one-file-datum path)
  (call-with-input-file path
    (lambda (in) (read-one-datum in 'gate-fact-maintainer))))

(define (phase-name->string phase)
  (cond
    [(string? phase) phase]
    [(eq? phase 'residual) "residual"]
    [(eq? phase #f) "whole-file"]
    [else
     (raise-user-error 'gate-fact-maintainer
                       "tier claim has invalid phase: ~v" phase)]))

(define (tier-claims-from-file path candidate-root verifier policy)
  (define raw (read-one-file-datum path))
  (unless (and (vector? raw)
               (= (vector-length raw) 4)
               (eq? (vector-ref raw 0) 'beagle-tier-claims-v1))
    (raise-user-error 'gate-fact-maintainer
                      "~a is not beagle-tier-claims-v1" path))
  (define claims '())
  (for ([index (in-range 1 (vector-length raw))])
    (define section (vector-ref raw index))
    (unless (and (vector? section) (= (vector-length section) 2)
                 (symbol? (vector-ref section 0))
                 (vector? (vector-ref section 1)))
      (raise-user-error 'gate-fact-maintainer
                        "~a contains a malformed tier claim section" path))
    (define tier (symbol->string (vector-ref section 0)))
    ;; The current default authoritative gate runs active units only.
    (when (string=? tier "active")
      (for ([entry (in-vector (vector-ref section 1))])
        (match entry
          [(vector (? string? label) (? string? file) phase)
           (define phase-name (phase-name->string phase))
           (define command-sha256
             (sha256-string
              (canonical-edn-string
               (vector "TierUnitCommandV1" file phase-name))))
           (define dependencies
             (vector (string-append "tier:" tier)
                     (string-append "source:" file)
                     (string-append "phase:" phase-name)))
           (define claim-id
             (semantic-id
              "claim-v1"
              (vector candidate-root "tier-unit" label command-sha256
                      candidate-root verifier policy dependencies)))
           (set! claims
                 (cons
                  (make-gate-phase-claim-v1
                   claim-id candidate-root "tier-unit" label command-sha256
                   candidate-root verifier policy dependencies)
                  claims))]
          [_
           (raise-user-error 'gate-fact-maintainer
                             "~a contains a malformed tier claim: ~v"
                             path entry)]))))
  (reverse claims))

(define (raw-claims raw-directory candidate-root verifier policy)
  (define phase-paths
    (sort
     (for/list ([path (in-list (directory-list raw-directory #:build? #t))]
                #:when (regexp-match? #px"^phase-.*[.]claim$"
                                      (path->string (file-name-from-path path))))
       path)
     string<? #:key path->string))
  (define tier-path (build-path raw-directory "tier-claims.rktd"))
  (unless (file-exists? tier-path)
    (raise-user-error 'gate-fact-maintainer
                      "missing pre-run tier claims: ~a" tier-path))
  (append
   (for/list ([path (in-list phase-paths)])
     (phase-claim-from-file path candidate-root verifier policy))
   (tier-claims-from-file tier-path candidate-root verifier policy)))

(define (claim-key claim)
  (cons (vector-ref claim 3) (vector-ref claim 4)))

(define (entry->envelope entry)
  (unless (and (vector? entry) (= (vector-length entry) 3)
               (string? (vector-ref entry 0))
               (string? (vector-ref entry 1))
               (string? (vector-ref entry 2)))
    (raise-user-error 'gate-fact-maintainer
                      "Store returned malformed fact entry: ~v" entry))
  (define envelope
    (read-one-datum (open-input-string (vector-ref entry 2))
                    'gate-fact-maintainer))
  (unless (equal? (canonical-edn-string envelope) (vector-ref entry 2))
    (raise-user-error 'gate-fact-maintainer
                      "Store returned noncanonical envelope bytes"))
  envelope)

(define (response-envelopes response)
  (for/list ([entry (in-vector (vector-ref response 4))])
    (cons entry (entry->envelope entry))))

(define (verdict-covers? verdict claim observation verifier policy)
  (and (equal? (vector-ref verdict 0) "GateCandidateVerdictV1")
       (equal? (vector-ref verdict 3) "ADMITTED")
       (equal? (vector-ref verdict 4) "PASS")
       (equal? (vector-ref verdict 6) verifier)
       (equal? (vector-ref verdict 7) policy)
       (for/or ([link (in-vector (vector-ref verdict 8))])
         (and (equal? (vector-ref link 0) (vector-ref claim 1))
              (equal? (vector-ref link 1) (vector-ref observation 1))))))

(define (analyze-coverage response current-claims verifier policy
                          #:inject-unknown? [inject-unknown? #f])
  (define observed-root (vector-ref response 3))
  (define pairs (response-envelopes response))
  (define unknown?
    (or inject-unknown?
        (for/or ([pair (in-list pairs)])
          (not (member (vector-ref (car pair) 1) GATE-FACT-KINDS-V1)))))
  (define stored-claims
    (for/list ([pair (in-list pairs)]
               #:when (equal? (vector-ref (cdr pair) 0)
                              "GatePhaseClaimV1"))
      (cdr pair)))
  (define observations
    (for/list ([pair (in-list pairs)]
               #:when (equal? (vector-ref (cdr pair) 0)
                              "GatePhaseObservationV1"))
      (cdr pair)))
  (define verdicts
    (for/list ([pair (in-list pairs)]
               #:when (equal? (vector-ref (cdr pair) 0)
                              "GateCandidateVerdictV1"))
      (cdr pair)))
  (define retained 0)
  (define misses '())
  (define attempts (make-hash))
  (define stored-policy-substitution
    (getenv "BEAGLE_GATE_FACT_STORED_POLICY"))
  (define omitted-dependency-substitution
    (getenv "BEAGLE_GATE_FACT_OMIT_DEPENDENCY"))
  (for ([claim (in-list current-claims)] [index (in-naturals)])
    (define claim-id (vector-ref claim 1))
    (define claim-observations
      (filter (lambda (observation)
                (equal? (vector-ref observation 2) claim-id))
              observations))
    (define next-attempt
      (add1
       (for/fold ([maximum 0]) ([observation (in-list claim-observations)])
         (max maximum (vector-ref observation 3)))))
    (hash-set! attempts claim-id next-attempt)
    (define planned-observation-id
      (semantic-id "observation-v1"
                   (vector claim-id next-attempt "shadow-old-gate")))
    (define matching
      (findf (lambda (stored) (equal? (claim-key stored) (claim-key claim)))
             stored-claims))
    (define class
      (cond
        [(and unknown? (zero? index)) "unknown-fact-kind"]
        [(and stored-policy-substitution
              (not (string=? stored-policy-substitution "")))
         "stale"]
        [(and omitted-dependency-substitution
              (member omitted-dependency-substitution
                      (vector->list (vector-ref claim 9))))
         "omitted-dependency"]
        [(not matching) "absent"]
        [(not (equal? (vector-ref matching 8) policy)) "stale"]
        [(for/or ([dependency (in-vector (vector-ref claim 9))])
           (not (member dependency
                        (vector->list (vector-ref matching 9)))))
         "omitted-dependency"]
        [(not (equal? matching claim)) "stale"]
        [(for/or ([observation (in-list claim-observations)])
           (not (equal? (vector-ref observation 4) "PASS")))
         "inadmissible"]
        [(for/or ([observation (in-list claim-observations)])
           (for/or ([verdict (in-list verdicts)])
             (verdict-covers? verdict claim observation verifier policy)))
         #f]
        [else "absent"]))
    (if class
        (set! misses
              (cons (miss-plan class claim observed-root
                               (vector (vector "scope" (vector-ref claim 3))
                                       (vector "label" (vector-ref claim 4)))
                               "run-old-gate"
                               planned-observation-id)
                    misses))
        (set! retained (add1 retained))))
  (coverage-analysis
   (if (null? misses) "FULL" "INCOMPLETE")
   retained
   (reverse misses)
   attempts))

(define (route-miss-analysis current-claims)
  (define attempts (make-hash))
  (define misses
    (for/list ([claim (in-list current-claims)])
      (define claim-id (vector-ref claim 1))
      (define observation-id
        (semantic-id "observation-v1"
                     (vector claim-id 1 "shadow-old-gate")))
      (hash-set! attempts claim-id 1)
      (miss-plan "route-unresolved" claim "" #()
                 "run-old-gate" observation-id)))
  (coverage-analysis "INCOMPLETE" 0 misses attempts))

(define (stored-claim claim)
  (define stored-policy (getenv "BEAGLE_GATE_FACT_STORED_POLICY"))
  (define omitted (getenv "BEAGLE_GATE_FACT_OMIT_DEPENDENCY"))
  (define dependencies
    (if (and omitted (not (string=? omitted "")))
        (list->vector
         (filter (lambda (dependency) (not (equal? dependency omitted)))
                 (vector->list (vector-ref claim 9))))
        (vector-ref claim 9)))
  (make-gate-phase-claim-v1
   (vector-ref claim 1)
   (vector-ref claim 2)
   (vector-ref claim 3)
   (vector-ref claim 4)
   (vector-ref claim 5)
   (vector-ref claim 6)
   (vector-ref claim 7)
   (if (and stored-policy (not (string=? stored-policy "")))
       stored-policy
       (vector-ref claim 8))
   dependencies))

(define (miss-envelope query-id candidate-root verifier policy plan)
  (define claim (miss-plan-claim plan))
  (define miss-id
    (semantic-id
     "miss-v1"
     (vector query-id
             (miss-plan-class plan)
             (vector-ref claim 1)
             (miss-plan-observation-id plan))))
  (make-fact-miss-event-v1
   miss-id query-id candidate-root (miss-plan-observed-root plan)
   (miss-plan-class plan) (miss-plan-observed-identities plan)
   verifier policy (miss-plan-fallback plan) (vector-ref claim 1)
   (miss-plan-observation-id plan)))

(define (write-state! raw-directory state)
  (call-with-output-file (build-path raw-directory PREPARED-STATE-FILE)
    #:exists 'truncate
    (lambda (out) (write state out) (newline out))))

(define (read-state raw-directory)
  (read-one-file-datum (build-path raw-directory PREPARED-STATE-FILE)))

(define (miss-class-summary misses)
  (if (null? misses)
      "none"
      (string-join
       (remove-duplicates (map miss-plan-class misses)) ",")))

(define (shadow-prepare store-path query-store-path base-commit repository-root
                        policy verifier raw-directory)
  (for ([field (in-list
                `((store-path . ,store-path)
                  (query-store-path . ,query-store-path)
                  (base-commit . ,base-commit)
                  (policy . ,policy)
                  (verifier . ,verifier)))])
    (require-string 'shadow-prepare (car field) (cdr field)))
  (define repository-path (path->complete-path repository-root))
  (define raw-path (path->complete-path raw-directory))
  (define candidate (derive-candidate-v1 repository-path base-commit))
  (define candidate-root (vector-ref candidate 1))
  (define claims (raw-claims raw-path candidate-root verifier policy))
  (when (null? claims)
    (raise-user-error 'gate-fact-maintainer
                      "shadow preparation discovered zero gate claims"))
  (adapter-import repository-path store-path base-commit candidate-root
                  (cons candidate (map stored-claim claims)))
  (define query-id
    (semantic-id "query-v1"
                 (vector candidate-root verifier policy "cold-coverage")))
  (define analysis
    (with-handlers ([adapter-failure?
                     (lambda (_failure) (route-miss-analysis claims))])
      (analyze-coverage
       (adapter-cold-query repository-path query-store-path base-commit
                           candidate-root)
       claims verifier policy
       #:inject-unknown?
       (equal? (getenv "BEAGLE_GATE_FACT_QUERY_INJECT_UNKNOWN_KIND") "1"))))
  (define durable-misses '())
  (for ([plan (in-list (coverage-analysis-misses analysis))])
    (define envelope
      (miss-envelope query-id candidate-root verifier policy plan))
    ;; This subprocess must complete before shadow-prepare returns and before
    ;; the caller starts the conservative old gate.
    (adapter-record-miss repository-path store-path base-commit candidate-root
                         envelope)
    (set! durable-misses
          (cons (vector (vector-ref (miss-plan-claim plan) 1)
                        (gate-fact-envelope-v1-id envelope)
                        (miss-plan-observation-id plan)
                        (miss-plan-class plan))
                durable-misses)))
  (define state
    (vector "GateFactPreparedStateV1"
            candidate
            (list->vector claims)
            (list->vector (reverse durable-misses))
            (list->vector
             (sort (hash->list (coverage-analysis-attempts analysis))
                   string<? #:key car))
            (coverage-analysis-retained analysis)
            query-id
            verifier
            policy))
  (write-state! raw-path state)
  (eprintf "gate-facts: PREPARED misses=~a retained=~a rechecked=~a\n"
           (miss-class-summary (coverage-analysis-misses analysis))
           (coverage-analysis-retained analysis)
           (length claims))
  (vector "GateFactMaintainerResultV1"
          "shadow-prepare"
          candidate-root
          "durable"
          (list->vector
           (map (lambda (value) (vector-ref value 1))
                (reverse durable-misses)))
          (coverage-analysis-coverage analysis)))

(define (status-string raw-status)
  (define normalized
    (string-upcase (if (symbol? raw-status)
                       (symbol->string raw-status)
                       (format "~a" raw-status))))
  (cond
    [(member normalized GATE-OBSERVATION-STATUSES-V1) normalized]
    [(equal? normalized "ERROR") "INFRA-ERROR"]
    [(equal? normalized "SKIP") "NOT-RUN"]
    ;; A unit killed at its deadline never finished, so in this vocabulary it is
    ;; NOT-RUN. It is emphatically not FAIL: nothing observed the code.
    [(equal? normalized "DIAGNOSTIC") "NOT-RUN"]
    [else
     (raise-user-error 'gate-fact-maintainer
                       "unknown gate observation status: ~a" raw-status)]))

(define (phase-observations raw-directory)
  (for/hash
      ([path (in-list (directory-list raw-directory #:build? #t))]
       #:when (regexp-match? #px"^phase-.*[.]observation$"
                             (path->string (file-name-from-path path))))
    (define raw
      (read-key/value-file path "beagle-gate-phase-observation-v1"))
    (hash-exact-keys
     'phase-observations raw
     '("label" "completion" "exit-code" "log-sha256" "receipt-sha256")
     path)
    (define label (hash-ref raw "label"))
    (define exit-code (string->number (hash-ref raw "exit-code")))
    (unless (exact-integer? exit-code)
      (raise-user-error 'gate-fact-maintainer
                        "~a has invalid exit-code" path))
    (define completion (hash-ref raw "completion"))
    (define status
      (cond
        [(not (member completion '("exit" "complete" "completed")))
         "INFRA-ERROR"]
        [(zero? exit-code) "PASS"]
        [(= exit-code 1) "FAIL"]
        [else "INFRA-ERROR"]))
    (values label
            (vector status exit-code 0 0 completion
                    (hash-ref raw "log-sha256")
                    (hash-ref raw "receipt-sha256")))))

(define (tier-observations path)
  (define raw (read-one-file-datum path))
  (unless (and (vector? raw) (= (vector-length raw) 4)
               (eq? (vector-ref raw 0) 'beagle-tier-observations-v1))
    (raise-user-error 'gate-fact-maintainer
                      "~a is not beagle-tier-observations-v1" path))
  (define table (make-hash))
  (for ([index (in-range 1 (vector-length raw))])
    (define section (vector-ref raw index))
    (unless (and (vector? section) (= (vector-length section) 3)
                 (symbol? (vector-ref section 0))
                 (vector? (vector-ref section 1))
                 (vector? (vector-ref section 2)))
      (raise-user-error 'gate-fact-maintainer
                        "~a contains malformed tier observations" path))
    (when (eq? (vector-ref section 0) 'active)
      (define expected (vector->list (vector-ref section 1)))
      (define observed-labels '())
      (for ([entry (in-vector (vector-ref section 2))])
        (match entry
          [(vector (? string? label) raw-status
                   (? exact-nonnegative-integer? passed)
                   (? exact-nonnegative-integer? total)
                   cached?)
           (unless (boolean? cached?)
             (raise-user-error 'gate-fact-maintainer
                               "tier cached field is not boolean: ~v" entry))
           (set! observed-labels (cons label observed-labels))
           (hash-set!
            table label
            (vector (status-string raw-status)
                    (if (equal? (status-string raw-status) "PASS") 0 1)
                    passed total
                    (if cached? "cached-result" "completed")
                    (sha256-string (canonical-edn-string
                                    (vector label
                                            (status-string raw-status)
                                            passed total)))
                    (sha256-string (canonical-edn-string
                                    (vector "TierUnitReceiptV1" label)))))]
          [_
           (raise-user-error 'gate-fact-maintainer
                             "malformed tier observation: ~v" entry)]))
      (unless (equal? (sort expected string<?)
                      (sort observed-labels string<?))
        (raise-user-error 'gate-fact-maintainer
                          "tier observations do not cover the expected unit set"))))
  table)

(define (observation-table raw-directory)
  (define table (make-hash))
  (for ([(label value) (in-hash (phase-observations raw-directory))])
    (hash-set! table label value))
  (define tier-path (build-path raw-directory "tier-units.rktd"))
  (cond
    [(file-exists? tier-path)
     (for ([(label value) (in-hash (tier-observations tier-path))])
       (when (hash-has-key? table label)
         (raise-user-error 'gate-fact-maintainer
                           "duplicate gate observation label: ~a" label))
       (hash-set! table label value))]
    ;; If the tier-runner phase itself produced an observation, it started but
    ;; failed before publishing its exact unit set.  Every planned unit is an
    ;; infrastructure/error observation.  If the phase never started, absent
    ;; unit observations remain NOT-RUN below.
    [(hash-has-key? table "tier-runner")
     (hash-set!
      table '#%tier-default
      (vector "INFRA-ERROR" 2 0 0 "tier-observations-missing"
              (sha256-string "tier-observations-missing")
              (sha256-string "tier-observations-missing-receipt")))])
  table)

(define (count-table-vector keys values)
  (list->vector
   (for/list ([key (in-list keys)])
     (vector key (count (lambda (value) (equal? value key)) values)))))

(define (final-status statuses final-exit)
  (cond
    [(member "INFRA-ERROR" statuses) "INFRA-ERROR"]
    [(member "FAIL" statuses) "FAIL"]
    [(member "FLAKY" statuses) "FLAKY"]
    [(member "NOT-RUN" statuses) "NOT-RUN"]
    [(zero? final-exit) "PASS"]
    [else "FAIL"]))

(define (shadow-finish store-path base-commit repository-root policy verifier
                       raw-directory final-exit)
  (define repository-path (path->complete-path repository-root))
  (define raw-path (path->complete-path raw-directory))
  (define state (read-state raw-path))
  (unless (and (vector? state) (= (vector-length state) 9)
               (equal? (vector-ref state 0) "GateFactPreparedStateV1"))
    (raise-user-error 'gate-fact-maintainer
                      "prepared state is missing or malformed"))
  (define candidate (vector-ref state 1))
  (define candidate-root (vector-ref candidate 1))
  (define claims (vector->list (vector-ref state 2)))
  (define prepared-misses (vector->list (vector-ref state 3)))
  (define attempts (make-hash (vector->list (vector-ref state 4))))
  (define retained (vector-ref state 5))
  (unless (and (equal? verifier (vector-ref state 7))
               (equal? policy (vector-ref state 8)))
    (raise-user-error 'gate-fact-maintainer
                      "finish verifier/policy differs from preparation"))
  (define raw-observations (observation-table raw-path))
  (define miss-by-claim
    (for/hash ([entry (in-list prepared-misses)])
      (values (vector-ref entry 0) entry)))
  (define observation-envelopes '())
  (define semantic-links '())
  (define fact-links '())
  (for ([claim (in-list claims)])
    (define label (vector-ref claim 4))
    (define claim-id (vector-ref claim 1))
    (define raw
      (hash-ref raw-observations label
                (lambda ()
                  (if (and (equal? (vector-ref claim 3) "tier-unit")
                           (hash-has-key? raw-observations '#%tier-default))
                      (hash-ref raw-observations '#%tier-default)
                      (vector "NOT-RUN" 0 0 0 "not-run"
                              (sha256-string label)
                              (sha256-string
                               (string-append "not-run:" label)))))))
    (define observation-id
      (let ([prepared (hash-ref miss-by-claim claim-id #f)])
        (if prepared
            (vector-ref prepared 2)
            (semantic-id "observation-v1"
                         (vector claim-id (hash-ref attempts claim-id)
                                 "shadow-old-gate")))))
    (define observation
      (make-gate-phase-observation-v1
       observation-id claim-id (hash-ref attempts claim-id)
       (vector-ref raw 0) (vector-ref raw 1)
       (vector-ref raw 2) (vector-ref raw 3)
       (vector-ref raw 4) (vector-ref raw 5) (vector-ref raw 6)))
    (define miss (hash-ref miss-by-claim claim-id #f))
    (adapter-record-observation
     repository-path store-path base-commit candidate-root observation
     (and miss (vector-ref miss 1)))
    (set! observation-envelopes (cons observation observation-envelopes))
    (set! semantic-links
          (cons (vector claim-id observation-id) semantic-links))
    (when miss
      (set! fact-links
            (cons (vector (vector-ref miss 1)
                          (gate-fact-envelope-v1-id observation))
                  fact-links))))
  (set! observation-envelopes (reverse observation-envelopes))
  (set! semantic-links (reverse semantic-links))
  (set! fact-links (reverse fact-links))
  (define statuses
    (map (lambda (observation) (vector-ref observation 4))
         observation-envelopes))
  (define aggregate-status (final-status statuses final-exit))
  (define verdict-id
    (semantic-id "verdict-v1"
                 (vector candidate-root aggregate-status final-exit
                         verifier policy (list->vector semantic-links))))
  (define verdict
    (make-gate-candidate-verdict-v1
     verdict-id candidate-root "ADMITTED" aggregate-status final-exit
     verifier policy (list->vector semantic-links)
     "shadow observations admitted; old gate remains authoritative"))
  ;; Finalization accounts for every immutable miss already present for this
  ;; exact candidate, including misses from an earlier cold/recheck run.  The
  ;; adapter refuses a receipt that silently forgets historical fallback links.
  (define before-finalize
    (adapter-cold-query repository-path store-path base-commit candidate-root))
  (define durable-fact-links
    (vector->list (vector-ref before-finalize 5)))
  (for ([link (in-list fact-links)])
    (unless (member link durable-fact-links)
      (raise-user-error 'gate-fact-maintainer
                        "fallback observation link is not cold-durable: ~v"
                        link)))
  (define durable-miss-envelopes
    (for/list ([pair (in-list (response-envelopes before-finalize))]
               #:when (equal? (vector-ref (cdr pair) 0) "FactMissEventV1"))
      (cdr pair)))
  (define miss-classes
    (map (lambda (miss) (vector-ref miss 5)) durable-miss-envelopes))
  (define current-miss-classes
    (map (lambda (entry) (vector-ref entry 3)) prepared-misses))
  (define receipt-id
    (semantic-id "receipt-v1"
                 (vector candidate-root verdict-id
                         (list->vector durable-fact-links))))
  (define receipt
    (make-gate-maintenance-receipt-v1
     receipt-id candidate-root verdict-id
     (list->vector (map (lambda (claim) (vector-ref claim 1)) claims))
     (list->vector
      (map (lambda (observation) (vector-ref observation 1))
           observation-envelopes))
     (list->vector durable-fact-links)
     (count-table-vector GATE-OBSERVATION-STATUSES-V1 statuses)
     (count-table-vector FACT-MISS-CLASSES-V1 miss-classes)
     retained
     (length claims)
     (length durable-fact-links)))
  (define finalized
    (adapter-finalize repository-path store-path base-commit candidate-root
                      verdict receipt (list->vector durable-fact-links)))
  ;; A separate adapter process proves the persisted exact candidate is cold
  ;; readable; no in-memory response from finalize is accepted as coverage.
  (define cold (adapter-cold-query repository-path store-path base-commit
                                   candidate-root))
  (define coverage
    (analyze-coverage
     cold claims verifier policy
     #:inject-unknown?
     (equal? (getenv "BEAGLE_GATE_FACT_QUERY_INJECT_UNKNOWN_KIND") "1")))
  (define final-coverage
    (if (and (equal? aggregate-status "PASS")
             (equal? (coverage-analysis-coverage coverage) "FULL"))
        "FULL"
        "INCOMPLETE"))
  (eprintf "gate-facts: FINISHED misses=~a retained=~a rechecked=~a coverage=~a\n"
           (if (null? current-miss-classes)
               "none"
               (string-join (remove-duplicates current-miss-classes) ","))
           retained
           (length claims)
           final-coverage)
  (vector "GateFactMaintainerResultV1"
          "shadow-finish"
          candidate-root
          (vector-ref finalized 3)
          (vector (gate-fact-envelope-v1-id verdict)
                  (gate-fact-envelope-v1-id receipt))
          final-coverage))

(define (dispatch-low-level command request repository-root)
  (match* (command request)
    [("import"
      (vector "GateFactImportRequestV1" store base candidate claims))
     (validate-gate-fact-envelope-v1 candidate)
     (unless (and (vector? claims)
                  (for/and ([claim (in-vector claims)])
                    (equal? (gate-fact-envelope-v1-kind claim)
                            "GatePhaseClaimV1")))
       (raise-user-error 'gate-fact-maintainer
                         "import claims are malformed"))
     (define root (vector-ref candidate 1))
     (define response
       (adapter-import repository-root store base root
                       (cons candidate (vector->list claims))))
     (vector "GateFactMaintainerResultV1" command root
             (vector-ref response 3)
             (vector-map->vector gate-fact-envelope-v1-id
                                 (vector-append (vector candidate) claims))
             "SHADOW")]
    [("record-miss"
      (vector "GateFactMissRequestV1" store base miss))
     (unless (equal? (gate-fact-envelope-v1-kind miss) "FactMissEventV1")
       (raise-user-error 'gate-fact-maintainer "expected FactMissEventV1"))
     (define root (vector-ref miss 3))
     (define response
       (adapter-record-miss repository-root store base root miss))
     (vector "GateFactMaintainerResultV1" command root
             (vector-ref response 3)
             (vector (gate-fact-envelope-v1-id miss))
             "SHADOW")]
    [("record-observation"
      (vector "GateFactObservationRequestV1" store base root observation
              miss-id))
     (unless (equal? (gate-fact-envelope-v1-kind observation)
                     "GatePhaseObservationV1")
       (raise-user-error 'gate-fact-maintainer
                         "expected GatePhaseObservationV1"))
     (define response
       (adapter-record-observation repository-root store base root observation
                                   (and (nonempty-string? miss-id) miss-id)))
     (vector "GateFactMaintainerResultV1" command root
             (vector-ref response 3)
             (vector (gate-fact-envelope-v1-id observation))
             "SHADOW")]
    [("finalize"
      (vector "GateFactFinalizeRequestV1" store base root verdict receipt links))
     (define response
       (adapter-finalize repository-root store base root verdict receipt links))
     (vector "GateFactMaintainerResultV1" command root
             (vector-ref response 3)
             (vector (gate-fact-envelope-v1-id verdict)
                     (gate-fact-envelope-v1-id receipt))
             "SHADOW")]
    [("cold-query"
      (vector "GateFactColdQueryRequestV1" store query-store base root
              query-id verifier policy claims fallbacks))
     (unless (and (vector? claims) (vector? fallbacks))
       (raise-user-error 'gate-fact-maintainer
                         "cold-query claims and fallbacks must be vectors"))
     (define analysis
       (with-handlers ([adapter-failure?
                        (lambda (_failure)
                          (route-miss-analysis (vector->list claims)))])
         (analyze-coverage
          (adapter-cold-query repository-root query-store base root)
          (vector->list claims) verifier policy)))
     (define fallback-by-claim
       (for/hash ([fallback (in-vector fallbacks)])
         (match fallback
           [(vector (? nonempty-string? claim-id)
                    (? nonempty-string? observation-id)
                    (? nonempty-string? fallback-name))
            (values claim-id (vector observation-id fallback-name))]
           [_
            (raise-user-error 'gate-fact-maintainer
                              "malformed cold-query fallback: ~v" fallback)])))
     (define miss-fact-ids
       (for/list ([plan (in-list (coverage-analysis-misses analysis))])
         (define claim (miss-plan-claim plan))
         (define fallback
           (hash-ref fallback-by-claim (vector-ref claim 1)
                     (lambda ()
                       (raise-user-error
                        'gate-fact-maintainer
                        "cold-query miss has no declared fallback for claim ~a"
                        (vector-ref claim 1)))))
         (define declared-plan
           (miss-plan (miss-plan-class plan)
                      claim
                      (miss-plan-observed-root plan)
                      (miss-plan-observed-identities plan)
                      (vector-ref fallback 1)
                      (vector-ref fallback 0)))
         (define envelope
           (miss-envelope query-id root verifier policy declared-plan))
         ;; A cold-query miss is not returned until its diagnostic event is a
         ;; completed durable Store append.
         (adapter-record-miss repository-root store base root envelope)
         (gate-fact-envelope-v1-id envelope)))
     (vector "GateFactMaintainerResultV1" command root "cold"
             (list->vector miss-fact-ids)
             (coverage-analysis-coverage analysis))]
    [(_ _)
     (raise-user-error 'gate-fact-maintainer
                       "request does not match command ~a" command)]))

(define (write-result result)
  (write result)
  (newline))

(module+ main
  (define arguments (vector->list (current-command-line-arguments)))
  (with-handlers
      ([adapter-failure?
        (lambda (failure)
          (eprintf "gate-facts: Store adapter failed class=~a message=~a\n"
                   (adapter-failure-code failure)
                   (adapter-failure-message failure))
          (exit 2))]
       [exn:fail?
        (lambda (error)
          (eprintf "gate-facts: ~a\n" (exn-message error))
          (exit 2))])
    (match arguments
      [(list "shadow-prepare" store query-store base repository policy verifier raw)
       (write-result
        (shadow-prepare store query-store base repository policy verifier raw))]
      [(list "shadow-finish" store base repository policy verifier raw exit-text)
       (define final-exit (string->number exit-text))
       (unless (exact-integer? final-exit)
         (raise-user-error 'gate-fact-maintainer
                           "FINAL_EXIT must be an integer"))
       (write-result
        (shadow-finish store base repository policy verifier raw final-exit))]
      [(list (and command
                  (or "import" "record-miss" "record-observation"
                      "finalize" "cold-query")))
       (write-result
        (dispatch-low-level
         command
         (read-one-datum (current-input-port) 'gate-fact-maintainer)
         BEAGLE-ROOT))]
      [_
       (raise-user-error
        'gate-fact-maintainer
        (string-append
         "usage: gate-fact-maintainer.rkt shadow-prepare STORE QUERY_STORE "
         "BASE REPO POLICY VERIFIER RAW_DIR | shadow-finish STORE BASE REPO "
         "POLICY VERIFIER RAW_DIR FINAL_EXIT | "
         "import|record-miss|record-observation|finalize|cold-query"))])))

(provide derive-candidate-v1
         raw-claims
         analyze-coverage
         shadow-prepare
         shadow-finish
         dispatch-low-level
         (struct-out adapter-failure)
         (struct-out miss-plan)
         (struct-out coverage-analysis))
