#lang racket/base

;; Coherent multi-module checking for graph-authored candidates.
;;
;; Every candidate is reconstructed from its EDN datum projection.  A bootstrap
;; parse lets modules import candidate datums independent of input order; the
;; resulting public interfaces are then installed in a second, authoritative
;; parse.  Type checking and emission happen only against that single overlay,
;; and emitted bytes are returned only when the entire overlay succeeds.

(require racket/file
         racket/list
         racket/match
         racket/string
         "check.rkt"
         "emit.rkt"
         "facts-roundtrip.rkt"
         "module-interface.rkt"
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

(define (stxs-declared-namespace stxs source)
  (define namespaces
    (for/list ([stx (in-list stxs)]
               #:do [(define datum (syntax->datum stx))]
               #:when
               (match datum
                 [(list* 'ns (? symbol?) _) #t]
                 [_ #f]))
      (cadr (syntax->datum stx))))
  (cond
    ;; Namespace-free graph modules are valid standalone candidates.  They are
    ;; addressable by @file source id, but cannot satisfy a namespace require.
    [(null? namespaces) #f]
    [(pair? (cdr namespaces))
     (error 'check-edn-overlay
            "~a: candidate has multiple ns declarations: ~a"
            source namespaces)]
    [else (car namespaces)]))

(define (edn->module-source edn-path)
  (define source (edn-source-id edn-path))
  (define triples (read-edn-triples edn-path))
  (when (null? triples)
    (error 'check-edn-overlay "~a: candidate EDN contains no triples" edn-path))
  (define wrapper (edn-triples->syntax triples source))
  (define stxs (drop-beagle-file-wrapper wrapper source))
  (module-source
   (stxs-declared-namespace stxs source)
   source
   stxs
   (map syntax->datum stxs)
   #f))

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
      [(null? sources)
       (if closed?
           (error
            'check-module-overlay
            "required namespace ~a is absent from the closed source bundle (required by ~a)"
            namespace
            importer-source)
           #f)]
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

(define (check-module-overlay sources
                              #:check-profile [check-profile 2]
                              #:check-namespaces [check-namespaces #f]
                              #:check-sources [check-sources #f]
                              #:emit? [emit? #t]
                              #:capture-types? [capture-types? #f]
                              #:closed? [closed? #f]
                              #:parse-source [parse-source* parse-source])
  (let/ec abort
    (define (guard source phase thunk)
      (with-handlers ([(lambda (_value) #t)
                       (lambda (value)
                         (abort (failed-result source phase value)))])
        (thunk)))
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
    ;; Pass one is intentionally parse-only: it establishes canonical provider
    ;; interfaces while every import already reads candidate datums.
    (define bootstrap-programs
      (for/list ([source (in-list sources)])
        (cons
         source
         (guard
          (module-source-source-id source)
          'parse
          (lambda () (parse-source* source bootstrap-resolver))))))
    (define authoritative-sources
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
           #:datums (module-source-datums source))])))
    (define authoritative-overlay
      (guard #f 'index (lambda () (source-overlay authoritative-sources))))
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
         (candidate-overlay-by-namespace authoritative-overlay)
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
           (candidate-overlay-by-source authoritative-overlay)
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
    (define authoritative-resolver
      (overlay-resolver authoritative-overlay #:closed? closed?))
    (define all-programs
      (for/list ([source (in-list authoritative-sources)])
        (cons
         source
         (guard
          (module-source-source-id source)
          'parse
          (lambda () (parse-source* source authoritative-resolver))))))
    (define programs
      (if (or selected-namespaces selected-sources)
          (filter
           (lambda (entry)
             (define source (car entry))
             (or
              (and selected-namespaces
                   (memq
                    (module-source-namespace source)
                    selected-namespaces))
              (and selected-sources
                   (member
                    (format "~a" (module-source-source-id source))
                    selected-sources))))
           all-programs)
          all-programs))
    (define diagnostics '())
    (parameterize ([current-check-profile check-profile])
      (for ([entry (in-list programs)])
        (define source (car entry))
        (define prog (cdr entry))
        (type-check-with-locs!
         prog
         (lambda (error _location)
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
         #:capture-types? capture-types?)))
    (define interfaces
      (map module-source-interface authoritative-sources))
    (define overlay-digest
      (module-interfaces-overlay-digest interfaces))
    (when (pair? diagnostics)
      (abort
       (overlay-check-result
        #f
        (for/list ([entry (in-list programs)])
          (define source (car entry))
          (checked-overlay-module
           (module-source-namespace source)
           (module-source-source-id source)
           (cdr entry)
           (module-source-interface source)
           #f))
        (reverse diagnostics)
        overlay-digest)))
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
         (module-source-interface source)
         (and emit?
              (guard
               (module-source-source-id source)
               'emit
               (lambda () (emit-program prog)))))))
    (overlay-check-result #t modules '() overlay-digest)))

(define (check-edn-overlay edn-paths
                           #:check-profile [check-profile 2]
                           #:check-namespaces [check-namespaces #f]
                           #:check-sources [check-sources #f]
                           #:emit? [emit? #t])
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
     #:emit? emit?)))

(provide
 check-edn-overlay
 check-module-overlay
 (struct-out overlay-diagnostic)
 (struct-out checked-overlay-module)
 (struct-out overlay-check-result))
