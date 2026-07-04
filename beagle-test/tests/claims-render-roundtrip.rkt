#lang racket/base

;; #17 regression: the claims renderer (`--render`) must reconstruct the `#lang`
;; header from the leading `(define-target X)` form (read-beagle-syntax
;; canonicalizes `#lang beagle/X` -> that form). A rendered module that led with
;; `(define-target …)` instead of `#lang` was rejected by bin/beagle check's
;; module loader ("expected a `module' declaration") — blocking fram's schema.bclj
;; flip-view (self-host 12/12). This drives source -> EDN -> render and asserts the
;; rendered output is a real #lang module AND re-reads to the identical forms.

(require rackunit
         rackunit/text-ui
         racket/port
         racket/file
         racket/string)

(define crt-path
  (path->string (collection-file-path "claims-roundtrip.rkt" "beagle" "private")))

(define (run . args)
  (define-values (proc out in err) (apply subprocess #f #f #f (find-executable-path "racket") crt-path args))
  (close-output-port in)
  (define o (port->string out))
  (define e (port->string err))
  (subprocess-wait proc)
  (close-input-port out) (close-input-port err)
  (values (subprocess-status proc) o e))

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
 (test-suite "claims render — #lang reconstruction (#17)"

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
 (test-suite "claims render — EXP-025 reader-macro inversion (G1–G5)"

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
