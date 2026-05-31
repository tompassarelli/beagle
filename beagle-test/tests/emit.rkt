#lang racket/base

(require rackunit
         racket/string
         beagle/private/parse
         beagle/private/emit)

(require beagle/private/types)

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

(test-case "def with claim emits ^Type tag"
  (define out (compile `(claim greeting String)
                       '(def greeting "hello")))
  (check-true (matches? #rx"\\(def \\^String greeting \"hello\"\\)" out)))

(test-case "defn drops param types but emits arg vector"
  (define out (compile '(defn add [(x : Int) (y : Int)] (+ x y))))
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

;; when removed — interim (if c body) / (if c (do b1 b2 …)) pattern; covered
;; by general if + do emit tests.

(test-case "do emits"
  (define out (compile '(def y (do 1 2 3))))
  (check-true (matches? #rx"\\(do" out)))

(test-case "fn emits"
  (define out (compile '(def f (fn [x] (+ x 1)))))
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

(test-case "unsafe-clj is rejected at parse time"
  (check-exn (lambda (e) (and (exn:fail? e)
                              (regexp-match? #rx"escape hatches are not available"
                                             (exn-message e))))
             (lambda () (compile '(unsafe-clj "(defn h [] :ok)")))))

;; --- macro expansion shows up in emitted code ------------------------------

(test-case "safe macro expansion emits as direct Clojure"
  (define out (compile
               `(defmacro inc1 ,(br 'x) (+ x 1))
               '(defn use [n] (inc1 n))))
  (check-true (matches? #rx"\\(\\+ n 1\\)" out)))

(test-case "legacy (define-macro …) is rejected — points at defmacro"
  (check-exn (lambda (e) (and (exn:fail? e)
                              (regexp-match? #rx"define-macro.*defmacro"
                                             (exn-message e))))
             (lambda () (compile '(define-macro unsafe wild (x) (do (println "trace") x))))))

;; --- require emits in ns form ---------------------------------------------

(test-case "require with alias emits in ns :require"
  (define out (compile '(require beagle.example.helpers :as h)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx"\\[beagle\\.example\\.helpers :as h\\]" out)))

(test-case "require without alias emits :as with module name"
  (define out (compile '(require beagle.helpers)
                       '(def x 1)))
  (check-true (matches? #rx"\\[beagle\\.helpers :as helpers\\]" out)))

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
  (check-true (matches? #rx"\\(re-pattern \"\\\\s\\+\"\\)" out)))

(test-case "regex in function call emits correctly"
  (define out (compile '(require clojure.string :as str)
                       '(def x (str/split "a b" (#%regex "\\s+")))))
  (check-true (matches? #rx"str/split" out))
  (check-true (matches? #rx"\\(re-pattern \"\\\\s\\+\"\\)" out)))

;; --- declare-extern does not emit code ------------------------------------

(test-case "declare-extern is a type-only declaration; emits nothing"
  (define out (compile `(declare-extern foo ,(br 'Int '-> 'Int))
                       '(def x 1)))
  (check-false (matches? #rx"foo" out)))

;; --- macro &rest with splice emits correctly -------------------------------

(test-case "macro &rest with splice emits as expected Clojure call"
  (define out (compile
               `(defmacro call-it ,(br 'f '& 'args) (f (splice args)))
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
               `(defmacro with-temp ,(br 'val 'body) (let ,(br 'x 'val) body))
               '(def y (let [x 42] (with-temp 1 x)))))
  (check-true (matches? #rx"\\(let \\[x 42\\]" out))
  (check-false (matches? #rx"\\(let \\[x 1\\]" out)))

;; --- defrecord ---------------------------------------------------------------

(test-case "defrecord emits Clojure defrecord plus accessors"
  (define out (compile `(defrecord Employee ,(br '(name : String) '(rate : Int)))))
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

;; case removed — use (match x [v1 body1] [v2 body2] [_ default]) or
;; (match x [(or v1 v2) shared-body] [_ default]). Case-fold optimization
;; in the Clojure emitter lowers literal-only match -> native (case ...).
;; See "match: or-pattern + case-fold optimization" tests below.

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

;; (:keyword target) call-form removed — use (get m :key) for maps,
;; (field-name r) for record field access.

;; --- defprotocol -----------------------------------------------------------

(test-case "defprotocol emits"
  (define out (compile `(defprotocol Greetable
                          (greet ,(br '(self : Any)) : String))))
  (check-true (matches? #rx"defprotocol Greetable" out))
  (check-true (matches? #rx"\\(greet \\[self\\]\\)" out)))

;; defmulti / defmethod removed (zero corpus usage).

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

;; --- extend-type -------------------------------------------------------------
;;
;; deftype removed (2026-05 surface drop). Use (defrecord Name [...]) for the
;; data shape and (extend-type Name Protocol (method ...)) for the protocol
;; impls. The decomposition is the canonical idiom — bundling them into deftype
;; conflates data shape and protocol attachment.

(test-case "extend-type emits"
  (define out (compile `(extend-type String
                          Showable
                          (show ,(br '(self : String)) (str self)))))
  (check-true (matches? #rx"\\(extend-type String" out))
  (check-true (matches? #rx"Showable" out))
  (check-true (matches? #rx"\\(show \\[self\\]" out)))

;; --- threading macros expand at parse time ------------------------------------

;; -> removed; ->> covers threading.

(test-case "->> emits expanded form"
  (define out (compile '(def x (->> coll (map inc) (filter even?)))))
  (check-true (matches? #rx"\\(filter even\\? \\(map inc coll\\)\\)" out)))

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
  (define body-stx (located '(+ x 1) src 4))
  (define form-stx (located (list 'def 'y (list 'let bindings-stx body-stx)) src 1))
  (define prog (parse-program (list form-stx)))
  (define out (emit-program prog))
  (check-true (matches? #rx"\\^\\{:line 3 :file \"test\\.rkt\"\\} \\(\\+ 1 2\\)" out))
  (check-true (matches? #rx"\\^\\{:line 4 :file \"test\\.rkt\"\\} \\(\\+ x 1\\)" out)))

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

;; --- with form emission ------------------------------------------------------

(test-case "with emits assoc"
  (define out (compile `(defrecord P ,(br '(x : Int)))
                       `(def p (->P 1))
                       `(def q (with p ,(br ':x 2)))))
  (check-true (matches? #rx"\\(assoc p :x 2\\)" out)))

(test-case "with multi-field emits multi-arg assoc"
  (define out (compile `(defrecord P ,(br '(x : Int) '(y : Int)))
                       `(def p (->P 1 2))
                       `(def q (with p ,(br ':x 10) ,(br ':y 20)))))
  (check-true (matches? #rx"\\(assoc p :x 10 :y 20\\)" out)))

;; --- defenum emission --------------------------------------------------------

(test-case "defenum emits set def"
  (define out (compile '(defenum Color :red :green :blue)))
  (check-true (matches? #rx"\\(def Color-values #\\{" out))
  (check-true (matches? #rx":red" out))
  (check-true (matches? #rx":green" out))
  (check-true (matches? #rx":blue" out)))

;; --- defscalar emission -------------------------------------------------------

(test-case "defscalar without :where emits comment (erased)"
  (define out (compile '(defscalar Amount Int)
                       '(claim x Amount)
                       '(def x (->Amount 42))))
  (check-true (matches? #rx";; Amount : Int \\(scalar\\)" out))
  (check-false (matches? #rx"defn ->Amount" out)))

(test-case "defscalar with :where emits constructor with :pre"
  (define out (compile '(defscalar Percentage Int :where (>= 0) (<= 100))
                       '(claim x Percentage)
                       '(def x (->Percentage 50))))
  (check-true (matches? #rx"defn ->Percentage" out))
  (check-true (matches? #rx":pre" out))
  (check-true (matches? #rx"\\(>= v 0\\)" out))
  (check-true (matches? #rx"\\(<= v 100\\)" out)))

(test-case "defscalar with :where constructor is not erased at call site"
  (define out (compile '(defscalar Percentage Int :where (>= 0) (<= 100))
                       '(claim x Percentage)
                       '(def x (->Percentage 50))))
  (check-true (matches? #rx"\\(->Percentage 50\\)" out)))

;; --- varargs emission --------------------------------------------------------

(test-case "defn with & rest emits Clojure varargs"
  (define out (compile '(defn my-sum [(x : Int) & (rest : Int)]
                          (+ x (reduce + 0 rest)))))
  (check-true (matches? #rx"\\(defn my-sum \\[x & rest\\]" out)))

(test-case "fn with & rest emits varargs"
  (define out (compile '(def f (fn [(a : Int) & (b : Int)] (+ a 1)))))
  (check-true (matches? #rx"\\(fn \\[a & b\\]" out)))

(test-case "defn with only & rest and no fixed params"
  (define out (compile '(defn log-it [& (msgs : String)]
                          (clojure.string/join ", " msgs))))
  (check-true (matches? #rx"\\(defn log-it \\[& msgs\\]" out)))

;; --- metadata emission -------------------------------------------------------

(test-case "metadata emits ^{...} prefix"
  (define out (compile `(def x (#%meta (,MT :stretch 1) ,(br 1 2 3)))))
  (check-true (matches? #rx"\\^\\{:stretch 1\\}" out))
  (check-true (matches? #rx"\\[1 2 3\\]" out)))

(test-case "metadata keyword shorthand emits correctly"
  (define out (compile `(def x (#%meta (,MT :dynamic true) ,(br 4 5)))))
  (check-true (matches? #rx"\\^\\{:dynamic true\\}" out)))

(test-case "nested metadata in vector"
  (define out (compile `(def z ,(br `(#%meta (,MT :stretch 1) ,(br 'a))
                                     `(#%meta (,MT :stretch 2) ,(br 'b))))))
  (check-true (matches? #rx"\\^\\{:stretch 1\\}" out))
  (check-true (matches? #rx"\\^\\{:stretch 2\\}" out)))

;; when-let / if-let removed — interim (let [x v] (if x …)) pattern emits
;; standard let + if Clojure forms (already covered by let/if emit tests).

(test-case "with-open emits"
  (define out (compile '(defn f [(p : String)] (with-open [r (slurp p)] r))))
  (check-true (matches? #rx"\\(with-open \\[r" out)))

(test-case "doto emits"
  (define out (compile '(def x (doto (atom 1) (reset! 2)))))
  (check-true (matches? #rx"\\(doto" out)))

(test-case "for with :let emits"
  (define out (compile `(def x (for ,(br 'i '(range 3) ':let (br 's '(str i))) s))))
  (check-true (matches? #rx":let \\[s" out)))

;; when-not / if-not removed — use (when (not ...)) / (if (not ...) ...).

;; --- comment ---

(test-case "comment emits nil"
  (define out (compile '(def x (comment (+ 1 2)))))
  (check-true (matches? #rx"nil" out)))

;; dotimes removed — use (doseq [i (range n)] body).

;; --- condp ---

(test-case "condp emits with default"
  (define out (compile '(defn f [(x : Keyword)] (condp = x :a "alpha" :b "beta" "other"))))
  (check-true (matches? #rx"\\(condp = x" out))
  (check-true (matches? #rx":a \"alpha\"" out))
  (check-true (matches? #rx"\"other\"" out)))

;; --- defonce ---

(test-case "defonce emits"
  (define out (compile '(defonce db (atom nil))))
  (check-true (matches? #rx"\\(defonce db" out)))

;; --- letfn ---

(test-case "letfn emits"
  (define out (compile '(defn outer []
                          (letfn [(f [(x : Int)] : Int (+ x 1))
                                  (g [(x : Int)] : Int (f x))]
                            (g 10)))))
  (check-true (matches? #rx"\\(letfn \\[" out))
  (check-true (matches? #rx"\\(f \\[x\\]" out))
  (check-true (matches? #rx"\\(g \\[x\\]" out))
  (check-true (matches? #rx"\\(g 10\\)" out)))

(test-case "letfn emits rest param"
  (define out (compile '(defn outer []
                          (letfn [(f [(x : Int) & (rest : Int)] : Int x)]
                            (f 1 2 3)))))
  (check-true (matches? #rx"\\(letfn \\[" out))
  (check-true (matches? #rx"\\(f \\[x & rest\\]" out)))

;; --- check/rescue ------------------------------------------------------------

(test-case "check emits let+if pattern"
  (define out (compile '(def x (check (fetch-user 1)))))
  (check-true (matches? #rx"let \\[r__check" out))
  (check-true (matches? #rx"Ok" out)))

(test-case "rescue emits let+if pattern"
  (define out (compile '(def x (rescue (fetch-user 1) default-user))))
  (check-true (matches? #rx"let \\[r__rescue" out))
  (check-true (matches? #rx"Ok" out)))

(test-case "rescue with error binding emits binding name"
  (define out (compile '(def x (rescue (fetch-user 1) err (handle-error err)))))
  (check-true (matches? #rx"let \\[r__rescue" out))
  (check-true (matches? #rx"err" out)))

;; --- defunion :throwable -----------------------------------------------------

(test-case "defunion :throwable emits defrecord per variant"
  (define out (compile `(defunion :throwable ApiError
                          (NotFound ,(br '(id : Int)))
                          (RateLimit ,(br '(retry-after : Int))))))
  (check-true (matches? #rx"error ApiError" out))
  (check-true (matches? #rx"\\(defrecord NotFound" out))
  (check-true (matches? #rx"\\(defrecord RateLimit" out)))

;; --- target-case -------------------------------------------------------------

(test-case "target-case selects clj branch"
  (define out (compile '(def x (target-case :clj "clojure" :js "javascript"))))
  (check-true (matches? #rx"\"clojure\"" out))
  (check-false (matches? #rx"\"javascript\"" out)))

;; --- set! ------------------------------------------------------------------

(test-case "set! on a symbol emits Clojure set!"
  (define out (compile '(defn f [] (set! *warn-on-reflection* true))))
  (check-true (matches? #rx"\\(set! \\*warn-on-reflection\\* true\\)" out)))

(test-case "set! on a method-call target wraps in (set! (.field obj) val)"
  (define out (compile '(defn f [(o : Any)] (set! (.-name o) "x"))))
  (check-true (matches? #rx"\\(set! \\(\\.-name o\\) \"x\"\\)" out)))

;; (:keyword target) call-form removed — use (get m :key) for maps.

;; --- condp without default --------------------------------------------------

(test-case "condp without default omits trailing default clause"
  (define out (compile '(defn f [(k : Keyword)] (condp = k :a "alpha" :b "beta"))))
  (check-true (matches? #rx"\\(condp = k" out))
  (check-true (matches? #rx":a \"alpha\"" out))
  (check-true (matches? #rx":b \"beta\"" out))
  ;; default would be a 3-element format; without one, the output should
  ;; not end with a stray "other" branch
  (check-false (matches? #rx"\"other\"" out)))

;; --- match: record pattern with no bindings ---------------------------------

(test-case "match record pattern with empty bindings emits bare instance? test"
  (define out (compile `(defrecord Tag ,(br '(n : Int)))
                       `(defn f [(t : Any)]
                          (match t
                            ,(br '(Tag) 0)
                            ,(br '_ 1)))))
  (check-true (matches? #rx"\\(instance\\? Tag" out)))

(test-case "match map pattern with single key emits unwrapped test"
  (define out
    (compile `(defn f [(m : Any)]
                (match m
                  ,(br (mt ':k 1) 10)
                  ,(br '_ 20)))))
  (check-true (matches? #rx"\\(= \\(:k " out))
  (check-false (matches? #rx"\\(and \\(=" out)))

;; --- match: or-pattern + case-fold optimization (Clojure target) ---
;;
;; All-literal-dispatch match (with optional wildcard/var default) gets
;; lowered to Clojure's `case` form for O(1) dispatch — preserves the
;; perf characteristic of the dropped `case` form after it's folded into
;; match+or. Mixed-pattern matches (records + literals, etc.) fall
;; through to the general (let ... (cond ...)) emission, where or-pattern
;; emits as combined (or test1 test2 ...).

(test-case "or-pattern of integer literals — case-fold to (case x ...)"
  (define out
    (compile `(defn f [(x : Int)]
                (match x
                  ,(br '(or 1 2 3) "low")
                  ,(br '_ "other")))))
  (check-true (matches? #rx"\\(case x" out))
  (check-true (matches? #rx"\\(1 2 3\\) \"low\"" out))
  (check-true (matches? #rx"\"other\"" out)))

(test-case "or-pattern of keyword literals — case-fold to (case k ...)"
  (define out
    (compile `(defn f [(k : Keyword)]
                (match k
                  ,(br '(or :a :b) "first")
                  ,(br '_ "other")))))
  (check-true (matches? #rx"\\(case k" out))
  (check-true (matches? #rx"\\(:a :b\\) \"first\"" out)))

(test-case "or-pattern mixed with non-literal — falls through to cond chain"
  (define out
    (compile `(defrecord Tag ,(br '(n : Int)))
             `(defn f [(x : Any)]
                (match x
                  ,(br '(or 1 2) 10)
                  ,(br '(Tag n) 'n)
                  ,(br '_ 0)))))
  ;; Not case-foldable because (Tag n) is not a literal; emits the
  ;; general cond chain with (or test1 test2) for the literal alternatives.
  (check-true (matches? #rx"\\(cond" out))
  (check-true (matches? #rx"\\(or \\(= " out)))

;; --- new-form (single-arg constructor) -------------------------------------

(test-case "new-form with one arg emits as call"
  (define out (compile `(defrecord Box ,(br '(v : Int)))
                       '(def b (Box 42))))
  (check-true (matches? #rx"\\(Box 42\\)" out)))

;; --- with-form (record update) -----------------------------------------------

(test-case "with-form emits assoc"
  (define out
    (compile `(defrecord P ,(br '(x : Int) '(y : Int)))
             `(defn shift [(p : P)]
                (with p ,(br ':x '(+ (p-x p) 1)) ,(br ':y '(+ (p-y p) 1))))))
  (check-true (matches? #rx"\\(assoc p :x" out))
  (check-true (matches? #rx":y \\(\\+ \\(p-y p\\)" out)))

;; --- defenum ---------------------------------------------------------------

(test-case "defenum emits set of keywords with -values suffix"
  (define out (compile '(defenum Color red green blue)))
  (check-true (matches? #rx"\\(def Color-values #\\{" out))
  (check-true (matches? #rx":red" out))
  (check-true (matches? #rx":blue" out)))

;; --- defunion (closed, with member fields) ----------------------------------

(test-case "defunion with member fields emits comment + per-variant defrecord"
  (define out (compile `(defunion Shape
                          (Circle ,(br '(radius : Int)))
                          (Square ,(br '(side : Int))))))
  (check-true (matches? #rx";; Shape = Circle \\| Square" out))
  (check-true (matches? #rx"\\(defrecord Circle \\[radius\\]\\)" out))
  (check-true (matches? #rx"\\(defrecord Square \\[side\\]\\)" out)))

;; --- ns emits combined :require + :import correctly ------------------------

(test-case "ns with both :require and :import emits both clauses"
  (define out (compile '(require clojure.string :as str)
                       '(import java.io.File)
                       '(def x 1)))
  (check-true (matches? #rx":require" out))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"\\[clojure\\.string :as str\\]" out))
  (check-true (matches? #rx"\\[java\\.io File\\]" out)))

;; --- ns with bare-class import (no dot) -------------------------------------

(test-case "ns import for bare class emits plain symbol"
  (define out (compile '(import Exception)
                       '(def x 1)))
  (check-true (matches? #rx":import" out))
  (check-true (matches? #rx"Exception" out)))
