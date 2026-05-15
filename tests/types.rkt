#lang racket/base

(require rackunit
         "../private/types.rkt")

;; --- parse-type ------------------------------------------------------------

(test-case "parse primitive types (one canonical name per type)"
  (check-eq? (type-prim-name (parse-type 'String))  'String)
  (check-eq? (type-prim-name (parse-type 'Long))    'Long)
  (check-eq? (type-prim-name (parse-type 'Double))  'Double)
  (check-eq? (type-prim-name (parse-type 'Boolean)) 'Boolean)
  (check-eq? (type-prim-name (parse-type 'Keyword)) 'Keyword)
  (check-eq? (type-prim-name (parse-type 'Symbol))  'Symbol)
  (check-eq? (type-prim-name (parse-type 'Nil))     'Nil)
  (check-eq? (type-prim-name (parse-type 'Any))     'Any))

(test-case "former aliases are now errors (removed in AI-optimization pass)"
  (check-exn exn:fail? (lambda () (parse-type 'Integer)))
  (check-exn exn:fail? (lambda () (parse-type 'Int)))
  (check-exn exn:fail? (lambda () (parse-type 'Float)))
  (check-exn exn:fail? (lambda () (parse-type 'Bool))))

(test-case "parse function type from bracketed expression"
  ;; #%brackets-tagged form: [A B -> R]
  (define t (parse-type `(,BRACKET-TAG Long Long -> Boolean)))
  (check-true (type-fn? t))
  (check-equal? (length (type-fn-params t)) 2)
  (check-eq? (type-prim-name (type-fn-ret t)) 'Boolean))

(test-case "parse parametric types"
  (define t (parse-type '(Vec String)))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Vec)
  (check-eq? (type-prim-name (car (type-app-args t))) 'String))

(test-case "parse nested parametric / function types"
  (define t (parse-type `(Map String ,(list BRACKET-TAG 'Long '-> 'Long))))
  (check-true (type-app? t))
  (check-eq? (type-app-ctor t) 'Map)
  (check-eq? (type-prim-name (car (type-app-args t))) 'String)
  (check-true (type-fn? (cadr (type-app-args t)))))

(test-case "unknown primitive errors"
  (check-exn exn:fail?
             (lambda () (parse-type 'Quaternion))))

(test-case "function type without arrow errors"
  (check-exn exn:fail?
             (lambda () (parse-type `(,BRACKET-TAG Long Long Long)))))

;; --- type-compatible? ------------------------------------------------------

(test-case "Any is compatible with anything"
  (check-true (type-compatible? (type-prim 'Any) (type-prim 'String)))
  (check-true (type-compatible? (type-prim 'String) (type-prim 'Any)))
  (check-true (type-compatible? (type-prim 'Any) (type-prim 'Any))))

(test-case "primitives compatible with themselves only"
  (check-true  (type-compatible? (type-prim 'String) (type-prim 'String)))
  (check-false (type-compatible? (type-prim 'String) (type-prim 'Long)))
  (check-false (type-compatible? (type-prim 'Boolean) (type-prim 'Long))))

(test-case "function type compatibility (v0 invariant params + return)"
  (define a (type-fn (list (type-prim 'Long)) #f (type-prim 'Boolean)))
  (define b (type-fn (list (type-prim 'Long)) #f (type-prim 'Boolean)))
  (define c (type-fn (list (type-prim 'String)) #f (type-prim 'Boolean)))
  (check-true  (type-compatible? a b))
  (check-false (type-compatible? a c)))

(test-case "variadic function type parses & checks"
  (define t (parse-type `(,BRACKET-TAG Long & Long -> Long)))
  (check-true  (type-fn? t))
  (check-equal? (length (type-fn-params t)) 1)
  (check-true  (type? (type-fn-rest-type t)))
  (check-eq?   (type-prim-name (type-fn-rest-type t)) 'Long))

(test-case "union type parses and checks both ways"
  (define u (parse-type '(U String Nil)))
  (check-true (type-union? u))
  ;; String <: (U String Nil)
  (check-true  (type-compatible? (type-prim 'String) u))
  ;; (U String Nil) </: String (could be Nil)
  (check-false (type-compatible? u (type-prim 'String)))
  ;; Nil <: (U String Nil)
  (check-true  (type-compatible? (type-prim 'Nil) u))
  ;; Long </: (U String Nil)
  (check-false (type-compatible? (type-prim 'Long) u)))

(test-case "parametric type compatibility"
  (define vs (type-app 'Vec (list (type-prim 'String))))
  (define vs2 (type-app 'Vec (list (type-prim 'String))))
  (define vl (type-app 'Vec (list (type-prim 'Long))))
  (check-true  (type-compatible? vs vs2))
  (check-false (type-compatible? vs vl)))

;; --- infer-literal-type ----------------------------------------------------

(test-case "infer literal types"
  (check-eq? (type-prim-name (infer-literal-type "hi"))    'String)
  (check-eq? (type-prim-name (infer-literal-type 42))      'Long)
  (check-eq? (type-prim-name (infer-literal-type 3.14))    'Double)
  (check-eq? (type-prim-name (infer-literal-type #t))      'Boolean)
  (check-eq? (type-prim-name (infer-literal-type 'nil))    'Nil)
  (check-eq? (type-prim-name (infer-literal-type 'true))   'Boolean)
  (check-eq? (type-prim-name (infer-literal-type 'false))  'Boolean)
  (check-eq? (type-prim-name (infer-literal-type ':kw))    'Keyword))
