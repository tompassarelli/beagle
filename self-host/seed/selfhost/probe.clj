(ns selfhost.probe
  (:require [clojure.string :as str]))

(def NODE {"node" "if" "depth" 0})

(defn collect! [xs]
  (let [acc (atom [])]
  (doseq [x xs]
  (swap! acc conj (+ x 1)))
  (deref acc)))

(defn ^String char-at [^String s i]
  (if (and (>= i 0) (< i (count s))) (subs s i (+ i 1)) ""))

(defn ^String substring2 [^String s a b]
  (let [n (count s)
   lo (if (< a 0) 0 (if (> a n) n a))
   hi (if (< b lo) lo (if (> b n) n b))]
  (subs s lo hi)))

(defn to-int [^String s]
  (let [n (parse-long s)]
  (if (nil? n) 0 n)))

(defn ^String node-kind [d]
  (if (and (map? d) (string? (get d "node"))) (get d "node") "?"))

(defn tail [d]
  (if (and (vector? d) (> (count d) 0)) (subvec d 1) []))

(defn -main [& args]
  (println (str "collect=" (collect! [1 2 3])))
  (println (str "char-at=" (char-at "hello" 1) "|" (char-at "hello" 99) "|"))
  (println (str "substring2=" (substring2 "hello" 1 3) "|" (substring2 "hello" 3 99)))
  (println (str "to-int=" (to-int "42") "," (to-int "xx")))
  (println (str "node-kind=" (node-kind NODE)))
  (println (str "tail=" (tail ["a" "b" "c"])))
  (println (str "join=" (str/join " " ["x" "y"]))))
