#lang racket/base

;; #17 regression: the facts renderer (`--render`) must reconstruct the `#lang`
;; header from the leading `(define-target X)` form (read-beagle-syntax
;; canonicalizes `#lang beagle/X` -> that form). A rendered module that led with
;; `(define-target …)` instead of `#lang` was rejected by bin/beagle check's
;; module loader ("expected a `module' declaration") — blocking fram's schema.bclj
;; flip-view (self-host 12/12). This drives source -> EDN -> render and asserts the
;; rendered output is a real #lang module AND re-reads to the identical forms.
;;
;; facts-roundtrip.rkt is a pure data-level module (fixtures are read as data —
;; no dynamic-require or module-registry caching concern), so every case calls
;; emit-edn-file / render-edn in-process: one compiler load, many cheap cases.

(require rackunit
         rackunit/text-ui
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

;; --- in-process runner -------------------------------------------------------
;; Guards, per case:
;;   * catch-all with-handlers — one case's exn/raise never aborts the batch;
;;     mirrors certify.rkt's compile-fixture (lift of the same pattern).
;;   * exit-handler parameterized to RAISE instead of terminating the test
;;     process — emit-edn-file/render-edn never call (exit) themselves, but this
;;     is a hard guard against a downstream dependency doing so on a bad fixture.
;;   * stdout captured via a FRESH string port per call (parameterized
;;     current-output-port) — no shared mutable buffer, no cross-case leakage.
(define (run mode path)
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
          [else (error 'run "unsupported mode ~a" mode)])
        'ok)))
  (define captured (get-output-string op))
  (if (eq? result 'ok)
      (values 0 captured "")
      (values 1 captured (cdr result))))

(define (render-roundtrip src-text [extension ".bclj"])
  (define f (make-temporary-file (string-append "crt-~a" extension)))
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
     (define out (render-roundtrip "#lang beagle/clj\n\n;; hdr\n(def x Int 42)\n"))
     (check-true (string-prefix? out "#lang beagle/clj")
                 (format "rendered did not start with #lang:\n~a" out))
     (check-false (string-contains? out "(define-target")
                  "rendered still contains (define-target …)"))

   (test-case "render reconstructs #lang beagle/nix"
     (define out (render-roundtrip "#lang beagle/nix\n(def x Int 1)\n"))
     (check-true (string-prefix? out "#lang beagle/nix") out))

   (test-case "render reconstructs bare #lang beagle for Core"
     (define out
       (render-roundtrip "#lang beagle\n(def x Int 1)\n" ".bgl"))
     (check-true (string-prefix? out "#lang beagle\n") out))))

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

(define (reader-rejection-case name src)
  (test-case name
    (define path (make-temporary-file "facts-reader-rejection-~a.bclj"))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file path #:exists 'truncate
          (lambda (out) (display src out)))
        (define-values (status stdout stderr)
          (run "--emit-edn" (path->string path)))
        (check-equal? status 1)
        (check-equal? stdout "")
        (check-regexp-match #rx"bad syntax `#\\^`" stderr))
      (lambda ()
        (when (file-exists? path) (delete-file path))))))

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
             "(defmacro m\n  [obj\n   xs] `(vary-meta ~obj assoc :tags `[~@xs]))\n"
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
             "(defn assoc-param-map\n  [req\n   k\n   v]\n  (some-> req (assoc k (if-let [v' (req k)] (reduce-kv assoc v' v) v))))\n"
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

   ;; G12 was removed from the language. Keep the old spellings as negative
   ;; fixtures so the facts path cannot silently resurrect them.
   (reader-rejection-case "G12 #^String legacy metadata is rejected"
                          "(defn f [#^String s] s)\n")
   (reader-rejection-case "G12 #^{:tag} legacy metadata is rejected"
                          "(def #^{:tag String} x 1)\n")

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
