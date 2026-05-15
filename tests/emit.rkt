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
