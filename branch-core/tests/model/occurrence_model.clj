;; Pure oracle for tests/model_generative_test.clj: expected live propositions,
;; operation occurrences, targeted withdrawals, and receipts from an operation
;; sequence.
;;
;; INVARIANT: every rule here is restated from docs/architecture.md,
;; docs/concurrency-and-writes.md, and docs/guarantees.md — never transcribed
;; from fram:src/fram/store.bgl or fram:database.clj, so a divergence is evidence and not a
;; shared mistake. Depends on `fram.types` for Term construction only.
(ns occurrence-model
  (:require [fram.types :as t]))

(def tx-sequence-predicate :kernel/tx-sequence)
(def op-ordinal-predicate :kernel/op-ordinal)
(def supersedes-predicate :kernel/supersedes)

;; Metadata assertions ride the same transaction, after every source operation,
;; in this fixed predicate order.
(def metadata-order
  [:kernel/recorded-at :kernel/asserted-by :kernel/source-frame
   :kernel/supersedes])

(def ^:private metadata-source-key
  {:kernel/recorded-at :recorded-at
   :kernel/asserted-by :asserted-by
   :kernel/source-frame :source-frame
   :kernel/supersedes :supersedes})

;; ---------------------------------------------------------------- coordinates

(defn tx-coordinate [space-id sequence]
  (t/triple space-id tx-sequence-predicate sequence))

(defn occ-coordinate [tx ordinal]
  (t/triple tx op-ordinal-predicate ordinal))

(defn tx-coordinate? [value]
  (and (t/triple? value)
       (string? (t/triple-t1 value))
       (pos? (count (t/triple-t1 value)))
       (= tx-sequence-predicate (t/triple-t2 value))
       (integer? (t/triple-t3 value))
       (not (neg? (t/triple-t3 value)))))

(defn occ-coordinate? [value]
  (and (t/triple? value)
       (tx-coordinate? (t/triple-t1 value))
       (= op-ordinal-predicate (t/triple-t2 value))
       (integer? (t/triple-t3 value))
       (not (neg? (t/triple-t3 value)))))

;; Int atoms widen to Long and non-integral numbers to Double before a
;; proposition is durable, so equal-proposition identity is decided on the
;; canonical form.
(defn canonical [value]
  (cond
    (t/triple? value) (t/triple (canonical (t/triple-t1 value))
                                (canonical (t/triple-t2 value))
                                (canonical (t/triple-t3 value)))
    (integer? value) (long value)
    (t/instant? value) value
    (number? value) (double value)
    :else value))

;; --------------------------------------------------------------------- state

(defn new-model
  "OPTIONS may carry :dedupe-live-assertions? — a deliberate negation of the
   new-occurrence-per-assert contract, used only as a harness negative control."
  ([space-id] (new-model space-id nil))
  ([space-id options]
   {:space-id space-id
    :next-sequence 1
    :ops []
    :active {}
    :dedupe-live-assertions? (boolean (:dedupe-live-assertions? options))}))

(defn current-transaction [model]
  (tx-coordinate (:space-id model) (dec (:next-sequence model))))

(defn- append-operation [model {:keys [action proposition]} sequence ordinal]
  (let [position (count (:ops model))
        stack (get (:active model) proposition [])
        row {:sequence sequence :ordinal ordinal :action action
             :proposition proposition :live? (= :assert action)
             :withdrawal-target nil}]
    (if (= :assert action)
      (-> model
          (update :ops conj
                  (cond-> row
                    (and (:dedupe-live-assertions? model) (seq stack))
                    (assoc :live? false)))
          (assoc-in [:active proposition] (conj stack position)))
      (if (empty? stack)
        (update model :ops conj row)
        (let [target (peek stack)]
          (-> model
              (assoc-in [:ops target :live?] false)
              (update :ops conj (assoc row :withdrawal-target target))
              (assoc-in [:active proposition] (pop stack))))))))

;; --------------------------------------------------------------- projections

(defn- op-coordinate [model position]
  (let [row (nth (:ops model) position)]
    (occ-coordinate (tx-coordinate (:space-id model) (:sequence row))
                    (:ordinal row))))

(defn- operation-occurrence-at [model position]
  (let [row (nth (:ops model) position)]
    (t/operation-occurrence (op-coordinate model position)
                            (:action row)
                            (:proposition row))))

(defn occurrences [model]
  (mapv #(operation-occurrence-at model %) (range (count (:ops model)))))

(defn occurrences-between [model lower-exclusive upper-inclusive]
  (into []
        (comp
         (filter (fn [position]
                   (let [sequence (:sequence (nth (:ops model) position))]
                     (< lower-exclusive sequence (inc upper-inclusive)))))
         (map #(operation-occurrence-at model %)))
        (range (count (:ops model)))))

(defn withdrawals [model]
  (into []
        (comp
         (filter (fn [position]
                   (some? (:withdrawal-target (nth (:ops model) position)))))
         (map (fn [position]
                (t/withdrawal
                 (operation-occurrence-at model position)
                 (operation-occurrence-at
                  model
                  (:withdrawal-target (nth (:ops model) position)))))))
        (range (count (:ops model)))))

(defn- live-positions [model]
  (filterv #(:live? (nth (:ops model) %)) (range (count (:ops model)))))

(defn store-live-occurrences [model]
  (mapv #(operation-occurrence-at model %) (live-positions model)))

(defn store-live-propositions [model]
  (mapv #(:proposition (nth (:ops model) %)) (live-positions model)))

(defn store-live-propositions-as-of [model upper-inclusive]
  (let [{:keys [live]}
        (reduce
         (fn [{:keys [active live] :as state} position]
           (let [{:keys [sequence action proposition]} (nth (:ops model) position)]
             (if (> sequence upper-inclusive)
               state
               (let [stack (get active proposition [])]
                 (if (= :assert action)
                   {:active (assoc active proposition (conj stack position))
                    :live (conj live position)}
                   (if (empty? stack)
                     state
                     {:active (assoc active proposition (pop stack))
                      :live (disj live (peek stack))}))))))
         {:active {} :live #{}}
         (range (count (:ops model))))]
    (mapv #(:proposition (nth (:ops model) %)) (sort live))))

(defn- relation-proposition? [predicate value]
  (and (t/triple? value)
       (occ-coordinate? (t/triple-t1 value))
       (= predicate (t/triple-t2 value))
       (occ-coordinate? (t/triple-t3 value))))

(defn supersession-triples [model]
  (filterv #(relation-proposition? supersedes-predicate %)
           (store-live-propositions model)))

;; An occurrence named as the target of a live supersession proposition is no
;; longer effective, even though its store row stays live. Physical withdrawal
;; already removes the assertion from the store-live projection.
(defn- suppressed-coordinates [model]
  (into #{}
        (map t/triple-t3)
        (supersession-triples model)))

(defn live-occurrences [model]
  (let [suppressed (suppressed-coordinates model)]
    (filterv #(not (contains? suppressed
                              (t/operationoccurrence-coordinate %)))
             (store-live-occurrences model))))

(defn live-propositions [model]
  (mapv t/operationoccurrence-proposition (live-occurrences model)))

(defn occurrence [model coordinate]
  (some #(when (= coordinate (t/operationoccurrence-coordinate %)) %)
        (occurrences model)))

;; ------------------------------------------------------------------ mutation

(defn- metadata-operations [tx operations request]
  (let [per-source
        (into []
              (mapcat
               (fn [[ordinal operation]]
                 (let [source (occ-coordinate tx ordinal)]
                   (keep (fn [predicate]
                           (let [raw (get operation (metadata-source-key predicate))
                                 value (some-> raw canonical)]
                             (when (some? value)
                               {:action :assert
                                :proposition (t/triple source predicate value)})))
                         metadata-order))))
              (map-indexed vector operations))
        tx-metadata
        (cond-> []
          (:recorded-at request)
          (conj {:action :assert
                 :proposition (t/triple tx :kernel/recorded-at
                                        (canonical (:recorded-at request)))})
          (:actor request)
          (conj {:action :assert
                 :proposition (t/triple tx :kernel/asserted-by
                                        (canonical (:actor request)))}))]
    (into per-source tx-metadata)))

(defn commit
  "Model one transaction. Returns {:model model' :receipt receipt}."
  [model {:keys [operations base] :as request}]
  (let [current (current-transaction model)]
    (if (and base (not= base current))
      {:model model
       :receipt {:reject :conflict :expected base :current current}}
      (let [sequence (:next-sequence model)
            tx (tx-coordinate (:space-id model) sequence)
            source (mapv (fn [operation]
                           {:action (:action operation)
                            :proposition (canonical (:proposition operation))})
                         operations)
            all (into source (metadata-operations tx operations request))
            first-position (count (:ops model))
            committed (-> (reduce (fn [acc [ordinal operation]]
                                    (append-operation acc operation sequence ordinal))
                                  model
                                  (map-indexed vector all))
                          (assoc :next-sequence (inc sequence)))
            source-positions (range first-position
                                    (+ first-position (count source)))
            coordinates (into #{} (map #(op-coordinate committed %)) source-positions)]
        {:model committed
         :receipt {:ok tx
                   :occurrences (mapv #(operation-occurrence-at committed %)
                                      source-positions)
                   :withdrawals
                   (filterv #(contains?
                              coordinates
                              (t/operationoccurrence-coordinate
                               (t/withdrawal-retraction %)))
                            (withdrawals committed))
                   :operation-count (count all)}}))))

(defn assert-proposition [model proposition options]
  (commit model (assoc options :operations
                       [{:action :assert :proposition proposition
                         :supersedes (:supersedes options)
                         :source-frame (:source-frame options)}])))

(defn retract-proposition [model proposition options]
  (commit model (assoc options :operations
                       [{:action :retract :proposition proposition
                         :source-frame (:source-frame options)}])))

(defn withdraw-occurrence [model target options]
  (let [event (occurrence model target)
        effective (into #{} (map t/operationoccurrence-coordinate)
                        (live-occurrences model))]
    (cond
      (nil? event)
      {:model model :receipt {:reject :unknown-occurrence :occurrence target}}

      (not= :assert (t/operationoccurrence-action event))
      {:model model :receipt {:reject :not-assertion-occurrence :occurrence target}}

      (not (contains? effective target))
      {:model model :receipt {:reject :occurrence-not-live :occurrence target}}

      :else
      ;; The public target must be the same occurrence a bare retract would
      ;; withdraw: the latest store-live equal one.
      (let [proposition (t/operationoccurrence-proposition event)
            matching (filterv #(= proposition
                                  (t/operationoccurrence-proposition %))
                              (store-live-occurrences model))
            current (some-> (peek matching)
                            t/operationoccurrence-coordinate)]
        (if (not= target current)
          {:model model
           :receipt {:reject :withdrawal-target-not-current
                     :occurrence target :current current}}
          (retract-proposition model proposition options))))))

(defn supersede [model target replacement options]
  (if-not (some #{target} (map t/operationoccurrence-coordinate
                               (live-occurrences model)))
    {:model model :receipt {:reject :occurrence-not-live :occurrence target}}
    (assert-proposition model replacement (assoc options :supersedes target))))
