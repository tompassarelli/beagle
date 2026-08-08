#lang racket/base

;; `macro-eval` runs a `defmacro` body at expansion time. Its job is to build a
;; datum, so quasiquote and the typed-binding constructors must produce exactly
;; the shapes the parser accepts.

(require rackunit
         (only-in beagle/private/tags ANN-MARKER BRACKET-TAG)
         beagle/private/macro-eval)

(define (ev expr) (macro-eval expr (make-macro-env)))

;; `let` is macro-eval's only binder, so a test seeds values by wrapping.
(define (ev-let bindings expr)
  (macro-eval `(let ,(apply append
                            (map (lambda (p) (list (car p) (list 'quote (cdr p))))
                                 bindings))
                 ,expr)
              (make-macro-env)))

;; --- quasiquote --------------------------------------------------------------

(test-case "quasiquote returns its template literally"
  (check-equal? (ev '(quasiquote (defn f [] -> Float 1.0)))
                '(defn f [] -> Float 1.0)))

(test-case "unquote evaluates in place"
  (check-equal? (ev-let '((x . 42)) '(quasiquote (+ (unquote x) 1)))
                '(+ 42 1)))

(test-case "unquote splices a computed symbol into a definition head"
  (check-equal? (ev-let '((base . speed))
                        '(quasiquote (defn (unquote (format-symbol "~a-get" base)) [] -> Float 1.0)))
                '(defn speed-get [] -> Float 1.0)))

(test-case "unquote-splicing flattens a list into the surrounding form"
  (check-equal? (ev-let '((xs . (1.0 2.0 3.0))) '(quasiquote (+ (unquote-splicing xs))))
                '(+ 1.0 2.0 3.0)))

(test-case "unquote-splicing composes with literal neighbours"
  (check-equal? (ev-let '((xs . (2 3))) '(quasiquote (f 1 (unquote-splicing xs) 4)))
                '(f 1 2 3 4)))

(test-case "quasiquote nests through sub-forms"
  (check-equal? (ev-let '((n . x)) '(quasiquote (do (a (unquote n)) (b (unquote n)))))
                '(do (a x) (b x))))

(test-case "unquote-splicing rejects a non-list"
  (check-exn #rx"expected a list"
             (lambda () (ev-let '((v . 7)) '(quasiquote (+ (unquote-splicing v)))))))

(test-case "unquote outside a template is an error, not a silent call"
  (check-exn #rx"outside a quasiquote"
             (lambda () (ev '(unquote x)))))

;; --- typed bindings are FLAT in their vector ---------------------------------

(test-case "vec splices a param into the flat shape the parser accepts"
  ;; `[v: Float]` is three items in the vector, never a nested triple:
  ;; a nested `(v #%: Float)` is the retired parenthesized spelling.
  (check-equal? (ev '(vec (make-param (quote v) (quote Float))))
                (list BRACKET-TAG 'v ANN-MARKER 'Float)))

(test-case "vec splices several params, staying flat"
  (check-equal? (ev '(vec (make-param (quote a) (quote Float))
                          (make-param (quote b) (quote Int))))
                (list BRACKET-TAG 'a ANN-MARKER 'Float 'b ANN-MARKER 'Int)))

(test-case "vec splices record fields the same way"
  (check-equal? (ev '(vec (make-field (quote x) (quote Float))))
                (list BRACKET-TAG 'x ANN-MARKER 'Float)))

(test-case "vec leaves ordinary values alone"
  (check-equal? (ev '(vec 1 2 3)) (list BRACKET-TAG 1 2 3)))

(test-case "vec does not splice a same-shaped list that is not an annotation"
  (check-equal? (ev '(vec (list 1 2 3))) (list BRACKET-TAG '(1 2 3))))

(test-case "syntax-name/type read one typed binder from its raw bracketed form"
  (check-equal?
   (ev-let `((binding . (,BRACKET-TAG value ,ANN-MARKER sim/Player)))
           '(list (syntax-name binding) (syntax-type binding)))
   '(value sim/Player)))

(test-case "make-defn with a spliced param vector parses as a typed signature"
  (check-equal? (ev '(make-defn (quote f)
                                (vec (make-param (quote v) (quote Float)))
                                (quote Float)
                                (quote v)))
                (list 'defn 'f (list BRACKET-TAG 'v ANN-MARKER 'Float) '-> 'Float 'v)))

;; --- codegen primitives ------------------------------------------------------
;; A macro body has no named recursion, so these must be enough on their own to
;; turn a field list into a form.

(test-case "partition regroups a flat typed vector into fields"
  (check-equal? (ev (list 'partition 3 (list 'quote (list 'x ANN-MARKER 'Float 'z ANN-MARKER 'Float))))
                (list (list 'x ANN-MARKER 'Float) (list 'z ANN-MARKER 'Float))))

(test-case "partition drops a trailing remainder rather than emitting a short group"
  (check-equal? (ev '(partition 2 (list 1 2 3))) '((1 2))))

(test-case "partition rejects a non-positive size"
  (check-exn #rx"positive integer" (lambda () (ev '(partition 0 (list 1 2))))))

(test-case "apply spreads a computed list into a variadic builtin"
  (check-equal? (ev '(apply list (list 1 2 3))) '(1 2 3))
  (check-equal? (ev '(apply list 0 (list 1 2))) '(0 1 2)))

(test-case "apply rejects a non-list final argument"
  (check-exn #rx"must be a list" (lambda () (ev '(apply list 7)))))

(test-case "mapcat flattens one level, which map cannot"
  (check-equal? (ev '(mapcat (fn [x] (list x x)) (list 1 2))) '(1 1 2 2)))

(test-case "mapcat rejects a function that does not return a list"
  (check-exn #rx"must return a list" (lambda () (ev '(mapcat (fn [x] x) (list 1 2))))))

(test-case "map-indexed supplies the position a wire slot needs"
  (check-equal? (ev '(map-indexed (fn [i x] (list i x)) (list (quote a) (quote b))))
                '((0 a) (1 b))))

(test-case "range builds the index list"
  (check-equal? (ev '(range 3)) '(0 1 2))
  (check-equal? (ev '(range 0)) '()))

(test-case "nth reads a positional slot and refuses to run off the end"
  (check-equal? (ev '(nth (list 10 20 30) 1)) 20)
  (check-exn #rx"out of range" (lambda () (ev '(nth (list 1) 5)))))

(test-case "lower-case names a record's accessors from its type name"
  (check-equal? (ev '(lower-case (quote Move))) "move")
  (check-equal? (ev '(format-symbol "~a-~a" (lower-case (quote Move)) (quote x))) 'move-x))

(test-case "count is the Clojure spelling of length"
  (check-equal? (ev '(count (list 1 2 3))) 3))

(test-case "collection operators see a raw bracketed vec as its elements"
  (check-equal?
   (ev-let `((fields . (,BRACKET-TAG x ,ANN-MARKER Int y ,ANN-MARKER String)))
           '(partition 3 fields))
   `((x ,ANN-MARKER Int) (y ,ANN-MARKER String))))

(test-case "distinct? sees duplicate names derived from a raw typed field vec"
  (check-false
   (ev-let `((fields . (,BRACKET-TAG id ,ANN-MARKER String id ,ANN-MARKER String)))
           '(let [parts (partition 3 fields)
                  field-names (map first parts)]
              (distinct? field-names)))))

(test-case "reduce preserves Clojure accumulator-item order"
  (check-equal? (ev '(reduce (fn [acc item] (- acc item)) 10 (list 1 2 3))) 4)
  (check-exn #rx"non-empty collection"
             (lambda () (ev '(reduce (fn [acc item] (+ acc item)) (list))))))

(test-case "nested quasiquote tracks depth and tagged vec splice strips its tag"
  (check-equal?
   (ev-let '((x . 9))
           '(quasiquote (quasiquote (a (unquote (unquote x))))))
   '(quasiquote (a (unquote 9))))
  (check-equal?
   (ev-let `((xs . (,BRACKET-TAG 1 2)))
           '(quasiquote (f (unquote-splicing xs) 3)))
   '(f 1 2 3)))

(test-case "cond uses canonical flat Clojure pairs"
  (check-equal? (ev '(cond false 1 (= 2 2) 2 :else 3)) 2)
  (check-equal? (ev '(cond false 1 :else 3)) 3)
  (check-exn #rx"cond needs an expression"
             (lambda () (ev '(cond true)))))
