;; MaterializationAttestationV1 binds the complete executable proof tuple.
;; Verification is deliberately local: callers supply the trusted launcher key
;; and expected attestation ID, and observation starts only after both bindings
;; have been proven.
(ns materialization
  (:require [clojure.string :as str])
  (:import [java.nio.charset StandardCharsets]
           [java.security KeyFactory MessageDigest Signature]
           [java.security.spec X509EncodedKeySpec]
           [java.util Base64]))

(def materialization-attestation-version-v1 1)
(def materialization-attestation-format-v1
  "beagle.store/MaterializationAttestationV1")
(def materialization-proof-pack-format-v1
  "beagle.store/MaterializationProofPackV1")
(def materialization-verification-format-v1
  "beagle.store/MaterializationVerificationV1")

;; Order is part of the public byte contract. A semantic change starts V2.
(def materialization-attestation-fields-v1
  [:executable-id
   :compiler-epoch-id
   :schema-id
   :policy-id
   :snapshot-id
   :inputs-id
   :outputs-id
   :launcher-signature])

(def materialization-substitution-code-v1 :materialization/substitution)
(def materialization-signature-code-v1
  :materialization/invalid-launcher-signature)

(def ^:private unsigned-fields-v1
  (vec (butlast materialization-attestation-fields-v1)))
(def ^:private attestation-keys-v1
  (set (concat [:format :version] materialization-attestation-fields-v1)))
(def ^:private proof-pack-keys-v1
  #{:format :version :attestation-id :attestation :observation})
(def ^:private signature-byte-count-v1 64)

(defn- materialization-fail! [code message data]
  (throw (ex-info message (assoc data :type code :store/code code))))

(defn- exact-keys? [value expected-keys]
  (and (map? value) (= expected-keys (set (keys value)))))

(defn- unicode-scalar-string? [value]
  (and
   (string? value)
   (loop [index 0]
     (if (>= index (count value))
       true
       (let [unit (int (.charAt ^String value index))]
         (cond
           (<= 55296 unit 56319)
           (and (< (inc index) (count value))
                (let [next-unit (int (.charAt ^String value (inc index)))]
                  (and (<= 56320 next-unit 57343)
                       (recur (+ index 2)))))

           (<= 56320 unit 57343) false
           :else (recur (inc index))))))))

(defn- require-identifier! [field value]
  (when-not (and (unicode-scalar-string? value) (not (str/blank? value)))
    (materialization-fail!
     :materialization/invalid-attestation
     "materialization tuple fields must be nonempty Unicode scalar strings"
     {:field field}))
  value)

(defn- u32-bytes [value]
  (mapv #(bit-and 255 (unsigned-bit-shift-right (long value) %))
        [24 16 8 0]))

(defn- string-bytes [field value]
  (let [value (require-identifier! field value)
        bytes (mapv #(bit-and (int %) 255)
                    (.getBytes ^String value StandardCharsets/UTF_8))]
    (into (u32-bytes (count bytes)) bytes)))

(defn- signed-byte-array [bytes]
  (byte-array (map #(byte (if (> % 127) (- % 256) %)) bytes)))

(defn- sha256-id [bytes]
  (str "sha256:"
       (apply str
              (map #(format "%02x" (bit-and (int %) 255))
                   (.digest (MessageDigest/getInstance "SHA-256")
                            (signed-byte-array bytes))))))

(defn- decode-base64! [code label value]
  (when-not (and (string? value) (not (str/blank? value)))
    (materialization-fail! code (str label " must be canonical base64") {}))
  (try
    (let [decoder (Base64/getDecoder)
          encoder (Base64/getEncoder)
          bytes (.decode decoder ^String value)]
      (when-not (= value (.encodeToString encoder bytes))
        (materialization-fail! code (str label " must be canonical base64") {}))
      bytes)
    (catch IllegalArgumentException _
      (materialization-fail! code (str label " must be canonical base64") {}))))

(defn materialization-signing-bytes-v1
  "Return the frozen bytes signed by the launcher (all tuple fields but signature)."
  [attestation]
  (when-not (and (map? attestation)
                 (= materialization-attestation-format-v1
                    (:format attestation))
                 (= materialization-attestation-version-v1
                    (:version attestation)))
    (materialization-fail! :materialization/invalid-attestation
                           "materialization attestation format is not V1" {}))
  (vec
   (concat
    (map #(bit-and (int %) 255)
         (.getBytes materialization-attestation-format-v1
                    StandardCharsets/UTF_8))
    [0 1]
    (mapcat #(string-bytes % (get attestation %)) unsigned-fields-v1))))

(defn- require-attestation! [attestation]
  (when-not (exact-keys? attestation attestation-keys-v1)
    (materialization-fail! :materialization/invalid-attestation
                           "materialization attestation must contain exactly the V1 fields"
                           {:fields (when (map? attestation)
                                      (set (keys attestation)))}))
  (materialization-signing-bytes-v1 attestation)
  (let [signature
        (decode-base64! materialization-signature-code-v1
                        "launcher signature"
                        (:launcher-signature attestation))]
    (when-not (= signature-byte-count-v1 (count signature))
      (materialization-fail! materialization-signature-code-v1
                             "launcher signature must be a 64-byte Ed25519 signature"
                             {:bytes (count signature)})))
  attestation)

(defn materialization-attestation-v1
  "Freeze one signed executable tuple as MaterializationAttestationV1."
  [tuple]
  (when-not (and (map? tuple)
                 (= (set materialization-attestation-fields-v1)
                    (set (keys tuple))))
    (materialization-fail! :materialization/invalid-attestation
                           "materialization tuple must contain exactly the V1 fields"
                           {:fields (when (map? tuple) (set (keys tuple)))}))
  (require-attestation!
   (assoc tuple
          :format materialization-attestation-format-v1
          :version materialization-attestation-version-v1)))

(defn materialization-attestation-v1-bytes
  "Return the frozen bytes identifying all eight attestation fields."
  [attestation]
  (let [attestation (require-attestation! attestation)
        signing-bytes (materialization-signing-bytes-v1 attestation)
        signature (decode-base64! materialization-signature-code-v1
                                  "launcher signature"
                                  (:launcher-signature attestation))]
    (vec (concat signing-bytes (u32-bytes (count signature)) signature))))

(defn materialization-attestation-id-v1 [attestation]
  (sha256-id (materialization-attestation-v1-bytes attestation)))

(defn materialization-proof-pack-v1
  "Validate and freeze an offline proof pack without observing its payload."
  [{:keys [attestation-id attestation observation] :as proof-pack}]
  (when-not (exact-keys? proof-pack proof-pack-keys-v1)
    (materialization-fail! :materialization/invalid-proof-pack
                           "materialization proof pack must contain exactly the V1 fields"
                           {:fields (when (map? proof-pack)
                                      (set (keys proof-pack)))}))
  (when-not (and (= materialization-proof-pack-format-v1 (:format proof-pack))
                 (= materialization-attestation-version-v1
                    (:version proof-pack)))
    (materialization-fail! :materialization/invalid-proof-pack
                           "materialization proof pack format is not V1" {}))
  (require-identifier! :attestation-id attestation-id)
  (require-attestation! attestation)
  {:format materialization-proof-pack-format-v1
   :version materialization-attestation-version-v1
   :attestation-id attestation-id
   :attestation attestation
   :observation observation})

(defn- launcher-public-key! [encoded]
  (let [bytes (decode-base64! :materialization/invalid-launcher-key
                              "launcher public key" encoded)]
    (try
      (.generatePublic (KeyFactory/getInstance "Ed25519")
                       (X509EncodedKeySpec. bytes))
      (catch Exception error
        (materialization-fail! :materialization/invalid-launcher-key
                               "launcher public key is not an Ed25519 X.509 key"
                               {:cause (.getMessage error)})))))

(defn verify-materialization-proof-pack-v1!
  "Verify PACK locally, then and only then call :observe! and return PASS.

   OPTIONS must contain the externally trusted :expected-attestation-id and
   :launcher-public-key. :observe! is optional and defaults to identity."
  [proof-pack {:keys [expected-attestation-id launcher-public-key observe!]
               :or {observe! identity}
               :as options}]
  (when-not (= #{:expected-attestation-id :launcher-public-key :observe!}
               (set (keys (assoc options :observe! observe!))))
    (materialization-fail! :materialization/invalid-verifier
                           "materialization verifier options must contain exactly the V1 fields"
                           {:fields (when (map? options) (set (keys options)))}))
  (require-identifier! :expected-attestation-id expected-attestation-id)
  (when-not (ifn? observe!)
    (materialization-fail! :materialization/invalid-verifier
                           "materialization observer must be callable" {}))
  (let [proof-pack (materialization-proof-pack-v1 proof-pack)
        attestation (:attestation proof-pack)
        computed-id (materialization-attestation-id-v1 attestation)]
    ;; Both comparisons precede key parsing, signature work, observation, and PASS.
    (when-not (and (= computed-id (:attestation-id proof-pack))
                   (= computed-id expected-attestation-id))
      (materialization-fail! materialization-substitution-code-v1
                             "materialization tuple does not match its trusted attestation"
                             {:expected-attestation-id expected-attestation-id
                              :claimed-attestation-id (:attestation-id proof-pack)
                              :computed-attestation-id computed-id}))
    (let [verifier (Signature/getInstance "Ed25519")
          signature
          (decode-base64! materialization-signature-code-v1
                          "launcher signature"
                          (:launcher-signature attestation))]
      (.initVerify verifier (launcher-public-key! launcher-public-key))
      (.update verifier
               (signed-byte-array
                (materialization-signing-bytes-v1 attestation)))
      (when-not (.verify verifier signature)
        (materialization-fail! materialization-signature-code-v1
                               "launcher signature does not authenticate the materialization tuple"
                               {:attestation-id computed-id})))
    (let [observation (observe! (:observation proof-pack))]
      {:format materialization-verification-format-v1
       :version materialization-attestation-version-v1
       :status :pass
       :attestation-id computed-id
       :observation observation})))
