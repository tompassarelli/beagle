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
         (loop [n Int 0]
           (if (< n 1) (recur (+ n 1)) n)))))))

(test-case "JsMath sine and cosine require Number and return Float"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn wave [(angle Number)] Float
         (+ (.sin Math angle)
            (.cos Math angle))))))
  (check-exn
   #rx"expected .*Number.*got String"
   (lambda ()
     (check-js-prog
      '(defn invalid-wave [] Float
         (.sin Math "not a number"))))))

(test-case "JsMath numeric members require Number and preserve precise results"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn angle [(value Number)] Float
         (+ (.atan Math value)
            (.atan2 Math value value)
            (.exp Math value)
            (.tan Math value)))
      '(defn minimum [(left Float) (right Float)] Float
         (.min Math left right))
      '(defn maximum [(left Int) (right Int)] Int
         (.max Math left right)))))
  (for ([invalid
         (in-list
          '((defn invalid-atan [] Float (.atan Math "bad"))
            (defn invalid-atan2 [] Float (.atan2 Math 1.0 "bad"))
            (defn invalid-exp [] Float (.exp Math "bad"))
            (defn invalid-tan [] Float (.tan Math "bad"))
            (defn invalid-min [] Float (.min Math 1.0 "bad"))
            (defn invalid-max [] Int (.max Math 1 "bad"))))])
    (check-exn #rx"(Int|Number|Float).*String|String.*(Int|Number|Float)"
               (lambda () (check-js-prog invalid)))))

(test-case "native Map construction is invariant and exposes precise members"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn empty-map-size [] Int
         (let [(values (JsMap String Int)) (new Map)]
           (.-size values)))
      '(defn string-index [] (JsMap String Int)
         (new Map))
      '(defn lookup [(values (JsMap String Int)) (key String)] (U Int Nil)
         (.get values key))
      '(defn insert
         [(values (JsMap String Int)) (key String) (value Int)]
         (JsMap String Int)
         (.set values key value)))))
  (check-exn
   #rx"expected (return )?String, got Int"
   (lambda ()
     (check-js-prog
      '(defn invalid-map-size [] String
         (let [(values (JsMap String Int)) (new Map)]
           (.-size values))))))
  (check-exn
   #rx"expected .*String.*got Int|expected String, got Int"
   (lambda ()
     (check-js-prog
      '(defn invalid-map-key [(values (JsMap String Int))] (U Int Nil)
         (.get values 1)))))
  (check-exn
   #rx"expected .*Int.*got String|expected Int, got String"
   (lambda ()
     (check-js-prog
      '(defn invalid-map-value [(values (JsMap String Int))] (JsMap String Int)
         (.set values "key" "bad")))))
  (check-exn
   #rx"JsMap String Int.*JsMap String Any|JsMap String Any.*JsMap String Int"
   (lambda ()
     (check-js-prog
      '(defn consume-dynamic-values [(values (JsMap String Any))] Int
         (.-size values))
      '(defn invalid-map-widening [(values (JsMap String Int))] Int
         (consume-dynamic-values values)))))
  (check-exn
   #rx"new cannot infer type parameters K, V without an expected result type"
   (lambda ()
     (check-js-prog '(def empty-native-map (new Map)))))
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(declare-extern Map Any)
      '(defn shadowed-map-constructor [] Any (new Map))))))

(test-case "hosted Math and performance contracts preserve numeric results"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn host-metrics [(value Float)] Float
         (+ (.ceil Math value)
            (.max Math value 0.0)
            (.-PI Math)
            (.now performance))))))
  (check-exn
   #rx"expected Number, got String"
   (lambda ()
     (check-js-prog
      '(defn invalid-ceiling [] Int
         (.ceil Math "bad"))))))

(test-case "DOM pointer and rectangle receivers expose numeric geometry"
  (check-not-exn
   (lambda ()
     (check-js-prog
      '(defn pointer-x [(event JsPointerEvent)] Float
         (.-clientX event))
      '(defn canvas-left [(canvas JsCanvas)] Float
         (.-left (.getBoundingClientRect canvas))))))
  (check-exn
   #rx"expected return String, got Float"
   (lambda ()
     (check-js-prog
      '(defn invalid-pointer-x [(event JsPointerEvent)] String
         (.-clientX event)))))
  (check-exn
   #rx"expected return String, got Float"
   (lambda ()
     (check-js-prog
      '(defn invalid-canvas-left [(canvas JsCanvas)] String
         (.-left (.getBoundingClientRect canvas)))))))

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
