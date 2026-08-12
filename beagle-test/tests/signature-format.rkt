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
     "(defn add [(x Int) (y Int)] Int (+ x y))\n"
     "(defn clamp [(value Int) (minimum Int) (maximum Int)] Int value)\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "an over-width signature puts one binding form on each line"
  (define name (make-string 52 #\f))
  (define source
    (format "(defn ~a [(value Int) (minimum Int) (maximum Int)] Int value)\n" name))
  (define-values (actual edits) (formatted source))
  (check-equal?
   actual
   (string-append
    (format "(defn ~a\n" name)
    "  [(value Int)\n"
    "   (minimum Int)\n"
    "   (maximum Int)] Int value)\n"))
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
                        (format "y] ~a x)" return-type)))
     (check-true (string-contains? (file->string path) "(fn\n")))))
