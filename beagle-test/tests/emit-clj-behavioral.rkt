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
         beagle/private/module-interface
         beagle/private/types)

(define (br . xs) (cons BRACKET-TAG xs))
;; Canonical function-type datum: (Fn [P ...] R).
(define (fn-ty params ret) (list 'Fn (apply br params) ret))
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
     #:source-path "test.bclj"))
  (type-check-with-locs!
   prog
   (lambda (failure _stx) (raise failure))
   #:capture-types? #t)
  (emit-program prog))

(define (run-clj-test beagle-forms assertions-clj)
  (define raw-clj
    (clj-emit (append (list '(ns test.clj-behavioral))
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

(define (checked-module ns forms #:module-resolver [module-resolver #f])
  (define stxs
    (map (lambda (form) (datum->syntax #f form))
         (append (list (list 'ns ns)

                       '(define-target clj))
                 forms)))
  (define program
    (parse-program
     stxs
     #:source-path (format "~a.bclj" ns)
     #:module-resolver module-resolver))
  (type-check-with-locs!
   program
   (lambda (failure _stx) (raise failure))
   #:capture-types? #t)
  (values program stxs))

(define (run-linked-clj-test provider-ns provider-forms
                             consumer-ns consumer-forms
                             assertions-clj)
  (define-values (provider provider-stxs)
    (checked-module provider-ns provider-forms))
  (define provider-interface
    (program->module-interface
     provider
     #:source-id (format "~a.bclj" provider-ns)))
  (define provider-source
    (module-source
     provider-ns
     (format "~a.bclj" provider-ns)
     provider-stxs
     provider-interface))
  (define-values (consumer _consumer-stxs)
    (checked-module
     consumer-ns
     consumer-forms
     #:module-resolver
     (lambda (namespace _importer-source)
       (and (eq? namespace provider-ns) provider-source))))
  (define modules
    (list (cons provider-ns (emit-program provider))
          (cons consumer-ns (emit-program consumer))))
  (define tmpdir (make-temporary-directory))
  (define all-clj "")
  (dynamic-wind
    void
    (lambda ()
      (for ([module (in-list modules)])
        (define ns (car module))
        (define emitted (cdr module))
        (define relative
          (string-append
           (string-replace
            (string-replace (symbol->string ns) "." "/") "-" "_")
           ".clj"))
        (define path (build-path tmpdir relative))
        (make-directory* (path-only path))
        (call-with-output-file path #:exists 'truncate
          (lambda (out) (display emitted out)))
        (set! all-clj
              (string-append
               all-clj (format ";;; --- ~a ---\n~a\n\n" ns emitted))))
      (define main-path (build-path tmpdir "main.clj"))
      (call-with-output-file main-path #:exists 'truncate
        (lambda (out) (display assertions-clj out)))
      (set! all-clj
            (string-append all-clj
                           (format ";;; --- main.clj ---\n~a\n" assertions-clj)))
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

(define-syntax-rule
  (check-linked-clj-output name provider-ns provider-forms
                           consumer-ns consumer-forms
                           assertions-clj expected-out)
  (test-case name
    (define-values (code out err clj)
      (run-linked-clj-test provider-ns provider-forms
                           consumer-ns consumer-forms assertions-clj))
    (check-equal? code 0
                  (format "exit ~a\n--- stderr ---\n~a\n--- clj ---\n~a"
                          code err clj))
    (check-equal? (string-trim out) expected-out
                  (format "wrong output\n--- clj ---\n~a" clj))))

(when BB-PATH
(run-tests
 (test-suite "CLJ behavioral"

   ;; --- basic arithmetic & values -------------------------------------------

   (check-clj-output "def + defn round-trip"
     (list '(def x 42)
           '(defn double [(n Int)] Int (* n 2)))
     "(println (double x))"
     "84")

   (check-clj-output "string concatenation"
     (list '(defn greet [(name String)] String (str "Hello, " name "!")))
     "(println (greet \"world\"))"
     "Hello, world!")

   (check-clj-output "boolean logic"
     (list '(defn both [(a Bool) (b Bool)] Bool (and a b)))
     "(println (both true true)) (println (both true false))"
     "true\nfalse")

   (check-clj-output "float arithmetic"
     (list '(def pi 3.14)
           '(defn circle-area [(r Float)] Float (* pi (* r r))))
     "(println (circle-area 2.0))"
     "12.56")

   ;; --- records -------------------------------------------------------------

   (check-clj-output "record construction and field access"
     (list '(defrecord Point [(x Int) (y Int)]))
     "(let [p (->Point 3 4)] (println (:x p)) (println (:y p)))"
     "3\n4")

   (check-clj-output "record with update"
     (list '(defrecord Point [(x Int) (y Int)])
           `(defn move-right [(p Point)] Point
              (with p ,(br ':x '(+ (point-x p) 1)))))
     "(let [p (->Point 1 2) q (move-right p)] (println (:x p)) (println (:x q)))"
     "1\n2")

   (check-clj-output "nested record access"
     (list '(defrecord Point [(x Int) (y Int)])
           '(defrecord Line [(start Point) (end Point)]))
     "(let [l (->Line (->Point 0 0) (->Point 3 4))]
        (println (:x (:start l)))
        (println (:y (:end l))))"
     "0\n4")

   ;; --- defunion + match ----------------------------------------------------

   (check-clj-output "defunion construction and field access"
     (list `(defunion Shape
              (Circle ,(br '(radius Int)))
              (Square ,(br '(side Int)))))
     "(let [c (->Circle 5) s (->Square 3)]
        (println (:radius c))
        (println (:side s))
        (println (instance? Circle c))
        (println (instance? Circle s)))"
     "5\n3\ntrue\nfalse")

   ;; The variant accessors must be DEFINED, not just type-registered:
   ;; check.rkt gives `circle-radius` a type, so an absent defn is an
   ;; unresolved symbol at run time.
   (check-clj-output "defunion variant accessors are defined"
     (list `(defunion Shape
              (Circle ,(br '(radius Int)))
              (Square ,(br '(side Int)))))
     "(println (circle-radius (->Circle 5)))
      (println (square-side (->Square 3)))"
     "5\n3")

   ;; A single-binding variant pattern binds the FIELD (checker and emitter
   ;; disagreed here: the checker used to bind the instance).
   (check-clj-output "single-binding variant pattern binds the field"
     (list `(defunion Shape
              (Circle ,(br '(radius Int)))
              (Square ,(br '(side Int))))
           `(defn shape-size [(s Shape)] Int
              (match s
                ,(br '(Circle value) 'value)
                ,(br '(Square value) 'value))))
     "(println (shape-size (->Circle 5)))
      (println (shape-size (->Square 3)))"
     "5\n3")

   ;; --- defenum + case ------------------------------------------------------

   (check-clj-output "defenum emits keywords"
     (list '(defenum Color red green blue))
     "(println (contains? Color-values :red))
      (println (contains? Color-values :blue))
      (println (count Color-values))"
     "true\ntrue\n3")

   (check-clj-output "match with keyword literals (was: case dispatch)"
     (list '(defn color-name [(c Keyword)] String
              (match c [:red "Red"] [:green "Green"] [:blue "Blue"] [_ "unknown"])))
     "(println (color-name :red)) (println (color-name :blue))"
     "Red\nBlue")

   ;; --- let -----------------------------------------------------------------

   (check-clj-output "let binds correctly"
     (list '(defn f [] Int (let [x Int 10 y Int 20] (+ x y))))
     "(println (f))"
     "30")

   (check-clj-output "nested let scoping"
     (list '(defn f [] Int (let [x Int 1] (let [x Int 2] x))))
     "(println (f))"
     "2")

   (check-clj-output "let with map destructuring"
     (list `(defn f [(m (Map Keyword Int))] Int
              (let [,(mt ':keys (br 'a 'b) ':or (mt 'a 0 'b 0)) m]
                (+ a b))))
     "(println (f {:a 10 :b 20}))"
     "30")

   (check-clj-output "let with seq destructuring"
     (list `(defn f [(xs (HVec Int Int Int))] Int
              (let [,(br 'a 'b 'c) xs]
                (+ a (+ b c)))))
     "(println (f [1 2 3]))"
     "6")

   ;; --- cond / if / when / case ---------------------------------------------

   (check-clj-output "cond evaluates correct branch"
     (list '(defn classify [(n Int)] String
              (cond (< n 0) "neg" (= n 0) "zero" :else "pos")))
     "(println (classify -1)) (println (classify 0)) (println (classify 1))"
     "neg\nzero\npos")

   (check-clj-output "if with else"
     (list '(defn abs [(n Int)] Int (if (< n 0) (- 0 n) n)))
     "(println (abs -5)) (println (abs 3))"
     "5\n3")

   (check-clj-output "when runs body on true"
     (list '(defn f [(x Bool)] Nil (when x (println "yes"))))
     "(f true)"
     "yes")

   (check-clj-behavior "when skips body on false"
     (list '(defn f [(x Bool)] Nil (when x (println "yes"))))
     "(f false)")

   (check-clj-output "when-let non-nil runs body"
     (list '(defn f [(x Any)] Nil (when-let [v x] (println v))))
     "(f 42)"
     "42")

   (check-clj-output "if-let selects branch"
     (list '(defn f [(x Any)] String (if-let [v x] "found" "missing")))
     "(println (f 1)) (println (f nil))"
     "found\nmissing")

   (check-clj-output "match with or-pattern matches correct value (was: case)"
     (list '(defn day-type [(d Int)] String
              (match d [(or 0 6) "weekend"] [_ "weekday"])))
     "(println (day-type 0)) (println (day-type 3)) (println (day-type 6))"
     "weekend\nweekday\nweekend")

   ;; --- loop / recur --------------------------------------------------------

   (check-clj-output "loop/recur basic countdown"
     (list '(defn countdown [(n Int)] Int
              (loop [i n] (if (= i 0) i (recur (- i 1))))))
     "(println (countdown 10))"
     "0")

   (check-clj-output "loop/recur accumulator"
     (list '(defn sum-to [(n Int)] Int
              (loop [i n acc 0]
                (if (= i 0) acc (recur (- i 1) (+ acc i))))))
     "(println (sum-to 5))"
     "15")

   (check-clj-output "loop/recur factorial"
     (list '(defn factorial [(n Int)] Int
              (loop [i n acc 1]
                (if (<= i 1) acc (recur (- i 1) (* acc i))))))
     "(println (factorial 5))"
     "120")

   ;; --- for / doseq ---------------------------------------------------------
   ;; dotimes removed — use (doseq [i (range n)] body).

   (check-clj-output "for comprehension"
     (list '(defn double-all [(xs (Vec Int))] (Vec Int)
              (for [x xs] (* x 2))))
     "(println (vec (double-all [1 2 3])))"
     "[2 4 6]")

   (check-clj-output "for with :when"
     (list '(defn positives [(xs (Vec Int))] (Vec Int)
              (for [x xs :when (> x 0)] x)))
     "(println (vec (positives [-1 0 1 2 -3])))"
     "[1 2]")

   (check-clj-output "doseq iterates"
     (list '(defn f [(xs (Vec Int))] Nil (doseq [x xs] (println x))))
     "(f [10 20 30])"
     "10\n20\n30")

   ;; --- higher-order functions ----------------------------------------------

   (check-clj-output "fn as argument"
     (list `(defn apply-twice [(f (Fn ,(br 'Int) Int)) (x Int)] Int (f (f x))))
     "(println (apply-twice inc 5))"
     "7")

   (check-clj-output "anonymous fn"
     '()
     "(println (mapv (fn [x] (* x x)) [1 2 3 4]))"
     "[1 4 9 16]")

   ;; #28: a defn whose `(Fn [A] B)` return is a bracket fn-type must parse as a
   ;; single-arity defn (was mis-parsed as 2-arity defn-multi: the `[params]` + the
   ;; `(Fn [A] B)` return looked like two arity clauses, the marker swallowed as a body).
   (check-clj-output "defn returning a fn via (Fn [Int] Int) (bracket fn-type return)"
     (list `(defn make-adder [(n Int)] (Fn ,(br 'Int) Int)
              (fn [(m Int)] Int (+ n m))))
     "(println ((make-adder 3) 4))"
     "7")

   (check-clj-output "map + filter pipeline"
     '()
     "(println (->> [1 2 3 4 5 6] (filter odd?) (mapv (fn [x] (* x x)))))"
     "[1 9 25]")

   ;; --- threading macros: source-side surface forms -----------------------
   ;;
   ;; The threading family parses to a desugared call/let/if composition
   ;; wrapped in a threading-marker. emit-clj recognises the marker and
   ;; reconstructs the surface threading form (-> / ->> / as-> / cond-> /
   ;; cond->> / some-> / some->>). These tests drive a real beagle threading
   ;; form through parse + emit-clj + babashka to confirm the emitted
   ;; Clojure runs and produces the right value.

   (check-clj-output "thread-last (assertion-only)"
     '()
     "(println (->> [1 2 3 4 5 6] (filter even?) (mapv inc)))"
     "[3 5 7]")

   (check-clj-output "-> surface form executes correctly"
     (list '(defn t-first [(x Int)] Int (-> x (+ 1) (* 2))))
     "(println (t-first 3))"
     "8")

   (check-clj-output "->> surface form executes correctly"
     (list `(defn t-last [] (Vec Int)
              (->> ,(br 1 2 3 4 5 6) (filter even?) (mapv inc))))
     "(println (t-last))"
     "[3 5 7]")

   (check-clj-output "as-> surface form executes correctly"
     (list '(defn t-as [(x Int)] Int
              (as-> x v
                (if (int? v) (+ v 1) 0)
                (if (int? v) (* v 2) 0))))
     "(println (t-as 3))"
     "8")

   (check-clj-output "cond-> surface form executes correctly"
     (list '(defn add-int [(value Any) (delta Int)] Int
              (if (int? value) (+ value delta) 0))
           '(defn t-cond [(x Int) (b Bool)] Int
              (cond-> x b (add-int 10) false (add-int 100))))
     "(println (t-cond 5 true)) (println (t-cond 5 false))"
     "15\n5")

   (check-clj-output "cond->> surface form executes correctly"
     (list '(defn t-cond-last [(xs (Vec Int)) (b Bool)] (Vec Int)
              (cond->> xs b (mapv inc))))
     "(println (t-cond-last [1 2 3] true)) (println (t-cond-last [1 2 3] false))"
     "[2 3 4]\n[1 2 3]")

   (check-clj-output "some-> surface form executes correctly"
     (list '(defn checked-inc [(value Any)] Int
              (if (int? value) (inc value) 0))
           '(defn t-some [(x (U Int Nil))] Any
              (some-> x checked-inc checked-inc)))
     "(println (t-some 5)) (println (t-some nil))"
     "7\nnil")

   (check-clj-output "some->> surface form executes correctly"
     (list '(defn t-some-last [(xs Any)] Any
              (some->> xs (mapv inc))))
     "(println (t-some-last [1 2 3])) (println (t-some-last nil))"
     "[2 3 4]\nnil")

   ;; --- try/catch -----------------------------------------------------------

   (check-clj-output "try/catch returns catch value on error"
     (list '(defn safe-div [(a Int) (b Int)] String
              (try
                (do (/ a b) "ok")
                (catch Exception e "error"))))
     "(println (safe-div 10 2)) (println (safe-div 10 0))"
     "ok\nerror")

   (check-clj-output "try/catch as expression in let"
     (list '(defn f [] Int
              (let [x Int (try 42 (catch Exception e 0))] (+ x 1))))
     "(println (f))"
     "43")

   ;; --- do ------------------------------------------------------------------

   (check-clj-output "do executes in order"
     (list '(defn f [] Nil
              (do (println "first") (println "second") (println "third"))))
     "(f)"
     "first\nsecond\nthird")

   ;; --- atoms ---------------------------------------------------------------

   (check-clj-output "atom + swap! + deref"
     (list '(def counter (atom 0)))
     "(swap! counter inc)
      (swap! counter inc)
      (swap! counter inc)
      (println @counter)"
     "3")

   ;; --- dynamic vars (^:dynamic + binding) ----------------------------------
   ;; Regression (the bug beagle-4 flagged): an earmuff/^:dynamic def used to
   ;; emit a plain `(def *x* …)` with NO ^:dynamic metadata, so `(binding …)`
   ;; over it threw "Can't dynamically bind non-dynamic var" at RUNTIME —
   ;; checks-and-builds, breaks when run. These exercise the emitted clj end
   ;; to end: the `^:dynamic` metadata must reach the var AND beagle's own
   ;; `binding` form must rebind within the dynamic extent, reverting after.
   ;; (Forms are post-reader datums — `^:dynamic` reads as `(#%meta :dynamic …)`;
   ;; the reader macro itself is covered in parse/reader tests.)
   (check-clj-output "^:dynamic var + beagle binding rebinds within extent then reverts"
     (list '(def (#%meta :dynamic *mult*) Int 1)
           '(defn scaled [(n Int)] Int (* n *mult*))
           '(defn scaled-by [(n Int) (m Int)] Int
              (binding [*mult* Int m] (scaled n))))
     "(println (scaled 5))
      (println (scaled-by 5 10))
      (println (scaled 5))"
     "5\n50\n5")

   (check-clj-output "binding rebinds multiple dynamic vars at once"
     (list '(def (#%meta :dynamic *a*) Int 1)
           '(def (#%meta :dynamic *b*) Int 2)
           '(defn combine [] Int
              (binding [*a* Int 10 *b* Int 20] (+ *a* *b*))))
     "(println (combine))"
     "30")

   ;; --- structural binding constraints ------------------------------------

   (check-clj-output "constraints guard params, rest, let, fn, and preserve ex-data"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      '(defn all-positive? [(values (Vec Int))] Bool
         (and (vector? values) (every? positive? values)))
      '(defn constrained-rest
         [(head Int positive?) & (tail (Vec Int) all-positive?)]
         Int
         (+ head (count tail)))
      '(defn constrained-let [(input Int)] Int
         (let [(checked Int positive?) input] checked))
      '(defn constrained-fn [(input Int)] Int
         ((fn [(value Int positive?)] Int value) input))
      ;; The parameter intentionally shadows the global predicate.  The
      ;; constraint expression must be captured before the authored binder.
      '(defn captures-global [(positive? Int positive?)] Int positive?)
      ;; Sibling parameters are simultaneous too: an earlier authored binder
      ;; must not capture the predicate owned by a later declaration.
      '(defn captures-before-sibling
         [(positive? Int) (value Int positive?)]
         Int
         value))
     (string-append
      "(println (constrained-rest 3 4 5))\n"
      "(println (constrained-let 6))\n"
      "(println (constrained-fn 7))\n"
      "(println (captures-global 8))\n"
      "(println (captures-before-sibling 100 9))\n"
      "(let [error (try (constrained-rest -1) nil "
      "                 (catch Exception error error))]\n"
      "  (println (.getMessage error))\n"
      "  (println (= {:binding \"head\" :value -1} (ex-data error))))\n"
      "(doseq [call [(fn [] (constrained-rest 1 -2)) "
      "              (fn [] (constrained-let -3)) "
      "              (fn [] (constrained-fn -4))]]\n"
      "  (try (call) (catch Exception error (println (.getMessage error)))))")
     (string-append
      "5\n6\n7\n8\n9\nBinding constraint failed: head\ntrue\n"
      "Binding constraint failed: tail\n"
      "Binding constraint failed: checked\n"
      "Binding constraint failed: value"))

   (check-clj-output "rest bindings are Vec at every callable boundary"
     (list
      `(defn ordinary-rest
         ,(br '& '(values (Vec Int)))
         Bool
         (vector? values))
      `(defn anonymous-rest [] Bool
         ((fn ,(br '& '(values (Vec Int))) Bool (vector? values)) 1 2))
      `(defn local-rest [] Bool
         (letfn
          ,(br (list 'collect
                     (br '& '(values (Vec Int)))
                     'Bool
                     '(vector? values)))
          (collect 1 2)))
      (list
       'defn
       'multi-rest
       (list (br) 'Bool 'true)
       (list (br '& '(values (Vec Int))) 'Bool '(vector? values)))
      `(defprotocol RestAware
         (rest-vector
          ,(br '(self RestAware) '& '(values (Vec Int)))
          Bool))
      (list 'defrecord 'RestBox (br '(label String)))
      `(extend-type RestBox
         RestAware
         (rest-vector
          ,(br '(self RestBox) '& '(values (Vec Int)))
          Bool
          (vector? values))))
     (string-append
      "(println [(ordinary-rest 1 2) (anonymous-rest) (local-rest) "
      "(multi-rest 1 2) (rest-vector (->RestBox \"r\") 1 2)])")
     "[true true true true true]")

   (check-clj-output "constraint and incoming expressions each evaluate once"
     (list
      '(def factory-calls (Atom Int) (atom 0))
      '(def predicate-calls (Atom Int) (atom 0))
      '(def incoming-calls (Atom Int) (atom 0))
      '(def phase (Atom Int) (atom 0))
      '(defn increment [(value Int)] Int (+ value 1))
      '(defn count-positive! [(value Int)] Bool
         (do (swap! predicate-calls increment) (> value 0)))
      `(defn make-predicate! [] ,(fn-ty '(Int) 'Bool)
         (do (swap! factory-calls increment) count-positive!))
      '(defn next-negative! [] Int
         (do (swap! incoming-calls increment) -1))
      '(defn ordered-value! [] Int (do (reset! phase 1) 2))
      `(defn ordered-predicate! [] ,(fn-ty '(Int) 'Bool)
         (if (= (deref phase) 1)
             count-positive!
             (fn [(value Int)] Bool false)))
      '(defn generated! [(value Int (make-predicate!))] Int value)
      '(defn guarded-rhs! [] Int
         (let [(value Int count-positive!) (next-negative!)] value))
      '(defn ordered! [] Int
         (let [(value Int (ordered-predicate!)) (ordered-value!)] value)))
     (string-append
      "(println (generated! 2))\n"
      "(try (generated! -1) (catch Exception _ nil))\n"
      "(try (guarded-rhs!) (catch Exception _ nil))\n"
      "(println (ordered!))\n"
      "(println [@factory-calls @predicate-calls @incoming-calls])")
     "2\n2\n[2 4 1]")

   (check-clj-output "destructuring constraint sees the aggregate before projection"
     (list
      '(defn positive-point? [(point (HVec Int Int))] Bool
         (and (> (first point) 0) (> (second point) 0)))
      '(defn positive-map? [(value (Map Keyword Int))] Bool
         (> (:x value) 0))
      `(defn point-x
         ,(br (list (br 'x 'y) '(HVec Int Int) 'positive-point?))
         Int
         x)
      `(defn local-y [(point (HVec Int Int))] Int
         (let ,(br (list (br 'x 'y)
                         '(HVec Int Int)
                         'positive-point?)
                    'point)
           y))
      `(defn mapped-x
         ,(br (list (mt ':keys (br 'x))
                    '(Map Keyword Int)
                    'positive-map?))
         Int?
         x))
     (string-append
      "(println (point-x [2 3])) (println (local-y [4 5])) "
      "(println (mapped-x {:x 6}))\n"
      "(doseq [call [(fn [] (point-x [-1 3])) "
      "              (fn [] (local-y [4 -5])) "
      "              (fn [] (mapped-x {:x -6}))]]\n"
      "  (try (call) (catch Exception error (println (.getMessage error)))))")
     (string-append
      "2\n5\n6\nBinding constraint failed: [x y]\n"
      "Binding constraint failed: [x y]\n"
      "Binding constraint failed: {:keys [x]}"))

   (check-clj-output "constraints guard multi-arity, letfn, for, loop/recur, and binding"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      `(defn choose
         ,(list (br '(value Int positive?)) 'Int 'value)
         ,(list (br '(value Int positive?) '(extra Int))
                'Int '(+ value extra)))
      '(defn nested [(value Int)] Int
         (letfn [(accept [(item Int positive?)] Int item)]
           (accept value)))
      '(defn projected [(values (Vec Int))] (Vec Int)
         (for [(value Int positive?) values] value))
      '(defn projected-let [(values (Vec Int))] (Vec Int)
         (for [value values :let [(checked Int positive?) value]] checked))
      '(defn visit! [(values (Vec Int))] Nil
         (doseq [(value Int positive?) values] (println value)))
      '(defn countdown [(start Int)] Int
         (loop [(value Int positive?) start]
           (if (= value 1) value (recur (- value 1)))))
      '(defn nested-tail [(start Int)] Int
         (loop [(outer Int positive?) start]
           (loop [inner outer]
             (if (= inner 0) outer (recur (- inner 1))))))
      '(def (#%meta :dynamic *limit*) Int 1)
      '(defn limited [(value Int)] Int
         (binding [(*limit* Int positive?) value] *limit*)))
     (string-append
      "(println (choose 2)) (println (choose 2 3)) (println (nested 4))\n"
      "(println (vec (projected [5 6])))\n"
      "(println (vec (projected-let [7 8])))\n"
      "(visit! [9 10])\n"
      "(println (countdown 3)) (println (nested-tail 3)) (println (limited 9))\n"
      "(doseq [call [(fn [] (choose 0)) (fn [] (nested -1)) "
      "              (fn [] (vec (projected [1 0]))) "
      "              (fn [] (vec (projected-let [1 -1]))) "
      "              (fn [] (visit! [1 0])) "
      "              (fn [] (countdown 0)) (fn [] (limited -2))]]\n"
      "  (try (call) (catch Exception error (println (.getMessage error)))))")
     (string-append
      "2\n5\n4\n[5 6]\n[7 8]\n9\n10\n1\n3\n9\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: item\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: checked\n"
      "1\nBinding constraint failed: value\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: *limit*"))

   (check-clj-output "record, union, and throwable fields guard all mutation surfaces"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      '(defrecord Score [(value Int positive?) (label String)])
      `(defn change [(score Score) (value Int)] Score
         (with score ,(br ':value 'value)))
      `(defunion Shape (Circle ,(br '(radius Int positive?))))
      `(defunion :throwable Failure (Bad ,(br '(code Int positive?)))))
     (string-append
      "(let [score (->Score 7 \"positional\") "
      "      mapped (map->Score {:value 8 :label \"mapped\"})]\n"
      "  (println (:value score)) (println (:value mapped))\n"
      "  (println (:value (change score 9))))\n"
      "(println (:radius (->Circle 10))) (println (:code (->Bad 11)))\n"
      "(doseq [call [(fn [] (->Score 0 \"bad\")) "
      "              (fn [] (map->Score {:value -1 :label \"bad\"})) "
      "              (fn [] (change (->Score 1 \"ok\") 0)) "
      "              (fn [] (->Circle 0)) (fn [] (->Bad -1))]]\n"
      "  (try (call) (catch Exception error (println (.getMessage error)))))")
     (string-append
      "7\n8\n9\n10\n11\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: value\n"
      "Binding constraint failed: radius\n"
      "Binding constraint failed: code"))

   (check-clj-output "with validates its private candidate before downstream use"
     (list
      '(def target-calls (Atom Int) (atom 0))
      '(def update-calls (Atom Int) (atom 0))
      '(def predicate-calls (Atom Int) (atom 0))
      '(def downstream-calls (Atom Int) (atom 0))
      '(defn increment [(value Int)] Int (+ value 1))
      '(defn positive! [(value Int)] Bool
         (do (swap! predicate-calls increment) (> value 0)))
      '(defrecord GuardedScore [(value Int positive!)])
      '(def initial GuardedScore (->GuardedScore 1))
      '(defn target! [] GuardedScore
         (do (swap! target-calls increment) initial))
      '(defn update! [(value Int)] Int
         (do (swap! update-calls increment) value))
      '(defn consume! [(score GuardedScore)] Int
         (do (swap! downstream-calls increment) (:value score)))
      `(defn update-and-consume! [(value Int)] Int
         (consume!
          (with (target!) ,(br ':value '(update! value))))))
     (string-append
      "(reset! target-calls 0) (reset! update-calls 0) "
      "(reset! predicate-calls 0) (reset! downstream-calls 0)\n"
      "(println (update-and-consume! 2))\n"
      "(try (update-and-consume! 0) "
      "     (catch Exception error (println (.getMessage error))))\n"
      "(println [@target-calls @update-calls "
      "          @predicate-calls @downstream-calls])")
     (string-append
      "2\nBinding constraint failed: value\n[2 2 2 1]"))

   (check-clj-output "with-open validates before projection and still closes on failure"
     (list
      '(def captured (Atom java.net.Socket?) (atom nil))
      '(defn reject-socket! [(value java.net.Socket)] Bool
         (do (reset! captured value) false))
      ;; The binding guard invokes `reject-socket!`, so this boundary is
      ;; effectful and carries the `!` its constraint forces on it.
      '(defn rejected-open! [] Bool
         (with-open
          [(socket java.net.Socket reject-socket!) (java.net.Socket.)]
          true)))
     (string-append
      "(try (rejected-open!) "
      "     (catch Exception error (println (.getMessage error))))\n"
     "(println (.isClosed @captured))")
     "Binding constraint failed: socket\ntrue")

   (check-clj-output "dynamic binding captures every incoming value in pre-binding scope"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      '(def (#%meta :dynamic *first*) Int 1)
      '(def (#%meta :dynamic *second*) Int 2)
      '(defn snapshot [] (Vec Int)
         (binding [(*first* Int positive?) 10
                   (*second* Int positive?) *first*]
           (vector *first* *second*))))
     "(println (snapshot))"
     "[10 1]")

   ;; --- nil -----------------------------------------------------------------

   (check-clj-output "nil? on nil"
     (list '(def x nil))
     "(println (nil? x))"
     "true")

   (check-clj-output "nil? on non-nil"
     '()
     "(println (nil? 42))"
     "false")

   ;; --- letfn ---------------------------------------------------------------

   (check-clj-output "letfn mutual recursion"
     (list '(defn mutual-test [] Bool
              (letfn [(is-even [(n Int)] Bool
                        (if (= n 0) true (is-odd (- n 1))))
                      (is-odd [(n Int)] Bool
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
     (list '(defn greeting [(name String) (age Int)] String
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

   ;; Racket's writer spells VT/BEL/ESC as \v \a \e and Clojure's reader takes
   ;; none of the three, so emitting a string verbatim through ~v can produce a
   ;; file that will not read at all.
   (check-clj-output "control characters emit escapes Clojure can read"
     (list `(def controls ,(list->string
                            (map integer->char '(11 7 27 9 10 13 12 8)))))
     "(println (mapv int controls))"
     "[11 7 27 9 10 13 12 8]")

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
     (list `(defonce config ,(mt ':timeout 30 ':retries 3)))
     "(println (:timeout config))"
     "30")

   ;; --- condp ---------------------------------------------------------------

   (check-clj-output "condp"
     (list '(defn describe-num [(n Int)] String
              (condp = n
                1 "one"
                2 "two"
                3 "three"
                "other")))
     "(println (describe-num 2)) (println (describe-num 99))"
     "two\nother")

   ;; --- if-let / when-let (if-some / when-some removed) ---------------------

   (check-clj-output "if-let with non-nil"
     (list '(defn f [(x Any)] String (if-let [v x] (str "got: " v) "nothing")))
     "(println (f 42)) (println (f nil))"
     "got: 42\nnothing")

   (check-clj-output "when-let with non-nil"
     (list '(defn f [(x Any)] Nil (when-let [v x] (println (str "got: " v)))))
     "(f 42)"
     "got: 42")

   ;; --- if-let / when-let: destructuring + typed binders (#22) --------------
   ;; The binder is bound only in the success branch (temp narrows non-nil first).

   (check-clj-output "if-let with map destructuring binds the keys"
     (list `(defn f [(m (Map Keyword Int))] Int
              (if-let [,(mt ':keys (br 'a 'b) ':or (mt 'a 0 'b 0))
                       (Map Keyword Int)
                       m]
                (+ a b)
                0)))
     "(println (f {:a 3 :b 4}))"
     "7")

   (check-clj-output "when-let with seq destructuring"
     (list `(defn f [(xs (HVec Int Int))] Int?
              (when-let [,(br 'a 'b) (HVec Int Int) xs] (+ a b))))
     "(println (f [10 20]))"
     "30")

   (check-clj-output "if-let with a typed binder (narrows nullable to the annotated type)"
     (list '(defn f [(s String)] Int
              (if-let [(v Int) (parse-long s)] v 0)))
     "(println (f \"42\")) (println (f \"nope\"))"
     "42\n0")

   ;; --- defprotocol + defrecord + extend-type --------------------------------
   ;; deftype removed — decomposed into defrecord (data shape) + extend-type
   ;; (protocol impls). Field access via (:field r) instead of (.-field self).

   (check-clj-output "defprotocol + defrecord + extend-type"
     (list `(defprotocol Greetable
              (greet ,(br '(self Greetable)) String))
           '(defrecord Person [(name String)])
           `(extend-type Person
              Greetable
              (greet ,(br '(self Person)) String
                (str "Hello, " (:name self)))))
     "(println (greet (->Person \"Alice\")))"
     "Hello, Alice")

   (check-clj-output "protocol declaration and impl constraints guard distinct ABI layers"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      '(defn under-ten? [(value Int)] Bool (< value 10))
      `(defprotocol Measurable
         (measure ,(br '(self Measurable) '(declared Int positive?)) Int))
      '(defrecord Meter [(label String)])
      `(extend-type Meter
         Measurable
         (measure ,(br '(self Meter) '(candidate Int under-ten?)) Int
           candidate)))
     (string-append
      "(let [meter (->Meter \"m\")]\n"
      "  (println (measure meter 5))\n"
      "  (doseq [call [(fn [] (measure meter -1)) "
      "                (fn [] (measure meter 12))]]\n"
      "    (try (call) "
      "         (catch Exception error (println (.getMessage error))))))")
     (string-append
      "5\nBinding constraint failed: declared\n"
      "Binding constraint failed: candidate"))

   (check-clj-output "variadic protocol guards its aggregate rest argument"
     (list
      '(defn positive? [(value Int)] Bool (> value 0))
      '(defn all-positive? [(values (Vec Int))] Bool
         (and (vector? values) (every? positive? values)))
      `(defprotocol Collectable
         (collect ,(br '(self Collectable)
                       '&
                       '(values (Vec Int) all-positive?)) Int))
      '(defrecord Bucket [(label String)])
      `(extend-type Bucket
         Collectable
         (collect ,(br '(self Bucket) '& '(items (Vec Int))) Int
           (count items))))
     (string-append
      "(let [bucket (->Bucket \"b\")]\n"
      "  (println (collect bucket 1 2 3))\n"
      "  (try (collect bucket 1 -2) "
      "       (catch Exception error (println (.getMessage error)))))")
     "3\nBinding constraint failed: values")

   (check-linked-clj-output
    "cross-module protocol keeps declaration and impl constraint layers"
    'constraints.protocol
    (list
     '(defn positive? [(value Int)] Bool (> value 0))
     `(defprotocol Measurable
        (measure ,(br '(self Measurable) '(declared Int positive?)) Int)))
    'constraints.protocol-impl
    (list
     `(require ,(br 'constraints.protocol ':as 'p))
     '(defn under-ten? [(value Int)] Bool (< value 10))
     '(defrecord Meter [(label String)])
     `(extend-type Meter
        p/Measurable
        (measure ,(br '(self Meter) '(candidate Int under-ten?)) Int
          candidate)))
    (string-append
     "(require '[constraints.protocol :as p])\n"
     "(require '[constraints.protocol-impl :as impl])\n"
     "(let [meter (impl/->Meter \"m\")]\n"
     "  (println (p/measure meter 5))\n"
     "  (doseq [call [(fn [] (p/measure meter -1)) "
     "                (fn [] (p/measure meter 12))]]\n"
     "    (try (call) "
     "         (catch Exception error (println (.getMessage error))))))")
    (string-append
     "5\nBinding constraint failed: declared\n"
     "Binding constraint failed: candidate"))

   (check-linked-clj-output
    "cross-module with calls the provider-owned record validator"
    'constraints.records
    (list
     '(defn positive? [(value Int)] Bool (> value 0))
     '(defrecord Score [(value Int positive?) (label String)]))
    'constraints.record-user
    (list
     `(require ,(br 'constraints.records ':as 'records))
     `(defn change [(score records/Score) (value Int)] records/Score
        (with score ,(br ':value 'value))))
    (string-append
     "(require '[constraints.records :as records])\n"
     "(require '[constraints.record-user :as user])\n"
     "(let [score (records/->Score 7 \"ok\")]\n"
     "  (println (:value (user/change score 8)))\n"
     "  (try (user/change score -1) "
     "       (catch Exception error (println (.getMessage error)))))")
    "8\nBinding constraint failed: value")

   (check-linked-clj-output
    "referred record with calls the provider-owned record validator"
    'constraints.referred-records
    (list
     '(defn positive? [(value Int)] Bool (> value 0))
     '(defrecord Score [(value Int positive?) (label String)]))
    'constraints.referred-record-user
    (list
     `(require
       ,(br 'constraints.referred-records ':refer (br 'Score '->Score)))
     `(defn change [(score Score) (value Int)] Score
        (with score ,(br ':value 'value))))
    (string-append
     "(require '[constraints.referred-records :refer [->Score]])\n"
     "(require '[constraints.referred-record-user :as user])\n"
     "(let [score (->Score 7 \"ok\")]\n"
     "  (println (:value (user/change score 8)))\n"
     "  (try (user/change score -1) "
     "       (catch Exception error (println (.getMessage error)))))")
    "8\nBinding constraint failed: value")

   (check-linked-clj-output
    "qualified record pattern resolves structural provider identity"
    'models.widgets
    (list '(defrecord Widget [(label String)]))
    'models.widget-user
    (list
     `(require ,(br 'models.widgets ':as 'models))
     `(defn label-of [(value Any)] Any
        (match value
          ,(br '(models/Widget label) 'label)
          ,(br '_ 'nil))))
    (string-append
     "(require '[models.widgets :as models])\n"
     "(require '[models.widget-user :as user])\n"
     "(println (user/label-of (models/->Widget \"ready\")))\n"
     "(println (user/label-of 0))")
    "ready\nnil")

   (check-clj-output "defrecord + extend-type with multiple methods"
     (list `(defprotocol Shape
              (area ,(br '(self Shape)) Int)
              (perimeter ,(br '(self Shape)) Int))
           '(defrecord Rect [(w Int) (h Int)])
           `(extend-type Rect
              Shape
              (area ,(br '(self Rect)) Int
                (* (:w self) (:h self)))
              (perimeter ,(br '(self Rect)) Int
                (* 2 (+ (:w self) (:h self))))))
     "(let [r (->Rect 3 4)]
        (println (area r))
        (println (perimeter r)))"
     "12\n14")

   ;; --- extend-type ----------------------------------------------------------

   (check-clj-output "extend-type on defrecord"
     (list '(defrecord Circle [(radius Int)])
           `(defprotocol Describable
              (describe ,(br '(self Describable)) String))
           `(extend-type Circle
              Describable
              (describe ,(br '(self Circle)) String
                (str "circle r=" (circle-radius self)))))
     "(println (describe (->Circle 5)))"
     "circle r=5")

   (check-clj-output "extend-type multiple types"
     (list '(defrecord Dog [(name String)])
           '(defrecord Cat [(name String)])
           `(defprotocol Speaker
              (speak ,(br '(self Speaker)) String))
           `(extend-type Dog
              Speaker
              (speak ,(br '(self Dog)) String
                (str (dog-name self) " says woof")))
           `(extend-type Cat
              Speaker
              (speak ,(br '(self Cat)) String
                (str (cat-name self) " says meow"))))
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

   ;; --- defprotocol / defrecord / extend-type edge cases -----------------------

   (check-clj-output "defrecord + extend-type implementing multiple protocols"
     (list `(defprotocol Printable
              (to-string ,(br '(self Printable)) String))
           `(defprotocol Measurable
              (size ,(br '(self Measurable)) Int))
           '(defrecord Box [(label String) (items Int)])
           `(extend-type Box
              Printable
              (to-string ,(br '(self Box)) String
                (str "Box(" (:label self) ")"))
              Measurable
              (size ,(br '(self Box)) Int
                (:items self))))
     "(let [b (->Box \"stuff\" 42)]
        (println (to-string b))
        (println (size b)))"
     "Box(stuff)\n42")

   (check-clj-output "protocol method with multiple parameters"
     (list `(defprotocol Combinable
              (combine ,(br '(self Combinable) '(other String) '(sep String)) String))
           '(defrecord Tag [(value String)])
           `(extend-type Tag
              Combinable
              (combine ,(br '(self Tag) '(other String) '(sep String)) String
                (str (:value self) sep other))))
     "(let [t (->Tag \"hello\")]
        (println (combine t \"world\" \"-\"))
        (println (combine t \"there\" \":\")))"
     "hello-world\nhello:there")

   (check-clj-output "extend-type on String (built-in JVM type)"
     (list `(defprotocol Reversible
              (rev ,(br '(self Reversible)) String))
           `(extend-type String
              Reversible
              (rev ,(br '(self String)) String
                (clojure.string/reverse self))))
     "(println (rev \"abcde\"))
      (println (rev \"racecar\"))"
     "edcba\nracecar")

   (check-clj-output "defrecord with no protocols (plain fields)"
     (list '(defrecord Pair [(fst Int) (snd Int)]))
     "(let [p (->Pair 10 20)]
        (println (:fst p))
        (println (:snd p))
        (println (+ (:fst p) (:snd p))))"
     "10\n20\n30")

   (check-clj-output "self-referential protocol (method returns protocol type)"
     (list `(defprotocol Incrementable
              (inc-val ,(br '(self Incrementable)) Incrementable))
           '(defrecord Counter [(n Int)])
           `(extend-type Counter
              Incrementable
              (inc-val ,(br '(self Counter)) Counter
                (->Counter (+ (:n self) 1)))))
     "(let [c0 (->Counter 0)
            c1 (inc-val c0)
            c2 (inc-val c1)
            c3 (inc-val c2)]
        (println (:n c0))
        (println (:n c1))
        (println (:n c2))
        (println (:n c3)))"
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
               (clj-emit (append (list (list 'ns mod-ns))
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
              '(defn square [(n Int)] Int (* n n)))
        (list 'app.main
              '(defn compute [(x Int)] Int (+ x 1))))
       "(require '[mathlib.core :as mc])
        (require '[app.main :as app])
        (println (mc/square 7))
        (println (app/compute 9))"
       "49\n10")

     ;; Test 2: record across modules — A defines a defrecord, B constructs/accesses it
     (check-multi-module "multi-module: record across modules"
       (list
        (list 'models.point
              '(defrecord Point [(x Int) (y Int)]))
        (list 'geo.ops
              '(defn origin-distance [(x Int) (y Int)] Int (+ (* x x) (* y y)))))
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
              '(defn double [(n Int)] Int (* n 2)))
        (list 'mid.transform
              '(defn quad [(n Int)] Int (* n 4)))
        (list 'top.app
              '(defn process [(n Int)] Int (+ n 100))))
       "(require '[base.math :as bm])
        (require '[mid.transform :as mt])
        (require '[top.app :as ta])
        (println (bm/double 5))
        (println (mt/quad 5))
        (println (ta/process 5))
        (println (mt/quad (bm/double 3)))"
       "10\n20\n105\n24")

     ;; --- 2026-06-12 surface hardening regressions ------------------------

     ;; :or defaults must survive to emitted Clojure (were silently dropped
     ;; → runtime NPE from valid Clojure).
     (check-clj-output ":or destructure defaults apply at runtime"
       (list (list 'defn 'f
                   (br (list (mt ':keys (br 'a 'b) ':or (mt 'a 0 'b 2))
                             '(Map Keyword Int)))
                   'Int
                   (list '+ 'a 'b))
             (list 'println (list 'f (mt ':a 1))))
       "" "3")

     ;; :as after :or (both were dropped when :or preceded :as).
     (check-clj-output ":as binding after :or"
       (list (list 'defn 'g
                   (br (list (mt ':keys (br 'a) ':or (mt 'a 1) ':as 'm)
                             '(Map Keyword Int)))
                   'Int
                   (list 'count 'm))
             (list 'println (list 'g (mt ':a 5 ':b 6))))
       "" "2")

     ;; defn docstrings carry through to the emitted defn.
     (check-clj-output "defn docstring lands on the emitted var"
       (list (list 'defn 'greet "Returns a greeting." (br 'name)
                   'String
                   (list 'str "hi " 'name)))
       "(println (:doc (meta #'greet)))"
       "Returns a greeting.")

     ;; def docstrings: typed def-form now, not a call-form passthrough.
     (check-clj-output "def docstring emits valid clojure def"
       (list (list 'def 'version "The version." "1.0.0")
             (list 'println 'version))
       "" "1.0.0")

     ;; Nested sequential destructure round-trips.
     (check-clj-output "nested seq destructure in let"
       (list (list 'defn 'nested-sum
                   (br (list 'input '(HVec Int (HVec Int Int))))
                   'Int
                   (list 'let
                         (br (br 'a (br 'b 'c)) 'input)
                         (list '+ 'a 'b 'c))))
       "(println (nested-sum [1 [2 3]]))" "6")

     (check-clj-output "doseq pair destructure over a map"
       (list (list 'doseq (br (br 'k 'v) (mt ':a 1))
                   (list 'println 'k 'v)))
       "" ":a 1")

     ;; Variadic→fixed-arity subsumption: (mapv str xs) was a false type
     ;; error before 2026-06-12.
     (check-clj-output "variadic str accepted in mapv fn position"
       (list (list 'prn (list 'mapv 'str (br 1 2))))
       "" "[\"1\" \"2\"]")

     ;; Defrecord fields use the same structural typed-binding grammar.
     (check-clj-output "defrecord structural field annotations"
       (list (list 'defrecord 'Pt (br (list 'x 'Int) (list 'y 'Int)))
             (list 'println (list ':y (list '->Pt 1 2))))
       "" "2")

     ;; Backslash regex literals must survive to bb (2026-06-12: emitted
     ;; (re-pattern "\d{4}") — invalid escapes; crashed at read).
     (check-clj-output "backslash regex literal round-trips and matches"
       (list (list 'println
                   (list 'second
                         (list 're-find (list '#%regex "(\\d{4})-(\\d{2})")
                               "on 2026-06-12 ok"))))
       "" "2026")

     ;; Nil-narrowing end-to-end: the guarded nullable type-checks AND the
     ;; emitted Clojure computes correctly under bb (2026-06-12).
     (check-clj-output "nil-narrowing: guarded Float? runs correctly"
       (list (list 'defn 'f (br (list 'v 'Float?)) 'String
                   (list 'if (list 'nil? 'v)
                         "none"
                         (list 'str (list 'long (list 'Math/floor 'v)))))
             (list 'println (list 'f 2.7) (list 'f 'nil)))
       "" "2 none")

     (check-clj-output "nil-narrowing: parse-long guarded via if-let"
       (list (list 'defn 'f (br (list 's 'String)) 'Int
                   (list 'if-let (br 'n (list 'parse-long 's)) 'n 0))
             (list 'println (list 'f "42") (list 'f "nope")))
       "" "42 0")

     (void))

)))
