#lang racket/base

;; Explicit, exact-path module source roots. A root maps a complete namespace
;; path to one physical source path; it never scans, walks ancestors, or falls
;; back to another spelling.

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "extensions.rkt"
         "parse.rkt"
         "targets.rkt")

(struct module-source-root-v0
  (logical-prefix lexical-directory physical-directory)
  #:transparent)
(struct module-source-input (source-id physical-path) #:transparent)
(struct module-source-snapshot
  (source-id physical-path bytes target-override source target explicit?)
  #:transparent)
(struct module-source-closure (snapshots explicit-source-ids) #:transparent)

(define (path-string value)
  (if (path? value) (path->string value) (format "~a" value)))

(define (resolve-existing-path-links path)
  ;; `simplify-path` and `resolve-path` do not resolve symlinks in intermediate
  ;; components. Walk the complete path component-by-component so containment
  ;; checks compare the provider's real location with the root's real location.
  (define (restart target remaining link-budget)
    (define target-parts
      (explode-path (simplify-path (path->complete-path target) #f)))
    (walk (car target-parts)
          (append (cdr target-parts) remaining)
          link-budget))
  (define (walk base remaining link-budget)
    (cond
      [(null? remaining) base]
      [else
       (define candidate (build-path base (car remaining)))
       (cond
         [(link-exists? candidate)
          (when (zero? link-budget)
            (error
             'module-source-root
             "symbolic-link resolution exceeded its bounded depth at ~a"
             candidate))
          (define target (resolve-path candidate))
          (restart
           (if (relative-path? target)
               (build-path base target)
               target)
           (cdr remaining)
           (sub1 link-budget))]
         [else
          (walk candidate (cdr remaining) link-budget)])]))
  (define parts
    (explode-path (simplify-path (path->complete-path path) #f)))
  (walk (car parts) (cdr parts) 256))

(define (canonical-physical-path value [filesystem? #t])
  (define complete
    (simplify-path
     (path->complete-path
      (if (path? value) value (string->path value)))
     #f))
  (if filesystem?
      (resolve-existing-path-links complete)
      complete))

(define (relative-path-inside root path)
  (define relative (find-relative-path root path))
  (and
   (relative-path? relative)
   (not
    (for/or ([part (in-list (explode-path relative))])
      (eq? part 'up)))
   relative))

(define (canonical-logical-prefix? value)
  (and
   (string? value)
   (positive? (string-length value))
   (string=? value (string-normalize-nfc value))
   (not (string-prefix? value "/"))
   (not (string-suffix? value "/"))
   (not (string-contains? value "\\"))
   (for/and ([character (in-string value)])
     (define scalar (char->integer character))
     (and (>= scalar 32) (not (= scalar 127))))
   (for/and ([part (in-list (string-split value "/" #:trim? #f))])
     (and (positive? (string-length part))
          (not (member part '("." "..")))))))

(define (make-module-source-root-v0 logical-prefix physical-directory)
  (unless (canonical-logical-prefix? logical-prefix)
    (error
     'module-source-root
     "logical prefix must be a canonical relative path without lexical escape: ~v"
     logical-prefix))
  (define lexical-directory
    (canonical-physical-path physical-directory #f))
  (unless (directory-exists? lexical-directory)
    (error
     'module-source-root
     "physical module root is not a directory: ~a"
     physical-directory))
  (module-source-root-v0
   logical-prefix
   lexical-directory
   (canonical-physical-path lexical-directory #t)))

(define (parse-module-source-root spec)
  (unless (string? spec)
    (raise-argument-error 'parse-module-source-root "string?" spec))
  (define match (regexp-match #px"^([^=]+)=(.+)$" spec))
  (unless match
    (error
     'module-source-root
     "module root must be LOGICAL_PREFIX=PHYSICAL_DIRECTORY, got ~v"
     spec))
  (make-module-source-root-v0 (cadr match) (caddr match)))

(define (namespace-relative-source-id namespace extension)
  (validate-module-path! namespace)
  (string-append
   (string-replace
    (string-replace (symbol->string namespace) "-" "_")
    "."
    "/")
   extension))

(define (root-logical-source-id root relative)
  (string-append
   (module-source-root-v0-logical-prefix root)
   "/"
   (path->string relative)))

(define (module-source-logical-id-for-path roots path)
  (define physical (canonical-physical-path path #t))
  (define rooted-ids
    (remove-duplicates
     (for/list ([root (in-list roots)]
                #:do
                [(define relative
                   (relative-path-inside
                    (module-source-root-v0-physical-directory root)
                    physical))]
                #:when relative)
       (root-logical-source-id root relative))
     string=?))
  (cond
    [(null? rooted-ids) (path->string physical)]
    [(null? (cdr rooted-ids)) (car rooted-ids)]
    [else
     (error
      'module-source-root
      "explicit source maps to multiple logical source IDs: ~a"
      (string-join (sort rooted-ids string<?) ", "))]))

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
    [(null? namespaces) #f]
    [(pair? (cdr namespaces))
     (error
      'module-source-root
      "~a: source has multiple namespace declarations: ~a"
      source
      namespaces)]
    [else (car namespaces)]))

(define (stxs->module-source stxs source)
  (module-source
   (stxs-declared-namespace stxs source)
   source
   stxs
   #f))

(define (stxs-target stxs source-id)
  (define targets
    (for/list ([stx (in-list stxs)]
               #:do [(define datum (syntax->datum stx))]
               #:when
               (match datum
                 [(list 'define-target (? symbol?)) #t]
                 [_ #f]))
      (cadr (syntax->datum stx))))
  (cond
    [(null? targets)
     (error
      'module-source-root
      "source ~a has no Beagle profile header"
      source-id)]
    [(pair? (cdr targets))
     (error
      'module-source-root
      "source ~a has multiple target declarations: ~a"
      source-id
      targets)]
    [else (car targets)]))

(define (source-extension source-id)
  (for/first ([entry (in-list EXTENSION-TARGET-MAP)]
              #:when (string-suffix? source-id (car entry)))
    (car entry)))

(define (snapshot-source input explicit?
                         #:required-namespace [required-namespace #f]
                         #:required-target [required-target #f])
  (define source-id (path-string (module-source-input-source-id input)))
  (define physical
    (canonical-physical-path (module-source-input-physical-path input) #t))
  (unless (file-exists? physical)
    (error
     'module-source-root
     "module source does not exist: ~a"
     (module-source-input-physical-path input)))
  (define extension (source-extension source-id))
  (unless extension
    (error
     'module-source-root
     "logical source ID has no Beagle profile extension: ~a"
     source-id))
  (define expected-target (expected-target-for-extension source-id))
  (define bytes (bytes->immutable-bytes (file->bytes physical)))
  (define declared-stxs
    (read-beagle-syntax/bytes
     physical
     bytes
     #:source-id source-id))
  (define declared-target (stxs-target declared-stxs source-id))
  (define physical-extension (source-extension (path-string physical)))
  (define target-override
    (and (not (eq? declared-target expected-target))
         (equal? physical-extension ".bgl")
         (eq? declared-target 'core)
         expected-target))
  (define stxs
    (if target-override
        (retarget-beagle-syntax declared-stxs target-override)
        declared-stxs))
  (define target (stxs-target stxs source-id))
  (unless (or (eq? target expected-target) target-override)
    (error
     'module-source-root
     "extension/header mismatch for ~a: extension requires #lang ~a, found #lang ~a"
     source-id
     (lang-for-target-id expected-target)
     (lang-for-target-id target)))
  (when (and required-target (not (eq? target required-target)))
    (error
     'module-source-root
     "target mismatch for required source ~a: importer target is ~a, provider target is ~a"
     source-id
     required-target
     target))
  (define source (stxs->module-source stxs source-id))
  (when (and required-namespace
             (not (eq? (module-source-namespace source)
                       required-namespace)))
    (error
     'module-source-root
     "required namespace ~a resolved to ~a, which declares ~a"
     required-namespace
     source-id
     (or (module-source-namespace source) "no namespace")))
  (module-source-snapshot
   source-id physical bytes target-override source target explicit?))

(define (parse-snapshot snapshot resolver)
  (define target-override
    (module-source-snapshot-target-override snapshot))
  (parse-program/bytes
   (module-source-snapshot-bytes snapshot)
   #:source-path (module-source-snapshot-physical-path snapshot)
   #:source-id (module-source-snapshot-source-id snapshot)
   #:target-override target-override
   #:module-resolver resolver))

(define (resolve-module-source-closure explicit-inputs roots)
  (unless (and (list? explicit-inputs)
               (andmap module-source-input? explicit-inputs))
    (raise-argument-error
     'resolve-module-source-closure
     "(listof module-source-input?)"
     explicit-inputs))
  (unless (and (list? roots) (andmap module-source-root-v0? roots))
    (raise-argument-error
     'resolve-module-source-closure
     "(listof module-source-root-v0?)"
     roots))
  (when (null? explicit-inputs)
    (error 'module-source-root "expected at least one explicit source"))

  (define by-source-id (make-hash))
  (define by-namespace (make-hasheq))
  (define pending '())

  (define (register! snapshot)
    (define source-id (module-source-snapshot-source-id snapshot))
    (when (hash-has-key? by-source-id source-id)
      (error
       'module-source-root
       "duplicate logical source ID: ~a"
       source-id))
    (hash-set! by-source-id source-id snapshot)
    (define namespace
      (module-source-namespace (module-source-snapshot-source snapshot)))
    (when namespace
      (hash-update! by-namespace namespace
                    (lambda (prior) (cons snapshot prior))
                    '()))
    (set! pending (append pending (list snapshot)))
    snapshot)

  (for ([input (in-list explicit-inputs)])
    (register! (snapshot-source input #t)))

  (define (providers-for namespace [explicit-only? #f])
    (sort
     (filter
      (lambda (snapshot)
        (or (not explicit-only?)
            (module-source-snapshot-explicit? snapshot)))
      (hash-ref by-namespace namespace '()))
     string<?
     #:key module-source-snapshot-source-id))

  (define (single-provider namespace importer providers)
    (cond
      [(null? providers) #f]
      [(null? (cdr providers)) (car providers)]
      [else
       (error
        'module-source-root
        "namespace ~a required by ~a has multiple explicit providers: ~a"
        namespace
        importer
        (string-join
         (map module-source-snapshot-source-id providers)
         ", "))]))

  (define (assert-target! snapshot importer-target namespace importer)
    (unless (eq? (module-source-snapshot-target snapshot) importer-target)
      (error
       'module-source-root
       "target mismatch for namespace ~a required by ~a: importer target is ~a, provider ~a target is ~a"
       namespace
       importer
       importer-target
       (module-source-snapshot-source-id snapshot)
       (module-source-snapshot-target snapshot)))
    snapshot)

  (define (root-candidates namespace importer-extension
                           [physical-extension importer-extension])
    (define relative-id
      (namespace-relative-source-id namespace importer-extension))
    (define physical-relative-id
      (namespace-relative-source-id namespace physical-extension))
    (for/list ([root (in-list roots)]
               #:do
               [(define relative (string->path physical-relative-id))
                (define candidate
                  (build-path
                   (module-source-root-v0-lexical-directory root)
                   relative))
                (define lexical-relative
                  (relative-path-inside
                   (module-source-root-v0-lexical-directory root)
                   (canonical-physical-path candidate #f)))]
               #:when
               (begin
                 (unless lexical-relative
                   (error
                    'module-source-root
                    "namespace ~a lexically escapes module root ~a"
                    namespace
                    (module-source-root-v0-logical-prefix root)))
                 (file-exists? candidate)))
      (define physical (canonical-physical-path candidate #t))
      (unless
          (relative-path-inside
           (module-source-root-v0-physical-directory root)
           physical)
        (error
         'module-source-root
         "namespace ~a resolves through a symlink outside module root ~a: ~a"
         namespace
         (module-source-root-v0-logical-prefix root)
         candidate))
      (cons
       root
       (module-source-input
        (string-append
         (module-source-root-v0-logical-prefix root)
         "/"
         relative-id)
        physical))))

  (define (resolver namespace importer)
    (define importer-id (path-string importer))
    (define importer-snapshot
      (hash-ref
       by-source-id
       importer-id
       (lambda ()
         (error
          'module-source-root
          "resolver received unknown importer source ID: ~a"
          importer-id))))
    (define importer-target (module-source-snapshot-target importer-snapshot))
    (define importer-extension (source-extension importer-id))
    (unless importer-extension
      (error
       'module-source-root
       "importer has no Beagle profile extension: ~a"
       importer-id))
    (define explicit-provider
      (single-provider
       namespace importer-id (providers-for namespace #t)))
    (cond
      [explicit-provider
       (module-source-snapshot-source
        (assert-target!
         explicit-provider importer-target namespace importer-id))]
      [(single-provider namespace importer-id (providers-for namespace))
       =>
       (lambda (snapshot)
         (module-source-snapshot-source
          (assert-target!
           snapshot importer-target namespace importer-id)))]
      [else
       (define same-target-candidates
         (root-candidates namespace importer-extension))
       (define candidates
         (if (or (pair? same-target-candidates)
                 (equal? importer-extension ".bgl"))
             same-target-candidates
             (root-candidates namespace importer-extension ".bgl")))
       (cond
         [(null? candidates) #f]
         [(pair? (cdr candidates))
          (error
           'module-source-root
           "namespace ~a required by ~a collides across module roots: ~a"
           namespace
           importer-id
           (string-join
            (sort
             (for/list ([candidate (in-list candidates)])
               (module-source-input-source-id (cdr candidate)))
             string<?)
            ", "))]
         [else
          (define candidate (cdar candidates))
          (define snapshot
            (snapshot-source
             candidate
             #f
             #:required-namespace namespace
             #:required-target importer-target))
          (register! snapshot)
          (module-source-snapshot-source snapshot)])]))

  ;; Parsing is discovery only. It extracts requires from the exact immutable
  ;; snapshots and may enqueue one exact root provider per unresolved namespace.
  ;; The coherent overlay reparses and checks the completed, sorted closure.
  (let discover! ()
    (unless (null? pending)
      (define snapshot (car pending))
      (set! pending (cdr pending))
      (define program
        (parse-snapshot snapshot resolver))
      (unless (eq? (program-target program)
                   (module-source-snapshot-target snapshot))
        (error
         'module-source-root
         "parsed target changed for source ~a"
         (module-source-snapshot-source-id snapshot)))
      (discover!)))

  (module-source-closure
   (sort
    (hash-values by-source-id)
    string<?
    #:key module-source-snapshot-source-id)
   (sort
    (map (lambda (input) (path-string (module-source-input-source-id input)))
         explicit-inputs)
    string<?)))

(define (module-source-closure-sources closure)
  (map module-source-snapshot-source
       (module-source-closure-snapshots closure)))

(define (module-source-closure-snapshot-ref closure source-id)
  (or
   (for/first
       ([snapshot (in-list (module-source-closure-snapshots closure))]
        #:when
        (equal? (module-source-snapshot-source-id snapshot)
                (path-string source-id)))
     snapshot)
   (error
    'module-source-root
    "source ID is absent from resolved closure: ~a"
    source-id)))

(define (module-source-closure-physical-path closure source-id)
  (module-source-snapshot-physical-path
   (module-source-closure-snapshot-ref closure source-id)))

(define (module-source-closure-parse-source closure source resolver)
  (define source-id (path-string (module-source-source-id source)))
  (define snapshot
    (module-source-closure-snapshot-ref closure source-id))
  (parse-snapshot snapshot resolver))

(provide
 (struct-out module-source-root-v0)
 (struct-out module-source-input)
 (struct-out module-source-snapshot)
 (struct-out module-source-closure)
 make-module-source-root-v0
 parse-module-source-root
 module-source-logical-id-for-path
 stxs-declared-namespace
 stxs->module-source
 resolve-module-source-closure
 module-source-closure-sources
 module-source-closure-snapshot-ref
 module-source-closure-physical-path
 module-source-closure-parse-source)
