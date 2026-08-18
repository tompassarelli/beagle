;; SP3: signed materialization tuple and compiler/network-free proof-pack check.
(require '[clojure.edn :as edn])

(import '(java.util Base64))

(load-file "materialization.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:fram/code (ex-data error)) (:type (ex-data error))))))

(def fixture
  (edn/read-string
   (slurp "tests/fixtures/sp3-materialization/proof_pack.edn")))
(def proof-pack (:proof-pack fixture))
(def expected-id (:expected-attestation-id fixture))
(def launcher-key (:launcher-public-key fixture))

(check! "MaterializationAttestationV1 public identifiers are frozen"
        (and (= 1 materialization/materialization-attestation-version-v1)
             (= "beagle.store/MaterializationAttestationV1"
                materialization/materialization-attestation-format-v1)
             (= "beagle.store/MaterializationProofPackV1"
                materialization/materialization-proof-pack-format-v1)
             (= "beagle.store/MaterializationVerificationV1"
                materialization/materialization-verification-format-v1)
             (= [:executable-id
                 :compiler-epoch-id
                 :schema-id
                 :policy-id
                 :snapshot-id
                 :inputs-id
                 :outputs-id
                 :launcher-signature]
                materialization/materialization-attestation-fields-v1)
             (= :materialization/substitution
                materialization/materialization-substitution-code-v1)
             (= :materialization/invalid-launcher-signature
                materialization/materialization-signature-code-v1)))

(check! "fixture freezes the complete eight-field attestation ID"
        (= expected-id
           (materialization/materialization-attestation-id-v1
            (:attestation proof-pack))))

(let [observed (atom [])
      result
      (materialization/verify-materialization-proof-pack-v1!
       proof-pack
       {:expected-attestation-id expected-id
        :launcher-public-key launcher-key
        :observe! #(do (swap! observed conj %) %)})]
  (check! "offline proof verification observes exactly once and returns PASS"
          (and (= :pass (:status result))
               (= "beagle.store/MaterializationVerificationV1"
                  (:format result))
               (= expected-id (:attestation-id result))
               (= [(:observation proof-pack)] @observed)
               (= (:observation proof-pack) (:observation result)))))

(def alternate-signature
  (.encodeToString (Base64/getEncoder) (byte-array 64)))

;; Recompute the untrusted pack ID and the caller-supplied expected ID after
;; each substitution. The unchanged trusted launcher key must still reject
;; every field before the observer can run or a PASS value can exist.
(doseq [field materialization/materialization-attestation-fields-v1]
  (let [original (get-in proof-pack [:attestation field])
        replacement (if (= field :launcher-signature)
                      alternate-signature
                      (str original "-substituted"))
        attacked-attestation (assoc (:attestation proof-pack) field replacement)
        attacked-id
        (materialization/materialization-attestation-id-v1
         attacked-attestation)
        attacked-pack (assoc proof-pack
                             :attestation attacked-attestation
                             :attestation-id attacked-id)
        observed (atom [])
        status (atom :not-run)
        code
        (error-code
         (fn []
           (reset!
            status
            (:status
             (materialization/verify-materialization-proof-pack-v1!
              attacked-pack
              {:expected-attestation-id attacked-id
               :launcher-public-key launcher-key
               :observe! (fn [value]
                           (swap! observed conj value)
                           value)})))))]
    (check! (str "substitution rejects before observation or PASS: " field)
            (and (= :materialization/invalid-launcher-signature code)
                 (empty? @observed)
                 (= :not-run @status)))))

(let [observed (atom [])
      attacked-pack (assoc-in proof-pack [:attestation :schema-id]
                              "sha256:substituted")]
  (check! "tuple/ID disagreement rejects before key parsing or observation"
          (and (= :materialization/substitution
                  (error-code
                   (fn []
                     (materialization/verify-materialization-proof-pack-v1!
                      attacked-pack
                      {:expected-attestation-id expected-id
                       :launcher-public-key "not-a-key"
                       :observe! (fn [value]
                                   (swap! observed conj value))}))))
               (empty? @observed))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp3-materialization: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp3-materialization: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
