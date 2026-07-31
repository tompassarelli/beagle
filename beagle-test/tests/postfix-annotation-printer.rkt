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

;; --- the 80-column breaker must never split an annotation -------------------

(define WIDE
  "[alpha: Int beta: String gamma: (Vec Int) delta: Bool epsilon: Keyword zeta: Float]")

(test-case "a param vector wide enough to break keeps each `NAME: TYPE` intact"
  (define out (pp WIDE))
  (check-true (> (length (string-split out "\n")) 1) "expected the vector to break")
  (for ([line (in-list (string-split out "\n"))])
    ;; a line ending in `:` would be a split annotation
    (check-false (regexp-match? #rx":[ ]*$" line) line))
  (check-true (string-contains? out "alpha: Int"))
  (check-true (string-contains? out "zeta: Float"))
  (check-equal? (rd out) (rd WIDE)))

(test-case "a wide defn signature keeps `-> RET` on the head line"
  (define out (pp (string-append
                   "(defn wide [alpha: Int beta: String gamma: (Vec Int)] -> (Map Keyword Int)"
                   " (do-something alpha beta gamma) (another-thing alpha beta gamma))")))
  (check-true (string-contains? (car (string-split out "\n")) "-> (Map Keyword Int)") out))

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
                             "(defn add [x: Int y: Int] -> String \"s\")\n"
                             "(def answer: Int 42)\n") o))
       #:exists 'truncate/replace)
     (define out (with-output-to-string
                   (lambda () (query-sig "add" (list (path->string tmp))))))
     (check-true (string-contains? out "Int") out)
     (check-false (string-contains? out "-> Any")
                  "a typed defn must not silently degrade to `-> Any`"))
   (lambda () (delete-file tmp))))
