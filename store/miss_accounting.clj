(ns miss-accounting
  (:require [clojure.set :as set]
            [clojure.string :as str]
            [writer-authority :as writer-authority]))

;; These names and byte-level status values are the Store-facing SP4 contract.
(def miss-accounting-version-v1 1)
(def miss-accounting-format-v1 "beagle.store/MissAccountingV1")
(def fact-miss-event-format-v1 "beagle.store/FactMissEventV1")
(def fact-miss-event-kind-v1 "FactMissEventV1")
(def claim-status-missing-v1 "MISSING")
(def observation-status-not-run-v1 "NOT-RUN")
(def missing-observation-class-v1 "missing-observation")
(def unexplained-claim-class-v1 "unexplained-claim")

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- claim-id-set! [field values]
  (when-not (and (coll? values)
                 (every? #(and (string? %) (not (str/blank? %))) values))
    (fail! :miss-accounting/invalid-claim-ids
           "claim ids must be a collection of nonempty strings"
           {:field field :value values}))
  (let [ids (set values)]
    (when-not (= (count ids) (count values))
      (fail! :miss-accounting/duplicate-claim-id
             "claim id collections must not contain duplicates"
             {:field field :value values}))
    ids))

(defn observed-prepared-difference-v1
  "Return the complete, deterministic difference between prepared and observed claims."
  [prepared-claim-ids observed-claim-ids]
  (let [prepared (claim-id-set! :prepared prepared-claim-ids)
        observed (claim-id-set! :observed observed-claim-ids)
        missing (vec (sort (set/difference prepared observed)))
        unexplained (vec (sort (set/difference observed prepared)))]
    {:format miss-accounting-format-v1
     :version miss-accounting-version-v1
     :missing-claim-ids missing
     :unexplained-claim-ids unexplained
     :complete? (and (empty? missing) (empty? unexplained))}))

(defn fact-miss-event-v1
  "Create one immutable FactMissEventV1 for a missing observation or claim."
  [attempt-id miss-class claim-id]
  (when-not (and (string? attempt-id) (not (str/blank? attempt-id)))
    (fail! :miss-accounting/invalid-attempt-id
           "miss accounting requires a nonempty MaintenanceAttemptId"
           {:attempt-id attempt-id}))
  (when-not (and (string? claim-id) (not (str/blank? claim-id)))
    (fail! :miss-accounting/invalid-claim-id
           "miss accounting requires a nonempty claim id"
           {:claim-id claim-id}))
  (when-not (some #{miss-class}
                  [missing-observation-class-v1
                   unexplained-claim-class-v1])
    (fail! :miss-accounting/invalid-miss-class
           "miss class must be missing-observation or unexplained-claim"
           {:miss-class miss-class}))
  (let [missing-observation? (= miss-class missing-observation-class-v1)
        claim-status (if missing-observation? "PREPARED"
                         claim-status-missing-v1)
        observation-status (if missing-observation?
                             observation-status-not-run-v1
                             "OBSERVED")
        payload [attempt-id miss-class claim-id
                 claim-status observation-status]]
    {:format fact-miss-event-format-v1
     :version miss-accounting-version-v1
     :kind fact-miss-event-kind-v1
     :id (writer-authority/fact-id-v1 fact-miss-event-kind-v1 payload)
     :maintenance-attempt-id attempt-id
     :miss-class miss-class
     :claim-id claim-id
     :claim-status claim-status
     :observation-status observation-status
     :payload payload}))

(defn- miss-events-v1 [attempt-id difference]
  (into []
        (concat
         (map #(fact-miss-event-v1 attempt-id
                                   missing-observation-class-v1 %)
              (:missing-claim-ids difference))
         (map #(fact-miss-event-v1 attempt-id
                                   unexplained-claim-class-v1 %)
              (:unexplained-claim-ids difference)))))

(defn account-misses-before-fallback-v1!
  "Persist every set-difference miss before invoking any conservative fallback.

   PERSIST-MISS! crosses the Store durability boundary: a normal return is its
   receipt and an exception is propagated unchanged. FALLBACK! receives the
   durable miss event and receipt. No fallback starts unless all misses were
   durably recorded."
  [{:keys [attempt-id prepared-claim-ids observed-claim-ids
           persist-miss! fallback!]}]
  (when-not (ifn? persist-miss!)
    (fail! :miss-accounting/invalid-persist-callback
           "miss persistence callback must be callable" {}))
  (when-not (ifn? fallback!)
    (fail! :miss-accounting/invalid-fallback-callback
           "miss fallback callback must be callable" {}))
  (let [difference (observed-prepared-difference-v1
                    prepared-claim-ids observed-claim-ids)
        misses (miss-events-v1 attempt-id difference)
        durable-results (mapv persist-miss! misses)
        fallback-results
        (mapv (fn [miss durable-result]
                (fallback! miss durable-result))
              misses durable-results)]
    {:format miss-accounting-format-v1
     :version miss-accounting-version-v1
     :difference difference
     :misses misses
     :durable-results durable-results
     :fallback-results fallback-results}))
