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
;; Each returns (values sorted-relpaths excluded-alist): a sorted list of
;; repo-relative membership paths plus an alist of (relpath . class) for
;; accountable non-membership files (only find-exclude classifies excludes;
;; the others return '()). Raises exn:fail:drift when the enumerator's shape
;; no longer matches or accounting fails closed.
(define (derive-enumerator repo enum)
  (case (spec-ref enum 'kind)
    [(glob)          (values (derive-glob repo enum) '())]
    [(bash-array)    (values (derive-bash-array repo enum) '())]
    [(bash-for-list) (values (derive-bash-for-list repo enum) '())]
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

(define (rel-basename rel) (last (string-split rel "/")))

;; find-exclude derives firn-build's EMIT membership (discovery minus the
;; firn-build skip arms) and reconciles the excluded remainder against an
;; explicit classification, failing closed on any silent membership gap.
(define (derive-find-exclude repo enum)
  ;; 1. firn-build's emit-discovery contract — source of the membership rule.
  (define build-source (spec-ref enum 'source))
  (assert-shape-markers (read-enumerator-source repo build-source)
                        (spec-ref enum 'shape-markers '())
                        (format "find-exclude ~a" build-source))
  ;; 2. firn-validate's broader discovery contract — the authority that
  ;;    separates intentionally-broken fixtures from real-but-non-emitted
  ;;    sources. Its presence + shape is asserted so a change to firn's
  ;;    validation surface trips drift too.
  (define validate-source (spec-ref enum 'validate-source #f))
  (when validate-source
    (assert-shape-markers (read-enumerator-source repo validate-source)
                          (spec-ref enum 'validate-shape-markers '())
                          (format "find-exclude ~a" validate-source)))
  (define ext (spec-ref enum 'ext))
  (define not-paths (spec-ref enum 'find-not-paths '()))
  (define excl-prefixes (spec-ref enum 'exclude-relpath-prefixes '()))
  (define excl-basenames (spec-ref enum 'exclude-basenames '()))
  (define neg-prefixes (spec-ref enum 'validate-negative-prefixes '()))
  ;; classified-excludes: ((relpath R) (class C)) specs -> alist relpath->class.
  (define classified-alist
    (for/list ([entry (in-list (spec-ref enum 'classified-excludes '()))])
      (cons (spec-ref entry 'relpath) (spec-ref entry 'class))))
  ;; discovery: every .bnix under the repo, pruning only VCS/build noise. This
  ;; is firn-validate's discovery universe (a superset of firn-build's emit set).
  (define discovered
    (sort (map (lambda (f) (relpath repo f))
               (walk-ext repo ext #:recursive? #t #:prune-extra not-paths))
          string<?))
  ;; firn-build's emit membership: discovery minus the firn-build skip arms.
  (define (firn-build-excludes? rel)
    (or (ormap (lambda (p) (string-prefix? rel p)) excl-prefixes)
        (member (rel-basename rel) excl-basenames)))
  (define membership (filter (lambda (r) (not (firn-build-excludes? r))) discovered))
  (define excluded   (filter firn-build-excludes? discovered))
  ;; --- FAIL-CLOSED ACCOUNTING ------------------------------------------------
  ;; (a) Every firn-build-excluded .bnix must be explicitly classified. A good
  ;;     source dropped under an excluded prefix, or a new negative fixture,
  ;;     therefore trips a pointed drift instead of silently leaving membership.
  (define classified-set (map car classified-alist))
  (for ([rel (in-list excluded)])
    (unless (member rel classified-set)
      (drift-error (string-append
                    "firn-build excludes ~s from its emit membership but the registry "
                    "has not classified it — add a classified-excludes entry "
                    "(class negative-fixture | resolver-input | doc-fixture) or make it "
                    "a real firn module (silent-membership-gap guard)")
                   rel)))
  ;; (b) No stale classification: every classified relpath must still be a
  ;;     firn-build-excluded discovered file.
  (for ([entry (in-list classified-alist)])
    (define rel (car entry))
    (unless (member rel excluded)
      (drift-error (string-append
                    "classified exclude ~s is stale — it is not a firn-build-excluded "
                    "discovered .bnix (file removed, moved, or now in membership); "
                    "remove it from the registry")
                   rel)))
  ;; (c) firn-validate reconciliation of each class:
  ;;     negative-fixture      <=> firn-validate ALSO excludes it (under a
  ;;                               validate-negative-prefix);
  ;;     resolver-input/doc-fixture <=> firn-validate validates it (NOT under one).
  (define (under-neg? rel) (ormap (lambda (p) (string-prefix? rel p)) neg-prefixes))
  (for ([entry (in-list classified-alist)])
    (define rel (car entry))
    (define cls (cdr entry))
    (case cls
      [(negative-fixture)
       (unless (under-neg? rel)
         (drift-error (string-append
                       "~s is classified negative-fixture but firn-validate does not "
                       "exclude it (not under ~a); reclassify as resolver-input/doc-fixture")
                      rel neg-prefixes))]
      [(resolver-input doc-fixture)
       (when (under-neg? rel)
         (drift-error (string-append
                       "~s is classified ~a but firn-validate excludes it as a fixture; "
                       "reclassify as negative-fixture")
                      rel cls))]
      [else (drift-error "unknown exclude class ~a for ~s (expected negative-fixture | resolver-input | doc-fixture)"
                         cls rel)]))
  (values membership (sort classified-alist string<? #:key car)))

;; --- consumer-level derivation -----------------------------------------------
;; `excluded` is an alist of (relpath . class-symbol): the accountable
;; non-membership files a find-exclude enumerator classified. Empty for every
;; other enumerator kind.
(struct consumer-result (name repo rev target relpaths count sha256 enumerators excluded)
  #:transparent)

;; enumerators here is a list of (source . count) provenance pairs.
(define (derive-consumer c)
  (define repo (consumer-repo-path c))
  (unless (directory-exists? repo)
    (drift-error "consumer ~a: repo ~a not found" (consumer-name c) repo))
  (define enums (spec-ref c 'enumerators))
  (define provenance '())
  (define excluded '())
  (define all
    (append*
     (for/list ([enum (in-list enums)])
       (define-values (paths exc) (derive-enumerator repo enum))
       (set! provenance
             (cons (cons (spec-ref enum 'source #f) (length paths)) provenance))
       (set! excluded (append excluded exc))
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
   (reverse provenance)
   (sort excluded string<? #:key car)))

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
                  'relpaths (consumer-result-relpaths r)
                  'excluded
                  (for/list ([p (in-list (consumer-result-excluded r))])
                    (hasheq 'relpath (car p) 'class (symbol->string (cdr p)))))))

(define (list->jsexpr results)
  (hasheq 'schema "beagle-downstream-list/1"
          'consumer_count (length results)
          'consumers (map result->jsexpr results)))
