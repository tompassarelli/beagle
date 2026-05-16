#lang racket/base

(require rackunit
         racket/string
         "../private/parse.rkt"
         "../private/emit.rkt")

(require "../private/types.rkt")

(define (compile . forms)
  (emit-program
   (parse-program (map (lambda (f) (datum->syntax #f f)) forms))))

(define (matches? rx out) (regexp-match? rx out))

(define (br . xs) (cons BRACKET-TAG xs))

(test-case "ns declaration"
  (define out (compile '(def x 1)))
  (check-true (matches? #rx"\\(ns beagle\\.user\\)" out)))

(test-case "namespace override"
  (define out (compile '(ns foo.bar) '(def x 1)))
  (check-true (matches? #rx"\\(ns foo\\.bar\\)" out)))

(test-case "def emits and drops type annotation"
  (define out (compile '(def greeting : String "hello")))
  (check-true (matches? #rx"\\(def greeting \"hello\"\\)" out)))

(test-case "defn drops types but emits arg vector"
  (define out (compile '(defn add [(x : Long) (y : Long)] : Long (+ x y))))
  (check-true (matches? #rx"\\(defn add \\[x y\\]" out))
  (check-true (matches? #rx"\\(\\+ x y\\)"            out)))

(test-case "let emits with brackets"
  (define out (compile '(def y (let [x 1 y 2] (+ x y)))))
  (check-true (matches? #rx"\\(let \\[" out)))

(test-case "if with and without else"
  (define a (compile '(def y (if true 1 2))))
  (define b (compile '(def y (if true 1))))
  (check-true (matches? #rx"\\(if true 1 2\\)" a))
  (check-true (matches? #rx"\\(if true 1\\)"  b)))

(test-case "cond emits as Clojure cond"
  (define out (compile `(def y (cond ,(br 'true 1) ,(br 'false 2)))))
  (check-true (matches? #rx"\\(cond" out))
  (check-true (matches? #rx"true 1"  out))
  (check-true (matches? #rx"false 2" out)))

(test-case "when emits"
  (define out (compile '(def y (when true 1))))
  (check-true (matches? #rx"\\(when true" out)))

(test-case "do emits"
  (define out (compile '(def y (do 1 2 3))))
  (check-true (matches? #rx"\\(do" out)))

(test-case "fn emits"
  (define out (compile '(def f (fn [x] (inc x)))))
  (check-true (matches? #rx"\\(fn \\[x\\]" out)))

(test-case "vector literal emits with brackets"
  (define out (compile `(def xs ,(br 1 2 3))))
  (check-true (matches? #rx"\\[1 2 3\\]" out)))

(test-case "function call emits"
  (define out (compile '(def y (add 1 2))))
  (check-true (matches? #rx"\\(add 1 2\\)" out)))

(test-case "boolean literals render Clojure-style"
  (define a (compile '(def y true)))
  (define b (compile '(def y false)))
  (check-true (matches? #rx"\\(def y true\\)"  a))
  (check-true (matches? #rx"\\(def y false\\)" b)))

;; Racket-style #t/#f map to Clojure true/false too
(test-case "Racket #t / #f render as Clojure true / false"
  (define a (compile '(def y #t)))
  (define b (compile '(def y #f)))
  (check-true (matches? #rx"\\(def y true\\)"  a))
  (check-true (matches? #rx"\\(def y false\\)" b)))

(test-case "unsafe block emitted verbatim"
  (define out (compile '(unsafe "(defn h [] :ok)")))
  (check-true (matches? #rx"\\(defn h \\[\\] :ok\\)" out)))

(test-case "unsafe preserves square brackets"
  (define out (compile '(unsafe "(d/q '[:find ?n :where [?e :name ?n]] @conn)")))
  (check-true (matches? #rx"\\[:find \\?n :where \\[\\?e :name \\?n\\]\\]" out)))

(test-case "inline unsafe emits inside an expression"
  (define out (compile '(def x (+ 1 (unsafe "(double sum)") 2))))
  (check-true (matches? #rx"\\(\\+ 1 \\(double sum\\) 2\\)" out))
  ;; Must NOT emit (unsafe ...) as a Clojure call:
  (check-false (matches? #rx"\\(unsafe " out)))

;; --- macro expansion shows up in emitted code ------------------------------

(test-case "safe macro expansion emits as direct Clojure"
  (define out (compile
               '(define-macro safe inc1 (x) (+ x 1))
               '(defn use [n] (inc1 n))))
  (check-true (matches? #rx"\\(\\+ n 1\\)" out)))

(test-case "unsafe macro emission renders inside expr position"
  (define out (compile
               '(define-macro unsafe wild (x) (do (println "trace") x))
               '(defn use [n] (wild (inc n)))))
  ;; The do form should appear inside the defn body
  (check-true (matches? #rx"\\(do" out))
  (check-true (matches? #rx"\\(inc n\\)" out)))

;; --- require emits in ns form ---------------------------------------------

(test-case "require with alias emits in ns :require"
  (define out (compile '(require beagle.example.helpers :as h)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx"\\[beagle\\.example\\.helpers :as h\\]" out)))

(test-case "require without alias emits bare"
  (define out (compile '(require beagle.helpers)
                       '(def x 1)))
  (check-true (matches? #rx"\\[beagle\\.helpers\\]" out)))

(test-case "clojure namespace require emits in ns :require"
  (define out (compile '(require clojure.string :as str)
                       '(def x (str/upper-case "hi"))))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"str/upper-case" out)))

(test-case "multiple clojure requires emit correctly"
  (define out (compile '(require clojure.string :as str)
                       '(require clojure.set :as cset)
                       '(def x 1)))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[clojure\\.set :as cset\\]" out)))

;; --- regex literal ---------------------------------------------------------

(test-case "regex literal emits as Clojure regex"
  (define out (compile '(def x (#%regex "\\s+"))))
  (check-true (matches? #rx"#\"\\\\s\\+\"" out)))

(test-case "regex in function call emits correctly"
  (define out (compile '(require clojure.string :as str)
                       '(def x (str/split "a b" (#%regex "\\s+")))))
  (check-true (matches? #rx"str/split" out))
  (check-true (matches? #rx"#\"\\\\s\\+\"" out)))

;; --- declare-extern does not emit code ------------------------------------

(test-case "declare-extern is a type-only declaration; emits nothing"
  (define out (compile `(declare-extern foo ,(br 'Long '-> 'Long))
                       '(def x 1)))
  (check-false (matches? #rx"foo" out)))

;; --- macro &rest with splice emits correctly -------------------------------

(test-case "macro &rest with splice emits as expected Clojure call"
  (define out (compile
               '(define-macro safe call-it (f & args) (f (splice args)))
               '(defn use [] (call-it + 1 2 3))))
  (check-true (matches? #rx"\\(\\+ 1 2 3\\)" out)))

;; --- loop/recur emits as Clojure loop/recur --------------------------------

(test-case "loop/recur emits"
  (define out (compile
               '(def x (loop [acc 0 n 10]
                  (if (= n 0) acc (recur (+ acc n) (- n 1)))))))
  (check-true (matches? #rx"\\(loop \\[acc 0" out))
  (check-true (matches? #rx"\\(recur \\(\\+ acc n\\)" out)))

;; --- for emits as Clojure for -----------------------------------------------

(test-case "for comprehension emits"
  (define out (compile
               '(def xs (for [x (range 10) y (range x)]
                  (+ x y)))))
  (check-true (matches? #rx"\\(for \\[x \\(range 10\\)" out))
  (check-true (matches? #rx"y \\(range x\\)" out))
  (check-true (matches? #rx"\\(\\+ x y\\)" out)))

(test-case "for with :when emits"
  (define out (compile
               '(def xs (for [x (range 10) :when (> x 5)] x))))
  (check-true (matches? #rx"\\(for" out))
  (check-true (matches? #rx":when" out)))

;; --- macro hygiene in emitted code ----------------------------------------

(test-case "safe macro hygiene: emitted let doesn't shadow outer binding"
  (define out (compile
               '(define-macro safe with-temp (val body) (let [x val] body))
               '(def y (let [x 42] (with-temp 1 x)))))
  (check-true (matches? #rx"\\(let \\[x 42\\]" out))
  (check-false (matches? #rx"\\(let \\[x 1\\]" out)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord emits Clojure defrecord plus accessors"
  (define out (compile `(defrecord Employee ,(br '(name : String) '(rate : Long)))))
  (check-true (matches? #rx"\\(defrecord Employee \\[name rate\\]\\)" out))
  (check-true (matches? #rx"\\(defn employee-name \\[r\\] \\(:name r\\)\\)" out))
  (check-true (matches? #rx"\\(defn employee-rate \\[r\\] \\(:rate r\\)\\)" out)))

;; --- Java interop ------------------------------------------------------------

(test-case "dot-method emits as (.method target args)"
  (define out (compile '(def x (.trim s))))
  (check-true (matches? #rx"\\(\\.trim s\\)" out)))

(test-case "dot-method with args emits correctly"
  (define out (compile '(def x (.startsWith s "http"))))
  (check-true (matches? #rx"\\(\\.startsWith s \"http\"\\)" out)))

(test-case "static method emits as (Class/method args)"
  (define out (compile '(def x (System/getProperty "user.home"))))
  (check-true (matches? #rx"\\(System/getProperty \"user\\.home\"\\)" out)))

(test-case "dynamic var emits as *name*"
  (define out (compile '(def x (first *command-line-args*))))
  (check-true (matches? #rx"\\*command-line-args\\*" out)))

;; --- map literals ------------------------------------------------------------

(define MT MAP-TAG)
(define (mt . xs) (cons MT xs))

(test-case "map literal emits as Clojure map"
  (define out (compile `(def m ,(mt ':a 1 ':b 2))))
  (check-true (matches? #rx"\\{:a 1 :b 2\\}" out)))

(test-case "empty map literal emits"
  (define out (compile `(def m ,(mt))))
  (check-true (matches? #rx"\\{\\}" out)))

(test-case "nested map in vector emits"
  (define out (compile `(def xs ,(br (mt ':a 1)))))
  (check-true (matches? #rx"\\[\\{:a 1\\}\\]" out)))

;; --- set literals ------------------------------------------------------------

(define ST SET-TAG)
(define (st . xs) (cons ST xs))

(test-case "set literal emits as Clojure set"
  (define out (compile `(def s ,(st 1 2 3))))
  (check-true (matches? #rx"#\\{1 2 3\\}" out)))

(test-case "empty set literal emits"
  (define out (compile `(def s ,(st))))
  (check-true (matches? #rx"#\\{\\}" out)))

;; --- import ------------------------------------------------------------------

(test-case "import emits :import in ns form"
  (define out (compile '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

(test-case "multiple imports emit correctly"
  (define out (compile '(import java.io.File)
                       '(import java.util.ArrayList)
                       '(def x 1)))
  (check-true (matches? #rx"\\[java\\.io File\\]" out))
  (check-true (matches? #rx"\\[java\\.util ArrayList\\]" out)))

(test-case "import with require emits both"
  (define out (compile '(require clojure.string :as str)
                       '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

;; --- try/catch/finally -------------------------------------------------------

(test-case "try/catch emits as Clojure try/catch"
  (define out (compile '(def x (try (/ 1 0) (catch Exception e (str e))))))
  (check-true (matches? #rx"\\(try" out))
  (check-true (matches? #rx"\\(catch Exception e" out))
  (check-true (matches? #rx"\\(str e\\)" out)))

(test-case "try/catch/finally emits all parts"
  (define out (compile '(def x (try (risky) (catch Exception e "err") (finally (cleanup))))))
  (check-true (matches? #rx"\\(try" out))
  (check-true (matches? #rx"\\(catch Exception e" out))
  (check-true (matches? #rx"\\(finally" out))
  (check-true (matches? #rx"\\(cleanup\\)" out)))

(test-case "try with multiple catches emits both"
  (define out (compile '(def x (try (risky)
    (catch ArithmeticException e "math")
    (catch Exception e "other")))))
  (check-true (matches? #rx"ArithmeticException" out))
  (check-true (matches? #rx"Exception e" out)))

;; --- doseq -------------------------------------------------------------------

(test-case "doseq emits as Clojure doseq"
  (define out (compile '(doseq [x (range 10)] (println x))))
  (check-true (matches? #rx"\\(doseq \\[x \\(range 10\\)\\]" out))
  (check-true (matches? #rx"\\(println x\\)" out)))

(test-case "doseq with :when emits"
  (define out (compile '(doseq [x (range 10) :when (even? x)] (println x))))
  (check-true (matches? #rx"\\(doseq" out))
  (check-true (matches? #rx":when" out)))

;; --- case --------------------------------------------------------------------

(test-case "case emits as Clojure case"
  (define out (compile '(def y (case x "a" 1 "b" 2 "default"))))
  (check-true (matches? #rx"\\(case x" out))
  (check-true (matches? #rx"\"a\" 1" out))
  (check-true (matches? #rx"\"b\" 2" out))
  (check-true (matches? #rx"\"default\"" out)))

(test-case "case without default emits"
  (define out (compile '(def y (case x 1 "one" 2 "two"))))
  (check-true (matches? #rx"\\(case x" out))
  (check-true (matches? #rx"1 \"one\"" out))
  (check-true (matches? #rx"2 \"two\"" out)))

;; --- constructor calls -------------------------------------------------------

(test-case "constructor call emits as Clojure constructor"
  (define out (compile '(def f (File. "/tmp"))))
  (check-true (matches? #rx"\\(File\\. \"/tmp\"\\)" out)))

(test-case "constructor with no args emits"
  (define out (compile '(def x (ArrayList.))))
  (check-true (matches? #rx"\\(ArrayList\\.\\)" out)))

(test-case "constructor with multiple args emits"
  (define out (compile '(def p (Point. 10 20))))
  (check-true (matches? #rx"\\(Point\\. 10 20\\)" out)))

;; --- keyword-as-function ---------------------------------------------------

(test-case "keyword access emits"
  (define out (compile '(def x (:name m))))
  (check-true (matches? #rx"\\(:name m\\)" out)))

(test-case "keyword access with default emits"
  (define out (compile '(def x (:age m "unknown"))))
  (check-true (matches? #rx"\\(:age m \"unknown\"\\)" out)))

(test-case "namespaced keyword access emits"
  (define out (compile '(def x (:db/ident schema))))
  (check-true (matches? #rx"\\(:db/ident schema\\)" out)))

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol emits"
  (define out (compile `(defprotocol Greetable
                          (greet ,(br '(self : Any)) : String))))
  (check-true (matches? #rx"defprotocol Greetable" out))
  (check-true (matches? #rx"\\(greet \\[self\\]\\)" out)))

;; --- defmulti / defmethod ---------------------------------------------------

(test-case "defmulti emits"
  (define out (compile '(defmulti greeting :lang)))
  (check-true (matches? #rx"\\(defmulti greeting :lang\\)" out)))

(test-case "defmethod emits"
  (define out (compile `(defmulti greeting :lang)
                       `(defmethod greeting :en ,(br 'x) "hello")))
  (check-true (matches? #rx"\\(defmethod greeting :en \\[x\\]" out))
  (check-true (matches? #rx"\"hello\"" out)))

;; --- destructuring ----------------------------------------------------------

(define (mp . xs) (cons MAP-TAG xs))

(test-case "map destructure in params emits"
  (define out (compile `(defn process ,(br (mp ':keys (br 'name 'age))) (println name))))
  (check-true (matches? #rx"\\{:keys \\[name age\\]\\}" out)))

(test-case "map destructure with :as emits"
  (define out (compile `(defn process ,(br (mp ':keys (br 'x 'y) ':as 'm)) (println x))))
  (check-true (matches? #rx"\\{:keys \\[x y\\] :as m\\}" out)))

(test-case "map destructure in let emits"
  (define out (compile `(let ,(br (mp ':keys (br 'x 'y)) 'point) (+ x y))))
  (check-true (matches? #rx"\\{:keys \\[x y\\]\\} point" out)))

;; --- sequential destructuring ------------------------------------------------

(test-case "sequential destructure in params emits"
  (define out (compile `(defn process ,(br (br 'a 'b 'c)) (println a))))
  (check-true (matches? #rx"\\[a b c\\]" out)))

(test-case "sequential destructure with & rest emits"
  (define out (compile `(defn process ,(br (br 'a 'b '& 'rest)) (println a))))
  (check-true (matches? #rx"\\[a b & rest\\]" out)))

(test-case "sequential destructure in let emits"
  (define out (compile `(let ,(br (br 'a 'b) 'coll) (+ a b))))
  (check-true (matches? #rx"\\[a b\\] coll" out)))

;; --- deftype / extend-type ---------------------------------------------------

(test-case "deftype emits"
  (define out (compile `(deftype Point ,(br '(x : Long) '(y : Long))
                          Printable
                          (to-string ,(br '(self : Any)) (str x y)))))
  (check-true (matches? #rx"\\(deftype Point \\[x y\\]" out))
  (check-true (matches? #rx"Printable" out))
  (check-true (matches? #rx"\\(to-string \\[self\\]" out)))

(test-case "deftype without impls emits"
  (define out (compile `(deftype Pair ,(br '(fst : Any) '(snd : Any)))))
  (check-true (matches? #rx"\\(deftype Pair \\[fst snd\\]\\)" out)))

(test-case "extend-type emits"
  (define out (compile `(extend-type String
                          Showable
                          (show ,(br '(self : String)) (str self)))))
  (check-true (matches? #rx"\\(extend-type String" out))
  (check-true (matches? #rx"Showable" out))
  (check-true (matches? #rx"\\(show \\[self\\]" out)))

;; --- threading macros pass through -------------------------------------------

(test-case "-> emits as Clojure threading"
  (define out (compile '(def x (-> m :name))))
  (check-true (matches? #rx"\\(-> m :name\\)" out)))

(test-case "->> emits correctly"
  (define out (compile '(def x (->> coll (map inc) (filter even?)))))
  (check-true (matches? #rx"\\(->> coll \\(map inc\\) \\(filter even\\?\\)\\)" out)))

;; --- expression-level source mapping ----------------------------------------

(define BT BRACKET-TAG)
(define (located d src line)
  (datum->syntax #f d (vector src line 0 #f #f)))

(test-case "expression-level: inner call gets per-expression metadata"
  (define src "test.rkt")
  (define body-stx (located '(+ x 1) src 2))
  (define params-stx (located (list BT 'x) src 1))
  (define form-stx (located (list 'defn 'f params-stx body-stx) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\^\\{:line 1 :file \"test\\.rkt\"\\} \\(defn" out))
  (check-true (matches? #rx"\\^\\{:line 2 :file \"test\\.rkt\"\\} \\(\\+ x 1\\)" out)))

(test-case "expression-level: atoms don't get metadata"
  (define src "test.rkt")
  (define form-stx (located '(def x 42) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-false (matches? #rx"\\^\\{.*\\} 42" out)))

(test-case "expression-level: let value expressions get metadata"
  (define src "test.rkt")
  (define value-stx (located '(+ 1 2) src 3))
  (define bindings-stx (located (list BT 'x value-stx) src 2))
  (define body-stx (located '(inc x) src 4))
  (define form-stx (located (list 'def 'y (list 'let bindings-stx body-stx)) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\^\\{:line 3 :file \"test\\.rkt\"\\} \\(\\+ 1 2\\)" out))
  (check-true (matches? #rx"\\^\\{:line 4 :file \"test\\.rkt\"\\} \\(inc x\\)" out)))

(test-case "expression-level: src-table is populated"
  (define src "test.rkt")
  (define body-stx (located '(+ x 1) src 2))
  (define params-stx (located (list BT 'x) src 1))
  (define form-stx (located (list 'defn 'f params-stx body-stx) src 1))
  (define prog (parse-program (list form-stx)))
  (check-true (> (hash-count (program-src-table prog)) 0)))

(test-case "expression-level: no metadata when syntax has no source location"
  (define out (compile '(defn f [x] (+ x 1))))
  (check-false (matches? #rx"\\^\\{" out)))
