(ns rep-jurisdiction
  (:require [store.store :as c]
            [store.datalog :as d]
            [store.types :as t]
            [callgraph :as cg]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^String space-id "codegraph")

(def ^String regime-pred "rep-regime")

(def ^String calls-pred "calls")

(def ^String hamt-pred "ships-hamt")

(def ^String hamt-mark "yes")

(defn parse-rep-blocks [^String path]
  (let [lines (str/split-lines (slurp path))
   acc (reduce (fn [st ^String l] (if (str/starts-with? l "@file ") {:cur {:file (subs l 6) :triples []} :out (if (empty? (:cur st)) (:out st) (conj (vec (:out st)) (:cur st)))} (if (str/starts-with? l "[") (assoc st :cur (assoc (:cur st) :triples (conj (vec (:triples (:cur st))) (edn/read-string l)))) st))) {:cur {} :out []} lines)]
  (if (empty? (:cur acc)) (vec (:out acc)) (conj (vec (:out acc)) (:cur acc)))))

(defn block->defs [block]
  (let [ts (vec (:triples block))
   by-subj (group-by (fn [t] (nth t 0)) ts)
   ms (mapv (fn [s] (into {} (mapv (fn [t] [(nth t 1) (nth t 2)]) (vec (get by-subj s))))) (vec (keys by-subj)))]
  (mapv (fn [m] {:name (get m "name") :regime (get m "rep-regime") :native (get m "native-sites") :hamt (get m "hamt-sites") :module (get m "module")}) (filterv (fn [m] (= "rep-def" (get m "form-kind"))) ms))))

(defn regime-operations [rep-defs]
  (mapv (fn [dd] (c/assert-operation (t/triple (:name dd) regime-pred (:regime dd)))) (filterv (fn [dd] (and (not (nil? (:name dd))) (not (nil? (:regime dd))))) rep-defs)))

(defn defs-with-regime [ctx ^String reg]
  (vec (sort (mapv (fn [p] (t/triple-t1 p)) (filterv (fn [p] (and (= regime-pred (t/triple-t2 p)) (= reg (t/triple-t3 p)))) (c/live-propositions ctx))))))

(defn q4! [rep-defs ^String cg-path]
  (let [cg-blocks (cg/parse-corpus! cg-path)
   graph (cg/build-graph cg-blocks)
   defns (vec (:defns graph))
   edges (vec (:edges graph))
   key->name (into {} (mapv (fn [dd] [(:key dd) (:name dd)]) defns))
   name-edges (vec (distinct (filterv (fn [x] (not (nil? x))) (mapv (fn [e] (let [an (get key->name (nth e 0))
   bn (get key->name (nth e 1))]
  (if (and (not (nil? an)) (not (nil? bn))) [an bn] nil))) edges))))
   hamt-names (set (mapv (fn [dd] (:name dd)) (filterv (fn [dd] (and (not (nil? (:name dd))) (contains? #{"mixed" "hamt"} (:regime dd)))) rep-defs)))
   gctx (c/new-term-store space-id)
   operations (vec (concat (mapv (fn [e] (c/assert-operation (t/triple (nth e 0) calls-pred (nth e 1)))) name-edges) (mapv (fn [nm] (c/assert-operation (t/triple nm hamt-pred hamt-mark))) (vec hamt-names))))
   _load (if (pos? (count operations)) (do
  (c/commit-transaction! gctx operations)))
   db (d/run-rules! (c/live-propositions gctx) [(d/rule "forces" [(d/variable "x")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant calls-pred) (d/variable "y")]) (d/relation-literal d/triple-relation [(d/variable "y") (d/constant hamt-pred) (d/constant hamt-mark)])]) (d/rule "forces" [(d/variable "x")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant calls-pred) (d/variable "y")]) (d/relation-literal "forces" [(d/variable "y")])])])
   forced (vec (distinct (vec (sort (filterv (fn [x] (not (nil? x))) (mapv (fn [row] (nth row 0)) (d/facts db "forces")))))))]
  (if (pos? (count forced)) (doseq [nm forced]
  (println "  forces-HAMT" nm)) (println "  (no caller transitively reaches a HAMT def in this corpus)"))
  (println (format "\nHAMT-shipping defs: %d ; defs that FORCE a HAMT downstream: %d" (count hamt-names) (count forced)))
  (println "  ^ THIS is the query grep-the-comment cannot answer: the comment is")
  (println "    per-module and disconnected from the call graph; the fact is a")
  (println "    graph node you JOIN against scope-correct edges — blast radius of a")
  (println "    rep decision, across module boundaries, in one fixpoint.")))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [argv (vec args)
   rep-path (str (nth argv 0))
   cg-path (if (> (count argv) 1) (str (nth argv 1)) nil)
   blocks (parse-rep-blocks rep-path)
   rep-defs (vec (mapcat (fn [b] (block->defs b)) blocks))]
  (println "================ REP JURISDICTION — compiler judgment as facts =================")
  (println "rep corpus:" rep-path)
  (println "rep-def facts:" (count rep-defs) " across" (count (distinct (mapv (fn [dd] (:module dd)) rep-defs))) "module(s)")
  (let [ctx (c/new-term-store space-id)
   operations (regime-operations rep-defs)
   _load (if (pos? (count operations)) (do
  (c/commit-transaction! ctx operations)))]
  (println "\n---- Q1. defs that SHIP THE HAMT (pull persistent runtime) ----")
  (doseq [nm (defs-with-regime ctx "hamt")]
  (println "  HAMT  " nm))
  (println "\n---- Q2. defs that are 100% NATIVE (zero persistent runtime) ----")
  (doseq [nm (defs-with-regime ctx "native")]
  (println "  native" nm))
  (println "\n---- Q3. defs that are MIXED (a rep boundary lives inside) ----")
  (doseq [nm (defs-with-regime ctx "mixed")]
  (println "  mixed " nm)))
  (if (nil? cg-path) nil (let [_h1 (println "\n---- Q4. transitive HAMT blast: defs DOWNSTREAM of any HAMT/mixed def ----")
   _h2 (println "(scope-correct call graph; a caller \"forces\" a HAMT if it reaches one)")]
  (q4! rep-defs (str cg-path)))))))
