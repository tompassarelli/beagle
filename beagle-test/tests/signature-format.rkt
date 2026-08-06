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

(test-case "one or two parameters stay inline when the complete signature fits"
  (define-values (actual edits)
    (formatted
     "(defn add\n  [(x : Int)\n   (y : Int)] -> Int\n  (+ x y))\n"))
  (check-equal? actual
                "(defn add [(x : Int) (y : Int)] -> Int\n  (+ x y))\n")
  (check-equal? (length edits) 1))

(test-case "three logical parameters are always vertical"
  (define-values (actual edits)
    (formatted
     "(defn clamp [(value : Int) (minimum : Int) (maximum : Int)] -> Int value)\n"))
  (check-equal?
   actual
   (string-append
    "(defn clamp\n"
    "  [(value : Int)\n"
    "   (minimum : Int)\n"
    "   (maximum : Int)] -> Int value)\n"))
  (check-equal? (length edits) 1))

(test-case "a flat typed binding is drift; the canonical form is parenthesized"
  (define-values (actual edits)
    (formatted "(defn add [x: Int y: Int] -> Int\n  (+ x y))\n"))
  (check-equal? actual "(defn add [(x : Int) (y : Int)] -> Int\n  (+ x y))\n")
  (check-equal? (length edits) 1)
  (check-equal? (layout-edit-role (car edits)) "parameter"))

(test-case "the canonical parenthesized form is silent"
  (define source
    (string-append
     "(defn add [(x : Int) (y : Int)] -> Int (+ x y))\n"
     "(defrecord Point [(x : Int) (y : Int)])\n"
     "(defn destr [([a b] : Point)] -> Int a)\n"
     "(defn kdestr [({:keys [a]} : Point)] -> Int a)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "marker spacing inside an already-wrapped entry is normalized"
  (define-values (actual edits)
    (formatted
     (string-append
      "(defn f [(x: Int)] -> Int x)\n"
      "(defn g [([a b]: Point)] -> Int a)\n")))
  (check-equal?
   actual
   (string-append
    "(defn f [(x : Int)] -> Int x)\n"
    "(defn g [([a b] : Point)] -> Int a)\n"))
  (check-equal? (length edits) 2))

(test-case "a typed rest parameter is wrapped inside the & pair"
  (define-values (actual edits)
    (formatted "(defn collect [a: Int & more: (Vec Int)] -> Int a)\n"))
  (check-equal? actual "(defn collect [(a : Int) & (more : (Vec Int))] -> Int a)\n")
  (check-equal? (length edits) 1))

(test-case "wrapping counts toward the 80-column signature width"
  ;; `(defn <60 f> [x: Int] -> Int x)` is 79 columns flat and 81 wrapped, so the
  ;; canonical text — not the source text — decides the break.
  (define source (format "(defn ~a [x: Int] -> Int x)\n" (make-string 60 #\f)))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (format "(defn ~a\n  [(x : Int)] -> Int x)\n" (make-string 60 #\f)))
  (check-equal? (length edits) 1))

(test-case "defmacro params have no typed-binding grammar, so they are never wrapped"
  ;; `[x: Any]` is three macro params, not one typed entry — wrapping it would
  ;; change the macro's arity.
  (define-values (actual edits)
    (formatted "(defmacro m [x: Any] `(do ~x))\n"))
  (check-equal? actual "(defmacro m [x: Any] `(do ~x))\n")
  (check-equal? edits '()))

(test-case "the legacy :- marker is left alone by the polarity rewrite"
  (define-values (actual edits)
    (formatted "(defn add [x :- Int y :- Int] :- Int (+ x y))\n"))
  (check-equal? actual "(defn add [x :- Int y :- Int] :- Int (+ x y))\n")
  (check-equal? edits '()))

(test-case "zero through two entries break when the complete signature exceeds 80"
  (define long-name (make-string 68 #\f))
  (define source (format "(defn ~a [] -> ExtremelyLongReturnType 0)\n" long-name))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (format "(defn ~a\n  [] -> ExtremelyLongReturnType 0)\n" long-name))
  (check-equal? (length edits) 1))

(test-case "the complete signature uses an inclusive 80-column boundary"
  (define at-width
    (format "(defn ~a [x y] -> Int x)\n" (make-string 61 #\f)))
  (define over-width
    (format "(defn ~a [x y] -> Int x)\n" (make-string 62 #\f)))
  (define-values (at-actual at-edits) (formatted at-width))
  (check-equal? at-actual at-width)
  (check-equal? at-edits '())
  (define-values (over-actual over-edits) (formatted over-width))
  (check-true (string-contains? over-actual "\n  [x\n   y] -> Int"))
  (check-equal? (length over-edits) 1))

(test-case "rest and destructuring forms are logical entries"
  (define-values (two-actual two-edits)
    (formatted "(defn collect\n  [x\n   & rest] x)\n"))
  (check-equal? two-actual "(defn collect [x & rest] x)\n")
  (check-equal? (length two-edits) 1)
  (define-values (three-actual three-edits)
    (formatted "(defn collect [x {:keys [y]} & rest] x)\n"))
  (check-equal?
   three-actual
   (string-append
    "(defn collect\n"
    "  [x\n"
    "   {:keys [y]}\n"
    "   & rest] x)\n"))
  (check-equal? (length three-edits) 1))

(test-case "function-style sites share the rule; ordinary vectors do not"
  (define source
    (string-append
     "(def data [x y z])\n"
     "(def f (fn\n        [x\n         y] (+ x y)))\n"
     "(defrecord Pair\n  [left: Int\n   right: Int])\n"
     "(defprotocol P (m\n                 [this\n                  x] -> Int))\n"
     "(defunion U (Pair\n               [left: Int\n                right: Int]))\n"))
  (define-values (actual edits) (formatted source))
  (check-true (string-contains? actual "(def data [x y z])"))
  (check-true (string-contains? actual "(fn [x y]"))
  (check-true (string-contains? actual "(defrecord Pair [(left : Int) (right : Int)])"))
  (check-true (string-contains? actual "(m [this x] -> Int)"))
  (check-true (string-contains? actual "(Pair [(left : Int) (right : Int)])"))
  (check-equal? (length edits) 4))

(test-case "line-comment reach makes a rewrite diagnostic-only"
  (define source
    "(defn f ; owner comment\n  [x ; first parameter\n   y] x)\n")
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

(test-case "check reports drift and write reaches an idempotent fixed point"
  (define source "(defn add\n  [x\n   y] (+ x y))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (file->string path) "(defn add [x y] (+ x y))\n")
     (check-equal? (format-signature-files 'check (list path)) 0))))

(test-case "one write converges nested signatures after outer column shifts"
  (define return-type (make-string 50 #\R))
  (define source
    (format "(defn outer [a b c] (fn [x y] -> ~a x))\n" return-type))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-true
      (string-contains? (file->string path)
                        (format "c] (fn [x y] -> ~a x)" return-type))))))
