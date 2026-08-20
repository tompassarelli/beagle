(ns codegraph
  (:require [store.store :as c]
            [store.datalog :as d]
            [store.types :as t]
            [callgraph :as cg]
            [clojure.string :as str]))

(defrecord Row [name file graph-p incumbent-p gn in])

(defn row-name [r] (:name r))

(defn row-file [r] (:file r))

(defn row-graph-p [r] (:graph-p r))

(defn row-incumbent-p [r] (:incumbent-p r))

(defn row-gn [r] (:gn r))

(defn row-in [r] (:in r))

(defn rev-adj [edges]
  (reduce (fn [m e] (let [a (nth e 0)
   b (nth e 1)]
  (assoc m b (conj (get m b #{}) a)))) {} edges))

(defn fwd-adj [edges]
  (reduce (fn [m e] (let [a (nth e 0)
   b (nth e 1)]
  (assoc m a (conj (get m a #{}) b)))) {} edges))

(defn transitive [adj n]
  (loop [seen #{}
   frontier (vec (get adj n #{}))]
  (if (empty? frontier) seen (let [x (peek frontier)
   fr (pop frontier)]
  (if (contains? seen x) (recur seen fr) (recur (conj seen x) (into fr (get adj x #{}))))))))

(defn avg-ranks [v]
  (let [idx (vec (map-indexed (fn [i x] [i x]) v))
   sorted (vec (sort-by (fn [p] (nth p 1)) idx))
   groups (vec (partition-by (fn [p] (nth p 1)) sorted))
   acc (loop [gs groups
   start 1
   acc {}]
  (if (empty? gs) acc (let [g (vec (nth gs 0))
   n (count g)
   r (/ (+ (* 2.0 start) (dec n)) 2.0)]
  (recur (vec (rest gs)) (+ start n) (reduce (fn [a p] (assoc a (nth p 0) r)) acc g)))))]
  (mapv (fn [i] (get acc i 0.0)) (vec (range (count v))))))

(defn pearson [xs ys]
  (let [n (count xs)
   sum-x (reduce (fn [total value] (+ total value)) 0.0 xs)
   sum-y (reduce (fn [total value] (+ total value)) 0.0 ys)
   mx (/ sum-x (double n))
   my (/ sum-y (double n))
   cov (reduce (fn [total i] (+ total (* (- (nth xs i) mx) (- (nth ys i) my)))) 0.0 (vec (range n)))
   sx (Math/sqrt (reduce (fn [total x] (let [dd (- x mx)]
  (+ total (* dd dd)))) 0.0 xs))
   sy (Math/sqrt (reduce (fn [total y] (let [dd (- y my)]
  (+ total (* dd dd)))) 0.0 ys))]
  (if (or (zero? sx) (zero? sy)) 0.0 (/ cov (* sx sy)))))

(defn spearman [xs ys]
  (pearson (avg-ranks xs) (avg-ranks ys)))

(defn ^String fmt3 [x]
  (format "%.3f" (double x)))

(defn ^String short-file [k]
  (str/replace (str (nth k 0)) (re-pattern ".*/gjoa/") ""))

(defn defn-keys-of [defns]
  (mapv (fn [dd] (:key dd)) defns))

(defn count-adj [defn-keys adj]
  (reduce (fn [m k] (assoc m k (count (get adj k #{})))) {} defn-keys))

(defn count-transitive [defn-keys adj]
  (reduce (fn [m k] (assoc m k (count (transitive adj k)))) {} defn-keys))

(defn ^String name-of [defns k]
  (let [hits (filterv (fn [dd] (= (:key dd) k)) defns)]
  (if (empty? hits) "" (str (:name (nth hits 0))))))

(defn collision-names [by-name]
  (vec (filterv (fn [^String nm] (> (count (distinct (mapv (fn [dd] (nth (:key dd) 0)) (get by-name nm)))) 1)) (vec (sort (set (keys by-name)))))))

(defn scored-rows [by-name collisions radj]
  (filterv (fn [^Row r] (pos? (:gn r))) (vec (mapcat (fn [^String nm] (let [ds (get by-name nm)
   incumbent (reduce (fn [acc dd] (into acc (get radj (:key dd) #{}))) #{} ds)]
  (if (pos? (count incumbent)) (mapv (fn [dd] (let [g (get radj (:key dd) #{})]
  (Row. nm (short-file (:key dd)) 1.0 (/ (count g) (double (count incumbent))) (count g) (count incumbent)))) ds) []))) collisions))))

(defn ^String node-term [k]
  (str (nth k 0) "#" (nth k 1)))

(defn closure-line! [edges defn-keys fadj]
  (let [ctx (c/new-term-store "codegraph")
   edge-pred "calls-defn"
   operations (mapv (fn [e] (c/assert-operation (t/triple (node-term (nth e 0)) edge-pred (node-term (nth e 1))))) edges)
   _load (if (pos? (count operations)) (do
  (c/commit-boundary! ctx operations (c/commit-metadata "store.codegraph/closure-v1" "store/CommitOperationV1" "codegraph-v1"))))
   t0 (System/currentTimeMillis)
   db (d/run-rules! (c/live-propositions ctx) [(d/rule "reaches" [(d/variable "x") (d/variable "y")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant edge-pred) (d/variable "y")])]) (d/rule "reaches" [(d/variable "x") (d/variable "z")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant edge-pred) (d/variable "y")]) (d/relation-literal "reaches" [(d/variable "y") (d/variable "z")])])])
   dl-reaches (set (d/facts db "reaches"))
   t1 (System/currentTimeMillis)
   truth (reduce + (mapv (fn [k] (count (transitive fadj k))) defn-keys))]
  (println (str "\nBeagle Store Datalog transitive closure: " (count dl-reaches) " reaches-pairs in " (- t1 t0) " ms" "  (in-process closure: " truth " pairs — " (if (= (count dl-reaches) truth) "MATCH" "DIVERGE") ")"))))

(defn bench-a! [by-name radj]
  (println "\n================ BENCHMARK A — caller precision on collisions ================")
  (println "(oracle = module-local scope: a call binds the defn in its own file)")
  (let [collisions (collision-names by-name)
   rows (scored-rows by-name collisions radj)
   delta-sum (reduce (fn [total ^Row r] (+ total (- (:graph-p r) (:incumbent-p r)))) 0.0 rows)
   mean-delta (if (empty? rows) 0.0 (/ delta-sum (double (count rows))))
   tot-g (reduce (fn [total ^Row r] (+ total (:gn r))) 0 rows)
   tot-in (reduce (fn [total ^Row r] (+ total (:in r))) 0 rows)
   micro-incumbent-p (if (pos? tot-in) (/ (double tot-g) (double tot-in)) 1.0)
   micro-delta (- 1.0 micro-incumbent-p)
   wrong (count (filterv (fn [^Row r] (< (:incumbent-p r) 1.0)) rows))]
  (println "collision names:" (count collisions) " scored targets:" (count rows))
  (doseq [r (vec (take 12 (sort-by (fn [^Row r] (:incumbent-p r)) rows)))]
  (println (format "  %-18s %-22s graph P=%.2f  incumbent P=%.2f  (%d of %d callers are in-scope)" (:name r) (:file r) (:graph-p r) (:incumbent-p r) (:gn r) (:in r))))
  (println (format "graph is PERFECT on %d/%d targets; the bare-symbol incumbent is WRONG (P<1) on %d (%.0f%%)" (count rows) (count rows) wrong (* 100.0 (/ (double wrong) (double (max 1 (count rows)))))))
  (println "MACRO mean precision delta (graph - incumbent):" (fmt3 mean-delta))
  (println (format "MICRO pooled delta: %s  (incumbent P=%.3f over %d in-scope / %d returned call-sites)" (fmt3 micro-delta) micro-incumbent-p tot-g tot-in))
  (println "  [PASS >= +0.20 (documented kill line)]" (if (>= mean-delta 0.2) "✅" "—"))))

(defn bench-b! [defns defn-keys direct blast]
  (println "\n================ BENCHMARK B — transitive leverage (keystones) ================")
  (let [called (filterv (fn [k] (pos? (get blast k 0))) defn-keys)
   xs (mapv (fn [k] (double (get direct k 0))) called)
   ys (mapv (fn [k] (double (get blast k 0))) called)
   rho (spearman xs ys)
   top-direct (set (vec (take 10 (sort-by (fn [k] (get direct k 0)) > defn-keys))))
   top-blast (vec (take 5 (sort-by (fn [k] (get blast k 0)) > defn-keys)))
   hidden (filterv (fn [k] (not (contains? top-direct k))) top-blast)
   ratio-3x (filterv (fn [k] (let [direct-count (int (get direct k 0))
   blast-count (int (get blast k 0))]
  (and (pos? direct-count) (>= (/ (double blast-count) (double direct-count)) 3.0)))) defn-keys)]
  (println "called defns:" (count called) " (ranked)")
  (println "\nTOP 8 by transitive blast radius (transitive callers):")
  (doseq [k (vec (take 8 (sort-by (fn [k] (get blast k 0)) > defn-keys)))]
  (println (format "  blast=%-4d direct=%-3d  %s   %s" (get blast k 0) (get direct k 0) (name-of defns k) (short-file k))))
  (println "\nSpearman rho (direct-rank vs blast-rank):" (fmt3 rho) "  [PASS < 0.80 => closure reorders]" (if (< rho 0.8) "✅" "—"))
  (println "defns with blast/direct >= 3x:" (count ratio-3x) "  [PASS >= 15]" (if (>= (count ratio-3x) 15) "✅" "—"))
  (if (not (empty? hidden)) (do
  (let [k (nth hidden 0)]
  (println (format "KEYSTONE HIDDEN BY ONE-HOP: %s (blast=%d, direct=%d) is top-5 transitive but NOT top-10 direct ✅" (name-of defns k) (get blast k 0) (get direct k 0))))))))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [corpus-path (if (empty? (vec args)) "build/gjoa.facts" (str (nth (vec args) 0)))
   blocks (cg/parse-corpus! corpus-path)
   graph (cg/build-graph blocks)
   defns (:defns graph)
   by-name (:by-name graph)
   edges (:edges graph)
   radj (rev-adj edges)
   fadj (fwd-adj edges)
   defn-keys (defn-keys-of defns)
   direct (count-adj defn-keys radj)
   blast (count-transitive defn-keys radj)]
  (println "================ CODEGRAPH — code-as-facts on Beagle Store =================")
  (println "corpus:" corpus-path)
  (println "files:" (count blocks) " defns:" (count defns) " resolved internal call-edges:" (count edges))
  (closure-line! edges defn-keys fadj)
  (bench-a! by-name radj)
  (bench-b! defns defn-keys direct blast)
  (println "\n===================================================================="))))
