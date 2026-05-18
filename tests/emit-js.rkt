#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         racket/match
         "../private/parse.rkt"
         "../private/check.rkt"
         "../private/emit.rkt"
         "../private/types.rkt")

(define (br . xs) (cons BRACKET-TAG xs))
(define (mt . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

(define (js-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.rkt"))
  (type-check! prog)
  (emit-program prog))

(define-syntax-rule (check-js name expected-rx form ...)
  (test-case name
    (define result (js-emit (list '(ns test.app) '(define-mode strict) '(define-target js) form ...)))
    (check-regexp-match expected-rx result)))

(define-syntax-rule (check-js-contains name expected-str form ...)
  (test-case name
    (define result (js-emit (list '(ns test.app) '(define-mode strict) '(define-target js) form ...)))
    (check-true (string-contains? result expected-str)
                (format "expected ~v in:\n~a" expected-str result))))

(run-tests
 (test-suite "JS emitter"

   (check-js-contains "def → const"
     "const x = 42;"
     '(def x : Int 42))

   (check-js-contains "def string → const"
     "const greeting = \"hello\";"
     '(def greeting : String "hello"))

   (check-js-contains "defn → function"
     "function add(x, y)"
     '(defn add [(x : Int) (y : Int)] : Int (+ x y)))

   (check-js-contains "defn body returns"
     "return (x + y);"
     '(defn add [(x : Int) (y : Int)] : Int (+ x y)))

   (check-js-contains "fn → arrow function"
     "=>"
     '(def f : Any (fn [(x : Int)] : Int (+ x 1))))

   (check-js-contains "defrecord → factory with _tag"
     "_tag: \"Point\""
     '(defrecord Point [(x : Int) (y : Int)]))

   (check-js-contains "defrecord → Object.freeze"
     "Object.freeze"
     '(defrecord Point [(x : Int) (y : Int)]))

   (check-js-contains "defrecord → accessor functions"
     "function point_x(r)"
     '(defrecord Point [(x : Int) (y : Int)]))

   (check-js-contains "constructor → factory call"
     "Point(1, 2)"
     '(defrecord Point [(x : Int) (y : Int)])
     '(def p : Point (->Point 1 2)))

   (check-js-contains "kw-access → dot access"
     "p.x"
     '(defrecord Point [(x : Int) (y : Int)])
     '(def p : Point (->Point 1 2))
     '(def v : Int (:x p)))

   (check-js-contains "with → freeze spread"
     "Object.freeze({...p"
     '(defrecord Point [(x : Int) (y : Int)])
     '(def p : Point (->Point 1 2))
     `(def q : Point (with p ,(br ':x 10))))

   (check-js-contains "if → ternary"
     "?"
     '(defn f [(x : Bool)] : Int (if x 1 0)))

   (check-js-contains "let → IIFE"
     "(() =>"
     '(defn f [] : Int (let [x 1] (+ x 1))))

   (check-js-contains "str → concat"
     "concat"
     '(defn f [(x : String)] : String (str "hello " x)))

   (check-js-contains "println → console.log"
     "console.log"
     '(defn f [] : Nil (println "hi")))

   (check-js-contains "nil → null"
     "null"
     '(def x : Nil nil))

   (check-js-contains "nil? → == null"
     "== null"
     '(defn f [(x : Any)] : Bool (nil? x)))

   (check-js-contains "for → map"
     ".map("
     '(defn f [(xs : (Vec Int))] : (Vec Int)
       (for [x xs] (+ x 1))))

   (check-js-contains "for with :when → filter + map"
     ".filter("
     '(defn f [(xs : (Vec Int))] : (Vec Int)
       (for [x xs :when (> x 0)] x)))

   (check-js-contains "cond → chained ternary"
     "? \"neg\" :"
     '(defn f [(x : Int)] : String
       (cond (< x 0) "neg" (= x 0) "zero" :else "pos")))

   (check-js-contains "match record → _tag check"
     "_tag ==="
     '(defrecord Circle [(radius : Int)])
     '(defrecord Rect [(w : Int) (h : Int)])
     `(defn area [(shape : Any)] : Int
       (match shape
         ,(br '(Circle r) '(* r r))
         ,(br '(Rect w h) '(* w h)))))

   (check-js-contains "vec literal → array"
     "[1, 2, 3]"
     `(def xs : (Vec Int) ,(br 1 2 3)))

   (check-js-contains "map literal → object"
     "a: 1"
     `(def m : Any ,(mt ':a 1 ':b 2)))

   (check-js-contains "set literal → new Set"
     "new Set(["
     `(def s : Any ,(st 1 2 3)))

   (check-js-contains "module header with import"
     "import * as"
     '(require inventory :as inv)
     '(def x : Int (inv/count-items)))

   (check-js-contains "kebab → underscore mangling"
     "my_func"
     '(defn my-func [] : Int 42))

   (check-js-contains "predicate → _p mangling"
     "valid_p"
     '(defn valid? [(x : Int)] : Bool (> x 0)))

   (check-js-contains "defenum → Set"
     "new Set(["
     '(defenum Color :red :green :blue))

   (check-js-contains "inc → + 1"
     "(x + 1)"
     '(defn f [(x : Int)] : Int (inc x)))

   (check-js-contains "count → .length"
     ".length"
     '(defn f [(xs : (Vec Int))] : Int (count xs)))

   (check-js-contains "first → [0]"
     "[0]"
     '(defn f [(xs : (Vec Int))] : Int (first xs)))

   (check-js-contains "await → await keyword"
     "await"
     `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
     '(defn f [(url : String)] : (Promise String) (await (fetch-data url))))

   (check-js-contains "defn with await → async function"
     "async function"
     `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
     '(defn f [(url : String)] : (Promise String) (await (fetch-data url))))

   (check-js-contains "fn with await → async arrow"
     "async ("
     `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
     '(def f : Any (fn [(url : String)] : (Promise String) (await (fetch-data url)))))

   (check-js-contains "defn without await → no async"
     "function g("
     '(defn g [(x : Int)] : Int (+ x 1)))

   ;; --- control flow ---------------------------------------------------------

   (check-js-contains "loop/recur → while"
     "while (true)"
     '(defn countdown [(n : Int)] : Int
       (loop [i n]
         (if (= i 0) i (recur (- i 1))))))

   (check-js-contains "recur → reassign + continue"
     "continue"
     '(defn countdown [(n : Int)] : Int
       (loop [i n]
         (if (= i 0) i (recur (- i 1))))))

   (check-js-contains "try/catch → try block"
     "try {"
     '(defn safe [(x : Int)] : Int
       (try x (catch Exception e 0))))

   (check-js-contains "do → IIFE"
     "(() =>"
     '(defn f [] : Nil (do (println "a") (println "b"))))

   (check-js-contains "when → IIFE with if"
     "if ("
     '(defn f [(x : Bool)] : Nil (when x (println "yes"))))

   (check-js-contains "case → chained equality"
     "=== 1"
     '(defn f [(x : Int)] : String
       (case x 1 "one" 2 "two" "other")))

   ;; --- iteration ------------------------------------------------------------

   (check-js-contains "doseq → forEach"
     ".forEach("
     '(defn f [(xs : (Vec Int))] : Nil (doseq [x xs] (println x))))

   (check-js-contains "dotimes → for loop"
     "for (let"
     '(defn f [(n : Int)] : Nil (dotimes [i n] (println i))))

   ;; --- interop --------------------------------------------------------------

   (check-js-contains ".method → dot call"
     ".toString("
     '(defn f [(x : Any)] : String (.toString x)))

   (check-js-contains "Class/method → dot call"
     "Math.abs("
     '(defn f [(x : Int)] : Int (Math/abs x)))

   (check-js-contains "new → new keyword"
     "new Date("
     '(def d : Any (Date. 2024)))

   ;; --- multi-arity ----------------------------------------------------------

   (check-js-contains "multi-arity → arguments.length dispatch"
     "arguments.length"
     `(defn greet
       (,(br '(name : String)) : String (str "Hello " name))
       (,(br '(first : String) '(last : String)) : String (str "Hello " first " " last))))

   ;; --- binding forms --------------------------------------------------------

   (check-js-contains "when-let → null check IIFE"
     "!= null"
     '(defn f [(x : Any)] : Nil (when-let [v x] (println v))))

   (check-js-contains "if-let → null check with else"
     "else"
     '(defn f [(x : Any)] : String (if-let [v x] "found" "missing")))

   ;; --- edge cases (CLJS-inspired) --------------------------------------------

   (check-js-contains "munge: hyphen and underscore produce distinct names"
     "my__var"
     '(def my_var : Int 1))

   (check-js-contains "munge: hyphen-name does not collide with underscore"
     "my_func"
     '(defn my-func [] : Int 42))

   (check-js-contains "string with embedded quotes"
     "\"he said \\\"hi\\\"\""
     '(def s : String "he said \"hi\""))

   (check-js-contains "boolean true → true"
     "true"
     '(def x : Bool true))

   (check-js-contains "boolean false → false"
     "false"
     '(def x : Bool false))

   (check-js-contains "nested let → nested IIFE"
     "const y"
     '(defn f [] : Int (let [x 1] (let [y 2] (+ x y)))))

   (check-js-contains "await in nested let propagates async"
     "async"
     `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
     '(defn f [(url : String)] : (Promise String)
       (let [x "prefix"]
         (let [result (await (fetch-data url))]
           (str x result)))))

   (check-js-contains "multi-arity with await → async dispatch"
     "async function"
     `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
     `(defn load
       (,(br '(url : String)) : (Promise String) (await (fetch-data url)))
       (,(br '(url : String) '(fallback : String)) : (Promise String)
         (let [r (await (fetch-data url))] (if (nil? r) fallback r)))))

   (check-js-contains "record field access chains"
     ".x"
     '(defrecord Point [(x : Int) (y : Int)])
     '(defrecord Line [(start : Point) (end : Point)])
     '(defn start-x [(l : Line)] : Int (:x (:start l))))

   (check-js-contains "empty string is a valid value"
     "const s = \"\";"
     '(def s : String ""))

   (check-js-contains "zero is a valid numeric value"
     "const z = 0;"
     '(def z : Int 0))

   (check-js-contains "negative number"
     "const n = -42;"
     '(def n : Int -42))

   (check-js-contains "double literal preserves decimal"
     "3.14"
     '(def pi : Float 3.14))

   (check-js-contains "keyword literal → string"
     "\"foo\""
     '(def k : Keyword :foo))

   (check-js-contains "for nested in let"
     ".map("
     '(defn f [(xs : (Vec Int))] : (Vec Int)
       (let [offset 10]
         (for [x xs] (+ x offset)))))

   (check-js-contains "cond with multiple branches → chained ternary"
     "? \"negative\" :"
     '(defn classify [(n : Int)] : String
       (cond (< n 0) "negative" (= n 0) "zero" :else "positive")))
 ))
