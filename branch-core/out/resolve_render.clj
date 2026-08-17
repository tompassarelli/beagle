(ns resolve-render
  (:require [clojure.string :as str]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [resolve-read :as rr]
            [resolve-binds :as rb]))

(defn ultimate [ctx view BOUND REFERS B]
  (loop [b B
   n 0]
  (let [tgt (rr/refers-target ctx view BOUND REFERS b)]
  (if (and (some? tgt) (< n 64)) (recur tgt (inc n)) b))))

(defn binding-name [ctx view BOUND REFERS B]
  (rr/sym-val ctx view (ultimate ctx view BOUND REFERS B)))

(defn render-sym [ctx view BOUND REFERS FIXED e]
  (let [v (rr/pred-val ctx view e "v")
   D (rr/refers-target ctx view BOUND REFERS e)]
  (if (nil? D) v (let [fixed? (and (some? ctx) (some? FIXED) (some? e) (not (empty? (ri/by-subject-predicate ctx e FIXED))))
   qual (rr/pred-val ctx view e "qualifier")
   cpfx (rr/pred-val ctx view e "ctor_prefix")
   afield (rr/pred-val ctx view e "accessor_field")
   nm0 (binding-name ctx view BOUND REFERS D)
   nm (cond
  (some? cpfx) (str (str cpfx) (str nm0))
  (some? afield) (str (str/lower-case (str nm0)) "-" (str afield))
  :else nm0)]
  (cond
  fixed? v
  (some? qual) (str (str qual) "/" (str nm))
  :else nm)))))

(defn ord-edges [ctx n]
  (if (or (nil? ctx) (nil? n)) [] (let [rows (reduce (fn [acc cid] (let [p (ri/predicate-at ctx cid)
   r (ri/target-at ctx cid)]
  (if (and (string? p) (rc/ord-pos? p) (some? r)) (conj acc [(rc/ord-parse p) p cid r]) acc))) [] (ri/by-subject ctx n))]
  (vec (sort-by (fn [row] (nth row 0)) rc/ord-cmp rows)))))

(defn ^String node->str [ctx view BOUND REFERS FIXED n]
  (let [k (rr/kind-of ctx view n)]
  (cond
  (= "list" k) (let [kids (rr/ordered-children ctx n)
   h (nth kids 0 nil)
   hs (if (and (some? h) (= "symbol" (rr/kind-of ctx view h))) (render-sym ctx view BOUND REFERS FIXED h) nil)
   kidstr (fn [ks] (str/join " " (mapv (fn [c] (node->str ctx view BOUND REFERS FIXED c)) ks)))]
  (cond
  (= hs "#%brackets") (str "[" (kidstr (vec (rest kids))) "]")
  (= hs "#%map") (str "{" (kidstr (vec (rest kids))) "}")
  (= hs "#%set") (str "#{" (kidstr (vec (rest kids))) "}")
  (= hs "#%regex") (str "#\"" (str (rr/pred-val ctx view (nth kids 1 nil) "v")) "\"")
  :else (str "(" (kidstr kids) ")")))
  (= "symbol" k) (str (render-sym ctx view BOUND REFERS FIXED n))
  (= "string" k) (pr-str (rr/pred-val ctx view n "v"))
  (= "number" k) (str (rr/pred-val ctx view n "v"))
  (= "char" k) (str "\\" (str (rr/pred-val ctx view n "v")))
  :else (str (rr/pred-val ctx view n "v")))))

(defn node->canon [ctx view BOUND REFERS FIXED n]
  (if (= "list" (rr/kind-of ctx view n)) (into [:list] (mapv (fn [c] (node->canon ctx view BOUND REFERS FIXED c)) (rr/ordered-children ctx n))) (if (= "symbol" (rr/kind-of ctx view n)) [:leaf "symbol" (render-sym ctx view BOUND REFERS FIXED n)] [:leaf (rr/kind-of ctx view n) (rr/pred-val ctx view n "v")])))

(defn- anchor-go [ctx view BOUND REFERS FIXED n target chain]
  (if (= "list" (rr/kind-of ctx view n)) (let [chain2 (if (nil? n) chain (conj chain n))
   st (reduce (fn [st row] (let [pos (nth row 1)
   cid (nth row 2)
   ch (nth row 3)
   sub (anchor-go ctx view BOUND REFERS FIXED ch target chain2)
   cc (nth sub 0)
   ms (into (nth st 1) (nth sub 1))]
  [(conj (nth st 0) cc) (if (= cc target) (conj ms {:parent n :pos pos :cid cid :child ch :chain chain2}) ms)])) [[] []] (ord-edges ctx n))]
  [(into [:list] (nth st 0)) (nth st 1)]) [(if (= "symbol" (rr/kind-of ctx view n)) [:leaf "symbol" (render-sym ctx view BOUND REFERS FIXED n)] [:leaf (rr/kind-of ctx view n) (rr/pred-val ctx view n "v")]) []]))

(defn anchor-match-sites [ctx view BOUND REFERS FIXED root target]
  (vec (nth (anchor-go ctx view BOUND REFERS FIXED root target []) 1)))

(defn anchor-matches [ctx view BOUND REFERS FIXED root target]
  (mapv (fn [s] [(:parent s) (:pos s) (:cid s) (:child s)]) (anchor-match-sites ctx view BOUND REFERS FIXED root target)))

(defn crumb-label [ctx view n]
  (let [h (rr/head-sym ctx view n)]
  (if (some? h) h (cond
  (rb/map-node? ctx view n) "{}"
  (rb/brackets? ctx view n) "[]"
  :else "(...)"))))
