#lang racket/base

;; Emit-level error tests: forms that no longer silently corrupt output now
;; throw clean errors with helpful messages.

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/nix/lang/reader-impl)

(define (nix-emit str)
  (define body (string-append "(define-target nix)\n" str))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax "test" (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (emit-program prog))

;; --- set literals rejected --------------------------------------------------

(test-case "set literal rejected with helpful message"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"no set literal" (exn-message e))))
             (lambda () (nix-emit "#{1 2 3}"))))

;; --- await rejected ---------------------------------------------------------

(test-case "await rejected on nix target"
  (check-exn exn:fail?
             (lambda () (nix-emit "(await (some-call))"))))

;; --- defn multi-arity rejected ----------------------------------------------

(test-case "multi-arity defn rejected with target name"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"multi-arity" (exn-message e))))
             (lambda () (nix-emit "(defn f ([x] : Any x) ([x y] : Any x))"))))

;; --- derivation missing :pname/:name ----------------------------------------

(test-case "derivation without :pname or :name errors"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx":pname or :name" (exn-message e))))
             (lambda () (nix-emit "(derivation {:src ./.})"))))

;; --- overlay arity ----------------------------------------------------------

(test-case "overlay rejects wrong arity"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"exactly two formals" (exn-message e))))
             (lambda () (nix-emit "(overlay [a] body)"))))

;; --- Infinity / NaN rejected -----------------------------------------------

(test-case "Infinity/NaN rejected in number emission"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"Infinity|NaN" (exn-message e))))
             (lambda () (nix-emit "(def x : Float +inf.0)"))))

;; --- mod operator emits inline arithmetic, not /* mod */ comment ------------

(test-case "mod operator emits inline arithmetic"
  (define out (nix-emit "(def x : Int (mod 10 3))"))
  (check-true (string-contains? out "(10 - (10 / 3) * 3)"))
  (check-false (string-contains? out "/* mod */")))

;; --- loop with recur actually recurses --------------------------------------

(test-case "loop body recur emits self-call, not null comment"
  (define out (nix-emit "(def f : Any (fn [(n : Int)] : Any (loop [i n] (if (<= i 0) 0 (recur (- i 1))))))"))
  (check-true (string-contains? out "__loop"))
  (check-false (string-contains? out "/* recur outside loop */")))

;; --- check-expr uses _tag (single underscore) ------------------------------

(test-case "check-expr uses _tag (single underscore)"
  (define out (nix-emit "(def x : Any (check (foo)))"))
  (check-true (string-contains? out "r._tag"))
  (check-false (string-contains? out "r.__tag")))

;; --- try-form unwraps the tryEval struct ------------------------------------

(test-case "try-form unwraps tryEval to value-or-null"
  (define out (nix-emit "(def x : Any (try (foo)))"))
  (check-true (string-contains? out "builtins.tryEval"))
  (check-true (string-contains? out "__t.success"))
  (check-true (string-contains? out "__t.value")))

;; --- import is not mangled --------------------------------------------------

(test-case "import is not mangled (it's a function, not keyword)"
  (define out (nix-emit "(def x : Any (import nixpkgs))"))
  (check-true (string-contains? out "import nixpkgs"))
  (check-false (string-contains? out "import'")))
