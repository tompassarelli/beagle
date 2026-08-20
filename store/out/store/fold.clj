(ns store.fold
  (:require [store.store :as store]
            [store.types :as t]))

(defrecord Fold [space-id occurrences withdrawals live-occurrences live-propositions version dump])

(defn fold-space-id [r] (:space-id r))

(defn fold-occurrences [r] (:occurrences r))

(defn fold-withdrawals [r] (:withdrawals r))

(defn fold-live-occurrences [r] (:live-occurrences r))

(defn fold-live-propositions [r] (:live-propositions r))

(defn fold-version [r] (:version r))

(defn fold-dump [r] (:dump r))

(defn transaction-record [sequence operations]
  (store/transaction-record sequence operations))

(defn max-sequence [records]
  (reduce (fn [maximum record] (let [sequence (t/transactionrecord-sequence record)]
  (if (> sequence maximum) sequence maximum))) 0 records))

(defn- ^Fold project [ctx]
  (->Fold (store/space-id ctx) (store/occurrences ctx) (store/withdrawals ctx) (store/live-occurrences ctx) (store/live-propositions ctx) (store/current-sequence ctx) (store/dump-term-store ctx)))

(defn ^Fold fold! [^String space-id records]
  (let [ctx (store/new-term-store space-id)]
  (doseq [record records]
  (store/replay-transaction! ctx record))
  (project ctx)))

(defn ^Fold refold! [^String space-id dump]
  (let [ctx (store/new-term-store space-id)]
  (store/load-term-store! ctx dump)
  (project ctx)))
