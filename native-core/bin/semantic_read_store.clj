(ns semantic-read-store
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [source-fact-store :as blobs]
            [store.dev-compile-facts :as compile-facts])
  (:import [java.nio.charset StandardCharsets]
           [java.nio.file Files]
           [java.security MessageDigest]))

;; The development-fact Store owns this envelope kind and stage. The semantic
;; cache's identity is the admitted query closure below, not an opaque tag.
(def fact-kind "DevCompileUnitResultV1")
(def fact-stage "typed")
(def blob-kind "beagle.source-facts/blob-v1")

(defrecord CompileQueryFact [order relation subject slot value])
(defrecord QueryAdmissionRequest
  [source-facts compiler-projection-content-id rules-content-id entries
   strict-entry-abi?])
(defrecord AdmittedQueryClosure
  [query-digest source-facts-content-id compiler-projection-content-id
   rules-content-id entries strict-entry-abi? facts])
(defrecord QueryAdmitted [closure])
(defrecord QueryRejected [code detail])

(defrecord ResultAdmissionRequest [query payload])
(defrecord AdmittedResultClosure
  [query payload payload-byte-count payload-content-id])
(defrecord ResultAdmitted [closure])
(defrecord ResultMissing [])
(defrecord ResultRejected [code detail])

(declare query-rejected? result-rejected?)

(defn sha256-bytes [^bytes value]
  (str "sha256:"
       (apply str
              (map #(format "%02x" (bit-and (int %) 255))
                   (.digest (MessageDigest/getInstance "SHA-256")
                            value)))))

(defn sha256 [^String value]
  (sha256-bytes (.getBytes value StandardCharsets/UTF_8)))

(defn sha256-source-rows [rows]
  (let [digest (MessageDigest/getInstance "SHA-256")]
    (doseq [row rows]
      (doseq [position (range 4)]
        (.update digest (.getBytes ^String (nth row position)
                                   StandardCharsets/UTF_8))
        (.update digest (.getBytes ^String (if (= position 3) "\n" "\t")
                                   StandardCharsets/UTF_8))))
    (str "sha256:"
         (apply str
                (map #(format "%02x" (bit-and (int %) 255))
                     (.digest digest))))))

(defn- exact-digest? [value]
  (and (string? value)
       (boolean (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- nonempty-string? [value]
  (and (string? value) (not (str/blank? value))))

(defn- query-part [value]
  (let [text (str value)]
    (str (count text) ":" text)))

(defn- query-fact-encoding [fact]
  (str (query-part (:order fact))
       (query-part (:relation fact))
       (query-part (:subject fact))
       (query-part (:slot fact))
       (query-part (:value fact))))

(defn- query-digest [facts]
  (sha256 (apply str (map query-fact-encoding facts))))

(defn- source-rows [source-facts]
  (cond
    (string? source-facts)
    (try
      (loop [lines (remove str/blank? (str/split-lines source-facts)) rows []]
        (if-let [line (first lines)]
          (let [fields (str/split line #"\t" -1)]
            (if (= 4 (count fields))
              (recur (next lines) (conj rows fields))
              (->QueryRejected :query/malformed-source-facts
                               "source facts must have four tab-separated fields")))
          rows))
      (catch Exception error
        (->QueryRejected :query/malformed-source-facts (.getMessage error))))

    (and (vector? source-facts)
         (every? #(and (vector? %) (= 4 (count %)) (every? string? %))
                 source-facts))
    source-facts

    :else
    (->QueryRejected :query/invalid-source-facts
                     "source facts must be canonical text or four-field rows")))

(defn- one-text [by-subject subject predicate]
  (let [values (get-in by-subject [subject predicate] [])]
    (if (and (= 1 (count values)) (nonempty-string? (first values)))
      (first values)
      (->QueryRejected :query/ambiguous-module-identity
                       (str "module " subject " needs one " predicate)))))

(defn- module-identities [rows]
  (let [by-subject
        (reduce
         (fn [found [subject predicate kind object]]
           (if (= "t" kind)
             (update-in found [subject predicate] (fnil conj []) object)
             found))
         {}
         rows)
        roots
        (sort
         (for [[subject predicates] by-subject
               :when (= ["module-root"] (get predicates "form-kind"))]
           subject))]
    (loop [remaining roots identities [] paths #{}]
      (if-let [subject (first remaining)]
        (let [relative-path (one-text by-subject subject "relative-path")
              source-digest (one-text by-subject subject "source-sha256")
              projection-digest
              (one-text by-subject subject "checked-projection-sha256")
              interface-digest (one-text by-subject subject "interface-sha256")]
          (cond
            (query-rejected? relative-path) relative-path
            (query-rejected? source-digest) source-digest
            (query-rejected? projection-digest) projection-digest
            (query-rejected? interface-digest) interface-digest
            (not (every? exact-digest?
                         [source-digest projection-digest interface-digest]))
            (->QueryRejected :query/invalid-module-content-id
                             (str "module " relative-path
                                  " has an invalid content ID"))
            (contains? paths relative-path)
            (->QueryRejected :query/duplicate-module-path
                             (str "module path appears more than once: " relative-path))
            :else
            (recur (next remaining)
                   (conj identities {:relative-path relative-path
                                     :source-digest source-digest
                                     :projection-digest projection-digest
                                     :interface-digest interface-digest})
                   (conj paths relative-path))))
        identities))))

(defn- valid-entries? [entries]
  (and (vector? entries)
       (every? nonempty-string? entries)
       (= (count entries) (count (set entries)))))

(defn- canonical-query-facts
  [source-facts-content-id compiler-projection-content-id rules-content-id
   entries strict-entry-abi? modules]
  (let [base [(->CompileQueryFact 1 :query/source-facts "query" 0
                                  source-facts-content-id)
              (->CompileQueryFact 2 :query/compiler-projection "query" 0
                                  compiler-projection-content-id)
              (->CompileQueryFact 3 :query/rules "query" 0 rules-content-id)
              (->CompileQueryFact 4 :query/strict-entry-abi "query" 0
                                  (if strict-entry-abi? "true" "false"))]
        module-facts
        (mapcat
         (fn [position {:keys [relative-path source-digest projection-digest
                               interface-digest]}]
           (let [order (+ 5 (* position 4))]
             [(->CompileQueryFact order :query/module relative-path 0 relative-path)
              (->CompileQueryFact (inc order) :query/source-shard relative-path 0
                                  source-digest)
              (->CompileQueryFact (+ order 2) :query/checked-projection
                                  relative-path 0 projection-digest)
              (->CompileQueryFact (+ order 3) :query/interface relative-path 0
                                  interface-digest)]))
         (range)
         modules)
        entry-offset (+ 5 (* 4 (count modules)))]
    (vec
     (concat base module-facts
             (map-indexed
              (fn [position entry]
                (->CompileQueryFact (+ entry-offset position) :query/entry
                                    "query" position entry))
              entries)))))

(defn admit-and-identify-query [request]
  (if-not (instance? QueryAdmissionRequest request)
    (->QueryRejected :query/invalid-request
                     "query admission requires a QueryAdmissionRequest")
    (let [{:keys [source-facts compiler-projection-content-id rules-content-id
                  entries strict-entry-abi?]} request]
    (cond
    (not (exact-digest? compiler-projection-content-id))
    (->QueryRejected :query/invalid-compiler-projection
                     "compiler projection must be a lower-case sha256 content ID")
    (not (exact-digest? rules-content-id))
    (->QueryRejected :query/invalid-rules
                     "rules must be a lower-case sha256 content ID")
    (not (valid-entries? entries))
    (->QueryRejected :query/invalid-entries
                     "entries must be a vector of non-empty strings with no duplicates")
    (not (instance? Boolean strict-entry-abi?))
    (->QueryRejected :query/invalid-strict-entry-abi
                     "strict entry ABI must be boolean")
    :else
    (let [rows (source-rows source-facts)]
      (if (query-rejected? rows)
        rows
        (let [modules (module-identities rows)]
          (if (query-rejected? modules)
            modules
            (let [source-facts-content-id
                  (if (string? source-facts)
                    (sha256 source-facts)
                    (sha256-source-rows rows))
                  facts (canonical-query-facts
                         source-facts-content-id compiler-projection-content-id
                         rules-content-id entries strict-entry-abi? modules)]
              (->QueryAdmitted
               (->AdmittedQueryClosure
                (query-digest facts) source-facts-content-id
                compiler-projection-content-id rules-content-id entries
                strict-entry-abi? facts)))))))))))

(defn- envelope [query descriptor]
  [fact-kind fact-stage (:query-digest query) (:rules-content-id query)
   (:compiler-projection-content-id query) (:source-facts-content-id query)
   (alength (.getBytes ^String descriptor StandardCharsets/UTF_8))
   (sha256 descriptor) descriptor])

(defn admit-and-identify-result [request]
  (if-not (instance? ResultAdmissionRequest request)
    (->ResultRejected :result/invalid-request
                      "result admission requires a ResultAdmissionRequest")
    (let [{:keys [query payload]} request]
      (cond
        (not (instance? AdmittedQueryClosure query))
        (->ResultRejected :result/invalid-query
                          "result must belong to an admitted query closure")
        (not (string? payload))
        (->ResultRejected :result/invalid-payload "cache payload must be text")
        :else
        (let [payload-bytes (.getBytes ^String payload StandardCharsets/UTF_8)]
          (->ResultAdmitted
           (->AdmittedResultClosure query payload (alength payload-bytes)
                                    (sha256 payload))))))))

(defn- descriptor-payload [store descriptor]
  (try
    (let [parsed (edn/read-string descriptor)]
      (if-not (and (vector? parsed) (= 3 (count parsed))
                   (= blob-kind (nth parsed 0))
                   (integer? (nth parsed 1)) (<= 0 (nth parsed 1))
                   (exact-digest? (nth parsed 2))
                   (= descriptor (pr-str parsed)))
        (->ResultRejected :result/invalid-payload-descriptor
                          "payload descriptor is not canonical content-addressed data")
        (let [payload-byte-count (nth parsed 1)
              payload-content-id (nth parsed 2)
              bytes (Files/readAllBytes (blobs/blob-path store payload-content-id))
              payload (String. ^bytes bytes StandardCharsets/UTF_8)]
          (if (and (= payload-byte-count (alength ^bytes bytes))
                   (= payload-content-id (sha256-bytes bytes))
                   (= payload-content-id (sha256 payload)))
            payload
            (->ResultRejected :result/payload-content-id-mismatch
                              "payload bytes do not match their content ID")))))
    (catch Exception error
      (->ResultRejected :result/invalid-payload
                        (or (.getMessage error) "payload could not be read")))))

(defn- admit-row [store query row]
  (try
    (if-not (and (vector? row) (= 4 (count row))
                 (= fact-stage (nth row 0))
                 (= (:query-digest query) (nth row 1))
                 (exact-digest? (nth row 2))
                 (string? (nth row 3)))
      (->ResultRejected :result/malformed-candidate
                        "query returned a malformed cache candidate")
      (let [[_ _ fact-id encoding] row
            parsed (edn/read-string encoding)
            descriptor (nth parsed 8 nil)]
        (compile-facts/compile-fact fact-id encoding)
        (if-not (and (vector? parsed) (= 9 (count parsed))
                     (= fact-kind (nth parsed 0))
                     (= fact-stage (nth parsed 1))
                     (= (:query-digest query) (nth parsed 2))
                     (= (:rules-content-id query) (nth parsed 3))
                     (= (:compiler-projection-content-id query) (nth parsed 4))
                     (= (:source-facts-content-id query) (nth parsed 5))
                     (= fact-id (sha256 encoding)))
          (->ResultRejected :result/identity-mismatch
                            "cache candidate does not match its admitted query")
          (let [payload (descriptor-payload store descriptor)]
            (if (result-rejected? payload)
              payload
              (admit-and-identify-result
               (->ResultAdmissionRequest query payload)))))))
    (catch Exception error
      (->ResultRejected :result/malformed-candidate
                        (or (.getMessage error) "cache candidate could not be read")))))

(defn query! [store query]
  (if-not (instance? AdmittedQueryClosure query)
    (->ResultRejected :result/invalid-query
                      "cache query requires an AdmittedQueryClosure")
    (try
      (let [response
          (compile-facts/query!
           store
           [[fact-stage (:query-digest query) (:rules-content-id query)
             (:compiler-projection-content-id query)
             (:source-facts-content-id query)]])]
      (if-not (and (vector? response) (= 5 (count response))
                   (= "store.dev-compile-facts/query-response-v1" (nth response 0))
                   (contains? #{"ONLINE" "COLD"} (nth response 1))
                   (vector? (nth response 4)))
        (->ResultRejected :result/invalid-store-response
                          "Store returned an invalid cache query response")
        (let [candidates (nth response 4)]
          (cond
            (empty? candidates) (->ResultMissing)
            (some #(not (and (vector? %)
                             (= fact-stage (nth % 0 nil))
                             (= (:query-digest query) (nth % 1 nil))))
                  candidates)
            (->ResultRejected :result/unexpected-candidate
                              "cache query returned a candidate outside its exact key")
            (not= 1 (count candidates))
            (->ResultRejected :result/duplicate-candidates
                              "cache query returned more than one candidate")
            :else (admit-row store query (first candidates))))))
      (catch Exception error
        (->ResultRejected :result/invalid-store-response
                          (or (.getMessage error) "Store query failed"))))))

(defn append! [store query payload]
  (let [admission
        (admit-and-identify-result (->ResultAdmissionRequest query payload))]
    (if (result-rejected? admission)
      admission
      (try
        (let [payload-bytes (.getBytes ^String payload StandardCharsets/UTF_8)
            descriptor (pr-str (blobs/publish-blob! store payload-bytes))
            encoding (pr-str (envelope query descriptor))
            entry (compile-facts/compile-fact (sha256 encoding) encoding)
            response (compile-facts/append! store [entry])]
        (if (and (vector? response) (= 5 (count response))
                 (= "store.dev-compile-facts/append-response-v1" (nth response 0))
                 (= "ok" (nth response 1))
                 (exact-digest? (nth response 2))
                 (integer? (nth response 3)) (<= 0 (nth response 3))
                 (integer? (nth response 4)) (<= 0 (nth response 4)))
          admission
          (->ResultRejected :result/invalid-append-response
                            "Store returned an invalid cache append response")))
        (catch Exception error
          (->ResultRejected :result/append-failed
                            (or (.getMessage error) "Store append failed")))))))

(defn query-admitted? [value] (instance? QueryAdmitted value))
(defn query-rejected? [value] (instance? QueryRejected value))
(defn result-admitted? [value] (instance? ResultAdmitted value))
(defn result-missing? [value] (instance? ResultMissing value))
(defn result-rejected? [value] (instance? ResultRejected value))
(defn admitted-query [value] (:closure value))
(defn admitted-result-payload-content-id [value]
  (:payload-content-id (:closure value)))
(defn admitted-result-payload [value] (:payload (:closure value)))
(defn admitted-query-digest [value] (:query-digest (:closure value)))
(defn rejection-detail [value]
  (str (name (:code value)) ": " (:detail value)))
