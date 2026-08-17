(ns resolve-read
  (:require [fram.types :as t]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [fram.rotation :as rot]
            [fram.txn :as txn]))

(def SEG-RE (re-pattern "seg\\d+"))

(defrecord OrdPair [key child])

(defn ordpair-key [r] (:key r))

(defn ordpair-child [r] (:child r))

(defrecord SegPair [idx child])

(defn segpair-idx [r] (:idx r))

(defn segpair-child [r] (:child r))

(defn view-cids [ctx v cids]
  (if (nil? v) nil (let [sel (reduce (fn [acc occ] (let [r (ri/value-at ctx occ)]
  (if (nil? r) acc (conj acc r)))) #{} (ri/by-subject-predicate ctx v "selects"))]
  (filterv (fn [cid] (contains? sel cid)) cids))))

(defn- pool-of [ctx view cids]
  (let [in-view (if (nil? view) nil (view-cids ctx view cids))]
  (if (or (nil? in-view) (empty? in-view)) cids in-view)))

(defn- occ-key [ctx occ]
  [(ri/occurrence-order occ) (ri/writer-of ctx occ)])

(defn select-main-1 [ctx view cids]
  (if (empty? cids) nil (if (nil? ctx) (first cids) (first (sort-by (fn [cid] (occ-key ctx cid)) (pool-of ctx view cids))))))

(defn select-causal-1 [ctx view cids]
  (if (empty? cids) nil (if (nil? ctx) (first cids) (first (sort-by (fn [cid] (occ-key ctx cid)) (pool-of ctx view cids))))))

(defn- fact-r [ctx cid]
  (if (or (nil? ctx) (nil? cid)) nil (ri/target-at ctx cid)))

(defn pred-val [ctx view e pname]
  (if (or (nil? ctx) (nil? e)) nil (let [occ (select-main-1 ctx view (ri/by-subject-predicate ctx e pname))]
  (if (nil? occ) nil (ri/value-at ctx occ)))))

(defn kind-of [ctx view e]
  (pred-val ctx view e "kind"))

(defn sym-qualifier [ctx view e]
  (if (= "symbol" (kind-of ctx view e)) (pred-val ctx view e "qualifier") nil))

(defn sym-val [ctx view e]
  (if (= "symbol" (kind-of ctx view e)) (let [name (pred-val ctx view e "name")]
  (if (some? name) name (pred-val ctx view e "v"))) nil))

(defn ordered-children [ctx e]
  (if (or (nil? ctx) (nil? e)) [] (let [pairs (reduce (fn [acc cid] (let [k (rc/ord-parse (ri/predicate-at ctx cid))
   r (fact-r ctx cid)]
  (if (or (nil? k) (nil? r)) acc (conj acc (->OrdPair k r))))) [] (ri/by-subject ctx e))]
  (mapv (fn [^OrdPair pr] (:child pr)) (sort-by (fn [^OrdPair pr] (:key pr)) rc/ord-cmp pairs)))))

(defn ordered-segs [ctx e]
  (if (or (nil? ctx) (nil? e)) [] (let [pairs (reduce (fn [acc cid] (let [p (ri/predicate-at ctx cid)
   r (fact-r ctx cid)]
  (if (and (string? p) (some? (re-matches SEG-RE (str p))) (some? r)) (let [n (parse-long (subs (str p) 3))]
  (if (nil? n) acc (conj acc (->SegPair n r)))) acc))) [] (ri/by-subject ctx e))]
  (mapv (fn [^SegPair pr] (:child pr)) (sort-by (fn [^SegPair pr] (:idx pr)) pairs)))))

(defn head-sym [ctx view e]
  (if (= "list" (kind-of ctx view e)) (let [head (first (ordered-children ctx e))]
  (if (nil? (sym-qualifier ctx view head)) (sym-val ctx view head) nil)) nil))

(defn unwrap-meta [ctx view e]
  (loop [e e
   n 0]
  (if (and (some? e) (< n 64) (= "#%meta" (head-sym ctx view e))) (recur (nth (ordered-children ctx e) 2 nil) (inc n)) e)))

(defn bound-target [ctx view BOUND L]
  (if (or (nil? ctx) (nil? BOUND) (nil? L)) nil (fact-r ctx (select-main-1 ctx view (ri/by-subject-predicate ctx L BOUND)))))

(defn refers-target [ctx view BOUND REFERS L]
  (let [bt (bound-target ctx view BOUND L)]
  (if (some? bt) bt (if (or (nil? ctx) (nil? REFERS) (nil? L)) nil (fact-r ctx (select-main-1 ctx view (ri/by-subject-predicate ctx L REFERS)))))))

(defn ^Boolean live-node? [ctx KIND e]
  (if (or (nil? ctx) (nil? KIND) (nil? e)) false (not (empty? (ri/by-subject-predicate ctx e KIND)))))

(def builder-key :builder)

(defn builder [context]
  (get (ri/writers-of context) builder-key))

(defn- resync! [context]
  (let [open (deref (builder context))
   coordinate (txn/builder-coordinate open)
   store (ri/store-of context)]
  (ri/with-view! context (rot/staged (rot/project! store) (t/triple-t1 coordinate) (t/triple-t3 coordinate) (txn/builder-operations open)))))

(defn context! [store]
  (ri/graph! store {builder-key (txn/open store)}))

(defn mint! [context]
  (txn/mint! (builder context)))

(defn assert! [context subject predicate value]
  (let [occurrence (txn/assert! (builder context) (t/triple subject predicate value))]
  (do
  (resync! context)
  occurrence)))

(defn update-single! [context subject predicate value]
  (let [occurrence (txn/update-single! (builder context) (ri/view context) subject predicate value)]
  (do
  (resync! context)
  occurrence)))

(defn commit! [context]
  (let [store (ri/store-of context)
   cell (builder context)
   coordinate (txn/commit! store cell)]
  (do
  (reset! cell (deref (txn/open store)))
  (resync! context)
  coordinate)))

(defn events-by-subject [context subject]
  (rot/by-t1 (ri/view context) subject))

(defn events-by-subject-predicate [context subject predicate]
  (rot/by-t12 (ri/view context) subject predicate))

(defn event-predicate [event]
  (t/triple-t2 (rot/proposition-of event)))

(defn event-value [event]
  (t/triple-t3 (rot/proposition-of event)))
