#lang racket/base

;; Odin backend golden snapshots.
;;
;; Each fixtures/odin-golden/NN-name.bgl compiles (target injected) and
;; must match its committed NN-name.odin snapshot byte-for-byte — any
;; diff is a deliberate, reviewed change. Re-bless after a reviewed
;; emitter change with:
;;
;;   BEAGLE_ODIN_BLESS=1 raco test beagle-test/tests/emit-odin.rkt

(require rackunit
         racket/file
         racket/path
         racket/string
         beagle/private/parse
         beagle/private/check
         beagle/private/emit)

(define fixtures-dir
  (let-values ([(dir _n _d?) (split-path (syntax-source #'here))])
    (build-path dir "fixtures" "odin-golden")))

(define bless? (and (getenv "BEAGLE_ODIN_BLESS") #t))

(define (compile-odin-src src-path)
  (define stxs (read-beagle-syntax src-path))
  (define forms (cons (datum->syntax #f '(define-target odin)) stxs))
  (define prog (parse-program forms #:source-path src-path))
  (type-check! prog)
  (emit-program prog))

;; Discover fixtures: every .bgl file in the directory.
(define fixture-files
  (sort
   (for/list ([f (in-list (directory-list fixtures-dir))]
              #:when (regexp-match? #rx"\\.bgl$" (path->string f)))
     f)
   string<? #:key path->string))

;; Snapshot comparison tests.
(for ([f (in-list fixture-files)])
  (define src-path (build-path fixtures-dir f))
  (define name (regexp-replace #rx"\\.bgl$" (path->string f) ""))
  (define golden-path (build-path fixtures-dir (string-append name ".odin")))
  (define result
    (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
      (compile-odin-src src-path)))

  (cond
    [bless?
     (call-with-output-file golden-path #:exists 'replace
       (lambda (p) (display result p)))
     (printf "  blessed ~a\n" name)]
    [(file-exists? golden-path)
     (define expected (file->string golden-path))
     (test-equal? (format "odin golden: ~a" name) result expected)]
    [else
     (printf "  SKIP ~a (no golden — run with BEAGLE_ODIN_BLESS=1)\n" name)]))

;; Pointed-rejection tests: forms the odin backend explicitly rejects.
(define (must-reject label src #:pattern [pattern #f])
  (test-case (format "odin rejects: ~a" label)
    (define f (make-temporary-file "odin-reject~a.bgl"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file f #:exists 'replace (lambda (p) (display src p)))
        (check-exn
         (if pattern (regexp pattern) exn:fail?)
         (lambda () (compile-odin-src f))))
      (lambda () (delete-file f)))))

(must-reject "regex literal"
             "(ns g) (defn f [s :- String] :- Bool (re-matches #\"\\\\d+\" s))"
             #:pattern "regex")

(must-reject "set literal"
             "(ns g) (def S :- Any #{1 2 3})"
             #:pattern "set")

(must-reject "Any-typed boundary"
             "(ns g) (defn f [] :- Any 42)"
             #:pattern "Any-typed")
