;; g1-gate.clj — epoch-assignment gate (report-only).
;; Input: epoch-map JSON files (one per module, from epoch-stage.clj).
;; Passes iff, across all given maps together:
;;   1. >= 90% of allocating sites carry an epoch assignment;
;;   2. every refusal reason is TODO-EPOCH-coded;
;;   3. the fold is total: assigned + refused == sites (zero unexplained).
;; Prints the per-module assignment table and the refusal census by code.
(require '[cheshire.core :as json]
         '[clojure.string :as str])

(def threshold 0.90)

(when (empty? *command-line-args*)
  (binding [*out* *err*]
    (println "usage: bb g1-gate.clj <epoch-map.json>..."))
  (System/exit 2))

(let [maps (mapv #(json/parse-string (slurp %)) *command-line-args*)
      row (fn [m]
            (let [kinds (get m "assignedByKind" {})]
              {:item (get m "item")
               :sites (get m "totalSites")
               :assigned (get m "assigned")
               :refused (get m "refused")
               :static (get kinds "static" 0)
               :stage (get kinds "stage" 0)
               :loop (get kinds "loop" 0)
               :caller (get kinds "caller-owned" 0)
               :refusals (get m "refusalProfile" {})
               :total? (= (get m "totalSites")
                          (+ (get m "assigned") (get m "refused")))}))
      rows (mapv row maps)
      pct (fn [a t] (if (zero? t) 100.0 (* 100.0 (/ (double a) t))))
      sum (fn [k] (reduce + 0 (map k rows)))
      agg-sites (sum :sites)
      agg-assigned (sum :assigned)
      agg-rate (pct agg-assigned agg-sites)
      census (reduce (fn [acc r]
                       (merge-with + acc (into {} (:refusals r))))
                     (sorted-map) rows)
      uncoded (vec (remove #(str/starts-with? % "TODO-EPOCH-") (keys census)))
      partial- (vec (keep #(when-not (:total? %) (:item %)) rows))
      line "---------------------------------------------------------------------------------"]
  (println "=== G1: per-module epoch assignment (allocating sites) ===")
  (println (format "%-18s %6s %9s %8s %7s %6s %5s %7s %8s"
                   "module" "sites" "assigned" "pct" "static" "stage" "loop"
                   "caller" "refused"))
  (println line)
  (doseq [r rows]
    (println (format "%-18s %6d %9d %7.1f%% %7d %6d %5d %7d %8d"
                     (:item r) (:sites r) (:assigned r)
                     (pct (:assigned r) (:sites r))
                     (:static r) (:stage r) (:loop r) (:caller r)
                     (:refused r))))
  (println line)
  (println (format "%-18s %6d %9d %7.1f%%" "TOTAL" agg-sites agg-assigned
                   agg-rate))
  (println)
  (if (empty? census)
    (println "refusal census: none")
    (do (println "refusal census by code:")
        (doseq [[code n] census]
          (println (format "  %4d  %s" n code)))))
  (let [fail (cond-> []
               (< agg-rate (* 100.0 threshold))
               (conj (format "aggregate assignment %.1f%% < %.0f%%"
                             agg-rate (* 100.0 threshold)))
               (seq uncoded)
               (conj (str "refusal codes not TODO-EPOCH-*: "
                          (str/join ", " uncoded)))
               (seq partial-)
               (conj (str "fold not total (unexplained sites) in: "
                          (str/join ", " partial-))))]
    (println)
    (if (empty? fail)
      (println (format "G1 PASS: %.1f%% assigned, every refusal TODO-EPOCH-coded, zero unexplained sites"
                       agg-rate))
      (do (doseq [f fail] (println (str "G1 FAIL: " f)))
          (System/exit 1)))))
