#lang racket/base

;; Tests for typed JS target AST (js/* forms)

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
 (test-suite "jst — typed JS target AST"

   ;; ===== Parsing =====
   (test-suite "parse"

     (check-jst-parse-ok "js/const"
       '(js/const x 42))

     (check-jst-parse-ok "js/const with type"
       '(js/const x : Int 42))

     (check-jst-parse-ok "js/let"
       '(js/let count 0))

     (check-jst-parse-ok "js/fn"
       '(js/fn add [(a : Int) (b : Int)] : Int
          (js/return (js/+ a b))))

     (check-jst-parse-ok "js/async-fn"
       '(js/async-fn fetchData [(url : String)]
          (js/return (js/await (js/call fetch url)))))

     (check-jst-parse-ok "js/arrow"
       '(js/arrow [(x : Int)] (js/+ x 1)))

     (check-jst-parse-ok "js/async-arrow"
       '(js/async-arrow [(url : String)]
          (js/await (js/call fetch url))))

     (check-jst-parse-ok "js/call"
       '(js/call console.log "hello"))

     (check-jst-parse-ok "js/if with else"
       '(js/if (js/> x 0)
          (js/return x)
          else
          (js/return (js/- 0 x))))

     (check-jst-parse-ok "js/?"
       '(js/? (js/> x 0) "positive" "non-positive"))

     (check-jst-parse-ok "js/for-of"
       '(js/for-of item items
          (js/call console.log item)))

     (check-jst-parse-ok "js/while"
       '(js/while (js/> n 0)
          (js/set! n (js/- n 1))))

     (check-jst-parse-ok "js/try"
       '(js/try
          (js/const data (js/call fetchData))
          catch e
          (js/call console.log e)
          finally
          (js/call cleanup)))

     (check-jst-parse-ok "js/class"
       '(js/class Animal
          (constructor [(name : String)]
            (js/set! (js/. this name) name))
          (speak []
            (js/return (js/. this name)))))

     (check-jst-parse-ok "js/class with extends"
       '(js/class Dog extends Animal
          (speak []
            (js/return "woof"))))

     (check-jst-parse-ok "js/new"
       '(js/new Date))

     (check-jst-parse-ok "js/. member access"
       '(js/. obj name))

     (check-jst-parse-ok "js/.. computed index"
       '(js/.. arr 0))

     (check-jst-parse-ok "js/array"
       '(js/array 1 2 3))

     (check-jst-parse-ok "js/object"
       '(js/object name "Alice" age 30))

     (check-jst-parse-ok "js/template"
       '(js/template "Hello, " name "!"))

     (check-jst-parse-ok "js/spread"
       '(js/spread items))

     (check-jst-parse-ok "js/typeof"
       '(js/typeof x))

     (check-jst-parse-ok "js/do"
       '(js/do
          (js/const x 1)
          (js/const y 2)))

     (check-jst-parse-ok "js/export function"
       '(js/export (js/fn main []
          (js/return 0))))

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

     (test-case "js/fn rejected in CLJ target"
       (check-exn
        exn:fail?
        (lambda ()
          (define prog (jst-parse (list '(ns test.app) '(define-mode strict)
                                        '(js/fn hello [] (js/return 42)))))
          (type-check! prog))))

     (test-case "js/const infers type"
       (check-not-exn
        (lambda ()
          (jst-emit (jst-preamble '(js/const x : Int 42))))))

     (test-case "js/arrow returns function type"
       (check-not-exn
        (lambda ()
          (jst-emit (jst-preamble '(js/const inc (js/arrow [(x : Int)] (js/+ x 1))))))))

   ) ;; end type-check suite

   ;; ===== Emission =====
   (test-suite "emit"

     (check-jst-emit "js/const"
       "const x = 42;"
       '(js/const x 42))

     (check-jst-emit "js/let"
       "let count = 0;"
       '(js/let count 0))

     (check-jst-emit "js/fn"
       "function add(a, b)"
       '(js/fn add [(a : Int) (b : Int)] : Int
          (js/return (js/+ a b))))

     (check-jst-emit "js/fn body has return"
       "return (a + b);"
       '(js/fn add [(a : Int) (b : Int)] : Int
          (js/return (js/+ a b))))

     (check-jst-emit "js/async-fn"
       "async function fetchData(url)"
       '(js/async-fn fetchData [(url : String)]
          (js/return url)))

     (check-jst-emit "js/export fn"
       "export function"
       '(js/export (js/fn main []
          (js/return 0))))

     (check-jst-emit "js/return"
       "return 42;"
       '(js/fn f [] (js/return 42)))

     (check-jst-emit "bare js/return"
       "return;"
       '(js/fn f [] (js/return)))

     (check-jst-emit "js/if"
       "if (x)"
       '(js/fn f [(x : Bool)]
          (js/if x (js/return 1))))

     (check-jst-emit "js/if-else"
       "} else {"
       '(js/fn f [(x : Bool)]
          (js/if x (js/return 1) else (js/return 0))))

     (check-jst-emit "js/while"
       "while ((n > 0))"
       '(js/fn f [(n : Int)]
          (js/while (js/> n 0) (js/set! n (js/- n 1)))))

     (check-jst-emit "js/for-of"
       "for (const item of items)"
       '(js/fn f [(items : (Vec String))]
          (js/for-of item items (js/call console.log item))))

     (check-jst-emit "js/throw"
       "throw new Error(\"oops\");"
       '(js/fn f [] (js/throw (js/new Error "oops"))))

     (check-jst-emit "js/try"
       "try {"
       '(js/fn f []
          (js/try
            (js/call doSomething)
            catch e
            (js/call handleError e))))

     (check-jst-emit "catch clause"
       "catch (e)"
       '(js/fn f []
          (js/try
            (js/call doSomething)
            catch e
            (js/call handleError e))))

     (check-jst-emit "finally clause"
       "finally {"
       '(js/fn f []
          (js/try
            (js/call doSomething)
            catch e
            (js/call log e)
            finally
            (js/call cleanup))))

     (check-jst-emit "js/+ binary"
       "(a + b)"
       '(js/const r (js/+ a b)))

     (check-jst-emit "js/=== binary"
       "(a === b)"
       '(js/const r (js/=== a b)))

     (check-jst-emit "js/&& binary"
       "(a && b)"
       '(js/const r (js/&& a b)))

     (check-jst-emit "js/|| binary"
       "(a || b)"
       '(js/const r (js/|| a b)))

     (check-jst-emit "js/?? binary"
       "(a ?? b)"
       '(js/const r (js/?? a b)))

     (check-jst-emit "js/! unary"
       "!done"
       '(js/const r (js/! done)))

     (check-jst-emit "js/typeof"
       "typeof x"
       '(js/const r (js/typeof x)))

     (check-jst-emit "js/? ternary"
       "(x ? 1 : 0)"
       '(js/const r (js/? x 1 0)))

     (check-jst-emit "js/arrow"
       "(x) => (x + 1)"
       '(js/const inc (js/arrow [(x : Int)] (js/+ x 1))))

     (check-jst-emit "js/template"
       "`Hello, ${name}!`"
       '(js/const msg (js/template "Hello, " name "!")))

     (check-jst-emit "js/call dotted"
       "console.log(\"hello\")"
       '(js/call console.log "hello"))

     (check-jst-emit "js/.. index"
       "obj[key]"
       '(js/const v (js/.. obj key)))

     (check-jst-emit "js/new"
       "new Map()"
       '(js/const m (js/new Map)))

     (check-jst-emit "js/await"
       "await fetch(\"/api\")"
       '(js/const data (js/await (js/call fetch "/api"))))

     (check-jst-emit "js/spread"
       "...items"
       '(js/const arr (js/array (js/spread items))))

     (check-jst-emit "js/object"
       "name: \"Alice\""
       '(js/const obj (js/object name "Alice" age 30)))

     (check-jst-emit "js/. member access"
       "obj.name"
       '(js/const v (js/. obj name)))

     (check-jst-emit "js/set! assignment"
       "x = 10;"
       '(js/set! x 10))

     (check-jst-emit "js/class declaration"
       "class Animal {"
       '(js/class Animal
          (constructor [(name : String)]
            (js/set! (js/. this name) name))))

     (check-jst-emit "class constructor"
       "constructor(name)"
       '(js/class Animal
          (constructor [(name : String)]
            (js/set! (js/. this name) name))))

     (check-jst-emit "class with extends"
       "class Dog extends Animal {"
       '(js/class Dog extends Animal
          (speak []
            (js/return "woof"))))

   ) ;; end emit suite

   ;; ===== Complex examples =====
   (test-suite "complex"

     (check-jst-emit "REST API handler"
       "export async function"
       '(js/export (js/async-fn handleRequest [(req : Any) (res : Any)]
          (js/try
            (js/const data (js/await (js/call (js/. req json))))
            (js/const result (js/await (js/call processData data)))
            (js/call (js/. res json) (js/object status "ok" data result))
            catch error
            (js/call (js/. res status) 500)
            (js/call (js/. res json) (js/object status "error" message (js/. error message)))))))

     (check-jst-emit "async iteration"
       "for (const item of items)"
       '(js/async-fn processAll [(items : (Vec Any))]
          (js/const results (js/array))
          (js/for-of item items
            (js/const result (js/await (js/call process item)))
            (js/call (js/. results push) result))
          (js/return results)))

     (check-jst-emit "class with static method"
       "static create"
       '(js/class Config
          (constructor [(data : Any)]
            (js/set! (js/. this data) data))
          (static create [(path : String)]
            (js/const raw (js/call readFileSync path "utf8"))
            (js/return (js/new Config (js/call JSON.parse raw))))))

   ) ;; end complex suite
 ))
