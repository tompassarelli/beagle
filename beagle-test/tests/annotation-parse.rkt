#lang racket/base

;; Structural typed bindings and fixed positional return slots.

(require rackunit
         racket/string
         beagle/lang/reader-impl
         beagle/private/parse
         beagle/private/check
         beagle/private/types
         beagle/private/ast)

(define PRELUDE "(ns t)\n(define-mode strict)\n(define-target clj)\n")

(define (read-forms str)
  (parameterize ([current-readtable beagle-readtable])
    (define in (open-input-string str))
    (let loop ()
      (define stx (read-syntax 'annotation-test in))
      (if (eof-object? stx) '() (cons stx (loop))))))

(define (parse-src str)
  (parse-program (read-forms (string-append PRELUDE str))))

(define (check-src str)
  (parameterize ([current-check-profile 2])
    (type-check! (parse-src str))))

(define-syntax-rule (ok name src)
  (test-case name (check-not-exn (lambda () (check-src src)))))

(define-syntax-rule (err/rx name rx src)
  (test-case name (check-exn rx (lambda () (parse-src src)))))

;; Every binding-bearing surface uses `(name Type)` as one structural datum.
(ok "def"                     "(def answer Int 42)")
(ok "def + docstring"         "(def answer Int \"doc\" 42)")
(ok "untyped def"             "(def answer 42)")
(ok "defonce"                 "(defonce once Int 1)")
(ok "dynamic def"             "(def ^:dynamic *cfg* Int 1)")
(ok "typed, bare, and mixed params"
    "(defn f [(x Int) y (z String)] Int x)")
(ok "typed rest param"        "(defn r [(x Int) & (more (Vec Int))] Int x)")
(ok "bare rest param"         "(defn r [x & more] Any more)")
(ok "function type param"     "(defn hof [(cb [Int -> String])] String (cb 1))")
(ok "let and loop bindings"
    "(defn f [(x Int)] Int (let [(y Int) x z y] (loop [(n Int) z] n)))")
(ok "conditional binding"     "(defn f [(x Int)] Int (if-let [(y Int) x] y 0))")
(ok "for and nested :let"
    "(defn f [(xs (Vec Int))] (Vec Int) (for [(x Int) xs :let [(y Int) x]] y))")
(ok "doseq binding"
    "(defn f [(xs (Vec Int))] Nil (doseq [(x Int) xs] (println x)))")
(ok "record fields"           "(defrecord Point [(x Int) (y Int)])")
(ok "union and error fields"
    "(defunion Shape (Circle [(radius Int)]))\n(defunion :throwable Boom (Boom [(message String)]))")
(ok "catch binding"
    "(defn f [] Int (try 1 (catch (e Exception) 0)))")

;; Every executable/declaration signature has a mandatory positional return.
(ok "defn return"             "(defn f [(x Int)] Int x)")
(ok "defn raises"
    "(defunion :throwable Boom (Boom [(message String)]))\n(defn f [] Int :raises Boom 1)")
(ok "private defn"            "(defn- f [(x Int)] Int x)")
(ok "anonymous fn"            "(defn f [(x Int)] Int ((fn [(y Int)] Int y) x))")
(ok "letfn"                   "(defn f [(x Int)] Int (letfn [(g [(y Int)] Int y)] (g x)))")
(ok "multi-arity"
    "(defn f ([(x Int)] Int x) ([(x Int) (y Int)] Int (+ x y)))")
(ok "protocol and implementation"
    (string-append
     "(defrecord Box [(value Int)])\n"
     "(defprotocol Value (value-of [(self Value)] Int))\n"
     "(extend-type Box Value (value-of [(self Box)] Int (:value self)))"))

(test-case "types populate AST slots"
  (define program
    (parse-src
     "(def answer Int 42)\n(defn add [(x Int) y] String (let [(n Int) x] \"s\"))"))
  (define forms (program-forms program))
  (check-eq? (type-prim-name (def-form-type (car forms))) 'Int)
  (define function (cadr forms))
  (check-eq? (type-prim-name (param-type (car (defn-form-params function)))) 'Int)
  (check-false (param-type (cadr (defn-form-params function))))
  (check-eq? (type-prim-name (defn-form-return-type function)) 'String)
  (define binding (car (let-form-bindings (car (defn-form-body function)))))
  (check-eq? (type-prim-name (let-binding-type binding)) 'Int))

;; There is no compatibility parser for either retired punctuation form.
(err/rx "flat colon binding rejected"
        #rx"punctuation annotations are not supported"
        "(defn f [x: Int] Int x)")
(err/rx "legacy binding rejected"
        #rx"punctuation annotations are not supported"
        "(defn f [x :- Int] Int x)")
(err/rx "return arrow rejected"
        #rx"return arrows are not supported"
        "(defn f [(x Int)] -> Int x)")
(err/rx "legacy return marker rejected"
        #rx"return arrows are not supported"
        "(defn f [(x Int)] :- Int x)")
(err/rx "colon inside structural binding rejected"
        #rx"punctuation annotations are not supported"
        "(defn f [(x : Int)] Int x)")

;; The slot is fixed; the parser never guesses whether a type-shaped symbol is
;; a body expression.
(err/rx "defn missing return slot"
        #rx"expected.*ReturnType"
        "(defn f [] 1)")
(err/rx "defn return without body"
        #rx"expected.*ReturnType"
        "(defn f [] Int)")
(err/rx "fn return without body"
        #rx"fn needs a return type and body"
        "(def f (fn [] Int))")
(err/rx "multi-arity return without body"
        #rx"needs a return type and body"
        "(defn f ([] Int))")
(err/rx "protocol missing return"
        #rx"must be.*ReturnType"
        "(defprotocol P (f [self]))")

(test-case "type-level and Clojure arrows remain separate surfaces"
  (check-not-exn
   (lambda ()
     (check-src
      "(defn f [(cb [Int -> Int]) (x Int)] Int (-> x cb))"))))
