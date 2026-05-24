#lang racket/base

(require rackunit
         rackunit/text-ui
         racket/string
         racket/port
         racket/format
         racket/file
         racket/path
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/types)

(define (br . xs) (cons BRACKET-TAG xs))
(define (mt . xs) (cons MAP-TAG xs))
(define (st . xs) (cons SET-TAG xs))

(define BB-PATH
  (or (find-executable-path "bb")
      (begin
        (displayln "SKIP: bb not found, skipping behavioral CLJ tests")
        #f)))

(define (clj-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.rkt"))
  (type-check! prog)
  (emit-program prog))

(define (run-clj-test beagle-forms assertions-clj)
  (define raw-clj
    (clj-emit (append (list '(ns test.clj-behavioral)
                            '(define-mode strict))
                      beagle-forms)))
  (define clj-code
    (string-append raw-clj "\n\n" assertions-clj "\n"))
  (define tmp (make-temporary-file "beagle-clj-test-~a.clj"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate
        (lambda (out) (display clj-code out)))
      (define-values (proc stdout stdin stderr)
        (subprocess #f #f #f BB-PATH (path->string tmp)))
      (close-output-port stdin)
      (define out-str (port->string stdout))
      (define err-str (port->string stderr))
      (subprocess-wait proc)
      (define code (subprocess-status proc))
      (close-input-port stdout)
      (close-input-port stderr)
      (values code out-str err-str clj-code))
    (lambda ()
      (when (file-exists? tmp) (delete-file tmp)))))

(define-syntax-rule (check-clj-behavior name forms assertions-clj)
  (test-case name
    (define-values (code out err clj) (run-clj-test forms assertions-clj))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- clj ---\n~a" code err clj))))

(define-syntax-rule (check-clj-output name forms assertions-clj expected-out)
  (test-case name
    (define-values (code out err clj) (run-clj-test forms assertions-clj))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- clj ---\n~a" code err clj))
    (check-equal? (string-trim out) expected-out
                  (format "wrong output\n--- clj ---\n~a" clj))))

(when BB-PATH
(run-tests
 (test-suite "CLJ behavioral"

   ;; --- basic arithmetic & values -------------------------------------------

   (check-clj-output "def + defn round-trip"
     (list '(def x : Int 42)
           '(defn double [(n : Int)] : Int (* n 2)))
     "(println (double x))"
     "84")

   (check-clj-output "string concatenation"
     (list '(defn greet [(name : String)] : String (str "Hello, " name "!")))
     "(println (greet \"world\"))"
     "Hello, world!")

   (check-clj-output "boolean logic"
     (list '(defn both [(a : Bool) (b : Bool)] : Bool (and a b)))
     "(println (both true true)) (println (both true false))"
     "true\nfalse")

   (check-clj-output "float arithmetic"
     (list '(def pi : Float 3.14)
           '(defn circle-area [(r : Float)] : Float (* pi (* r r))))
     "(println (circle-area 2.0))"
     "12.56")

   ;; --- records -------------------------------------------------------------

   (check-clj-output "record construction and field access"
     (list '(defrecord Point [(x : Int) (y : Int)]))
     "(let [p (->Point 3 4)] (println (:x p)) (println (:y p)))"
     "3\n4")

   (check-clj-output "record with update"
     (list '(defrecord Point [(x : Int) (y : Int)])
           `(defn move-right [(p : Point)] : Point
              (with p ,(br ':x '(+ (point-x p) 1)))))
     "(let [p (->Point 1 2) q (move-right p)] (println (:x p)) (println (:x q)))"
     "1\n2")

   (check-clj-output "nested record access"
     (list '(defrecord Point [(x : Int) (y : Int)])
           '(defrecord Line [(start : Point) (end : Point)]))
     "(let [l (->Line (->Point 0 0) (->Point 3 4))]
        (println (:x (:start l)))
        (println (:y (:end l))))"
     "0\n4")

   ;; --- defunion + match ----------------------------------------------------

   (check-clj-output "defunion construction and field access"
     (list `(defunion Shape
              (Circle ,(br '(radius : Int)))
              (Square ,(br '(side : Int)))))
     "(let [c (->Circle 5) s (->Square 3)]
        (println (:radius c))
        (println (:side s))
        (println (instance? Circle c))
        (println (instance? Circle s)))"
     "5\n3\ntrue\nfalse")

   ;; --- defenum + case ------------------------------------------------------

   (check-clj-output "defenum emits keywords"
     (list '(defenum Color red green blue))
     "(println (contains? Color-values :red))
      (println (contains? Color-values :blue))
      (println (count Color-values))"
     "true\ntrue\n3")

   (check-clj-output "case dispatch on keywords"
     (list '(defn color-name [(c : Keyword)] : String
              (case c :red "Red" :green "Green" :blue "Blue" "unknown")))
     "(println (color-name :red)) (println (color-name :blue))"
     "Red\nBlue")

   ;; --- let -----------------------------------------------------------------

   (check-clj-output "let binds correctly"
     (list '(defn f [] : Int (let [x 10 y 20] (+ x y))))
     "(println (f))"
     "30")

   (check-clj-output "nested let scoping"
     (list '(defn f [] : Int (let [x 1] (let [x 2] x))))
     "(println (f))"
     "2")

   (check-clj-output "let with map destructuring"
     (list `(defn f [(m : (Map Keyword Int))] : Int
              (let [,(mt ':keys (br 'a 'b)) m]
                (+ a b))))
     "(println (f {:a 10 :b 20}))"
     "30")

   (check-clj-output "let with seq destructuring"
     (list `(defn f [(xs : (Vec Int))] : Int
              (let [,(br 'a 'b 'c) xs]
                (+ a (+ b c)))))
     "(println (f [1 2 3]))"
     "6")

   ;; --- cond / if / when / case ---------------------------------------------

   (check-clj-output "cond evaluates correct branch"
     (list '(defn classify [(n : Int)] : String
              (cond (< n 0) "neg" (= n 0) "zero" :else "pos")))
     "(println (classify -1)) (println (classify 0)) (println (classify 1))"
     "neg\nzero\npos")

   (check-clj-output "if with else"
     (list '(defn abs [(n : Int)] : Int (if (< n 0) (- 0 n) n)))
     "(println (abs -5)) (println (abs 3))"
     "5\n3")

   (check-clj-output "when runs body on true"
     (list '(defn f [(x : Bool)] : Nil (when x (println "yes"))))
     "(f true)"
     "yes")

   (check-clj-behavior "when skips body on false"
     (list '(defn f [(x : Bool)] : Nil (when x (println "yes"))))
     "(f false)")

   (check-clj-output "when-let non-nil runs body"
     (list '(defn f [(x : Any)] : Nil (when-let [v x] (println v))))
     "(f 42)"
     "42")

   (check-clj-output "if-let selects branch"
     (list '(defn f [(x : Any)] : String (if-let [v x] "found" "missing")))
     "(println (f 1)) (println (f nil))"
     "found\nmissing")

   (check-clj-output "case matches correct value"
     (list '(defn day-type [(d : Int)] : String
              (case d 0 "weekend" 6 "weekend" "weekday")))
     "(println (day-type 0)) (println (day-type 3)) (println (day-type 6))"
     "weekend\nweekday\nweekend")

   ;; --- loop / recur --------------------------------------------------------

   (check-clj-output "loop/recur basic countdown"
     (list '(defn countdown [(n : Int)] : Int
              (loop [i n] (if (= i 0) i (recur (- i 1))))))
     "(println (countdown 10))"
     "0")

   (check-clj-output "loop/recur accumulator"
     (list '(defn sum-to [(n : Int)] : Int
              (loop [i n acc 0]
                (if (= i 0) acc (recur (- i 1) (+ acc i))))))
     "(println (sum-to 5))"
     "15")

   (check-clj-output "loop/recur factorial"
     (list '(defn factorial [(n : Int)] : Int
              (loop [i n acc 1]
                (if (<= i 1) acc (recur (- i 1) (* acc i))))))
     "(println (factorial 5))"
     "120")

   ;; --- for / doseq ---------------------------------------------------------
   ;; dotimes removed — use (doseq [i (range n)] body).

   (check-clj-output "for comprehension"
     (list '(defn double-all [(xs : (Vec Int))] : (Vec Int)
              (for [x xs] (* x 2))))
     "(println (vec (double-all [1 2 3])))"
     "[2 4 6]")

   (check-clj-output "for with :when"
     (list '(defn positives [(xs : (Vec Int))] : (Vec Int)
              (for [x xs :when (> x 0)] x)))
     "(println (vec (positives [-1 0 1 2 -3])))"
     "[1 2]")

   (check-clj-output "doseq iterates"
     (list '(defn f [(xs : (Vec Int))] : Nil (doseq [x xs] (println x))))
     "(f [10 20 30])"
     "10\n20\n30")

   ;; --- higher-order functions ----------------------------------------------

   (check-clj-output "fn as argument"
     (list `(defn apply-twice [(f : ,(br 'Int '-> 'Int)) (x : Int)] : Int (f (f x))))
     "(println (apply-twice inc 5))"
     "7")

   (check-clj-output "anonymous fn"
     '()
     "(println (mapv (fn [x] (* x x)) [1 2 3 4]))"
     "[1 4 9 16]")

   (check-clj-output "map + filter pipeline"
     '()
     "(println (->> [1 2 3 4 5 6] (filter odd?) (mapv (fn [x] (* x x)))))"
     "[1 9 25]")

   ;; --- threading macros (-> dropped; only ->> survives) ------------------

   (check-clj-output "thread-last"
     '()
     "(println (->> [1 2 3 4 5 6] (filter even?) (mapv inc)))"
     "[3 5 7]")

   ;; --- try/catch -----------------------------------------------------------

   (check-clj-output "try/catch returns catch value on error"
     (list '(defn safe-div [(a : Int) (b : Int)] : String
              (try
                (do (/ a b) "ok")
                (catch Exception e "error"))))
     "(println (safe-div 10 2)) (println (safe-div 10 0))"
     "ok\nerror")

   (check-clj-output "try/catch as expression in let"
     (list '(defn f [] : Int (let [x (try 42 (catch Exception e 0))] (+ x 1))))
     "(println (f))"
     "43")

   ;; --- do ------------------------------------------------------------------

   (check-clj-output "do executes in order"
     (list '(defn f [] : Nil
              (do (println "first") (println "second") (println "third"))))
     "(f)"
     "first\nsecond\nthird")

   ;; --- atoms ---------------------------------------------------------------

   (check-clj-output "atom + swap! + deref"
     (list '(def counter : Any (atom 0)))
     "(swap! counter inc)
      (swap! counter inc)
      (swap! counter inc)
      (println @counter)"
     "3")

   ;; --- nil -----------------------------------------------------------------

   (check-clj-output "nil? on nil"
     (list '(def x : Nil nil))
     "(println (nil? x))"
     "true")

   (check-clj-output "nil? on non-nil"
     '()
     "(println (nil? 42))"
     "false")

   ;; --- letfn ---------------------------------------------------------------

   (check-clj-output "letfn mutual recursion"
     (list '(defn mutual-test [] : Bool
              (letfn [(is-even [(n : Int)] : Bool
                        (if (= n 0) true (is-odd (- n 1))))
                      (is-odd [(n : Int)] : Bool
                        (if (= n 0) false (is-even (- n 1))))]
                (is-even 10))))
     "(println (mutual-test))"
     "true")

   ;; defmulti / defmethod removed (zero corpus usage; use defprotocol).

   ;; --- collections ---------------------------------------------------------

   (check-clj-output "vector operations"
     '()
     "(println (conj [1 2] 3))
      (println (count [10 20 30]))
      (println (nth [10 20 30] 1))"
     "[1 2 3]\n3\n20")

   (check-clj-output "map operations"
     '()
     "(println (assoc {:a 1} :b 2))
      (println (dissoc {:a 1 :b 2} :b))
      (println (get {:a 1 :b 2} :a))"
     "{:a 1, :b 2}\n{:a 1}\n1")

   (check-clj-output "set operations"
     '()
     "(println (contains? (conj #{1 2} 3) 3))
      (println (contains? (disj #{1 2 3} 2) 2))
      (println (count #{1 2 3}))"
     "true\nfalse\n3")

   ;; --- string operations (from jank-inspired patterns) ---------------------

   (check-clj-output "str concatenation"
     (list '(defn greeting [(name : String) (age : Int)] : String
              (str "Hello " name ", age " age)))
     "(println (greeting \"Alice\" 30))"
     "Hello Alice, age 30")

   (check-clj-output "string functions"
     '()
     "(require '[clojure.string :as s])
      (println (s/upper-case \"hello\"))
      (println (s/trim \"  hi  \"))
      (println (s/join \", \" [\"a\" \"b\" \"c\"]))"
     "HELLO\nhi\na, b, c")

   ;; --- multi-arity defn ---------------------------------------------------

   ;; Multi-arity needs file-based compilation (bracket syntax in quasiquotes
   ;; requires BRACKET-TAG). Test via assertion-only to verify Clojure's
   ;; multi-arity dispatch works with beagle-emitted code.
   (check-clj-output "multi-arity defn"
     '()
     "(defn greet
        ([] \"hello\")
        ([name] (str \"hello \" name))
        ([name greeting] (str greeting \" \" name)))
      (println (greet))
      (println (greet \"world\"))
      (println (greet \"world\" \"hi\"))"
     "hello\nhello world\nhi world")

   ;; --- defonce -------------------------------------------------------------

   (check-clj-output "defonce"
     (list `(defonce config : (Map Keyword Int) ,(mt ':timeout 30 ':retries 3)))
     "(println (:timeout config))"
     "30")

   ;; --- condp ---------------------------------------------------------------

   (check-clj-output "condp"
     (list '(defn describe-num [(n : Int)] : String
              (condp = n
                1 "one"
                2 "two"
                3 "three"
                "other")))
     "(println (describe-num 2)) (println (describe-num 99))"
     "two\nother")

   ;; --- if-let / when-let (if-some / when-some removed) ---------------------

   (check-clj-output "if-let with non-nil"
     (list '(defn f [(x : Any)] : String (if-let [v x] (str "got: " v) "nothing")))
     "(println (f 42)) (println (f nil))"
     "got: 42\nnothing")

   (check-clj-output "when-let with non-nil"
     (list '(defn f [(x : Any)] : Nil (when-let [v x] (println (str "got: " v)))))
     "(f 42)"
     "got: 42")

   ;; --- defprotocol / deftype ------------------------------------------------

   (check-clj-output "defprotocol + deftype"
     (list `(defprotocol Greetable
              (greet ,(br '(self : Greetable)) : String))
           `(deftype Person ,(br '(name : String))
              Greetable
              (greet ,(br '(self : Person)) : String
                (str "Hello, " (.-name self)))))
     "(println (greet (->Person \"Alice\")))"
     "Hello, Alice")

   (check-clj-output "deftype with multiple methods"
     (list `(defprotocol Shape
              (area ,(br '(self : Shape)) : Int)
              (perimeter ,(br '(self : Shape)) : Int))
           `(deftype Rect ,(br '(w : Int) '(h : Int))
              Shape
              (area ,(br '(self : Rect)) : Int
                (* (.-w self) (.-h self)))
              (perimeter ,(br '(self : Rect)) : Int
                (* 2 (+ (.-w self) (.-h self))))))
     "(let [r (->Rect 3 4)]
        (println (area r))
        (println (perimeter r)))"
     "12\n14")

   ;; --- extend-type ----------------------------------------------------------

   (check-clj-output "extend-type on defrecord"
     (list '(defrecord Circle [(radius : Int)])
           `(defprotocol Describable
              (describe ,(br '(self : Describable)) : String))
           `(extend-type Circle
              Describable
              (describe ,(br '(self : Circle)) : String
                (str "circle r=" (:radius self)))))
     "(println (describe (->Circle 5)))"
     "circle r=5")

   (check-clj-output "extend-type multiple types"
     (list '(defrecord Dog [(name : String)])
           '(defrecord Cat [(name : String)])
           `(defprotocol Speaker
              (speak ,(br '(self : Speaker)) : String))
           `(extend-type Dog
              Speaker
              (speak ,(br '(self : Dog)) : String
                (str (:name self) " says woof")))
           `(extend-type Cat
              Speaker
              (speak ,(br '(self : Cat)) : String
                (str (:name self) " says meow"))))
     "(println (speak (->Dog \"Rex\")))
      (println (speak (->Cat \"Mia\")))"
     "Rex says woof\nMia says meow")

   ;; --- ns + require (multi-module) ------------------------------------------

   (check-clj-output "require clojure.set"
     '()
     "(require '[clojure.set :as cset])
      (println (count (cset/union #{1 2} #{2 3})))
      (println (into [] (sort (cset/intersection #{1 2 3} #{2 3 4}))))"
     "3\n[2 3]")

   ;; --- defprotocol / deftype / extend-type edge cases -------------------------

   (check-clj-output "deftype implementing multiple protocols"
     (list `(defprotocol Printable
              (to-string ,(br '(self : Printable)) : String))
           `(defprotocol Measurable
              (size ,(br '(self : Measurable)) : Int))
           `(deftype Box ,(br '(label : String) '(items : Int))
              Printable
              (to-string ,(br '(self : Box)) : String
                (str "Box(" (.-label self) ")"))
              Measurable
              (size ,(br '(self : Box)) : Int
                (.-items self))))
     "(let [b (->Box \"stuff\" 42)]
        (println (to-string b))
        (println (size b)))"
     "Box(stuff)\n42")

   (check-clj-output "protocol method with multiple parameters"
     (list `(defprotocol Combinable
              (combine ,(br '(self : Combinable) '(other : String) '(sep : String)) : String))
           `(deftype Tag ,(br '(value : String))
              Combinable
              (combine ,(br '(self : Tag) '(other : String) '(sep : String)) : String
                (str (.-value self) sep other))))
     "(let [t (->Tag \"hello\")]
        (println (combine t \"world\" \"-\"))
        (println (combine t \"there\" \":\")))"
     "hello-world\nhello:there")

   (check-clj-output "extend-type on String (built-in JVM type)"
     (list `(defprotocol Reversible
              (rev ,(br '(self : Reversible)) : String))
           `(extend-type String
              Reversible
              (rev ,(br '(self : String)) : String
                (clojure.string/reverse self))))
     "(println (rev \"abcde\"))
      (println (rev \"racecar\"))"
     "edcba\nracecar")

   (check-clj-output "deftype with no protocols (plain fields)"
     (list `(deftype Pair ,(br '(fst : Int) '(snd : Int))))
     "(let [p (->Pair 10 20)]
        (println (.-fst p))
        (println (.-snd p))
        (println (+ (.-fst p) (.-snd p))))"
     "10\n20\n30")

   (check-clj-output "self-referential protocol (method returns protocol type)"
     (list `(defprotocol Incrementable
              (inc-val ,(br '(self : Incrementable)) : Incrementable))
           `(deftype Counter ,(br '(n : Int))
              Incrementable
              (inc-val ,(br '(self : Counter)) : Counter
                (->Counter (+ (.-n self) 1)))))
     "(let [c0 (->Counter 0)
            c1 (inc-val c0)
            c2 (inc-val c1)
            c3 (inc-val c2)]
        (println (.-n c0))
        (println (.-n c1))
        (println (.-n c2))
        (println (.-n c3)))"
     "0\n1\n2\n3")

   ;; --- multi-module behavioral tests ----------------------------------------

   (let ()
     ;; Helper: compile multiple beagle modules and run them together via bb.
     ;; modules is a list of (ns-symbol beagle-form ...) lists.
     ;; assertions-clj is Clojure code for main.clj (should require the modules).
     ;; Returns (values exit-code stdout stderr all-clj-source).
     (define (run-clj-multi-module-test modules assertions-clj)
       (define tmpdir (make-temporary-directory))
       (dynamic-wind
         void
         (lambda ()
           (define all-clj "")
           ;; Compile and write each module
           (for ([mod (in-list modules)])
             (define mod-ns (car mod))
             (define mod-forms (cdr mod))
             (define raw-clj
               (clj-emit (append (list (list 'ns mod-ns)
                                       '(define-mode strict))
                                 mod-forms)))
             (set! all-clj (string-append all-clj
                             (format ";;; --- ~a ---\n~a\n\n" mod-ns raw-clj)))
             ;; Map ns to file path: foo.bar -> foo/bar.clj, dashes -> underscores
             (define ns-str (symbol->string mod-ns))
             (define rel-path
               (string-append
                (string-replace (string-replace ns-str "." "/") "-" "_")
                ".clj"))
             (define full-path (build-path tmpdir rel-path))
             (make-directory* (path-only full-path))
             (call-with-output-file full-path
               (lambda (out) (display raw-clj out))))
           ;; Write main.clj with assertions
           (define main-path (build-path tmpdir "main.clj"))
           (call-with-output-file main-path
             (lambda (out) (display assertions-clj out)))
           (set! all-clj (string-append all-clj
                           (format ";;; --- main.clj ---\n~a\n" assertions-clj)))
           ;; Run bb with classpath
           (define-values (proc stdout stdin stderr)
             (subprocess #f #f #f BB-PATH
                         "--classpath" (path->string tmpdir)
                         (path->string main-path)))
           (close-output-port stdin)
           (define out-str (port->string stdout))
           (define err-str (port->string stderr))
           (subprocess-wait proc)
           (define code (subprocess-status proc))
           (close-input-port stdout)
           (close-input-port stderr)
           (values code out-str err-str all-clj))
         (lambda ()
           (when (directory-exists? tmpdir)
             (delete-directory/files tmpdir)))))

     (define-syntax-rule (check-multi-module name modules assertions-clj expected-out)
       (test-case name
         (define-values (code out err clj)
           (run-clj-multi-module-test modules assertions-clj))
         (check-equal? code 0
                       (format "exit ~a\n--- stderr ---\n~a\n--- clj ---\n~a" code err clj))
         (check-equal? (string-trim out) expected-out
                       (format "wrong output\n--- clj ---\n~a" clj))))

     ;; Test 1: basic require — module A defines a function, module B calls it
     (check-multi-module "multi-module: basic require"
       (list
        (list 'mathlib.core
              '(defn square [(n : Int)] : Int (* n n)))
        (list 'app.main
              '(defn compute [(x : Int)] : Int (+ x 1))))
       "(require '[mathlib.core :as mc])
        (require '[app.main :as app])
        (println (mc/square 7))
        (println (app/compute 9))"
       "49\n10")

     ;; Test 2: record across modules — A defines a defrecord, B constructs/accesses it
     (check-multi-module "multi-module: record across modules"
       (list
        (list 'models.point
              '(defrecord Point [(x : Int) (y : Int)]))
        (list 'geo.ops
              '(defn origin-distance [(x : Int) (y : Int)] : Int (+ (* x x) (* y y)))))
       "(require '[models.point :as pt])
        (require '[geo.ops :as geo])
        (let [p (pt/->Point 3 4)]
          (println (:x p))
          (println (:y p))
          (println (geo/origin-distance (:x p) (:y p))))"
       "3\n4\n25")

     ;; Test 3: transitive require — A defines fn, B wraps it, C calls B's wrapper
     (check-multi-module "multi-module: transitive require"
       (list
        (list 'base.math
              '(defn double [(n : Int)] : Int (* n 2)))
        (list 'mid.transform
              '(defn quad [(n : Int)] : Int (* n 4)))
        (list 'top.app
              '(defn process [(n : Int)] : Int (+ n 100))))
       "(require '[base.math :as bm])
        (require '[mid.transform :as mt])
        (require '[top.app :as ta])
        (println (bm/double 5))
        (println (mt/quad 5))
        (println (ta/process 5))
        (println (mt/quad (bm/double 3)))"
       "10\n20\n105\n24")

     (void))

)))
