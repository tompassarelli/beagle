#lang racket/base

;; Tests for js/quote — structural JavaScript quasiquotation

(require rackunit
         rackunit/text-ui
         racket/string
         racket/match
         racket/port
         beagle/private/parse
         beagle/private/check
         beagle/private/emit
         beagle/private/types)

(define (br . xs) (cons BRACKET-TAG xs))
(define (mt . xs) (cons MAP-TAG xs))

(define (js-emit src-forms)
  (define prog
    (parse-program
     (map (lambda (f) (datum->syntax #f f)) src-forms)
     #:source-path "test.rkt"))
  (type-check! prog)
  (emit-program prog))

(define (js-parse src-forms)
  (parse-program
   (map (lambda (f) (datum->syntax #f f)) src-forms)
   #:source-path "test.rkt"))

(define-syntax-rule (check-js-contains name expected-str form ...)
  (test-case name
    (define result (js-emit (list '(ns test.app) '(define-mode strict) '(define-target js) form ...)))
    (check-true (string-contains? result expected-str)
                (format "expected ~v in:\n~a" expected-str result))))

(define-syntax-rule (check-js-quote name expected-str body ...)
  (test-case name
    (define result (js-emit (list '(ns test.app) '(define-mode strict) '(define-target js) body ...)))
    (check-true (string-contains? result expected-str)
                (format "expected ~v in:\n~a" expected-str result))))

(define-syntax-rule (check-js-parse-ok name form ...)
  (test-case name
    (check-not-exn (lambda () (js-parse (list '(ns test.app) '(define-mode strict) '(define-target js) form ...))))))

(define-syntax-rule (check-js-parse-err name form ...)
  (test-case name
    (check-exn exn:fail? (lambda () (js-parse (list '(ns test.app) '(define-mode strict) '(define-target js) form ...))))))

(run-tests
 (test-suite "js/quote"

   ;; ===== Parsing =====
   (test-suite "parse"

     (check-js-parse-ok "simple const"
       '(js/quote (const x 42)))

     (check-js-parse-ok "function declaration"
       '(js/quote (function hello (name)
                    (return (+ name " world")))))

     (check-js-parse-ok "multiple statements"
       '(js/quote
         (const x 1)
         (const y 2)
         (return (+ x y))))

     (check-js-parse-ok "if statement"
       '(js/quote
         (if (> x 0)
           (return x)
           else
           (return (- 0 x)))))

     (check-js-parse-ok "while loop"
       '(js/quote
         (while (> n 0)
           (= n (- n 1)))))

     (check-js-parse-ok "for-of loop"
       '(js/quote
         (for-of item items
           (console.log item))))

     (check-js-parse-ok "try-catch-finally"
       '(js/quote
         (try
           (const data (fetchData))
           (catch e
             (console.log e))
           (finally
             (cleanup)))))

     (check-js-parse-ok "arrow function expression"
       '(js/quote (const add (=> (a b) (+ a b)))))

     (check-js-parse-ok "ternary expression"
       '(js/quote (const result (? (> x 0) "positive" "non-positive"))))

     (check-js-parse-ok "template literal"
       '(js/quote (const msg (tpl "Hello, " name "!"))))

     (check-js-parse-ok "array literal with brackets"
       `(js/quote (const arr ,(br 1 2 3))))

     (check-js-parse-ok "object literal with braces"
       `(js/quote (const obj ,(mt 'name "Alice" 'age 30))))

     (check-js-parse-ok "new expression"
       '(js/quote (const d (new Date))))

     (check-js-parse-ok "await expression"
       '(js/quote (const data (await (fetch "/api")))))

     (check-js-parse-ok "typeof expression"
       '(js/quote (const t (typeof x))))

     (check-js-parse-ok "spread in array"
       `(js/quote (const combined ,(br 1 2 '(spread rest)))))

     (check-js-parse-ok "class declaration"
       '(js/quote
         (class Animal
           (constructor (name)
             (= this.name name))
           (speak ()
             (return this.name)))))

     (check-js-parse-ok "export async function"
       '(js/quote
         (export (async function fetchData (url)
                   (const response (await (fetch url)))
                   (return response)))))

     (check-js-parse-ok "class with extends"
       '(js/quote
         (class Dog extends Animal
           (speak ()
             (return (tpl "" this.name " barks"))))))

   ) ;; end parse suite

   ;; ===== Emission =====
   (test-suite "emit"

     (check-js-quote "const declaration"
       "const x = 42;"
       '(js/quote (const x 42)))

     (check-js-quote "let declaration"
       "let count = 0;"
       '(js/quote (let count 0)))

     (check-js-quote "string literal"
       "const name = \"Alice\";"
       '(js/quote (const name "Alice")))

     (check-js-quote "boolean literal"
       "const flag = true;"
       '(js/quote (const flag true)))

     (check-js-quote "null literal"
       "const x = null;"
       '(js/quote (const x null)))

     (check-js-quote "function declaration"
       "function add(a, b)"
       '(js/quote (function add (a b)
                    (return (+ a b)))))

     (check-js-quote "function body has return"
       "return (a + b);"
       '(js/quote (function add (a b)
                    (return (+ a b)))))

     (check-js-quote "async function"
       "async function fetchData(url)"
       '(js/quote (async (function fetchData (url)
                    (return url)))))

     (check-js-quote "export function"
       "export function"
       '(js/quote (export (function main ()
                    (return 0)))))

     (check-js-quote "export async function"
       "export async function"
       '(js/quote (export (async (function handler (req)
                    (return req))))))

     (check-js-quote "return statement"
       "return 42;"
       '(js/quote (return 42)))

     (check-js-quote "bare return"
       "return;"
       '(js/quote (return)))

     (check-js-quote "if statement"
       "if (x)"
       '(js/quote (if x (return 1))))

     (check-js-quote "if-else statement"
       "} else {"
       '(js/quote (if x (return 1) else (return 0))))

     (check-js-quote "while loop"
       "while ((n > 0))"
       '(js/quote (while (> n 0) (= n (- n 1)))))

     (check-js-quote "for-of loop"
       "for (const item of items)"
       '(js/quote (for-of item items (console.log item))))

     (check-js-quote "throw statement"
       "throw new Error(\"oops\");"
       '(js/quote (throw (new Error "oops"))))

     (check-js-quote "try-catch"
       "try {"
       '(js/quote (try (doSomething) (catch e (handleError e)))))

     (check-js-quote "catch clause"
       "catch (e)"
       '(js/quote (try (doSomething) (catch e (handleError e)))))

     (check-js-quote "finally clause"
       "finally {"
       '(js/quote (try (doSomething) (catch e (log e)) (finally (cleanup)))))

     (check-js-quote "binary +"
       "(a + b)"
       '(js/quote (const r (+ a b))))

     (check-js-quote "binary ==="
       "(a === b)"
       '(js/quote (const r (=== a b))))

     (check-js-quote "binary and (&&)"
       "(a && b)"
       '(js/quote (const r (and a b))))

     (check-js-quote "binary or (||)"
       "(a || b)"
       '(js/quote (const r (or a b))))

     (check-js-quote "binary nullish (??)"
       "(a ?? b)"
       '(js/quote (const r (nullish a b))))

     (check-js-quote "unary !"
       "!done"
       '(js/quote (const r (! done))))

     (check-js-quote "typeof"
       "typeof x"
       '(js/quote (const r (typeof x))))

     (check-js-quote "ternary"
       "(x ? 1 : 0)"
       '(js/quote (const r (? x 1 0))))

     (check-js-quote "arrow function"
       "(x) => (x + 1)"
       '(js/quote (const inc (=> (x) (+ x 1)))))

     (check-js-quote "template literal"
       "`Hello, ${name}!`"
       '(js/quote (const msg (tpl "Hello, " name "!"))))

     (check-js-quote "method call"
       "console.log(\"hello\")"
       '(js/quote (.log console "hello")))

     (check-js-quote "chained method"
       "arr.filter"
       '(js/quote (const result (.filter arr (=> (x) (> x 0))))))

     (check-js-quote "computed index"
       "obj[key]"
       '(js/quote (const v (bracket obj key))))

     (check-js-quote "new expression"
       "new Map()"
       '(js/quote (const m (new Map))))

     (check-js-quote "await expression"
       "await fetch(\"/api\")"
       '(js/quote (const data (await (fetch "/api")))))

     (check-js-quote "spread"
       "...items"
       `(js/quote (const arr ,(br '(spread items)))))

     (check-js-quote "object literal"
       "name: \"Alice\""
       `(js/quote (const obj (object name "Alice" age 30))))

     (check-js-quote "member access via dot"
       "obj.name"
       '(js/quote (const v (dot obj name))))

     (check-js-quote "assignment"
       "x = 10;"
       '(js/quote (= x 10)))

     (check-js-quote "class declaration"
       "class Animal {"
       '(js/quote (class Animal
                    (constructor (name)
                      (= this.name name)))))

     (check-js-quote "class constructor"
       "constructor(name)"
       '(js/quote (class Animal
                    (constructor (name)
                      (= this.name name)))))

     (check-js-quote "class with extends"
       "class Dog extends Animal {"
       '(js/quote (class Dog extends Animal
                    (speak ()
                      (return "woof")))))

   ) ;; end emit suite

   ;; ===== Splices =====
   (test-suite "splices"

     (check-js-quote "splice expr in const value"
       "const greeting ="
       '(def name :- String "world")
       '(js/quote (const greeting ~name)))

     (check-js-quote "splice in function call"
       "alert("
       '(def msg :- String "hello")
       '(js/quote (alert ~msg)))

     (check-js-quote "splice in binary op"
       ;; splice beagle expression into JS AST binary op
       "const result ="
       '(def x :- Int 42)
       '(js/quote (const result (+ ~x 1))))

   ) ;; end splices suite

   ;; ===== Type checking =====
   (test-suite "type-check"

     (test-case "js/quote returns JsAst type"
       (define prog (js-parse (list '(ns test.app) '(define-mode strict) '(define-target js)
                                    '(def code :- JsAst (js/quote (const x 1))))))
       (check-not-exn (lambda () (type-check! prog))))

     (test-case "js/quote rejected in CLJ target"
       (check-exn
        exn:fail?
        (lambda ()
          (define prog (js-parse (list '(ns test.app) '(define-mode strict)
                                       '(js/quote (const x 1)))))
          (type-check! prog))))

   ) ;; end type-check suite

   ;; ===== Complex examples =====
   (test-suite "complex"

     (check-js-quote "REST API handler"
       "export async function"
       '(js/quote
         (export (async (function handleRequest (req res)
                    (try
                      (const data (await (.json req)))
                      (const result (await (processData data)))
                      (.json res (object status "ok" data result))
                      (catch error
                        (.status res 500)
                        (.json res (object status "error" message (dot error message))))))))))

     (check-js-quote "React component pattern"
       "function Counter"
       '(js/quote
         (function Counter (props)
           (const count (dot props initial))
           (return
             (object render (=> ()
               (tpl "<div>" count "</div>")))))))

     (check-js-quote "event listener setup"
       "addEventListener"
       '(js/quote
         (function setup ()
           (.addEventListener document "click"
             (=> (event)
               (const target (dot event target))
               (.preventDefault event)
               (handleClick target))))))

     (check-js-quote "async iteration"
       "for (const item of items)"
       '(js/quote
         (async (function processAll (items)
           (const results ,(br))
           (for-of item items
             (const result (await (process item)))
             (.push results result))
           (return results)))))

     (check-js-quote "class with static method"
       "static create"
       '(js/quote
         (class Config
           (constructor (data)
             (= this.data data))
           (static create (path)
             (const raw (readFileSync path "utf8"))
             (return (new Config (JSON.parse raw)))))))

   ) ;; end complex suite
 ))
