#lang racket/base

;; Beagle's v0 type system.
;;
;;   primitives:   String, Long, Integer, Int, Double, Float, Boolean, Bool,
;;                 Keyword, Symbol, Nil, Any
;;   function:     [A B -> R]              fixed arity
;;                 [A B & T -> R]           variadic; tail args of type T
;;   parametric:   (Vec T), (List T), (Set T), (Map K V)
;;   union:        (U String Nil)
;;
;; `Any` is universal; matches anything in either direction. Skipped entirely
;; in dynamic mode.

(require racket/match
         racket/format)

(define BRACKET-TAG '#%brackets)

(define PRIMITIVES
  '(String Long Integer Int Double Float Boolean Bool
    Keyword Symbol Nil Any))

(define PRIM-ALIASES
  '((Integer . Long)
    (Int     . Long)
    (Float   . Double)
    (Bool    . Boolean)))

(define PARAMETRIC-CTORS
  '(Vec List Set Map))

;; --- type AST --------------------------------------------------------------

(struct type-prim  (name)                      #:transparent)
(struct type-fn    (params rest-type ret)      #:transparent)  ; rest-type: type or #f
(struct type-app   (ctor args)                 #:transparent)
(struct type-union (alts)                      #:transparent)

(define (type? x)
  (or (type-prim? x) (type-fn? x) (type-app? x) (type-union? x)))

;; --- parsing types from source datums --------------------------------------

(define (parse-type t)
  (cond
    ;; [A B [& T] -> R] form (function, possibly variadic)
    [(and (pair? t) (eq? (car t) BRACKET-TAG))
     (parse-fn-type (cdr t))]

    ;; (U A B C) union
    [(and (pair? t) (eq? (car t) 'U))
     (when (null? (cdr t))
       (error 'beagle "empty union type: ~v" t))
     (type-union (map parse-type (cdr t)))]

    ;; (Vec T), (Map K V), etc.
    [(and (pair? t) (memq (car t) PARAMETRIC-CTORS))
     (type-app (car t) (map parse-type (cdr t)))]

    ;; primitive symbol
    [(symbol? t)
     (define canonical
       (cond
         [(assq t PRIM-ALIASES) => cdr]
         [else t]))
     (unless (member canonical PRIMITIVES)
       (error 'beagle
              "unknown type: ~a~nexpected primitive, [A B -> R], (Vec T)/(Map K V)/etc., or (U ...)"
              t))
     (type-prim canonical)]

    [else
     (error 'beagle "bad type expression: ~v" t)]))

(define (parse-fn-type bracket-contents)
  ;; Split on `->` to find params vs return.
  (define arrow-pos
    (let loop ([rest bracket-contents] [i 0])
      (cond
        [(null? rest)
         (error 'beagle "function type missing `->`: ~v"
                (cons BRACKET-TAG bracket-contents))]
        [(eq? (car rest) '->) i]
        [else (loop (cdr rest) (+ i 1))])))
  (define before-arrow (take* bracket-contents arrow-pos))
  (define after-arrow  (drop* bracket-contents (+ arrow-pos 1)))
  (unless (= (length after-arrow) 1)
    (error 'beagle "function type must have exactly one return type: ~v"
           (cons BRACKET-TAG bracket-contents)))
  ;; Detect `& T` for variadic: if `&` appears, the type after it is the
  ;; rest-type; before it are fixed params.
  (define-values (fixed-params rest-type)
    (let loop ([rest before-arrow] [acc '()])
      (cond
        [(null? rest) (values (reverse acc) #f)]
        [(eq? (car rest) '&)
         (when (not (= (length (cdr rest)) 1))
           (error 'beagle "function type: `&` must be followed by exactly one rest-type"))
         (values (reverse acc) (parse-type (cadr rest)))]
        [else (loop (cdr rest) (cons (parse-type (car rest)) acc))])))
  (type-fn fixed-params rest-type (parse-type (car after-arrow))))

(define (take* xs n)
  (if (or (zero? n) (null? xs)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))
(define (drop* xs n)
  (if (or (zero? n) (null? xs)) xs (drop* (cdr xs) (- n 1))))

;; --- compatibility ---------------------------------------------------------

(define (type-compatible? actual expected)
  (cond
    [(or (not actual) (not expected)) #t]
    [(any-type? actual)   #t]
    [(any-type? expected) #t]

    ;; Union on the expected side: actual must match SOME alternative.
    [(type-union? expected)
     (ormap (lambda (alt) (type-compatible? actual alt))
            (type-union-alts expected))]

    ;; Union on the actual side: ALL alts must satisfy expected.
    [(type-union? actual)
     (andmap (lambda (alt) (type-compatible? alt expected))
             (type-union-alts actual))]

    ;; Primitives match by canonical name.
    [(and (type-prim? actual) (type-prim? expected))
     (eq? (type-prim-name actual) (type-prim-name expected))]

    ;; Function compatibility: same fixed-arity, compatible params, compatible
    ;; rest-types (or both absent), compatible return.
    [(and (type-fn? actual) (type-fn? expected))
     (and (= (length (type-fn-params actual)) (length (type-fn-params expected)))
          (andmap type-compatible?
                  (type-fn-params actual)
                  (type-fn-params expected))
          (eq? (and (type-fn-rest-type actual) #t)
               (and (type-fn-rest-type expected) #t))
          (or (not (type-fn-rest-type actual))
              (type-compatible? (type-fn-rest-type actual)
                                (type-fn-rest-type expected)))
          (type-compatible? (type-fn-ret actual) (type-fn-ret expected)))]

    [(and (type-app? actual) (type-app? expected))
     (and (eq? (type-app-ctor actual) (type-app-ctor expected))
          (= (length (type-app-args actual)) (length (type-app-args expected)))
          (andmap type-compatible? (type-app-args actual) (type-app-args expected)))]

    [else #f]))

(define (any-type? t)
  (and (type-prim? t) (eq? (type-prim-name t) 'Any)))

(define (type->string t)
  (cond
    [(not t) "?"]
    [(type-prim? t) (symbol->string (type-prim-name t))]
    [(type-fn? t)
     (define rest (type-fn-rest-type t))
     (format "[~a~a -> ~a]"
             (string-join (map type->string (type-fn-params t)) " ")
             (if rest (format " & ~a" (type->string rest)) "")
             (type->string (type-fn-ret t)))]
    [(type-app? t)
     (format "(~a ~a)"
             (type-app-ctor t)
             (string-join (map type->string (type-app-args t)) " "))]
    [(type-union? t)
     (format "(U ~a)"
             (string-join (map type->string (type-union-alts t)) " "))]
    [else (~v t)]))

(define (string-join xs sep)
  (cond
    [(null? xs) ""]
    [(null? (cdr xs)) (car xs)]
    [else (string-append (car xs) sep (string-join (cdr xs) sep))]))

;; --- inferring types of literal expressions --------------------------------

(define (infer-literal-type v)
  (cond
    [(string? v)         (type-prim 'String)]
    [(boolean? v)        (type-prim 'Boolean)]
    [(exact-integer? v)  (type-prim 'Long)]
    [(real? v)           (type-prim 'Double)]
    [(eq? v 'nil)        (type-prim 'Nil)]
    [(eq? v 'true)       (type-prim 'Boolean)]
    [(eq? v 'false)      (type-prim 'Boolean)]
    [(and (symbol? v)
          (positive? (string-length (symbol->string v)))
          (char=? (string-ref (symbol->string v) 0) #\:))
     (type-prim 'Keyword)]
    [else                #f]))

;; The built-in environment (BUILTIN-ENV) lives in stdlib-types.rkt to avoid
;; a circular dependency (stdlib-types.rkt needs the type constructors from
;; this module). Consumers should import STDLIB-TYPES directly.

(provide
 BRACKET-TAG
 (struct-out type-prim)
 (struct-out type-fn)
 (struct-out type-app)
 (struct-out type-union)
 type?
 any-type?
 parse-type
 type-compatible?
 type->string
 infer-literal-type)
