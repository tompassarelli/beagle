(ns supersession-check
  (:require [store.store :as c]
            [store.types :as t]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^String space-id "codegraph")

(defn line->operation [^String line]
  (let [trip (edn/read-string line)]
  (c/assert-operation (t/triple (nth trip 0) (nth trip 1) (nth trip 2)))))

(defn propositions-of [ctx node]
  (filterv (fn [p] (= node (t/triple-t1 p))) (c/live-propositions ctx)))

(defn ^Boolean sym? [ctx node]
  (pos? (count (filterv (fn [p] (and (= "kind" (t/triple-t2 p)) (= "symbol" (t/triple-t3 p)))) (propositions-of ctx node)))))

(defn first-sym-value-proposition [ctx ^String old-name]
  (let [hits (filterv (fn [p] (and (= "v" (t/triple-t2 p)) (and (= old-name (t/triple-t3 p)) (sym? ctx (t/triple-t1 p))))) (c/live-propositions ctx))]
  (if (empty? hits) nil (nth hits 0))))

(defn ^String occurrence-label [occurrence]
  (let [transaction (t/triple-t1 occurrence)]
  (str (t/triple-t1 transaction) "/" (t/triple-t3 transaction) "#" (t/triple-t3 occurrence))))

(defn ^String proposition-label [proposition]
  (str "(" (t/triple-t1 proposition) " " (pr-str (t/triple-t2 proposition)) " " (pr-str (t/triple-t3 proposition)) ")"))

(defn assertion-occurrence-of [events proposition]
  (let [hits (filterv (fn [e] (and (t/assertion-occurrence? e) (= proposition (t/operationoccurrence-proposition e)))) events)]
  (if (empty? hits) nil (t/operationoccurrence-coordinate (nth hits 0)))))

(defn withdrawal-of [ctx occurrence]
  (let [hits (filterv (fn [w] (= occurrence (t/operationoccurrence-coordinate (t/withdrawal-assertion w)))) (c/withdrawals ctx))]
  (if (empty? hits) nil (nth hits 0))))

(defn ^Boolean live-occurrence? [ctx occurrence]
  (pos? (count (filterv (fn [e] (= occurrence (t/operationoccurrence-coordinate e))) (c/live-occurrences ctx)))))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [ctx (c/new-term-store space-id)
   lines (str/split-lines (slurp "/tmp/trap.edn"))
   operations (mapv (fn [^String line] (line->operation line)) (filterv (fn [^String line] (str/starts-with? line "[")) lines))
   _load (if (pos? (count operations)) (do
  (c/commit-boundary! ctx operations (c/commit-metadata "store.codegraph/supersession-load-v1" "store/CommitOperationV1" "codegraph-v1"))))
   old-proposition (first-sym-value-proposition ctx "red")
   node (t/triple-t1 old-proposition)
   new-proposition (t/triple node "v" "crimson")
   occurrences-before (c/occurrences ctx)
   old-occurrence (assertion-occurrence-of occurrences-before old-proposition)
   _edit (c/commit-boundary! ctx [(c/retract-operation old-proposition) (c/assert-operation new-proposition)] (c/commit-metadata "store.codegraph/supersession-v1" "store/CommitOperationV1" "codegraph-v1"))
   occurrences (c/occurrences ctx)
   new-occurrence (assertion-occurrence-of occurrences new-proposition)
   withdrawal (withdrawal-of ctx old-occurrence)]
  (println "node (the symbol node):" node)
  (println)
  (println "OLD value-assertion  at=" (occurrence-label old-occurrence) "  ->" (proposition-label old-proposition) "  value=" (pr-str (t/triple-t3 old-proposition)) "  LIVE?=" (live-occurrence? ctx old-occurrence))
  (println "NEW value-assertion  at=" (occurrence-label new-occurrence) "  ->" (proposition-label new-proposition) "  value=" (pr-str (t/triple-t3 new-proposition)) "  LIVE?=" (live-occurrence? ctx new-occurrence))
  (println "WITHDRAWAL           at=" (occurrence-label (t/operationoccurrence-coordinate (t/withdrawal-retraction withdrawal))) " withdraws=" (occurrence-label (t/operationoccurrence-coordinate (t/withdrawal-assertion withdrawal))) "  (the retraction occurrence that withdraws the old assertion occurrence)")
  (println)
  (println "same node for old & new?   " (= (t/triple-t1 old-proposition) (t/triple-t1 new-proposition)))
  (println "old still retrievable (history preserved)? " (some? (assertion-occurrence-of occurrences old-proposition)))
  (println "live view of the node's v-propositions (live-propositions is live-only):" (mapv (fn [p] (pr-str (t/triple-t3 p))) (filterv (fn [p] (= "v" (t/triple-t2 p))) (propositions-of ctx node))))
  (println "=> old red assertion EXISTS, marked not-live; new crimson assertion is live; same node. Withdrawal is real:" (and (some? (assertion-occurrence-of occurrences old-proposition)) (not (live-occurrence? ctx old-occurrence)) (live-occurrence? ctx new-occurrence) (= (t/triple-t1 old-proposition) (t/triple-t1 new-proposition)))))))
