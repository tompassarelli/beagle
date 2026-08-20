(ns resolve-binds
  (:require [resolve-ident :as ri]
            [resolve-read :as rr]))

(defn- sv [ctx view e]
  (rr/sym-val ctx view e))

(defn ^Boolean brackets? [ctx view e]
  (= "#%brackets" (rr/head-sym ctx view e)))

(defn ^Boolean map-node? [ctx view e]
  (= "#%map" (rr/head-sym ctx view e)))

(defn- tail [ctx e]
  (vec (rest (rr/ordered-children ctx e))))

(defn- ^Boolean binding-form? [ctx view node]
  (let [n (rr/unwrap-meta ctx view node)]
  (or (some? (sv ctx view n)) (brackets? ctx view n) (map-node? ctx view n))))

(defn typed-binding-parts [ctx view node]
  (let [n (rr/unwrap-meta ctx view node)
   children (rr/ordered-children ctx n)]
  (if (and (= "list" (rr/kind-of ctx view n)) (contains? #{2 3} (count children)) (binding-form? ctx view (nth children 0 nil))) (do
  {:binding (nth children 0) :type (nth children 1) :constraint (nth children 2 nil)}))))

(defn signature-parts [ctx view forms ^Boolean macro? ^Boolean raises-allowed?]
  (let [params (nth forms 0 nil)]
  (if (and (some? params) (brackets? ctx view params)) (do
  (let [after-params (vec (rest forms))
   return-type (if macro? nil (nth after-params 0 nil))
   after-return (if macro? after-params (vec (rest after-params)))
   raises? (and raises-allowed? (not macro?) (= ":raises" (str (sv ctx view (nth after-return 0 nil)))))
   raises-type (if raises? (nth after-return 1 nil) nil)
   body (if raises? (vec (drop 2 after-return)) after-return)]
  {:params params :return-type return-type :raises-type raises-type :body body})))))

(defn signature-tail [ctx view forms ^Boolean macro?]
  (signature-parts ctx view forms macro? (not macro?)))

(defn- complete-signature [ctx view forms ^Boolean macro? ^Boolean raises-allowed?]
  (let [signature (signature-parts ctx view forms macro? raises-allowed?)
   raises-marker? (and raises-allowed? (= ":raises" (str (sv ctx view (nth forms 2 nil)))))
   complete? (and (some? signature) (if macro? (= 1 (count (:body signature))) (and (some? (:return-type signature)) (> (count (:body signature)) 0) (or (not raises-marker?) (some? (:raises-type signature))))))]
  (if complete? (do
  (assoc signature :forms forms)))))

(defn- structural-arity-signatures [ctx view clauses]
  (if (empty? clauses) [] (let [signatures (mapv (fn [clause] (if (= "list" (rr/kind-of ctx view clause)) (do
  (complete-signature ctx view (rr/ordered-children ctx clause) false false)))) clauses)]
  (if (every? some? signatures) signatures []))))

(defn executable-signatures [ctx view ^String head forms]
  (cond
  (contains? #{"defn" "defn-"} head) (let [tail (if (= "string" (rr/kind-of ctx view (nth forms 0 nil))) (vec (rest forms)) forms)]
  (cond
  (brackets? ctx view (nth tail 0 nil)) (let [signature (complete-signature ctx view tail false true)]
  (if (some? signature) [signature] []))
  :else (structural-arity-signatures ctx view tail)))
  (= "defmacro" head) (let [signature (complete-signature ctx view forms true false)]
  (if (some? signature) [signature] []))
  (contains? #{"fn" "fn*"} head) (let [signature (complete-signature ctx view forms false false)]
  (if (some? signature) [signature] []))
  :else []))

(defn param-type-nodes [ctx view bracket]
  (vec (keep (fn [node] (let [parts (typed-binding-parts ctx view node)]
  (if (some? parts) (do
  (:type parts))))) (tail ctx bracket))))

(defn param-constraint-nodes [ctx view bracket]
  (vec (keep (fn [node] (let [parts (typed-binding-parts ctx view node)]
  (if (some? parts) (do
  (:constraint parts))))) (tail ctx bracket))))

(defn let-type-nodes [ctx view bracket]
  (loop [nodes (tail ctx bracket)
   types []]
  (if (empty? nodes) types (let [parts (typed-binding-parts ctx view (nth nodes 0 nil))
   type-node (if (nil? parts) nil (:type parts))]
  (recur (vec (drop 2 nodes)) (if (nil? type-node) types (conj types type-node)))))))

(defn for-type-nodes [ctx view bracket]
  (loop [nodes (tail ctx bracket)
   types []]
  (if (empty? nodes) types (let [binding (nth nodes 0 nil)
   marker (str (sv ctx view binding))
   value (nth nodes 1 nil)
   rest-nodes (vec (drop 2 nodes))]
  (cond
  (= ":let" marker) (recur rest-nodes (into types (if (and (some? value) (brackets? ctx view value)) (let-type-nodes ctx view value) [])))
  (contains? #{":when" ":while"} marker) (recur rest-nodes types)
  :else (let [parts (typed-binding-parts ctx view binding)
   type-node (if (nil? parts) nil (:type parts))]
  (recur rest-nodes (if (nil? type-node) types (conj types type-node)))))))))

(defn collect-bind-syms [ctx view node]
  (if (nil? node) [] (let [n (rr/unwrap-meta ctx view node)
   v (sv ctx view n)]
  (cond
  (some? v) (if (contains? #{"_" "&"} (str v)) [] [n])
  (brackets? ctx view n) (reduce (fn [acc k] (into acc (collect-bind-syms ctx view k))) [] (tail ctx n))
  (map-node? ctx view n) (loop [ks (tail ctx n)
   acc []]
  (if (empty? ks) acc (let [k (first ks)
   kv (sv ctx view k)
   v2 (nth ks 1 nil)
   ks2 (vec (drop 2 ks))]
  (cond
  (contains? #{":keys" ":strs" ":syms"} (str kv)) (recur ks2 (into acc (if (and (some? v2) (brackets? ctx view v2)) (vec (keep (fn [c] (let [leaf (rr/unwrap-meta ctx view c)]
  (if (some? (sv ctx view leaf)) (do
  leaf)))) (tail ctx v2))) [])))
  (= ":as" (str kv)) (recur ks2 (into acc (collect-bind-syms ctx view v2)))
  (= ":or" (str kv)) (recur ks2 acc)
  (some? kv) (recur ks2 (if (nil? k) acc (conj acc k)))
  :else (recur ks2 (into acc (collect-bind-syms ctx view k)))))))
  (= "list" (rr/kind-of ctx view n)) (let [parts (typed-binding-parts ctx view n)]
  (if (nil? parts) [] (collect-bind-syms ctx view (:binding parts))))
  :else []))))

(defn collect-or-vals [ctx view node]
  (if (nil? node) [] (let [parts (typed-binding-parts ctx view node)
   binding (if (nil? parts) node (:binding parts))]
  (cond
  (map-node? ctx view binding) (loop [ks (tail ctx binding)
   acc []]
  (if (empty? ks) acc (let [k (first ks)
   kv (sv ctx view k)
   v2 (nth ks 1 nil)
   ks2 (vec (drop 2 ks))]
  (cond
  (= ":or" (str kv)) (recur ks2 (into acc (if (and (some? v2) (map-node? ctx view v2)) (vec (keep-indexed (fn [i cc] (if (odd? i) cc nil)) (tail ctx v2))) [])))
  (contains? #{":as" ":keys" ":strs" ":syms"} (str kv)) (recur ks2 acc)
  (some? kv) (recur ks2 acc)
  :else (recur ks2 (into acc (collect-or-vals ctx view k)))))))
  (brackets? ctx view binding) (reduce (fn [acc k] (into acc (collect-or-vals ctx view k))) [] (tail ctx binding))
  :else []))))

(defn param-binds [ctx view bracket]
  (loop [ks (tail ctx bracket)
   binds []]
  (if (empty? ks) binds (let [node (first ks)
   parts (typed-binding-parts ctx view node)
   binding (if (nil? parts) node (:binding parts))]
  (recur (vec (rest ks)) (into binds (collect-bind-syms ctx view binding)))))))

(defn let-bind-pairs [ctx view bracket]
  (loop [ks (tail ctx bracket)
   acc []]
  (if (empty? ks) acc (let [raw-pat (first ks)
   parts (typed-binding-parts ctx view raw-pat)
   pat (if (nil? parts) raw-pat (:binding parts))
   val (nth ks 1 nil)
   constraint (if (nil? parts) nil (:constraint parts))]
  (recur (vec (drop 2 ks)) (conj acc [(collect-bind-syms ctx view pat) val (collect-or-vals ctx view pat) constraint]))))))

(defn for-bind-pairs [ctx view bracket]
  (loop [ks (tail ctx bracket)
   acc []]
  (if (empty? ks) acc (let [k (first ks)
   kv (sv ctx view k)
   v (nth ks 1 nil)
   ks2 (vec (drop 2 ks))]
  (cond
  (contains? #{":when" ":while"} (str kv)) (recur ks2 (conj acc [:expr v]))
  (= ":let" (str kv)) (recur ks2 (into acc (if (and (some? v) (brackets? ctx view v)) (mapv (fn [p] [:bind (nth p 0 nil) (nth p 1 nil) (nth p 2 nil) (nth p 3 nil)]) (let-bind-pairs ctx view v)) [])))
  :else (let [parts (typed-binding-parts ctx view k)
   binding (if (nil? parts) k (:binding parts))
   constraint (if (nil? parts) nil (:constraint parts))]
  (recur ks2 (conj acc [:bind (collect-bind-syms ctx view binding) v (collect-or-vals ctx view binding) constraint]))))))))

(defn context-of [ctx view bsyms]
  (reduce (fn [acc b] (assoc acc (sv ctx view b) b)) {} bsyms))

(defn match-pat-binds [ctx view pat]
  (if (nil? pat) [] (let [n (rr/unwrap-meta ctx view pat)
   v (sv ctx view n)]
  (cond
  (some? v) (if (= "_" (str v)) [] [n])
  (or (= "list" (rr/kind-of ctx view n)) (brackets? ctx view n)) (reduce (fn [acc k] (into acc (match-pat-binds ctx view k))) [] (tail ctx n))
  :else []))))
