#lang racket/base
;; Downstream consumer registry: derive each live Beagle consumer's membership
;; from its OWN authoritative enumerator, fail closed on enumerator drift.
;;
;; Gate C1 scope: registry load, membership derivation, sorted-relpath count +
;; SHA-256, and a fail-closed drift guard. NO compilation, receipts beyond the
;; list, sensitivity harness, or release wiring live here.
(require racket/list
         racket/string
         racket/path
         racket/port
         racket/system
         racket/runtime-path)

(provide (struct-out consumer-result)
         exn:fail:drift?
         registry-path
         load-consumers
         consumer-name
         consumer-repo-path
         derive-consumer
         derive-all
         result->jsexpr
         list->jsexpr)

(define-runtime-path default-registry-path "consumers.rktd")

;; --- drift signal ------------------------------------------------------------
;; A drift error is fail-closed: an enumerator's SHAPE no longer matches what
;; the registry recorded, so any derived membership would be untrustworthy.
(struct exn:fail:drift exn:fail ())

(define (drift-error fmt . args)
  (raise (exn:fail:drift (string-append "downstream drift: " (apply format fmt args))
                         (current-continuation-marks))))

;; --- spec accessors (registry entries are plain S-exprs) ---------------------
(define (spec-ref spec key [default 'no-default])
  (cond [(assq key (cdr spec)) => cadr]
        [(eq? default 'no-default)
         (error 'spec-ref "missing key ~a in ~a" key (car spec))]
        [else default]))

(define (registry-path) default-registry-path)

;; --- path helpers ------------------------------------------------------------
(define (expand-user p)
  (define s (if (path? p) (path->string p) p))
  (cond [(string=? s "~") (path->string (find-system-path 'home-dir))]
        [(string-prefix? s "~/")
         (path->string (build-path (find-system-path 'home-dir) (substring s 2)))]
        [else s]))

(define (consumer-name c) (spec-ref c 'name))

(define (consumer-repo-path c)
  (define env-var (spec-ref c 'repo-env #f))
  (define override (and env-var (getenv env-var)))
  (simplify-path
   (path->complete-path
    (expand-user (or override (spec-ref c 'repo-default))))))

;; --- external shells (deterministic, boring) ---------------------------------
(define (sha256-of-string s)
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "sha256sum")))
  (write-string s in)
  (close-output-port in)
  (define line (read-line out))
  (close-input-port out) (close-input-port err)
  (subprocess-wait proc)
  (unless (zero? (subprocess-status proc))
    (error 'sha256 "sha256sum failed"))
  (car (string-split line)))

(define (git-rev repo)
  (define out (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-nowhere)])
      (system* (find-executable-path "git") "-C" (path->string repo)
               "rev-parse" "HEAD")))
  (if ok? (string-trim (get-output-string out)) "unknown"))

;; Read an enumerator source file, failing closed if it has vanished.
(define (read-enumerator-source repo rel)
  (define full (build-path repo rel))
  (unless (file-exists? full)
    (drift-error "enumerator source ~a is missing under ~a" rel repo))
  (call-with-input-file full port->string))

(define (assert-shape-markers text markers where)
  (for ([m (in-list markers)])
    (unless (string-contains? text m)
      (drift-error "~a: expected shape marker ~s not found (enumerator changed)"
                   where m))))

;; --- filesystem walk (prunes VCS / build noise for speed & determinism) ------
(define prune-dirs (list ".git" ".direnv" ".beagle" ".beagle-out" ".beagle-tools"
                         "node_modules"))

(define (walk-ext root ext #:recursive? [recursive? #t] #:prune-extra [extra '()])
  (define pruned (append prune-dirs extra))
  (let loop ([dir root] [acc '()])
    (for/fold ([acc acc]) ([entry (in-list (sort (directory-list dir) path<?))])
      (define full (build-path dir entry))
      (cond
        [(and (directory-exists? full) recursive?
              (not (member (path->string entry) pruned)))
         (loop full acc)]
        [(and (file-exists? full) (string-suffix? (path->string entry) ext))
         (cons full acc)]
        [else acc]))))

(define (relpath repo full)
  (path->string (find-relative-path (path->directory-path repo) full)))

;; --- enumerator kinds --------------------------------------------------------
;; Each returns a sorted list of repo-relative source paths (as strings), and
;; raises exn:fail:drift when the enumerator's shape no longer matches.
(define (derive-enumerator repo enum)
  (case (spec-ref enum 'kind)
    [(glob)          (derive-glob repo enum)]
    [(bash-array)    (derive-bash-array repo enum)]
    [(bash-for-list) (derive-bash-for-list repo enum)]
    [(find-exclude)  (derive-find-exclude repo enum)]
    [else (error 'derive-enumerator "unknown kind ~a" (spec-ref enum 'kind))]))

(define (derive-glob repo enum)
  (define source (spec-ref enum 'source #f))
  (define markers (spec-ref enum 'shape-markers '()))
  (when source
    (assert-shape-markers (read-enumerator-source repo source) markers
                          (format "glob ~a" source)))
  ;; A require-absent path asserts the seam is still glob-only: if a manifest
  ;; appears, the roster is no longer glob-derived -> fail closed.
  (define ra (spec-ref enum 'require-absent #f))
  (when ra
    (define p (build-path repo ra))
    (when (and (file-exists? p) (> (file-size p) 0))
      (drift-error "glob seam grew a manifest ~a (~a bytes); registry must adopt it"
                   ra (file-size p))))
  (define root-rel (spec-ref enum 'root))
  (define root (build-path repo root-rel))
  (unless (directory-exists? root)
    (drift-error "glob root ~a is missing under ~a" root-rel repo))
  (define ext (spec-ref enum 'ext))
  (define skip-basenames (spec-ref enum 'skip-basenames '()))
  (define skip-suffixes (spec-ref enum 'skip-suffixes '()))
  (define skip-prefixes (spec-ref enum 'skip-prefixes '()))
  (define files
    (walk-ext root ext #:recursive? (spec-ref enum 'recursive #t)))
  (sort
   (for/list ([f (in-list files)]
              #:unless (let ([under-root (path->string (find-relative-path
                                                        (path->directory-path root) f))]
                             [base (path->string (file-name-from-path f))])
                         (or (member base skip-basenames)
                             (ormap (lambda (s) (string-suffix? base s)) skip-suffixes)
                             (ormap (lambda (p) (string-prefix? under-root p)) skip-prefixes))))
     (relpath repo f))
   string<?))

(define (derive-bash-array repo enum)
  (define source (spec-ref enum 'source))
  (define text (read-enumerator-source repo source))
  (assert-shape-markers text (spec-ref enum 'shape-markers '())
                        (format "bash-array ~a" source))
  (define name (spec-ref enum 'array-name))
  (define m (regexp-match (pregexp (string-append "(?s:" (regexp-quote name) "=\\((.*?)\\))"))
                          text))
  (unless m
    (drift-error "bash-array ~a: array ~a=( ... ) not found" source name))
  (define elems (filter non-empty-string? (regexp-split #px"\\s+" (string-trim (cadr m)))))
  (when (null? elems)
    (drift-error "bash-array ~a: array ~a is empty" source name))
  (elems->paths repo enum elems))

(define (derive-bash-for-list repo enum)
  (define source (spec-ref enum 'source))
  (define text (read-enumerator-source repo source))
  (assert-shape-markers text (spec-ref enum 'shape-markers '())
                        (format "bash-for-list ~a" source))
  (define var (spec-ref enum 'loop-var))
  (define m (regexp-match
             (pregexp (string-append "for\\s+" (regexp-quote var) "\\s+in\\s+([^;\n]*?)\\s*;\\s*do"))
             text))
  (unless m
    (drift-error "bash-for-list ~a: `for ~a in ... ; do` not found" source var))
  (define elems (filter non-empty-string? (regexp-split #px"\\s+" (string-trim (cadr m)))))
  (when (null? elems)
    (drift-error "bash-for-list ~a: loop over ~a is empty" source var))
  (elems->paths repo enum elems))

(define (elems->paths repo enum elems)
  (define template (spec-ref enum 'template))
  (sort
   (for/list ([e (in-list elems)])
     (define rel (string-replace template "{}" e))
     (define full (build-path repo rel))
     (unless (file-exists? full)
       (drift-error "enumerated source ~a does not exist (stale enumerator or moved file)" rel))
     rel)
   string<?))

(define (derive-find-exclude repo enum)
  (define source (spec-ref enum 'source))
  (assert-shape-markers (read-enumerator-source repo source)
                        (spec-ref enum 'shape-markers '())
                        (format "find-exclude ~a" source))
  (define ext (spec-ref enum 'ext))
  (define not-paths (spec-ref enum 'find-not-paths '()))
  (define excl-prefixes (spec-ref enum 'exclude-relpath-prefixes '()))
  (define excl-basenames (spec-ref enum 'exclude-basenames '()))
  (define files (walk-ext repo ext #:recursive? #t #:prune-extra not-paths))
  (sort
   (for/list ([f (in-list files)]
              #:unless (let ([rel (relpath repo f)]
                             [base (path->string (file-name-from-path f))])
                         (or (ormap (lambda (p) (string-prefix? rel (string-append p "/"))) not-paths)
                             (ormap (lambda (p) (string-prefix? rel p)) excl-prefixes)
                             (member base excl-basenames))))
     (relpath repo f))
   string<?))

;; --- consumer-level derivation -----------------------------------------------
(struct consumer-result (name repo rev target relpaths count sha256 enumerators)
  #:transparent)

;; enumerators here is a list of (source . count) provenance pairs.
(define (derive-consumer c)
  (define repo (consumer-repo-path c))
  (unless (directory-exists? repo)
    (drift-error "consumer ~a: repo ~a not found" (consumer-name c) repo))
  (define enums (spec-ref c 'enumerators))
  (define provenance '())
  (define all
    (append*
     (for/list ([enum (in-list enums)])
       (define paths (derive-enumerator repo enum))
       (set! provenance
             (cons (cons (spec-ref enum 'source #f) (length paths)) provenance))
       paths)))
  (define relpaths (sort (remove-duplicates all) string<?))
  (consumer-result
   (consumer-name c)
   (path->string repo)
   (git-rev repo)
   (spec-ref c 'target)
   relpaths
   (length relpaths)
   (sha256-of-string (string-join relpaths "\n"))
   (reverse provenance)))

(define (load-consumers [path (registry-path)])
  (call-with-input-file path read))

(define (derive-all [path (registry-path)])
  (for/list ([c (in-list (load-consumers path))]) (derive-consumer c)))

;; --- JSON projection (list output only) --------------------------------------
(define (result->jsexpr r)
  (hasheq 'name (consumer-result-name r)
          'repo (consumer-result-repo r)
          'rev (consumer-result-rev r)
          'target (consumer-result-target r)
          'membership
          (hasheq 'count (consumer-result-count r)
                  'sha256 (consumer-result-sha256 r)
                  'enumerators
                  (for/list ([p (in-list (consumer-result-enumerators r))])
                    (hasheq 'source (or (car p) 'null) 'count (cdr p)))
                  'relpaths (consumer-result-relpaths r))))

(define (list->jsexpr results)
  (hasheq 'schema "beagle-downstream-list/1"
          'consumer_count (length results)
          'consumers (map result->jsexpr results)))
