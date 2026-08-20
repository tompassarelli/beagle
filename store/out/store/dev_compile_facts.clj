(ns store.dev-compile-facts
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

(def ^String space-id "beagle-dev-compile-facts-v1")

(def ^String subject-tag "store.dev-compile-facts/result-v1")

(def ^String fact-kind "DevCompileUnitResultV1")

(defrecord CompileFact [stage result-key id encoding])

(defn compilefact-stage [r] (:stage r))

(defn compilefact-result-key [r] (:result-key r))

(defn compilefact-id [r] (:id r))

(defn compilefact-encoding [r] (:encoding r))

(defrecord AppendCounts [appended retained])

(defn appendcounts-appended [r] (:appended r))

(defn appendcounts-retained [r] (:retained r))

(defn- fail [^String message code]
  (throw (ex-info message {:type code :store/code code})))

(defn- ^Boolean nonempty-string? [value]
  (and (string? value) (pos? (count value))))

(defn- ^Boolean exact-sha256? [value]
  (and (string? value) (some? (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- ^Boolean allowed-stage? [value]
  (or (= "typed" value) (= "native" value)))

(defn- ^String sha256-id [^String text]
  (str "sha256:" (apply str (mapv (fn [value] (format "%02x" (bit-and (int value) 255))) (vec (.digest (MessageDigest/getInstance "SHA-256") (.getBytes text StandardCharsets/UTF_8)))))))

(defn- payload-byte-count [^String payload]
  (count (vec (.getBytes payload StandardCharsets/UTF_8))))

(defn- ^String absolute-store-path [value]
  (if (and (string? value) (some? (re-matches #"/.*" value))) value (fail "development fact Store path must be absolute" :dev-compile-facts/relative-route)))

(defn ^CompileFact compile-fact [^String id ^String encoding]
  (let [envelope (store.rt/parse-edn encoding)]
  (if (and (vector? envelope) (= 9 (count envelope))) (let [kind (nth envelope 0)
   stage (nth envelope 1)
   result-key (nth envelope 2)
   compiler-context (nth envelope 3)
   profile (nth envelope 4)
   unit-id (nth envelope 5)
   byte-count (nth envelope 6)
   digest (nth envelope 7)
   payload (nth envelope 8)]
  (cond
  (not= fact-kind kind) (fail "compile fact envelope has an unknown kind" :dev-compile-facts/unknown-kind)
  (not= encoding (pr-str envelope)) (fail "compile fact envelope must be canonical EDN" :dev-compile-facts/noncanonical-envelope)
  (not (allowed-stage? stage)) (fail "compile fact stage must be typed or native" :dev-compile-facts/invalid-stage)
  (not (and (exact-sha256? id) (exact-sha256? result-key) (exact-sha256? compiler-context) (nonempty-string? profile) (nonempty-string? unit-id) (integer? byte-count) (<= 0 byte-count) (exact-sha256? digest) (string? payload))) (fail "compile fact envelope metadata is malformed" :dev-compile-facts/invalid-envelope)
  (not= id (sha256-id encoding)) (fail "compile fact id does not match its canonical envelope" :dev-compile-facts/fact-id-mismatch)
  (or (not= byte-count (payload-byte-count payload)) (not= digest (sha256-id payload))) (fail "compile fact payload bytes do not match its digest" :dev-compile-facts/payload-mismatch)
  :else (->CompileFact stage result-key id encoding))) (fail "compile fact envelope must have nine vector fields" :dev-compile-facts/invalid-envelope))))

(defn- fact-subject [^String stage ^String result-key]
  (store.types/triple subject-tag stage result-key))

(defn- fact-proposition [^CompileFact entry]
  (store.types/triple (fact-subject (compilefact-stage entry) (compilefact-result-key entry)) fact-kind (compilefact-encoding entry)))

(defn- proposition-entry [proposition]
  (if (store.types/triple? proposition) (let [subject (store.types/triple-t1 proposition)
   kind (store.types/triple-t2 proposition)
   encoding (store.types/triple-t3 proposition)]
  (if (and (store.types/triple? subject) (= subject-tag (store.types/triple-t1 subject)) (allowed-stage? (store.types/triple-t2 subject)) (exact-sha256? (store.types/triple-t3 subject)) (= fact-kind kind) (string? encoding)) (->CompileFact (store.types/triple-t2 subject) (store.types/triple-t3 subject) (sha256-id encoding) encoding) nil)) nil))

(defn- all-facts [database]
  (reduce (fn [entries proposition] (let [entry (proposition-entry proposition)]
  (if (some? entry) (conj entries entry) entries))) [] (database/live-propositions database)))

(defn- facts-for-key [entries ^String stage ^String result-key]
  (filterv (fn [^CompileFact entry] (and (= stage (compilefact-stage entry)) (= result-key (compilefact-result-key entry)))) entries))

(defn- ^Boolean same-entry? [^CompileFact left ^CompileFact right]
  (and (= (compilefact-stage left) (compilefact-stage right)) (= (compilefact-result-key left) (compilefact-result-key right)) (= (compilefact-id left) (compilefact-id right)) (= (compilefact-encoding left) (compilefact-encoding right))))

(defn- create-or-open! [^String path]
  (let [file (File. path)
   parent (.getParentFile file)]
  (if (and (some? parent) (not (.isDirectory parent))) (.mkdirs parent) nil)
  (if (.exists file) nil (database/create-triple-log! path space-id))
  (database/open-database! path space-id)))

(defn- ^String revision-identity [^String path]
  (let [revision (database/branch-revision! path)
   identity (:identity revision)]
  (if (string? identity) identity (fail "Store returned no branch revision identity" :dev-compile-facts/revision-unresolved))))

(defn- append-propositions! [database propositions]
  (if (empty? propositions) nil (do
  (database/commit! database {:actor "store.dev-compile-facts/v1" :commit-metadata {:producer "store.dev-compile-facts/v1" :shape-schema-id "store/CommitOperationV1" :profile "dev-compile-facts-v1" :validation-attestation {:validator "store/canonical-validator-v1" :result :pending :attestation "store/canonical-validator-v1"}} :operations (mapv (fn [proposition] {:action :assert :proposition proposition}) propositions)})
  nil)))

(defn- ^AppendCounts append-entries! [database entries]
  (let [known (all-facts database)
   pending (reduce (fn [accepted ^CompileFact entry] (let [candidates (facts-for-key (vec (concat known accepted)) (compilefact-stage entry) (compilefact-result-key entry))]
  (cond
  (empty? candidates) (conj accepted entry)
  (every? (fn [^CompileFact candidate] (same-entry? candidate entry)) candidates) accepted
  :else (fail (str "compile fact result key has conflicting content: " (compilefact-result-key entry)) :dev-compile-facts/conflicting-fact)))) [] entries)]
  (append-propositions! database (mapv fact-proposition pending))
  (->AppendCounts (count pending) (- (count entries) (count pending)))))

(defn append! [^String path entries]
  (let [authority (writer-authority/acquire! path)]
  (try
  (let [database (create-or-open! path)
   counts (append-entries! database entries)]
  ["store.dev-compile-facts/append-response-v1" "ok" (revision-identity path) (appendcounts-appended counts) (appendcounts-retained counts)])
  (finally
    (writer-authority/release! authority)))))

(defn- request-row [value]
  (if (and (vector? value) (= 5 (count value)) (allowed-stage? (nth value 0)) (exact-sha256? (nth value 1)) (exact-sha256? (nth value 2)) (nonempty-string? (nth value 3)) (nonempty-string? (nth value 4))) [(nth value 0) (nth value 1) (nth value 2) (nth value 3) (nth value 4)] (fail "query row must be [stage key context profile unit-id]" :dev-compile-facts/invalid-query)))

(defn- query-rows [facts requests]
  (reduce (fn [rows request] (let [stage (nth request 0)
   result-key (nth request 1)
   matches (facts-for-key facts stage result-key)]
  (vec (concat rows (mapv (fn [^CompileFact entry] [stage result-key (compilefact-id entry) (compilefact-encoding entry)]) matches))))) [] requests))

(defn query! [^String path requests]
  (let [file (File. path)]
  (if (.isFile file) (let [database (database/open-database! path space-id)
   facts (all-facts database)]
  ["store.dev-compile-facts/query-response-v1" "ONLINE" (revision-identity path) requests (query-rows facts requests)]) ["store.dev-compile-facts/query-response-v1" "COLD" "" requests []])))

(defn- request-vector [^String expected-tag]
  (let [line (read-line)
   value (if (string? line) (store.rt/parse-edn line) nil)]
  (if (and (vector? value) (= 3 (count value)) (= expected-tag (nth value 0))) value (fail (str "request must be " expected-tag " with three fields") :dev-compile-facts/invalid-request))))

(defn- query-requests-from [value]
  (if (vector? value) (mapv request-row value) (fail "query requests must be a vector" :dev-compile-facts/invalid-query)))

(defn- ^CompileFact entry-from-value [value]
  (if (and (vector? value) (= 2 (count value)) (string? (nth value 0)) (string? (nth value 1))) (compile-fact (nth value 0) (nth value 1)) (fail "append entry must be [id canonical-envelope-edn]" :dev-compile-facts/invalid-entry)))

(defn- entries-from-value [value]
  (if (vector? value) (mapv entry-from-value value) (fail "append entries must be a vector" :dev-compile-facts/invalid-entry)))

(defn dispatch! [^String command]
  (cond
  (= command "query") (let [request (request-vector "store.dev-compile-facts/query-v1")]
  (query! (absolute-store-path (nth request 1)) (query-requests-from (nth request 2))))
  (= command "append") (let [request (request-vector "store.dev-compile-facts/append-v1")]
  (append! (absolute-store-path (nth request 1)) (entries-from-value (nth request 2))))
  :else (fail (str "unknown development compile fact command: " command) :dev-compile-facts/unknown-command)))

(defn- ^String error-code [error]
  (let [data (ex-data error)
   code (or (:store/code data) (:type data))]
  (if (keyword? code) (subs (str code) 1) "unclassified")))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (try
  (if (= 1 (count args)) (println (pr-str (dispatch! (first args)))) (fail "development compile facts expects one command argument" :dev-compile-facts/invalid-command-line))
  (catch Exception error
    (println (pr-str ["store.dev-compile-facts/error-v1" (error-code error) (.getMessage error)]))
    (System/exit 2)))))
