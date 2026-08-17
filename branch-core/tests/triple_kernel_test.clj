;; Recursive Term/Triple kernel: uniform slots, structural identity, occurrence
;; coordinates, and portable store round-trip.
;;   env -u FRAM_TELEMETRY_LOG bb -cp out tests/triple_kernel_test.clj
(require '[fram.types :as t]
         '[fram.store :as store]
         '[fram.kernel :as kernel])

(defn error-type [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo e (:type (ex-data e)))))

(def instant (t/instant 1785560000 123456789))
(def proposition-a (t/triple "Alice" :contactable_at "alice@example.com"))
(def proposition-b (t/triple "Alice" :contactable_at "alice@example.com"))

;; A Triple may occupy every slot. `/` inside a keyword is spelling only: it
;; asserts no grouping and gets no kernel behavior, which is what the probe atom
;; below is here to hold.
(def nested-t1 (t/triple proposition-a :not-a/grouping "t1"))
(def nested-t2 (t/triple "t2" proposition-a true))
(def nested-t3 (t/triple :t3 42 proposition-a))
(def nested-all (t/triple nested-t1 nested-t2 nested-t3))

(def tx-1842 (t/transaction-coordinate "msa-space" 1842))
(def tx-1843 (t/transaction-coordinate "msa-space" 1843))
(def other-space-tx (t/transaction-coordinate "north-telemetry" 1842))
(def occurrence-0 (t/occurrence-coordinate tx-1842 0))
(def occurrence-1 (t/occurrence-coordinate tx-1842 1))
(def occurrence-2 (t/occurrence-coordinate tx-1842 2))
(def occurrence-next-tx (t/occurrence-coordinate tx-1843 0))
(def other-space-occurrence (t/occurrence-coordinate other-space-tx 0))

(def assertion-0
  (t/operation-occurrence occurrence-0 t/assert-action proposition-a))
(def assertion-1
  (t/operation-occurrence occurrence-1 t/assert-action proposition-b))
(def retraction-2
  (t/operation-occurrence occurrence-2 t/retract-action proposition-b))
(def withdrawal-1 (t/withdrawal retraction-2 assertion-1))
(def mismatched-retraction
  (t/operation-occurrence occurrence-2 t/retract-action nested-all))
(def recorded (t/recorded-at occurrence-0 instant))

(def terms
  [nested-all recorded (t/triple 1.5 :float "roundtrip")])

(def term-store (store/new-term-store "triple-kernel-test"))
(store/replay-terms! term-store terms)
(def first-count (store/term-count term-store))
(def first-dump (store/dump-term-store term-store))
(def second-dump (store/dump-term-store term-store))

(def restored (store/new-term-store "triple-kernel-test"))
(store/load-term-store! restored first-dump)
(def restored-count (store/term-count restored))
(def canonical-recorded (store/intern-term! restored recorded))
(def count-after-reintern (store/term-count restored))

(def malformed-row
  (t/->TermStoreDump
   2
   "triple-kernel-test"
   1
   (t/termstoredump-atoms first-dump)
   (conj (t/termstoredump-triples first-dump) (t/->TripleRow 999999 0 0))
   (t/termstoredump-transactions first-dump)
   (t/termstoredump-operations first-dump)))

(def collision-store (store/new-term-store "collision-test"))
(def collision-row-a (t/->AtomRow :string "Aa" nil nil nil nil nil))
(def collision-row-b (t/->AtomRow :string "BB" nil nil nil nil nil))
(store/replay-terms! collision-store ["Aa" "BB" "Aa"])

(def growth-store (store/new-term-store "growth-test"))
(store/replay-terms! growth-store (vec (range 257)))
(def growth-count (store/term-count growth-store))
(store/intern-term! growth-store 256)

(def checks
  [["Atom includes portable Instant" (and (t/atom? instant) (= 123456789 (t/instant-nanos instant)))]
   ["Atom rejects compound legacy containers" (and (not (t/atom? [1 2 3])) (not (t/term? nil)))]
   ["Triple recursively accepts Triple in t1" (= proposition-a (t/triple-t1 nested-t1))]
   ["Triple recursively accepts Triple in t2" (= proposition-a (t/triple-t2 nested-t2))]
   ["Triple recursively accepts Triple in t3" (= proposition-a (t/triple-t3 nested-t3))]
   ["nested Triple remains a Term" (t/term? nested-all)]
   ["namespaced atoms carry no special slot behavior" (= :not-a/grouping (t/triple-t2 nested-t1))]
   ["equal proposition content is structural identity" (= proposition-a proposition-b)]
   ["transaction coordinate is an ordinary Triple"
    (= tx-1842 (t/triple "msa-space" :kernel/tx-sequence 1842))]
   ["occurrence coordinate is an ordinary nested Triple"
    (= occurrence-1 (t/triple tx-1842 :kernel/op-ordinal 1))]
   ["same proposition has distinct occurrence coordinates"
    (not= (t/operationoccurrence-coordinate assertion-0)
          (t/operationoccurrence-coordinate assertion-1))]
   ["assertion occurrence carries proposition unchanged"
    (and (= proposition-a (t/operationoccurrence-proposition assertion-0))
         (= :assert (t/operationoccurrence-action assertion-0)))]
   ["ordinal orders occurrences within a transaction" (t/occurrence-before? occurrence-0 occurrence-1)]
   ["transaction sequence orders occurrences within a space" (t/occurrence-before? occurrence-1 occurrence-next-tx)]
   ["different spaces have no shared order"
    (= :incomparable-occurrence-spaces
       (error-type #(t/occurrence-before? occurrence-0 other-space-occurrence)))]
   ["wall clock is ordinary metadata, not occurrence identity"
    (and (= occurrence-0 (t/triple-t1 recorded))
         (= :kernel/recorded-at (t/triple-t2 recorded))
         (= instant (t/triple-t3 recorded)))]
   ["history records are not semantic Terms"
    (and (t/operation-occurrence? assertion-0)
         (t/retraction-occurrence? retraction-2)
         (t/withdrawal? withdrawal-1)
         (not (t/term? assertion-0))
         (not (t/term? withdrawal-1)))]
   ["withdrawal binds a later retraction to the same assertion"
    (and (= retraction-2 (t/withdrawal-retraction withdrawal-1))
         (= assertion-1 (t/withdrawal-assertion withdrawal-1)))]
   ["withdrawal rejects different proposition content"
    (= :invalid-withdrawal
       (error-type #(t/withdrawal mismatched-retraction assertion-1)))]
   ["withdrawal rejects a retraction that does not follow its assertion"
    (= :invalid-withdrawal
       (error-type
        #(t/withdrawal
          (t/operation-occurrence occurrence-0 t/retract-action proposition-a)
          assertion-1)))]
   ["slot-addressed query assigns no positional roles"
    (and (= [nested-t1] (kernel/by-t1 [nested-t1 nested-t2 nested-t3]
                                           proposition-a))
         (= [nested-t2] (kernel/by-t2 [nested-t1 nested-t2 nested-t3]
                                           proposition-a))
         (= [nested-t3] (kernel/by-t3 [nested-t1 nested-t2 nested-t3]
                                           proposition-a)))]
   ["replay interns a finite structural store" (pos? first-count)]
   ["dump is deterministic" (= first-dump second-dump)]
   ["dump/load preserves every AtomRow and TripleRow" (= first-dump (store/dump-term-store restored))]
   ["dump/load preserves term count" (= first-count restored-count)]
   ["re-interning equal structure does not mint rows" (= restored-count count-after-reintern)]
   ["re-interned Instant metadata resolves structurally" (= recorded canonical-recorded)]
   ["hash collision is checked against full AtomRow structure"
    (and (= (hash collision-row-a) (hash collision-row-b))
         (= 2 (store/atom-term-count collision-store)))]
   ["slot index growth preserves every structural atom"
    (and (= 257 growth-count) (= growth-count (store/term-count growth-store)))]
   ["invalid Instant precision is typed"
    (= :invalid-instant (error-type #(t/instant 0 1000000000)))]
   ["invalid space is typed"
    (= :invalid-transaction-coordinate (error-type #(t/transaction-coordinate "" 1)))]
   ["dangling physical handles are rejected on load"
    (= :invalid-term-store-dump
       (error-type #(store/load-term-store!
                     (store/new-term-store "triple-kernel-test") malformed-row)))]] )

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\nrecursive triple kernel:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\nrecursive triple kernel:" (count failures) "FAILED")
      (System/exit 1))))
