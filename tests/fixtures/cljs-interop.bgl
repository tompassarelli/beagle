#lang beagle

(define-target cljs)
(ns test.cljs-interop)

;; JS global functions
(def parsed : Long (js/parseInt "42"))
(def float-val : Double (js/parseFloat "3.14"))
(def nan-check : Boolean (js/isNaN 0))
(def finite-check : Boolean (js/isFinite 100))

;; JS Math
(def pi-area : Double (js/Math.pow 3.14 2.0))
(def root : Double (js/Math.sqrt 16.0))
(def rnd : Double (js/Math.random))
(def floored : Double (js/Math.floor 3.7))
(def ceiled : Double (js/Math.ceil 3.2))

;; JS console
(defn log-it [(msg : String)] : Nil
  (js/console.log msg))

;; JS URI encoding
(def encoded : String (js/encodeURIComponent "hello world"))
(def decoded : String (js/decodeURIComponent encoded))

;; Standard Clojure functions work in both targets
(defn greet [(name : String)] : String
  (str "Hello, " name "!"))

(def items (vec (map inc (range 5))))

;; try/catch uses :default in CLJS
(def safe-val
  (try
    (/ 1 0)
    (catch :default e
      (str "error: " e))))

;; defrecord works in both targets
(defrecord Point [(x : Long) (y : Long)])

(defn make-origin [] : Point
  (->Point 0 0))

(def origin (make-origin))
(def ox : Long (:x origin))
