(ns callgraph
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [cheshire.core :as json]
            [resolve :as rsv]))

(defn parse-corpus! [^String path]
  (let [skips (atom 0)
   lines (str/split-lines (slurp path))
   acc (reduce (fn [st ^String l] (if (str/starts-with? l "@file ") {:cur {:file (subs l 6) :triples []} :out (if (empty? (:cur st)) (:out st) (conj (vec (:out st)) (:cur st)))} (if (str/starts-with? l "[") (let [t (try
  (edn/read-string l)
  (catch Exception e
    nil))]
  (if (nil? t) (let [_ (swap! skips (fn [n] (inc n)))]
  st) (assoc st :cur (assoc (:cur st) :triples (conj (vec (:triples (:cur st))) t))))) st))) {:cur {} :out []} lines)
   blocks (if (empty? (:cur acc)) (vec (:out acc)) (conj (vec (:out acc)) (:cur acc)))]
  (if (pos? (deref skips)) (binding [*out* *err*]
  (println "  (skipped" (deref skips) "EDN-unparseable leaf literals)")) nil)
  (vec blocks)))

(defn index-by [^String pred triples]
  (reduce (fn [m t] (if (= pred (nth t 1)) (assoc m (nth t 0) (nth t 2)) m)) {} triples))

(defn ^String module-of [^String file]
  (let [parts (str/split file (re-pattern "/"))]
  (str/replace (str (nth parts (dec (count parts)))) (re-pattern "\\.[^.]+$") "")))

(defn derive-block [block]
  (let [ts (vec (:triples block))
   file (str (:file block))
   fk (index-by "form-kind" ts)
   names (index-by "name" ts)
   calls (index-by "calls" ts)
   kids (reduce (fn [m t] (if (= "child" (nth t 1)) (assoc m (nth t 0) (conj (vec (get m (nth t 0) [])) (nth t 2))) m)) {} ts)
   childset (reduce (fn [s t] (if (= "child" (nth t 1)) (conj s (nth t 2)) s)) #{} ts)
   ordered-keys (vec (sort (set (keys fk))))
   roots (filterv (fn [k] (not (contains? childset k))) ordered-keys)
   defns (mapv (fn [s] {:key [file s] :name (get names s) :file file :module (module-of file)}) (filterv (fn [s] (= "defn" (get fk s))) ordered-keys))
   mentions (loop [stack (mapv (fn [r] [r nil]) roots)
   ms []]
  (if (empty? stack) ms (let [top (peek stack)
   st (pop stack)
   node (nth top 0)
   cd (nth top 1)
   cd2 (if (= "defn" (get fk node)) node cd)
   ms2 (if (and (= "call" (get fk node)) (and (not (nil? cd2)) (not (nil? (get calls node))))) (conj ms [[file cd2] (get calls node)]) ms)]
  (recur (into st (mapv (fn [k] [k cd2]) (vec (get kids node [])))) ms2))))]
  {:file file :defns defns :mentions mentions}))

(defn resolve-call [by-name caller-key callname]
  (let [cands (vec (get by-name callname []))
   cfile (nth caller-key 0)
   same (filterv (fn [d] (= cfile (nth (:key d) 0))) cands)]
  (if (pos? (count same)) (:key (nth same 0)) (if (= 1 (count cands)) (:key (nth cands 0)) nil))))

(defn build-graph [blocks]
  (let [derived (mapv (fn [b] (derive-block b)) blocks)
   defns (vec (mapcat (fn [d] (vec (:defns d))) derived))
   by-name (group-by (fn [d] (:name d)) defns)
   mentions (vec (mapcat (fn [d] (vec (:mentions d))) derived))
   edges (vec (distinct (filterv (fn [x] (not (nil? x))) (mapv (fn [m] (let [ck (nth m 0)
   nm (nth m 1)
   callee (resolve-call by-name ck nm)]
  (if (nil? callee) nil (if (not= ck callee) [ck callee] nil)))) mentions))))]
  {:defns defns :by-name by-name :edges edges}))

(defn ^String key->str [k]
  (str (nth k 0) "#" (nth k 1)))

(defn key-index [edges]
  (reduce (fn [m e] (assoc (assoc m (key->str (nth e 0)) (nth e 0)) (key->str (nth e 1)) (nth e 1))) {} (vec edges)))

(defn blast-radius [edges]
  (let [key-of (key-index edges)
   closure (rsv/blast-closure (mapv (fn [e] [(key->str (nth e 0)) (key->str (nth e 1))]) (vec edges)))]
  {:reaches (set (mapv (fn [r] [(get key-of (nth r 0)) (get key-of (nth r 1))]) (vec (:reaches closure)))) :blast (reduce (fn [m kv] (assoc m (get key-of (nth kv 0)) (set (mapv (fn [x] (get key-of x)) (vec (nth kv 1)))))) {} (vec (:blast closure)))}))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [facts-path (str (nth (vec args) 0))
   blocks (parse-corpus! facts-path)
   graph (build-graph blocks)
   defns (vec (:defns graph))
   edges (vec (:edges graph))
   closure (blast-radius edges)
   blast (:blast closure)
   reaches (:reaches closure)
   defns-out (mapv (fn [dd] {:key (key->str (:key dd)) :file (:file dd) :module (:module dd) :name (:name dd)}) defns)
   edges-out (mapv (fn [e] [(key->str (nth e 0)) (key->str (nth e 1))]) edges)
   blast-out (into {} (mapv (fn [kv] [(key->str (nth kv 0)) (mapv (fn [x] (key->str x)) (vec (nth kv 1)))]) (vec blast)))]
  (binding [*out* *err*]
  (println (format "callgraph: %d defns, %d scope-correct edges, %d transitive reaches-pairs (Fram Datalog closure)" (count defns) (count edges) (count reaches))))
  (println (json/generate-string {:defns defns-out :edges edges-out :blast blast-out})))))
