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
     #:source-path "test.bjs"))
  (type-check! prog)
  (emit-program prog))

(define (jst-parse src-forms)
  (parse-program
   (map (lambda (f) (datum->syntax #f f)) src-forms)
   #:source-path "test.bjs"))

(define (jst-preamble . forms)
  (append '((ns test.app) (define-target js)) forms))

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
          (constructor [(name String)]
            Any
            (js/set! this .name name))
          (speak []
            String
            (js/return (js/get this .name)))))

     (check-jst-parse-ok "js/class with extends"
       '(js/class Dog extends Animal
          (speak []
            String
            (js/return "woof"))))

     (check-jst-parse-ok "js/template"
       '(js/template "Hello, " name "!"))

     (check-jst-parse-ok "js/spread"
       '(js/spread items))

     (check-jst-parse-ok "js/typeof"
       '(js/typeof x))

     (check-jst-parse-ok "receiver-first member operators with selectors"
       '(js/get object .field)
       '(js/call object .method 1 2)
       '(js/set! object .field 3)
       '(js/delete! object .field)
       '(js/in? object .field))

     (check-jst-parse-ok "receiver-first member operators with dynamic keys"
       '(js/get object key)
       '(js/call object key 1 2)
       '(js/set! object key 3)
       '(js/delete! object key)
       '(js/in? object key))

     (check-jst-parse-ok "js/new"
       '(js/new Constructor 1 2))

     (check-jst-parse-err "js/get requires receiver and key"
       '(js/get object))

     (check-jst-parse-err "js/get rejects extra operands"
       '(js/get object .field extra))

     (check-jst-parse-err "js/call requires receiver and key"
       '(js/call object))

     (check-jst-parse-err "js/set! requires receiver key and value"
       '(js/set! object .field))

     (check-jst-parse-err "js/set! rejects extra operands"
       '(js/set! object .field value extra))

     (check-jst-parse-err "js/new requires a constructor"
       '(js/new))

     (check-jst-parse-err "js/delete! requires receiver and key"
       '(js/delete! object))

     (check-jst-parse-err "js/delete! rejects extra operands"
       '(js/delete! object .field extra))

     (check-jst-parse-err "js/in? requires receiver and key"
       '(js/in? object))

     (check-jst-parse-err "js/in? rejects extra operands"
       '(js/in? object .field extra))

     (check-jst-parse-ok "js/export function"
       '(js/export (defn main [] Int 0)))

     (check-jst-parse-ok "js/export class"
       '(js/export (js/class App
          (constructor []
            Nil
            (js/return)))))

     (check-jst-parse-ok "js/return bare"
       '(defn f [] Nil (js/return)))

     (check-jst-parse-ok "js/return with value"
       '(defn f [] Int (js/return 42)))

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

     (test-case "super is lexical only inside a derived js/class"
       (define emitted
         (jst-emit
          (jst-preamble
           '(declare-extern Error Any)
           '(js/class Child extends Error
              (constructor [(message String)]
                Nil
                (super message)
                (js/return))))))
       (check-true (string-contains? emitted "super(message);"))
       (for ([forms
              (in-list
               (list
                (jst-preamble
                 '(js/class Child
                    (constructor [(message String)]
                      Nil
                      (super message)
                      (js/return))))
                (jst-preamble
                 '(declare-extern Error Any)
                 '(js/class Child extends Error
                    (constructor [(message String)] Nil (js/return)))
                 '(defn stray [(message String)] Any (super message)))))])
         (check-exn
          #rx"unresolved function `super`"
          (lambda () (type-check! (jst-parse forms))))))

     (test-case "js/class rejected in CLJ target"
       (check-exn
        exn:fail?
        (lambda ()
          (define prog (jst-parse (list '(ns test.app)
                                        '(js/class Foo (constructor [] Nil (js/return))))))
          (type-check! prog))))

     (test-case "member operators are rejected outside the JS target"
       (for ([form (in-list '((js/get object .field)
                              (js/call object .method)
                              (js/set! object .field 1)
                              (js/new Constructor)
                              (js/delete! object .field)
                              (js/in? object .field)
                              (js/typeof object)))])
         (check-exn
          exn:fail?
          (lambda ()
            (define prog
              (jst-parse
               (list '(ns test.app)

                     '(declare-extern object Any)
                     '(declare-extern key Any)
                     '(declare-extern Constructor Any)
                     `(def result Any ,form))))
            (type-check! prog)))))

   ) ;; end type-check suite

   ;; ===== Emission =====
   (test-suite "emit"

     (check-jst-emit "js/+ binary"
       "(a + b)"
       '(def r Any (js/+ a b)))

     (check-jst-emit "js/=== binary"
       "(a === b)"
       '(def r Any (js/=== a b)))

     (check-jst-emit "js/&& binary"
       "(a && b)"
       '(def r Any (js/&& a b)))

     (check-jst-emit "js/|| binary"
       "(a || b)"
       '(def r Any (js/|| a b)))

     (check-jst-emit "js/?? binary"
       "(a ?? b)"
       '(def r Any (js/?? a b)))

     (check-jst-emit "js/! unary"
       "!done"
       '(def r Any (js/! done)))

     (check-jst-emit "js/typeof"
       "typeof x"
       '(def r Any (js/typeof x)))

     (check-jst-emit "js/get selector"
       "object.field"
       '(def r Any (js/get object .field)))

     (check-jst-emit "js/get dynamic key"
       "object[key]"
       '(def r Any (js/get object key)))

     (check-jst-emit "js/call selector"
       "object.method(1, 2)"
       '(def r Any (js/call object .method 1 2)))

     (check-jst-emit "js/call dynamic key"
       "object[key](1, 2)"
       '(def r Any (js/call object key 1 2)))

     (check-jst-emit "js/set! selector"
       "object.field = 3"
       '(def r Any (js/set! object .field 3)))

     (check-jst-emit "js/new"
       "new Constructor(1, 2)"
       '(def r Any (js/new Constructor 1 2)))

     (check-jst-emit "js/delete! selector"
       "delete object.field"
       '(def r Bool (js/delete! object .field)))

     (check-jst-emit "js/in? selector"
       "\"field\" in object"
       '(def r Bool (js/in? object .field)))

     (check-jst-emit "js/template"
       "`Hello, ${name}!`"
       '(def msg Any (js/template "Hello, " name "!")))

     (check-jst-emit "js/spread"
       "...items"
       '(def arr Any (js/spread items)))

     (check-jst-emit "js/return"
       "return 42;"
       '(defn f [] Int (js/return 42)))

     (check-jst-emit "bare js/return"
       "return;"
       '(defn f [] Nil (js/return)))

     (check-jst-emit "js/class declaration"
       "class Animal {"
       '(js/class Animal
          (constructor [(name String)]
            Any
            (js/set! this .name name))))

     (check-jst-emit "class constructor"
       "constructor(name)"
       '(js/class Animal
          (constructor [(name String)]
            Any
            (js/set! this .name name))))

     (check-jst-emit "class with extends"
       "class Dog extends Animal {"
       '(js/class Dog extends Animal
          (speak []
            String
            (js/return "woof"))))

     (check-jst-emit "js/export class"
       "export class"
       '(js/export (js/class App
          (constructor []
            Nil
            (js/return)))))

     (check-jst-emit "js/export def"
       "export const"
       '(js/export (def x 42)))

     (check-jst-emit "js/export defn"
       "export function"
       '(js/export (defn main [] Int 0)))

   ) ;; end emit suite

   ;; ===== Complex examples =====
   (test-suite "complex"

     (check-jst-emit "class with static method"
       "static create"
       '(js/class Config
          (constructor [(data Any)]
            Any
            (js/set! this .data data))
          (static create [(path String)]
            Any
            (js/return
              (js/new Config (js/call JSON .parse path))))))

   ) ;; end complex suite
 ))
