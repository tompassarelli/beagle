#lang racket/base

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/private/types)

(define (mt . xs) (cons MAP-TAG xs))
(define (br . xs) (cons '#%brackets xs))

(define (nix-emit src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

(define (nix-emit-forms . forms)
  (define stxs (map (lambda (f) (datum->syntax #f f)) forms))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

;; --- basic forms -----------------------------------------------------------

(test-case "def emits let binding"
  ;; Inline `: Int` removed — bare form still emits the same let binding.
  (define out (nix-emit "(define-target nix) (def x 42)"))
  (check-true (string-contains? out "x = 42;"))
  (check-true (string-contains? out "let")))

(test-case "defn emits curried function"
  (define out (nix-emit "(define-target nix) (defn add [(a : Int) (b : Int)] (+ a b))"))
  (check-true (string-contains? out "add = a: b:"))
  (check-true (string-contains? out "a + b")))

(test-case "fn emits lambda"
  ;; Drop inline `: Any` / `: Int` — typed params on the inner fn are kept.
  (define out (nix-emit "(define-target nix) (def f (fn [(x : Int)] (+ x 1)))"))
  (check-true (string-contains? out "x:"))
  (check-true (string-contains? out "x + 1")))

(test-case "if emits if/then/else"
  (define out (nix-emit "(define-target nix) (if true 1 0)"))
  (check-true (string-contains? out "if true then 1 else 0")))

(test-case "let emits let/in"
  (define out (nix-emit "(define-target nix) (let [x 1 y 2] (+ x y))"))
  (check-true (string-contains? out "let"))
  (check-true (string-contains? out "x = 1;"))
  (check-true (string-contains? out "y = 2;"))
  (check-true (string-contains? out "in"))
  (check-true (string-contains? out "x + y")))

;; --- data structures -------------------------------------------------------

(test-case "vector emits nix list"
  (define out (nix-emit "(define-target nix) [1 2 3]"))
  (check-true (string-contains? out "[ 1 2 3 ]")))

(test-case "long list breaks to multi-line"
  (define out (nix-emit "(define-target nix) [\"local-fs.target\" \"suspend.target\" \"suspend-then-hibernate.target\" \"hibernate.target\"]"))
  (check-true (and out (string-contains? out "[\n")))
  (check-true (and out (string-contains? out "\"local-fs.target\""))))

(test-case "map emits nix attrset"
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':a 1 ':b 2))))
  (check-true (string-contains? out "a = 1;"))
  (check-true (string-contains? out "b = 2;"))
  (check-true (string-contains? out "{")))

(test-case "nested attrset"
  (define inner (mt ':inner 42))
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':outer inner))))
  (check-true (and out (string-contains? out "outer ="))))

;; --- records ---------------------------------------------------------------

(test-case "defrecord emits constructor + accessors"
  (define out (nix-emit "(define-target nix) (defrecord Point [(x : Int) (y : Int)])"))
  (check-true (string-contains? out "mkPoint = x: y:"))
  (check-true (string-contains? out "_tag = \"point\""))
  (check-true (string-contains? out "point-x = r: r.x;"))
  (check-true (string-contains? out "point-y = r: r.y;")))

;; --- nix builtins ----------------------------------------------------------

(test-case "builtins/ calls emit as builtins.*"
  (define out (nix-emit "(define-target nix) (builtins/length [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "lib/ calls emit as lib.*"
  (define out (nix-emit-forms '(define-target nix)
    `(lib/mkIf true ,(mt ':enable #t))))
  (check-true (string-contains? out "lib.mkIf true")))

;; --- stdlib fns ------------------------------------------------------------

(test-case "map fn emits builtins.map"
  (define out (nix-emit-forms '(define-target nix)
    `(map (fn ,(br '(x : Int)) (+ x 1)) ,(br 1 2 3))))
  (check-true (string-contains? out "builtins.map")))

(test-case "filter fn emits builtins.filter"
  (define out (nix-emit-forms '(define-target nix)
    `(filter (fn ,(br '(x : Int)) (> x 0)) ,(br 1 -1 2))))
  (check-true (string-contains? out "builtins.filter")))

(test-case "nil? emits null check"
  (define out (nix-emit "(define-target nix) (nil? x)"))
  (check-true (string-contains? out "== null")))

(test-case "count emits builtins.length"
  (define out (nix-emit "(define-target nix) (count [1 2 3])"))
  (check-true (string-contains? out "builtins.length")))

(test-case "merge emits //"
  (define out (nix-emit-forms '(define-target nix)
    `(merge ,(mt ':a 1) ,(mt ':b 2))))
  (check-true (string-contains? out "//")))

(test-case "concat emits ++"
  (define out (nix-emit "(define-target nix) (concat [1] [2])"))
  (check-true (string-contains? out "++")))

;; --- attrset field access via get -----------------------------------------
;; (:keyword target) call-form removed — use (get m :key); emit-nix lowers
;; literal-keyword get to unquoted attrset access (person.name).

(test-case "get with literal keyword emits unquoted attrset access"
  (define out (nix-emit "(define-target nix) (get person :name)"))
  (check-true (string-contains? out "person.name")))

(test-case "round-trip identity at Nix emit: (:k target) == (get target :k)"
  ;; Both forms canonicalize to kw-access; emit produces identical Nix.
  (define a (nix-emit "(define-target nix) (:name person)"))
  (define b (nix-emit "(define-target nix) (get person :name)"))
  (check-equal? a b))

(test-case "(get target :kw default) emits `target.kw or default`"
  ;; 3-arity literal-key kw-access lowers to Nix's `or` suffix — same
  ;; emit as the explicit (get-or target kw default) form, modulo the
  ;; identifier-vs-path key (kw-access requires keyword, get-or any path).
  (define out (nix-emit "(define-target nix) (get config :timeout 30)"))
  (check-true (string-contains? out "config.timeout or 30")))

;; --- dotted option paths ---------------------------------------------------

(test-case "dotted keyword keys become Nix option paths"
  (define out (nix-emit-forms '(define-target nix) `(def m ,(mt ':services.openssh.enable #t))))
  (check-true (string-contains? out "services.openssh.enable = true;")))

;; --- cond ------------------------------------------------------------------

(test-case "cond emits nested if/then/else"
  (define out (nix-emit "(define-target nix) (cond [true 1] [false 2])"))
  (check-true (string-contains? out "if true then 1 else"))
  (check-true (string-contains? out "if false then 2")))

;; Clojure-shaped flat-pair cond is accepted and canonicalizes to the same
;; AST as the bracketed form — the emitted Nix is byte-identical.
(test-case "cond: flat-pair Clojure form == bracketed form (with :else)"
  (define flat (nix-emit "(define-target nix) (cond (= x 1) :a (= x 2) :b :else :c)"))
  (define brk  (nix-emit "(define-target nix) (cond [(= x 1) :a] [(= x 2) :b] [:else :c])"))
  (check-equal? flat brk)
  ;; sanity: :else collapses to the bare else-body, not a literal "else" test
  (check-false (string-contains? flat "if \"else\"")))

(test-case "cond: flat-pair without :else falls through to null"
  (define out (nix-emit "(define-target nix) (cond (= x 1) :a (= x 2) :b)"))
  (check-true (string-contains? out "if (x == 1) then \"a\""))
  (check-true (string-contains? out "if (x == 2) then \"b\""))
  (check-true (string-contains? out "else null")))

(test-case "cond: bare `else` in bracketed clause works (same as :else)"
  (define a (nix-emit "(define-target nix) (cond [(= x 1) :a] [else :b])"))
  (define b (nix-emit "(define-target nix) (cond [(= x 1) :a] [:else :b])"))
  (check-equal? a b))

(test-case "cond: mixed bracketed + flat clauses is rejected"
  ;; nix-emit returns #f on parse failure (its handler swallows the error)
  ;; — so a #f result indicates the mixed form was refused.
  (define out (nix-emit "(define-target nix) (cond [(= x 1) :a] (= x 2) :b)"))
  (check-false out))

;; --- with (record update) --------------------------------------------------

(test-case "with emits attrset merge"
  (define out (nix-emit "(define-target nix) (defrecord Foo [(a : Int)]) (with (->Foo 1) [:a 2])"))
  (check-true (string-contains? out "//")))

;; --- string ops ------------------------------------------------------------

(test-case "str emits string concatenation"
  (define out (nix-emit "(define-target nix) (str \"hello\" \" \" \"world\")"))
  (check-true (string-contains? out "\"hello\" + \" \" + \"world\"")))

;; --- comparison operators --------------------------------------------------

(test-case "comparison operators"
  (define out (nix-emit "(define-target nix) (< 1 2)"))
  (check-true (string-contains? out "1 < 2"))
  (define out2 (nix-emit "(define-target nix) (= 1 1)"))
  (check-true (string-contains? out2 "1 == 1")))

;; === Nix-specific forms (Nisp parity) ======================================

;; --- Phase 1: Module-writing core ------------------------------------------

(test-case "fn-set emits attrset-pattern lambda"
  (define out (nix-emit "(define-target nix) (fn-set (a b) (+ a b))"))
  (check-true (and out (string-contains? out "{ a, b }:")))
  (check-true (and out (string-contains? out "a + b"))))

(test-case "fn-set with defaults"
  (define out (nix-emit "(define-target nix) (fn-set (a (b 5)) (+ a b))"))
  (check-true (and out (string-contains? out "b ? 5")))
  (check-true (and out (string-contains? out "{ a, b ? 5 }:"))))

(test-case "module emits ... in formals"
  (define out (nix-emit "(define-target nix) (module [config lib pkgs] config)"))
  (check-true (and out (string-contains? out "...")))
  (check-true (and out (string-contains? out "{ config, lib, pkgs, ... }:"))))

(test-case "overlay emits curried (final: prev: body)"
  (define out (nix-emit-forms '(define-target nix)
    `(overlay ,(br 'final 'prev) ,(mt ':foo 1))))
  (check-true (and out (string-contains? out "final: prev:")))
  (check-false (and out (string-contains? out "{ final, prev"))))

(test-case "inherit emits inherit"
  (define out (nix-emit "(define-target nix) (inherit a b c)"))
  (check-true (and out (string-contains? out "inherit a b c;"))))

(test-case "inherit-from emits inherit (ns)"
  (define out (nix-emit "(define-target nix) (inherit-from pkgs vim git)"))
  (check-true (and out (string-contains? out "inherit (pkgs) vim git;"))))

(test-case "nix/with emits with"
  (define out (nix-emit "(define-target nix) (nix/with lib [1 2 3])"))
  (check-true (and out (string-contains? out "with lib;")))
  (check-true (and out (string-contains? out "[ 1 2 3 ]"))))

(test-case "s emits interpolated string"
  (define out (nix-emit "(define-target nix) (s \"hello \" name \"!\")"))
  (check-true (and out (string-contains? out "\"hello ${name}!\""))))

(test-case "s with only literals"
  (define out (nix-emit "(define-target nix) (s \"hello\" \" world\")"))
  (check-true (and out (string-contains? out "\"hello world\""))))

(test-case "p emits path literal"
  (define out (nix-emit "(define-target nix) (p \"./foo/bar.nix\")"))
  (check-true (and out (string-contains? out "./foo/bar.nix"))))

;; --- Phase 2: Nix semantic essentials --------------------------------------

(test-case "rec-attrs emits recursive attrset"
  (define out (nix-emit "(define-target nix) (rec-attrs x 1 y x)"))
  (check-true (and out (string-contains? out "rec {")))
  (check-true (and out (string-contains? out "x = 1;")))
  (check-true (and out (string-contains? out "y = x;"))))

(test-case "nix/assert emits assert"
  (define out (nix-emit "(define-target nix) (nix/assert true 42)"))
  (check-true (and out (string-contains? out "assert true; 42"))))

(test-case "get-or emits select with or-default"
  (define out (nix-emit "(define-target nix) (get-or config a.b.c \"fallback\")"))
  (check-true (and out (string-contains? out "config.a.b.c or \"fallback\""))))

(test-case "has emits has-attr check"
  (define out (nix-emit "(define-target nix) (has config a.b)"))
  (check-true (and out (string-contains? out "config ? a.b"))))

(test-case "ms emits multiline string"
  (define out (nix-emit "(define-target nix) (ms \"line one\" \"line two\")"))
  (check-true (and out (string-contains? out "''")))
  (check-true (and out (string-contains? out "line one")))
  (check-true (and out (string-contains? out "line two"))))

(test-case "search-path emits search path"
  (define out (nix-emit "(define-target nix) (search-path nixpkgs)"))
  (check-true (and out (string-contains? out "<nixpkgs>"))))

;; --- Phase 3: Operator/convenience parity ----------------------------------

;; pipe-to / pipe-from / implies removed alongside the pipe family.
;; These no longer parse, so they cannot emit. Rejection behaviour is
;; covered by tests/threading.rkt.

;; --- escape hatch removed --------------------------------------------------

(test-case "unsafe-nix is rejected at parse time"
  ;; nix-emit swallows the parse error and returns #f when the program fails.
  (check-false (nix-emit "(def x (unsafe-nix \"hello\"))")))

;; --- qualified calls: / -> . --------------------------------------------------

(test-case "pkgs/ call emits as pkgs.fn"
  (define out (nix-emit "(define-target nix) (pkgs/writeScriptBin \"hello\" \"body\")"))
  (check-true (and out (string-contains? out "pkgs.writeScriptBin")))
  (check-false (string-contains? out "pkgs/writeScriptBin")))

(test-case "arbitrary ns/ call emits as ns.fn"
  (define out (nix-emit "(define-target nix) (config/boot.kernelPackages.kernel)"))
  (check-true (and out (string-contains? out "config.boot.kernelPackages.kernel"))))

(test-case "ns/ symbol in non-call position emits as ns.sym"
  (define out (nix-emit "(define-target nix) (def x pkgs/hello)"))
  (check-true (and out (string-contains? out "pkgs.hello")))
  (check-false (string-contains? out "pkgs/hello")))

;; --- not -> ! -----------------------------------------------------------------

(test-case "not emits ! prefix operator"
  (define out (nix-emit "(define-target nix) (not true)"))
  (check-true (and out (string-contains? out "!true")))
  (check-false (string-contains? out "not true")))

(test-case "not with complex expr wraps inner in parens"
  (define out (nix-emit "(define-target nix) (not (= x 1))"))
  (check-true (and out (string-contains? out "!(")))
  (check-true (and out (string-contains? out "==")))
  (check-false (string-contains? out "((!")))

;; --- quoted containers (Clojure-shaped data literals) -----------------------
;; '[…] / '{…} / '#{…} parse as the container itself. Containers always
;; evaluate in beagle; the quote is identity (meaning-preserving). Lets
;; agents author Clojure-shaped data literals without learning beagle's
;; "quote only on lists" discipline.
;;
;; The plain `read-syntax` used by `nix-emit` doesn't have the beagle
;; readtable, so we construct quoted-container datums by hand via
;; `nix-emit-forms` to exercise the parse layer directly.

(test-case "quoted vector '[…] parses as vec-form (matches bare [..])"
  (define out (nix-emit-forms
               '(define-target nix)
               `(def xs (quote ,(br 1 2 3)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def xs ,(br 1 2 3))))
  (check-true (and out (string-contains? out "[ 1 2 3 ]")))
  (check-equal? out ref))

(test-case "quoted map '{…} parses as map-form (matches bare {..})"
  (define out (nix-emit-forms
               '(define-target nix)
               `(def m (quote ,(mt ':a 1 ':b 2)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def m ,(mt ':a 1 ':b 2))))
  (check-true (and out (string-contains? out "a = 1")))
  (check-true (and out (string-contains? out "b = 2")))
  (check-equal? out ref))

(test-case "quoted set '#{…} parses as set-form (matches bare #{..})"
  (define st (lambda xs (cons SET-TAG xs)))
  (define out (nix-emit-forms
               '(define-target nix)
               `(def s (quote ,(st 1 2 3)))))
  (define ref (nix-emit-forms
               '(define-target nix)
               `(def s ,(st 1 2 3))))
  (check-equal? out ref))

(test-case "quoted symbol still produces a quoted AST node (unchanged)"
  ;; Regression: only containers get the strip-quote treatment.
  ;; '(a b c) and 'symbol must continue to parse as `quoted`.
  (define out (nix-emit "(define-target nix) (def s 'hello)"))
  (check-true (and out (string-contains? out "\"hello\""))))

;; --- nix/-prefixed canonical Nix-namespaced forms ---------------------------
;; Per the "Prefix where meaning diverges from Clojure" rule in beagle/CLAUDE.md,
;; Nix-specific forms whose Clojure namesake means something different get the
;; nix/ prefix. `nix/assert` / `nix/with` / `nix/with-cfg` are the ONLY accepted
;; spellings; bare `assert` / `with-cfg` / Nix-scope `with` are HARD-REJECTED at
;; parse time (see beagle-test/tests/parse.rkt regression tests).

(test-case "nix/assert emits Nix assert form"
  (define out (nix-emit "(define-target nix) (def x (nix/assert true 42))"))
  (check-true (and out (string-contains? out "assert true"))))

(test-case "nix/with emits Nix scope form"
  (define out (nix-emit "(define-target nix) (def x (nix/with pkgs 42))"))
  (check-true (and out (string-contains? out "with pkgs;"))))

(test-case "nix/with-cfg emits cfg-let binding"
  (define out (nix-emit
               "(define-target nix) (def x (nix/with-cfg config.myConfig.x 42))"))
  (check-true (and out (string-contains? out "cfg = config.myConfig.x"))))

(test-case "bare (with target [:k v] ...) record-update still works — not renamed"
  ;; (with …) is overloaded — only the Nix-scope shape is the §C-silent
  ;; collision. Record-update form stays bare; it's not a Clojure collision.
  (define out (nix-emit
               "(define-target nix) (def x (with base [:k 1] [:j 2]))"))
  (check-true (and out (string-contains? out "//"))))

;; --- ms + s inline interpolation ---------------------------------------------

(test-case "ms with s inlines interpolation without double-wrapping"
  (define out (nix-emit "(define-target nix) (ms (s \"#!\" pkgs.bash \"/bin/bash\") \"echo hi\")"))
  (check-true (and out (string-contains? out "#!${pkgs.bash}/bin/bash")))
  (check-false (string-contains? out "${\"")))

;; Multi-operand (ms …) is the canonical form (one operand per physical
;; line). Each operand must land on its own output line — concatenation
;; without \n is the bug we fixed for both legacy and operative emitters.
(test-case "ms multi-operand emits one physical line per operand"
  (define out (nix-emit "(define-target nix) (ms \"first line\" \"second line\" \"third\")"))
  (check-true (and out (regexp-match? #rx"first line[\n\r]" out)))
  (check-true (and out (regexp-match? #rx"second line[\n\r]" out)))
  ;; No "lineSecond" concatenation regression
  (check-false (and out (regexp-match? #rx"first linesecond" out))))

(test-case "ms with multiple s operands keeps each on its own line"
  (define out (nix-emit
               "(define-target nix) (ms (s \"#!\" pkgs.bash) \"set -e\" (s \"echo \" name))"))
  (check-true (and out (string-contains? out "#!${pkgs.bash}")))
  (check-true (and out (regexp-match? #rx"\\$\\{pkgs.bash\\}[\n\r]" out)))
  (check-true (and out (regexp-match? #rx"set -e[\n\r]" out)))
  (check-true (and out (string-contains? out "echo ${name}"))))

;; ~''…'' reader-level tests live in tests/nix-roundtrip.rkt — they
;; need the beagle/nix #lang reader which nix-emit (plain read-syntax)
;; doesn't invoke.

;; Plain Racket strings have no interpolation semantics in bnix, so literal
;; `${X}` in an (ms …) / (s …) chunk must be escaped as `''${X}` / `\${X}`
;; in the emitted Nix string. Otherwise bash array-expansion syntax like
;; `${THEMES[@]}` lands in the output as a malformed Nix interp.
(test-case "ms escapes bare ${ in plain string chunks (multiline)"
  (define out (nix-emit
               "(define-target nix) (ms \"printf '%s\\\\n' \\\"${THEMES[@]}\\\"\")"))
  (check-true (and out (string-contains? out "''${THEMES[@]}")))
  (check-false (and out (regexp-match? #rx"[^'\\\\]\\$\\{THEMES" out))))

(test-case "ms preserves $${ literal-dollar marker (multiline)"
  (define out (nix-emit "(define-target nix) (ms \"hello $${X} world\")"))
  (check-true (and out (string-contains? out "''${X}"))))

(test-case "s escapes bare ${ in plain string chunks (single-line)"
  (define out (nix-emit
               "(define-target nix) (s \"prefix ${VAR} suffix\")"))
  (check-true (and out (string-contains? out "\\${VAR}")))
  (check-false (and out (regexp-match? #rx"[^\\\\]\\$\\{VAR" out))))

;; --- flake-input emission ----------------------------------------------------

(test-case "flake-input emits canonical inputs.X.Y.${system}.Z path"
  (define out (nix-emit "(define-target nix) (def pkg (flake-input :quickshell :packages :default))"))
  (check-true (and out (string-contains? out "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default"))))

(test-case "flake-input with multi-segment path"
  (define out (nix-emit "(define-target nix) (def pkg (flake-input :nur :legacyPackages :repos :rycee :firefox-addons :sidebery))"))
  (check-true (and out (string-contains? out "inputs.nur.legacyPackages.${pkgs.stdenv.hostPlatform.system}.repos.rycee.firefox-addons.sidebery"))))

(test-case "flake-input inside string concat composes cleanly"
  (define out (nix-emit "(define-target nix) (def exec (s (flake-input :quickshell :packages :default) \"/bin/qs\"))"))
  ;; Should produce a string with the flake-input path interpolated, then "/bin/qs" appended
  (check-true (and out (string-contains? out "inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default")))
  (check-true (and out (string-contains? out "/bin/qs"))))

;; --- nix-ident migration error (emit-side; parse-side covered in nix-parse) ---

(test-case "nix-ident fails at parse — nix-emit returns #f"
  ;; nix-emit's parse-program is wrapped in with-handlers that returns #f
  ;; on parse failure. The migration-error message itself is tested in
  ;; nix-parse.rkt; here we just confirm the form doesn't reach emit.
  (define out (nix-emit "(define-target nix) (def x (nix-ident \"inputs.foo\"))"))
  (check-false out))

;; --- Clojure conditional sugar: accept-and-canonicalize ---------------------
;;
;; (when c body…)      → (if c (do body…))
;; (when-not c body…)  → (if (not c) (do body…))
;; (if-not c t e)      → (if c e t)
;; (unless c body…)    → (if c nil (do body…))
;;
;; Each test parses both the surface form and the lowered form and asserts
;; the emitted Nix is byte-equal. Pre-condition: parse-side coverage lives in
;; tests/parse.rkt (AST shape) and tests/diagnostic-kind.rkt (the no-body
;; rejection-form tag).

(test-case "when emits same Nix as if + do (multi body)"
  (define a (nix-emit "(define-target nix) (when (> x 0) (println x) x)"))
  (define b (nix-emit "(define-target nix) (if (> x 0) (do (println x) x))"))
  (check-equal? a b))

(test-case "when-not emits same Nix as if (not c) + body (single body)"
  (define a (nix-emit "(define-target nix) (when-not (> x 0) (println x))"))
  (define b (nix-emit "(define-target nix) (if (not (> x 0)) (println x))"))
  (check-equal? a b))

(test-case "if-not emits same Nix as if with branches swapped"
  (define a (nix-emit "(define-target nix) (if-not (> x 0) \"neg\" \"pos\")"))
  ;; Source swap: (if-not c t e) → (if c e t)
  (define b (nix-emit "(define-target nix) (if (> x 0) \"pos\" \"neg\")"))
  (check-equal? a b))

(test-case "unless emits same Nix as if c nil + body (chosen lowering)"
  ;; Chosen lowering: (unless c body…) → (if c nil (do body…)).
  ;; For single body the (do body) wrap collapses to bare body in emit
  ;; (emit-body of a single expr is just the expr), so emit is byte-equal.
  (define a (nix-emit "(define-target nix) (unless (> x 0) (println x))"))
  (define b (nix-emit "(define-target nix) (if (> x 0) nil (println x))"))
  (check-equal? a b))
