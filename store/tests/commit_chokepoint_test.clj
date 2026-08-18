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
      before (store/operation-count ctx)
      coordinate (store/commit-boundary!
                  ctx
                  [(store/assert-operation proposition)]
                  metadata)]
  (check! "public writes land through the boundary"
          (and (= 1 (store/operation-count ctx))
               (= 1 (store/transaction-count ctx))
               (t/transaction-coordinate? coordinate)))
  (check! "a rejected metadata envelope writes nothing"
          (= :canonical-commit-rejected
             (try
               (store/commit-boundary!
                ctx
                [(store/assert-operation (t/triple "s2" "p" "v2"))]
                (assoc metadata :producer ""))
               nil
               (catch clojure.lang.ExceptionInfo e (:type (ex-data e))))))
  (check! "rejection leaves the operation count unchanged"
          (= (inc before) (store/operation-count ctx))))

(let [ctx (store/new-term-store "commit-seam")
      seen (atom [])
      original store/commit-boundary!
      builder (txn/open ctx)]
  (txn/assert! builder (t/triple "seam" "p" "v"))
  (with-redefs [store/commit-boundary!
                (fn [root operations metadata]
                  (swap! seen conj metadata)
                  (original root operations metadata))]
    (txn/commit! ctx builder))
  (let [metadata (first @seen)
        attestation (t/commitmetadata-validation-attestation metadata)]
    (check! "transaction builder cannot bypass the boundary"
            (and (= 1 (count @seen))
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
