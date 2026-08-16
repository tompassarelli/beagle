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
