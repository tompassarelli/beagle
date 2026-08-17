(ns fram.claims
  (:require [fram.types :as t]
            [fram.schema :as s]
            [fram.rotation :as rot]
            [fram.datalog :as d]
            [fram.rt :as rt]
            [clojure.string :as str]))

(def ^String evidence-pred "claim.evidence")

(def ^String reason-pred "claim.reason")

(def ^String source-pred "evidence.source")

(def ^String region-pred "evidence.region")

(def ^String fingerprint-pred "evidence.fingerprint")

(def ^String world-pred "evidence.world")

(def ^String verified-view "@view:claim.verified")

(def ^String rejected-view "@view:claim.rejected")

(def ^String select-pred "selects")

(def ^String world-record-pred "world.record")

(def ^String version-prefix "world.version:")

(def ^String reverification-relation "claim.reverification")

(def ^String changed-slot-relation "claim.changed-slot")

(def ^String verdict-view-relation "claim.verdict-view")

(def default-views {:verified verified-view :rejected rejected-view})

(defn ^String scoped-view [^String root ^String agent]
  (str root ":" agent))

(defn- sess [co]
  (:schema co))

(defn- vw [co]
  (s/view (sess co)))

(defn- pid [co ^String spelling]
  (s/resolve-predicate (sess co) spelling))

(defn- ^Boolean family? [^String root nm]
  (if (nil? nm) false (or (= nm root) (str/starts-with? (str nm) (str root ":")))))

(defn- writer-of [co occurrence]
  (get (:writers co) occurrence))

(defn evidence-nodes [co claim]
  (let [p (pid co evidence-pred)]
  (if (nil? p) [] (vec (distinct (rot/values (rot/by-t12 (vw co) claim p)))))))

(defn evidence [co node]
  (let [st (sess co)]
  {:node node :source (s/lookup st node source-pred) :region (s/lookup st node region-pred) :fingerprint (s/lookup st node fingerprint-pred) :world (s/lookup st node world-pred)}))

(defn provenance [co claim]
  (mapv (fn [n] (evidence co n)) (evidence-nodes co claim)))

(defn- selections-of [co claim]
  (let [p (pid co select-pred)]
  (if (nil? p) [] (rot/by-t23 (vw co) p claim))))

(defn- verdict-of [co views selection]
  (let [occurrence (rot/occurrence-of selection)
   nm (s/name-of (sess co) (t/triple-t1 (rot/proposition-of selection)))]
  (cond
  (family? (:verified views) nm) {:verdict :verified :view nm :by (writer-of co occurrence) :cid occurrence}
  (family? (:rejected views) nm) {:verdict :rejected :view nm :by (writer-of co occurrence) :cid occurrence}
  :else nil)))

(defn verdict
  ([co claim]
    (verdict co default-views claim))
  ([co views claim]
    (reduce (fn [best selection] (let [v (verdict-of co views selection)]
  (cond
  (nil? v) best
  (nil? best) v
  (t/occurrence-before? (:cid best) (:cid v)) v
  :else best))) nil (selections-of co claim))))

(defn verifier [co claim]
  (let [v (verdict co claim)]
  (if (and (some? v) (= :verified (:verdict v))) (:by v) nil)))

(defn rejection [co claim]
  (let [v (verdict co claim)]
  (if (and (some? v) (= :rejected (:verdict v))) {:reason (s/lookup (sess co) claim reason-pred) :by (:by v) :cid (:cid v)} nil)))

(defn status
  ([co claim]
    (status co default-views claim))
  ([co views claim]
    (if (not (rot/live-occurrence? (vw co) claim)) :superseded (let [v (verdict co views claim)]
  (cond
  (some? v) (:verdict v)
  (not (empty? (evidence-nodes co claim))) :pending
  :else nil)))))

(defn- version-record-of [co vid]
  (let [e (s/resolve-name (sess co) (str version-prefix vid))]
  (if (nil? e) nil (let [t (s/lookup (sess co) e world-record-pred)]
  (if (nil? t) nil (fram.rt/parse-edn (str t)))))))

(defn- version-chain [co vid]
  (loop [v vid
   acc {}]
  (if (or (nil? v) (contains? acc v)) acc (let [r (version-record-of co v)]
  (if (nil? r) acc (recur (:base r) (assoc acc v r)))))))

(defn- resolve-slot [versions version slot]
  (loop [vid version]
  (if (nil? vid) nil (let [record (get versions vid)]
  (if (nil? record) nil (let [hits (filterv (fn [e] (= (:slot e) slot)) (vec (:overlay record)))
   e (if (empty? hits) nil (first hits))]
  (cond
  (nil? e) (recur (:base record))
  (= (:op e) :inherit) (recur (:base record))
  (= (:op e) :delete) nil
  :else {:blob-id (:blob-id e)})))))))

(defn- chain-slots [versions version]
  (loop [vid version
   acc []]
  (if (nil? vid) (vec (distinct acc)) (let [record (get versions vid)]
  (if (nil? record) (vec (distinct acc)) (recur (:base record) (vec (concat acc (mapv (fn [e] (:slot e)) (vec (:overlay record)))))))))))

(defn- slot-blobs [co vid]
  (let [versions (version-chain co vid)]
  (reduce (fn [m s] (let [r (resolve-slot versions vid s)]
  (if (nil? r) m (assoc m s (:blob-id r))))) {} (chain-slots versions vid))))

(defn- changed-slots [co from to]
  (let [a (slot-blobs co from)
   b (slot-blobs co to)]
  (vec (filterv (fn [k] (not (= (get a k) (get b k)))) (vec (sort (vec (keys a))))))))

(defn- verdict-view-ids [co views]
  (let [p (pid co select-pred)]
  (if (nil? p) [] (vec (distinct (reduce (fn [acc selection] (let [l (t/triple-t1 (rot/proposition-of selection))]
  (if (family? (:verified views) (s/name-of (sess co) l)) (conj acc l) acc))) [] (rot/by-t2 (vw co) p)))))))

(defn reverification-rules
  ([co from to]
    (reverification-rules co default-views from to))
  ([co views from to]
    (let [evp (pid co evidence-pred)
   srp (pid co source-pred)
   wlp (pid co world-pred)
   selp (pid co select-pred)
   slots (if (nil? from) [] (changed-slots co from to))
   vids (verdict-view-ids co views)]
  (if (or (nil? evp) (or (nil? srp) (or (nil? wlp) (or (nil? selp) (or (nil? from) (or (empty? slots) (empty? vids))))))) [[] []] [(vec (concat (mapv (fn [sid] (d/rule changed-slot-relation [(d/constant sid)] [])) slots) (mapv (fn [v] (d/rule verdict-view-relation [(d/constant v)] [])) vids))) [(d/rule reverification-relation [(d/variable "x")] [(d/relation-literal d/triple-relation [(d/variable "e") (d/constant wlp) (d/constant from)]) (d/relation-literal d/triple-relation [(d/variable "e") (d/constant srp) (d/variable "s")]) (d/relation-literal changed-slot-relation [(d/variable "s")]) (d/relation-literal d/triple-relation [(d/variable "x") (d/constant evp) (d/variable "e")]) (d/relation-literal d/occurrence-relation [(d/variable "x") (d/constant :assert) (d/variable "p")]) (d/relation-literal d/triple-relation [(d/variable "view") (d/constant selp) (d/variable "x")]) (d/relation-literal verdict-view-relation [(d/variable "view")])])]]))))

(defn- live-db [co]
  (let [events (rot/all-occurrences (vw co))]
  (d/edb-with-history (rot/propositions events) events [])))

(defn needs-reverification!
  ([co from to]
    (needs-reverification! co default-views from to))
  ([co views from to]
    (let [db (d/run-strata-db! (live-db co) (reverification-rules co views from to))]
  (set (mapv (fn [t] (get t 0)) (d/facts db reverification-relation))))))
