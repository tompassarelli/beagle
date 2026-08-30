#lang racket/base

(require rackunit
         json
         racket/match
         beagle/private/types)

;; --- parse-type ------------------------------------------------------------

(test-case "parse primitive types (one canonical name per type)"
  (check-eq? (type-prim-name (parse-type 'String))  'String)
  (check-eq? (type-prim-name (parse-type 'Int))     'Int)
  (check-eq? (type-prim-name (parse-type 'Float))   'Float)
  (check-eq? (type-prim-name (parse-type 'Bool))    'Bool)
  (check-eq? (type-prim-name (parse-type 'Keyword)) 'Keyword)
  (check-eq? (type-prim-name (parse-type 'Symbol))  'Symbol)
  (check-eq? (type-prim-name (parse-type 'Nil))     'Nil)
  (check-eq? (type-prim-name (parse-type 'Any))     'Any)
  (check-eq? (type-prim-name (parse-type 'Regex))   'Regex))

(test-case "CLJ-ALIASES resolve to canonical names"
  (check-eq? (type-prim-name (parse-type 'Long))    'Int)
  (check-eq? (type-prim-name (parse-type 'Double))  'Float)
  (check-eq? (type-prim-name (parse-type 'Boolean)) 'Bool)
  (check-eq? (type-prim-name (parse-type 'Integer)) 'Int))

(test-case "Number resolves to (U Int Float)"
  (let ([t (parse-type 'Number)])
    (check-true (type-union? t))
    (define names (sort (map type-prim-name (type-union-alts t)) symbol<?))
    (check-not-false (memq 'Int names))
    (check-not-false (memq 'Float names))))

(test-case "parse canonical Fn type"
  (define t (parse-type `(Fn (,BRACKET-TAG Int Int) Bool)))
  (check-true (type-fn? t))
  (check-equal? (length (type-fn-params t)) 2)
  (check-eq? (type-prim-name (type-fn-ret t)) 'Bool))

(test-case "parse parametric types"
  (define t (parse-type '(Vec String)))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Vec)
  (check-eq? (type-prim-name (car (type-app-args t))) 'String))

(test-case "Buffer requires exactly one type argument"
  (define t (parse-type '(Buffer Float)))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Buffer)
  (check-exn #rx"type Buffer expects 1 argument, got 0"
             (lambda () (parse-type 'Buffer)))
  (check-exn #rx"type Buffer expects 1 argument, got 2"
             (lambda () (parse-type '(Buffer Float Int)))))

(test-case "TransientVec requires exactly one type argument"
  (define t (parse-type '(TransientVec Int)))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'TransientVec)
  (check-eq? (type-prim-name (car (type-app-args t))) 'Int)
  (check-exn #rx"type TransientVec expects 1 argument, got 0"
             (lambda () (parse-type 'TransientVec)))
  (check-exn #rx"type TransientVec expects 1 argument, got 2"
             (lambda () (parse-type '(TransientVec Int String)))))

(test-case "Regex keeps its scalar form and accepts exactly one match shape"
  (define shaped (parse-type '(Regex (HVec String String))))
  (check-true (type-app? shaped))
  (check-eq? (type-app-ctor shaped) 'Regex)
  (check-equal? (length (type-app-args shaped)) 1)
  (check-eq? (type-prim-name (parse-type 'Regex)) 'Regex)
  (check-exn #rx"type Regex expects 1 argument, got 0"
             (lambda () (parse-type '(Regex))))
  (check-exn #rx"type Regex expects 1 argument, got 2"
             (lambda () (parse-type '(Regex String String)))))

(test-case "parse nested parametric / function types"
  (define t (parse-type `(Map String (Fn (,BRACKET-TAG Int) Int))))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Map)
  (check-eq? (type-prim-name (car (type-app-args t))) 'String)
  (check-true (type-fn? (cadr (type-app-args t)))))

(test-case "unknown lowercase type errors"
  (check-exn exn:fail?
             (lambda () (parse-type 'nope))))

(test-case "user-defined capitalized type accepted"
  (check-eq? (type-prim-name (parse-type 'Employee)) 'Employee))

(test-case "retired arrow function type is rejected with canonical replacement"
  (check-exn #rx"arrow function types are not supported.*\\(Fn \\[ParamType"
             (lambda () (parse-type `(,BRACKET-TAG Int -> Int)))))

(test-case "bare type vector is rejected with canonical replacement"
  (check-exn #rx"vector is not a type expression.*\\(Fn \\[ParamType"
             (lambda () (parse-type `(,BRACKET-TAG Int Int)))))

(test-case "Fn requires a parameter vector"
  (check-exn #rx"parameters must be a vector"
             (lambda () (parse-type '(Fn Int Int)))))

(test-case "Fn has one return type"
  (check-exn #rx"requires exactly"
             (lambda () (parse-type `(Fn (,BRACKET-TAG Int) Int String)))))

;; --- type-compatible? ------------------------------------------------------

(test-case "Any is compatible with anything"
  (check-true (type-compatible? (type-prim 'Any) (type-prim 'String)))
  (check-true (type-compatible? (type-prim 'String) (type-prim 'Any)))
  (check-true (type-compatible? (type-prim 'Any) (type-prim 'Any))))

(test-case "primitives compatible with themselves only"
  (check-true  (type-compatible? (type-prim 'String) (type-prim 'String)))
  (check-false (type-compatible? (type-prim 'String) (type-prim 'Int)))
  (check-false (type-compatible? (type-prim 'Bool) (type-prim 'Int))))

(test-case "function compatibility preserves call shapes, contravariant inputs, and covariant results"
  (define string (type-prim 'String))
  (define nullable-string (type-union (list string (type-prim 'Nil))))
  (define int (type-prim 'Int))
  (define float (type-prim 'Float))
  (define any (type-prim 'Any))
  (define bool (type-prim 'Bool))
  (define (fn-type params [rest #f] [ret bool]) (type-fn params rest ret))
  (define narrow-fn (fn-type (list string)))
  (define wide-fn (fn-type (list nullable-string)))
  (for ([case
         (in-list
          (list
           (list "same fixed shape" (fn-type (list string)) (fn-type (list string)) #t)
           (list "actual requires too many args" (fn-type (list string string)) (fn-type (list string)) #f)
           (list "actual accepts too few fixed args" (fn-type (list string)) (fn-type (list string string)) #f)
           (list "rest-only actual accepts zero args" (fn-type '() string) (fn-type '()) #t)
           (list "fixed-plus-rest actual absorbs expected tail" (fn-type (list string) string) (fn-type (list string string)) #t)
           (list "actual fixed prefix cannot exceed expected" (fn-type (list string string) string) (fn-type (list string)) #f)
           (list "fixed actual cannot satisfy variadic expected" (fn-type (list string)) (fn-type (list string) string) #f)
           (list "rest-only actual satisfies fixed-plus-rest expected" (fn-type '() string) (fn-type (list string) string) #t)
           (list "longer actual prefix cannot satisfy shorter variadic expected" (fn-type (list string string) string) (fn-type (list string) string) #f)
           (list "wider nullable actual parameter domain" (fn-type (list nullable-string)) (fn-type (list string)) #t)
           (list "narrower actual parameter domain" (fn-type (list string)) (fn-type (list nullable-string)) #f)
           (list "wider nullable actual rest domain" (fn-type '() nullable-string) (fn-type '() string) #t)
           (list "narrower actual rest domain" (fn-type '() string) (fn-type '() nullable-string) #f)
           (list "nullable rest absorbs nonnullable fixed tail" (fn-type (list string) nullable-string) (fn-type (list string string)) #t)
           (list "covariant nullable result widening" (fn-type '() #f string) (fn-type '() #f nullable-string) #t)
           (list "covariant result rejects narrowing" (fn-type '() #f nullable-string) (fn-type '() #f string) #f)
           (list "numeric parameter contravariance" (fn-type (list float)) (fn-type (list int)) #t)
           (list "numeric parameter rejects reverse widening" (fn-type (list int)) (fn-type (list float)) #f)
           (list "numeric result covariance" (fn-type '() #f int) (fn-type '() #f float) #t)
           (list "numeric result rejects reverse widening" (fn-type '() #f float) (fn-type '() #f int) #f)
           (list "Any parameter remains an explicit escape" (fn-type (list any)) (fn-type (list string)) #t)
           (list "Any expected parameter remains an explicit escape" (fn-type (list string)) (fn-type (list any)) #t)
           (list "Any does not erase arity" (fn-type (list any) #f any) (fn-type (list any any) #f any) #f)
           (list "nested function parameter contravariance" (fn-type (list narrow-fn)) (fn-type (list wide-fn)) #t)
           (list "nested function parameter rejects reverse" (fn-type (list wide-fn)) (fn-type (list narrow-fn)) #f)))])
    (match-define (list label actual expected wanted) case)
    (check-equal? (type-compatible? actual expected) wanted label)))

(test-case "variadic function type parses & checks"
  (define t (parse-type `(Fn (,BRACKET-TAG Int & Int) Int)))
  (check-true  (type-fn? t))
  (check-equal? (length (type-fn-params t)) 1)
  (check-true  (type? (type-fn-rest-type t)))
  (check-eq?   (type-prim-name (type-fn-rest-type t)) 'Int))

(test-case "union type parses and checks both ways"
  (define u (parse-type '(U String Nil)))
  (check-true (type-union? u))
  ;; String <: (U String Nil)
  (check-true  (type-compatible? (type-prim 'String) u))
  ;; (U String Nil) </: String (could be Nil)
  (check-false (type-compatible? u (type-prim 'String)))
  ;; Nil <: (U String Nil)
  (check-true  (type-compatible? (type-prim 'Nil) u))
  ;; Int </: (U String Nil)
  (check-false (type-compatible? (type-prim 'Int) u)))

(test-case "parametric type compatibility"
  (define vs (type-app 'Vec (list (type-prim 'String))))
  (define vs2 (type-app 'Vec (list (type-prim 'String))))
  (define vl (type-app 'Vec (list (type-prim 'Int))))
  (check-true  (type-compatible? vs vs2))
  (check-false (type-compatible? vs vl)))

(test-case "Buffer element type is invariant"
  (define bf (type-app 'Buffer (list (type-prim 'Float))))
  (define ba (type-app 'Buffer (list (type-prim 'Any))))
  (check-true (type-compatible? bf bf))
  (check-false (type-compatible? bf ba))
  (check-false (type-compatible? ba bf)))

(test-case "TransientVec element type is invariant"
  (define vi (type-app 'TransientVec (list (type-prim 'Int))))
  (define va (type-app 'TransientVec (list (type-prim 'Any))))
  (check-true (type-compatible? vi vi))
  (check-false (type-compatible? vi va))
  (check-false (type-compatible? va vi)))

;; --- polymorphic types (forall) --------------------------------------------

(test-case "parse forall type"
  (define t (parse-type `(forall (A) (Fn (,BRACKET-TAG A) A))))
  (check-true (type-poly? t))
  (check-equal? (type-poly-vars t) '(A))
  (define body (type-poly-body t))
  (check-true (type-fn? body))
  (check-true (type-var? (car (type-fn-params body))))
  (check-eq? (type-var-name (car (type-fn-params body))) 'A))

(test-case "type-var is compatible with anything"
  (check-true (type-compatible? (type-var 'A) (type-prim 'Int)))
  (check-true (type-compatible? (type-prim 'Int) (type-var 'A))))

(test-case "infer-type-var-bindings matches fn arg types"
  (define expected (type-fn (list (type-var 'A)) #f (type-var 'B)))
  (define actual (type-fn (list (type-prim 'Int)) #f (type-prim 'String)))
  (define bindings (make-hasheq))
  (infer-type-var-bindings expected actual bindings)
  (check-eq? (type-prim-name (hash-ref bindings 'A)) 'Int)
  (check-eq? (type-prim-name (hash-ref bindings 'B)) 'String))

(test-case "apply-type-bindings replaces vars"
  (define bindings (make-hasheq))
  (hash-set! bindings 'A (type-prim 'Int))
  (define result (apply-type-bindings (type-app 'Vec (list (type-var 'A))) bindings))
  (check-true (type-app? result))
  (check-eq? (type-prim-name (car (type-app-args result))) 'Int))

(test-case "unbound type vars resolve to Any"
  (define bindings (make-hasheq))
  (define result (apply-type-bindings (type-var 'X) bindings))
  (check-true (type-prim? result))
  (check-eq? (type-prim-name result) 'Any))

;; --- infer-literal-type ----------------------------------------------------

(test-case "infer literal types"
  (check-eq? (type-prim-name (infer-literal-type "hi"))    'String)
  (check-eq? (type-prim-name (infer-literal-type 42))      'Int)
  (check-eq? (type-prim-name (infer-literal-type 3.14))    'Float)
  (check-eq? (type-prim-name (infer-literal-type #t))      'Bool)
  (check-eq? (type-prim-name (infer-literal-type 'nil))    'Nil)
  (check-eq? (type-prim-name (infer-literal-type 'true))   'Bool)
  (check-eq? (type-prim-name (infer-literal-type 'false))  'Bool)
  (check-eq? (type-prim-name (infer-literal-type ':kw))    'Keyword))

;; --- qualified type names ---------------------------------------------------

(test-case "parse structurally registered qualified type names"
  (register-qualified-type-name! 'cat/ProductId 'ProductId)
  (define t (parse-type 'cat/ProductId))
  (check-true (type-prim? t))
  (check-eq? (type-prim-name t) 'cat/ProductId))

(test-case "qualified and unqualified scalar types are compatible"
  (register-qualified-type-name! 'cat/ProductId 'ProductId)
  (register-qualified-type-name! 'ord/Amount 'Amount)
  (check-true (type-compatible? (type-prim 'cat/ProductId) (type-prim 'ProductId)))
  (check-true (type-compatible? (type-prim 'ProductId) (type-prim 'cat/ProductId)))
  (check-true (type-compatible? (type-prim 'ord/Amount) (type-prim 'Amount)))
  ;; Different base names are NOT compatible
  (check-false (type-compatible? (type-prim 'cat/ProductId) (type-prim 'CategoryId)))
  (check-false (type-compatible? (type-prim 'ord/Amount) (type-prim 'Timestamp)))
  ;; types.rkt no longer interprets slash-bearing symbols independently.
  (check-false
   (type-compatible? (type-prim 'unregistered/ProductId)
                     (type-prim 'ProductId))))

;; --- Promise type ----------------------------------------------------------

(test-case "parse (Promise T) parametric type"
  (define t (parse-type '(Promise String)))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Promise)
  (check-equal? (length (type-app-args t)) 1)
  (check-eq? (type-prim-name (car (type-app-args t))) 'String))

(test-case "(Promise T) compatible with itself"
  (define a (type-app 'Promise (list (type-prim 'String))))
  (define b (type-app 'Promise (list (type-prim 'String))))
  (check-true (type-compatible? a b)))

(test-case "(Promise String) not compatible with (Promise Int)"
  (define a (type-app 'Promise (list (type-prim 'String))))
  (define b (type-app 'Promise (list (type-prim 'Int))))
  (check-false (type-compatible? a b)))

;; --- type->jsexpr: structured serialization for the repair compiler --------

(test-case "type->jsexpr structures every type constructor (MessageData core)"
  (define p (type->jsexpr (type-prim 'Int)))
  (check-equal? (hash-ref p 'kind) "prim")
  (check-equal? (hash-ref p 'name) "Int")
  (check-equal? (hash-ref p 'repr) "Int")
  (define v (type->jsexpr (type-app 'Vec (list (type-prim 'Int)))))
  (check-equal? (hash-ref v 'kind) "app")
  (check-equal? (hash-ref v 'ctor) "Vec")
  (check-equal? (hash-ref v 'repr) "(Vec Int)")
  (check-equal? (map (lambda (a) (hash-ref a 'name)) (hash-ref v 'args)) (list "Int"))
  (define f (type->jsexpr (type-fn (list (type-prim 'Int)) #f (type-prim 'Bool))))
  (check-equal? (hash-ref f 'kind) "fn")
  (check-equal? (hash-ref (hash-ref f 'ret) 'name) "Bool")
  ;; pure jsexpr — serializes straight into the JSON error stream
  (check-true (jsexpr? v))
  (check-true (jsexpr? f)))
