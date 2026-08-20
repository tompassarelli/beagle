#lang racket/base

(require rackunit
         racket/file
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

(test-case "single flat unrefined pair is already canonical"
  (define source "(defn greet [name String] String name)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "legacy grouped pair canonicalizes inline"
  (define-values (actual edits)
    (formatted "(defn greet [(name String)] String name)\n"))
  (check-equal? actual "(defn greet [name String] String name)\n")
  (check-equal? (length edits) 1))

(test-case "pair count alone expands a defn signature"
  (define-values (actual edits)
    (formatted "(defn add [x Int y Int] Int (+ x y))\n"))
  (check-equal?
   actual
   (string-append
    "(defn add\n"
    "  [x Int\n"
    "   y Int] Int\n"
    "  (+ x y))\n"))
  (check-equal? (length edits) 1))

(test-case "single refinement stays inline"
  (define source
    "(defn positive [x (Int where (> _ 0))] Int x)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "legacy constraints refuse command-wide writes"
  (define blocked "(defn positive [(x Int positive?)] Int x)\n")
  (define rewritable "(defn add [(x Int) (y Int)] Int (+ x y))\n")
  (with-source
   blocked
   (lambda (blocked-path)
     (with-source
      rewritable
      (lambda (rewritable-path)
        (define edits (signature-layout-edits blocked-path))
        (check-equal? (length edits) 1)
        (check-equal? (layout-edit-refusal (car edits))
                      'refinement-not-implemented)
        (check-equal?
         (format-signature-files 'check (list blocked-path rewritable-path)) 3)
        (check-equal?
         (format-signature-files 'write (list blocked-path rewritable-path)) 2)
        (check-equal? (file->string blocked-path) blocked)
        (check-equal? (file->string rewritable-path) rewritable))))))

(test-case "signature where clause remains after its return line"
  (define-values (actual edits)
    (formatted
     "(defn bounded [lo Int hi Int] Bool (where (<= lo hi)) true)\n"))
  (check-equal?
   actual
   (string-append
    "(defn bounded\n"
    "  [lo Int\n"
    "   hi Int] Bool\n"
    "  (where (<= lo hi))\n"
    "  true)\n"))
  (check-equal? (length edits) 1))

(test-case "variadic marker and pair stay one logical row"
  (define-values (actual edits)
    (formatted
     "(defn collect [(first Int) & (more (Vec Int))] Int first)\n"))
  (check-equal?
   actual
   (string-append
    "(defn collect\n"
    "  [first Int\n"
    "   & more (Vec Int)] Int\n"
    "  first)\n"))
  (check-equal? (length edits) 1))

(test-case "fn keeps its return after the expanded vector"
  (define-values (actual edits)
    (formatted "(fn [x Int y Int] Int (+ x y))\n"))
  (check-equal?
   actual
   (string-append
    "(fn\n"
    "  [x Int\n"
    "   y Int] Int\n"
    "  (+ x y))\n"))
  (check-equal? (length edits) 1))

(test-case "defrecord shares the pair break law"
  (define-values (actual edits)
    (formatted "(defrecord Point [(x Float) (y Float)])\n"))
  (check-equal?
   actual
   (string-append
    "(defrecord Point\n"
    "  [x Float\n"
    "   y Float])\n"))
  (check-equal? (length edits) 1))

(test-case "one local binding triple stays inline"
  (define source "(let [x Int 1] x)\n")
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "let and loop break one complete triple per line"
  (for ([source+expected
         (in-list
          (list
           (cons "(let [x Int 1 y Int 2] (+ x y))\n"
                 (string-append
                  "(let [x Int 1\n"
                  "      y Int 2]\n"
                  "  (+ x y))\n"))
           (cons "(loop [x Int 1 y Int 2] (+ x y))\n"
                 (string-append
                  "(loop [x Int 1\n"
                  "       y Int 2]\n"
                  "  (+ x y))\n"))))])
    (define-values (actual edits) (formatted (car source+expected)))
    (check-equal? actual (cdr source+expected))
    (check-equal? (length edits) 1)))

(test-case "nested binding rewrites converge without overlapping edits"
  (define source
    (string-append
     "(let [f (Fn [Int Int] Int) (fn [x Int y Int] Int (+ x y)) "
     "z Int 2] (f z z))\n"))
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [f (Fn [Int Int] Int) (fn\n"
       "                             [x Int\n"
       "                              y Int] Int\n"
       "                             (+ x y))\n"
       "      z Int 2]\n"
       "  (f z z))\n")))))

(test-case "legacy local pairs preserve nested initializer layout"
  (define source
    "(let [f (fn [x Int y Int] Int (+ x y)) z 2] (f z z))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(let [f (fn\n"
       "          [x Int\n"
       "           y Int] Int\n"
       "          (+ x y))\n"
       "      z 2]\n"
       "  (f z z))\n")))))

(test-case "width never changes a single-pair signature"
  (define name (make-string 120 #\f))
  (define source (format "(defn ~a [x Int] Int x)\n" name))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "ordinary and macro vectors are not typed-signature rewrites"
  (define source
    (string-append
     "(def data [x y z])\n"
     "(defmacro pair [x y] `[~x ~y])\n"))
  (define-values (actual edits) (formatted source))
  (check-equal? actual source)
  (check-equal? edits '()))

(test-case "line-comment reach makes a rewrite diagnostic-only"
  (define source
    "(defn f ; owner comment\n  [x Int y Int] Int x)\n")
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

(test-case "one write reaches the canonical fixed point"
  (define source "(defn add [(x Int) (y Int)] Int (+ x y))\n")
  (with-source
   source
   (lambda (path)
     (check-equal? (format-signature-files 'check (list path)) 3)
     (check-equal? (format-signature-files 'write (list path)) 0)
     (check-equal? (format-signature-files 'check (list path)) 0)
     (check-equal?
      (file->string path)
      (string-append
       "(defn add\n"
       "  [x Int\n"
       "   y Int] Int\n"
       "  (+ x y))\n")))))
