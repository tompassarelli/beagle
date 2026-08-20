(ns store.epoch
  (:require [cheshire.core :as json]
            [clojure.string :as str])
  (:import [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

;; Epoch-one is deliberately a closed, wire-shaped contract. The structural
;; branch says what was observed; the semantic branch says when that statement
;; is current. Neither branch is allowed to silently imply the other.
(def epoch-genesis-version-v1 1)
(def epoch-genesis-format-v1 "beagle.store/EpochGenesisV1")
(def epoch-genesis-kind-v1 "GENESIS")
(def epoch-source-cold-v1 "COLD")
(def validity-kinds-v1 #{"STRUCTURAL" "SEMANTIC"})
(def semantic-currentness-kinds-v1 #{"EPOCH" "RE-ATTESTATION"})

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :store/code code))))

(defn- value-of [m key]
  (or (get m key) (get m (name key))))

(defn- nonblank-string? [value]
  (and (string? value) (not (str/blank? value))))

(defn- canonical
  "Convert keyword-keyed Clojure values to deterministic JSON-shaped values."
  [value]
  (cond
    (map? value)
    (into (sorted-map)
          (map (fn [[key item]] [(name (if (keyword? key) key (str key)))
                                  (canonical item)]))
          value)
    (vector? value) (mapv canonical value)
    (seq? value) (mapv canonical value)
    (set? value) (vec (sort (map canonical value)))
    :else value))

(defn canonical-json-v1 [value]
  (json/generate-string (canonical value)))

(defn- sha256-hex [bytes]
  (apply str (map #(format "%02x" (bit-and (int %) 255))
                  (.digest (MessageDigest/getInstance "SHA-256")
                           (byte-array
                            (map #(byte (if (> % 127) (- % 256) %)) bytes))))))

(defn- snapshot-id [snapshot]
  (str "sha256:" (sha256-hex (.getBytes (canonical-json-v1 snapshot)
                                       StandardCharsets/UTF_8))))

(defn- binding-source [fact]
  (let [structural (value-of fact :structural)
        semantic (value-of fact :semantic)
        present (count (remove nil? [structural semantic]))]
    (when-not (= 1 present)
      (fail! :epoch/ambiguous-validity
             "each program fact must have exactly one validity binding"
             {:fact fact :binding-count present}))
    (if structural [:STRUCTURAL structural] [:SEMANTIC semantic])))

(defn classify-fact-v1
  "Normalize one fact while enforcing the one-binding rule."
  [fact]
  (when-not (map? fact)
    (fail! :epoch/invalid-fact "program fact must be a map" {:fact fact}))
  (let [fact-id (value-of fact :id)
        [kind body] (binding-source fact)]
    (when-not (nonblank-string? fact-id)
      (fail! :epoch/invalid-fact "program fact requires a nonempty id"
             {:fact fact}))
    (when-not (map? body)
      (fail! :epoch/invalid-binding "validity binding must be a map"
             {:fact-id fact-id :binding body}))
    (case kind
      :STRUCTURAL
      (let [shape (value-of body :shape)]
        (when-not (nonblank-string? shape)
          (fail! :epoch/invalid-structural-binding
                 "structural validity requires a nonempty shape"
                 {:fact-id fact-id :binding body}))
        {"id" fact-id
         "validity" "STRUCTURAL"
         "shape" shape})

      :SEMANTIC
      (let [currentness (value-of body :currentness)
            currentness-kind (some-> (value-of currentness :kind) str/upper-case)
            currentness-name (value-of currentness :name)]
        (when-not (and (map? currentness)
                       (contains? semantic-currentness-kinds-v1
                                  currentness-kind)
                       (nonblank-string? currentness-name))
          (fail! :epoch/invalid-semantic-binding
                 "semantic validity requires an epoch or re-attestation name"
                 {:fact-id fact-id :binding body}))
        {"id" fact-id
         "validity" "SEMANTIC"
         "currentness" {"kind" currentness-kind
                         "name" currentness-name}}))))

(defn- ensure-unique-fact-ids! [facts]
  (let [ids (mapv #(get % "id") facts)]
    (when-not (= (count ids) (count (distinct ids)))
      (fail! :epoch/duplicate-fact-id
             "GENESIS facts must identify each program fact once"
             {:ids ids})))
  facts)

(defn genesis-snapshot-v1
  "Build and content-address a deterministic cold-derived fact snapshot."
  [program-id facts]
  (when-not (nonblank-string? program-id)
    (fail! :epoch/invalid-program "GENESIS requires a nonempty program id"
           {:program-id program-id}))
  (when-not (vector? facts)
    (fail! :epoch/invalid-facts "GENESIS facts must be an ordered vector"
           {:facts facts}))
  (let [classified (ensure-unique-fact-ids!
                    (mapv classify-fact-v1 facts))
        body {"format" epoch-genesis-format-v1
              "version" epoch-genesis-version-v1
              "kind" epoch-genesis-kind-v1
              "source" epoch-source-cold-v1
              "programId" program-id
              "facts" classified
              "factCount" (count classified)}]
    (assoc body "snapshotId" (snapshot-id body))))

(defn snapshot-bytes-v1 [snapshot]
  (.getBytes (canonical-json-v1 snapshot) StandardCharsets/UTF_8))

(defn cross-runtime-vector-v1
  "Return the JSON text and unsigned bytes consumed by other runtimes."
  [value]
  (let [json-text (canonical-json-v1 value)
        bytes (.getBytes json-text StandardCharsets/UTF_8)]
    {:json json-text
     :bytes (vec (map #(bit-and (int %) 255) bytes))}))

(defn decode-snapshot-v1!
  "Decode a JSON snapshot and reject tampering or non-canonical identity."
  [bytes]
  (let [snapshot (json/parse-string (String. ^bytes bytes StandardCharsets/UTF_8))
        expected (value-of snapshot :snapshotId)
        body (dissoc snapshot "snapshotId")]
    (when-not (= epoch-genesis-format-v1 (value-of snapshot :format))
      (fail! :epoch/invalid-snapshot "not an EpochGenesisV1 snapshot" {}))
    (when-not (= epoch-genesis-version-v1 (value-of snapshot :version))
      (fail! :epoch/invalid-snapshot "unsupported EpochGenesisV1 version" {}))
    (when-not (= epoch-genesis-kind-v1 (value-of snapshot :kind))
      (fail! :epoch/invalid-snapshot "snapshot kind is not GENESIS" {}))
    (when-not (= epoch-source-cold-v1 (value-of snapshot :source))
      (fail! :epoch/invalid-snapshot "GENESIS source is not COLD" {}))
    (when-not (= expected (snapshot-id body))
      (fail! :epoch/snapshot-id-mismatch
             "snapshot identity does not match canonical content"
             {:expected (snapshot-id body) :actual expected}))
    (when-not (= (value-of snapshot :factCount)
                 (count (value-of snapshot :facts)))
      (fail! :epoch/fact-count-mismatch
             "snapshot fact count does not match its fact vector" {}))
    (ensure-unique-fact-ids!
     (mapv classify-fact-v1 (mapv (fn [fact]
                                    {"id" (value-of fact :id)
                                     (if (= "STRUCTURAL" (value-of fact :validity))
                                       "structural"
                                       "semantic")
                                     (if (= "STRUCTURAL" (value-of fact :validity))
                                       {"shape" (value-of fact :shape)}
                                       {"currentness" (value-of fact :currentness)})})
                                  (value-of snapshot :facts))))
    snapshot))

(defn cold-round-trip-v1
  "Produce a cold GENESIS snapshot, serialize it, and decode it again."
  [program-id facts]
  (let [snapshot (genesis-snapshot-v1 program-id facts)
        vector (cross-runtime-vector-v1 snapshot)
        bytes (:bytes vector)
        recovered (decode-snapshot-v1! (byte-array bytes))]
    {:source epoch-source-cold-v1
     :snapshot recovered
     :wire-json (:json vector)
     :wire-bytes bytes
     :round-trip? (= snapshot recovered)}))

(defn certify-cold-genesis-v1
  "Attach a certificate only after the cold wire round trip has succeeded."
  [round-trip]
  (when-not (and (= epoch-source-cold-v1 (:source round-trip))
                 (:round-trip? round-trip))
    (fail! :epoch/unverified-genesis
           "GENESIS certification requires a successful cold round trip"
           {:round-trip round-trip}))
  (let [snapshot (:snapshot round-trip)]
    (assoc snapshot
           "certificate"
           {"kind" epoch-genesis-kind-v1
            "source" epoch-source-cold-v1
            "snapshotId" (value-of snapshot :snapshotId)
            "factCount" (value-of snapshot :factCount)})))
