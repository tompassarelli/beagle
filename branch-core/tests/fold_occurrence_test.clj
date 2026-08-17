;; Transaction-frame fold over exact assertion occurrences.
;;   env -u FRAM_TELEMETRY_LOG bb -cp out tests/fold_occurrence_test.clj
(require '[fram.fold :as fold]
         '[fram.store :as store]
         '[fram.types :as t])

(defn error-type [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))

(def proposition (t/triple "Alice" :email "alice@example.com"))
(def nested (t/triple proposition :reported-by (t/triple "CRM" :batch 71)))

(def frames
  [(fold/transaction-frame
    10 [(store/assert-operation proposition)
        (store/assert-operation proposition)
        (store/assert-operation nested)])
   (fold/transaction-frame 12 [(store/retract-operation proposition)])])

(def result (fold/fold! "msa-space" frames))
(def refolded (fold/refold! "msa-space" (:dump result)))
(def occurrences (:occurrences result))
(def withdrawals (:withdrawals result))
(def live-occurrences (:live-occurrences result))
(def live-propositions (:live-propositions result))
(def live-proposition-events
  (filterv #(= proposition (t/operationoccurrence-proposition %))
           live-occurrences))

(def checks
  [["fold preserves SpaceId" (= "msa-space" (:space-id result))]
   ["fold version is exact logical transaction sequence" (= 12 (:version result))]
   ["transaction sequence gaps do not fabricate transactions"
    (= 2 (count (t/termstoredump-transactions (:dump result))))]
   ["max-sequence reads logical coordinates" (= 12 (fold/max-sequence frames))]
   ["equal proposition occurrences remain separately addressable"
    (let [events (filterv t/assertion-occurrence?
                          (filterv
                           #(= proposition
                               (t/operationoccurrence-proposition %))
                           (take 2 occurrences)))]
      (and (= 2 (count events))
           (not= (t/operationoccurrence-coordinate (first events))
                 (t/operationoccurrence-coordinate (second events)))))]
   ["one retraction removes only the latest equal occurrence"
    (= 1 (count live-proposition-events))]
   ["unrelated nested proposition remains live"
    (= [proposition nested] live-propositions)]
   ["history keeps operation occurrences and withdrawals outside Term"
    (and (= 4 (count occurrences))
         (= 1 (count withdrawals))
         (every? t/operation-occurrence? occurrences)
         (every? t/withdrawal? withdrawals)
         (not-any? t/term? (concat occurrences withdrawals)))]
   ["withdrawal points to the second assertion coordinate"
    (let [withdrawal (first withdrawals)]
      (= (t/occurrence-coordinate (t/transaction-coordinate "msa-space" 10) 1)
         (t/operationoccurrence-coordinate
          (t/withdrawal-assertion withdrawal))))]
   ["dump refold is projection-identical"
    (and (= (:occurrences result) (:occurrences refolded))
         (= (:withdrawals result) (:withdrawals refolded))
         (= (:live-occurrences result) (:live-occurrences refolded))
         (= (:live-propositions result) (:live-propositions refolded))
         (= (:version result) (:version refolded)))]
   ["out-of-order frames are rejected by occurrence order"
    (= :nonmonotonic-transaction-sequence
       (error-type #(fold/fold!
                     "msa-space"
                     [(fold/transaction-frame 12 [(store/assert-operation proposition)])
                      (fold/transaction-frame 10 [(store/assert-operation nested)])])))]
   ["dump refold cannot silently change spaces"
    (= :space-mismatch
       (error-type #(fold/refold! "other-space" (:dump result))))]])

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\noccurrence fold:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\noccurrence fold:" (count failures) "FAILED")
      (System/exit 1))))
