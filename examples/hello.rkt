#lang beagle

(ns beagle.example.hello)

(def greeting : String "hello, world")

(defn shout [(msg : String)] : String
  (str msg "!"))

(defn add [(x : Long) (y : Long)] : Long
  (+ x y))

(defn pick [(n : Long)] : String
  (cond
    [(< n 0)  "negative"]
    [(= n 0)  "zero"]
    [(> n 0)  "positive"]))

(defn main []
  (println (shout greeting))
  (println (add 2 3))
  (println (pick -1))
  (println (pick 0))
  (println (pick 5)))
