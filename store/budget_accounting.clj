;; budget_accounting.clj — bounded Store volume and routine admission.
(ns budget-accounting
  (:require [clojure.string :as str]))

(def budget-accounting-version-v1 1)
(def budget-accounting-format-v1 "beagle.store/BudgetAccountingV1")
(def budget-accounting-fixture-format-v1 "beagle.store/SP6BudgetFixtureV1")

;; The order is part of the V1 result contract. A semantic change starts V2.
(def budget-metric-fields-v1
  [:packed-volume-bytes
   :append-bytes
   :fact-count
   :replay-bytes
   :replay-fact-count
   :read-bytes
   :read-fact-count
   :transaction-count
   :fsync-count])
(def routine-budget-fields-v1
  (mapv #(keyword (str "max-" (name %))) budget-metric-fields-v1))
(def budget-breach-code-v1 :budget/routine-breach)
(def budget-invalid-code-v1 :budget/invalid)
(def budget-accepted-code-v1 :budget/accepted)

(defn- budget-fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- nonnegative-integer! [label value]
  (when-not (and (integer? value) (not (neg? value)))
    (budget-fail! budget-invalid-code-v1
                  (str label " must be a nonnegative integer")
                  {:label label :value value}))
  value)

(defn- exact-map-keys? [value expected]
  (and (map? value) (= expected (set (keys value)))))

(defn- fact-measurement! [index fact]
  (when-not (map? fact)
    (budget-fail! budget-invalid-code-v1
                  "each accounted fact must be a map"
                  {:index index}))
  (doseq [field [:packed-bytes :append-bytes :replay-bytes :read-bytes]]
    (nonnegative-integer! (str "fact " index " " (name field))
                          (get fact field)))
  fact)

(defn- fact-vector! [label facts]
  (when-not (vector? facts)
    (budget-fail! budget-invalid-code-v1
                  (str label " must be a vector of facts")
                  {:label label}))
  (mapv fact-measurement! (range (count facts)) facts))

(defn- sum-field [facts field]
  (reduce +' 0 (map field facts)))

(defn- metric-values! [metrics]
  (when-not (exact-map-keys? metrics
                             (set (concat [:format :version]
                                          budget-metric-fields-v1)))
    (budget-fail! budget-invalid-code-v1
                  "budget metrics must contain exactly the V1 fields"
                  {:fields (when (map? metrics) (set (keys metrics)))}))
  (when-not (and (= budget-accounting-format-v1 (:format metrics))
                 (= budget-accounting-version-v1 (:version metrics)))
    (budget-fail! budget-invalid-code-v1
                  "budget metrics format is not V1"
                  {:format (:format metrics) :version (:version metrics)}))
  (doseq [field budget-metric-fields-v1]
    (nonnegative-integer! (name field) (get metrics field)))
  metrics)

(defn measure-routine-v1
  "Measure append, replay, and read work before it reaches the Store.

   APPEND-FACTS is required. REPLAY-FACTS and READ-FACTS are independent
   vectors so a caller cannot accidentally charge a replay or read as an
   append. Each fact carries packed, append, replay, and read byte sizes.
   Transaction and fsync counts default to one for one durable append.
  "
  [{:keys [append-facts replay-facts read-facts transaction-count fsync-count]
    :or {replay-facts []
         read-facts []
         transaction-count 1
         fsync-count 1}}]
  (let [append-facts (fact-vector! "append-facts" append-facts)
        replay-facts (fact-vector! "replay-facts" replay-facts)
        read-facts (fact-vector! "read-facts" read-facts)]
    (nonnegative-integer! "transaction-count" transaction-count)
    (nonnegative-integer! "fsync-count" fsync-count)
    (metric-values!
     {:format budget-accounting-format-v1
      :version budget-accounting-version-v1
      :packed-volume-bytes (sum-field append-facts :packed-bytes)
      :append-bytes (sum-field append-facts :append-bytes)
      :fact-count (count append-facts)
      :replay-bytes (sum-field replay-facts :replay-bytes)
      :replay-fact-count (count replay-facts)
      :read-bytes (sum-field read-facts :read-bytes)
      :read-fact-count (count read-facts)
      :transaction-count transaction-count
      :fsync-count fsync-count})))

(defn routine-budget-v1
  "Validate and freeze a complete fail-closed routine budget."
  [limits]
  (let [expected (set (concat [:format :version] routine-budget-fields-v1))]
    (when-not (exact-map-keys? limits expected)
      (budget-fail! budget-invalid-code-v1
                    "routine budget must contain exactly the V1 fields"
                    {:fields (when (map? limits) (set (keys limits)))}))
    (when-not (and (= budget-accounting-format-v1 (:format limits))
                   (= budget-accounting-version-v1 (:version limits)))
      (budget-fail! budget-invalid-code-v1
                    "routine budget format is not V1"
                    {:format (:format limits) :version (:version limits)}))
    (doseq [field routine-budget-fields-v1]
      (nonnegative-integer! (name field) (get limits field)))
    limits))

(defn- budget-limit [budget metric]
  (get budget (keyword (str "max-" (name metric)))))

(defn check-routine-budget-v1
  "Return PASS or a complete breach report without performing an append."
  [metrics budget]
  (let [metrics (metric-values! metrics)
        budget (routine-budget-v1 budget)
        breaches
        (mapv (fn [metric]
                (let [actual (get metrics metric)
                      limit (budget-limit budget metric)]
                  {:metric metric :actual actual :limit limit}))
              (filter #(> (get metrics %) (budget-limit budget %))
                      budget-metric-fields-v1))]
    {:format budget-accounting-format-v1
     :version budget-accounting-version-v1
     :status (if (empty? breaches) :pass :breach)
     :metrics metrics
     :budget budget
     :breaches breaches}))

(defn empty-state-v1
  "Create an empty cumulative accounting state."
  []
  {:format budget-accounting-format-v1
   :version budget-accounting-version-v1
   :facts []
   :metrics (measure-routine-v1 {:append-facts []
                                 :transaction-count 0
                                 :fsync-count 0})})

(defn- state! [state]
  (when-not (map? state)
    (budget-fail! budget-invalid-code-v1
                  "budget state must be a map" {}))
  (when-not (and (= budget-accounting-format-v1 (:format state))
                 (= budget-accounting-version-v1 (:version state))
                 (vector? (:facts state)))
    (budget-fail! budget-invalid-code-v1
                  "budget state format is not V1" {}))
  (metric-values! (:metrics state))
  state)

(defn- add-metrics [left right]
  (assoc (reduce (fn [result field]
                   (assoc result field
                          (+ (get left field) (get right field))))
                 left budget-metric-fields-v1)
         :format budget-accounting-format-v1
         :version budget-accounting-version-v1))

(defn append-with-budget-v1!
  "Atomically append only when cumulative routine budgets still pass.

   STATE-ATOM is unchanged for a refused append. Invalid input is an error and
   is also fail-closed: no state mutation occurs before validation completes.
  "
  [state-atom operation budget]
  (when-not (instance? clojure.lang.IAtom state-atom)
    (budget-fail! budget-invalid-code-v1
                  "budget append requires an atom state" {}))
  (let [incoming (measure-routine-v1 operation)
        budget (routine-budget-v1 budget)]
    (loop []
      (let [before (state! @state-atom)
            total (add-metrics (:metrics before) incoming)
            verdict (check-routine-budget-v1 total budget)]
        (if (= :breach (:status verdict))
          {:format budget-accounting-format-v1
           :version budget-accounting-version-v1
           :status :refused
           :code budget-breach-code-v1
           :metrics incoming
           :total-metrics total
           :budget budget
           :breaches (:breaches verdict)
           :state before}
          (let [after (assoc before
                             :facts (into (:facts before)
                                          (:append-facts operation))
                             :metrics total)]
            (if (compare-and-set! state-atom before after)
              {:format budget-accounting-format-v1
               :version budget-accounting-version-v1
               :status :accepted
               :code budget-accepted-code-v1
               :metrics incoming
               :total-metrics total
               :budget budget
               :breaches []
               :state after}
              (recur))))))))
