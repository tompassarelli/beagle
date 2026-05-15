#lang beagle

(ns mathlib)

(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(def pi : Double 3.14159)

(defn greet [(name : String)] : String
  (str "hello " name))

(defn untyped-inc [x]
  (inc x))
