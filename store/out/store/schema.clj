(ns store.schema
  (:require [store.types :as t]
            [store.rotation :as rot]
            [store.txn :as txn]))

(defrecord OrderedResultSnapshot [space version lower-exclusive])

(defn orderedresultsnapshot-space [r] (:space r))

(defn orderedresultsnapshot-version [r] (:version r))

(defn orderedresultsnapshot-lower-exclusive [r] (:lower-exclusive r))

(defrecord OrderedResultKey [snapshot operation digest])

(defn orderedresultkey-snapshot [r] (:snapshot r))

(defn orderedresultkey-operation [r] (:operation r))

(defn orderedresultkey-digest [r] (:digest r))

(defrecord OrderedResultEntry [key query-rows triple-rows bytes])

(defn orderedresultentry-key [r] (:key r))

(defn orderedresultentry-query-rows [r] (:query-rows r))

(defn orderedresultentry-triple-rows [r] (:triple-rows r))

(defn orderedresultentry-bytes [r] (:bytes r))

(defrecord OrderedResultCache [entries snapshots bytes hits misses evictions])

(defn orderedresultcache-entries [r] (:entries r))

(defn orderedresultcache-snapshots [r] (:snapshots r))

(defn orderedresultcache-bytes [r] (:bytes r))

(defn orderedresultcache-hits [r] (:hits r))

(defn orderedresultcache-misses [r] (:misses r))

(defn orderedresultcache-evictions [r] (:evictions r))

(defrecord Session [store view ordered-results derived-generation])

(defn session-store [r] (:store r))

(defn session-view [r] (:view r))

(defn session-ordered-results [r] (:ordered-results r))

(defn session-derived-generation [r] (:derived-generation r))

(def ^String name-predicate "name")

(def ^String cardinality-predicate "cardinality")

(def ^String value-kind-predicate "value_kind")

(def ^String predicate-name-predicate "predicate_name")

(def ^String predicate-alias-predicate "predicate_alias")

(def ^String single "single")

(def ^String multi "multi")

(def ^String literal-kind "literal")

(def ^String ref-kind "ref")

(def no-terms [])

(def no-ordered-result-entries [])

(def no-ordered-result-snapshots [])

(defn ^OrderedResultCache empty-ordered-result-cache []
  (->OrderedResultCache no-ordered-result-entries no-ordered-result-snapshots 0 0 0 0))

(defn ^Session session! [ctx]
  (->Session ctx (atom (rot/project! ctx)) (atom (empty-ordered-result-cache)) (atom 0)))

(defn ^Session fork-session [^Session s]
  (->Session (atom (deref (session-store s))) (atom (deref (session-view s))) (atom (deref (session-ordered-results s))) (atom (deref (session-derived-generation s)))))

(defn store-of [^Session s]
  (session-store s))

(defn ordered-results-of [^Session s]
  (session-ordered-results s))

(defn derived-generation-of [^Session s]
  (deref (session-derived-generation s)))

(defn mark-derived-change! [^Session s]
  (do
  (reset! (session-derived-generation s) (inc (deref (session-derived-generation s))))
  nil))

(defn view [^Session s]
  (deref (session-view s)))

(defn ^Session refresh! [^Session s]
  (do
  (reset! (session-view s) (rot/refresh! (view s) (store-of s)))
  s))

(defn- ^Session commit! [^Session s builder]
  (do
  (txn/commit! (store-of s) builder)
  (refresh! s)))

(defn predicate-ids [^Session s ^String spelling]
  (vec (distinct (concat (rot/subjects (rot/by-t23 (view s) predicate-name-predicate spelling)) (rot/subjects (rot/by-t23 (view s) predicate-alias-predicate spelling))))))

(defn resolve-predicate [^Session s ^String spelling]
  (let [ids (predicate-ids s spelling)]
  (cond
  (> (count ids) 1) (throw (ex-info (str "predicate spelling collision: " spelling) {:predicate spelling :ids ids}))
  (= (count ids) 1) (first ids)
  :else nil)))

(defn ^String predicate-name [^Session s pid]
  (let [events (rot/by-t12 (view s) pid predicate-name-predicate)
   raw (if (empty? events) pid (t/triple-t3 (rot/proposition-of (last events))))]
  (if (string? raw) raw (str raw))))

(defn register-predicate! [^Session s ^String spelling]
  (let [candidate (resolve-predicate s spelling)
   ^String canonical (if (some? candidate) (predicate-name s candidate) spelling)
   ^String default-alias (str ":" canonical)
   alias-ids (predicate-ids s default-alias)]
  (do
  (if (and (not (empty? alias-ids)) (or (nil? candidate) (not (and (= 1 (count alias-ids)) (= candidate (first alias-ids)))))) (do
  (throw (ex-info (str "predicate alias collision: " default-alias) {:predicate canonical :alias default-alias :ids alias-ids}))))
  (let [pid (if (some? candidate) candidate spelling)
   named (rot/by-t12 (view s) pid predicate-name-predicate)
   builder (txn/open (store-of s))]
  (do
  (if (empty? named) (do
  (txn/assert! builder (t/triple pid predicate-name-predicate spelling))))
  (if (empty? alias-ids) (do
  (txn/assert! builder (t/triple pid predicate-alias-predicate default-alias))))
  (if (pos? (txn/operation-count builder)) (do
  (commit! s builder)))
  pid)))))

(defn ^String cardinality [^Session s ^String pname]
  (let [pid (resolve-predicate s pname)
   card (resolve-predicate s cardinality-predicate)
   events (if (and (some? pid) (some? card)) (rot/by-t12 (view s) pid card) [])]
  (if (empty? events) multi (let [value (t/triple-t3 (rot/proposition-of (first events)))]
  (if (string? value) value multi)))))

(defn assert! [^Session s subject ^String pname value]
  (let [pid (register-predicate! s pname)
   builder (txn/open (store-of s))
   occurrence (if (= single (cardinality s pname)) (txn/update-single! builder (view s) subject pid value) (txn/assert! builder (t/triple subject pid value)))]
  (do
  (commit! s builder)
  occurrence)))

(defn link! [^Session s subject ^String pname target]
  (assert! s subject pname target))

(defn lookup-all [^Session s subject ^String pname]
  (let [pid (resolve-predicate s pname)]
  (if (nil? pid) no-terms (rot/values (rot/by-t12 (view s) subject pid)))))

(defn lookup [^Session s subject ^String pname]
  (let [all (lookup-all s subject pname)]
  (if (empty? all) nil (first all))))

(defn find-by [^Session s ^String pname value]
  (let [pid (resolve-predicate s pname)]
  (if (nil? pid) no-terms (rot/subjects (rot/by-t23 (view s) pid value)))))

(defn def-predicate! [^Session s ^String pname ^String card ^String kind]
  (let [pid (register-predicate! s pname)]
  (do
  (assert! s pid cardinality-predicate card)
  (assert! s pid value-kind-predicate kind)
  pid)))

(defn mint-node! [^Session s ^String pname value]
  (let [pid (register-predicate! s pname)
   builder (txn/open (store-of s))
   node (txn/mint! builder)]
  (do
  (txn/assert! builder (t/triple node pid value))
  (commit! s builder)
  node)))

(defn name! [^Session s subject ^String nm]
  (assert! s subject name-predicate nm))

(defn name-of [^Session s subject]
  (lookup s subject name-predicate))

(defn resolve-name [^Session s ^String nm]
  (let [ls (find-by s name-predicate nm)]
  (if (empty? ls) nil (first ls))))

(defn alias-predicate! [^Session s ^String spelling ^String alias]
  (let [resolved (resolve-predicate s spelling)
   ids-before (predicate-ids s alias)]
  (do
  (if (and (not (empty? ids-before)) (or (nil? resolved) (not (and (= 1 (count ids-before)) (= resolved (first ids-before)))))) (do
  (throw (ex-info (str "predicate spelling collision: " alias) {:predicate spelling :alias alias :ids ids-before}))))
  (let [pid (register-predicate! s spelling)
   ids (predicate-ids s alias)]
  (do
  (if (empty? ids) (do
  (let [builder (txn/open (store-of s))]
  (do
  (txn/assert! builder (t/triple pid predicate-alias-predicate alias))
  (commit! s builder)))))
  pid)))))

(defn rename-predicate! [^Session s ^String spelling ^String new-name]
  (let [resolved (resolve-predicate s spelling)
   name-ids (predicate-ids s new-name)
   ^String default-alias (str ":" new-name)
   alias-ids (predicate-ids s default-alias)]
  (do
  (if (and (not (empty? name-ids)) (or (nil? resolved) (not (and (= 1 (count name-ids)) (= resolved (first name-ids)))))) (do
  (throw (ex-info (str "predicate spelling collision: " new-name) {:predicate spelling :new-name new-name :ids name-ids}))))
  (if (and (not (empty? alias-ids)) (or (nil? resolved) (not (and (= 1 (count alias-ids)) (= resolved (first alias-ids)))))) (do
  (throw (ex-info (str "predicate alias collision: " default-alias) {:predicate spelling :new-name new-name :alias default-alias :ids alias-ids}))))
  (let [pid (register-predicate! s spelling)
   old-name (predicate-name s pid)]
  (do
  (if (not (= old-name new-name)) (do
  (do
  (let [old-ids (predicate-ids s old-name)
   aliases (rot/by-t23 (view s) predicate-alias-predicate old-name)]
  (if (and (= 1 (count old-ids)) (and (= pid (first old-ids)) (empty? aliases))) (do
  (let [builder (txn/open (store-of s))]
  (do
  (txn/assert! builder (t/triple pid predicate-alias-predicate old-name))
  (commit! s builder))))))
  (assert! s pid predicate-name-predicate new-name)
  (alias-predicate! s new-name default-alias))))
  pid)))))

(defn ^Session setup! [^Session s]
  (do
  (def-predicate! s cardinality-predicate single literal-kind)
  (def-predicate! s value-kind-predicate single literal-kind)
  (def-predicate! s name-predicate single literal-kind)
  (def-predicate! s predicate-name-predicate single literal-kind)
  (def-predicate! s predicate-alias-predicate multi literal-kind)
  s))
