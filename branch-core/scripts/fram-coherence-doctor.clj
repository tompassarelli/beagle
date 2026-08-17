#!/usr/bin/env bb
;; Pure, cold coherence report for the main read view.  This deliberately folds
;; the log rather than starting a server: diagnosis must not make the view
;; more coherent, nor change a byte of the corpus it describes.
(require '[clojure.edn :as edn]
         '[clojure.string :as str]
         '[fram.fold :as fold]
         '[fram.kernel :as kernel])

(def read-first-predicates #{"kind" "v" "refers_to" "bound_to"})

(defn fail! [message]
  (binding [*out* *err*] (println (str "coherence error=" (pr-str message))))
  (System/exit 2))

(defn read-ops [path]
  (try
    (with-open [reader (java.io.BufferedReader. (java.io.FileReader. path))]
      (->> (line-seq reader)
           (map-indexed
            (fn [line-index line]
              (try
                (let [m (edn/read-string line)]
                  (when (and (map? m) (#{"assert" "retract"} (:op m))
                             (some? (:l m)) (some? (:p m)) (some? (:r m)))
                    (assoc m :report/index line-index)))
                (catch Exception _ nil))))
           (remove nil?)
           vec))
    (catch Exception e (fail! (or (ex-message e) (str e))))))

(defn fact-op [m]
  (fold/->FactOp (or (:tx m) 0) (:op m) (:l m) (:p m) (:r m) (or (:frame m) "coherence")))

(defn fact-key [cmap m]
  (if (kernel/single-eff? cmap (:p m))
    [(:l m) (:p m)]
    [(:l m) (:p m) (:r m)]))

(defn live-ops [ops]
  (let [cmap (fold/card-map (mapv fact-op ops))
        latest (reduce
                (fn [acc m]
                  (let [k (fact-key cmap m) prior (get acc k)]
                    (if (and prior (> (long (or (:tx prior) 0)) (long (or (:tx m) 0))))
                      acc
                      (assoc acc k m))))
                {} ops)]
    (->> (vals latest) (filter #(= "assert" (:op %))) vec)))

(defn by-lp [facts]
  (reduce (fn [acc fact] (update acc [(:l fact) (:p fact)] (fnil conj []) fact)) {} facts))

(defn live-values [groups l p]
  (mapv :r (get groups [l p] [])))

(defn declared-cardinality [facts]
  (reduce (fn [acc {:keys [l r]}]
            (if (and (string? l) (string? r) (#{"single" "multi"} r))
              (assoc acc (if (str/starts-with? l "@") (subs l 1) l) r)
              acc))
          {} (filter #(= "cardinality" (:p %)) facts)))

(defn cid-of [fact]
  (str (or (:cid fact) "tx-" (:tx fact) "-" (:report/index fact))))

(defn finding [type fields]
  (str "finding type=" type
       (apply str (for [[k v] (sort-by (comp name key) fields)]
                    (str " " (name k) "=" (pr-str v))))))

(defn dangling-findings [facts groups]
  (->> facts
       (filter #(contains? #{"bound_to" "refers_to"} (:p %)))
       (keep (fn [{:keys [l p r] :as edge}]
               (when (and (string? r) (seq (live-values groups l "v"))
                          (empty? (live-values groups r "v")))
                 (finding "dangling-reference"
                          {:cid (cid-of edge) :predicate p :source l
                           :spelling (first (sort (live-values groups l "v"))) :target r}))))
       sort vec))

(defn rival-findings [facts groups declared]
  (->> groups
       (keep (fn [[[l p] members]]
               (when (and (contains? read-first-predicates p)
                          (not (contains? declared p))
                          (> (count members) 1))
                 (finding "undeclared-take-first-rival"
                          {:cids (vec (sort (map cid-of members))) :predicate p :subject l
                           :values (vec (sort (map :r members)))}))))
       sort vec))

(defn world-findings [facts groups]
  (->> facts
       (filter #(and (= "world.head" (:p %)) (str/starts-with? (:l %) "world:")))
       (keep (fn [{:keys [l r] :as head}]
               (when (empty? (live-values groups (str "world.version:" r) "world.record"))
                 (finding "world-unresolvable"
                          {:cid (cid-of head) :head r :world (subs l (count "world:"))
                           :reason "missing-world-record"}))))
       sort vec))

(defn report [path]
  (let [facts (live-ops (read-ops path))
        groups (by-lp facts)
        findings (vec (concat (dangling-findings facts groups)
                              (rival-findings facts groups (declared-cardinality facts))
                              (world-findings facts groups)))]
    (doseq [line findings] (println line))
    (println (str "coherence findings=" (count findings)))
    (if (empty? findings) 0 1)))

(let [[path & extra] *command-line-args*]
  (when (or (nil? path) (seq extra)) (fail! "usage: fram-coherence-doctor <log-path>"))
  (System/exit (report path)))
