(ns resolve-query
  (:require [clojure.string :as str]
            [store.types :as t]
            [store.datalog :as d]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [resolve-read :as rr]
            [resolve-modules :as rm]
            [resolve-render :as rv]))

(def SLASH-RE (re-pattern "/"))

(def EXT-RE (re-pattern "\\.[^.]+$"))

(defn- call-refs [ctx view BOUND REFERS node]
  (if (some? (rr/refers-target ctx view BOUND REFERS node)) (if (nil? node) [] [node]) (if (= "list" (rr/kind-of ctx view node)) (reduce (fn [acc ch] (into acc (call-refs ctx view BOUND REFERS ch))) [] (rr/ordered-children ctx node)) [])))

(defn- src-label [ctx view ^String src ents]
  (let [mn (rm/module-name ctx view ents)]
  (if (some? mn) mn (str/replace (str (last (str/split src SLASH-RE))) EXT-RE ""))))

(defn- defn-meta-of [ctx view srcs file-module-context ents-of]
  (reduce (fn [acc ^String src] (let [module-context (get file-module-context src {})
   label (src-label ctx view src (get ents-of src []))]
  (reduce (fn [a nm] (let [leaf (get module-context nm)]
  (assoc a leaf {:key (str src "#" (str leaf)) :file src :module label :name nm}))) acc (set (keys module-context))))) {} srcs))

(defn- callers-of [ctx view BOUND REFERS srcs ents-of defn-meta]
  (reduce (fn [acc ^String src] (reduce (fn [a form] (let [d (rm/unwrap-def ctx view form)
   h (str (rr/head-sym ctx view d))]
  (cond
  (contains? rc/TOPLEVEL-VALUE-DEFS h) (let [cl (rm/logical-name-leaf ctx view (nth (rr/ordered-children ctx d) 1 nil))]
  (if (contains? defn-meta cl) (conj a [cl d]) a))
  (contains? #{"extend-protocol" "extend-type"} h) (reduce (fn [b cc] (let [outer (rr/unwrap-meta ctx view cc)]
  (if (= "list" (rr/kind-of ctx view outer)) (let [mnode (rm/logical-name-leaf ctx view cc)
   cl (if (some? (rr/sym-val ctx view mnode)) (rv/ultimate ctx view BOUND REFERS (rr/refers-target ctx view BOUND REFERS mnode)) nil)]
  (if (and (some? cl) (contains? defn-meta cl)) (conj b [cl cc]) b)) b))) a (vec (rest (rr/ordered-children ctx d))))
  :else a))) acc (rm/forms-of ctx view (get ents-of src [])))) [] srcs))

(defn call-edges [ctx view BOUND REFERS srcs file-module-context ents-of]
  (let [defn-meta (defn-meta-of ctx view srcs file-module-context ents-of)
   defn-set (set (keys defn-meta))
   callers (callers-of ctx view BOUND REFERS srcs ents-of defn-meta)
   edges (reduce (fn [acc pair] (let [caller-leaf (nth pair 0)
   body (nth pair 1)]
  (reduce (fn [a r] (let [callee (rv/ultimate ctx view BOUND REFERS (rr/refers-target ctx view BOUND REFERS r))]
  (if (and (contains? defn-set callee) (not= callee caller-leaf)) (conj a [caller-leaf callee]) a))) acc (call-refs ctx view BOUND REFERS body)))) [] callers)]
  {:defn-meta defn-meta :edges (vec (distinct edges)) :defn-set defn-set}))

(defn binding-privacy [ctx view srcs ents-of]
  (reduce (fn [acc ^String src] (reduce (fn [a f] (let [d (rm/unwrap-def ctx view f)
   h (str (rr/head-sym ctx view d))]
  (if (contains? rc/TOPLEVEL-VALUE-DEFS h) (let [nl (rm/logical-name-leaf ctx view (nth (rr/ordered-children ctx d) 1 nil))]
  (if (some? (rr/sym-val ctx view nl)) (assoc a nl (if (contains? #{"def-" "defn-"} h) :private :public)) a)) a))) acc (rm/forms-of ctx view (get ents-of src [])))) {} srcs))

(def ^String CALLS-DEFN "calls-defn")

(def ^String IS-ROOT "is-root")

(def ^String IS-PRIV "is-priv")

(defn- edge-propositions [edges ^String predicate]
  (mapv (fn [e] (t/triple (nth e 0) predicate (nth e 1))) edges))

(defn blast-closure! [edges]
  (let [db (d/run-rules! (edge-propositions edges CALLS-DEFN) [(d/rule "reaches" [(d/variable "x") (d/variable "y")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant CALLS-DEFN) (d/variable "y")])]) (d/rule "reaches" [(d/variable "x") (d/variable "z")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant CALLS-DEFN) (d/variable "y")]) (d/relation-literal "reaches" [(d/variable "y") (d/variable "z")])])])
   reaches (set (mapv (fn [row] [(nth row 0) (nth row 1)]) (vec (d/facts db "reaches"))))
   blast (reduce (fn [m row] (let [x (nth row 0)
   y (nth row 1)]
  (assoc m y (conj (get m y #{}) x)))) {} (vec reaches))]
  {:reaches reaches :blast blast}))

(defn dead-private-bindings! [cg privacy]
  (let [defn-meta (:defn-meta cg {})
   edges (:edges cg [])
   marks (mapv (fn [leaf] (t/triple leaf (if (= :private (get privacy leaf)) IS-PRIV IS-ROOT) leaf)) (vec (set (keys defn-meta))))
   db (d/run-strata-db! (d/edb (vec (concat (edge-propositions edges CALLS-DEFN) marks))) [[(d/rule "live" [(d/variable "x")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant IS-ROOT) (d/variable "x")])]) (d/rule "live" [(d/variable "y")] [(d/relation-literal d/triple-relation [(d/variable "x") (d/constant CALLS-DEFN) (d/variable "y")]) (d/relation-literal "live" [(d/variable "x")])])] [(d/rule "dead" [(d/variable "p")] [(d/relation-literal d/triple-relation [(d/variable "p") (d/constant IS-PRIV) (d/variable "p")]) (d/negated-literal "live" [(d/variable "p")])])]])]
  (set (vec (keep (fn [row] (nth row 0)) (vec (d/facts db "dead")))))))
