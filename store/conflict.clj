;; conflict.clj — deterministic V1 conflict algebra for immutable Store facts.
(ns conflict
  (:require [clojure.string :as str])
  (:import [java.io ByteArrayOutputStream DataOutputStream]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

;; Locate the sibling from this file so callers need not choose a working
;; directory. FactEnvelopeV1 remains the sole authority for fact identity.
(load-file
 (.getPath (java.io.File.
            (.getParentFile (.getCanonicalFile (java.io.File. (str *file*))))
            "writer_authority.clj")))

(def conflict-algebra-version-v1 1)
(def fact-conflict-key-format-v1 "beagle.store/FactConflictKeyV1")
(def conflict-set-format-v1 "beagle.store/ConflictSetV1")
(def conflict-set-digest-format-v1 "beagle.store/ConflictSetDigestV1")
(def fact-supersession-format-v1 "beagle.store/FactSupersessionV1")
(def conflict-publication-result-format-v1
  "beagle.store/ConflictPublicationResultV1")
(def conflict-state-format-v1 "beagle.store/ConflictStateV1")

(def fact-conflict-key-fields-v1
  [:candidateRoot
   :claimId
   :verifierMaterializationId
   :compilerEpochId
   :policyId
   :targetAbiProfile
   :factSchemaId])
(def conflict-result-statuses-v1
  [:missing :pass :fail :conflict :inadmissible])
(def fact-id-mismatch-code-v1 :conflict/fact-id-mismatch)
(def fact-id-collision-code-v1 :conflict/fact-id-collision)
(def stale-revision-code-v1 :conflict/stale-revision)
(def unresolved-publication-code-v1 :conflict/unresolved-publication)

(defn- conflict-fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- nonblank-string? [value]
  (and (string? value) (not (str/blank? value))))

(defn fact-conflict-key-v1
  "Validate and freeze the complete semantic identity of one decision set."
  [value]
  (when-not (map? value)
    (conflict-fail! :conflict/invalid-key
                    "FactConflictKeyV1 must be a map" {:key value}))
  (doseq [field fact-conflict-key-fields-v1]
    (when-not (nonblank-string? (get value field))
      (conflict-fail! :conflict/invalid-key
                      "FactConflictKeyV1 requires every identity field"
                      {:field field :value (get value field)})))
  (let [unknown (seq (remove (set (concat [:format :version]
                                          fact-conflict-key-fields-v1))
                             (keys value)))]
    (when unknown
      (conflict-fail! :conflict/invalid-key
                      "FactConflictKeyV1 contains unknown fields"
                      {:fields (vec (sort-by str unknown))})))
  (when (and (contains? value :format)
             (not= fact-conflict-key-format-v1 (:format value)))
    (conflict-fail! :conflict/invalid-key
                    "FactConflictKeyV1 format does not match V1"
                    {:format (:format value)}))
  (when (and (contains? value :version)
             (not= conflict-algebra-version-v1 (:version value)))
    (conflict-fail! :conflict/invalid-key
                    "FactConflictKeyV1 version is not supported"
                    {:version (:version value)}))
  (merge {:format fact-conflict-key-format-v1
          :version conflict-algebra-version-v1}
         (select-keys value fact-conflict-key-fields-v1)))

(defn- require-decision-status! [status]
  (when-not (some #{status} [:pass :fail])
    (conflict-fail! :conflict/invalid-decision
                    "an admitted decision must be PASS or FAIL"
                    {:status status}))
  status)

(defn decision-fact-v1
  "Create canonical GateCandidateVerdictV1 content for a conflict decision."
  [key status evidence-digest]
  (let [key (fact-conflict-key-v1 key)
        status (require-decision-status! status)]
    (when-not (nonblank-string? evidence-digest)
      (conflict-fail! :conflict/invalid-decision
                      "a decision requires an evidence digest" {}))
    (let [envelope
          (writer-authority/fact-envelope-v1
           "GateCandidateVerdictV1" [key status evidence-digest])]
      {:fact-id (:id envelope)
       :bytes (:bytes envelope)})))

(defn validate-decision-fact-v1
  "Recompute fact identity and decode decision metadata from canonical bytes."
  [{:keys [fact-id bytes]}]
  (when-not (nonblank-string? fact-id)
    (conflict-fail! :conflict/invalid-fact
                    "a conflict fact requires a fact ID" {}))
  (let [decoded
        (try
          (writer-authority/validate-fact-envelope! bytes fact-id)
          (catch clojure.lang.ExceptionInfo error
            (if (= :fact-envelope/id-mismatch
                   (or (:fram/code (ex-data error)) (:type (ex-data error))))
              (conflict-fail! fact-id-mismatch-code-v1
                              "supplied fact ID does not match canonical bytes"
                              {:fact-id fact-id :actual (:actual (ex-data error))})
              (throw error))))
        payload (:payload decoded)]
    (when-not (and (= "GateCandidateVerdictV1" (:kind decoded))
                   (vector? payload)
                   (= 3 (count payload)))
      (conflict-fail! :conflict/invalid-fact
                      "conflict input must be a GateCandidateVerdictV1"
                      {:fact-id fact-id :kind (:kind decoded)}))
    (let [[key status evidence-digest] payload]
      (require-decision-status! status)
      (when-not (nonblank-string? evidence-digest)
        (conflict-fail! :conflict/invalid-decision
                        "a decision requires an evidence digest"
                        {:fact-id fact-id}))
      {:fact-id fact-id
       :bytes (vec bytes)
       :key (fact-conflict-key-v1 key)
       :status status
       :evidence-digest evidence-digest})))

(defn merge-validated-content-v1
  "Merge one identity-checked fact into ID->bytes content.

   This is the collision boundary after hash verification. Equal bytes are an
   idempotent RETAINED-SAME-CONTENT result; unequal bytes for one valid ID are
   a typed collision and never replace the retained content."
  [contents {:keys [fact-id bytes]}]
  (if-let [retained (get contents fact-id)]
    (if (= retained bytes)
      {:contents contents
       :result {:status :retained-same-content :fact-id fact-id}}
      (conflict-fail! fact-id-collision-code-v1
                      "two valid canonical contents claim one fact ID"
                      {:fact-id fact-id}))
    {:contents (assoc contents fact-id bytes)
     :result {:status :accepted :fact-id fact-id}}))

(defn deduplicate-fact-contents-v1
  "Validate all submissions, reject collisions, and return facts by fact ID."
  [submissions]
  (when-not (sequential? submissions)
    (conflict-fail! :conflict/invalid-facts
                    "conflict facts must be a sequential collection" {}))
  (let [validated (mapv validate-decision-fact-v1
                        (sort-by (juxt :fact-id :bytes) submissions))
        grouped (group-by :fact-id validated)]
    (doseq [[fact-id facts] (sort-by key grouped)]
      (when (> (count (set (map :bytes facts))) 1)
        (conflict-fail! fact-id-collision-code-v1
                        "two valid canonical contents claim one fact ID"
                        {:fact-id fact-id})))
    (mapv (comp first val) (sort-by key grouped))))

(defn- digest-parts [domain parts]
  (let [buffer (ByteArrayOutputStream.)
        output (DataOutputStream. buffer)]
    (doseq [part (cons domain parts)]
      (let [bytes (.getBytes ^String (str part) StandardCharsets/UTF_8)]
        (.writeInt output (alength bytes))
        (.write output bytes)))
    (.flush output)
    (str "sha256:"
         (apply str
                (map #(format "%02x" (bit-and (int %) 255))
                     (.digest (MessageDigest/getInstance "SHA-256")
                              (.toByteArray buffer)))))))

(defn conflict-set-digest-v1
  "Digest sorted fact ID, status, and evidence-digest tuples."
  [decisions]
  (let [ordered (sort-by :fact-id decisions)]
    (digest-parts
     conflict-set-digest-format-v1
     (mapcat (fn [{:keys [fact-id status evidence-digest]}]
               [fact-id (name status) evidence-digest])
             ordered))))

(defn fact-supersession-v1
  "Create a content-addressed exact-set supersession statement."
  [{:keys [key prior-conflict-set-digest superseded-fact-id
           replacement-fact-id reason authority]}]
  (let [key (fact-conflict-key-v1 key)]
    (doseq [[field value]
            [[:prior-conflict-set-digest prior-conflict-set-digest]
             [:superseded-fact-id superseded-fact-id]
             [:replacement-fact-id replacement-fact-id]
             [:reason reason]
             [:authority authority]]]
      (when-not (nonblank-string? value)
        (conflict-fail! :conflict/invalid-supersession
                        "FactSupersessionV1 requires every field"
                        {:field field})))
    (when (= superseded-fact-id replacement-fact-id)
      (conflict-fail! :conflict/invalid-supersession
                      "a supersession must name a distinct replacement" {}))
    (let [body {:format fact-supersession-format-v1
                :version conflict-algebra-version-v1
                :key key
                :prior-conflict-set-digest prior-conflict-set-digest
                :superseded-fact-id superseded-fact-id
                :replacement-fact-id replacement-fact-id
                :reason reason
                :authority authority}
          parts (concat (map key fact-conflict-key-fields-v1)
                        [prior-conflict-set-digest superseded-fact-id
                         replacement-fact-id reason authority])]
      (assoc body :supersession-id
             (digest-parts fact-supersession-format-v1 parts)))))

(defn- validate-supersession!
  [statement key base-result facts admitted-reasons admitted-authorities]
  (let [canonical (fact-supersession-v1 statement)]
    (when-not (= (:supersession-id statement) (:supersession-id canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession ID does not match its canonical content"
                      {:supersession-id (:supersession-id statement)}))
    (when-not (= key (:key canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession names a different conflict key" {}))
    (when-not (= (:conflict-set-digest base-result)
                 (:prior-conflict-set-digest canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession does not name the exact prior conflict set"
                      {:expected (:conflict-set-digest base-result)
                       :actual (:prior-conflict-set-digest canonical)}))
    (when-not (contains? facts (:superseded-fact-id canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession member is absent from the prior set" {}))
    (when-not (contains? facts (:replacement-fact-id canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession replacement is absent from the prior set" {}))
    (when-not (contains? admitted-reasons (:reason canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession reason is not admitted"
                      {:reason (:reason canonical)}))
    (when-not (contains? admitted-authorities (:authority canonical))
      (conflict-fail! :conflict/invalid-supersession
                      "supersession authority is not admitted"
                      {:authority (:authority canonical)}))
    canonical))

(defn- conflict-result [key status facts]
  (let [decisions (mapv #(select-keys % [:fact-id :status :evidence-digest])
                        (sort-by :fact-id facts))]
    {:format conflict-set-format-v1
     :version conflict-algebra-version-v1
     :key key
     :status status
     :fact-ids (mapv :fact-id decisions)
     :decisions decisions
     :conflict-set-digest (conflict-set-digest-v1 decisions)}))

(defn- unresolved-result [key facts]
  (let [status (case (count facts)
                 0 :missing
                 1 (:status (first facts))
                 :conflict)]
    (conflict-result key status facts)))

(defn resolve-conflict-set-v1
  "Resolve immutable decisions as a set, independent of arrival order.

   The request keys are :key, :facts, optional :supersessions, and the admitted
   reason/authority sets. A fact for any different full key is INADMISSIBLE.
   Supersessions are applied only against the exact unsuperseded set digest."
  [{:keys [key facts supersessions admitted-supersession-reasons
           admitted-supersession-authorities]
    :or {facts [] supersessions []
         admitted-supersession-reasons #{}
         admitted-supersession-authorities #{}}}]
  (let [key (fact-conflict-key-v1 key)
        facts (deduplicate-fact-contents-v1 facts)
        mismatched (seq (remove #(= key (:key %)) facts))]
    (if mismatched
      (conflict-result key :inadmissible facts)
      (let [base (unresolved-result key facts)]
        (if (empty? supersessions)
          base
          (let [by-id (into {} (map (juxt :fact-id identity) facts))
                validated
                (mapv #(validate-supersession!
                        % key base by-id admitted-supersession-reasons
                        admitted-supersession-authorities)
                      (sort-by #(str (:supersession-id %)) supersessions))
                contradictory
                (some (fn [[_ group]]
                        (> (count (set (map :replacement-fact-id group))) 1))
                      (group-by :superseded-fact-id validated))]
            (when contradictory
              (conflict-fail! :conflict/invalid-supersession
                              "one member has contradictory replacements" {}))
            (let [removed (set (map :superseded-fact-id validated))
                  retained (remove #(contains? removed (:fact-id %)) facts)]
              (unresolved-result key retained))))))))

(defn conflict-state-v1 [revision published-route]
  (when-not (some? revision)
    (conflict-fail! :conflict/invalid-state
                    "conflict state requires a Store revision" {}))
  {:format conflict-state-format-v1
   :version conflict-algebra-version-v1
   :revision revision
   :published-route published-route})

(defn apply-conflict-publication-v1
  "Resolve and atomically decide publication against one Store revision."
  [state {:keys [expected-revision published-route] :as request} next-revision]
  (when-not (and (map? state)
                 (= conflict-state-format-v1 (:format state))
                 (= conflict-algebra-version-v1 (:version state))
                 (some? (:revision state)))
    (conflict-fail! :conflict/invalid-state
                    "publication requires a ConflictStateV1 value" {}))
  (when-not (some? expected-revision)
    (conflict-fail! :conflict/invalid-revision
                    "publication requires an expected Store revision" {}))
  (if (not= expected-revision (:revision state))
    {:state state
     :result {:format conflict-publication-result-format-v1
              :version conflict-algebra-version-v1
              :status :stale-revision
              :code stale-revision-code-v1
              :expected-revision expected-revision
              :current-revision (:revision state)}}
    (let [resolution (resolve-conflict-set-v1 request)]
      (if (some #{(:status resolution)} [:missing :conflict :inadmissible])
        {:state state
         :result {:format conflict-publication-result-format-v1
                  :version conflict-algebra-version-v1
                  :status :unresolved
                  :code unresolved-publication-code-v1
                  :resolution resolution}}
        (do
          (when-not (and (some? next-revision)
                         (not= next-revision (:revision state)))
            (conflict-fail! :conflict/invalid-revision
                            "accepted publication must advance revision" {}))
          (let [next-state (assoc state
                                  :revision next-revision
                                  :published-route published-route)]
            {:state next-state
             :result {:format conflict-publication-result-format-v1
                      :version conflict-algebra-version-v1
                      :status :accepted
                      :revision next-revision
                      :resolution resolution}}))))))
