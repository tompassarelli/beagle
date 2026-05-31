#lang racket/base

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/private/types)

(define (py-emit src)
  (define stxs
    (parameterize ([read-square-bracket-with-tag '#%brackets])
      (with-input-from-string src
        (lambda ()
          (let loop ([acc '()])
            (define d (read-syntax 'test))
            (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

(define (py-emit-forms . forms)
  (define stxs (map (lambda (f) (datum->syntax #f f)) forms))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

;; --- def / defonce ----------------------------------------------------------

(test-case "def emits assignment"
  (define out (py-emit "(define-target py) (def x : Int 42)"))
  (check-true (string-contains? out "x = 42")))

(test-case "defonce emits assignment"
  (define out (py-emit "(define-target py) (defonce y : String \"hello\")"))
  (check-true (string-contains? out "y = \"hello\"")))

;; --- defn / defn-multi ------------------------------------------------------

(test-case "defn emits def"
  (define out (py-emit "(define-target py) (defn add [(a : Int) (b : Int)] : Int (+ a b))"))
  (check-true (string-contains? out "def add(a, b):"))
  (check-true (string-contains? out "return (a + b)")))

(test-case "defn with rest param"
  (define out (py-emit "(define-target py) (defn log [(msg : String) & (args : Any)] : Nil (println msg))"))
  (check-true (string-contains? out "def log(msg, *args):")))

(test-case "defn-multi emits *args dispatch"
  (define out (py-emit "(define-target py) (defn f ([(x : Int)] x) ([(x : Int) (y : Int)] (+ x y)))"))
  (check-true (string-contains? out "def f(*args):"))
  (check-true (string-contains? out "if len(args) == 1:")))

;; --- records ----------------------------------------------------------------

(test-case "defrecord emits dataclass"
  (define out (py-emit "(define-target py) (defrecord Point [(x : Int) (y : Int)])"))
  (check-true (string-contains? out "@dataclass(frozen=True)"))
  (check-true (string-contains? out "class Point:"))
  (check-true (string-contains? out "x: object"))
  (check-true (string-contains? out "y: object")))

(test-case "defrecord single field"
  (define out (py-emit "(define-target py) (defrecord Wrapper [(val : Any)])"))
  (check-true (string-contains? out "class Wrapper:"))
  (check-true (string-contains? out "val: object")))

;; --- defunion / deferror ----------------------------------------------------

(test-case "defunion emits base + variant classes"
  (define out (py-emit "(define-target py) (defunion Shape (Circle [(r : Float)]) (Rect [(w : Float) (h : Float)]))"))
  (check-true (string-contains? out "class Shape:"))
  (check-true (string-contains? out "class Circle(Shape):"))
  (check-true (string-contains? out "r: object"))
  (check-true (string-contains? out "class Rect(Shape):"))
  (check-true (string-contains? out "w: object")))

(test-case "defunion :throwable emits Exception base"
  (define out (py-emit "(define-target py) (defunion :throwable AppError (NotFound [(msg : String)]) (Timeout [(code : Int)]))"))
  (check-true (string-contains? out "class AppError(Exception):"))
  (check-true (string-contains? out "class NotFound(AppError):"))
  (check-true (string-contains? out "msg: object"))
  (check-true (string-contains? out "class Timeout(AppError):")))

;; --- defenum ----------------------------------------------------------------

(test-case "defenum emits class with constants"
  (define out (py-emit "(define-target py) (defenum Color red green blue)"))
  (check-true (string-contains? out "class Color:"))
  (check-true (string-contains? out "red = \"red\""))
  (check-true (string-contains? out "green = \"green\"")))

;; --- defscalar --------------------------------------------------------------

(test-case "defscalar emits newtype wrapper"
  (define out (py-emit "(define-target py) (defscalar UserId Int)"))
  (check-true (string-contains? out "class UserId:"))
  (check-true (string-contains? out "value: object")))

;; --- if / when / cond -------------------------------------------------------

(test-case "if emits ternary"
  (define out (py-emit "(define-target py) (if true 1 0)"))
  (check-true (string-contains? out "1 if True else 0")))

(test-case "if without else"
  (define out (py-emit "(define-target py) (if true 1)"))
  (check-true (string-contains? out "1 if True else None")))

;; when removed — replaced by if (no else). Python emit-layer renders if
;; (with or without else) as a ternary expression (`body if cond else None`
;; when no else). Side-effecting body becomes ternary; runtime behavior is
;; equivalent in modern Python.
(test-case "if (no else) emits ternary with None"
  (define out (py-emit "(define-target py) (if true (println \"yes\"))"))
  (check-true (string-contains? out "if True else None"))
  (check-true (string-contains? out "print(\"yes\")")))

(test-case "cond emits if/elif/else"
  (define out (py-emit "(define-target py) (defn f [(x : Int)] : String (cond [(< x 0) \"neg\"] [:else \"pos\"]))"))
  (check-true (string-contains? out "if (x < 0):"))
  (check-true (string-contains? out "else:")))

;; --- let --------------------------------------------------------------------

(test-case "let emits assignments"
  (define out (py-emit "(define-target py) (let [x 1 y 2] (+ x y))"))
  (check-true (string-contains? out "x = 1"))
  (check-true (string-contains? out "y = 2")))

;; --- fn / lambda ------------------------------------------------------------

(test-case "fn single body emits lambda"
  (define out (py-emit "(define-target py) (def f : Any (fn [(x : Int)] (+ x 1)))"))
  (check-true (string-contains? out "lambda x: (x + 1)")))

;; --- literals ---------------------------------------------------------------

(test-case "vec emits list"
  (define out (py-emit "(define-target py) [1 2 3]"))
  (check-true (string-contains? out "[1, 2, 3]")))

(test-case "map emits dict"
  (define out (py-emit-forms '(define-target py) `(#%map :a 1 :b 2)))
  (check-true (string-contains? out "\"a\": 1"))
  (check-true (string-contains? out "\"b\": 2")))

(test-case "set emits set"
  (define out (py-emit-forms '(define-target py) `(#%set 1 2 3)))
  (check-true (string-contains? out "{1, 2, 3}")))

(test-case "empty set emits set()"
  (define out (py-emit-forms '(define-target py) `(#%set)))
  (check-true (string-contains? out "set()")))

(test-case "nil emits None"
  (define out (py-emit "(define-target py) nil"))
  (check-true (string-contains? out "None")))

(test-case "booleans emit True/False"
  (define out (py-emit "(define-target py) true"))
  (check-true (string-contains? out "True")))

;; --- name mangling ----------------------------------------------------------

(test-case "kebab-case to snake_case"
  (define out (py-emit "(define-target py) (def my-var : Int 1)"))
  (check-true (string-contains? out "my_var = 1")))

(test-case "predicate names mangled"
  (define out (py-emit "(define-target py) (def is-valid? : Bool true)"))
  (check-true (string-contains? out "is_valid_p = True")))

(test-case "bang names mangled"
  (define out (py-emit "(define-target py) (def reset! : Any nil)"))
  (check-true (string-contains? out "reset_bang = None")))

;; --- method calls / static calls / new -------------------------------------

(test-case "method call strips dot"
  (define out (py-emit "(define-target py) (.upper \"hello\")"))
  (check-true (string-contains? out "\"hello\".upper()")))

(test-case "constructor emits class call"
  (define out (py-emit "(define-target py) (Point. 1 2)"))
  (check-true (string-contains? out "Point(1, 2)")))

;; --- call translations ------------------------------------------------------

(test-case "println emits print"
  (define out (py-emit "(define-target py) (println \"hi\")"))
  (check-true (string-contains? out "print(\"hi\")")))

(test-case "not emits parens"
  (define out (py-emit "(define-target py) (not true)"))
  (check-true (string-contains? out "(not True)")))

(test-case "nil? emits is None"
  (define out (py-emit "(define-target py) (nil? x)"))
  (check-true (string-contains? out "is None")))

(test-case "some? emits is not None"
  (define out (py-emit "(define-target py) (some? x)"))
  (check-true (string-contains? out "is not None")))

(test-case "count emits len"
  (define out (py-emit "(define-target py) (count [1 2 3])"))
  (check-true (string-contains? out "len(")))

(test-case "conj emits list append"
  (define out (py-emit "(define-target py) (conj [1 2] 3)"))
  (check-true (string-contains? out "[1, 2] + [3]")))

(test-case "get emits dict.get"
  (define out (py-emit-forms '(define-target py) '(get (#%map :a 1) :a)))
  (check-true (string-contains? out ".get(")))

(test-case "contains? emits in"
  (define out (py-emit "(define-target py) (contains? [1 2 3] 2)"))
  (check-true (string-contains? out "2 in [1, 2, 3]")))

(test-case "map with lambda inlines to comprehension"
  (define out (py-emit "(define-target py) (map (fn [(x : Int)] (* x 2)) [1 2 3])"))
  (check-true (string-contains? out "[(x * 2) for x in [1, 2, 3]]")))

(test-case "filter with lambda inlines to comprehension"
  (define out (py-emit "(define-target py) (filter (fn [(x : Int)] (> x 0)) [1 -2 3])"))
  (check-true (string-contains? out "for x in"))
  (check-true (string-contains? out "if (x > 0)")))

(test-case "reduce emits functools.reduce"
  (define out (py-emit "(define-target py) (reduce + [1 2 3])"))
  (check-true (string-contains? out "functools")))

(test-case "first/last/rest emit indexing"
  (define out1 (py-emit "(define-target py) (first [1 2 3])"))
  (check-true (string-contains? out1 "[0]"))
  (define out2 (py-emit "(define-target py) (last [1 2 3])"))
  (check-true (string-contains? out2 "[-1]"))
  (define out3 (py-emit "(define-target py) (rest [1 2 3])"))
  (check-true (string-contains? out3 "[1:]")))

(test-case "throw emits raise"
  (define out (py-emit "(define-target py) (throw (Exception. \"err\"))"))
  (check-true (string-contains? out "raise Exception(\"err\")")))

(test-case "mod emits percent"
  (define out (py-emit "(define-target py) (mod 10 3)"))
  (check-true (string-contains? out "(10 % 3)")))

(test-case "arithmetic operators"
  (define out (py-emit "(define-target py) (+ 1 2)"))
  (check-true (string-contains? out "(1 + 2)"))
  (define out2 (py-emit "(define-target py) (* 3 4)"))
  (check-true (string-contains? out2 "(3 * 4)")))

(test-case "comparison operators"
  (define out (py-emit "(define-target py) (= 1 1)"))
  (check-true (string-contains? out "=="))
  (define out2 (py-emit "(define-target py) (not (= 1 2))"))
  ;; was `not=` before surface redesign; now emits as wrapped `not (==)`.
  (check-true (string-contains? out2 "(not")))

(test-case "and/or emit keywords"
  (define out (py-emit "(define-target py) (and true false)"))
  (check-true (string-contains? out "True and False"))
  (define out2 (py-emit "(define-target py) (or true false)"))
  (check-true (string-contains? out2 "True or False")))

;; --- match / case -----------------------------------------------------------

(test-case "match emits match/case"
  (define out (py-emit "(define-target py) (defn f [(x : Any)] : Any (match x [(Circle r) r] [_ nil]))"))
  (check-true (string-contains? out "match x:"))
  (check-true (string-contains? out "case Circle(r):"))
  (check-true (string-contains? out "case _:")))

(test-case "or-pattern emits PEP 634 | syntax"
  (define out (py-emit "(define-target py) (defn f [(x : Int)] : String (match x [(or 1 2 3) \"low\"] [_ \"other\"]))"))
  (check-true (string-contains? out "case 1 | 2 | 3:")))

;; --- loop/recur -------------------------------------------------------------

(test-case "loop/recur emits while True"
  (define out (py-emit "(define-target py) (defn f [(n : Int)] : Int (loop [acc 1 i n] (if (<= i 1) acc (recur (* acc i) (- i 1)))))"))
  (check-true (string-contains? out "acc = 1"))
  (check-true (string-contains? out "i = n"))
  (check-true (string-contains? out "while True:"))
  (check-true (string-contains? out "continue")))

;; --- try/catch/finally ------------------------------------------------------

(test-case "try/catch emits try/except"
  (define out (py-emit "(define-target py) (try (/ 1 0) (catch Exception e nil))"))
  (check-true (string-contains? out "try:"))
  (check-true (string-contains? out "except Exception as e:")))

;; --- for / doseq ------------------------------------------------------------

(test-case "for emits list comprehension"
  (define out (py-emit "(define-target py) (for [x [1 2 3]] (* x 2))"))
  (check-true (string-contains? out "for x in"))
  (check-true (string-contains? out "(x * 2)")))

(test-case "doseq emits for loop without return"
  (define out (py-emit "(define-target py) (doseq [x [1 2 3]] (println x))"))
  (check-true (string-contains? out "for x in"))
  (check-false (string-contains? out "return")))

;; --- with (record update) ---------------------------------------------------

(test-case "with emits dataclasses.replace"
  (define out (py-emit "(define-target py) (defrecord P [(x : Int)]) (with (new P 1) [:x 2])"))
  (check-true (string-contains? out "replace("))
  (check-true (string-contains? out "x=2")))

;; dotimes removed — use (doseq [i (range n)] body); covered by doseq emit tests.

;; --- letfn ------------------------------------------------------------------

(test-case "letfn emits local defs"
  (define out (py-emit "(define-target py) (defn f [] : Int (letfn [(g [(x : Int)] : Int (* x 2))] (g 5)))"))
  (check-true (string-contains? out "def g(x):"))
  (check-true (string-contains? out "return (x * 2)"))
  (check-true (string-contains? out "return g(5)")))

;; --- condp ------------------------------------------------------------------

(test-case "condp with = emits infix comparison"
  (define out (py-emit "(define-target py) (defn f [(x : Int)] : String (condp = x 1 \"one\" 2 \"two\" \"other\"))"))
  (check-true (string-contains? out "1 == x"))
  (check-true (string-contains? out "2 == x"))
  (check-true (string-contains? out "else:")))

;; --- with-open --------------------------------------------------------------

(test-case "with-open emits with statement"
  (define out (py-emit "(define-target py) (defn f [(p : String)] : String (with-open [f (open p \"r\")] (.read f)))"))
  (check-true (string-contains? out "with open(p, \"r\") as f:"))
  (check-true (string-contains? out "return f.read()")))

;; --- defprotocol ------------------------------------------------------------

(test-case "defprotocol emits ABC"
  (define out (py-emit "(define-target py) (defprotocol Showable (show [(self : Any)] : String))"))
  (check-true (string-contains? out "class Showable(ABC):"))
  (check-true (string-contains? out "@abstractmethod"))
  (check-true (string-contains? out "def show(self):")))

;; --- await ------------------------------------------------------------------

(test-case "await emits await"
  (define out (py-emit "(define-target py) (js/await (fetch \"url\"))"))
  (check-true (string-contains? out "await fetch(\"url\")")))

;; --- set! -------------------------------------------------------------------

(test-case "set! emits assignment"
  (define out (py-emit "(define-target py) (set! x 42)"))
  (check-true (string-contains? out "x = 42")))

;; --- block string -----------------------------------------------------------

(test-case "string literal"
  (define out (py-emit "(define-target py) \"hello world\""))
  (check-true (string-contains? out "\"hello world\"")))

;; when-let / if-let removed — interim (let [x v] (if x …)) pattern.
;; Standard let + if Python emission already tested above.

;; --- keyword access ---------------------------------------------------------
;; (:keyword target) call-form removed — use (get m :key); covered by get emit tests.

;; --- header imports ---------------------------------------------------------

(test-case "record triggers dataclass import"
  (define out (py-emit "(define-target py) (defrecord Foo [(x : Int)])"))
  (check-true (string-contains? out "from dataclasses import dataclass")))

(test-case "no record no dataclass import"
  (define out (py-emit "(define-target py) (def x : Int 42)"))
  (check-false (string-contains? out "dataclass")))
