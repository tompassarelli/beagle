#lang racket/base

;; Printer half: every beagle-source writer must emit ONLY the new syntax, glue
;; the marker to the preceding NAME with exactly one space after and none
;; before, and never break `NAME: TYPE` across a line.
;;
;; Four independent writers exist and each is covered here:
;;   datum->src / datum->pretty (facts-roundtrip — the canonical formatter)
;;   datum->beagle-src          (expand-tool — backs `bin/beagle expand`)
;;   write-beagle-form          (rewrite    — backs `bin/beagle-rewrite --apply`)
;;   query.rkt signature extraction (backs `bin/beagle sig` + lsp hover)

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

;; --- glue + spacing ---------------------------------------------------------

(define GLUE-BATTERY
  '("(def answer: Int 42)"
    "(defonce once: Int 1)"
    "(defn add [x: Int y: Int] -> Int (+ x y))"
    "(defn hof [cb: [Int -> String]] -> String (cb 1))"
    "(defrecord P [x: Int y: (Vec Int)])"
    "(let [v: Int e] v)"
    "(fn [b: Int] -> Int b)"
    "(defn m ([a: Int] -> Int a) ([a: Int b: Int] -> Int b))"))

(for ([s (in-list GLUE-BATTERY)])
  (test-case (format "datum->src is byte-identical for: ~a" s)
    (check-equal? (src s) s))
  (test-case (format "datum->beagle-src is byte-identical for: ~a" s)
    (check-equal? (datum->beagle-src (rd s)) s)))

(test-case "noncanonical input spacing is NORMALIZED to the canonical glue"
  (check-equal? (src "(a : Int)") "(a: Int)")
  (check-equal? (src "[a  :  Int]") "[a: Int]")
  (check-equal? (datum->beagle-src (rd "(a : Int)")) "(a: Int)"))

(test-case "legacy `:-` never appears in printed output for new-syntax input"
  (for ([s (in-list GLUE-BATTERY)])
    (check-false (string-contains? (src s) ":-") s)
    (check-false (string-contains? (pp s) ":-") s)))

(test-case "the reader-internal marker spelling never reaches output"
  (for ([s (in-list (cons "[: Int]" GLUE-BATTERY))])
    (check-false (string-contains? (src s) "#%:") s)
    (check-false (string-contains? (pp s) "#%:") s)
    (check-false (string-contains? (datum->beagle-src (rd s)) "#%:") s)))

;; --- round-trip: read -> print -> read is the identity ----------------------

(define ROUNDTRIP-BATTERY
  (append GLUE-BATTERY
          '("(defn ^:private q [a: Int] -> Int a)"
            "(def ^:dynamic *cfg*: Int 1)"
            "(defn r [a: Int & more: Int] -> Int a)"
            "(defn w [(a: Int)] -> Int a)"
            "(defn fr [xs: (Vec Int)] -> Nil (for [x: Int xs :let [y: Int x]] y))"
            "(defprotocol Area (area [self] -> Int))"
            "(letfn [(h [b: Int] -> Int b)] (h 1))"
            "(forall [(T <: String)] T)"
            "[: Int]"
            "{:k 1 :j 2}"
            "`[~name: ~type]"
            "(defn old [x :- Int] :- Int x)")))

(for ([s (in-list ROUNDTRIP-BATTERY)])
  (test-case (format "read->datum->src->read is the identity: ~a" s)
    (check-equal? (rd (src s)) (rd s)))
  (test-case (format "read->datum->pretty->read is the identity: ~a" s)
    (check-equal? (rd (pp s)) (rd s)))
  (test-case (format "read->write-beagle-form->read is the identity: ~a" s)
    (define out (with-output-to-string
                  (lambda () (write-beagle-source (list (rd s)) (current-output-port)))))
    (check-equal? (rd out) (rd s) out)))

;; --- canonical grammar layout ----------------------------------------------

(define CANONICAL-LAYOUT
  (list
   (cons "(defn add [x: Int y: Int] -> Int (+ x y))"
         "(defn add [x: Int y: Int] -> Int (+ x y))")
   (cons "(defn resty [x: Int & more: Int] -> Int x)"
         "(defn resty [x: Int & more: Int] -> Int x)")
   (cons "(fn [x: Int y: Int] -> Int (+ x y))"
         "(fn [x: Int y: Int] -> Int (+ x y))")
   (cons "(fn add [x: Int y: Int] -> Int (+ x y))"
         "(fn add [x: Int y: Int] -> Int (+ x y))")
   (cons "(defmacro pair [x y] `[~x ~y])"
         "(defmacro pair [x y] `[~x ~y])")
   (cons "(defn choose ([x] x) ([x y] y))"
         "(defn choose ([x] x) ([x y] y))")
   (cons "(defn choose [x] x [x y] y)"
         "(defn choose [x] x [x y] y)")
   (cons "(letfn [(sum [x: Int y: Int] -> Int (+ x y))] (sum 1 2))"
         "(letfn [(sum [x: Int y: Int] -> Int (+ x y))] (sum 1 2))")
   (cons "(defprotocol P (m [self x: Int] -> Int))"
         "(defprotocol P (m [self x: Int] -> Int))")
   (cons "(extend-type T P (m [self x: Int] -> Int x))"
         "(extend-type T P (m [self x: Int] -> Int x))")
   (cons "(defrecord P [x: Int y: String])"
         "(defrecord P [x: Int y: String])")
   (cons "(defunion Shape (Rect [width: Int height: Int]))"
         "(defunion Shape (Rect [width: Int height: Int]))")
   (cons "(defunion :throwable Failure (Bad [message: String path: String]))"
         "(defunion :throwable Failure (Bad [message: String path: String]))")))

(for ([example (in-list CANONICAL-LAYOUT)])
  (test-case (format "canonical grammar layout: ~a" (car example))
    (define out (pp (car example)))
    (check-equal? out (cdr example))
    (check-equal? (rd out) (rd (car example)))))

(test-case "zero through two grammar vectors stay inline when the signature fits"
  (check-equal? (pp "(defn zero [] -> Int 0)") "(defn zero [] -> Int 0)")
  (check-equal? (pp "(defn one [x: Int] -> Int x)") "(defn one [x: Int] -> Int x)")
  (check-equal? (pp "(defn two [x: Int y: Int] -> Int x)")
                "(defn two [x: Int y: Int] -> Int x)")
  (check-equal? (pp "(defrecord One [x: Int])") "(defrecord One [x: Int])"))

(test-case "three grammar entries force one logical entry per line"
  (check-equal? (pp "(defn f [a b c] a)")
                "(defn f\n  [a\n   b\n   c]\n  a)"))

(test-case "complete signature width is inclusive at 80 columns"
  (define prefix "(defn ")
  (define suffix " [x: Int y: Int] -> Int")
  (define name-80 (make-string (- 80 (string-length prefix) (string-length suffix)) #\x))
  (define signature-80 (string-append prefix name-80 suffix))
  (define out-80 (pp (string-append signature-80 " 0)")))
  (check-equal? (car (string-split out-80 "\n")) signature-80)
  (define name-81 (string-append name-80 "x"))
  (define out-81 (pp (string-append prefix name-81 suffix " 0)")))
  (check-equal? (car (string-split out-81 "\n")) (string-append prefix name-81))
  (check-true (string-prefix? (cadr (string-split out-81 "\n")) "  [x: Int")))

(test-case "over-width zero-parameter signature moves the vector as a unit"
  (define name (make-string 72 #\z))
  (define out (pp (format "(defn ~a [] -> Int 0)" name)))
  (check-equal? (car (string-split out "\n")) (format "(defn ~a" name))
  (check-true (string-prefix? (cadr (string-split out "\n")) "  [] -> Int")))

(test-case "ordinary data and let binding vectors keep generic pretty-printing"
  (check-equal? (pp "[a b]") "[a b]")
  (check-equal? (pp "(f [a b])") "(f [a b])")
  (check-equal? (pp "(let [a 1 b 2] (+ a b))") "(let [a 1 b 2] (+ a b))"))

;; --- the 80-column breaker must never split an annotation -------------------

(define WIDE
  "[alpha: Int beta: String gamma: (Vec Int) delta: Bool epsilon: Keyword zeta: Float]")

(test-case "a generic vector wide enough to break keeps each `NAME: TYPE` intact"
  (define out (pp WIDE))
  (check-true (> (length (string-split out "\n")) 1) "expected the vector to break")
  (for ([line (in-list (string-split out "\n"))])
    ;; a line ending in `:` would be a split annotation
    (check-false (regexp-match? #rx":[ ]*$" line) line))
  (check-true (string-contains? out "alpha: Int"))
  (check-true (string-contains? out "zeta: Float"))
  (check-equal? (rd out) (rd WIDE)))

(test-case "a grammar-broken defn keeps `-> RET` after the final parameter"
  (define out (pp (string-append
                   "(defn wide [alpha: Int beta: String gamma: (Vec Int)] -> (Map Keyword Int)"
                   " (do-something alpha beta gamma) (another-thing alpha beta gamma))")))
  (check-true (string-contains? (list-ref (string-split out "\n") 3)
                                "gamma: (Vec Int)] -> (Map Keyword Int)") out))

(test-case "datum->pretty is idempotent at the fixed point"
  (for ([s (in-list (cons WIDE ROUNDTRIP-BATTERY))])
    (check-equal? (datum->pretty (rd (pp s))) (pp s) s)))

;; --- symbols the colon reader would otherwise split -------------------------

(test-case "a symbol whose text contains an interior `:` round-trips via bars"
  (for ([s (in-list '("|a:b|" "|:|" "(f |x:| |:y|)"))])
    (check-equal? (rd (src s)) (rd s) (src s))))

(test-case "keywords stay bare — bar-quoting them would be a regression"
  (check-equal? (src "(f :kw ::kw :a/b :-)") "(f :kw ::kw :a/b :-)"))

;; --- query.rkt: `bin/beagle sig` must see the new syntax ---------------------

(test-case "query-sig reports a real signature for a new-syntax defn"
  (define tmp (make-temporary-file "sig-~a.bclj"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file tmp
       (lambda (o) (display (string-append
                             "#lang beagle/clj\n(ns t)\n"
                             "(defn add\n  [x: Int\n   y: Int] -> String\n  \"s\")\n"
                             "(def answer: Int 42)\n") o))
       #:exists 'truncate/replace)
     (define out (with-output-to-string
                   (lambda () (query-sig "add" (list (path->string tmp))))))
     (check-true (string-contains? out "Int") out)
     (check-false (string-contains? out "-> Any")
                  "a typed defn must not silently degrade to `-> Any`"))
   (lambda () (delete-file tmp))))
