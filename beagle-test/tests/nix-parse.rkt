#lang racket/base

;; Parse-level tests for #lang beagle/nix surface forms.
;; Verifies each form lands on the right AST node with the right structure.

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/ast
         beagle/nix/lang/reader-impl)

(define (parse-nix str)
  (define body (string-append "(define-target nix)\n" str))
  (define stxs
    (with-input-from-string body
      (lambda ()
        (let loop ([acc '()])
          (define d (beagle-nix-read-syntax "test" (current-input-port)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc)))))))
  (define prog (parse-program stxs))
  (program-forms prog))

(define (first-form str)
  (car (parse-nix str)))

;; --- inherit / inherit-from -------------------------------------------------

(test-case "inherit parses to nix-inherit with symbol names"
  (define f (first-form "(inherit a b c)"))
  (check-true (nix-inherit? f))
  (check-equal? (nix-inherit-names f) '(a b c)))

(test-case "inherit-from parses to nix-inherit-from with ns + names"
  (define f (first-form "(inherit-from pkgs vim git)"))
  (check-true (nix-inherit-from? f))
  (check-equal? (nix-inherit-from-names f) '(vim git)))

(test-case "inherit rejects non-symbol"
  (check-exn exn:fail? (lambda () (first-form "(inherit 42)"))))

;; --- with shape disambiguation ----------------------------------------------

(test-case "(with ns body) parses to nix-with"
  (define f (first-form "(with pkgs hello)"))
  (check-true (nix-with? f)))

(test-case "(with ns [vec lit]) parses to nix-with"
  (define f (first-form "(with pkgs [1 2 3])"))
  (check-true (nix-with? f)))

(test-case "(with target [:k v]) parses to record-update with-form"
  (define f (first-form "(with rec [:field 42])"))
  (check-true (with-form? f)))

;; --- module / fn-set / overlay ----------------------------------------------

(test-case "module parses to nix-fn-set with rest? true"
  (define f (first-form "(module [config lib pkgs] config)"))
  (check-true (nix-fn-set? f))
  (check-true (nix-fn-set-rest? f))
  (check-equal? (length (nix-fn-set-formals f)) 3))

(test-case "fn-set parses to nix-fn-set with rest? false"
  (define f (first-form "(fn-set [a b] a)"))
  (check-true (nix-fn-set? f))
  (check-false (nix-fn-set-rest? f)))

(test-case "overlay enforces exactly two formals"
  (check-true (fn-form? (first-form "(overlay [a b] a)")))
  (check-equal? (length (fn-form-params (first-form "(overlay [a b] a)"))) 2)
  (check-exn exn:fail? (lambda () (first-form "(overlay [a] a)")))
  (check-exn exn:fail? (lambda () (first-form "(overlay [a b c] a)"))))

;; --- derivation -------------------------------------------------------------

(test-case "derivation parses to nix-derivation with attrset"
  (define f (first-form "(derivation {:pname \"x\" :src ./.})"))
  (check-true (nix-derivation? f))
  (check-true (map-form? (nix-derivation-attrs f))))

;; --- flake ------------------------------------------------------------------

(test-case "flake parses to nix-flake"
  (define f (first-form "(flake {:description \"x\"})"))
  (check-true (nix-flake? f)))

;; --- with-cfg ---------------------------------------------------------------

(test-case "with-cfg parses to nix-with-cfg with path + body"
  (define f (first-form "(with-cfg config.foo.bar BODY)"))
  (check-true (nix-with-cfg? f))
  (check-equal? (nix-with-cfg-path f) 'config.foo.bar))

;; --- rec-attrs --------------------------------------------------------------

(test-case "rec-attrs parses key-value pairs"
  (define f (first-form "(rec-attrs x 1 y x)"))
  (check-true (nix-rec-attrs? f))
  (check-equal? (length (nix-rec-attrs-pairs f)) 2))

(test-case "rec-attrs rejects odd number of args"
  (check-exn exn:fail? (lambda () (first-form "(rec-attrs x 1 y)"))))

;; --- assert -----------------------------------------------------------------

(test-case "assert parses to nix-assert"
  (define f (first-form "(assert true 42)"))
  (check-true (nix-assert? f)))

;; --- get-or, has ------------------------------------------------------------

(test-case "get-or parses to nix-get-or"
  (define f (first-form "(get-or config a.b 0)"))
  (check-true (nix-get-or? f))
  (check-equal? (nix-get-or-path f) "a.b"))

(test-case "has parses to nix-has-attr"
  (define f (first-form "(has config a.b)"))
  (check-true (nix-has-attr? f))
  (check-equal? (nix-has-attr-path f) "a.b"))

;; --- search-path ------------------------------------------------------------

(test-case "search-path parses to nix-search-path"
  (define f (first-form "(search-path nixpkgs)"))
  (check-true (nix-search-path? f))
  (check-equal? (nix-search-path-name f) "nixpkgs"))

;; --- s (interp) -------------------------------------------------------------

(test-case "s parses to nix-interpolated-string"
  (define f (first-form "(s \"hi \" name \"!\")"))
  (check-true (nix-interpolated-string? f))
  (check-equal? (length (nix-interpolated-string-parts f)) 3))

;; --- ~"..." reader ---------------------------------------------------------

(test-case "~\"hi ${name}!\" reader desugars to (s ...)"
  (define f (first-form "~\"hi ${name}!\""))
  (check-true (nix-interpolated-string? f))
  (define parts (nix-interpolated-string-parts f))
  (check-equal? (length parts) 3)
  (check-equal? (car parts) "hi ")
  (check-equal? (caddr parts) "!"))

(test-case "~\"no interp\" produces single literal"
  (define f (first-form "~\"no interp\""))
  (check-true (nix-interpolated-string? f))
  (check-equal? (nix-interpolated-string-parts f) '("no interp")))

(test-case "~\"a ${(+ x 1)} b\" parses arbitrary expr"
  (define f (first-form "~\"a ${(+ x 1)} b\""))
  (check-true (nix-interpolated-string? f))
  (define parts (nix-interpolated-string-parts f))
  (check-equal? (length parts) 3)
  (check-true (call-form? (cadr parts))))

;; --- ms (multiline) ---------------------------------------------------------

(test-case "ms parses to nix-multiline-string"
  (define f (first-form "(ms \"l1\" \"l2\")"))
  (check-true (nix-multiline-string? f))
  (check-equal? (length (nix-multiline-string-lines f)) 2))

;; --- p (path) ---------------------------------------------------------------

(test-case "p parses to nix-path"
  (define f (first-form "(p \"./hello.nix\")"))
  (check-true (nix-path? f))
  (check-equal? (nix-path-path-string f) "./hello.nix"))

;; --- pipe-to / pipe-from ----------------------------------------------------

(test-case "pipe-to parses to nix-pipe with direction 'to"
  (define f (first-form "(pipe-to x f)"))
  (check-true (nix-pipe? f))
  (check-eq? (nix-pipe-direction f) 'to))

(test-case "pipe-from parses to nix-pipe with direction 'from"
  (define f (first-form "(pipe-from f x)"))
  (check-true (nix-pipe? f))
  (check-eq? (nix-pipe-direction f) 'from))

;; --- implies ----------------------------------------------------------------

(test-case "implies parses to nix-impl"
  (define f (first-form "(implies a b)"))
  (check-true (nix-impl? f)))

;; --- flake-input ------------------------------------------------------------

(test-case "flake-input parses to flake-input-form"
  (define f (first-form "(flake-input :quickshell :packages :default)"))
  (check-true (flake-input-form? f))
  (check-equal? (flake-input-form-input-name f) ':quickshell)
  (check-equal? (flake-input-form-namespace f) ':packages)
  (check-equal? (flake-input-form-path-segments f) '(:default)))

(test-case "flake-input with multi-segment path"
  (define f (first-form "(flake-input :nur :legacyPackages :repos :rycee :firefox-addons :sidebery)"))
  (check-true (flake-input-form? f))
  (check-equal? (flake-input-form-input-name f) ':nur)
  (check-equal? (flake-input-form-namespace f) ':legacyPackages)
  (check-equal? (flake-input-form-path-segments f)
                '(:repos :rycee :firefox-addons :sidebery)))

(test-case "flake-input rejects non-keyword input-name"
  (check-exn exn:fail? (lambda () (first-form "(flake-input quickshell :packages :default)"))))

(test-case "flake-input rejects non-keyword namespace"
  (check-exn exn:fail? (lambda () (first-form "(flake-input :quickshell packages :default)"))))

;; --- nix-ident migration error ----------------------------------------------

(test-case "nix-ident is rejected with migration error"
  (check-exn (lambda (e)
               (and (exn:fail? e)
                    (regexp-match? #rx"nix-ident removed" (exn-message e))))
             (lambda () (first-form "(nix-ident \"inputs.foo.bar\")"))))
