#lang racket/base

;; Zig backend golden snapshots (thread 20260612232001, brief §7.1).
;;
;; Each fixtures/zig-golden/NN-name.bgl compiles (target injected) and
;; must match its committed NN-name.zig snapshot byte-for-byte — any
;; diff is a deliberate, reviewed change. Re-bless after a reviewed
;; emitter change with:
;;
;;   BEAGLE_ZIG_BLESS=1 raco test beagle-test/tests/emit-zig.rkt
;;
;; Additionally every snapshot must COMPILE: when `zig` is on PATH the
;; suite runs `zig build-obj -fno-emit-bin` over each snapshot (with the
;; kernel prelude copied alongside), so snapshots can't rot into
;; non-Zig. Without zig the compile check is skipped (snapshot
;; comparison still runs).
;;
;; Also here: pointed-rejection cases — out-of-table IR must error with
;; "not yet supported by zig backend", never silently approximate.

(require rackunit
         racket/file
         racket/path
         racket/string
         racket/system
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "zig-golden")))

(define kernel-rt
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (simplify-path (build-path dir 'up 'up "kernel" "src" "beagle_rt.zig"))))

(define bless? (and (getenv "BEAGLE_ZIG_BLESS") #t))

(define (compile-zig-src src-path)
  (define stxs (read-beagle-syntax src-path))
  (define forms (cons (datum->syntax #f '(define-target zig)) stxs))
  (define prog (parse-program forms #:source-path src-path))
  (type-check! prog)
  (emit-program prog))

(define (compile-zig-forms . datums)
  (define forms (map (lambda (d) (datum->syntax #f d))
                     (cons '(define-target zig) datums)))
  (define prog (parse-program forms))
  (type-check! prog)
  (emit-program prog))

(define (compile-zig-string src)
  ;; through the REAL beagle reader (brackets/braces), via a temp file.
  (define f (make-temporary-file "zigsrc~a.bgl"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'replace (lambda (p) (display src p)))
      (compile-zig-src f))
    (lambda () (delete-file f))))

(define ZIG (find-executable-path "zig"))
(unless ZIG
  (displayln "note: zig not on PATH — snapshot compile checks skipped"))

(define (zig-compiles? zig-src name)
  (define dir (make-temporary-file "zigck~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (copy-file kernel-rt (build-path dir "beagle_rt.zig"))
      (define f (build-path dir (format "~a.zig" name)))
      (call-with-output-file f (lambda (p) (display zig-src p)))
      (define out (open-output-string))
      (define ok
        (parameterize ([current-output-port out]
                       [current-error-port out]
                       [current-directory dir])
          (system* ZIG "build-obj" "-fno-emit-bin" (path->string f))))
      (unless ok
        (eprintf "zig compile check failed for ~a:\n~a\n" name
                 (get-output-string out)))
      ok)
    (lambda () (delete-directory/files dir))))

(define fixture-files
  (sort (for/list ([f (in-list (directory-list fixtures-dir))]
                   #:when (regexp-match? #rx"\\.bgl$" (path->string f)))
          (path->string f))
        string<?))

(for ([bgl (in-list fixture-files)])
  (define name (regexp-replace #rx"\\.bgl$" bgl ""))
  (define snap-path (build-path fixtures-dir (string-append name ".zig")))
  (define emitted (compile-zig-src (build-path fixtures-dir bgl)))
  (when bless?
    (call-with-output-file snap-path #:exists 'replace
      (lambda (p) (display emitted p))))
  (test-case (format "golden: ~a matches snapshot" name)
    (check-true (file-exists? snap-path)
                (format "missing snapshot ~a (run with BEAGLE_ZIG_BLESS=1)" name))
    (check-equal? emitted (file->string snap-path)))
  (when ZIG
    (test-case (format "golden: ~a compiles as zig" name)
      (check-true (zig-compiles? emitted name)))))

;; --- determinism: same input → byte-identical output --------------------------

(test-case "emission is deterministic"
  (define f (build-path fixtures-dir "07-loop-recur.bgl"))
  (check-equal? (compile-zig-src f) (compile-zig-src f)))

;; --- pointed rejections (out-of-table IR) --------------------------------------

(define-syntax-rule (check-unsupported name rx form ...)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-forms form ...)))))

(check-unsupported "zig rejects untyped def pointedly"
  #rx"untyped def"
  '(def x 42))

(check-unsupported "zig rejects defn without return annotation"
  #rx"return annotation"
  '(defn f [x :- Int] x))

(define-syntax-rule (check-unsupported/src name rx src)
  (test-case name
    (check-exn (lambda (e)
                 (and (exn:fail? e)
                      (regexp-match? #rx"not yet supported by zig backend" (exn-message e))
                      (regexp-match? rx (exn-message e))))
               (lambda () (compile-zig-string src)))))

(check-unsupported/src "zig rejects map literals pointedly"
  #rx"map literal"
  "(ns g)\n(defn f [x :- Int] :- Int (do {:a x} x))")

(check-unsupported/src "zig rejects multi-arity defn"
  #rx"multi-arity"
  "(ns g)\n(defn f ([a :- Int] :- Int a) ([a :- Int b :- Int] :- Int (+ a b)))")

(check-unsupported "zig rejects variable shift amounts"
  #rx"shift"
  '(defn f [x :- Int n :- Int] :- Int (bit-shift-left x n)))

(check-unsupported "zig rejects / pointing at quot"
  #rx"quot"
  '(defn f [a :- Int b :- Int] :- Int (/ a b)))

(check-unsupported/src "zig rejects general qualified calls"
  #rx"qualified"
  "(ns g)\n(require clojure.string :as str)\n(defn f [s :- String] :- String (str/trim s))")
