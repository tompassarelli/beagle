#lang racket/base

;; Every Beagle source writer preserves structural typed forms. Executable
;; signatures use a mandatory positional return; function-type arrows remain.

(require rackunit
         racket/string
         racket/port
         racket/file
         beagle/lang/reader-impl
         (only-in beagle/private/facts-roundtrip datum->src datum->pretty)
         (only-in beagle/private/expand-tool datum->beagle-src)
         (only-in beagle/private/rewrite write-beagle-source)
         (only-in beagle/private/query query-sig))

(define (rd s) (beagle-read (open-input-string s)))
(define (src s) (datum->src (rd s)))
(define (pp s [col 0]) (datum->pretty (rd s) col))

(define STRUCTURAL-BATTERY
  '("(def answer Int 42)"
    "(defonce once Int 1)"
    "(defn add [(x Int) (y Int)] Int (+ x y))"
    "(defn positive [(x Int positive?)] Int x)"
    "(defn hof [(cb (Fn [Int] String))] String (cb 1))"
    "(defrecord P [(x Int) (y (Vec Int) nonempty?)])"
    "(let [(v Int positive?) e] v)"
    "(fn [(b Int)] Int b)"
    "(defn m ([(a Int)] Int a) ([(a Int) (b Int)] Int b))"))

(for ([s (in-list STRUCTURAL-BATTERY)])
  (test-case (format "datum->src is byte-identical for: ~a" s)
    (check-equal? (src s) s))
  (test-case (format "datum->beagle-src is byte-identical for: ~a" s)
    (check-equal? (datum->beagle-src (rd s)) s)))

(test-case "function-type arrows remain data inside types"
  (check-equal? (src "(defn hof [(cb (Fn [Int] String))] String (cb 1))")
                "(defn hof [(cb (Fn [Int] String))] String (cb 1))"))

(test-case "structural source writers emit no annotation punctuation"
  (for ([s (in-list STRUCTURAL-BATTERY)])
    (for ([out (in-list (list (src s) (pp s) (datum->beagle-src (rd s))))])
      (check-false (string-contains? out "#%:") s)
      (check-false (string-contains? out ":-") s))))

(define ROUNDTRIP-BATTERY
  (append
   STRUCTURAL-BATTERY
   '("(defn ^:private q [(a Int)] Int a)"
     "(def ^:dynamic *cfg* Int 1)"
     "(defn r [(a Int) & (more Int)] Int a)"
     "(defn fr [(xs (Vec Int))] Nil (for [(x Int) xs :let [(y Int) x]] y))"
     "(defprotocol Area (area [self] Int))"
     "(letfn [(h [(b Int)] Int b)] (h 1))"
     "(forall [(T <: String)] T)"
     "{:k 1 :j 2}"
     "`[(~name ~type)]")))

(for ([s (in-list ROUNDTRIP-BATTERY)])
  (test-case (format "read->datum->src->read is the identity: ~a" s)
    (check-equal? (rd (src s)) (rd s)))
  (test-case (format "read->datum->pretty->read is the identity: ~a" s)
    (check-equal? (rd (pp s)) (rd s)))
  (test-case (format "read->write-beagle-source->read is the identity: ~a" s)
    (define out
      (with-output-to-string
        (lambda () (write-beagle-source (list (rd s)) (current-output-port)))))
    (check-equal? (rd out) (rd s) out)))

(define CANONICAL-LAYOUT
  '("(defn add [(x Int) (y Int)] Int (+ x y))"
    "(defn resty [(x Int) & (more Int)] Int x)"
    "(fn [(x Int) (y Int)] Int (+ x y))"
    "(fn add [(x Int) (y Int)] Int (+ x y))"
    "(defmacro pair [x y] `[~x ~y])"
    "(defn choose ([x] Any x) ([x y] Any y))"
    "(letfn [(sum [(x Int) (y Int)] Int (+ x y))] (sum 1 2))"
    "(defprotocol P (m [self (x Int)] Int))"
    "(extend-type T P (m [self (x Int)] Int x))"
    "(defrecord P [(x Int) (y String)])"
    "(defunion Shape (Rect [(width Int) (height Int)]))"
    "(defunion :throwable Failure (Bad [(message String) (path String)]))"))

(for ([s (in-list CANONICAL-LAYOUT)])
  (test-case (format "canonical grammar layout: ~a" s)
    (define out (pp s))
    (check-equal? out s)
    (check-equal? (rd out) (rd s))))

(test-case "three grammar entries stay inline when the complete signature fits"
  (check-equal? (pp "(defn f [(a Int) (b Int) (c Int)] Int a)")
                "(defn f [(a Int) (b Int) (c Int)] Int a)"))

(test-case "compact constrained bindings preserve their structural owner form"
  (check-equal? (pp "(defn f [(a Int positive?)] Int a)")
                "(defn f [(a Int positive?)] Int a)"))

(test-case "complete signature width is inclusive at 80 columns"
  (define prefix "(defn ")
  (define suffix " [(x Int) (y Int)] Int")
  (define name-80
    (make-string (- 80 (string-length prefix) (string-length suffix)) #\x))
  (define signature-80 (string-append prefix name-80 suffix))
  (define out-80 (pp (string-append signature-80 " 0)")))
  (check-equal? (car (string-split out-80 "\n")) signature-80)
  (define name-81 (string-append name-80 "x"))
  (define out-81 (pp (string-append prefix name-81 suffix " 0)")))
  (check-equal? (car (string-split out-81 "\n")) (string-append prefix name-81))
  (check-equal? (cadr (string-split out-81 "\n"))
                "  [(x Int) (y Int)] Int"))

(test-case "an over-width owner moves a fitting signature as one unit"
  (define name (make-string 58 #\z))
  (define out
    (pp (format "(defn ~a [(alpha Int) (beta String)] Int alpha)" name)))
  (define lines (string-split out "\n"))
  (check-equal? (car lines) (format "(defn ~a" name))
  (check-equal? (cadr lines) "  [(alpha Int) (beta String)] Int")
  (check-equal? (caddr lines) "  alpha)"))

(test-case "an over-width signature unit expands bindings and isolates return"
  (define source
    (string-append
     "(defn complicated-distance "
     "[(anchor Coordinate) (coord Coordinate) (world WorldState) "
     "(options DistanceOptions)] Float world)"))
  (check-equal?
   (pp source)
   (string-append
    "(defn complicated-distance\n"
    "  [(anchor Coordinate)\n"
    "   (coord Coordinate)\n"
    "   (world WorldState)\n"
    "   (options DistanceOptions)]\n"
    "  Float\n"
    "  world)")))

(test-case "expanded signatures keep constrained declarations whole"
  (define source
    (string-append
     "(defn constrained-distance "
     "[(anchor Coordinate coordinate?) (coord Coordinate coordinate?) "
     "(world WorldState ready-world?) (options DistanceOptions valid-options?)] "
     "Float world)"))
  (check-equal?
   (pp source)
   (string-append
    "(defn constrained-distance\n"
    "  [(anchor Coordinate coordinate?)\n"
    "   (coord Coordinate coordinate?)\n"
    "   (world WorldState ready-world?)\n"
    "   (options DistanceOptions valid-options?)]\n"
    "  Float\n"
    "  world)")))

(test-case "an individually over-width declaration expands internally"
  (define source
    (string-append
     "(defn validated-coordinate "
     "[(coordinate InternationalCoordinateReferenceSystem "
     "coordinate-inside-supported-world-boundaries?)] Float coordinate)"))
  (define expected
    (string-append
     "(defn validated-coordinate\n"
     "  [(coordinate\n"
     "    InternationalCoordinateReferenceSystem\n"
     "    coordinate-inside-supported-world-boundaries?)]\n"
     "  Float\n"
     "  coordinate)"))
  (check-equal? (pp source) expected)
  (check-equal? (pp expected) expected))

(test-case "a long constraint expression expands inside its declaration"
  (define source
    (string-append
     "(defn validated-coordinate "
     "[(coordinate Coordinate (and coordinate-inside-supported-world-boundaries? "
     "coordinate-has-supported-reference-system?))] Float coordinate)"))
  (define expected
    (string-append
     "(defn validated-coordinate\n"
     "  [(coordinate\n"
     "    Coordinate\n"
     "    (and\n"
     "     coordinate-inside-supported-world-boundaries?\n"
     "     coordinate-has-supported-reference-system?))]\n"
     "  Float\n"
     "  coordinate)"))
  (check-equal? (pp source) expected)
  (check-true
   (for/and ([line (in-list (string-split expected "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (pp expected) expected))

(test-case "a long constrained rest declaration expands as one structural entry"
  (define source
    (string-append
     "(defn collect [(first Int) & "
     "(remaining-values (Vec InternationalCoordinateReferenceSystem) "
     "all-coordinates-inside-supported-world-boundaries?)] Int first)"))
  (define expected
    (string-append
     "(defn collect\n"
     "  [(first Int)\n"
     "   & (remaining-values\n"
     "      (Vec InternationalCoordinateReferenceSystem)\n"
     "      all-coordinates-inside-supported-world-boundaries?)]\n"
     "  Int\n"
     "  first)"))
  (check-equal? (pp source) expected)
  (check-true
   (for/and ([line (in-list (string-split expected "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (pp expected) expected))

(test-case "the enclosing vector closer counts at the 80-column boundary"
  (define predicate-at-80 (make-string 68 #\p))
  (define predicate-at-81 (string-append predicate-at-80 "p"))
  (define at-80
    (pp (format "(defn f [(x Int ~a)] Int x)" predicate-at-80)))
  (check-true
   (string-contains? at-80 (format "  [(x Int ~a)]\n" predicate-at-80)))
  (check-true
   (for/and ([line (in-list (string-split at-80 "\n"))])
     (<= (string-length line) 80)))
  (define at-81
    (pp (format "(defn f [(x Int ~a)] Int x)" predicate-at-81)))
  (check-true (string-contains? at-81 "  [(x\n    Int\n"))
  (check-true
   (for/and ([line (in-list (string-split at-81 "\n"))])
     (<= (string-length line) 80))))

(test-case "typed destructuring is one structural binding form"
  (check-equal?
   (pp (string-append
        "(defn distance [([x1 y1] (HVec Float Float)) "
        "([x2 y2] (HVec Float Float))] Float "
        "(+ x1 x2))"))
   (string-append
    "(defn distance [([x1 y1] (HVec Float Float)) "
    "([x2 y2] (HVec Float Float))] Float\n"
    "  (+ x1 x2))"))
  (check-equal?
   (src "(defn connect [({:keys [host port]} Config)] String host)")
   "(defn connect [({:keys [host port]} Config)] String host)"))

(test-case "all three signature layout tiers are idempotent"
  (define sources
    (list
     "(defn distance [(a Point) (b Point)] Float a)"
     (format "(defn ~a [(a Point) (b Point)] Float a)"
             (make-string 62 #\h))
     (string-append
      "(defn complicated-distance "
      "[(anchor Coordinate) (coord Coordinate) (world WorldState) "
      "(options DistanceOptions)] Float world)")))
  (for ([source (in-list sources)])
    (define once (pp source))
    (check-equal? (datum->pretty (rd once)) once source)))

(test-case "multi-arity clauses expand the unit without orphaning their opener"
  (define source
    (string-append
     "(defn f "
     "([(anchor Coordinate) (coord Coordinate) (world WorldState) "
     "(options DistanceOptions)] Float anchor) ([x] Int x))"))
  (check-equal?
   (pp source)
   (string-append
    "(defn f\n"
    "  ([(anchor Coordinate)\n"
    "    (coord Coordinate)\n"
    "    (world WorldState)\n"
    "    (options DistanceOptions)]\n"
    "   Float\n"
    "   anchor)\n"
    "  ([x] Int x))")))

(test-case "ordinary data and let binding vectors keep generic pretty-printing"
  (check-equal? (pp "[a b]") "[a b]")
  (check-equal? (pp "(f [a b])") "(f [a b])")
  (check-equal? (pp "(let [a 1 b 2] (+ a b))")
                "(let [a 1 b 2] (+ a b))"))

(test-case "datum->pretty is idempotent at the fixed point"
  (for ([s (in-list ROUNDTRIP-BATTERY)])
    (check-equal? (datum->pretty (rd (pp s))) (pp s) s)))

(test-case "symbols containing an interior colon still round-trip via bars"
  (for ([s (in-list '("|a:b|" "|:|" "(f |x:| |:y|)"))])
    (check-equal? (rd (src s)) (rd s) (src s))))

(test-case "keywords stay bare"
  (check-equal? (src "(f :kw ::kw :a/b :-)" )
                "(f :kw ::kw :a/b :-)"))

(test-case "query-sig reports the structural signature"
  (define tmp (make-temporary-file "sig-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o)
         (display (string-append
                   "#lang beagle/clj\n(ns t)\n"
                   "(defn add [(x Int) (y Int)] String \"s\")\n"
                   "(def answer Int 42)\n") o))
       #:exists 'truncate/replace)
     (define out
       (with-output-to-string
         (lambda () (query-sig "add" (list (path->string tmp))))))
     (check-true (string-contains? out "Int") out)
     (check-true (string-contains? out "String") out))
   (lambda () (delete-file tmp))))
