#lang racket/base

;; Coherent multi-module checking for graph-authored candidates.
;;
;; Every candidate is reconstructed from its EDN syntax projection. A bootstrap
;; parse mints provisional semantic interfaces independent of input order. Those
;; provisional interfaces are never authority: every module is
;; reparsed and checked, checked interfaces are reminted, and the process
;; repeats until the whole overlay reaches one fixed point.  Type checking and
;; emission happen only against that coherent overlay, and emitted bytes are
;; returned only when every module succeeds.

(require racket/file
         racket/list
         racket/string
         "check.rkt"
         "emit.rkt"
         "facts-roundtrip.rkt"
         "module-interface.rkt"
         "module-source-root.rkt"
         "parse.rkt")

(struct overlay-diagnostic (source phase message) #:transparent)
(struct checked-overlay-module
  (namespace source program interface emitted)
  #:transparent)
(struct overlay-check-result
  (ok? modules diagnostics overlay-digest)
  #:transparent)

(define (edn-source-id edn-path)
  (or
   (for/first ([line (in-list (file->lines edn-path))]
               #:when (string-prefix? line "@file "))
     (substring line (string-length "@file ")))
   (if (path? edn-path) (path->string edn-path) edn-path)))

(define (drop-beagle-file-wrapper wrapper source)
  (define children (syntax->list wrapper))
  (unless (and children
               (pair? children)
               (eq? (syntax->datum (car children)) 'beagle-file))
    (error 'check-edn-overlay
           "~a: EDN root is not a beagle-file wrapper"
           source))
  (cdr children))

(define (edn->module-source edn-path)
  (define source (edn-source-id edn-path))
  (define triples (read-edn-triples edn-path))
  (when (null? triples)
    (error 'check-edn-overlay "~a: candidate EDN contains no triples" edn-path))
  (define wrapper (edn-triples->syntax triples source))
  (define stxs (drop-beagle-file-wrapper wrapper source))
  (stxs->module-source stxs source))

(struct candidate-overlay (by-namespace by-source) #:transparent)

(define (module-source-id-string source)
  (format "~a" (module-source-source-id source)))

(define (candidate-source-list sources)
  (string-join (map module-source-id-string sources) ", "))

(define (source-overlay sources)
  (define by-namespace (make-hasheq))
  (define by-source (make-hash))
  (for ([source (in-list sources)])
    (define namespace (module-source-namespace source))
    (define source-id (module-source-id-string source))
    (when (hash-has-key? by-source source-id)
      (error
       'check-edn-overlay
       "duplicate candidate source id ~a"
       source-id))
    (hash-set! by-source source-id source)
    (when namespace
      ;; Namespace identity can be shared; source identity stays authoritative.
      (hash-update! by-namespace namespace
                    (lambda (existing) (cons source existing))
                    '())))
  (for ([(namespace namespace-sources) (in-hash by-namespace)])
    (hash-set! by-namespace
               namespace
               (sort namespace-sources
                     string<?
                     #:key module-source-id-string)))
  (candidate-overlay by-namespace by-source))

(define (overlay-resolver overlay #:closed? [closed? #f])
  (lambda (namespace importer-source)
    (define sources
      (hash-ref (candidate-overlay-by-namespace overlay) namespace '()))
    (cond
      [(null? sources) #f]
      [(null? (cdr sources)) (car sources)]
      [else
       (error
        'check-edn-overlay
        "ambiguous candidate namespace ~a required by ~a; providers: ~a"
        namespace
        importer-source
        (candidate-source-list sources))])))

(define (parse-source source resolver)
  (parse-program
   (module-source-stxs source)
   #:source-path (module-source-source-id source)
   #:module-resolver resolver))

(define (failed-result source phase value)
  (overlay-check-result
   #f
   '()
   (list
    (overlay-diagnostic
     source
     phase
     (if (exn? value) (exn-message value) (format "~a" value))))
   #f))

(define (parameter-inferred? parameter)
  (and (param? parameter) (not (param-type parameter))))

(define (callable-publishes-inference? form)
  (cond
    [(defn-form? form)
     (and (not (defn-form-private? form))
          (or (ormap parameter-inferred? (defn-form-params form))
              (and (defn-form-rest-param form)
                   (parameter-inferred? (defn-form-rest-param form)))))]
    [(defn-multi? form)
     (and
      (not (defn-multi-private? form))
      (for/or ([arity (in-list (defn-multi-arities form))])
        (or (ormap parameter-inferred? (arity-clause-params arity))
            (and (arity-clause-rest-param arity)
                 (parameter-inferred?
                  (arity-clause-rest-param arity))))))]
    [else #f]))

(define (program-publishes-inference? prog)
  (for/or ([raw-form (in-list (program-forms prog))])
    (callable-publishes-inference? (unwrap-definition-form raw-form))))

(define (record-ordering-dependency-receipts! entries overlay)
  (for ([entry (in-list entries)])
    (define source (car entry))
    (define prog (cdr entry))
    (define source-id (module-source-id-string source))
    (define dependencies
      (for/list ([required (in-list (program-requires prog))])
        (define providers
          (sort
           (map module-source-id-string
                (hash-ref
                 (candidate-overlay-by-namespace overlay)
                 (require-entry-ns required)
                 '()))
           string<?))
        (vector (require-entry-ns required) providers
                (and (= (length providers) 1) (car providers)))))
    (define selected
      (for/list ([dependency (in-list dependencies)]
                 #:when (string? (vector-ref dependency 2)))
        (vector-ref dependency 2)))
    (define target (program-target prog))
    (define profile (semantic-profile-for-target target))
    (ensure-program-read-receipt-table! prog)
    (record-program-read-receipt!
     prog
     (make-read-receipt-v1
      'ordering-dependency
      (list 'module-order source-id)
      (sort (remove-duplicates
             (append-map (lambda (dependency)
                           (vector-ref dependency 1))
                         dependencies))
            string<?)
      (list->vector selected)
      profile
      target
      (hash 'source-id source-id
            'requires (list->vector dependencies)
            'ordering 'candidate-overlay)))))

;; Return deterministic strongly connected components for candidate requires.
;; Namespace-free modules cannot satisfy requires and therefore have no inbound
;; graph edge, but still participate as singleton source nodes.
(define (candidate-source-sccs entries overlay)
  (define source-ids
    (map (lambda (entry) (module-source-id-string (car entry))) entries))
  (define program-by-source
    (for/hash ([entry (in-list entries)])
      (values (module-source-id-string (car entry)) (cdr entry))))
  (define edges
    (for/hash ([source-id (in-list source-ids)])
      (define prog (hash-ref program-by-source source-id))
      (values
       source-id
       (sort
        (remove-duplicates
         (for*/list ([required (in-list (program-requires prog))]
                     [providers
                      (in-value
                       (hash-ref
                        (candidate-overlay-by-namespace overlay)
                        (require-entry-ns required)
                        '()))]
                     #:when (= (length providers) 1))
           (module-source-id-string (car providers))))
        string<?))))
  (define next-index 0)
  (define indexes (make-hash))
  (define lowlinks (make-hash))
  (define stack '())
  (define on-stack (make-hash))
  (define components '())
  (define (strongconnect source-id)
    (hash-set! indexes source-id next-index)
    (hash-set! lowlinks source-id next-index)
    (set! next-index (add1 next-index))
    (set! stack (cons source-id stack))
    (hash-set! on-stack source-id #t)
    (for ([provider-id (in-list (hash-ref edges source-id))])
      (cond
        [(not (hash-has-key? indexes provider-id))
         (strongconnect provider-id)
         (hash-set! lowlinks source-id
                    (min (hash-ref lowlinks source-id)
                         (hash-ref lowlinks provider-id)))]
        [(hash-ref on-stack provider-id #f)
         (hash-set! lowlinks source-id
                    (min (hash-ref lowlinks source-id)
                         (hash-ref indexes provider-id)))]))
    (when (= (hash-ref lowlinks source-id) (hash-ref indexes source-id))
      (define component '())
      (let pop! ()
        (define member (car stack))
        (set! stack (cdr stack))
        (hash-remove! on-stack member)
        (set! component (cons member component))
        (unless (equal? member source-id) (pop!)))
      (set! components (cons (sort component string<?) components))))
  (for ([source-id (in-list (sort source-ids string<?))])
    (unless (hash-has-key? indexes source-id)
      (strongconnect source-id)))
  (values (reverse components) edges program-by-source))

(define (reject-inferred-interface-cycles! entries overlay)
  (define-values (components edges programs)
    (candidate-source-sccs entries overlay))
  (for ([component (in-list components)])
    (define cyclic?
      (or (pair? (cdr component))
          (member (car component) (hash-ref edges (car component)))))
    (when
        (and cyclic?
             (for/or ([source-id (in-list component)])
               (program-publishes-inference?
                (hash-ref programs source-id))))
      (error
       'check-module-overlay
       (string-append
        "module cycle exports an inferred parameter signature: ~a; "
        "annotate every public parameter in the cycle explicitly")
       (string-join component ", ")))))

(define (interfaces-stable? current next)
  (and
   (= (length current) (length next))
   (for/and ([left (in-list current)] [right (in-list next)])
     (and
      (equal? (module-source-id-string left)
              (module-source-id-string right))
      (equal?
       (module-interface-digest (module-source-interface left))
       (module-interface-digest (module-source-interface right)))))))

(define (check-module-overlay input-sources
                              #:check-profile [check-profile 2]
                              #:check-namespaces [check-namespaces #f]
                              #:check-sources [check-sources #f]
                              #:emit? [emit? #t]
                              #:capture-types? [capture-types? #f]
                              #:shadow-facts? [shadow-facts? #f]
                              #:closed? [closed? #f]
                              #:diagnostic-sink [diagnostic-sink void]
                              #:parse-source [parse-source* parse-source])
  (let/ec abort
    (define capture? (or capture-types? shadow-facts?))
    (define sources
      (sort input-sources string<? #:key module-source-id-string))
    (define (guard source phase thunk)
      (with-handlers ([(lambda (_value) #t)
                       (lambda (value)
                         (diagnostic-sink source phase value #f)
                         (abort (failed-result source phase value)))])
        (thunk)))
    (define (parse-checked-source source resolver)
      (parameterize
          ([current-module-resolution-closed? closed?])
        (parse-source* source resolver)))
    (when (null? sources)
      (abort
       (failed-result
        #f 'read
        (make-exn:fail
         "check-edn-overlay: expected at least one candidate EDN"
         (current-continuation-marks)))))
    (define bootstrap-overlay
      (guard #f 'index (lambda () (source-overlay sources))))
    (define bootstrap-resolver
      (overlay-resolver bootstrap-overlay #:closed? closed?))
    ;; Pass one is intentionally parse-only. Its interfaces are marked
    ;; provisional and may carry authored Any for omitted binders; they exist
    ;; only to make every candidate namespace parseable in the first checked
    ;; round.
    (define bootstrap-programs
      (for/list ([source (in-list sources)])
        (cons
         source
         (guard
          (module-source-source-id source)
          'parse
          (lambda () (parse-checked-source source bootstrap-resolver))))))
    (guard
     #f
     'interface
     (lambda ()
       (reject-inferred-interface-cycles!
        bootstrap-programs
        bootstrap-overlay)))
    (define bootstrap-sources
      (for/list ([entry (in-list bootstrap-programs)])
        (define source (car entry))
        (define prog (cdr entry))
        (struct-copy
         module-source
         source
         [interface
          (program->module-interface
           prog
           #:source-id (module-source-source-id source)
           #:provisional? #t
           #:capture-types? capture?)])))
    (define max-rounds (add1 (length sources)))
    ;; Imported aliases can cross more than one candidate boundary before a
    ;; checked consumer sees them.  Converge the deliberately weak parse-only
    ;; interfaces first; otherwise the first checked round can reject an exact
    ;; downstream value against an opaque bootstrap name before authoritative
    ;; interfaces have a chance to be reminted.
    (define provisional-sources
      (let stabilize-provisional ([current-sources bootstrap-sources]
                                  [round 1])
        (when (> round max-rounds)
          (abort
           (failed-result
            #f
            'interface
            (make-exn:fail
             (format
              "check-module-overlay: provisional interfaces did not converge after ~a parse-only rounds"
              max-rounds)
             (current-continuation-marks)))))
        (define current-overlay
          (guard #f 'index (lambda () (source-overlay current-sources))))
        (define current-resolver
          (overlay-resolver current-overlay #:closed? closed?))
        (define round-programs
          (for/list ([source (in-list current-sources)])
            (cons
             source
             (guard
              (module-source-source-id source)
              'parse
              (lambda () (parse-checked-source source current-resolver))))))
        (define next-sources
          (for/list ([entry (in-list round-programs)])
            (define source (car entry))
            (define prog (cdr entry))
            (struct-copy
             module-source
             source
             [interface
              (guard
               (module-source-source-id source)
               'interface
               (lambda ()
                 (program->module-interface
                  prog
                  #:source-id (module-source-source-id source)
                  #:provisional? #t
                  #:capture-types? capture?)))])))
        (if (interfaces-stable? current-sources next-sources)
            next-sources
            (stabilize-provisional next-sources (add1 round)))))
    (define provisional-overlay
      (guard #f 'index (lambda () (source-overlay provisional-sources))))
    (define selected-namespaces
      (and
       check-namespaces
       (for/list ([namespace (in-list check-namespaces)])
         (cond
           [(symbol? namespace) namespace]
           [(string? namespace) (string->symbol namespace)]
           [else
            (abort
             (failed-result
              #f
              'index
              (make-exn:fail
               (format
                "check-edn-overlay: checked namespace must be a symbol or string, got ~v"
                namespace)
               (current-continuation-marks))))]))))
    (define selected-sources
      (and
       check-sources
       (for/list ([source-id (in-list check-sources)])
         (cond
           [(path? source-id) (path->string source-id)]
           [(string? source-id) source-id]
           [(symbol? source-id) (symbol->string source-id)]
           [else
            (abort
             (failed-result
              #f
              'index
              (make-exn:fail
               (format
                "check-edn-overlay: checked source must be a path, string, or symbol, got ~v"
                source-id)
               (current-continuation-marks))))]))))
    (when (and (or selected-namespaces selected-sources)
               (null? (append (or selected-namespaces '())
                              (or selected-sources '()))))
      (abort
       (failed-result
        #f
        'index
        (make-exn:fail
         "check-edn-overlay: explicit checked module selector set is empty"
         (current-continuation-marks)))))
    (for ([namespace (in-list (or selected-namespaces '()))])
      (define sources
        (hash-ref
         (candidate-overlay-by-namespace provisional-overlay)
         namespace
         '()))
      (cond
        [(null? sources)
         (abort
          (failed-result
           #f
           'index
           (make-exn:fail
            (format
             "check-edn-overlay: checked namespace ~a is absent from the candidate overlay"
             namespace)
            (current-continuation-marks))))]
        [(pair? (cdr sources))
         (abort
          (failed-result
           #f
           'index
           (make-exn:fail
            (format
             "check-edn-overlay: checked namespace ~a is ambiguous across candidate sources: ~a"
             namespace
             (candidate-source-list sources))
            (current-continuation-marks))))]))
    (for ([source-id (in-list (or selected-sources '()))])
      (unless
          (hash-has-key?
           (candidate-overlay-by-source provisional-overlay)
           source-id)
        (abort
         (failed-result
          #f
          'index
          (make-exn:fail
           (format
            "check-edn-overlay: checked source ~a is absent from the candidate overlay"
            source-id)
           (current-continuation-marks))))))
    (define (selected-entry? entry)
      (define source (car entry))
      (or
       (not (or selected-namespaces selected-sources))
       (and selected-namespaces
            (memq (module-source-namespace source) selected-namespaces))
       (and selected-sources
            (member (module-source-id-string source) selected-sources))))
    (define (select entries) (filter selected-entry? entries))
    (define-values (final-programs final-sources)
      (let stabilize ([current-sources provisional-sources] [round 1])
        (when (> round max-rounds)
          (abort
           (failed-result
            #f
            'interface
            (make-exn:fail
             (format
              "check-module-overlay: inferred interfaces did not converge after ~a checked rounds"
              max-rounds)
             (current-continuation-marks)))))
        (define current-overlay
          (guard #f 'index (lambda () (source-overlay current-sources))))
        (define current-resolver
          (overlay-resolver current-overlay #:closed? closed?))
        (define round-programs
          (for/list ([source (in-list current-sources)])
            (cons
             source
             (guard
              (module-source-source-id source)
              'parse
              (lambda () (parse-checked-source source current-resolver))))))
        (when capture?
          (record-ordering-dependency-receipts!
           round-programs
           current-overlay))
        ;; Every provider in the candidate context is checked before its
        ;; interface can become authority. Selectors affect only the
        ;; returned/emitted module set, never the proof closure.
        (define diagnostics '())
        (parameterize ([current-check-profile check-profile])
          (for ([entry (in-list round-programs)])
            (define source (car entry))
            (type-check-with-locs!
             (cdr entry)
             (lambda (error location)
               (diagnostic-sink
                (module-source-source-id source)
                'check
                error
                location)
               (set!
                diagnostics
                (cons
                 (overlay-diagnostic
                  (module-source-source-id source)
                  'check
                  (if (exn? error)
                      (exn-message error)
                      (format "~a" error)))
                 diagnostics)))
             #:capture-types? capture?)))
        (define current-interfaces
          (map module-source-interface current-sources))
        (define current-digest
          (module-interfaces-overlay-digest current-interfaces))
        (when (pair? diagnostics)
          (abort
           (overlay-check-result
            #f
            (for/list ([entry (in-list (select round-programs))])
              (define source (car entry))
              (checked-overlay-module
               (module-source-namespace source)
               (module-source-source-id source)
               (cdr entry)
               (module-source-interface source)
               #f))
            (reverse diagnostics)
            current-digest)))
        (define next-sources
          (for/list ([entry (in-list round-programs)])
            (define source (car entry))
            (define prog (cdr entry))
            (struct-copy
             module-source
             source
             [interface
              (guard
               (module-source-source-id source)
               'interface
               (lambda ()
                 (program->module-interface
                  prog
                  #:source-id (module-source-source-id source)
                  #:capture-types? capture?)))])))
        (if (interfaces-stable? current-sources next-sources)
            (values round-programs next-sources)
            (stabilize next-sources (add1 round)))))
    (define programs (select final-programs))
    (define final-interface-by-source
      (for/hash ([source (in-list final-sources)])
        (values (module-source-id-string source)
                (module-source-interface source))))
    (define interfaces (map module-source-interface final-sources))
    (define overlay-digest (module-interfaces-overlay-digest interfaces))
    ;; Emission is overlay-atomic: collect into local module results only after
    ;; every checker has passed.  Any emitter failure returns no partial bytes.
    (define modules
      (for/list ([entry (in-list programs)])
        (define source (car entry))
        (define prog (cdr entry))
        (checked-overlay-module
         (module-source-namespace source)
         (module-source-source-id source)
         prog
         (hash-ref final-interface-by-source
                   (module-source-id-string source))
         (and emit?
              (guard
               (module-source-source-id source)
               'emit
               (lambda () (emit-program prog)))))))
    (overlay-check-result #t modules '() overlay-digest)))

(define (check-module-source-closure closure
                                     #:check-profile [check-profile 2]
                                     #:check-namespaces [check-namespaces #f]
                                     #:check-sources [check-sources #f]
                                     #:emit? [emit? #t]
                                     #:capture-types? [capture-types? #f]
                                     #:shadow-facts? [shadow-facts? #f]
                                     #:diagnostic-sink [diagnostic-sink void])
  (check-module-overlay
   (module-source-closure-sources closure)
   #:check-profile check-profile
   #:check-namespaces check-namespaces
   #:check-sources check-sources
   #:emit? emit?
   #:capture-types? capture-types?
   #:shadow-facts? shadow-facts?
   #:closed? #t
   #:diagnostic-sink diagnostic-sink
   #:parse-source
   (lambda (source resolver)
     (module-source-closure-parse-source closure source resolver))))

(define (check-edn-overlay edn-paths
                           #:check-profile [check-profile 2]
                           #:check-namespaces [check-namespaces #f]
                           #:check-sources [check-sources #f]
                           #:emit? [emit? #t]
                           #:capture-types? [capture-types? #f]
                           #:shadow-facts? [shadow-facts? #f])
  (let/ec abort
    (define sources
      (for/list ([edn-path (in-list edn-paths)])
        (with-handlers
            ([(lambda (_value) #t)
              (lambda (value)
                (abort
                 (failed-result
                  (if (path? edn-path)
                      (path->string edn-path)
                      edn-path)
                  'read
                  value)))])
          (edn->module-source edn-path))))
    (check-module-overlay
     sources
     #:check-profile check-profile
     #:check-namespaces check-namespaces
     #:check-sources check-sources
     #:emit? emit?
     #:capture-types? capture-types?
     #:shadow-facts? shadow-facts?)))

(provide
 check-edn-overlay
 check-module-overlay
 check-module-source-closure
 stxs->module-source
 (struct-out overlay-diagnostic)
 (struct-out checked-overlay-module)
 (struct-out overlay-check-result))
