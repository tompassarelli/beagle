#lang racket/base

;; Tests for the nix-aware lint pass.

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/lint
         beagle/nix/lang/reader-impl)

(define (lint-output str)
  (define body (string-append "(define-target nix)\n" str))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax "test" (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (lint-program! prog))
  (get-output-string out))

(define (lints-include? str warning-rx)
  (regexp-match? warning-rx str))

(test-case "(lib/mkIf false ...) → dead code warning"
  (define out (lint-output "(def x : Any (lib/mkIf false {:foo 1}))"))
  (check-true (lints-include? out #rx"dead code")))

(test-case "(lib/mkIf true ...) → always-on warning"
  (define out (lint-output "(def x : Any (lib/mkIf true {:foo 1}))"))
  (check-true (lints-include? out #rx"always-on")))

(test-case "(lib/mkIf X X) → typo warning"
  (define out (lint-output "(def x : Any (lib/mkIf y y))"))
  (check-true (lints-include? out #rx"likely a typo")))

(test-case "lib/mkOption with :type bool but no :default → warning"
  (define out (lint-output "(def x : Any (lib/mkOption {:type lib/types.bool :description \"x\"}))"))
  (check-true (lints-include? out #rx"will throw at eval time")))

(test-case "lib/mkOption missing :description → warning"
  (define out (lint-output "(def x : Any (lib/mkOption {:type lib/types.str :default \"x\"}))"))
  (check-true (lints-include? out #rx"missing :description")))

(test-case "(merge {} X) → no-op warning"
  (define out (lint-output "(def x : Any (merge {} other))"))
  (check-true (lints-include? out #rx"no-op")))

(test-case "(concat [] X) → no-op warning"
  (define out (lint-output "(def x : Any (concat [] other))"))
  (check-true (lints-include? out #rx"no-op")))

(test-case "(s \"hi\") with no interp → use plain literal"
  (define out (lint-output "(def x : Any (s \"hello\"))"))
  (check-true (lints-include? out #rx"plain string literal")))

(test-case "clean (lib/mkIf cond body) emits no warning"
  (define out (lint-output "(def x : Any (lib/mkIf cond {:foo 1}))"))
  (check-false (lints-include? out #rx"dead code|always-on|typo")))

(test-case "lints don't fire for non-nix targets"
  ;; mkIf only triggers when target is nix; same code under #lang beagle/clj
  ;; doesn't run nix lints
  (define body "(define-target clj) (def x : Any 42)")
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax "test" (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (define out (open-output-string))
  (parameterize ([current-error-port out])
    (lint-program! prog))
  (define s (get-output-string out))
  (check-false (lints-include? s #rx"dead code|always-on|no-op")))
