(ns pull
  (:require [store.store :as c]
            [store.schema :as s]
            [store.types :as t]
            [clojure.string :as str]))

(def default-max-depth 5)

(def default-max-nodes 1000)

(def reserved-preds #{"withdrawn_reason" "value_kind" "withdrawn_by" "store-supersedes" "name" "withdrawn_at" "cardinality"})

(defn- ^Boolean reserved-pred? [p]
  (contains? reserved-preds p))

(defn- clamp [v default]
  (if (and (integer? v) (pos? v)) (min v default) default))

(defn- ^Boolean valid-elem? [e]
  (letfn [(valid-subpat? [sp] (or (and (vector? sp) (every? (fn [x] (elem? x)) sp)) (and (integer? sp) (pos? sp)) (= sp :...)))
          (elem? [x] (cond
  (= x :*) true
  (string? x) (not (str/blank? x))
  (map? x) (and (seq x) (every? (fn [k] (and (string? k) (not (str/blank? k)) (valid-subpat? (get x k)))) (keys x)))
  :else false))]
  (elem? e)))

(defn validate [root pattern opts]
  (let [e-root (if (or (and (string? root) (not (str/blank? root))) (and (vector? root) (seq root) (every? (fn [x] (and (string? x) (not (str/blank? x)))) root))) [] ["root must be a subject-name string or a non-empty vector of name strings"])
   e-pat (if (vector? pattern) (vec (mapcat (fn [e] (if (valid-elem? e) [] [(str "malformed pattern element: " (pr-str e))])) pattern)) ["pattern must be a vector"])
   e-caps (vec (mapcat (fn [k] (let [v (get opts k)]
  (if (and (contains? opts k) (not (and (integer? v) (pos? v)))) [(str k " must be a positive integer")] []))) [:max-depth :max-nodes]))
   e-asof (let [v (:as-of opts)]
  (if (and (contains? opts :as-of) (not (and (integer? v) (>= v 0)))) [":as-of must be a non-negative integer"] []))]
  (vec (concat e-root e-pat e-caps e-asof))))

(defn run! [store-atom root pattern opts]
  (let [errs (validate root pattern opts)]
  (if (seq errs) {:error errs} (let [schema (s/session! store-atom)
   occurrences (c/occurrences store-atom)
   live-now (c/live-occurrences store-atom)
   withdrawals (c/withdrawals store-atom)
   asof (let [candidate (:as-of opts)]
  (if (integer? candidate) candidate nil))
   prov? (boolean (:provenance opts))
   max-depth (clamp (:max-depth opts) default-max-depth)
   max-nodes (clamp (:max-nodes opts) default-max-nodes)
   state (atom 0)]
  (letfn [(event-occurrence [event] (t/operationoccurrence-coordinate event))
          (event-proposition [event] (t/operationoccurrence-proposition event))
          (event-sequence [event] (let [occurrence (event-occurrence event)
   transaction (t/triple-t1 occurrence)]
  (t/triple-t3 transaction)))
          (assertion-event? [event] (t/assertion-occurrence? event))
          (events-at [cutoff] (reduce (fn [active event] (if (> (event-sequence event) cutoff) active (if (assertion-event? event) (conj active event) (let [proposition (event-proposition event)
   target (last (filterv (fn [candidate] (= proposition (event-proposition candidate))) active))]
  (if (nil? target) active (filterv (fn [candidate] (not= (event-occurrence target) (event-occurrence candidate))) active)))))) [] occurrences))
          (snapshot-events [] (if (some? asof) (events-at asof) live-now))
          (live-event? [event] (boolean (some (fn [candidate] (= (event-occurrence event) (event-occurrence candidate))) live-now)))
          (withdrawal-for [occurrence] (let [withdrawal (first (filterv (fn [candidate] (= occurrence (t/operationoccurrence-coordinate (t/withdrawal-assertion candidate)))) withdrawals))]
  withdrawal))
          (metadata-value [owner predicate] (let [event (last (filterv (fn [candidate] (if (assertion-event? candidate) (let [proposition (event-proposition candidate)]
  (and (= owner (t/triple-t1 proposition)) (= predicate (t/triple-t2 proposition)) (or (nil? asof) (<= (event-sequence candidate) asof)))) false)) (snapshot-events)))]
  (if (nil? event) nil (t/triple-t3 (event-proposition event)))))
          (agent-of [occurrence] (or (metadata-value occurrence :kernel/asserted-by) (metadata-value (t/triple-t1 occurrence) :kernel/asserted-by)))
          (recorded-at-of [occurrence] (or (metadata-value occurrence :kernel/recorded-at) (metadata-value (t/triple-t1 occurrence) :kernel/recorded-at)))
          (pid-of [^String p] (s/resolve-predicate schema p))
          (nm-of [term] (or (s/name-of schema term) term))
          (fwd-events [left predicate] (let [candidates (cond
  (some? asof) (snapshot-events)
  prov? (filterv (fn [event] (and (assertion-event? event) (or (live-event? event) (some? (withdrawal-for (event-occurrence event)))))) occurrences)
  :else live-now)]
  (filterv (fn [event] (if (assertion-event? event) (let [proposition (event-proposition event)]
  (and (= left (t/triple-t1 proposition)) (= predicate (t/triple-t2 proposition)))) false)) candidates)))
          (rev-events [predicate right] (filterv (fn [event] (if (assertion-event? event) (let [proposition (event-proposition event)]
  (and (= predicate (t/triple-t2 proposition)) (= right (t/triple-t3 proposition)))) false)) (snapshot-events)))
          (subject-events [left] (filterv (fn [event] (and (assertion-event? event) (= left (t/triple-t1 (event-proposition event))))) (snapshot-events)))
          (leaf [predicate event] (let [proposition (event-proposition event)
   right (t/triple-t3 proposition)
   value (if (= s/ref-kind (s/lookup schema predicate s/value-kind-predicate)) (nm-of right) right)]
  (if prov? (let [occurrence (event-occurrence event)
   withdrawal (if (some? asof) nil (withdrawal-for occurrence))
   recorded-at (recorded-at-of occurrence)
   base (cond-> {:val value :cid occurrence :by (agent-of occurrence) :seq (event-sequence event) :withdrawn (boolean withdrawal)} (some? recorded-at) (assoc :ts recorded-at))]
  (if (nil? withdrawal) base (let [retraction (t/operationoccurrence-coordinate (t/withdrawal-retraction withdrawal))]
  (assoc base :withdrawn_by (agent-of retraction) :withdrawn_at retraction)))) value)))
          (values [^String pname predicate left] (let [events (fwd-events left predicate)]
  (if (seq events) (do
  (let [rendered (mapv (fn [event] (leaf predicate event)) events)]
  (if (= "single" (s/cardinality schema pname)) (last rendered) rendered))))))
          (subpat->pattern [^String key subpattern] (cond
  (vector? subpattern) subpattern
  (integer? subpattern) (if (> subpattern 1) [{key (dec subpattern)}] [])
  (= subpattern :...) [{key :...}]
  :else []))
          (recur-target [target subpattern depth visited] (if (> (inc depth) max-depth) {:store/id (nm-of target) :store/truncated true} (node target (nm-of target) subpattern (inc depth) visited)))
          (elem [acc left depth visited element] (cond
  (= element :*) (reduce (fn [result predicate] (let [pname (s/predicate-name schema predicate)]
  (if (reserved-pred? pname) result (let [value (values pname predicate left)]
  (if (nil? value) result (assoc result pname value)))))) acc (distinct (mapv (fn [event] (t/triple-t2 (event-proposition event))) (subject-events left))))
  (and (string? element) (str/starts-with? element "_")) (let [predicate (pid-of (subs element 1))]
  (if (nil? predicate) acc (let [subjects (mapv (fn [event] (t/triple-t1 (event-proposition event))) (rev-events predicate left))]
  (assoc acc element (mapv (fn [subject] (node subject (nm-of subject) [] (inc depth) visited)) subjects)))))
  (string? element) (let [predicate (pid-of element)]
  (if (nil? predicate) acc (let [value (values element predicate left)]
  (if (nil? value) acc (assoc acc element value)))))
  (map? element) (reduce (fn [result ^String key] (let [subpattern (get element key)]
  (if (str/starts-with? key "_") (let [predicate (pid-of (subs key 1))]
  (if (nil? predicate) result (let [subjects (mapv (fn [event] (t/triple-t1 (event-proposition event))) (rev-events predicate left))]
  (assoc result key (mapv (fn [subject] (recur-target subject (subpat->pattern key subpattern) depth visited)) subjects))))) (let [predicate (pid-of key)]
  (if (nil? predicate) result (let [rendered (mapv (fn [event] (let [right (t/triple-t3 (event-proposition event))
   target-name (s/name-of schema right)]
  (if (nil? target-name) right (recur-target right (subpat->pattern key subpattern) depth visited)))) (fwd-events left predicate))]
  (if (seq rendered) (assoc result key (if (= "single" (s/cardinality schema key)) (first rendered) rendered)) result))))))) acc (keys element))
  :else acc))
          (node [subject name requested depth visited] (cond
  (contains? visited subject) {:store/id name :store/cycle true}
  (>= (deref state) max-nodes) {:store/id name :store/truncated true}
  :else (do
  (swap! state (fn [count] (inc count)))
  (reduce (fn [acc element] (elem acc subject depth (conj visited subject) element)) {:store/id name} requested))))]
  (let [one (fn [name] (let [subject (s/resolve-name schema name)]
  (if (nil? subject) {:store/id name} (node subject name pattern 0 #{}))))]
  (if (vector? root) (mapv (fn [name] (one name)) root) (one root))))))))
