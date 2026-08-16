#lang racket/base

(require rackunit
         beagle/private/parse
         beagle/private/check
         beagle/private/types)

(define (check-prog . forms)
  (type-check!
   (parse-program
    (map (lambda (form) (datum->syntax #f form)) forms))))

(define (check-js-prog . forms)
  (apply check-prog (cons '(define-target js) forms)))

(define (br . values) (cons BRACKET-TAG values))

(define (private-check-binding name)
  (parameterize ([current-namespace
                  (module->namespace 'beagle/private/check)])
    (namespace-variable-value name)))

(test-case "inference bottom is neutral while authored Any is absorbing"
  (define merge-types/private (private-check-binding 'merge-types))
  (check-equal? (type-prim 'Int)
                (merge-types/private #f (type-prim 'Int)))
  (check-equal? (type-prim 'Any)
                (merge-types/private (type-prim 'Any) (type-prim 'Int)))
  (check-equal? (type-prim 'Any) (merge-types/private))
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn count-to-one [] Int
         (loop [(n Int) 0]
           (if (< n 1) (recur (+ n 1)) n)))))))

(test-case "JsMath sine and cosine require Number and return Float"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn wave [(angle Number)] Float
         (+ (js/call Math .sin angle)
            (js/call Math .cos angle))))))
  (check-exn
   #rx"expected .*Number.*got String"
   (lambda ()
     (check-js-prog
      '(defn invalid-wave [] Float
         (js/call Math .sin "not a number"))))))

(test-case "JsMath numeric members require Number and preserve precise results"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn angle [(value Number)] Float
         (+ (js/call Math .atan value)
            (js/call Math .atan2 value value)
            (js/call Math .exp value)
            (js/call Math .tan value)))
      '(defn minimum [(left Float) (right Float)] Float
         (js/call Math .min left right))
      '(defn maximum [(left Int) (right Int)] Int
         (js/call Math .max left right)))))
  (for ([invalid
         (in-list
          '((defn invalid-atan [] Float (js/call Math .atan "bad"))
            (defn invalid-atan2 [] Float (js/call Math .atan2 1.0 "bad"))
            (defn invalid-exp [] Float (js/call Math .exp "bad"))
            (defn invalid-tan [] Float (js/call Math .tan "bad"))
            (defn invalid-min [] Float (js/call Math .min 1.0 "bad"))
            (defn invalid-max [] Int (js/call Math .max 1 "bad"))))])
    (check-exn #rx"(Int|Number|Float).*String|String.*(Int|Number|Float)"
               (lambda () (check-js-prog invalid)))))

(test-case "native Map construction returns JsMap with an Int size member"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn empty-map-size [] Int
         (let [values (js/new Map)]
           (js/get values .size))))))
  (check-exn
   #rx"expected (return )?String, got Int"
   (lambda ()
     (check-js-prog
      '(defn invalid-map-size [] String
         (let [values (js/new Map)]
           (js/get values .size)))))))

(test-case "an explicit Atom Any accepts concrete writes without alias widening"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn store-dynamic! [(cell (Atom Any))] Any
         (reset! cell true)))))
  (check-exn
   #rx"expected .Atom Any.*got .Atom Bool"
   (lambda ()
     (check-js-prog
      '(defn poison! [(cell (Atom Any))] Any
         (reset! cell "wrong"))
      '(defn preserve-bool! [(cell (Atom Bool))] Bool
         (do (poison! cell) (deref cell)))))))

(test-case "a nil guard narrows a declared nullable HVec"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn entry-generation
         [(entry (U (HVec Any Float String) Nil))]
         Float
         (if (nil? entry) 0.0 (nth entry 1)))))))

(test-case "fresh invariant cells inherit typed call and record context"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defrecord Gesture [(id Int)])
      '(defrecord Pointer [(gesture (Atom (U Gesture Nil)))])
      '(defn consume-pointer [(gesture (Atom (U Gesture Nil)))] Any
         (deref gesture))
      '(defn fresh-call [] Any
         (consume-pointer (atom nil)))
      '(defn fresh-record [] Pointer
         (->Pointer (atom nil)))))))

(test-case "fresh Atom initializer follows union and HVec expected structure"
  (check-not-exn
   (lambda ()
     (check-js-prog
      `(def origin (Atom (U (HVec Float Float Float) Nil))
         (atom ,(br 0.0 0.0 0.0))))))
  (check-exn
   #rx"atom init: expected .*HVec Float Float Float.*got"
   (lambda ()
     (check-js-prog
      `(def invalid-origin (Atom (U (HVec Float Float Float) Nil))
         (atom ,(br 0.0 "wrong" 0.0))))))
  (check-exn
   #rx"def widened-alias: expected .*Atom.*HVec Float Float Float.*got .*Atom.*HVec Float Float Float"
   (lambda ()
     (check-js-prog
      `(def exact-origin (Atom (HVec Float Float Float))
         (atom ,(br 0.0 0.0 0.0)))
      '(def widened-alias (Atom (U (HVec Float Float Float) Nil))
         exact-origin)))))
