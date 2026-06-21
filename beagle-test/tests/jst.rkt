#lang racket/base

;; Tests for typed JS target AST (js/* forms) — minimal set only.
;; Pruned forms (js/fn, js/const, js/if, etc.) use core beagle equivalents.

(require rackunit
         rackunit/text-ui
         racket/string
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/types)

(define (jst-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.rkt"))
  (type-check! prog)
  (emit-program prog))

(define (jst-parse src-forms)
  (parse-program
   (map (lambda (f) (datum->syntax #f f)) src-forms)
   #:source-path "test.rkt"))

(define (jst-preamble . forms)
  (append '((ns test.app) (define-mode strict) (define-target js)) forms))

(define-syntax-rule (check-jst-emit name expected-str form ...)
  (test-case name
    (define result (apply jst-emit (list (apply jst-preamble (list form ...)))))
    (check-true (string-contains? result expected-str)
                (format "expected ~v in:\n~a" expected-str result))))

(define-syntax-rule (check-jst-parse-ok name form ...)
  (test-case name
    (check-not-exn (lambda () (apply jst-parse (list (apply jst-preamble (list form ...))))))))

(define-syntax-rule (check-jst-parse-err name form ...)
  (test-case name
    (check-exn exn:fail? (lambda () (apply jst-parse (list (apply jst-preamble (list form ...))))))))

(run-tests
 (test-suite "jst — typed JS target AST (minimal)"

   ;; ===== Parsing =====
   (test-suite "parse"

     (check-jst-parse-ok "js/class"
       '(js/class Animal
          (constructor [(name : String)]
            (set! (.-name this) name))
          (speak []
            (js/return (.-name this)))))

     (check-jst-parse-ok "js/class with extends"
       '(js/class Dog extends Animal
          (speak []
            (js/return "woof"))))

     (check-jst-parse-ok "js/template"
       '(js/template "Hello, " name "!"))

     (check-jst-parse-ok "js/spread"
       '(js/spread items))

     (check-jst-parse-ok "js/typeof"
       '(js/typeof x))

     (check-jst-parse-ok "js/export function"
       '(js/export (defn main [] 0)))

     (check-jst-parse-ok "js/export class"
       '(js/export (js/class App
          (constructor []
            (js/return)))))

     (check-jst-parse-ok "js/return bare"
       '(defn f [] (js/return)))

     (check-jst-parse-ok "js/return with value"
       '(defn f [] (js/return 42)))

     (check-jst-parse-ok "js/! unary"
       '(js/! done))

     (check-jst-parse-ok "js/=== binary"
       '(js/=== a b))

     (check-jst-parse-ok "js/&& binary"
       '(js/&& a b))

     (check-jst-parse-ok "js/|| binary"
       '(js/|| a b))

     (check-jst-parse-ok "js/?? binary"
       '(js/?? a b))

   ) ;; end parse suite

   ;; ===== Type checking =====
   (test-suite "type-check"

     (test-case "js/class rejected in CLJ target"
       (check-exn
        exn:fail?
        (lambda ()
          (define prog (jst-parse (list '(ns test.app) '(define-mode strict)
                                        '(js/class Foo (constructor [] (js/return))))))
          (type-check! prog))))

   ) ;; end type-check suite

   ;; ===== Emission =====
   (test-suite "emit"

     (check-jst-emit "js/+ binary"
       "(a + b)"
       '(def r :- Any (js/+ a b)))

     (check-jst-emit "js/=== binary"
       "(a === b)"
       '(def r :- Any (js/=== a b)))

     (check-jst-emit "js/&& binary"
       "(a && b)"
       '(def r :- Any (js/&& a b)))

     (check-jst-emit "js/|| binary"
       "(a || b)"
       '(def r :- Any (js/|| a b)))

     (check-jst-emit "js/?? binary"
       "(a ?? b)"
       '(def r :- Any (js/?? a b)))

     (check-jst-emit "js/! unary"
       "!done"
       '(def r :- Any (js/! done)))

     (check-jst-emit "js/typeof"
       "typeof x"
       '(def r :- Any (js/typeof x)))

     (check-jst-emit "js/template"
       "`Hello, ${name}!`"
       '(def msg :- Any (js/template "Hello, " name "!")))

     (check-jst-emit "js/spread"
       "...items"
       '(def arr :- Any (js/spread items)))

     (check-jst-emit "js/return"
       "return 42;"
       '(defn f [] (js/return 42)))

     (check-jst-emit "bare js/return"
       "return;"
       '(defn f [] (js/return)))

     (check-jst-emit "js/class declaration"
       "class Animal {"
       '(js/class Animal
          (constructor [(name : String)]
            (set! (.-name this) name))))

     (check-jst-emit "class constructor"
       "constructor(name)"
       '(js/class Animal
          (constructor [(name : String)]
            (set! (.-name this) name))))

     (check-jst-emit "class with extends"
       "class Dog extends Animal {"
       '(js/class Dog extends Animal
          (speak []
            (js/return "woof"))))

     (check-jst-emit "js/export class"
       "export class"
       '(js/export (js/class App
          (constructor []
            (js/return)))))

     (check-jst-emit "js/export def"
       "export const"
       '(js/export (def x 42)))

     (check-jst-emit "js/export defn"
       "export function"
       '(js/export (defn main [] 0)))

   ) ;; end emit suite

   ;; ===== Complex examples =====
   (test-suite "complex"

     (check-jst-emit "class with static method"
       "static create"
       '(js/class Config
          (constructor [(data : Any)]
            (set! (.-data this) data))
          (static create [(path : String)]
            (js/return (Config. (JSON/parse path))))))

   ) ;; end complex suite
 ))
