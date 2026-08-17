(ns fram.import
  (:require [fram.types :as t]
            [fram.store :as store]
            [fram.fold :as fold]
            [clojure.string :as str]
            [fram.rt :as rt]))

(defrecord Doc [head body])

(defn doc-head [r] (:head r))

(defn doc-body [r] (:body r))

(defrecord PredicateRegistry [by-name canonical])

(defn predicateregistry-by-name [r] (:by-name r))

(defn predicateregistry-canonical [r] (:canonical r))

(def ref-predicates ["depends_on" "part_of" "relates_to" "clarifies" "amends"])

(defn- ^String string-term [value]
  (if (string? value) value (throw (ex-info "thread projection requires string Triple terms" {:type :invalid-thread-triple}))))

(defn- ^String triple-left [value]
  (string-term (t/triple-t1 value)))

(defn- ^String triple-predicate [value]
  (string-term (t/triple-t2 value)))

(defn- ^String triple-right [value]
  (string-term (t/triple-t3 value)))

(defn- ^Doc split-doc [^String content]
  (let [lines (fram.rt/split-on content "\n")
   n (count lines)]
  (loop [i 0]
  (cond
  (>= i n) (->Doc content "")
  (= "---" (str/trim (nth lines i))) (->Doc (str/join "\n" (subvec (vec lines) 0 i)) (str/join "\n" (subvec (vec lines) (+ i 1) n)))
  :else (recur (+ i 1))))))

(defn- ^String parse-obj [^String token]
  (cond
  (str/starts-with? token "@") token
  (str/starts-with? token "\"") (fram.rt/edn-unquote token)
  :else token))

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

(defn- normalize-predicate-triples [triples]
  (let [registry (predicate-registry triples)
   normalized (mapv (fn [value] (let [predicate (predicate-name registry (triple-predicate value))
   right (triple-right value)
   normalized-right (if (and (= "ref" (value-kind-of registry triples predicate)) (not (str/starts-with? right "@"))) (str "@" right) right)]
  (t/triple (triple-left value) predicate normalized-right))) triples)]
  (vec (concat (filterv identity-triple? normalized) (filterv (fn [value] (not (identity-triple? value))) normalized)))))

(defn- warn [^String message]
  (binding [*out* *err*]
  (println (str "WARN import: " message))))

(defn- file->triples [^String path ^String content]
  (let [doc (split-doc content)
   lines (fram.rt/split-on (doc-head doc) "\n")
   n (count lines)
   subject-index (loop [i 0]
  (cond
  (>= i n) -1
  (str/starts-with? (str/trim (nth lines i)) "@") i
  :else (recur (+ i 1))))]
  (if (< subject-index 0) (do
  (if (str/blank? (doc-head doc)) nil (warn (str path " — no @subject line found in head; dropping " n " head line(s)")))
  []) (let [subject (str/trim (nth lines subject-index))
   triples (loop [i (+ subject-index 1)
   acc []]
  (if (>= i n) acc (let [line (str/trim (nth lines i))]
  (if (str/blank? line) (recur (+ i 1) acc) (let [pair (fram.rt/split-kv line)]
  (recur (+ i 1) (conj acc (t/triple subject (nth pair 0) (parse-obj (nth pair 1))))))))))
   body (doc-body doc)]
  (if (str/blank? body) triples (conj triples (t/triple subject "body" body)))))))

(defn- safe-file->triples [^String path]
  (try
  (file->triples path (fram.rt/slurp path))
  (catch Exception error
    (warn (str path " — skipped (could not parse): " (.getMessage error)))
    [])))

(defn- number-frames [triples]
  (loop [position 0
   frames []]
  (if (>= position (count triples)) frames (recur (+ position 1) (conj frames (fold/transaction-frame (+ position 1) [(store/assert-operation (nth triples position))]))))))

(defn load-corpus [^String threads-dir]
  (let [files (fram.rt/list-md threads-dir)
   triples (reduce (fn [acc ^String path] (vec (concat acc (safe-file->triples path)))) [] files)]
  (number-frames (normalize-predicate-triples triples))))
