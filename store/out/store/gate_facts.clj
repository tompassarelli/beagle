(ns store.gate-facts
  (:gen-class)
  (:import [java.io File]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

(clojure.core/require 'store.rt)

(let [raw-emitted-file (File. (str *file*))
   emitted-file (.getCanonicalFile raw-emitted-file)
   emitted-namespace-directory (.getParentFile emitted-file)
   out-directory (.getParentFile emitted-namespace-directory)
   store-directory (.getParentFile out-directory)]
  (clojure.core/load-file (str (.getPath store-directory) "/database.clj")))

(def ^String protocol-prefix "store.gate-facts")

(def ^String space-prefix "beagle-gate-facts-experimental-v1:")

(def ^String subject-tag "store.gate-facts/subject-v1")

(def ^String fallback-link-kind "store.gate-facts/fallback-link-v1")

(def allowed-kinds #{"GateCandidateV1" "GatePhaseClaimV1" "GatePhaseObservationV1" "GateCandidateVerdictV1" "FactMissEventV1" "GateMaintenanceReceiptV1"})

(defrecord FactRoute [path base-commit candidate-root space-id])

(defn factroute-path [r] (:path r))

(defn factroute-base-commit [r] (:base-commit r))

(defn factroute-candidate-root [r] (:candidate-root r))

(defn factroute-space-id [r] (:space-id r))

(defrecord FactEntry [id kind envelope])

(defn factentry-id [r] (:id r))

(defn factentry-kind [r] (:kind r))

(defn factentry-envelope [r] (:envelope r))

(defrecord FallbackLink [miss-id observation-id])

(defn fallbacklink-miss-id [r] (:miss-id r))

(defn fallbacklink-observation-id [r] (:observation-id r))

(defrecord AppendCounts [appended retained])

(defn appendcounts-appended [r] (:appended r))

(defn appendcounts-retained [r] (:retained r))

(defn- fail [^String message code]
  (throw (ex-info message {:type code :store/code code})))

(defn- ^Boolean nonempty-string? [value]
  (and (string? value) (pos? (count value))))

(defn- ^Boolean exact-base-commit? [value]
  (and (string? value) (some? (re-matches #"[0-9a-f]{40}" value))))

(defn- ^String sha256-id [^String text]
  (str "sha256:" (apply str (mapv (fn [value] (format "%02x" (bit-and (int value) 255))) (vec (.digest (MessageDigest/getInstance "SHA-256") (.getBytes text StandardCharsets/UTF_8)))))))

(defn ^FactRoute route [^String path ^String base-commit ^String candidate-root]
  (cond
  (nil? (re-matches #"/.*" path)) (fail "gate fact Store path must be absolute" :gate-facts/relative-route)
  (not (exact-base-commit? base-commit)) (fail "gate fact base commit must be one full lowercase Git object id" :gate-facts/invalid-base-commit)
  (not (nonempty-string? candidate-root)) (fail "gate fact candidate root must be nonempty" :gate-facts/invalid-candidate-root)
  (or (= candidate-root "main") (= candidate-root "refs/heads/main")) (fail "gate fact candidate root must be immutable, not a published route" :gate-facts/published-route-refused)
  :else (->FactRoute path base-commit candidate-root (str space-prefix base-commit))))

(defn ^FactEntry fact-entry [^String id ^String kind ^String envelope]
  (let [payload (store.rt/parse-edn envelope)]
  (cond
  (not (nonempty-string? id)) (fail "gate fact id must be nonempty" :gate-facts/invalid-fact-id)
  (not (contains? allowed-kinds kind)) (fail (str "gate fact kind is unknown: " kind) :gate-facts/unknown-kind)
  (not (and (vector? payload) (pos? (count payload)) (= kind (first payload)) (= envelope (pr-str payload)))) (fail "gate fact envelope must be an EDN vector headed by its V1 kind" :gate-facts/invalid-envelope)
  (not= id (sha256-id envelope)) (fail "gate fact id does not match the canonical envelope bytes" :gate-facts/fact-id-mismatch)
  :else (->FactEntry id kind envelope))))

(defn- fact-subject [^String candidate-root ^String fact-id]
  (store.types/triple subject-tag candidate-root fact-id))

(defn- fact-proposition [^String candidate-root ^FactEntry entry]
  (store.types/triple (fact-subject candidate-root (factentry-id entry)) (factentry-kind entry) (factentry-envelope entry)))

(defn- fallback-proposition [^String candidate-root ^FallbackLink link]
  (store.types/triple (fact-subject candidate-root (fallbacklink-miss-id link)) fallback-link-kind (fallbacklink-observation-id link)))

(defn- ^Boolean candidate-subject? [value ^String candidate-root]
  (and (store.types/triple? value) (= subject-tag (store.types/triple-t1 value)) (= candidate-root (store.types/triple-t2 value)) (string? (store.types/triple-t3 value))))

(defn- proposition-entry [proposition ^String candidate-root]
  (let [subject (store.types/triple-t1 proposition)
   kind (store.types/triple-t2 proposition)
   envelope (store.types/triple-t3 proposition)]
  (if (and (candidate-subject? subject candidate-root) (string? kind) (contains? allowed-kinds kind) (string? envelope)) (->FactEntry (store.types/triple-t3 subject) kind envelope) nil)))

(defn- proposition-link [proposition ^String candidate-root]
  (let [subject (store.types/triple-t1 proposition)
   kind (store.types/triple-t2 proposition)
   observation-id (store.types/triple-t3 proposition)]
  (if (and (candidate-subject? subject candidate-root) (= fallback-link-kind kind) (string? observation-id)) (->FallbackLink (store.types/triple-t3 subject) observation-id) nil)))

(defn- facts-for [database ^FactRoute selected]
  (reduce (fn [entries proposition] (let [entry (proposition-entry proposition (factroute-candidate-root selected))]
  (if (some? entry) (conj entries entry) entries))) [] (database/live-propositions! database)))

(defn- links-for [database ^FactRoute selected]
  (reduce (fn [links proposition] (let [link (proposition-link proposition (factroute-candidate-root selected))]
  (if (some? link) (conj links link) links))) [] (database/live-propositions! database)))

(defn- entry-with-id [entries ^String fact-id]
  (reduce (fn [found ^FactEntry entry] (if (= fact-id (factentry-id entry)) entry found)) nil entries))

(defn- ^Boolean same-entry? [^FactEntry left ^FactEntry right]
  (and (= (factentry-id left) (factentry-id right)) (= (factentry-kind left) (factentry-kind right)) (= (factentry-envelope left) (factentry-envelope right))))

(defn- link-with-miss-id [links ^String miss-id]
  (reduce (fn [found ^FallbackLink link] (if (= miss-id (fallbacklink-miss-id link)) link found)) nil links))

(defn- ^FallbackLink required-link [link]
  (if (some? link) link (fail "fallback link is absent" :gate-facts/fallback-link-absent)))

(defn- create-or-open! [^FactRoute selected]
  (let [path (factroute-path selected)
   file (File. path)]
  (if (.exists file) nil (database/create-triple-log! path (factroute-space-id selected)))
  (database/open-database! path (factroute-space-id selected))))

(defn- with-writer! [^FactRoute selected operation]
  (let [authority (writer-authority/acquire! (factroute-path selected))]
  (try
  (operation (create-or-open! selected))
  (finally
    (writer-authority/release! authority)))))

(defn- cold-open! [^FactRoute selected]
  (let [path (factroute-path selected)
   file (File. path)]
  (if (.isFile file) (database/open-database! path (factroute-space-id selected)) (fail "gate fact Store route is unopened" :gate-facts/route-unresolved))))

(defn- append-propositions! [database propositions]
  (if (empty? propositions) nil (do
  (database/commit! database {:actor "store.gate-facts/v1" :commit-metadata {:producer "store.gate-facts/v1" :shape-schema-id "store/CommitOperationV1" :profile "gate-facts-v1" :validation-attestation {:validator "store/canonical-validator-v1" :result :pending :attestation "store/canonical-validator-v1"}} :operations (mapv (fn [proposition] {:action :assert :proposition proposition}) propositions)})
  nil)))

(defn- ^AppendCounts append-entries! [database ^FactRoute selected entries]
  (let [known (facts-for database selected)
   new-entries (reduce (fn [pending ^FactEntry entry] (let [prior (entry-with-id (vec (concat known pending)) (factentry-id entry))]
  (cond
  (nil? prior) (conj pending entry)
  (same-entry? prior entry) pending
  :else (fail (str "gate fact id has conflicting immutable content: " (factentry-id entry)) :gate-facts/conflicting-fact)))) [] entries)]
  (append-propositions! database (mapv (fn [^FactEntry entry] (fact-proposition (factroute-candidate-root selected) entry)) new-entries))
  (->AppendCounts (count new-entries) (- (count entries) (count new-entries)))))

(defn- ^String revision-identity! [^FactRoute selected]
  (let [revision (database/branch-revision! (factroute-path selected))
   identity (:identity revision)]
  (if (string? identity) identity (fail "Store returned no durable branch revision identity" :gate-facts/revision-unresolved))))

(defn- response-for! [database ^FactRoute selected]
  (let [entries (facts-for database selected)
   links (links-for database selected)
   receipts (filterv (fn [^FactEntry entry] (= "GateMaintenanceReceiptV1" (factentry-kind entry))) entries)]
  ["store.gate-facts/response-v1" "ok" (factroute-candidate-root selected) (revision-identity! selected) (mapv (fn [^FactEntry entry] [(factentry-id entry) (factentry-kind entry) (factentry-envelope entry)]) entries) (mapv (fn [^FallbackLink link] [(fallbacklink-miss-id link) (fallbacklink-observation-id link)]) links) (mapv factentry-id receipts)]))

(defn import-facts! [^FactRoute selected entries]
  (with-writer! selected (fn [database] (let [counts (append-entries! database selected entries)]
  (response-for! database selected)))))

(defn record-miss! [^FactRoute selected ^FactEntry entry]
  (if (not= "FactMissEventV1" (factentry-kind entry)) (fail "record-miss accepts only FactMissEventV1" :gate-facts/not-a-miss) (with-writer! selected (fn [database] (let [counts (append-entries! database selected [entry])]
  (response-for! database selected))))))

(defn record-observation! [^FactRoute selected ^FactEntry entry miss-id]
  (if (not= "GatePhaseObservationV1" (factentry-kind entry)) (fail "record-observation accepts only GatePhaseObservationV1" :gate-facts/not-an-observation) (with-writer! selected (fn [database] (let [known (facts-for database selected)
   known-links (links-for database selected)
   prior-entry (entry-with-id known (factentry-id entry))
   prior-miss (if (some? miss-id) (entry-with-id known miss-id) nil)
   prior-link (if (some? miss-id) (link-with-miss-id known-links miss-id) nil)
   link (if (some? miss-id) (->FallbackLink miss-id (factentry-id entry)) nil)]
  (if (and (some? prior-entry) (not (same-entry? prior-entry entry))) (fail "observation id has conflicting immutable content" :gate-facts/conflicting-fact) nil)
  (if (and (some? miss-id) (or (nil? prior-miss) (not= "FactMissEventV1" (factentry-kind prior-miss)))) (fail "fallback observation has no prior durable FactMissEventV1" :gate-facts/miss-not-durable) nil)
  (if (and (some? prior-link) (not= (factentry-id entry) (fallbacklink-observation-id prior-link))) (fail "FactMissEventV1 already links to another fallback observation" :gate-facts/conflicting-fallback-link) nil)
  (cond
  (nil? miss-id) (let [counts (append-entries! database selected [entry])]
  nil)
  (and (nil? prior-entry) (nil? prior-link)) (append-propositions! database [(fact-proposition (factroute-candidate-root selected) entry) (fallback-proposition (factroute-candidate-root selected) (required-link link))])
  (and (some? prior-entry) (some? prior-link)) nil
  :else (fail "observation and fallback link are not one durable result" :gate-facts/partial-fallback-result))
  (response-for! database selected))))))

(defn- ^FallbackLink requested-link [value]
  (if (and (vector? value) (= 2 (count value)) (nonempty-string? (nth value 0)) (nonempty-string? (nth value 1))) (->FallbackLink (nth value 0) (nth value 1)) (fail "finalize miss link must be [miss-id observation-id]" :gate-facts/invalid-fallback-link)))

(defn- ^Boolean exact-link-present? [links ^FallbackLink wanted]
  (some? (some (fn [^FallbackLink link] (and (= (fallbacklink-miss-id wanted) (fallbacklink-miss-id link)) (= (fallbacklink-observation-id wanted) (fallbacklink-observation-id link)))) links)))

(defn finalize! [^FactRoute selected ^FactEntry verdict ^FactEntry receipt requested-links]
  (if (not= "GateCandidateVerdictV1" (factentry-kind verdict)) (fail "finalize verdict must be GateCandidateVerdictV1" :gate-facts/not-a-verdict) nil)
  (if (not= "GateMaintenanceReceiptV1" (factentry-kind receipt)) (fail "finalize receipt must be GateMaintenanceReceiptV1" :gate-facts/not-a-receipt) nil)
  (with-writer! selected (fn [database] (let [known (facts-for database selected)
   durable-links (links-for database selected)
   candidate-present (some? (some (fn [^FactEntry entry] (= "GateCandidateV1" (factentry-kind entry))) known))
   misses (filterv (fn [^FactEntry entry] (= "FactMissEventV1" (factentry-kind entry))) known)]
  (if candidate-present nil (fail "finalize requires a durable exact candidate" :gate-facts/candidate-root-unresolved))
  (if (not= (count misses) (count requested-links)) (fail "maintenance receipt does not account for every durable miss" :gate-facts/unaccounted-miss) nil)
  (doseq [miss misses]
  (if (nil? (link-with-miss-id requested-links (factentry-id miss))) (fail "maintenance receipt omits a durable FactMissEventV1" :gate-facts/unaccounted-miss) nil))
  (doseq [link requested-links]
  (let [miss (entry-with-id known (fallbacklink-miss-id link))
   observation (entry-with-id known (fallbacklink-observation-id link))]
  (if (or (nil? miss) (not= "FactMissEventV1" (factentry-kind miss)) (nil? observation) (not= "GatePhaseObservationV1" (factentry-kind observation)) (not (exact-link-present? durable-links link))) (fail "maintenance receipt names an unproved miss fallback link" :gate-facts/unproved-fallback-link) nil)))
  (let [counts (append-entries! database selected [verdict receipt])]
  (response-for! database selected))))))

(defn cold-query! [^FactRoute selected expected-ids]
  (let [database (cold-open! selected)
   entries (facts-for database selected)
   candidate-present (some? (some (fn [^FactEntry entry] (= "GateCandidateV1" (factentry-kind entry))) entries))]
  (if candidate-present (response-for! database selected) (fail "exact candidate root was not admitted in the opened Store" :gate-facts/candidate-root-unresolved))))

(defn- request-vector [^String expected-tag expected-count]
  (let [line (read-line)
   value (if (string? line) (store.rt/parse-edn line) nil)]
  (if (and (vector? value) (= expected-count (count value)) (= expected-tag (nth value 0))) value (fail (str "request must be " expected-tag " with " expected-count " vector fields") :gate-facts/invalid-request))))

(defn- ^FactRoute route-from-request [request]
  (if (and (string? (nth request 1)) (string? (nth request 2)) (string? (nth request 3))) (route (nth request 1) (nth request 2) (nth request 3)) (fail "request route fields must be strings" :gate-facts/invalid-request)))

(defn- ^FactEntry entry-from-value [value]
  (if (and (vector? value) (= 3 (count value)) (string? (nth value 0)) (string? (nth value 1)) (string? (nth value 2))) (fact-entry (nth value 0) (nth value 1) (nth value 2)) (fail "fact entry must be [id kind canonical-envelope-edn]" :gate-facts/invalid-entry)))

(defn- entries-from-value [value]
  (if (vector? value) (mapv entry-from-value value) (fail "fact entries must be a vector" :gate-facts/invalid-entry)))

(defn- strings-from-value [value]
  (if (and (vector? value) (every? string? value)) value (fail "expected fact ids must be a vector of strings" :gate-facts/invalid-request)))

(defn dispatch! [^String command]
  (cond
  (= command "import") (let [request (request-vector "store.gate-facts/import-v1" 5)]
  (import-facts! (route-from-request request) (entries-from-value (nth request 4))))
  (= command "record-miss") (let [request (request-vector "store.gate-facts/record-miss-v1" 5)]
  (record-miss! (route-from-request request) (entry-from-value (nth request 4))))
  (= command "record-observation") (let [request (request-vector "store.gate-facts/record-observation-v1" 6)
   miss-id (nth request 5)]
  (if (or (nil? miss-id) (string? miss-id)) (record-observation! (route-from-request request) (entry-from-value (nth request 4)) miss-id) (fail "record-observation miss id must be a string or nil" :gate-facts/invalid-request)))
  (= command "finalize") (let [request (request-vector "store.gate-facts/finalize-v1" 7)
   links (nth request 6)]
  (if (vector? links) (finalize! (route-from-request request) (entry-from-value (nth request 4)) (entry-from-value (nth request 5)) (mapv requested-link links)) (fail "finalize links must be a vector" :gate-facts/invalid-request)))
  (= command "cold-query") (let [request (request-vector "store.gate-facts/cold-query-v1" 5)]
  (cold-query! (route-from-request request) (strings-from-value (nth request 4))))
  :else (fail (str "unknown gate fact command: " command) :gate-facts/unknown-command)))

(defn- ^String error-code [error]
  (let [data (ex-data error)
   code (or (:store/code data) (:type data))]
  (if (keyword? code) (subs (str code) 1) "unclassified")))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (try
  (if (= 1 (count args)) (println (pr-str (dispatch! (first args)))) (fail "gate facts expects exactly one command argument" :gate-facts/invalid-command-line))
  (catch Exception error
    (println (pr-str ["store.gate-facts/error-v1" (error-code error) (.getMessage error)]))
    (System/exit 2)))))
