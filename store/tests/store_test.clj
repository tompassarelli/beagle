;; Authoritative TermStore occurrence history.
;;   env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp out tests/store_test.clj
(require '[store.store :as store]
         '[store.types :as t])

(defn error-type [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))

(def proposition (t/triple "Alice" :contactable_at "alice@example.com"))
(def nested-proposition
  (t/triple (t/triple "Alice" :account "primary")
            (t/triple :slot "email" 2)
            (t/triple "alice@example.com" :observed-at (t/instant 1785561000 7))))

(def ctx (store/new-term-store "msa-space"))

;; Equal content may occur more than once. The transaction-local ordinals, not
;; the shared private content handle, distinguish the two assertions.
(def tx1
  (store/commit-transaction!
   ctx [(store/assert-operation proposition)
        (store/assert-operation proposition)]))
(def assertions-after-tx1 (store/live-occurrences ctx))
(def first-assertion (nth assertions-after-tx1 0))
(def second-assertion (nth assertions-after-tx1 1))
(def first-coordinate (t/operationoccurrence-coordinate first-assertion))
(def second-coordinate (t/operationoccurrence-coordinate second-assertion))

;; Retractions withdraw the most recent live occurrence of equal content.
(def tx2 (store/commit-transaction! ctx [(store/retract-operation proposition)]))
(def live-after-first-retract (store/live-occurrences ctx))
(def withdrawals-after-first-retract (store/withdrawals ctx))

(def tx3 (store/commit-transaction! ctx [(store/retract-operation proposition)]))
(def live-after-second-retract (store/live-occurrences ctx))
(def withdrawals-after-second-retract (store/withdrawals ctx))

;; A retraction with no live target remains an exact history occurrence but
;; does not invent a withdrawal edge.
(def tx4 (store/commit-transaction! ctx [(store/retract-operation proposition)]))
(def occurrences-after-noop (store/occurrences ctx))
(def withdrawals-after-noop (store/withdrawals ctx))

(def tx5 (store/commit-transaction! ctx [(store/assert-operation nested-proposition)]))
(def dump (store/dump-term-store ctx))
(def occurrences (store/occurrences ctx))
(def withdrawals (store/withdrawals ctx))
(def withdrawal-window
  (store/withdrawal-tuples-between (deref ctx) 2 3))
(def historical-records-result
  (store/transaction-records-between-result (deref ctx) -1 5))

(def corrupt-operation-store
  (assoc (deref ctx) :operations
         (atom (assoc (deref (t/termstore-operations (deref ctx))) 0
                      (assoc (first (deref (t/termstore-operations (deref ctx))))
                             :triple-handle 0)))))
(def corrupt-operation-records
  (store/transaction-records-between-result corrupt-operation-store -1 5))

(def corrupt-triple-store
  (assoc (deref ctx) :triples
         (atom (assoc (deref (t/termstore-triples (deref ctx))) 0
                      (assoc (first (deref (t/termstore-triples (deref ctx))))
                             :t1 999999)))))
(def corrupt-triple-records
  (store/transaction-records-between-result corrupt-triple-store -1 5))

(def corrupt-history-store
  (assoc (deref ctx) :operations
         (atom (assoc (deref (t/termstore-operations (deref ctx))) 0
                      (assoc (first (deref (t/termstore-operations (deref ctx))))
                             :action :invalid)))))
(def corrupt-history-records
  (store/transaction-records-between-result corrupt-history-store -1 5))

(def replay-outcome-context (store/new-term-store "replay-outcome-space"))
(def successful-replay
  (store/replay-transaction-result!
   replay-outcome-context
   (store/transaction-record 3 [(store/assert-operation proposition)])))
(def replay-before-rejection (store/dump-term-store replay-outcome-context))
(def rejected-replay
  (store/replay-transaction-result!
   replay-outcome-context
   (store/transaction-record
    2 [(store/assert-operation
        (t/triple "Bob" :email "bob@example.com"))])))
(def overflow-replay
  (store/replay-transaction-result!
   replay-outcome-context
   (store/transaction-record
    9223372036854775807
    [(store/assert-operation (t/triple "Max" :sequence "overflow"))])))
(def invalid-replay
  (store/replay-transaction-result!
   replay-outcome-context (t/->TransactionRecord -1 [])))

(def restored (store/new-term-store "msa-space"))
(store/load-term-store! restored dump)

(def outcome-restored (store/new-term-store "msa-space"))
(def successful-load (store/load-term-store-result! outcome-restored dump))

(def wrong-space (store/new-term-store "other-space"))
(def first-row (first (t/termstoredump-operations dump)))
(def malformed-ordinal
  (assoc dump :operations
         (assoc (t/termstoredump-operations dump) 0
                (t/->OperationRow
                 (t/operationrow-tx-sequence first-row)
                 9
                 (t/operationrow-action first-row)
                 (t/operationrow-triple-handle first-row)))))
(def malformed-next-sequence (assoc dump :next-sequence 99))
(def malformed-target (store/new-term-store "msa-space"))
(def malformed-before (store/dump-term-store malformed-target))
(def malformed-load
  (store/load-term-store-result! malformed-target malformed-next-sequence))

(def growth-context (store/new-term-store "growth-space"))
(def growth-propositions
  (mapv #(t/triple :entry % (t/triple % :parity (odd? %))) (range 257)))
(store/commit-transaction! growth-context
                           (mapv store/assert-operation growth-propositions))
(def growth-live-count (count (store/live-occurrences growth-context)))
(store/commit-transaction! growth-context
                           (mapv store/retract-operation growth-propositions))
(def growth-dump (store/dump-term-store growth-context))
(def growth-restored (store/new-term-store "growth-space"))
(store/load-term-store! growth-restored growth-dump)

;; A fork taken during a fused replay owns its nested liveness cells. The two
;; writers then reuse the same private row positions through shared append-only
;; slot candidates; full-row and full-handle confirmation keeps them isolated.
(def fork-proposition (t/triple "fork" :state "shared"))
(def fork-parent-only (t/triple "fork" :parent "only"))
(def fork-child-only (t/triple "fork" :child "only"))
(def fork-parent (store/new-term-store "fork-space"))
(store/commit-transaction! fork-parent
                           [(store/assert-operation fork-proposition)])
(store/open-fold! fork-parent)
(def fork-child (store/fork-store fork-parent))
(store/commit-transaction! fork-child
                           [(store/retract-operation fork-proposition)])
(def fork-parent-after-child-version (store/current-sequence fork-parent))
(def fork-parent-after-child-live (store/live-propositions fork-parent))
(store/commit-transaction! fork-child
                           [(store/assert-operation fork-child-only)])
(store/commit-transaction! fork-parent
                           [(store/assert-operation fork-parent-only)])
(store/close-fold! fork-parent)
(store/close-fold! fork-child)

(def checks
  [["store carries immutable SpaceId" (= "msa-space" (store/space-id ctx))]
   ["first commit receives logical transaction sequence 1"
    (= (t/transaction-coordinate "msa-space" 1) tx1)]
   ["two equal assertions have different occurrence coordinates"
    (and (not= first-coordinate second-coordinate)
         (= (t/occurrence-coordinate tx1 0) first-coordinate)
         (= (t/occurrence-coordinate tx1 1) second-coordinate))]
   ["two equal assertions preserve the same proposition"
    (and (= proposition (t/operationoccurrence-proposition first-assertion))
         (= proposition (t/operationoccurrence-proposition second-assertion)))]
   ["first retraction withdraws the most recent matching occurrence"
    (and (= [first-assertion] live-after-first-retract)
         (= 1 (count withdrawals-after-first-retract))
         (= second-coordinate
            (t/operationoccurrence-coordinate
             (t/withdrawal-assertion
              (first withdrawals-after-first-retract)))))]
   ["second retraction withdraws the earlier matching occurrence"
    (and (empty? live-after-second-retract)
         (= 2 (count withdrawals-after-second-retract))
         (= first-coordinate
            (t/operationoccurrence-coordinate
             (t/withdrawal-assertion
              (second withdrawals-after-second-retract)))))]
   ["no-target retraction is history without a fabricated withdrawal"
    (and (= 5 (count occurrences-after-noop))
         (= 2 (count withdrawals-after-noop)))]
   ["nested Triple terms survive as a live proposition"
    (= [nested-proposition] (store/live-propositions ctx))]
   ["physical transaction rows preserve record boundaries"
    (and (= 5 (store/transaction-count ctx))
         (= 6 (store/operation-count ctx))
         (= [0 2 3 4 5]
            (mapv t/transactionrow-first-operation
                  (t/termstoredump-transactions dump)))
         (= [2 1 1 1 1]
            (mapv t/transactionrow-operation-count
                  (t/termstoredump-transactions dump))))]
   ["operation ordinals are contiguous inside each transaction"
    (= [0 1 0 0 0 0]
       (mapv t/operationrow-ordinal (t/termstoredump-operations dump)))]
   ["physical operation identity contains no wall-clock field"
    (= #{:tx-sequence :ordinal :action :triple-handle}
       (set (keys first-row)))]
   ["history projection uses non-Term system records"
    (and (every? t/operation-occurrence? occurrences)
         (every? t/withdrawal? withdrawals)
         (not-any? t/term? occurrences)
         (not-any? t/term? withdrawals))]
   ["withdrawal/2 windows on the retraction and projects coordinates"
    (= [[(t/occurrence-coordinate tx3 0) first-coordinate]]
       withdrawal-window)]
   ["typed historical record outcomes reject corrupt state before resolution"
    (and (store/transactionrecordsresult-ok historical-records-result)
         (= (store/transaction-records-between (deref ctx) -1 5)
            (store/transactionrecordsresult-records historical-records-result))
         (= :invalid-operation-handle
            (store/transactionrecordsresult-code corrupt-operation-records))
         (= :invalid-term-handle
            (store/transactionrecordsresult-code corrupt-triple-records))
         (= :invalid-transaction-record
            (store/transactionrecordsresult-code corrupt-history-records)))]
   ["typed replay outcomes validate before mutation and preserve errors"
    (and (store/transactionreplayresult-ok successful-replay)
         (= 3 (store/current-sequence replay-outcome-context))
         (not (store/transactionreplayresult-ok rejected-replay))
         (= :nonmonotonic-transaction-sequence
            (store/transactionreplayresult-code rejected-replay))
         (= "store: transaction sequence must advance within its space"
            (store/transactionreplayresult-message rejected-replay))
         (= replay-before-rejection
            (store/dump-term-store replay-outcome-context))
         (not (store/transactionreplayresult-ok overflow-replay))
         (nil? (store/transactionreplayresult-code overflow-replay))
         (nil? (store/transactionreplayresult-message overflow-replay))
         (= :invalid-transaction-record
            (store/transactionreplayresult-code invalid-replay)))]
   ["dump carries SpaceId and the next logical sequence"
    (and (= "msa-space" (t/termstoredump-space-id dump))
         (= 6 (t/termstoredump-next-sequence dump)))]
   ["dump/load preserves authoritative rows exactly"
    (= dump (store/dump-term-store restored))]
   ["dump/load rebuilds identical system history"
    (and (= occurrences (store/occurrences restored))
         (= withdrawals (store/withdrawals restored))
         (= (store/live-occurrences ctx) (store/live-occurrences restored)))]
   ["typed load outcomes preserve success and reject before mutation"
    (and (store/termstoreloadresult-ok successful-load)
         (nil? (store/termstoreloadresult-code successful-load))
         (= dump (store/dump-term-store outcome-restored))
         (not (store/termstoreloadresult-ok malformed-load))
         (= :invalid-term-store-dump
            (store/termstoreloadresult-code malformed-load))
         (= malformed-before (store/dump-term-store malformed-target)))]
   ["a dump cannot cross SpaceId boundaries"
    (= :space-mismatch (error-type #(store/load-term-store! wrong-space dump)))]
   ["malformed transaction-local ordinals are rejected"
    (= :invalid-term-store-dump
       (error-type #(store/load-term-store! (store/new-term-store "msa-space")
                                            malformed-ordinal)))]
   ["dump next-sequence must name the exact successor coordinate"
    (= :invalid-term-store-dump
       (error-type #(store/load-term-store! (store/new-term-store "msa-space")
                                            malformed-next-sequence)))]
   ["raw operation rows cannot smuggle an Atom in place of a Triple"
    (= :invalid-transaction-record
       (error-type #(store/transaction-record
                     6 [(t/->CommitOperation t/assert-action "not-a-triple")])))]
   ["active occurrence index growth preserves exact withdrawal state"
    (and (= 257 growth-live-count)
         (empty? (store/live-occurrences growth-context))
         (= 257 (count (store/withdrawals growth-context)))
         (= growth-dump (store/dump-term-store growth-restored))
         (= (store/occurrences growth-context)
            (store/occurrences growth-restored))
         (= (store/withdrawals growth-context)
            (store/withdrawals growth-restored)))]
   ["a fold-open child cannot change its parent's version or liveness"
    (and (= 1 fork-parent-after-child-version)
         (= [fork-proposition] fork-parent-after-child-live))]
   ["divergent forks isolate liveness while reusing private row positions"
    (and (= 2 (store/current-sequence fork-parent))
         (= 3 (store/current-sequence fork-child))
         (= #{fork-proposition fork-parent-only}
            (set (store/live-propositions fork-parent)))
         (= #{fork-child-only}
            (set (store/live-propositions fork-child))))]
   ["replay rejects nonmonotonic transaction coordinates"
    (= :nonmonotonic-transaction-sequence
       (error-type #(store/replay-transaction!
                     restored
                     (store/transaction-record 5 [(store/assert-operation proposition)]))))]])

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\nTermStore occurrence history:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\nTermStore occurrence history:" (count failures) "FAILED")
      (System/exit 1))))
