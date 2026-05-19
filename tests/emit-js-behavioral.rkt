#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         racket/system
         racket/port
         racket/format
         racket/file
         racket/runtime-path
         "../private/parse.rkt"
         "../private/check.rkt"
         "../private/emit.rkt"
         "../private/types.rkt")

(define (br . xs) (cons BRACKET-TAG xs))
(define (mt . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

(define BUN-PATH
  (or (find-executable-path "bun")
      (let ([nix-bun (for/or ([p (in-list (directory-list (string->path "/nix/store")))])
                       (define candidate (build-path "/nix/store" p "bin" "bun"))
                       (and (file-exists? candidate) candidate))])
        nix-bun)
      (begin
        (displayln "SKIP: bun not found, skipping behavioral JS tests")
        #f)))

(define (js-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.rkt"))
  (type-check! prog)
  (emit-program prog))

;; Compile beagle forms to JS, append assertion code, run with bun.
;; assertions-js is raw JS appended after the emitted program.
(define-runtime-path BEAGLE-CORE-JS-PATH "../lib/beagle/core.js")
(define BEAGLE-CORE-JS (path->string BEAGLE-CORE-JS-PATH))

(define (run-js-test beagle-forms assertions-js)
  (define raw-js
    (js-emit (append (list '(ns test.app) '(define-mode strict) '(define-target js))
                     beagle-forms)))
  (define js-code
    (string-append
     (string-replace raw-js "from 'beagle/core.js'" (format "from '~a'" BEAGLE-CORE-JS))
     "\n\n// --- assertions ---\n"
     assertions-js
     "\n"))
  (define tmp (make-temporary-file "beagle-test-~a.js"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out) (display js-code out)))
      (define-values (proc stdout stdin stderr)
        (subprocess #f #f #f BUN-PATH (path->string tmp)))
      (close-output-port stdin)
      (define out-str (port->string stdout))
      (define err-str (port->string stderr))
      (subprocess-wait proc)
      (define code (subprocess-status proc))
      (close-input-port stdout)
      (close-input-port stderr)
      (values code out-str err-str js-code))
    (lambda ()
      (when (file-exists? tmp) (delete-file tmp)))))

(define-syntax-rule (check-js-behavior name forms assertions-js)
  (test-case name
    (define-values (code out err js) (run-js-test forms assertions-js))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- js ---\n~a" code err js))))

(define-syntax-rule (check-js-output name forms assertions-js expected-out)
  (test-case name
    (define-values (code out err js) (run-js-test forms assertions-js))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- js ---\n~a" code err js))
    (check-equal? (string-trim out) expected-out
                  (format "wrong output\n--- js ---\n~a" js))))

(when BUN-PATH
(run-tests
 (test-suite "JS behavioral"

   ;; --- basic arithmetic & values -------------------------------------------

   (check-js-output "def + defn round-trip"
     (list '(def x : Int 42)
           '(defn double [(n : Int)] : Int (* n 2))
           '(defn main [] : Nil (println (double x))))
     "main();"
     "84")

   (check-js-output "string concatenation"
     (list '(defn greet [(name : String)] : String (str "Hello, " name "!"))
           '(defn main [] : Nil (println (greet "world"))))
     "main();"
     "Hello, world!")

   (check-js-output "boolean logic"
     (list '(defn both [(a : Bool) (b : Bool)] : Bool (and a b))
           '(defn main [] : Nil
              (do (println (both true true))
                  (println (both true false)))))
     "main();"
     "true\nfalse")

   ;; --- records -------------------------------------------------------------

   (check-js-output "record construction and field access"
     (list '(defrecord Point [(x : Int) (y : Int)])
           '(defn main [] : Nil
              (let [p (->Point 3 4)]
                (do (println (point-x p))
                    (println (point-y p))))))
     "main();"
     "3\n4")

   (check-js-output "record with → Object.freeze is immutable"
     (list '(defrecord Point [(x : Int) (y : Int)])
           `(defn main [] : Nil
              (let [p (->Point 1 2)
                    q (with p ,(br ':x 10))]
                (do (println (point-x p))
                    (println (point-x q))))))
     "main();"
     "1\n10")

   (check-js-behavior "record is frozen (mutation throws in strict mode)"
     (list '(defrecord Point [(x : Int) (y : Int)]))
     "
'use strict';
const p = Point(1, 2);
let threw = false;
try { p.x = 99; } catch(e) { threw = true; }
console.assert(threw, 'frozen record should reject mutation');
")

   (check-js-output "record _tag for pattern dispatch"
     (list '(defrecord Circle [(radius : Int)])
           '(defrecord Rect [(w : Int) (h : Int)])
           `(defn area [(shape : Any)] : Int
              (match shape
                ,(br '(Circle r) '(* r r))
                ,(br '(Rect w h) '(* w h)))))
     "console.log(area(Circle(5))); console.log(area(Rect(3, 4)));"
     "25\n12")

   ;; --- nil / null ----------------------------------------------------------

   (check-js-output "nil maps to null"
     (list '(def x : Nil nil)
           '(defn main [] : Nil (println (nil? x))))
     "main();"
     "true")

   (check-js-output "nil? on non-nil returns false"
     (list '(defn main [] : Nil (println (nil? "hello"))))
     "main();"
     "false")

   ;; --- truthiness (CLJS-inspired) ------------------------------------------

   (check-js-output "if with 0 — JS falsy"
     (list '(defn f [(x : Int)] : String (if x "truthy" "falsy")))
     "console.log(f(0));"
     "falsy")

   (check-js-output "if with empty string — JS falsy"
     (list '(defn f [(x : String)] : String (if x "truthy" "falsy")))
     "console.log(f(\"\"));"
     "falsy")

   (check-js-output "if with null — falsy"
     (list '(defn f [(x : Any)] : String (if x "truthy" "falsy")))
     "console.log(f(null));"
     "falsy")

   (check-js-output "if with false — falsy"
     (list '(defn f [(x : Bool)] : String (if x "truthy" "falsy")))
     "console.log(f(false));"
     "falsy")

   (check-js-output "if with non-zero — truthy"
     (list '(defn f [(x : Int)] : String (if x "truthy" "falsy")))
     "console.log(f(1));"
     "truthy")

   ;; --- let / IIFE ----------------------------------------------------------

   (check-js-output "let binds correctly"
     (list '(defn f [] : Int (let [x 10 y 20] (+ x y))))
     "console.log(f());"
     "30")

   (check-js-output "nested let scoping"
     (list '(defn f [] : Int
              (let [x 1]
                (let [x 2]
                  x))))
     "console.log(f());"
     "2")

   (check-js-output "let does not leak into outer scope"
     (list '(defn f [] : Int
              (let [x 1]
                (+ (let [y 10] y) x))))
     "console.log(f());"
     "11")

   ;; --- loop/recur ----------------------------------------------------------

   (check-js-output "loop/recur basic countdown"
     (list '(defn countdown [(n : Int)] : Int
              (loop [i n]
                (if (= i 0) i (recur (- i 1))))))
     "console.log(countdown(10));"
     "0")

   (check-js-output "loop/recur accumulator"
     (list '(defn sum-to [(n : Int)] : Int
              (loop [i n acc 0]
                (if (= i 0) acc (recur (- i 1) (+ acc i))))))
     "console.log(sum_to(5));"
     "15")

   ;; --- for / map / filter --------------------------------------------------

   (check-js-output "for → map"
     (list '(defn double-all [(xs : (Vec Int))] : (Vec Int)
              (for [x xs] (* x 2))))
     "console.log(JSON.stringify(double_all([1,2,3])));"
     "[2,4,6]")

   (check-js-output "for with :when → filter + map"
     (list '(defn positives [(xs : (Vec Int))] : (Vec Int)
              (for [x xs :when (> x 0)] x)))
     "console.log(JSON.stringify(positives([-1, 0, 1, 2, -3])));"
     "[1,2]")

   ;; --- cond / case ---------------------------------------------------------

   (check-js-output "cond evaluates correct branch"
     (list '(defn classify [(n : Int)] : String
              (cond (< n 0) "neg" (= n 0) "zero" :else "pos")))
     "console.log(classify(-1)); console.log(classify(0)); console.log(classify(1));"
     "neg\nzero\npos")

   (check-js-output "case matches correct value"
     (list '(defn day-type [(d : Int)] : String
              (case d 0 "weekend" 6 "weekend" "weekday")))
     "console.log(day_type(0)); console.log(day_type(3)); console.log(day_type(6));"
     "weekend\nweekday\nweekend")

   ;; --- try/catch -----------------------------------------------------------

   (check-js-output "try/catch returns catch value on error"
     (list '(defn safe-div [(a : Int) (b : Int)] : Int
              (try (/ a b) (catch Exception e -1))))
     "console.log(safe_div(10, 2));"
     "5")

   (check-js-output "try/catch as expression in let"
     (list '(defn f [] : Int
              (let [x (try 42 (catch Exception e 0))]
                (+ x 1))))
     "console.log(f());"
     "43")

   ;; --- do ------------------------------------------------------------------

   (check-js-output "do executes side effects in order"
     (list '(defn f [] : Nil
              (do (println "first")
                  (println "second")
                  (println "third"))))
     "f();"
     "first\nsecond\nthird")

   ;; --- when / when-let / if-let --------------------------------------------

   (check-js-output "when true runs body"
     (list '(defn f [(x : Bool)] : Nil (when x (println "yes"))))
     "f(true);"
     "yes")

   (check-js-behavior "when false produces no output"
     (list '(defn f [(x : Bool)] : Nil (when x (println "yes"))))
     "f(false);")

   (check-js-output "when-let non-null runs body"
     (list '(defn f [(x : Any)] : Nil (when-let [v x] (println v))))
     "f(42);"
     "42")

   (check-js-behavior "when-let null skips body"
     (list '(defn f [(x : Any)] : Nil (when-let [v x] (println v))))
     "f(null);")

   (check-js-output "if-let selects branch"
     (list '(defn f [(x : Any)] : String (if-let [v x] "found" "missing")))
     "console.log(f(1)); console.log(f(null));"
     "found\nmissing")

   ;; --- doseq / dotimes -----------------------------------------------------

   (check-js-output "doseq iterates"
     (list '(defn f [(xs : (Vec Int))] : Nil (doseq [x xs] (println x))))
     "f([10, 20, 30]);"
     "10\n20\n30")

   (check-js-output "dotimes counts"
     (list '(defn f [(n : Int)] : Nil (dotimes [i n] (println i))))
     "f(3);"
     "0\n1\n2")

   ;; --- interop -------------------------------------------------------------

   (check-js-output ".method call"
     (list '(defn f [(x : Any)] : String (.toString x)))
     "console.log(f(42));"
     "42")

   (check-js-output "Math/abs static call"
     (list '(defn f [(x : Int)] : Int (Math/abs x)))
     "console.log(f(-7));"
     "7")

   (check-js-output "new constructor"
     (list '(def d : Any (Date. 2024)))
     "console.log(typeof d);"
     "object")

   ;; --- multi-arity ---------------------------------------------------------

   (check-js-output "multi-arity dispatch"
     (list `(defn greet
              (,(br '(name : String)) : String (str "Hi " name))
              (,(br '(first : String) '(last : String)) : String (str "Hi " first " " last))))
     "console.log(greet(\"Alice\")); console.log(greet(\"Bob\", \"Smith\"));"
     "Hi Alice\nHi Bob Smith")

   ;; --- async/await ---------------------------------------------------------

   (check-js-output "async/await basic"
     (list `(declare-extern fetch-data ,(br 'String '-> '(Promise String)))
           '(defn f [(x : String)] : (Promise String) (await (fetch-data x))))
     "
globalThis.fetch_data = async (x) => 'got:' + x;
f('hello').then(r => console.log(r));
"
     "got:hello")

   (check-js-output "await in nested let"
     (list `(declare-extern get-val ,(br 'Int '-> '(Promise Int)))
           '(defn f [(n : Int)] : (Promise Int)
              (let [a (await (get-val n))
                    b (await (get-val (+ n 1)))]
                (+ a b))))
     "
globalThis.get_val = async (n) => n * 10;
f(3).then(r => console.log(r));
"
     "70")

   ;; --- munge disambiguation ------------------------------------------------

   (check-js-behavior "hyphen and underscore names are distinct"
     (list '(def my-x : Int 1)
           '(def my_x : Int 2))
     "
console.assert(my_x === 1, 'my-x should be 1, got ' + my_x);
console.assert(my__x === 2, 'my_x should be 2, got ' + my__x);
")

   ;; --- edge cases ----------------------------------------------------------

   (check-js-output "inc and dec"
     (list '(defn f [(x : Int)] : Int (inc x))
           '(defn g [(x : Int)] : Int (dec x)))
     "console.log(f(5)); console.log(g(5));"
     "6\n4")

   (check-js-output "count on vec"
     (list '(defn f [(xs : (Vec Int))] : Int (count xs)))
     "console.log(f([1,2,3]));"
     "3")

   (check-js-output "first on vec"
     (list '(defn f [(xs : (Vec Int))] : Int (first xs)))
     "console.log(f([10,20,30]));"
     "10")

   (check-js-output "nested record construction"
     (list '(defrecord Inner [(val : Int)])
           '(defrecord Outer [(inner : Inner)])
           '(defn get-val [(o : Outer)] : Int (:val (:inner o))))
     "console.log(get_val(Outer(Inner(42))));"
     "42")

   (check-js-output "defenum values"
     (list '(defenum Color :red :green :blue))
     "console.log(Color_values.has(':red')); console.log(Color_values.has(':purple'));"
     "true\nfalse")

   ;; --- atom operations -------------------------------------------------------

   (check-js-output "atom create and deref"
     (list '(defn f [] : Int
              (let [a (atom 42)]
                (deref a))))
     "console.log(f());"
     "42")

   (check-js-output "atom reset!"
     (list '(defn f [] : Int
              (let [a (atom 0)]
                (do (reset! a 99)
                    (deref a)))))
     "console.log(f());"
     "99")

   (check-js-output "atom swap!"
     (list '(defn f [] : Int
              (let [a (atom 10)]
                (do (swap! a (fn [(x : Int)] : Int (+ x 1)))
                    (deref a)))))
     "console.log(f());"
     "11")

   (check-js-output "atom swap! with extra args"
     (list '(defn add [(x : Int) (y : Int)] : Int (+ x y))
           '(defn f [] : Int
              (let [a (atom 10)]
                (do (swap! a add 5)
                    (deref a)))))
     "console.log(f());"
     "15")

   ;; --- additional stdlib -----------------------------------------------------

   (check-js-output "take-last"
     (list '(defn f [(xs : (Vec Int))] : Any (take-last 2 xs)))
     "console.log(JSON.stringify(f([1,2,3,4,5])));"
     "[4,5]")

   (check-js-output "not= returns boolean"
     (list '(defn f [(a : Int) (b : Int)] : Bool (not= a b)))
     "console.log(f(1,2)); console.log(f(1,1));"
     "true\nfalse")

   (check-js-output "seq on empty returns null"
     (list '(defn f [(xs : (Vec Int))] : Any (seq xs)))
     "console.log(f([])); console.log(f([1]) !== null);"
     "null\ntrue")

   (check-js-output "sequential? predicate"
     (list '(defn f [(x : Any)] : Bool (sequential? x)))
     "console.log(f([1,2])); console.log(f(42));"
     "true\nfalse")

   ;; --- runtime helpers (beagle/core.js) ------------------------------------

   (check-js-output "range generates array"
     (list '(defn f [] : Any (range 5)))
     "console.log(JSON.stringify(f()));"
     "[0,1,2,3,4]")

   (check-js-output "range with start and end"
     (list '(defn f [] : Any (range 2 7)))
     "console.log(JSON.stringify(f()));"
     "[2,3,4,5,6]")

   (check-js-output "range with step"
     (list '(defn f [] : Any (range 0 10 3)))
     "console.log(JSON.stringify(f()));"
     "[0,3,6,9]")

   (check-js-output "remove filters out matching"
     (list '(defn z? [(x : Int)] : Bool (= x 0))
           '(defn f [(xs : (Vec Int))] : Any (remove z? xs)))
     "console.log(JSON.stringify(f([0,1,0,2,0,3])));"
     "[1,2,3]")

   (check-js-output "mapcat flattens"
     (list '(defn dup [(x : Int)] : (Vec Int)
              (let [v x] (conj (conj (conj (range 0) v) v) v)))
            '(defn f [(xs : (Vec Int))] : Any (mapcat dup xs)))
     "console.log(JSON.stringify(f([1,2])));"
     "[1,1,1,2,2,2]")

   (check-js-output "every? checks all"
     (list '(defn p? [(x : Int)] : Bool (> x 0))
           '(defn f [(xs : (Vec Int))] : Any (every? p? xs)))
     "console.log(f([1,2,3])); console.log(f([1,0,3]));"
     "true\nfalse")

   (check-js-output "keep filters nulls"
     (list '(defn maybe-inc [(x : Int)] : Any (if (> x 0) (inc x) nil))
           '(defn f [(xs : (Vec Int))] : Any (keep maybe-inc xs)))
     "console.log(JSON.stringify(f([0,1,0,2])));"
     "[2,3]")

   (check-js-output "take-while stops at first false"
     (list '(defn p? [(x : Int)] : Bool (> x 0))
           '(defn f [(xs : (Vec Int))] : Any (take-while p? xs)))
     "console.log(JSON.stringify(f([3,2,1,0,-1])));"
     "[3,2,1]")

   (check-js-output "drop-while drops prefix"
     (list '(defn n? [(x : Int)] : Bool (< x 0))
           '(defn f [(xs : (Vec Int))] : Any (drop-while n? xs)))
     "console.log(JSON.stringify(f([-3,-2,-1,0,1,2])));"
     "[0,1,2]")

   (check-js-output "select-keys picks keys"
     (list `(defn f [(m : Any)] : Any (select-keys m ,(br ":a" ":c"))))
     "console.log(JSON.stringify(f({':a':1, ':b':2, ':c':3})));"
     "{\":a\":1,\":c\":3}")

   (check-js-output "assoc-in nested set"
     (list `(defn f [(m : Any)] : Any (assoc-in m ,(br ":a" ":b") 42)))
     "console.log(JSON.stringify(f({':a': {':b': 0}})));"
     "{\":a\":{\":b\":42}}")

   (check-js-output "update-in nested update"
     (list '(defn add1 [(x : Int)] : Int (+ x 1))
           `(defn f [(m : Any)] : Any (update-in m ,(br ":a") add1)))
     "console.log(JSON.stringify(f({':a': 5})));"
     "{\":a\":6}")

   ;; --- higher-order value wrappers -------------------------------------------

   (check-js-output "map inc as value"
     (list '(defn f [(xs : (Vec Int))] : Any (map inc xs)))
     "console.log(JSON.stringify(f([1,2,3])));"
     "[2,3,4]")

   (check-js-output "map dec as value"
     (list '(defn f [(xs : (Vec Int))] : Any (map dec xs)))
     "console.log(JSON.stringify(f([10,20,30])));"
     "[9,19,29]")

   (check-js-output "filter pos? as value"
     (list '(defn f [(xs : (Vec Int))] : Any (filter pos? xs)))
     "console.log(JSON.stringify(f([-1,0,1,2,-3])));"
     "[1,2]")

   (check-js-output "reduce + as value"
     (list '(defn f [(xs : (Vec Int))] : Any (reduce + 0 xs)))
     "console.log(f([1,2,3,4]));"
     "10")

   (check-js-output "filter some? as value"
     (list '(defn f [(xs : (Vec Any))] : Any (filter some? xs)))
     "console.log(JSON.stringify(f([1,null,2,null,3])));"
     "[1,2,3]")

   (check-js-output "filter nil? as value"
     (list '(defn f [(xs : (Vec Any))] : Any (filter nil? xs)))
     "console.log(f([1,null,2,null,3]).length);"
     "2")

   (check-js-output "user-defined inc shadows stdlib in map"
     (list '(defn inc [(x : Int)] : Int (* x 10))
           '(defn f [(xs : (Vec Int))] : Any (map inc xs)))
     "console.log(JSON.stringify(f([1,2,3])));"
     "[10,20,30]")

   (check-js-output "loop with let containing recur"
     (list '(defn find-char [(s : String) (target : Int)] : Int
              (loop [i 0]
                (let [c (.charCodeAt s i)]
                  (if (= c target) i (recur (+ i 1)))))))
     "console.log(find_char('hello', 108));"
     "2")

   (check-js-output "loop with nested let containing recur"
     (list '(defn sum-until [(xs : (Vec Int)) (limit : Int)] : Int
              (loop [i 0 total 0]
                (if (>= i (count xs)) total
                  (let [v (nth xs i)]
                    (if (>= (+ total v) limit) total
                      (recur (+ i 1) (+ total v))))))))
     "console.log(sum_until([1,2,3,4,5], 7));"
     "6")

   (check-js-output "loop with cond containing recur"
     (list '(defn classify-first [(xs : (Vec Int))] : String
              (loop [i 0]
                (if (>= i (count xs)) "none"
                  (let [v (nth xs i)]
                    (cond
                      (> v 100) "big"
                      (> v 10) "medium"
                      :else (recur (+ i 1))))))))
     "console.log(classify_first([1,5,50,200]));"
     "medium")

 )))
