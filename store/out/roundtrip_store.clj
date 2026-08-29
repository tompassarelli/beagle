(ns roundtrip-store
  (:require [store.store :as c]
            [store.types :as t]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^String space-id "codegraph")

(defn line->operation [^String line]
  (let [trip (edn/read-string line)]
  (c/assert-operation (t/triple (nth trip 0) (nth trip 1) (nth trip 2)))))

(defn dump-proposition! [proposition]
  (let [l (t/triple-t1 proposition)
   p (t/triple-t2 proposition)
   r (t/triple-t3 proposition)]
  (if (integer? r) (println (str "[" l " " (pr-str p) " " r "]")) (println (str "[" l " " (pr-str p) " " (pr-str r) "]")))))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [^String edn-path (str (nth (vec args) 0))
   ctx (c/new-term-store space-id)
   lines (str/split-lines (slurp edn-path))
   operations (mapv (fn [^String line] (line->operation line)) (filterv (fn [^String line] (str/starts-with? line "[")) lines))]
  (if (pos? (count operations)) (do
  (c/commit-boundary! ctx operations (c/commit-metadata "store.codegraph/roundtrip-v1" "store/CommitOperationV1" "codegraph-v1"))))
  (binding [*out* *err*]
  (println "loaded" (count (c/live-propositions ctx)) "facts into a Beagle Store store"))
  (doseq [proposition (c/live-propositions ctx)]
  (dump-proposition! proposition)))))
