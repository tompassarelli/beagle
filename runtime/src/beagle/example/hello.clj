(ns beagle.example.hello)

(def greeting "hello, world")

(defn shout [msg]
  (str msg "!"))

(defn add [x y]
  (+ x y))

(defn pick [n]
  (cond
  (< n 0) "negative"
  (= n 0) "zero"
  (> n 0) "positive"))

(defn main []
  (println (shout greeting))
  (println (add 2 3))
  (println (pick -1))
  (println (pick 0))
  (println (pick 5)))
