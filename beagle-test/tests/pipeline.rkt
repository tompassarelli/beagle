#lang racket/base

;; End-to-end pipeline tests: read source → check → emit → (optionally) run.

(require rackunit
         racket/file
         racket/port
         beagle/private/pipeline
         beagle/private/eval-standard)

(define (with-temp-source text proc)
  (define tmp (make-temporary-file "beagle-pipeline-~a.bgl"))
  (with-handlers ([exn:fail? (lambda (e) (delete-file tmp) (raise e))])
    (with-output-to-file tmp #:exists 'replace
      (lambda () (display text)))
    (define r (proc tmp))
    (delete-file tmp)
    r))

;; --- read-source-string -------------------------------------------------

(test-case "read-source-string parses #lang line + forms"
  (define-values (lang forms)
    (read-source-string "#lang beagle/clj\n(+ 1 2)\n(claim foo ∈ Int)"))
  (check-equal? lang "#lang beagle/clj")
  (check-equal? forms '((+ 1 2) (claim foo ∈ Int))))

;; --- detect-target ------------------------------------------------------

(test-case "detect-target maps #lang lines correctly"
  (check-equal? (detect-target "#lang beagle") 'clj)
  (check-equal? (detect-target "#lang beagle/clj") 'clj)
  (check-equal? (detect-target "#lang beagle/js") 'js)
  (check-equal? (detect-target "#lang beagle/nix") 'nix)
  (check-equal? (detect-target "#lang beagle/py") 'py)
  (check-equal? (detect-target "#lang beagle/sql") 'sql)
  (check-equal? (detect-target "#lang beagle/rkt") 'rkt)
  (check-equal? (detect-target "#lang beagle/cljs") 'cljs)
  (check-equal? (detect-target #f) 'rkt))

;; --- check ---------------------------------------------------------------

(test-case "check-source on a clean file"
  (with-temp-source
    "#lang beagle/clj\n(+ 1 2)\n"
    (lambda (path)
      (check-equal? (check-source path) '()))))

(test-case "check-source treats unbound names as Any (gradual)"
  ;; Gradual checker: unbound symbols default to Any, no error reported.
  ;; Real "doesn't exist" issues surface at runtime / backend resolution.
  (with-temp-source
    "#lang beagle/clj\nunbound-thing\n"
    (lambda (path)
      (define errs (check-source path))
      (check-equal? errs '()))))

;; --- compile to each target --------------------------------------------

(test-case "compile to Racket"
  (with-temp-source
    "#lang beagle/rkt\n(+ 1 2)\n"
    (lambda (path)
      (define out (compile-source path 'rkt))
      (check-true (regexp-match? #rx"\\(\\+ 1 2\\)" out)))))

(test-case "compile to Clojure"
  (with-temp-source
    "#lang beagle/clj\n(+ 1 2)\n"
    (lambda (path)
      (define out (compile-source path 'clj))
      (check-true (regexp-match? #rx"\\(\\+ 1 2\\)" out)))))

(test-case "compile to JS"
  (with-temp-source
    "#lang beagle/js\n(+ 1 2)\n"
    (lambda (path)
      (define out (compile-source path 'js))
      (check-true (regexp-match? #rx"\\(1 \\+ 2\\)" out)))))

(test-case "compile to Nix"
  (with-temp-source
    "#lang beagle/nix\n(+ 1 2)\n"
    (lambda (path)
      (define out (compile-source path 'nix))
      (check-true (regexp-match? #rx"\\(1 \\+ 2\\)" out)))))

(test-case "compile to Python"
  (with-temp-source
    "#lang beagle/py\n(+ 1 2)\n"
    (lambda (path)
      (define out (compile-source path 'py))
      (check-true (regexp-match? #rx"\\(1 \\+ 2\\)" out)))))

;; --- compile aborts on type errors --------------------------------------

(test-case "compile aborts on real type mismatch"
  ;; Need a structural mismatch the gradual checker catches: arity error.
  (with-temp-source
    "#lang beagle/rkt
(claim f ∈ (→ (' params Int Int) (returns Int)))
(defn f (' params a b) (body (+ a b)))
(f 1 2 3)\n"
    (lambda (path)
      (check-exn exn:fail:user? (lambda () (compile-source path))))))

;; --- run (operative evaluator) ------------------------------------------

(test-case "run a small program via operative evaluator"
  (with-temp-source
    "#lang beagle/clj\n(+ 1 2)\n"
    (lambda (path)
      (check-equal? (run-source path) 3))))

(test-case "run a defn and call it"
  ;; Note: source uses Beagle's `'` syntax. The reader treats `'` as ordinary.
  (with-temp-source
    "#lang beagle/clj\n(defn add (' params a b) (body (+ a b)))\n(add 3 4)\n"
    (lambda (path)
      (check-equal? (run-source path) 7))))
