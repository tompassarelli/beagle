#lang racket/base

;; #17 regression: the facts renderer (`--render`) must reconstruct the `#lang`
;; header from the leading `(define-target X)` form (read-beagle-syntax
;; canonicalizes `#lang beagle/X` -> that form). A rendered module that led with
;; `(define-target …)` instead of `#lang` was rejected by bin/beagle check's
;; module loader ("expected a `module' declaration") — blocking fram's schema.bclj
;; flip-view (self-host 12/12). This drives source -> EDN -> render and asserts the
;; rendered output is a real #lang module AND re-reads to the identical forms.
;;
;; D3 (batch compilation decomposition): this file used to drive every case
;; through a FRESH `racket facts-roundtrip.rkt --emit-edn|--render` subprocess —
;; each spawn re-pays the ~1.8s compiler-module cold load, and every idempotence
;; case pays it FOUR times (emit+render, twice). That's ~100 cold loads for this
;; one file (measured: ~190s of the 650s whole-tier baseline). facts-roundtrip.rkt
;; is a pure data-level module (fixtures are read as data — no dynamic-require, no
;; module-registry caching concern), so the fix is the certify.rkt pattern: call
;; emit-edn-file / render-edn IN-PROCESS, once compiler-loaded, many times cheap.
;; The legacy subprocess path is kept as BEAGLE_FACTS_RENDER_SUBPROCESS=1 (a
;; rollback lever and the CLI-fidelity oracle for the identity suite at the
;; bottom of this file).

(require rackunit
         rackunit/text-ui
         racket/port
         racket/file
         racket/string
         racket/path)

;; Worktree root discovery (same pattern as beagle-test/tests/ast-json.rkt): load
;; facts-roundtrip.rkt by FILE PATH so the WORKTREE's edited source is exercised,
;; not a stale collection .zo.
(define root
  (path->string
   (simplify-path
    (if (file-exists? (build-path (current-directory) "beagle-lib/private/facts-roundtrip.rkt"))
        (current-directory)
        (build-path (path-only (build-path (syntax-source #'here))) ".." "..")))))
(define crt-path (build-path root "beagle-lib" "private" "facts-roundtrip.rkt"))
(define crt-path-str (path->string crt-path))

(define-values (emit-edn-file render-edn)
  (values
   (dynamic-require `(file ,crt-path-str) 'emit-edn-file)
   (dynamic-require `(file ,crt-path-str) 'render-edn)))

;; --- legacy subprocess path (unchanged; the CLI oracle) ---------------------
(define (run-subprocess . args)
  (define-values (proc out in err) (apply subprocess #f #f #f (find-executable-path "racket") crt-path-str args))
  (close-output-port in)
  (define o (port->string out))
  (define e (port->string err))
  (subprocess-wait proc)
  (close-input-port out) (close-input-port err)
  (values (subprocess-status proc) o e))

;; --- in-process path (D3) ----------------------------------------------------
;; Guards, per case:
;;   * catch-all with-handlers — one case's exn/raise never aborts the batch;
;;     mirrors certify.rkt's compile-fixture (lift of the same pattern).
;;   * exit-handler parameterized to RAISE instead of terminating the test
;;     process — emit-edn-file/render-edn never call (exit) themselves, but this
;;     is a hard guard against a downstream dependency doing so on a bad fixture.
;;   * stdout captured via a FRESH string port per call (parameterized
;;     current-output-port) — no shared mutable buffer, no cross-case leakage.
(define (run-inprocess mode path)
  (define op (open-output-string))
  (define result
    (with-handlers ([(lambda (e) #t)
                      (lambda (e) (cons 'fail (if (exn? e) (exn-message e) (format "~a" e))))])
      (parameterize ([current-output-port op]
                     [exit-handler (lambda (code)
                                     (raise (make-exn:fail (format "in-process exit ~a" code)
                                                            (current-continuation-marks))))])
        (cond
          [(equal? mode "--emit-edn") (emit-edn-file path)]
          [(equal? mode "--render")   (render-edn path)]
          [else (error 'run-inprocess "unsupported mode ~a" mode)])
        'ok)))
  (define captured (get-output-string op))
  (if (eq? result 'ok)
      (values 0 captured "")
      (values 1 captured (cdr result))))

;; Rollback/CLI-fidelity lever: BEAGLE_FACTS_RENDER_SUBPROCESS=1 forces the
;; pre-D3 full-subprocess path for every case in this file.
(define legacy-subprocess? (and (getenv "BEAGLE_FACTS_RENDER_SUBPROCESS") #t))
(define (run . args)
  (if legacy-subprocess?
      (apply run-subprocess args)
      (run-inprocess (car args) (cadr args))))

(define (render-roundtrip src-text)
  (define f (make-temporary-file "crt-~a.bclj"))
  (define edn (make-temporary-file "crt-~a.edn"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'truncate (lambda (p) (display src-text p)))
      (define-values (c1 o1 e1) (run "--emit-edn" (path->string f)))
      (call-with-output-file edn #:exists 'truncate (lambda (p) (display o1 p)))
      (define-values (c2 o2 e2) (run "--render" (path->string edn)))
      o2)
    (lambda () (when (file-exists? f) (delete-file f)) (when (file-exists? edn) (delete-file edn)))))

(run-tests
 (test-suite "facts render — #lang reconstruction (#17)"

   (test-case "render reconstructs #lang beagle/clj from leading (define-target clj)"
     (define out (render-roundtrip "#lang beagle/clj\n\n;; hdr\n(def x :- Int 42)\n"))
     (check-true (string-prefix? out "#lang beagle/clj")
                 (format "rendered did not start with #lang:\n~a" out))
     (check-false (string-contains? out "(define-target")
                  "rendered still contains (define-target …)"))

   (test-case "render reconstructs #lang beagle/nix"
     (define out (render-roundtrip "#lang beagle/nix\n(def x :- Int 1)\n"))
     (check-true (string-prefix? out "#lang beagle/nix") out))))

;; ---------------------------------------------------------------------------
;; EXP-025 (G1–G5): the renderer must INVERT the five Clojure reader-macros the
;; beagle reader normalizes to Scheme-style heads — else the emitted text leaks
;; `(#%meta …)` / `(quasiquote …)` / `(unquote …)` / `(unquote-splicing …)` /
;; `(syntax …)`, which is invalid Clojure (won't compile) even though beagle's
;; own reader round-trips it. Each case asserts: the correct surface glyph is
;; present, the raw normalized head is ABSENT (no leak), and render is an
;; idempotent fixed point (⇒ the emitted text re-reads to the identical datum,
;; i.e. it is valid, re-readable beagle/Clojure).
(define (gap-case name src #:has has #:no [no '()])
  (test-case name
    (define out (render-roundtrip src))
    (for ([g (in-list has)])
      (check-true (string-contains? out g)
                  (format "expected ~s in rendered output:\n~a" g out)))
    (for ([g (in-list no)])
      (check-false (string-contains? out g)
                   (format "leaked normalized head ~s in rendered output:\n~a" g out)))
    ;; idempotence: feeding the rendered text back through emit→render must be a
    ;; no-op. Fails loudly if the emitted text is not re-readable beagle.
    (check-equal? (render-roundtrip out) out
                  (format "render is not a fixed point (emitted text not re-readable):\n~a" out))))

(run-tests
 (test-suite "facts render — EXP-025 reader-macro inversion (G1–G5)"

   ;; G1 metadata `^m form`
   (gap-case "G1 type hint ^String"
             "(defn f [^String s] s)\n"
             #:has '("^String") #:no '("#%meta"))
   (gap-case "G1 flag ^:dynamic"
             "(def ^:dynamic *x* 1)\n"
             #:has '("^:dynamic *x*") #:no '("#%meta"))
   (gap-case "G1 map ^{:private true}"
             "(def ^{:private true} q 2)\n"
             #:has '("^{:private true}") #:no '("#%meta"))
   (gap-case "G1 nested metadata ^a ^b x"
             "(def y ^a ^b x)\n"
             #:has '("^a ^b x") #:no '("#%meta"))
   (gap-case "G1 metadata on a collection"
             "(def m ^:foo [1 2 3])\n"
             #:has '("^:foo [1 2 3]") #:no '("#%meta"))
   (gap-case "G1 metadata on an ns form"
             "(ns ^{:deprecated \"5.0.0\"} cheshire.custom)\n"
             #:has '("(ns ^{:deprecated \"5.0.0\"} cheshire.custom)") #:no '("#%meta"))

   ;; G2 syntax-quote `` `form ``  / G3 unquote ~x / G4 splice ~@x (all in one macro)
   (gap-case "G2/G3/G4 quasiquote + unquote + unquote-splicing"
             "(defmacro m [obj xs] `(vary-meta ~obj assoc :tags `[~@xs]))\n"
             #:has '("`(vary-meta " "~obj" "`[~@xs]")
             #:no '("quasiquote" "(unquote"))

   ;; G5 var-quote `#'form`
   (gap-case "G5 var-quote #'foo"
             "(def v #'foo)\n"
             #:has '("#'foo") #:no '("(syntax "))

   ;; G6 primed symbols (EXP-025 ring-core). A trailing/embedded `'` is a legal
   ;; Clojure symbol char; the reader must keep `v'` as ONE symbol (not `v` +
   ;; quote), and the renderer must print it BARE (`v'`, never `v\'` — an escape
   ;; the reader would re-split at `\`). The exact ring params.clj construct:
   (gap-case "G6 primed let-binding (v')"
             "(defn assoc-param-map [req k v] (some-> req (assoc k (if-let [v' (req k)] (reduce-kv assoc v' v) v))))\n"
             #:has '("[v' (req k)]" "(reduce-kv assoc v' v)")
             #:no '("(quote " "v\\'"))
   (gap-case "G6 double-primed symbol (x'')"
             "(def y x'')\n"
             #:has '("x''") #:no '("(quote " "x\\'"))
   ;; UNCHANGED: a LEADING quote is still normalized to (quote …) (the renderer
   ;; does not invert 1-arg quote — pre-existing, valid Clojure), and `x''` in a
   ;; quoted context stays intact.
   (gap-case "G6 leading quote unchanged ('sym → (quote sym))"
             "(def q 'sym)\n"
             #:has '("(quote sym)") #:no '("sym\\'"))))

;; ---------------------------------------------------------------------------
;; EXP-025 (G7–G11, malli): five more reader/render gaps the renderer must
;; invert so rendered text is valid Clojure that re-reads to the identical datum.
;;   G7  reader conditionals  #?(…) / #?@(…)   (render inversion; emit already faithful)
;;   G8  discard              #_form           (kept as datum, not dropped — text is a view)
;;   G10 tagged literal       #js form
;;   G11 symbolic values      ##Inf / ##-Inf / ##NaN
;; (G9 bare-dot interop `(. T m)` is a READ-side change; its fixtures live below,
;; guarded, so this suite stays green whether or not G9 landed.)
(run-tests
 (test-suite "facts render — EXP-025 reader/render gaps (G7–G11)"

   ;; G7 reader conditional — the flagged unknown (emit faithful, render was broken)
   (gap-case "G7 #?(:clj … :cljs … :nix …)"
             "(def x #?(:clj 1 :cljs 2 :nix 3))\n"
             #:has '("#?(:clj 1 :cljs 2 :nix 3)")
             #:no '("reader-conditional" "#%"))
   (gap-case "G7 #?@ splice in an ns :require"
             "(ns foo (:require #?@(:clj [[a.b]] :default [[c.d]])))\n"
             #:has '("#?@(:clj [[a.b]] :default [[c.d]])")
             #:no '("reader-conditional-splice" "#%"))

   ;; G8 discard #_form — KEPT (no silent drop), inverted to #_
   (gap-case "G8 #_ discard in a vector ([1 #_2 3])"
             "(def v [1 #_2 3])\n"
             #:has '("[1 #_2 3]") #:no '("#%discard"))
   (gap-case "G8 #_ discard of a list (#_(a b))"
             "(def w [1 #_(a b) 3])\n"
             #:has '("#_(a b)") #:no '("#%discard"))

   ;; G10 #js tagged literal inside a :cljs branch
   (gap-case "G10 #js [] inside a :cljs branch"
             "(def j #?(:clj [] :cljs #js []))\n"
             #:has '("#js []") #:no '("#%js"))
   (gap-case "G10 #js map literal"
             "(def o #js {:a 1})\n"
             #:has '("#js {:a 1}") #:no '("#%js"))

   ;; G12 #^ legacy metadata shorthand — reads as (#%meta …), same as `^`, and
   ;; renders NORMALIZED to `^` (the legacy #^ spelling is not preserved; #^ → ^
   ;; is the correct, desired inversion since both mean identical metadata).
   (gap-case "G12 #^String param tag renders as ^String"
             "(defn f [#^String s] s)\n"
             #:has '("^String") #:no '("#^" "#%meta"))
   (gap-case "G12 #^{:tag} longhand renders as ^{:tag …}"
             "(def #^{:tag String} x 1)\n"
             #:has '("^{:tag String}") #:no '("#^" "#%meta"))

   ;; G11 symbolic values ##Inf / ##-Inf / ##NaN
   (gap-case "G11 ##NaN ##Inf ##-Inf"
             "(def s [##NaN ##Inf ##-Inf])\n"
             #:has '("##NaN" "##Inf" "##-Inf") #:no '("#%symbolic-val" "nan.0" "inf.0"))

   ;; G9 bare-dot interop `(. Target member)` (READ-side fix; render was never
   ;; the gap — a lone `.` is an ordinary symbol that already renders bare). These
   ;; assert the whole emit→render path is a fixed point on malli's java.time shape
   ;; and that the interop head stays a bare `.`, never a pipe-quoted `|.|`.
   (gap-case "G9 `(. Target -field)` interop head renders bare"
             "(def m (. LocalTime -MIN))\n"
             #:has '("(. LocalTime -MIN)") #:no '("|.|"))
   (gap-case "G9 `(. obj method arg)` interop renders bare"
             "(def r (. obj method arg))\n"
             #:has '("(. obj method arg)") #:no '("|.|"))
   (gap-case "G9 `.method` sugar unchanged through render"
             "(def m (.method obj))\n"
             #:has '("(.method obj)"))
   (gap-case "G9 java.time schema map round-trips"
             "(def s {:min (. LocalTime -MIN) :max (. LocalTime -MAX)})\n"
             #:has '("(. LocalTime -MIN)" "(. LocalTime -MAX)") #:no '("|.|"))))

;; ---------------------------------------------------------------------------
;; D3 acceptance gate: CLI (real subprocess, unchanged) vs in-process byte
;; identity, over every gap/plain fixture above PLUS idempotence-pass and
;; diagnostic/state-leak probes. This is the oracle: the subprocess path is the
;; untouched pre-D3 CLI behavior, so identity here proves the in-process seam is
;; a semantics-preserving rewrite, not just "still green".
;;
;; Isolation: each side gets its OWN fresh temp-fixture pair (make-temporary-file
;; per call, per side) — never a shared file between the CLI run and the
;; in-process run, and never reused across cases.
(define (render-roundtrip-via runner src-text)
  (define f (make-temporary-file "crt-~a.bclj"))
  (define edn (make-temporary-file "crt-~a.edn"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file f #:exists 'truncate (lambda (p) (display src-text p)))
      (define-values (c1 o1 e1) (runner "--emit-edn" (path->string f)))
      (call-with-output-file edn #:exists 'truncate (lambda (p) (display o1 p)))
      (define-values (c2 o2 e2) (runner "--render" (path->string edn)))
      (list c1 e1 c2 o2 e2))
    (lambda () (when (file-exists? f) (delete-file f)) (when (file-exists? edn) (delete-file edn)))))

(define (check-cli-inprocess-identical name src-text)
  (test-case name
    (define cli (render-roundtrip-via run-subprocess src-text))
    (define ip  (render-roundtrip-via run-inprocess src-text))
    (check-equal? (list-ref ip 0) (list-ref cli 0) (format "~a: emit-edn exit code diverged" name))
    (check-equal? (list-ref ip 1) (list-ref cli 1) (format "~a: emit-edn stderr diverged" name))
    (check-equal? (list-ref ip 2) (list-ref cli 2) (format "~a: render exit code diverged" name))
    (check-equal? (list-ref ip 3) (list-ref cli 3) (format "~a: render stdout diverged" name))
    (check-equal? (list-ref ip 4) (list-ref cli 4) (format "~a: render stderr diverged" name))))

(define FIXTURES
  (list
   (cons "plain #lang clj" "#lang beagle/clj\n\n;; hdr\n(def x :- Int 42)\n")
   (cons "plain #lang nix" "#lang beagle/nix\n(def x :- Int 1)\n")
   (cons "G1 type hint" "(defn f [^String s] s)\n")
   (cons "G1 flag" "(def ^:dynamic *x* 1)\n")
   (cons "G1 map" "(def ^{:private true} q 2)\n")
   (cons "G1 nested" "(def y ^a ^b x)\n")
   (cons "G1 collection" "(def m ^:foo [1 2 3])\n")
   (cons "G1 ns" "(ns ^{:deprecated \"5.0.0\"} cheshire.custom)\n")
   (cons "G2/3/4 quasiquote" "(defmacro m [obj xs] `(vary-meta ~obj assoc :tags `[~@xs]))\n")
   (cons "G5 var-quote" "(def v #'foo)\n")
   (cons "G6 primed let" "(defn assoc-param-map [req k v] (some-> req (assoc k (if-let [v' (req k)] (reduce-kv assoc v' v) v))))\n")
   (cons "G6 double-primed" "(def y x'')\n")
   (cons "G6 leading quote" "(def q 'sym)\n")
   (cons "G7 reader-cond" "(def x #?(:clj 1 :cljs 2 :nix 3))\n")
   (cons "G7 splice" "(ns foo (:require #?@(:clj [[a.b]] :default [[c.d]])))\n")
   (cons "G8 discard vec" "(def v [1 #_2 3])\n")
   (cons "G8 discard list" "(def w [1 #_(a b) 3])\n")
   (cons "G10 js vec" "(def j #?(:clj [] :cljs #js []))\n")
   (cons "G10 js map" "(def o #js {:a 1})\n")
   (cons "G12 legacy meta param" "(defn f [#^String s] s)\n")
   (cons "G12 legacy meta longhand" "(def #^{:tag String} x 1)\n")
   (cons "G11 symbolic values" "(def s [##NaN ##Inf ##-Inf])\n")
   (cons "G9 interop -field" "(def m (. LocalTime -MIN))\n")
   (cons "G9 interop method-arg" "(def r (. obj method arg))\n")
   (cons "G9 dot-sugar" "(def m (.method obj))\n")
   (cons "G9 java.time schema" "(def s {:min (. LocalTime -MIN) :max (. LocalTime -MAX)})\n")))

;; a diagnostic-normalizing helper: temp-file names are process-local (differ
;; between the CLI subprocess and this test process) but here BOTH sides are
;; handed the identical path string, so no normalization of paths is needed.
;; The ONE real divergence: an uncaught exn propagating to a subprocess's
;; top-level gets a "context...:" continuation-mark backtrace appended by
;; racket's default error-display-handler; the in-process with-handlers catch
;; sees the raw exn-message with no such backtrace (it's caught at the raise
;; site, not printed by the top-level handler). The backtrace is call-stack
;; provenance, not semantic diagnostic content — strip it (same spirit as
;; certify.rkt's normalize-diag/strip-srcloc: normalize incidental provenance,
;; keep the message identity check meaningful), then trim trailing newlines.
(define (norm-diag s)
  (string-trim (car (string-split s "\n  context...:" #:trim? #f)) "\n" #:left? #f))

;; Gated behind BEAGLE_FACTS_RENDER_VERIFY=1: this suite's whole POINT is to
;; drive the untouched subprocess CLI oracle once per fixture (>50 subprocess
;; cold loads across fixtures+idempotence+leak-probes) — running it by DEFAULT
;; would reintroduce exactly the ~190s cost D3 removes and blow the <15s wall
;; bar. It is the byte-identity PROOF, run on demand / in CI verification, not
;; part of the fast everyday suite; `bin/beagle test` stays under the wall bar,
;; and `BEAGLE_FACTS_RENDER_VERIFY=1 raco test …` is the acceptance oracle.
(when (getenv "BEAGLE_FACTS_RENDER_VERIFY")
 (run-tests
 (test-suite "facts render — D3 CLI vs in-process byte identity"

   (for ([fx (in-list FIXTURES)])
     (check-cli-inprocess-identical (car fx) (cdr fx)))

   ;; idempotence pass: identity must ALSO hold feeding the CLI's own rendered
   ;; output back through both paths — this is exactly where the hidden cold
   ;; load doubled up (gap-case's fixed-point check), so it gets its own probe.
   (for ([fx (in-list FIXTURES)])
     (define-values (c1 o1 e1) (run-subprocess "--emit-edn"
                                                (let ([f (make-temporary-file "crt-idem-~a.bclj")])
                                                  (call-with-output-file f #:exists 'truncate
                                                    (lambda (p) (display (cdr fx) p)))
                                                  (path->string f))))
     (define edn (make-temporary-file "crt-idem-~a.edn"))
     (call-with-output-file edn #:exists 'truncate (lambda (p) (display o1 p)))
     (define-values (c2 rendered e2) (run-subprocess "--render" (path->string edn)))
     (delete-file edn)
     (check-cli-inprocess-identical (string-append (car fx) " (idempotence pass)") rendered))

   ;; state-leak probes: interleave two DISTINCT fixtures repeatedly through the
   ;; SAME in-process runner (same Racket process/namespace as every other case
   ;; in this file) and confirm each still matches its independent CLI oracle —
   ;; i.e. no gensym counter / parameter / hash-table leaks across calls. (The
   ;; fresh! id counters and props tables inside facts-roundtrip.rkt are LOCAL
   ;; to each function call, not module-level state, so this is expected to
   ;; hold; the probe makes that a checked fact instead of an assumption.)
   (let ([a (cons "leak-probe A" "(def a :- Int 1)\n")]
         [b (cons "leak-probe B" "(def b :- Int 2)\n")])
     (for ([i (in-range 5)])
       (check-cli-inprocess-identical (format "~a #~a" (car a) i) (cdr a))
       (check-cli-inprocess-identical (format "~a #~a" (car b) i) (cdr b))))

   ;; diagnostic identity: a genuine failure path (missing file), same path
   ;; string handed to both sides, so stdout/stderr/exit are directly comparable
   ;; with no normalization needed beyond a trailing-newline trim.
   (test-case "diagnostic identity: --emit-edn on a missing source file"
     (define missing (path->string (build-path (find-system-path 'temp-dir) "crt-missing-does-not-exist.bclj")))
     (define-values (c1 o1 e1) (run-subprocess "--emit-edn" missing))
     (define-values (c2 o2 e2) (run-inprocess "--emit-edn" missing))
     (check-equal? o2 o1 "stdout diverged on missing-file diagnostic")
     (check-equal? (norm-diag e2) (norm-diag e1) "diagnostic text diverged on missing-file case")
     (check-equal? (zero? c2) (zero? c1) "exit-code success/failure diverged on missing-file case"))

   (test-case "diagnostic identity: --render on a missing edn file"
     (define missing (path->string (build-path (find-system-path 'temp-dir) "crt-missing-does-not-exist.edn")))
     (define-values (c1 o1 e1) (run-subprocess "--render" missing))
     (define-values (c2 o2 e2) (run-inprocess "--render" missing))
     (check-equal? o2 o1 "stdout diverged on missing-file diagnostic")
     (check-equal? (norm-diag e2) (norm-diag e1) "diagnostic text diverged on missing-file case")
     (check-equal? (zero? c2) (zero? c1) "exit-code success/failure diverged on missing-file case")))))
