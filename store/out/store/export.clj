(ns store.export
  (:require [store.types :as t]
            [clojure.string :as str]
            [store.rt :as rt]))

(defrecord PredicateRegistry [by-name canonical])

(defn predicateregistry-by-name [r] (:by-name r))

(defn predicateregistry-canonical [r] (:canonical r))

(def order ["title" "owner" "lead" "driver" "source" "proposed_by" "created_by" "created_at" "updated_at" "committed" "do_on" "valid_until" "estimate_hours" "repo" "part_of" "depends_on" "relates_to" "clarifies" "amends" "outcome" "abandoned"])

(def ref-predicates ["depends_on" "part_of" "relates_to" "clarifies" "amends"])

(defn- ^String string-term [value]
  (if (string? value) value (throw (ex-info "thread projection requires string Triple terms" {:type :invalid-thread-triple}))))

(defn- ^String triple-left [value]
  (string-term (t/triple-t1 value)))

(defn- ^String triple-predicate [value]
  (string-term (t/triple-t2 value)))

(defn- ^String triple-right [value]
  (string-term (t/triple-t3 value)))

(defn- ^Boolean vec-contains? [values ^String wanted]
  (loop [remaining values]
  (if (empty? remaining) false (if (= (first remaining) wanted) true (recur (rest remaining))))))

(defn- distinct-strings [values]
  (reduce (fn [distinct ^String value] (if (vec-contains? distinct value) distinct (conj distinct value))) [] values))

(defn- ^Boolean identity-predicate? [^String predicate]
  (or (= predicate "predicate_name") (= predicate "predicate_alias")))

(defn- ^Boolean identity-triple? [value]
  (identity-predicate? (triple-predicate value)))

(defn- bind-predicate-spelling [spellings ^String spelling ^String identity]
  (let [prior (get spellings spelling)]
  (if (and (some? prior) (not (= prior identity))) (throw (ex-info (str "predicate spelling collision: " spelling " resolves to both " prior " and " identity) {:predicate spelling :left prior :right identity})) (assoc spellings spelling identity))))

(defn- ^PredicateRegistry predicate-registry [triples]
  (let [registry-triples (filterv identity-triple? triples)
   canonical (reduce (fn [names value] (if (= "predicate_name" (triple-predicate value)) (assoc names (triple-left value) (triple-right value)) names)) {} registry-triples)
   by-name (reduce (fn [spellings value] (bind-predicate-spelling spellings (triple-right value) (triple-left value))) {} registry-triples)]
  (->PredicateRegistry by-name canonical)))

(defn- ^String strip-at [^String spelling]
  (if (str/starts-with? spelling "@") (subs spelling 1) spelling))

(defn- ^String predicate-id [^PredicateRegistry registry ^String spelling]
  (if (str/starts-with? spelling "@") spelling (let [identity (get (predicateregistry-by-name registry) spelling)]
  (if (some? identity) identity (str "@" spelling)))))

(defn- ^String predicate-name [^PredicateRegistry registry ^String spelling]
  (let [identity (predicate-id registry spelling)
   canonical (get (predicateregistry-canonical registry) identity)]
  (if (some? canonical) canonical (strip-at identity))))

(defn- predicate-property-value [^PredicateRegistry registry triples ^String predicate ^String property]
  (let [identity (predicate-id registry predicate)
   property-id (predicate-id registry property)]
  (reduce (fn [found value] (if (and (= identity (predicate-id registry (triple-left value))) (= property-id (predicate-id registry (triple-predicate value)))) (triple-right value) found)) nil triples)))

(defn- ^Boolean fallback-ref? [^PredicateRegistry registry ^String predicate]
  (let [identity (predicate-id registry predicate)]
  (loop [remaining ref-predicates]
  (if (empty? remaining) false (if (= identity (predicate-id registry (first remaining))) true (recur (rest remaining)))))))

(defn- ^String value-kind-of [^PredicateRegistry registry triples ^String predicate]
  (let [explicit (predicate-property-value registry triples predicate "value_kind")]
  (if (some? explicit) explicit (if (fallback-ref? registry predicate) "ref" "literal"))))

(defn- subject-triples [triples ^String subject]
  (filterv (fn [value] (= subject (triple-left value))) triples))

(defn- ^String render-object [^PredicateRegistry registry triples ^String predicate ^String value]
  (if (= "ref" (value-kind-of registry triples predicate)) (if (str/starts-with? value "@") value (str "@" value)) (if (or (str/blank? value) (str/includes? value " ") (str/includes? value "\t") (str/includes? value "\n") (str/includes? value "\r") (str/starts-with? value "@") (str/starts-with? value "\"")) (store.rt/edn-quote value) value)))

(defn ^String subject-md [triples ^String subject]
  (let [registry (predicate-registry triples)
   selected (subject-triples triples subject)
   present (distinct-strings (mapv (fn [value] (predicate-name registry (triple-predicate value))) selected))
   ordered (filterv (fn [^String predicate] (vec-contains? present predicate)) order)
   extra (vec (sort (filterv (fn [^String predicate] (and (not (vec-contains? order predicate)) (not (= predicate "body")))) present)))
   predicates (vec (concat ordered extra))
   lines (reduce (fn [acc ^String predicate] (let [identity (predicate-id registry predicate)
   values (mapv (fn [value] (triple-right value)) (filterv (fn [value] (= identity (predicate-id registry (triple-predicate value)))) selected))]
  (vec (concat acc (mapv (fn [^String value] (str predicate "  " (render-object registry triples predicate value))) values))))) [] predicates)
   body-id (predicate-id registry "body")
   bodies (filterv (fn [value] (= body-id (predicate-id registry (triple-predicate value)))) selected)
   maybe-body (if (empty? bodies) nil (triple-right (first bodies)))
   body (if (some? maybe-body) maybe-body "")]
  (str subject "\n" (str/join "\n" lines) "\n---\n" body)))
