#!/usr/bin/env bb
(require '[cheshire.core :as json]
         '[clojure.string :as str])

(def path (or (first *command-line-args*)
              (throw (ex-info "usage: report.bb RESULTS.jsonl" {}))))
(def rows
  (->> (str/split-lines (slurp path))
       (remove str/blank?)
       (mapv #(json/parse-string % true))))

(when (empty? rows)
  (throw (ex-info "no benchmark rows" {:path path})))

(def required
  [:adapter :run :corpus-triples :boot-to-serving-ms
   :cold-start-query-ms :cold-query-rows :write-under-read-ops-s
   :concurrent-read-ops :mixed-ops-s :mixed-read-p50-ms :errors])

(doseq [row rows]
  (let [missing (remove #(contains? row %) required)]
    (when (seq missing)
      (throw (ex-info "adapter row violates scenario contract"
                      {:missing missing :row row}))))
  (when-not (zero? (:errors row))
    (throw (ex-info "adapter reported benchmark errors" {:row row}))))

(def metrics
  [[:boot-to-serving-ms "boot ms"]
   [:cold-start-query-ms "cold query ms"]
   [:write-under-read-ops-s "write/read ops/s"]
   [:mixed-ops-s "mixed ops/s"]])

(defn mean [xs] (/ (reduce + xs) (double (count xs))))
(defn variance-pct [xs]
  (if (= 1 (count xs))
    0.0
    (* 100.0 (/ (- (apply max xs) (apply min xs)) (mean xs)))))

(println "| adapter | live triples | metric | runs | mean | range variance |")
(println "| --- | ---: | --- | ---: | ---: | ---: |")
(doseq [[[adapter size] rs] (sort-by key (group-by (juxt :adapter :corpus-triples) rows))
        [metric label] metrics
        :let [xs (mapv metric rs)]]
  (println (format "| %s | %d | %s | %d | %.3f | %.1f%% |"
                   adapter size label (count xs) (mean xs) (variance-pct xs))))
