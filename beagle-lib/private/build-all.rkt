#lang racket/base

(require racket/path
         racket/file
         racket/list
         racket/set
         racket/string
         "parse.rkt"
         "check.rkt"
         "emit.rkt"
         (only-in "emit-js.rkt" current-js-export-names)
         "lint.rkt"
         "error-format.rkt"
         "query.rkt"
         "extensions.rkt"
         "targets.rkt"
         (only-in "batch-compile.rkt" compile-source-for-target)
         ;; #33 datum-IR: build straight from fact triples, skipping the text trip
         (only-in "facts-roundtrip.rkt" edn-triples->syntax read-edn-triples))

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

;; Compile a syntax list to a target file. Shared by the text path
;; (build-one-file → read-beagle-syntax) and the datum-IR path (build-one-edn →
;; fact triples). `path` is the SOURCE .b* path — used for require resolution
;; (#:source-path), the extension/header check, in-place output naming, and error
;; locations. The two front-ends differ ONLY in how they obtain `stxs`.
(define (build-from-stxs stxs path out-dir json? warn? in-place? export-plan)
  (define type-errors 0)

  (define (handle-error e [loc-stx #f])
    (cond
      [json?
       (write-json-error (exn-message e) loc-stx)
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

    (define ok? #t)
    (type-check-with-locs! prog
      (lambda (e loc-stx)
        (set! ok? #f)
        (set! type-errors (+ type-errors 1))
        (handle-error e loc-stx))
      #:capture-types? #t)  ; emit-path: feed type table to emit-program below
    (unless (or ok? warn?) (error "type errors"))

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

    (with-output-to-file out-path #:exists 'replace
      (lambda () (display source)))

    (if (and warn? (not ok?))
        (begin
          (eprintf "  ~a -> ~a [~a warning(s)]\n" path (path->string out-path) type-errors)
          #t)
        (begin
          (eprintf "  ~a -> ~a\n" path (path->string out-path))
          #t))))

;; Text front-end: read source text → syntax → shared compile tail.
(define (build-one-file path out-dir json? export-plan
                        #:warn? [warn? #f] #:in-place? [in-place? #f])
  (with-handlers
    ([exn:fail? (lambda (e)
                  (if json? (write-json-error (exn-message e) #f)
                      (eprintf "  ~a: ~a\n" path (exn-message e)))
                  #f)])
    (build-from-stxs
     (read-beagle-syntax path) path out-dir json? warn? in-place? export-plan)))

;; Retargeted text front-end: force `target` through compile-source-for-target
;; instead of trusting the source's own #lang, mirroring `beagle-build --target`
;; for a batch (a whole invocation compiles under ONE forced target). Output
;; naming here is scratch-only (basename + target ext) — never a real ns path.
(define (build-one-file-target path out-dir json? target)
  (with-handlers
    ([exn:fail? (lambda (e)
                  (if json? (write-json-error (exn-message e) #f)
                      (eprintf "  ~a: ~a\n" path (exn-message e)))
                  #f)])
    (define source (compile-source-for-target path target))
    (define base (regexp-replace #rx"\\.b[a-z]+$"
                                 (path->string (file-name-from-path path)) ""))
    (define out-path (build-path (or out-dir ".") (string-append base (extension-for-target target))))
    (when out-dir (make-directory* out-dir))
    (with-output-to-file out-path #:exists 'replace (lambda () (display source)))
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
                  (if json? (write-json-error (exn-message e) #f)
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

(define (expand-args args)
  (sort
    (apply append
      (for/list ([a (in-list args)])
        (cond
          [(directory-exists? a) (find-rkt-files a)]
          [(regexp-match? BEAGLE-FILE-RX a) (list a)]
          [else
           (eprintf "beagle-build-all: skipping non-beagle file: ~a\n" a)
           '()])))
    string<?))

(define (run-build-all args)
  (define out-dir #f)
  (define warn? #f)
  (define in-place? #f)
  (define build-edn? #f)   ; #33: treat file-args as --emit-edn triple dumps
  (define target-override #f)   ; --target: force every file through this target
  (define file-args '())

  (let loop ([rest args])
    (cond
      [(null? rest) (void)]
      [(string=? (car rest) "--out")
       (when (null? (cdr rest))
         (eprintf "beagle-build-all: --out requires a directory argument\n")
         (exit 2))
       (set! out-dir (cadr rest))
       (loop (cddr rest))]
      [(string=? (car rest) "--warn")
       (set! warn? #t)
       (loop (cdr rest))]
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
      [else
       (set! file-args (append file-args (list (car rest))))
       (loop (cdr rest))]))

  (when (and out-dir in-place?)
    (eprintf "beagle-build-all: --out and --in-place are mutually exclusive\n")
    (exit 2))

  (when (and target-override build-edn?)
    (eprintf "beagle-build-all: --target and --build-edn are mutually exclusive\n")
    (exit 2))

  (when (null? file-args)
    (eprintf "usage: beagle-build-all <file-or-dir> ... [--out <dir>] [--in-place] [--warn]\n")
    (exit 2))

  ;; --build-edn args are triple dumps (any extension), not .b* source — take
  ;; them verbatim; the text path globs/filters for beagle source files.
  (define files (if build-edn? file-args (expand-args file-args)))

  (when (null? files)
    (eprintf "beagle-build-all: no ~a found\n"
             (if build-edn? "triple dumps" "beagle source files"))
    (exit 2))

  (define json? (json-error-mode?))
  (define export-plan (build-export-plan files build-edn?))
  (define built 0)
  (define errors 0)

  (for ([f (in-list files)])
    (define ok?
      (cond
        [build-edn?
         (build-one-edn f out-dir json? export-plan
                        #:warn? warn? #:in-place? in-place?)]
        [target-override (build-one-file-target f out-dir json? target-override)]
        [else
         (build-one-file f out-dir json? export-plan
                         #:warn? warn? #:in-place? in-place?)]))
    (if ok? (set! built (+ built 1)) (set! errors (+ errors 1))))

  (unless json?
    (eprintf "\n~a built, ~a error(s)\n" built errors))

  (exit (if (zero? errors) 0 1)))

(provide run-build-all)
