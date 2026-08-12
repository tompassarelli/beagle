#lang racket/base

(require rackunit
         beagle/lang/reader-impl
         beagle/private/ast
         beagle/private/check
         beagle/private/parse
         beagle/private/stdlib-types
         beagle/private/types)

(define PRELUDE
  "(ns inference.test)\n(define-mode strict)\n(define-target clj)\n")

(define (read-forms source)
  (parameterize ([current-readtable beagle-readtable])
    (define input (open-input-string (string-append PRELUDE source)))
    (let loop ()
      (define form (read-syntax 'definition-inference input))
      (if (eof-object? form) '() (cons form (loop))))))

(define (checked source)
  (define program (parse-program (read-forms source)))
  (parameterize ([current-check-profile 2])
    (type-check! program))
  program)

(define (signature program name)
  (program-effective-definition-type
   program name
   (lambda () (error 'definition-inference "missing signature: ~a" name))))

(test-case "mandatory return constrains a bare identity parameter"
  (define program (checked "(defn identity [x] Int x)"))
  (check-equal? (type->string (signature program 'identity)) "[Int -> Int]")
  ;; Source authority remains annotation-free.
  (define function (car (program-forms program)))
  (check-false (param-type (car (defn-form-params function)))))

(test-case "unused bare parameter generalizes instead of degrading to Any"
  (define program (checked "(defn one [x] Int 1)"))
  (define inferred (signature program 'one))
  (check-true (inferred-type-poly? inferred))
  (check-equal? (type->string inferred) "(forall [A] [A -> Int])"))

(test-case "explicit Any remains authored Any and is not generalized"
  (define program (checked "(defn one [(x Any)] Int 1)"))
  (define declared (signature program 'one))
  (check-false (type-poly? declared))
  (check-equal? (type->string declared) "[Any -> Int]"))

(test-case "inferred polymorphic calls instantiate independently"
  (define program
    (checked
     (string-append
      "(defn one [x] Int 1)\n"
      "(defn from-string [] Int (one \"s\"))\n"
      "(defn from-int [] Int (one 42))")))
  (check-equal? (type->string (signature program 'one))
                "(forall [A] [A -> Int])"))

(test-case "calling a bare higher-order parameter infers its function shape"
  (define program (checked "(defn apply-one [f] Int (f 1))"))
  (check-equal? (type->string (signature program 'apply-one))
                "[[Int -> Int] -> Int]"))

(test-case "anonymous functions infer bare binders before call checking"
  (check-not-exn
   (lambda ()
     (checked "(defn use [] Int ((fn [x] Int x) 1))"))))

(test-case "mutually recursive letfn binders solve as one local group"
  (check-not-exn
   (lambda ()
     (checked
      (string-append
       "(defn use [] Int "
       "  (letfn [(left [x] Int (if true x (right x))) "
       "          (right [y] Int (if true y (left y)))] "
       "    (left 1)))")))))

(test-case "meta-free authored polymorphic values retain compatibility"
  ;; `first` is an authored forall value passed as map's callback.  The
  ;; definition solver must not feed that closed poly value to unification.
  (check-not-exn
   (lambda ()
     (checked "(defn heads [(tail Any)] Any (map first tail))"))))

(test-case "callee-before-caller and caller-before-callee infer identically"
  (define before
    (checked
     "(defn consume [(x Int)] Int x)\n(defn forward [x] Int (consume x))"))
  (define after
    (checked
     "(defn forward [x] Int (consume x))\n(defn consume [(x Int)] Int x)"))
  (check-equal? (type->string (signature before 'forward)) "[Int -> Int]")
  (check-equal? (type->string (signature after 'forward)) "[Int -> Int]"))

(test-case "direct recursion solves through its monomorphic provisional signature"
  (define program
    (checked
     "(defn recur-id [x] Int (if true x (recur-id x)))"))
  (check-equal? (type->string (signature program 'recur-id)) "[Int -> Int]"))

(test-case "mutual recursive SCC is source-order independent"
  (define first
    (checked
     (string-append
      "(defn evenish [x] Int (if true x (oddish x)))\n"
      "(defn oddish [y] Int (if true y (evenish y)))")))
  (define second
    (checked
     (string-append
      "(defn oddish [y] Int (if true y (evenish y)))\n"
      "(defn evenish [x] Int (if true x (oddish x)))")))
  (for ([program (in-list (list first second))]
        [unused (in-naturals)])
    (check-equal? (type->string (signature program 'evenish)) "[Int -> Int]")
    (check-equal? (type->string (signature program 'oddish)) "[Int -> Int]")))

(test-case "unconstrained mutual recursion generalizes deterministically"
  (define program
    (checked
     "(defn left [x] Int (right x))\n(defn right [y] Int 1)"))
  (check-equal? (type->string (signature program 'left))
                "(forall [A] [A -> Int])")
  (check-equal? (type->string (signature program 'right))
                "(forall [A] [A -> Int])"))

(test-case "multi-arity definitions infer and generalize their whole union"
  (define program
    (checked
     (string-append
      "(defn choose ([x] Int x) ([x y] String y))\n"
      "(defn use-one [] Int (choose 1))\n"
      "(defn use-two [] String (choose true \"ok\"))")))
  (define inferred (signature program 'choose))
  (check-equal? (type->string inferred)
                "(forall [A] (U [Int -> Int] [A String -> String]))")
  (check-equal? (free-type-metas inferred) '()))

(test-case "multi-arity variadic calls derive callable elements from rest vectors"
  (define program
    (checked
     (string-append
      "(defn collect ([] (Vec Int) []) "
      "  ([tag & more] (Vec Int) (distinct more)))\n"
      "(defn use [] (Vec Int) (collect true 1 2))")))
  (define inferred (signature program 'collect))
  (check-equal? (type->string inferred)
                "(forall [A] (U [ -> (Vec Int)] [A & Int -> (Vec Int)]))")
  (check-equal? (free-type-metas inferred) '()))

(test-case "lexical shadowing does not invent a top-level SCC edge"
  (define program
    (checked
     (string-append
      "(defn caller [] Int "
      "  (+ (shadow (fn [(x Int)] Int x)) "
      "     (shadow (fn [(x Int)] String \"s\"))))\n"
      "(defn shadow [caller] Int (do (caller 1) 1))")))
  (check-equal? (type->string (signature program 'shadow))
                "(forall [A] [[Int -> A] -> Int])"))

(test-case "typed destructuring remains aggregate-typed"
  (define program
    (checked "(defn first-of [([x y] (HVec Int String))] Int x)"))
  (check-equal? (type->string (signature program 'first-of))
                "[(HVec Int String) -> Int]"))

(test-case "typed rest aggregate separates body Vec from call element type"
  (define program
    (checked
     (string-append
      "(defn count-more [& (more (Vec Int))] Int (count more))\n"
      "(defn use [] Int (count-more 1 2 3))")))
  (check-equal? (type->string (signature program 'count-more))
                "[ & Int -> Int]"))

(test-case "scalar rest annotations are rejected instead of reinterpreted"
  (check-exn
   #rx"rest parameter annotation must describe its aggregate body binding"
   (lambda ()
     (checked "(defn old-rest [& (more Int)] Int 1)"))))

(test-case "bare rest infers an element and binds a vector in the body"
  (define program
    (checked "(defn count-more [& more] Int (count more))"))
  (check-equal? (type->string (signature program 'count-more))
                "(forall [A] [ & A -> Int])"))

(test-case "every finalized definition signature is meta-free"
  (define program
    (checked
     "(defn one [x] Int 1)\n(defn identity [x] Int x)"))
  (for ([name (in-list '(one identity))])
    (check-equal? (free-type-metas (signature program name)) '())))

(test-case "stdlib compound union signatures are canonical and solver-safe"
  (define replace-type
    (hash-ref (stdlib-for-target 'clj) 'clojure.string/replace))
  (define pattern-type (cadr (type-fn-params replace-type)))
  (check-true (type-union? pattern-type))
  (check-equal? (map type-prim-name (type-union-alts pattern-type))
                '(String Regex))
  (check-equal? (type->string replace-type)
                "[String (U String Regex) String -> String]")
  (check-not-exn
   (lambda ()
     (checked
      "(require clojure.string :as str)\n(defn clean [(s String)] String (str/replace s \"-\" \"_\"))"))))
