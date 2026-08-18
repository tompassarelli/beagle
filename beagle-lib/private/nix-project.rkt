#lang racket/base

;; A Nix project manifest is ordinary, checked .bnix data. It makes the
;; repository-wide source boundary explicit without adding a second config
;; language or teaching the compiler consumer-specific paths.

(require racket/file
         racket/list
         racket/path
         racket/string
         "ast.rkt"
         "check.rkt"
         "parse.rkt")

(struct nix-project (root manifest members excluded omit-module-attrs)
  #:transparent)

(define allowed-exclude-classes
  '(negative-fixture resolver-input doc-fixture))

(define (absolute-path path)
  (simplify-path (path->complete-path path) #t))

(define (relative-path-inside root path who)
  (define rel (find-relative-path root path))
  (unless (and (relative-path? rel)
               (not (for/or ([part (in-list (explode-path rel))])
                      (eq? part 'up))))
    (error who "path is outside project root ~a: ~a" root path))
  (path->string rel))

(define (pruned-directory-name? entry)
  (define name (path->string entry))
  (or (string-prefix? name ".")
      (string-prefix? name "result")
      (member name '("node_modules" "target"))))

(define (discover-bnix root)
  (define (walk dir)
    (for/fold ([found '()]) ([entry (in-list (sort (directory-list dir) path<?))])
      (define full (build-path dir entry))
      (cond
        [(and (directory-exists? full)
              (not (pruned-directory-name? entry)))
         (append (walk full) found)]
        [(and (file-exists? full)
              (string-suffix? (path->string entry) ".bnix"))
         (cons (relative-path-inside root (absolute-path full) 'nix-project)
               found)]
        [else found])))
  (sort (walk root) string<?))

(define (map-value value key [fallback #f])
  (unless (map-form? value)
    (error 'nix-project "expected a map, got ~v" value))
  (define pair
    (for/or ([entry (in-list (map-form-pairs value))])
      (and (eq? (car entry) key) entry)))
  (if pair (cdr pair) fallback))

(define (required-map-value value key)
  (define result (map-value value key #f))
  (unless result
    (error 'nix-project "manifest is missing ~a" key))
  result)

(define (vector-items value label)
  (unless (vec-form? value)
    (error 'nix-project "~a must be a vector" label))
  (vec-form-items value))

(define (keyword-name value label)
  (unless (and (symbol? value)
               (string-prefix? (symbol->string value) ":"))
    (error 'nix-project "~a must be a keyword" label))
  (string->symbol (substring (symbol->string value) 1)))

(define (manifest-program manifest)
  (define prog (parse-program (read-beagle-syntax manifest)
                              #:source-path manifest))
  (unless (eq? (program-target prog) 'nix)
    (error 'nix-project "manifest must use #lang beagle/nix: ~a" manifest))
  (type-check! prog)
  prog)

(define (manifest-body prog manifest)
  (define bodies (filter map-form? (program-forms prog)))
  (unless (= (length bodies) 1)
    (error 'nix-project
           "manifest must contain exactly one top-level project map: ~a"
           manifest))
  (car bodies))

(define (parse-excluded body)
  (define entries (vector-items (required-map-value body ':exclude) ':exclude))
  (define seen (make-hash))
  (for/list ([entry (in-list entries)] [index (in-naturals)])
    (unless (map-form? entry)
      (error 'nix-project ":exclude entry ~a must be a map" index))
    (define path (required-map-value entry ':path))
    (unless (and (string? path) (non-empty-string? path))
      (error 'nix-project ":exclude entry ~a :path must be a nonempty string" index))
    (when (or (absolute-path? (string->path path))
              (for/or ([part (in-list (explode-path (string->path path)))])
                (eq? part 'up)))
      (error 'nix-project ":exclude path must stay inside the project: ~a" path))
    (when (hash-has-key? seen path)
      (error 'nix-project "duplicate :exclude path: ~a" path))
    (hash-set! seen path #t)
    (define class
      (keyword-name (required-map-value entry ':class)
                    (format ":exclude entry ~a :class" index)))
    (unless (memq class allowed-exclude-classes)
      (error 'nix-project
             "unknown exclude class ~a for ~a; expected one of ~a"
             class path allowed-exclude-classes))
    (cons path class)))

(define (parse-omit-module-attrs body)
  (define values
    (vector-items (required-map-value body ':omit-module-attrs)
                  ':omit-module-attrs))
  (define attrs
    (for/list ([value (in-list values)] [index (in-naturals)])
      (string->symbol
       (string-append
        ":"
        (symbol->string
         (keyword-name value
                       (format ":omit-module-attrs entry ~a" index)))))))
  (when (check-duplicates attrs eq?)
    (error 'nix-project ":omit-module-attrs contains a duplicate key"))
  attrs)

(define (load-nix-project root manifest)
  (define root-path (absolute-path root))
  (unless (directory-exists? root-path)
    (error 'nix-project "project root does not exist: ~a" root))
  (define manifest-path (absolute-path manifest))
  (unless (file-exists? manifest-path)
    (error 'nix-project "manifest does not exist: ~a" manifest))
  (define manifest-rel
    (relative-path-inside root-path manifest-path 'nix-project))
  (define body (manifest-body (manifest-program manifest-path) manifest-path))
  (define excluded (parse-excluded body))
  (define omit-module-attrs (parse-omit-module-attrs body))
  (define discovered (discover-bnix root-path))
  (unless (member manifest-rel discovered)
    (error 'nix-project "manifest is not a discovered .bnix source: ~a" manifest-rel))
  (for ([entry (in-list excluded)])
    (unless (member (car entry) discovered)
      (error 'nix-project
             "classified exclude is stale or not a .bnix source: ~a"
             (car entry))))
  (define excluded-paths (map car excluded))
  (define members
    (filter (lambda (rel)
              (and (not (string=? rel manifest-rel))
                   (not (member rel excluded-paths))))
            discovered))
  (when (null? members)
    (error 'nix-project "manifest selects no source members"))
  (nix-project root-path manifest-path members excluded omit-module-attrs))

(provide (struct-out nix-project)
         allowed-exclude-classes
         load-nix-project)
