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
    "(defn hof [(cb [Int -> String])] String (cb 1))"
    "(defrecord P [(x Int) (y (Vec Int))])"
    "(let [(v Int) e] v)"
    "(fn [(b Int)] Int b)"
    "(defn m ([(a Int)] Int a) ([(a Int) (b Int)] Int b))"))

(for ([s (in-list STRUCTURAL-BATTERY)])
  (test-case (format "datum->src is byte-identical for: ~a" s)
    (check-equal? (src s) s))
  (test-case (format "datum->beagle-src is byte-identical for: ~a" s)
    (check-equal? (datum->beagle-src (rd s)) s)))

(test-case "function-type arrows remain data inside types"
  (check-equal? (src "(defn hof [(cb [Int -> String])] String (cb 1))")
                "(defn hof [(cb [Int -> String])] String (cb 1))"))

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
  (check-true (string-prefix? (cadr (string-split out-81 "\n")) "  [(x Int)")))

(test-case "over-width signatures put one binding form on each line"
  (define name (make-string 58 #\z))
  (define out
    (pp (format "(defn ~a [(alpha Int) (beta String)] Int alpha)" name)))
  (define lines (string-split out "\n"))
  (check-equal? (car lines) (format "(defn ~a" name))
  (check-true (string-prefix? (cadr lines) "  [(alpha Int)"))
  (check-true (string-prefix? (caddr lines) "   (beta String)] Int")))

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
