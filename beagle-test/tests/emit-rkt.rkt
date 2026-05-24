#lang racket/base

(require rackunit
         racket/string
         racket/port
         beagle/private/parse
         beagle/private/emit
         beagle/private/types)

(define (rkt-emit src)
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

(define BRACKET-TAG '#%brackets)
(define MAP-TAG '#%map)
(define SET-TAG '#%set)

(define (br . xs) (cons BRACKET-TAG xs))
(define (mp . xs) (cons MAP-TAG xs))

(define (rkt-emit-forms . forms)
  (define stxs (map (lambda (f) (datum->syntax #f f)) forms))
  (define prog
    (with-handlers ([exn:fail? (lambda (e) #f)])
      (parse-program stxs)))
  (and prog
       (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
         (string-trim (emit-program prog)))))

;; --- header ----------------------------------------------------------------

(test-case "emits #lang typed/racket header"
  (define out (rkt-emit "(define-target rkt) (def x 42)"))
  (check-true (string-contains? out "#lang typed/racket")))

;; --- def / defonce ----------------------------------------------------------

(test-case "def with type emits typed define"
  (define out (rkt-emit "(define-target rkt) (def x : Int 42)"))
  (check-true (string-contains? out "(define x : Integer 42)")))

(test-case "def without type"
  (define out (rkt-emit "(define-target rkt) (def x 42)"))
  (check-true (string-contains? out "(define x 42)")))

;; --- defn ------------------------------------------------------------------

(test-case "defn emits type annotation + define"
  (define out (rkt-emit "(define-target rkt) (defn add [(a : Int) (b : Int)] : Int (+ a b))"))
  (check-true (string-contains? out "(: add (-> Integer Integer Integer))"))
  (check-true (string-contains? out "(define (add [a : Integer] [b : Integer])")))

(test-case "defn body emits correctly"
  (define out (rkt-emit "(define-target rkt) (defn inc1 [(x : Int)] : Int (+ x 1))"))
  (check-true (string-contains? out "(+ x 1)")))

;; --- records ---------------------------------------------------------------

(test-case "defrecord emits struct"
  (define out (rkt-emit "(define-target rkt) (defrecord Point [(x : Float) (y : Float)])"))
  (check-true (string-contains? out "(struct Point ([x : Flonum] [y : Flonum]) #:transparent)")))

;; --- defunion --------------------------------------------------------------

(test-case "defunion emits define-type with variant structs"
  (define out (rkt-emit "(define-target rkt) (defunion Color Red Blue)"))
  (check-true (string-contains? out "(struct Red () #:transparent)"))
  (check-true (string-contains? out "(struct Blue () #:transparent)"))
  (check-true (string-contains? out "(define-type Color (U Red Blue))")))

(test-case "defunion with existing records skips struct re-emission"
  (define out (rkt-emit "(define-target rkt) (defrecord Circle [(r : Float)]) (defrecord Rect [(w : Float)]) (defunion Shape Circle Rect)"))
  (define circle-count
    (length (regexp-match* #rx"\\(struct Circle" out)))
  (check-equal? circle-count 1))

;; --- defenum ---------------------------------------------------------------

(test-case "defenum emits define-type with symbols"
  (define out (rkt-emit "(define-target rkt) (defenum Status :active :inactive :pending)"))
  (check-true (string-contains? out "(define-type Status (U 'active 'inactive 'pending))")))

;; --- defscalar -------------------------------------------------------------

(test-case "defscalar emits wrapper struct"
  (define out (rkt-emit "(define-target rkt) (defscalar TaskId String)"))
  (check-true (string-contains? out "(struct TaskId ([v :")))

;; --- fn (lambda) -----------------------------------------------------------

(test-case "fn emits lambda"
  (define out (rkt-emit "(define-target rkt) (def f (fn [(x : Int)] (+ x 1)))"))
  (check-true (string-contains? out "(λ ([x : Integer]) (+ x 1))")))

;; --- let -------------------------------------------------------------------

(test-case "multi-binding let emits let*"
  (define out (rkt-emit "(define-target rkt) (def r (let [x 1 y 2] (+ x y)))"))
  (check-true (string-contains? out "(let* ([x 1] [y 2])")))

(test-case "single-binding let emits let"
  (define out (rkt-emit "(define-target rkt) (def r (let [x 1] x))"))
  (check-true (string-contains? out "(let ([x 1])")))

;; --- if / cond / when ------------------------------------------------------

(test-case "if emits if"
  (define out (rkt-emit "(define-target rkt) (def r (if true 1 2))"))
  (check-true (string-contains? out "(if #t 1 2)")))

(test-case "cond emits cond"
  (define out (rkt-emit "(define-target rkt) (def r (cond [(= x 1) \"one\"] [(= x 2) \"two\"]))"))
  (check-true (string-contains? out "(cond")))

(test-case "when emits when"
  (define out (rkt-emit "(define-target rkt) (when true (println \"hi\"))"))
  (check-true (string-contains? out "(when #t")))

;; --- do --------------------------------------------------------------------

(test-case "do emits begin"
  (define out (rkt-emit "(define-target rkt) (do (println \"a\") (println \"b\"))"))
  (check-true (string-contains? out "(begin")))

;; --- vectors / maps / sets -------------------------------------------------

(test-case "vec emits list"
  (define out (rkt-emit-forms '(define-target rkt) `(def v ,(br 1 2 3))))
  (check-true (string-contains? out "(list 1 2 3)")))

(test-case "map emits hash"
  (define out (rkt-emit-forms '(define-target rkt) `(def m (,MAP-TAG "a" 1 "b" 2))))
  (check-true (string-contains? out "(hash")))

(test-case "set emits set"
  (define out (rkt-emit-forms '(define-target rkt) `(def s (,SET-TAG 1 2 3))))
  (check-true (string-contains? out "(set 1 2 3)")))

;; --- core call translations ------------------------------------------------

(test-case "println → displayln"
  (define out (rkt-emit "(define-target rkt) (println \"hello\")"))
  (check-true (string-contains? out "(displayln \"hello\")")))

(test-case "first → car"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (first ,(br 1 2 3)))))
  (check-true (string-contains? out "(car")))

(test-case "rest → cdr"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (rest ,(br 1 2 3)))))
  (check-true (string-contains? out "(cdr")))

(test-case "count → length"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (count ,(br 1 2 3)))))
  (check-true (string-contains? out "(length")))

(test-case "empty? → null?"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (empty? ,(br)))))
  (check-true (string-contains? out "(null?")))

(test-case "nil? → not"
  (define out (rkt-emit "(define-target rkt) (def x (nil? y))"))
  (check-true (string-contains? out "(not y)")))

(test-case "= → equal?"
  (define out (rkt-emit "(define-target rkt) (def x (= 1 2))"))
  (check-true (string-contains? out "(equal? 1 2)")))

(test-case "filter → filter"
  (define out (rkt-emit "(define-target rkt) (def x (filter odd? xs))"))
  (check-true (string-contains? out "(filter odd?")))

(test-case "conj → append + list"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (conj ,(br 1 2) 3))))
  (check-true (string-contains? out "(append")))

(test-case "str → format ~a for coercion"
  (define out (rkt-emit "(define-target rkt) (def x (str \"hi \" 42))"))
  (check-true (string-contains? out "format")))

;; inc/dec → add1/sub1 emit-rkt translations removed — inc/dec dropped
;; from beagle surface; use (+ x 1) / (- x 1) directly. The Racket emit
;; produces (+ 5 1) literally, which Racket also accepts.

(test-case "string/upper-case as value ref → string-upcase"
  (define out (rkt-emit "(define-target rkt) (def f string/upper-case)"))
  (check-true (string-contains? out "string-upcase")))

(test-case "get with default wraps in thunk"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (get m "k" 0))))
  (check-true (string-contains? out "(hash-ref m \"k\" (λ () 0))")))

;; --- constructor translation -----------------------------------------------

(test-case "->Name becomes Name"
  (define out (rkt-emit "(define-target rkt) (defrecord P [(x : Int)]) (def p (->P 1))"))
  (check-true (string-contains? out "(P 1)")))

;; --- accessor translation --------------------------------------------------

(test-case "record-field becomes Record-field"
  (define out (rkt-emit "(define-target rkt) (defrecord P [(x : Int)]) (def v (p-x p))"))
  (check-true (string-contains? out "P-x")))

;; --- nil / true / false literals -------------------------------------------

(test-case "nil → #f"
  (define out (rkt-emit "(define-target rkt) (def x nil)"))
  (check-true (string-contains? out "#f")))

(test-case "true → #t"
  (define out (rkt-emit "(define-target rkt) (def x true)"))
  (check-true (string-contains? out "#t")))

;; --- type emission ---------------------------------------------------------

(test-case "Int → Integer"
  (define out (rkt-emit "(define-target rkt) (def x : Int 42)"))
  (check-true (string-contains? out "Integer")))

(test-case "Float → Flonum"
  (define out (rkt-emit "(define-target rkt) (def x : Float 3.14)"))
  (check-true (string-contains? out "Flonum")))

(test-case "Bool → Boolean"
  (define out (rkt-emit "(define-target rkt) (def x : Bool true)"))
  (check-true (string-contains? out "Boolean")))

(test-case "(Vec Int) → (Listof Integer)"
  (define out (rkt-emit "(define-target rkt) (defn f [(xs : (Vec Int))] : Int (first xs))"))
  (check-true (string-contains? out "(Listof Integer)")))

(test-case "(Map String Int) → (HashTable String Integer)"
  (define out (rkt-emit "(define-target rkt) (defn f [(m : (Map String Int))] : Int (get m \"k\"))"))
  (check-true (string-contains? out "(HashTable String Integer)")))

(test-case "String? → (Option String)"
  (define out (rkt-emit "(define-target rkt) (defn f [(x : String?)] : String (if (nil? x) \"\" x))"))
  (check-true (string-contains? out "(Option String)")))

(test-case "(U A B) → (U A B)"
  (define out (rkt-emit "(define-target rkt) (defn f [(x : (U Int String))] : Int 0)"))
  (check-true (string-contains? out "(U Integer String)")))

;; --- loop/recur ------------------------------------------------------------

(test-case "loop/recur emits named let"
  (define out (rkt-emit "(define-target rkt) (def x (loop [i 0 acc 0] (if (= i 10) acc (recur (+ i 1) (+ acc i)))))"))
  (check-true (string-contains? out "(let loop"))
  (check-true (string-contains? out "(loop (+ i 1)")))

;; --- match -----------------------------------------------------------------

(test-case "match with record patterns emits cond"
  (define out (rkt-emit "(define-target rkt) (defrecord Circle [(r : Float)]) (defrecord Rect [(w : Float)]) (defunion Shape Circle Rect) (defn area [(s : Shape)] : Float (match s [(Circle r) r] [(Rect w) w]))"))
  (check-true (string-contains? out "(cond"))
  (check-true (string-contains? out "Circle?"))
  (check-true (string-contains? out "Circle-r")))

(test-case "or-pattern (all-literal) case-folds to (case ...) for O(1) dispatch"
  (define out (rkt-emit "(define-target rkt) (defn f [(x : Integer)] : String (match x [(or 1 2 3) \"low\"] [_ \"other\"]))"))
  (check-true (string-contains? out "(case x"))
  (check-true (string-contains? out "[(1 2 3) \"low\"]"))
  (check-true (string-contains? out "[else \"other\"]")))

;; --- try/catch -------------------------------------------------------------

(test-case "try/catch emits with-handlers"
  (define out (rkt-emit "(define-target rkt) (def x (try (/ 1 0) (catch Exception e \"error\")))"))
  (check-true (string-contains? out "with-handlers")))

;; --- for / doseq -----------------------------------------------------------

(test-case "for emits for/list"
  (define out (rkt-emit-forms '(define-target rkt) `(def xs (for [x ,(br 1 2 3)] (* x x)))))
  (check-true (string-contains? out "for/list")))

(test-case "doseq emits for"
  (define out (rkt-emit-forms '(define-target rkt) `(doseq [x ,(br 1 2 3)] (println x))))
  (check-true (string-contains? out "(for")))

;; --- string stdlib ---------------------------------------------------------

(test-case "string/join → string-join"
  (define out (rkt-emit-forms '(define-target rkt) `(def x (string/join ,(br "a" "b") ","))))
  (check-true (string-contains? out "(string-join")))

(test-case "string/upper-case → string-upcase"
  (define out (rkt-emit "(define-target rkt) (def x (string/upper-case \"hi\"))"))
  (check-true (string-contains? out "(string-upcase")))

;; --- parametric types ------------------------------------------------------

(test-case "parametric defunion emits type-parameterized structs"
  (define out (rkt-emit "(define-target rkt) (defunion (Result T E) (Ok [(value : T)]) (Err [(error : E)]))"))
  (check-true (string-contains? out "(struct (T E) Ok"))
  (check-true (string-contains? out "(define-type (Result T E)")))

;; when-let / if-let removed — interim (let [x v] (if x …)) pattern emits
;; standard let + if forms (covered by general let/if emit tests).
;; when-some / if-some removed previously for same reason.

;; dotimes removed — use (doseq [i (range n)] body) instead.

;; --- condp -----------------------------------------------------------------

(test-case "condp emits cond with predicate application"
  (define out (rkt-emit "(define-target rkt) (def r (condp = x 1 \"one\" 2 \"two\" \"other\"))"))
  (check-true (string-contains? out "(cond"))
  (check-true (string-contains? out "[else")))

;; --- set! ------------------------------------------------------------------

(test-case "set! emits set!"
  (define out (rkt-emit "(define-target rkt) (set! x 42)"))
  (check-true (string-contains? out "(set! x 42)")))

;; --- letfn -----------------------------------------------------------------

(test-case "letfn emits let with define + type annotations"
  (define out (rkt-emit "(define-target rkt) (def r (letfn [(f [(x : Int)] : Int (g x)) (g [(x : Int)] : Int (+ x 1))] (f 10)))"))
  (check-true (string-contains? out "(let ()"))
  (check-true (string-contains? out "(: f (-> Integer Integer))"))
  (check-true (string-contains? out "(define (f ")))
