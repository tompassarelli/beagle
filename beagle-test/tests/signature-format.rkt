#lang racket/base

(require rackunit
         racket/file
         racket/string
         beagle/private/parse
         beagle/private/signature-format)

(define (with-source source proc)
  (define path (make-temporary-file "beagle-signature-format-~a.bclj"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file path
        (lambda (out) (display source out))
        #:exists 'truncate/replace))
    (lambda () (proc path))
    (lambda () (when (file-exists? path) (delete-file path)))))

(define (formatted source)
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (values (apply-signature-layout-edits source edits) edits))))

(test-case "typed parameters stay structural and compact when the signature fits"
  (define source
    (string-append
     "(defn one [(x Int)] Int x)\n"
     "(defn positive [(x Int positive?)] Int x)\n"
     "(defn add [(x Int) (y Int)] Int (+ x y))\n"
     "(defn clamp [(value Int) (minimum Int) (maximum Int)] Int value)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "an over-width owner moves a fitting signature as one unit"
  (define name (make-string 52 #\f))
  (define source
    (format "(defn ~a [(value Int) (minimum Int) (maximum Int)] Int value)\n" name))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    (format "(defn ~a\n" name)
    "  [(value Int) (minimum Int) (maximum Int)] Int value)\n"))
  (check-equal? (length edits) 1))

(test-case "expanded signatures keep each constrained binding structurally whole"
  (define source
    (string-append
     "(defn constrained-distance "
     "[(anchor Coordinate coordinate?) (coord Coordinate coordinate?) "
     "(world WorldState ready-world?) (options DistanceOptions valid-options?)] "
     "Float world)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    "(defn constrained-distance\n"
    "  [(anchor Coordinate coordinate?)\n"
    "   (coord Coordinate coordinate?)\n"
    "   (world WorldState ready-world?)\n"
    "   (options DistanceOptions valid-options?)]\n"
    "  Float\n"
    "  world)\n"))
  (check-equal? (length edits) 1))

(test-case "an individually over-width binding expands inside its vector"
  (define source
    (string-append
     "(defn validated-coordinate "
     "[(coordinate InternationalCoordinateReferenceSystem "
     "coordinate-inside-supported-world-boundaries?)] Float coordinate)\n"))
  (define expected
    (string-append
     "(defn validated-coordinate\n"
     "  [(coordinate\n"
     "    InternationalCoordinateReferenceSystem\n"
     "    coordinate-inside-supported-world-boundaries?)]\n"
     "  Float\n"
     "  coordinate)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual expected)
  (check-equal? (length edits) 1)
  (define-values (fixed-point fixed-point-edits) (formatted expected))
  (check-equal? fixed-point expected)
  (check-equal? fixed-point-edits '()))

(test-case "an over-width constraint expression expands inside its declaration"
  (define source
    (string-append
     "(defn validated-coordinate "
     "[(coordinate Coordinate (and coordinate-inside-supported-world-boundaries? "
     "coordinate-has-supported-reference-system?))] Float coordinate)\n"))
  (define expected
    (string-append
     "(defn validated-coordinate\n"
     "  [(coordinate\n"
     "    Coordinate\n"
     "    (and\n"
     "     coordinate-inside-supported-world-boundaries?\n"
     "     coordinate-has-supported-reference-system?))]\n"
     "  Float\n"
     "  coordinate)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual expected)
  (check-true
   (for/and ([line (in-list (string-split actual "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (length edits) 1)
  (define-values (fixed-point fixed-point-edits) (formatted expected))
  (check-equal? fixed-point expected)
  (check-equal? fixed-point-edits '()))

(test-case "the vector closer participates in the binding width boundary"
  (define predicate-at-80 (make-string 68 #\p))
  (define predicate-at-81 (string-append predicate-at-80 "p"))
  (define-values (at-80 at-80-edits)
    (formatted
     (format "(defn f [(x Int ~a)] Int x)\n" predicate-at-80)))
  (check-true
   (string-contains? at-80 (format "  [(x Int ~a)]\n" predicate-at-80)))
  (check-true
   (for/and ([line (in-list (string-split at-80 "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (length at-80-edits) 1)
  (define-values (at-81 at-81-edits)
    (formatted
     (format "(defn f [(x Int ~a)] Int x)\n" predicate-at-81)))
  (check-true (string-contains? at-81 "  [(x\n    Int\n"))
  (check-true
   (for/and ([line (in-list (string-split at-81 "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (length at-81-edits) 1))

(test-case "an over-width signature unit expands bindings and isolates return"
  (define source
    (string-append
     "(defn complicated-distance "
     "[(anchor Coordinate) (coord Coordinate) (world WorldState) "
     "(options DistanceOptions)] Float world)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    "(defn complicated-distance\n"
    "  [(anchor Coordinate)\n"
    "   (coord Coordinate)\n"
    "   (world WorldState)\n"
    "   (options DistanceOptions)]\n"
    "  Float\n"
    "  world)\n"))
  (check-equal? (length edits) 1))

(test-case "structural bindings, bare destructuring, and data vectors are stable"
  (define source
    (string-append
     "(defn add [(x Int) (y Int)] Int (+ x y))\n"
     "(defrecord Point [(x Int) (y Int)])\n"
     "(defn destr [[a b]] Int a)\n"
     "(defn kdestr [{:keys [a]}] Int a)\n"
     "(def data [x y z])\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "layout correction never wraps a typed binding in another form"
  (define-values (actual edits)
    (formatted "(defn add\n  [(x Int)\n   (y Int)] Int (+ x y))\n"))
  (check-equal? actual "(defn add [(x Int) (y Int)] Int (+ x y))\n")
  (check-equal? (length edits) 1)
  (check-equal? (layout-edit-role (car edits)) "parameter"))

(test-case "a typed rest parameter is one logical entry after ampersand"
  (define-values (actual edits)
    (formatted "(defn collect\n  [(a Int)\n   & (more (Vec Int))] Int a)\n"))
  (check-equal? actual
                "(defn collect [(a Int) & (more (Vec Int))] Int a)\n")
  (check-equal? (length edits) 1))

(test-case "an over-width constrained rest binding expands structurally"
  (define source
    (string-append
     "(defn collect [(first Int) & "
     "(remaining-values (Vec InternationalCoordinateReferenceSystem) "
     "all-coordinates-inside-supported-world-boundaries?)] Int first)\n"))
  (define expected
    (string-append
     "(defn collect\n"
     "  [(first Int)\n"
     "   & (remaining-values\n"
     "      (Vec InternationalCoordinateReferenceSystem)\n"
     "      all-coordinates-inside-supported-world-boundaries?)]\n"
     "  Int\n"
     "  first)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual expected)
  (check-true
   (for/and ([line (in-list (string-split actual "\n"))])
     (<= (string-length line) 80)))
  (check-equal? (length edits) 1)
  (define-values (fixed-point fixed-point-edits) (formatted expected))
  (check-equal? fixed-point expected)
  (check-equal? fixed-point-edits '()))

(test-case "the positional return participates in the inclusive width boundary"
  (define signature-skeleton "(defn ~a [(x Int)] ExtremelyLongReturnType")
  (define source-skeleton
    (string-append signature-skeleton " x)"))
  (define base-width (string-length (format signature-skeleton "")))
  (define at-name (make-string (- 80 base-width) #\f))
  (define over-name (string-append at-name "f"))
  (define at-width (string-append (format source-skeleton at-name) "\n"))
  (define over-width (string-append (format source-skeleton over-name) "\n"))
  (define-values (at-actual at-edits) (formatted at-width))
  (check-equal? at-actual at-width)
  (check-equal? at-edits '())
  (define-values (over-actual over-edits) (formatted over-width))
  (check-equal? over-actual
                (format "(defn ~a\n  [(x Int)] ExtremelyLongReturnType x)\n"
                        over-name))
  (check-equal? (length over-edits) 1))

(test-case "raises metadata stays with the positional return signature"
  (define name (make-string 58 #\f))
  (define source
    (string-append
     "(defunion :throwable Boom (Boom [(message String)]))\n"
     (format "(defn ~a [(x Int)] Int :raises Boom x)\n" name)))
  (define-values (actual edits) (formatted source))
  (check-true
   (string-contains?
    actual
    (format "(defn ~a\n  [(x Int)] Int :raises Boom x)" name)))
  (check-equal? (length edits) 1))

(test-case "multi-arity clauses expand without orphaning their opener"
  (define source
    (string-append
     "(defn f\n"
     "  ([(anchor Coordinate) (coord Coordinate) (world WorldState) "
     "(options DistanceOptions)] Float anchor)\n"
     "  ([x] Int x))\n"))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    "(defn f\n"
    "  ([(anchor Coordinate)\n"
    "    (coord Coordinate)\n"
    "    (world WorldState)\n"
    "    (options DistanceOptions)]\n"
    "   Float\n"
    "   anchor)\n"
    "  ([x] Int x))\n"))
  (check-equal? (length edits) 1))

(test-case "defmacro uses the same structural parameter layout"
  (define-values (actual edits)
    (formatted "(defmacro m [(x Any)] `(do ~x))\n"))
  (check-equal? actual "(defmacro m [(x Any)] `(do ~x))\n")
  (check-equal? edits '()))

(test-case "rest and destructuring forms are logical entries"
  (define-values (actual edits)
    (formatted "(defn collect\n  [x\n   {:keys [y]}\n   & rest] Any x)\n"))
  (check-equal? actual
                "(defn collect [x {:keys [y]} & rest] Any x)\n")
  (check-equal? (length edits) 1))

(test-case "function-style grammar sites share the rule"
  (define source
    (string-append
     "(def f (fn\n        [x\n         y] Any (+ x y)))\n"
     "(defrecord Pair\n  [(left Int)\n   (right Int)])\n"
     "(defprotocol P (m\n                 [this\n                  x] Int))\n"
     "(extend-type Pair (m\n                    [this\n                     x] Int x))\n"
     "(defunion U (Pair\n               [(left Int)\n                (right Int)]))\n"))
  (define-values (actual edits) (formatted source))
  (check-true (string-contains? actual "(fn [x y] Any"))
  (check-true (string-contains? actual "(defrecord Pair [(left Int) (right Int)])"))
  (check-true (string-contains? actual "(m [this x] Int)"))
  (check-true (string-contains? actual "(m [this x] Int x)"))
  (check-true (string-contains? actual "(Pair [(left Int) (right Int)])"))
  (check-equal? (length edits) 5))

(test-case "record fields and methods use the same width hierarchy"
  (define record-name (make-string 58 #\R))
  (define method-name (make-string 54 #\m))
  (define source
    (string-append
     (format "(defrecord ~a [(left Int) (right Int)])\n" record-name)
     (format "(defprotocol P (~a [(self P) (x Int)] Int))\n" method-name)))
  (define-values (actual edits) (formatted source))
  (check-true
   (string-contains?
    actual
    (format "(defrecord ~a\n  [(left Int) (right Int)])" record-name)))
  (check-true
   (string-contains?
    actual
    (format "(~a\n                 [(self P) (x Int)] Int)" method-name)))
  (check-equal? (length edits) 2))

(test-case "line-comment reach makes a rewrite diagnostic-only"
  (define source
    "(defn f ; owner comment\n  [x ; first parameter\n   y] Any x)\n")
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (check-equal? (length edits) 1)
     (check-false (layout-edit-safe? (car edits)))
     (check-exn exn:fail?
                (lambda () (apply-signature-layout-edits source edits)))
     (check-equal? (format-signature-files 'write (list path)) 2)
     (check-equal? (file->string path) source))))

(test-case "expanding a signature never moves a return-line comment"
  (define source
    (string-append
     "(defn complicated-distance "
     "[(anchor Coordinate) (coord Coordinate) (world WorldState) "
     "(options DistanceOptions)] Float ; keep with return\n"
     "  world)\n"))
  (with-source
   source
   (lambda (path)
     (define edits (signature-layout-edits path))
     (check-equal? (length edits) 1)
     (check-false (layout-edit-safe? (car edits)))
     (check-exn exn:fail?
                (lambda () (apply-signature-layout-edits source edits))))))

(test-case "check reports drift and write reaches an idempotent fixed point"
  (define source "(defn add\n  [x\n   y] Any (+ x y))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (file->string path)
                   "(defn add [x y] Any (+ x y))\n")
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "one write converges nested signatures after outer column shifts"
  (define return-type (make-string 50 #\R))
  (define source
    (format "(defn outer [a b c] Any (fn [x y] ~a x))\n" return-type))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-true
      (string-contains? (file->string path)
                        (format "y]\n                          ~a\n                          x)"
                                return-type)))
     (check-true (string-contains? (file->string path) "(fn\n")))))
