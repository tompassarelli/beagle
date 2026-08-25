#lang racket/base

(require json
         racket/path
         racket/file
         racket/list
         racket/runtime-path
         racket/set
         racket/string
         "parse.rkt"
         "check.rkt"
         "emit.rkt"
         (only-in "emit-nix.rkt" current-nix-module-omit-attrs)
         (only-in "emit-js.rkt"
                  current-js-export-names
                  js-emit-program-with-source-map)
         "lint.rkt"
         "module-overlay-check.rkt"
         "module-source-root.rkt"
         "module-source-root-cli.rkt"
         "canonical-value-v1.rkt"
         "error-format.rkt"
         "query.rkt"
         "shadow-facts-v1.rkt"
         "extensions.rkt"
         "targets.rkt"
         "nix-project.rkt"
         ;; #33 datum-IR: build straight from fact triples, skipping the text trip
         (only-in "facts-roundtrip.rkt" edn-triples->syntax read-edn-triples))

(define-runtime-path canonical-js-runtime-root "../lib")

(define (extension-for-target target)
  (case target
    [(js)   ".js"]
    [(py)   ".py"]
    [(nix)  ".nix"]
    [else   ".clj"]))

(define (ns->path ns-sym target)
  (define s (symbol->string ns-sym))
  (define file-ns
    (if (eq? target 'clj)
        (regexp-replace* #rx"-" s "_")
        s))
  (string-append (regexp-replace* #rx"\\." file-ns "/")
                 (extension-for-target target)))

(define (canonical-source-id path)
  (path->string (simplify-path (path->complete-path path))))

(define (source-map-source-id path)
  (path->string (file-name-from-path (string->path path))))

(define (write-js-artifacts prog path out-path source)
  (define source-content (file->string path))
  (define map-path
    (string->path (string-append (path->string out-path) ".map")))
  (define map-name (path->string (file-name-from-path map-path)))
  (define js-name (path->string (file-name-from-path out-path)))
  (define-values (mapped-source document)
    (js-emit-program-with-source-map prog
                                     (source-map-source-id path)
                                     source-content
                                     js-name))
  (unless (string=? source mapped-source)
    (error 'beagle-build-all
           "source-map annotation changed JavaScript bytes for ~a"
           path))
  (define source-with-url
    (string-append
     source
     (if (string-suffix? source "\n") "" "\n")
     "//# sourceMappingURL=" map-name "\n"))
  (with-output-to-file out-path #:exists 'replace
    (lambda () (display source-with-url)))
  (call-with-output-file map-path #:exists 'replace
    (lambda (port)
      (write-json document port)
      (newline port))))

(define (materialize-js-runtime-requires! prog out-dir)
  (when out-dir
    (for ([entry (in-list (program-requires prog))])
      (define relative-path (ns->path (require-entry-ns entry) 'js))
      (define runtime-source
        (build-path canonical-js-runtime-root relative-path))
      (when (file-exists? runtime-source)
        (define runtime-output (build-path out-dir relative-path))
        (make-parent-directory* runtime-output)
        (copy-file runtime-source runtime-output #t)))))

(define (emit-checked-program prog path out-dir in-place? export-plan
                              #:warning-count [warning-count 0]
                              #:artifact-sink
                              [artifact-sink (lambda (_path _target _source)
                                               (void))])
  ;; Extension/header mismatch check
  (define expected-tgt (expected-target-for-extension path))
  (when (extension-target-mismatch? path (program-target prog))
    (define ext-str
      (car (findf (lambda (pair) (string-suffix? path (car pair)))
                  EXTENSION-TARGET-MAP)))
    (error (format "extension/header mismatch: ~a expects #lang ~a, found #lang ~a"
                   ext-str
                   (lang-for-target-id expected-tgt)
                   (lang-for-target-id (program-target prog)))))

  (unless (getenv "BEAGLE_NO_LINT")
    (lint-program! prog))

  (define ns (program-namespace prog))
  (define target (program-target prog))
  (define source
    (parameterize
      ([current-js-export-names
        (and (eq? target 'js)
             (hash-ref export-plan ns (set)))])
      (emit-program prog)))
  (artifact-sink path target source)
  (define out-path
    (cond
      [in-place?
       (string->path
        (string-append (regexp-replace #rx"\\.b[a-z]+$" path "")
                       (extension-for-target target)))]
      [out-dir
       (build-path out-dir (ns->path ns target))]
      [else
       (string->path (ns->path ns target))]))

  (define out-dir-part (path-only out-path))
  (when out-dir-part
    (make-directory* out-dir-part))

  (if (eq? target 'js)
      (begin
        (write-js-artifacts prog path out-path source)
        (materialize-js-runtime-requires! prog out-dir))
      (with-output-to-file out-path #:exists 'replace
        (lambda () (display source))))

  (if (positive? warning-count)
      (eprintf "  ~a -> ~a [~a warning(s)]\n"
               path (path->string out-path) warning-count)
      (eprintf "  ~a -> ~a\n" path (path->string out-path)))
  #t)

;; Compile a syntax list to a target file. Shared by the text path
;; (build-one-file → read-beagle-syntax) and the datum-IR path (build-one-edn →
;; fact triples). `path` is the SOURCE .b* path — used for require resolution
;; (#:source-path), the extension/header check, in-place output naming, and error
;; locations. The two front-ends differ ONLY in how they obtain `stxs`.
(define (build-from-stxs stxs path out-dir json? warn? in-place? export-plan)
  (let/ec reject-build
    (define type-errors 0)
    (define hard-errors 0)

  (define (handle-error e [loc-stx #f])
    (cond
      [json?
       (write-json-error e loc-stx)
       #f]
      [else
       (define loc
         (cond
           [(and loc-stx (syntax-line loc-stx))
            (define src (syntax-source loc-stx))
            (define file-str
              (cond [(path? src) (path->string src)]
                    [(string? src) src]
                    [else path]))
            (format "~a:~a" file-str (syntax-line loc-stx))]
           [else path]))
       (eprintf "  ~a: ~a\n" loc (exn-message e))
       #f]))

  (with-handlers
    ([exn:fail? (lambda (e) (handle-error e #f))])
    (define prog (parse-program stxs #:source-path path))

    (define ok? #t)
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (set! ok? #f)
        (set! type-errors (+ type-errors 1))
        ;; --warn deliberately keeps ordinary type-error emission available to
        ;; repair/oracle consumers. A purity diagnostic whose configured
        ;; severity reached `error` is different: publishing that program would
        ;; break the checked no-unmarked-effects contract.
        (when (and (beagle-diagnostic? e)
                   (eq? (beagle-diagnostic-kind e) 'purity-leak))
          (set! hard-errors (+ hard-errors 1)))
        (handle-error e loc-stx))
      #:capture-types? #t)  ; emit-path: feed type table to emit-program below
    ;; Each check error has already been reported. Stop before lint/emission
    ;; without throwing a second generic exception that would duplicate and
    ;; erase the structured diagnostic in JSON mode.
    (unless (or ok? (and warn? (zero? hard-errors)))
      (reject-build #f))

    (emit-checked-program
     prog path out-dir in-place? export-plan
     #:warning-count (if (and warn? (not ok?)) type-errors 0)))))

;; Text front-end: read source text → syntax → shared compile tail.
(define (build-one-file path out-dir json? export-plan
                        #:warn? [warn? #f] #:in-place? [in-place? #f])
  (with-handlers
    ([exn:fail? (lambda (e)
                  (if json? (write-json-error e #f)
                      (eprintf "  ~a: ~a\n" path (exn-message e)))
                  #f)])
    (build-from-stxs
     (read-beagle-syntax path) path out-dir json? warn? in-place? export-plan)))

;; Retargeted text front-end: force `target` through the same reader → parse →
;; check → emit stages without trusting the source's own #lang. Output naming
;; here is scratch-only (basename + target ext) — never a real ns path.
(define (compile-target-program path target)
  ;; Keep the checked program that produced the JavaScript so the annotated
  ;; source-map pass observes the identical type and source-location tables.
  (define prog
    (parse-program
     (retarget-beagle-syntax (read-beagle-syntax path) target)
     #:source-path path))
  (type-check-with-locs!
   prog
   (lambda (error _location) (raise error))
   #:capture-types? #t)
  (unless (getenv "BEAGLE_NO_LINT")
    (lint-program! prog)
    (check-scalar-provenance! prog))
  prog)

(define (build-one-file-target path out-dir json? target)
  (with-handlers
    ([exn:fail? (lambda (e)
                  (if json? (write-json-error e #f)
                      (eprintf "  ~a: ~a\n" path (exn-message e)))
                  #f)])
    (define prog (compile-target-program path target))
    (define source (emit-program prog))
    (define base (regexp-replace #rx"\\.b[a-z]+$"
                                 (path->string (file-name-from-path path)) ""))
    (define out-path (build-path (or out-dir ".") (string-append base (extension-for-target target))))
    (when out-dir (make-directory* out-dir))
    (if (eq? target 'js)
        (write-js-artifacts prog path out-path source)
        (with-output-to-file out-path #:exists 'replace
          (lambda () (display source))))
    (eprintf "  ~a -> ~a\n" path (path->string out-path))
    #t))

;; The `@file <path>` header line an --emit-edn dump carries (the original source
;; path) — used as #:source-path so cross-module requires still resolve.
(define (edn-file-source triples-path)
  (for/or ([line (in-list (file->lines triples-path))])
    (and (>= (string-length line) 6)
         (string=? (substring line 0 6) "@file ")
         (string-trim (substring line 6)))))

;; #33 datum-IR front-end: compile straight from fact triples (the --emit-edn
;; shape), skipping the text round-trip. edn-triples->datum rebuilds the
;; (beagle-file form ...) datum the reader would have produced; we drop the
;; wrapper head and hand the forms — as syntax — to the SAME compile tail, so the
;; output is identical to the text path (KEYSTONE-B). Slice-1: the datum is bare,
;; so blame/srclocs degrade (closed later by adding line/col/pos facts).
(define (build-one-edn triples-path out-dir json? export-plan
                       #:warn? [warn? #f] #:in-place? [in-place? #f])
  (with-handlers
    ([exn:fail? (lambda (e)
                  (if json? (write-json-error e #f)
                      (eprintf "  ~a: ~a\n" triples-path (exn-message e)))
                  #f)])
    (define src-path (or (edn-file-source triples-path) triples-path))
    ;; srcloc source must match read-beagle-syntax's (simplify-path∘complete-path)
    ;; so the emitted ^{:line :file} provenance is byte-identical to the text path.
    (define srcloc-source (simplify-path (path->complete-path src-path)))
    (define wrapper (edn-triples->syntax (read-edn-triples triples-path) srcloc-source))
    (define forms (if wrapper (syntax->list wrapper) '()))
    (define stxs
      (if (and (pair? forms) (eq? (syntax->datum (car forms)) 'beagle-file))
          (cdr forms) forms))
    (build-from-stxs
     stxs src-path out-dir json? warn? in-place? export-plan)))

;; Exact ESM export demand for a batch. A named `:refer` requests only those
;; bindings; a namespace import requests every public defn. The emitter keeps
;; declaration rendering separate and receives only this set-valued sink plan.
(define (programs->export-plan programs)
  (for/fold ([plan (hash)])
            ([prog (in-list programs)]
             #:when prog)
    (for/fold ([next plan])
              ([r (in-list (program-requires prog))])
      (define ns (require-entry-ns r))
      (define requested
        (if (require-entry-refer r)
            (list->set (require-entry-refer r))
            (set '*)))
      (hash-update next ns
                   (lambda (prior) (set-union prior requested))
                   (set)))))

(define (build-export-plan files build-edn?)
  (define programs
    (for/list ([f (in-list files)])
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (cond
          [build-edn?
           (define src-path (or (edn-file-source f) f))
           (define srcloc-source (simplify-path (path->complete-path src-path)))
           (define wrapper
             (edn-triples->syntax (read-edn-triples f) srcloc-source))
           (define forms (if wrapper (syntax->list wrapper) '()))
           (define stxs
             (if (and (pair? forms)
                      (eq? (syntax->datum (car forms)) 'beagle-file))
                 (cdr forms)
                 forms))
           (parse-program stxs #:source-path src-path)]
          [else
           (parse-program (read-beagle-syntax f) #:source-path f)]))))
  (programs->export-plan (filter values programs)))

(define (build-text-overlay files roots out-dir json? in-place? shadow-output
                            check-profile)
  (define captured '())
  (define source->file (make-hash))
  (define source->profile-path (make-hash))
  (define emitted-artifacts (make-hash))
  (define (capture! source _phase value location)
    (set! captured (cons (list source value location) captured)))
  (define (report! source value location)
    (define source-id (and source (format "~a" source)))
    (define path
      (hash-ref source->file source-id
                (lambda () (or source-id (car files)))))
    (define error
      (if (exn? value)
          value
          (make-exn:fail (format "~a" value) (current-continuation-marks))))
    (if json?
        (begin
          (write-json-error error location)
          (flush-output (current-error-port)))
        (eprintf "  ~a: ~a\n" path (exn-message error))))
  (define explicit-inputs
    (for/list ([path (in-list files)])
      (define source-id (module-source-logical-id-for-path roots path))
      (hash-set! source->file source-id path)
      (module-source-input source-id path)))
  (define closure
    (with-handlers
        ([exn:fail?
          (lambda (error)
            (capture! (car files) 'resolve error #f)
            #f)])
      (resolve-module-source-closure explicit-inputs roots)))
  (when closure
    (for ([snapshot (in-list (module-source-closure-snapshots closure))])
      (define source-id (module-source-snapshot-source-id snapshot))
      (hash-set!
       source->profile-path
       source-id
       (if (module-source-snapshot-target-override snapshot)
           source-id
           (path->string (module-source-snapshot-physical-path snapshot))))
      (unless (hash-has-key? source->file source-id)
        (hash-set!
         source->file
         source-id
         (path->string (module-source-snapshot-physical-path snapshot))))))
  (define checked
    (and closure
         (null? captured)
         (check-module-source-closure
          closure
          #:check-profile check-profile
          #:capture-types? #t
          #:shadow-facts? (and shadow-output #t)
          #:emit? #f
          #:diagnostic-sink capture!)))
  (when (and checked
             (not (overlay-check-result-ok? checked))
             (null? captured))
    (for ([diagnostic
           (in-list (overlay-check-result-diagnostics checked))])
      (capture!
       (overlay-diagnostic-source diagnostic)
       (overlay-diagnostic-phase diagnostic)
       (make-exn:fail
        (overlay-diagnostic-message diagnostic)
        (current-continuation-marks))
       #f)))
  (for ([entry (in-list (reverse captured))])
    (report! (car entry) (cadr entry) (caddr entry)))
  (cond
    [(or (not checked) (not (overlay-check-result-ok? checked)))
     (values 0 (max 1 (length captured)))]
    [else
     (define modules (overlay-check-result-modules checked))
     (define export-plan
       (programs->export-plan
        (map checked-overlay-module-program modules)))
     (define-values (built errors)
       (for/fold ([built 0] [errors 0])
                 ([module (in-list modules)])
         (define source-id (format "~a" (checked-overlay-module-source module)))
         (define path (hash-ref source->file source-id source-id))
         (define profile-path
           (hash-ref source->profile-path source-id path))
         (if
          (with-handlers
              ([exn:fail?
                (lambda (error)
                  (report! source-id error #f)
                  #f)])
            (emit-checked-program
             (checked-overlay-module-program module)
             profile-path out-dir in-place? export-plan
             #:artifact-sink
             (lambda (_path target source)
               (hash-set!
                emitted-artifacts
                source-id
                (vector source-id
                        target
                        (canonical-value-v1-id source))))))
          (values (add1 built) errors)
          (values built (add1 errors)))))
     (when (and shadow-output (zero? errors))
       (shadow-fact-graph-v1-write
        (shadow-fact-graph-v1-from-modules
         (for/list ([module (in-list modules)])
           (shadow-fact-module-input-v1
            (checked-overlay-module-source module)
            (checked-overlay-module-namespace module)
            (checked-overlay-module-program module)
            (checked-overlay-module-interface module)))
         #:source-snapshots
         (module-source-closure-snapshots closure)
         #:artifacts emitted-artifacts)
        shadow-output))
     (values built errors)]))

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-beagle-files a)]
          [(regexp-match? BEAGLE-FILE-RX a) (list a)]
          [else
           (eprintf "beagle-build-all: skipping non-beagle file: ~a\n" a)
           '()])))
    string<?))

(define (run-build-all args)
  (define out-dir #f)
  (define warn? #f)
  (define in-place? #f)
  (define shadow-output #f)
  (define build-edn? #f)   ; #33: treat file-args as --emit-edn triple dumps
  (define target-override #f)   ; --target: force every file through this target
  (define nix-project-manifest #f)
  (define check-profile (current-check-profile))
  (define file-args '())

  (define-values (roots args-without-roots)
    (parse-module-root-arguments args 'beagle-build-all))

  (let loop ([rest args-without-roots])
    (cond
      [(null? rest) (void)]
      [(string=? (car rest) "--out")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --out requires a directory argument\n")
         (exit 2))
       (set! out-dir (cadr rest))
       (loop (cddr rest))]
      [(string=? (car rest) "--shadow-facts")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --shadow-facts requires a graph path\n")
         (exit 2))
       (set! shadow-output (cadr rest))
       (loop (cddr rest))]
      [(string-prefix? (car rest) "--shadow-facts=")
       (set! shadow-output (substring (car rest) (string-length "--shadow-facts=")))
       (loop (cdr rest))]
      [(string=? (car rest) "--warn")
       (set! warn? #t)
       (loop (cdr rest))]
      [(string=? (car rest) "--profile")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --profile requires 0, 1, 2, or 3\n")
         (exit 2))
       (let ([parsed-profile (string->number (cadr rest))])
         (unless (and parsed-profile
                      (exact-integer? parsed-profile)
                      (<= 0 parsed-profile 3))
           (eprintf "beagle-build-all: --profile must be 0, 1, 2, or 3\n")
           (exit 2))
         (set! check-profile parsed-profile))
       (loop (cddr rest))]
      [(string=? (car rest) "--in-place")
       (set! in-place? #t)
       (loop (cdr rest))]
      [(string=? (car rest) "--build-edn")
       (set! build-edn? #t)
       (loop (cdr rest))]
      [(string=? (car rest) "--target")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --target requires a target argument\n")
         (exit 2))
       (set! target-override (string->symbol (cadr rest)))
       (loop (cddr rest))]
      [(string=? (car rest) "--nix-project")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --nix-project requires a .bnix manifest\n")
         (exit 2))
       (set! nix-project-manifest (cadr rest))
       (loop (cddr rest))]
      [else
       (set! file-args (append file-args (list (car rest))))
       (loop (cdr rest))]))

  (when (and out-dir in-place?)
    (eprintf "beagle-build-all: --out and --in-place are mutually exclusive\n")
    (exit 2))

  (when (and target-override build-edn?)
    (eprintf "beagle-build-all: --target and --build-edn are mutually exclusive\n")
    (exit 2))

  (when (and nix-project-manifest (pair? file-args))
    (eprintf "beagle-build-all: --nix-project owns membership; do not pass source paths\n")
    (exit 2))

  (when (and nix-project-manifest
             (or (not in-place?) out-dir target-override build-edn? warn?
                 (pair? roots)))
    (eprintf
     "beagle-build-all: --nix-project requires --in-place and cannot be combined with other build modes\n")
    (exit 2))

  (when (and (pair? roots) (or target-override build-edn? warn?))
    (eprintf
     "beagle-build-all: --module-root cannot be combined with --target, --build-edn, or --warn\n")
    (exit 2))

  (when (and shadow-output (or target-override build-edn? warn?))
    (eprintf
     "beagle-build-all: --shadow-facts requires the ordinary whole-module build path\n")
    (exit 2))

  (when (and (null? file-args) (not nix-project-manifest))
    (eprintf
     "usage: beagle-build-all <file-or-dir> ... [--profile 0|1|2|3] [--module-root LOGICAL=PHYSICAL]... [--out <dir>] [--in-place] [--warn]\n       beagle-build-all --nix-project PROJECT.bnix --in-place\n")
    (exit 2))

  ;; --build-edn args are triple dumps (any extension), not .b* source — take
  ;; them verbatim; the text path globs/filters for beagle source files.
  (define project
    (and nix-project-manifest
         (load-nix-project (current-directory) nix-project-manifest)))
  (define files
    (cond
      [project
       (for/list ([rel (in-list (nix-project-members project))])
         (path->string (build-path (nix-project-root project) rel)))]
      [build-edn? file-args]
      [else (expand-args file-args)]))

  (when (null? files)
    (eprintf "beagle-build-all: no ~a found\n"
             (if build-edn? "triple dumps" "beagle source files"))
    (exit 2))

  (define json? (json-error-mode?))
  (define built 0)
  (define errors 0)

  (parameterize
      ([current-check-profile check-profile]
       [current-nix-module-omit-attrs
        (if project (nix-project-omit-module-attrs project) '())])
    (cond
      [(and (not build-edn?) (not target-override) (not warn?))
       (define-values (overlay-built overlay-errors)
         (build-text-overlay
          files roots out-dir json? in-place? shadow-output check-profile))
       (set! built overlay-built)
       (set! errors overlay-errors)]
      [else
       ;; Retargeted, EDN-authored, and explicitly warning builds retain their
       ;; dedicated paths; they do not claim checked text-overlay semantics.
       (define export-plan (build-export-plan files build-edn?))
       (for ([f (in-list files)])
         (define ok?
           (cond
             [build-edn?
              (build-one-edn f out-dir json? export-plan
                             #:warn? warn? #:in-place? in-place?)]
             [target-override
              (build-one-file-target f out-dir json? target-override)]
             [else
              (build-one-file f out-dir json? export-plan
                              #:warn? warn? #:in-place? in-place?)]))
         (if ok? (set! built (+ built 1)) (set! errors (+ errors 1))))]))

  (unless json?
    (eprintf "\n~a built, ~a error(s)\n" built errors))

  (exit (if (zero? errors) 0 1)))

(provide run-build-all)
