#lang racket/base

;; Phase 1 — Nix-namespace bare-alias deprecation hint.
;;
;; The parser-aliases for `assert` / `with-cfg` / `with` (Nix scope shape)
;; remain accepted as transitional surface forms, but every parse of a bare
;; form should emit a deprecation hint to stderr so the corpus-migration
;; sweep has feedback. Suppress via BEAGLE_NO_DEPRECATION_HINTS=1.

(require rackunit
         racket/port
         beagle/private/parse
         beagle/nix/lang/reader-impl)

(define (parse-with-stderr str)
  (define body (string-append "(define-target nix)\n" str))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax "test" (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define err (open-output-string))
  (parameterize ([current-error-port err])
    (parse-program stxs))
  (get-output-string err))

;; --- bare forms fire the deprecation ---------------------------------------

(test-case "bare (assert ...) emits deprecation hint"
  (define out (parse-with-stderr "(def x : Any (assert true 42))"))
  (check-true (regexp-match? #rx"deprecation: bare `assert`" out)
              "stderr names the offending bare form")
  (check-true (regexp-match? #rx"nix/assert" out)
              "stderr names the canonical replacement")
  (check-true (regexp-match? #rx"20260530170000-beagle_corpus_migration" out)
              "stderr points at the migration thread"))

(test-case "bare (with-cfg ...) emits deprecation hint"
  (define out (parse-with-stderr
               "(def x : Any (with-cfg config.myConfig.modules.foo cfg))"))
  (check-true (regexp-match? #rx"deprecation: bare `with-cfg`" out))
  (check-true (regexp-match? #rx"nix/with-cfg" out)))

(test-case "bare (with NS BODY) scope-shape emits deprecation hint"
  ;; Single-body `with` parses to nix-with (Nix scope). The record-update
  ;; shape `(with target [:k v] ...)` is shape-disambiguated and does NOT
  ;; fire — covered by a separate test below.
  (define out (parse-with-stderr "(def x : Any (with pkgs 42))"))
  (check-true (regexp-match? #rx"deprecation: bare `with`" out))
  (check-true (regexp-match? #rx"nix/with" out)))

;; --- canonical nix/-prefixed forms do NOT fire -----------------------------

(test-case "(nix/assert ...) emits no deprecation"
  (define out (parse-with-stderr "(def x : Any (nix/assert true 42))"))
  (check-false (regexp-match? #rx"deprecation" out)))

(test-case "(nix/with-cfg ...) emits no deprecation"
  (define out (parse-with-stderr
               "(def x : Any (nix/with-cfg config.myConfig.modules.foo cfg))"))
  (check-false (regexp-match? #rx"deprecation" out)))

(test-case "(nix/with NS BODY) emits no deprecation"
  (define out (parse-with-stderr "(def x : Any (nix/with pkgs 42))"))
  (check-false (regexp-match? #rx"deprecation" out)))

;; --- record-update `with` is NOT a Nix-scope alias; stays bare, silent -----

(test-case "(with target [:k v]) record-update does NOT fire"
  ;; Shape-disambiguated: this is the record-update form, not Nix scope.
  ;; Stays bare per the design (no Clojure collision); should be silent.
  (define out (parse-with-stderr "(def x : Any (with rec [:k 42]))"))
  (check-false (regexp-match? #rx"deprecation" out)
               "record-update shape must not trigger the Nix-scope deprecation"))

;; --- suppression via env var -----------------------------------------------

(test-case "BEAGLE_NO_DEPRECATION_HINTS=1 silences the hint"
  (define out
    (parameterize ([current-environment-variables
                    (environment-variables-copy
                     (current-environment-variables))])
      (putenv "BEAGLE_NO_DEPRECATION_HINTS" "1")
      (parse-with-stderr "(def x : Any (assert true 42))")))
  (check-false (regexp-match? #rx"deprecation" out)
               "BEAGLE_NO_DEPRECATION_HINTS=1 must suppress the hint"))
