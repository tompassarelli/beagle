;; Deterministic proof of the Store commit chokepoint.
;;   bb -cp out tests/commit_chokepoint_test.clj
(require '[store.store :as store]
         '[store.txn :as txn]
         '[store.types :as t])

(def checks (atom []))
(defn check! [label ok] (swap! checks conj [label (boolean ok)]))

(check! "raw append primitive is module-private"
        (not (contains? (set (keys (ns-publics 'store.store)))
                        'append-transaction!)))

(let [metadata (store/commit-metadata "test.chokepoint/v1"
                                     "store/CommitOperationV1"
                                     "test-profile-v1")]
  (check! "metadata carries producer, shape/schema, profile, and validation"
          (and (t/commit-metadata? metadata)
               (= "test.chokepoint/v1" (t/commitmetadata-producer metadata))
               (= "store/CommitOperationV1"
                  (t/commitmetadata-shape-schema-id metadata))
               (= "test-profile-v1" (t/commitmetadata-profile metadata))
               (t/commit-validation-attestation?
                (t/commitmetadata-validation-attestation metadata)))))

(let [ctx (store/new-term-store "commit-chokepoint")
      proposition (t/triple "subject" "predicate" "value")
      metadata (store/commit-metadata "test.boundary/v1"
                                     "store/CommitOperationV1"
                                     nil)
      expected (store/next-sequence ctx)
      success (store/commit-boundary!
               ctx expected
               [(store/assert-operation proposition)]
               metadata)
      after-success (store/dump-term-store ctx)
      stale (store/commit-boundary!
             ctx expected
             [(store/assert-operation (t/triple "stale" "p" "v"))]
             metadata)
      after-stale (store/dump-term-store ctx)
      invalid (store/commit-boundary!
               ctx (store/next-sequence ctx)
               [(store/assert-operation (t/triple "invalid" "p" "v"))]
               (assoc metadata :producer ""))
      after-invalid (store/dump-term-store ctx)]
  (check! "matching expected sequence appends exactly once"
          (and (instance? store.store.CommitSuccess success)
               (= (t/transaction-coordinate "commit-chokepoint" expected)
                  (store/commitsuccess-coordinate success))
               (= 1 (store/operation-count ctx))
               (= 1 (store/transaction-count ctx))))
  (check! "stale expected sequence returns observed drift and appends nothing"
          (and (instance? store.store.CommitStale stale)
               (= expected (store/commitstale-expected-sequence stale))
               (= (inc expected) (store/commitstale-observed-sequence stale))
               (= after-success after-stale)))
  (check! "invalid metadata returns rejection and appends nothing"
          (and (instance? store.store.CommitRejected invalid)
               (= :canonical-commit-rejected
                  (store/commitrejected-code invalid))
               (= after-stale after-invalid))))

(let [ctx (store/new-term-store "commit-seam")
      seen (atom [])
      original store/commit-boundary!
      builder (txn/open ctx)]
  (txn/assert! builder (t/triple "seam" "p" "v"))
  (with-redefs [store/commit-boundary!
                (fn [root expected operations metadata]
                  (swap! seen conj [expected metadata])
                  (original root expected operations metadata))]
    (txn/commit! ctx builder))
  (let [[expected metadata] (first @seen)
        attestation (t/commitmetadata-validation-attestation metadata)]
    (check! "transaction builder cannot bypass the boundary"
            (and (= 1 (count @seen))
                 (= 1 expected)
                 (t/commit-metadata? metadata)
                 (= "store.txn/v1" (t/commitmetadata-producer metadata))
                 (= :pending (t/commitvalidationattestation-result attestation))))))

(let [failures (remove second @checks)]
  (doseq [[label ok] @checks]
    (println (if ok "  [PASS] " "  [FAIL] ") label))
  (if (empty? failures)
    (println (str "\nStore commit chokepoint: " (count @checks) " / "
                  (count @checks) " PASS"))
    (do
      (println (str "\nStore commit chokepoint: " (count failures) " FAILED"))
      (System/exit 1))))
