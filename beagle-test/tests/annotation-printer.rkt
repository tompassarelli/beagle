#lang racket/base

;; Canonical surface rendering for flat typed bindings and ascription.

(require rackunit
         racket/port
         racket/string
         beagle/lang/reader-impl
         (only-in beagle/private/facts-roundtrip datum->src datum->pretty)
         (only-in beagle/private/expand-tool datum->beagle-src)
         (only-in beagle/private/rewrite write-beagle-source))

(define (rd source)
  (beagle-read (open-input-string source)))

(define (src source)
  (datum->src (rd source)))

(define (pretty source)
  (datum->pretty (rd source)))

(define LEGACY->CANONICAL
  (list
   (cons "(def answer Int 42)"
         "(def answer (: 42 Int))")
   (cons "(defonce once Int 1)"
         "(defonce once (: 1 Int))")
   (cons "(defn greet [(name String)] String (str name))"
         "(defn greet [name String] String (str name))")
   (cons "(fn [(value Int)] Int value)"
         "(fn [value Int] Int value)")
   (cons "(defn collect [(first Int) & (more (Vec Int))] Int first)"
         "(defn collect [first Int & more (Vec Int)] Int first)")
   (cons "(let [(value Int) source] value)"
         "(let [value (: source Int)] value)")
   (cons "(defrecord Point [(x Float) (y Float)])"
         "(defrecord Point [x Float y Float])")))

(for ([example (in-list LEGACY->CANONICAL)])
  (define legacy (car example))
  (define canonical (cdr example))
  (test-case (format "datum source canonicalizes: ~a" legacy)
    (check-equal? (src legacy) canonical)
    (check-equal? (datum->beagle-src (rd legacy)) canonical)
    (check-equal? (src canonical) canonical)))

(test-case "single unrefined pair stays inline regardless of width"
  (define name (make-string 120 #\n))
  (define source (format "(defn ~a [value Int] Int value)" name))
  (check-equal?
   (pretty source)
   (format "(defn ~a [value Int] Int\n  value)" name)))

(test-case "more than one pair breaks by grammar, not width"
  (check-equal?
   (pretty "(defn add [(x Int) (y Int)] Int (+ x y))")
   (string-append
    "(defn add\n"
    "  [x Int\n"
    "   y Int]\n"
    "  Int\n"
    "  (+ x y))")))

(test-case "a refinement forces a one-pair vector to break"
  (check-equal?
   (pretty "(defn positive [(x Int positive?)] Int x)")
   (string-append
    "(defn positive\n"
    "  [x (Int where positive?)]\n"
    "  Int\n"
    "  x)")))

(test-case "canonical ruling example"
  (define source
    (string-append
     "(defn resize [shape Shape width (Int where (> _ 0)) "
     "height (Int where (> _ 0))] Shape "
     "(where (fits shape width height)) ...)"))
  (define expected
    (string-append
     "(defn resize\n"
     "  [shape Shape\n"
     "   width (Int where (> _ 0))\n"
     "   height (Int where (> _ 0))]\n"
     "  Shape\n"
     "  (where (fits shape width height))\n"
     "  ...)"))
  (check-equal? (pretty source) expected)
  (check-equal? (pretty expected) expected))

(test-case "destructuring binder remains one pair"
  (check-equal?
   (pretty
    "(defn place [({:keys [w h]} Size) (label String)] Point label)")
   (string-append
    "(defn place\n"
    "  [{:keys [w h]} Size\n"
    "   label String]\n"
    "  Point\n"
    "  label)")))

(test-case "variadic marker stays attached to exactly one pair"
  (check-equal?
   (pretty "(defn collect [(first Int) & (more (Vec Int))] Int first)")
   (string-append
    "(defn collect\n"
    "  [first Int\n"
    "   & more (Vec Int)]\n"
    "  Int\n"
    "  first)")))

(test-case "fn and defrecord use the same vector break law"
  (check-equal?
   (pretty "(fn [(x Int) (y Int)] Int (+ x y))")
   (string-append
    "(fn\n"
    "  [x Int\n"
    "   y Int] Int\n"
    "  (+ x y))"))
  (check-equal?
   (pretty "(defrecord Point [(x Float) (y Float)])")
   (string-append
    "(defrecord Point\n"
    "  [x Float\n"
    "   y Float])")))

;; The breaking law is per-VECTOR, not per-form: there is no form in the
;; language where two bindings share a line. `let` and `loop` are bound by it
;; exactly as `defn` is, with no width threshold and no "it fits" case.
(test-case "let and loop break more than one binding one per line"
  (check-equal?
   (pretty "(let [a 1 b 2] a)")
   (string-append
    "(let\n"
    "  [a 1\n"
    "   b 2]\n"
    "  a)"))
  (check-equal?
   (pretty "(loop [i 0 total 0] i)")
   (string-append
    "(loop\n"
    "  [i 0\n"
    "   total 0]\n"
    "  i)"))
  (check-equal?
   (pretty "(let [(a Int) 1 (b Int) 2] a)")
   (string-append
    "(let\n"
    "  [a (: 1 Int)\n"
    "   b (: 2 Int)]\n"
    "  a)")))

(test-case "a single unrefined binding may stay inline"
  (check-equal? (pretty "(let [a 1] a)") "(let [a 1] a)")
  (check-equal? (pretty "(loop [i 0] i)") "(loop [i 0] i)")
  (check-equal? (pretty "(let [(a Int) 1] a)") "(let [a (: 1 Int)] a)"))

(test-case "a refinement forces a one-binding let to break"
  (check-equal?
   (pretty "(let [(width Int (> _ 0)) source] width)")
   (string-append
    "(let\n"
    "  [width (: source (Int where (> _ 0)))]\n"
    "  width)")))

(test-case "multi-arity defn prints each expanded return on its own line"
  (check-equal?
   (pretty
    "(defn f ([(x Int)] Int x) ([(x Int) (y Int)] Int (+ x y)))")
   (string-append
    "(defn f\n"
    "  ([x Int] Int x)\n"
    "  ([x Int\n"
    "    y Int]\n"
    "   Int\n"
    "   (+ x y)))")))

(test-case "nested typed owner sites contain no grouped declarations"
  (for ([source
         (in-list
          (list
           "(letfn [(sum [(x Int) (y Int)] Int (+ x y))] (sum 1 2))"
           "(defprotocol P (m [(self P) (x Int)] Int))"
           "(extend-type T P (m [(self T) (x Int)] Int x))"
           "(defunion Shape (Rect [(width Int) (height Int)]))"))])
    (define rendered (src source))
    (check-false (regexp-match? #px"\\[\\([^]]+ [^]]+\\)" rendered)
                 rendered)))

(test-case "write-beagle-source emits the canonical fixed point"
  (define legacy (rd "(defn add [(x Int) (y Int)] Int (+ x y))"))
  (define rendered
    (with-output-to-string
      (lambda ()
        (write-beagle-source (list legacy) (current-output-port)))))
  (check-equal?
   rendered
   (string-append
    "(defn add\n"
    "  [x Int\n"
    "   y Int]\n"
    "  Int\n"
    "  (+ x y))\n\n")))

(test-case "ordinary vectors and colon-bearing symbols stay data"
  (check-equal? (pretty "(f [a b])") "(f [a b])")
  (check-equal? (rd (src "(f |x:| :kw ::kw)"))
                (rd "(f |x:| :kw ::kw)")))
