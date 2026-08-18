;; SP5 cold fallback: every declared Store failure performs one bounded cold
;; transition without mutation and returns the Store-disabled compiler output.
(require '[clojure.edn :as edn])

(load-file "cold_fallback.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(def route
  {:factStoreSpaceId "store-space-v1"
   :requestedSnapshotId "snapshot-v1"
   :requestedBranchRevisionId "branch-revision-v1"
   :probeDeadlineClass "interactive-v1"})
(def input {:source-bytes [40 43 32 49 32 50 41] :store-route route})
(def failures
  (edn/read-string (slurp "tests/fixtures/sp5-cold/failures.edn")))
(defn compile-cold [compiler-input]
  {:status :pass :artifact (:source-bytes compiler-input)})
(def baseline
  (cold-fallback/store-disabled-baseline-v1! compile-cold input))

(check! "StoreAvailabilityReceiptV1 public identifiers are frozen"
        (and (= 1 cold-fallback/store-availability-version-v1)
             (= "beagle.store/StoreAvailabilityReceiptV1"
                cold-fallback/store-availability-format-v1)
             (= [:receiptId :factStoreSpaceId :requestedSnapshotId
                 :requestedBranchRevisionId :probeDeadlineClass :mode
                 :failureClass :fallbackMode :maintenanceStatus]
                cold-fallback/store-availability-receipt-fields-v1)
             (= ["ONLINE" "COLD" "DEGRADED"]
                cold-fallback/store-availability-modes-v1)
             (= ["NONE" "UNREACHABLE" "QUEUE-DEADLINE" "CORRUPT"
                 "TORN-TAIL" "PARTIAL-COMMIT" "BUDGET" "STALE-REVISION"
                 "DURABILITY-UNKNOWN"]
                cold-fallback/store-failure-classes-v1)
             (ifn? cold-fallback/store-availability-receipt-v1)
             (ifn? cold-fallback/store-disabled-baseline-v1!)
             (ifn? cold-fallback/run-with-cold-fallback-v1!)))

(doseq [{:keys [case failure mode failure-class maintenance-status]} failures]
  (let [probes (atom 0)
        compiles (atom 0)
        transitions (atom [])
        store-mutations (atom 0)
        result
        (cold-fallback/run-with-cold-fallback-v1!
         {:input input
          :probe-deadline-ms 100
          :probe! (fn [_]
                    (swap! probes inc)
                    {:status :failure :failure failure})
          :cold-compile! (fn [value]
                           (swap! compiles inc)
                           (compile-cold value))
          :transition! #(swap! transitions conj %)})
        receipt (:availability-receipt result)]
    (check! (str (name case) " makes one cold transition and one compiler call")
            (and (= 1 @probes)
                 (= 1 @compiles)
                 (= 1 (count @transitions))
                 (= :cold (:phase (first @transitions)))
                 (= case (:failure (first @transitions)))))
    (check! (str (name case) " returns the Store-disabled baseline")
            (and (= baseline (:output result))
                 (= :cold (:source result))
                 (false? (:fact-backed? result))
                 (zero? @store-mutations)))
    (check! (str (name case) " records the exact conservative receipt")
            (and (= mode (:mode receipt))
                 (= failure-class (:failureClass receipt))
                 (= "COLD-COMPILATION" (:fallbackMode receipt))
                 (= maintenance-status (:maintenanceStatus receipt))
                 (re-matches #"sha256:[0-9a-f]{64}" (:receiptId receipt))))))

(let [probes (atom 0)
      compiles (atom 0)
      transitions (atom [])
      started (System/nanoTime)
      result
      (cold-fallback/run-with-cold-fallback-v1!
       {:input input
        :probe-deadline-ms 20
        :probe! (fn [_]
                  (swap! probes inc)
                  (Thread/sleep 5000)
                  {:status :online :output :too-late})
        :cold-compile! (fn [value]
                         (swap! compiles inc)
                         (compile-cold value))
        :transition! #(swap! transitions conj %)})
      elapsed-ms (/ (- (System/nanoTime) started) 1000000.0)]
  (check! "a blocked adapter is cut off at the probe deadline without retry"
          (and (= 1 @probes)
               (= 1 @compiles)
               (= 1 (count @transitions))
               (< elapsed-ms 1000.0)
               (= "QUEUE-DEADLINE"
                  (get-in result [:availability-receipt :failureClass])))))

(let [compiles (atom 0)
      transitions (atom [])
      cached {:status :pass :artifact [9 9 9]}
      result
      (cold-fallback/run-with-cold-fallback-v1!
       {:input input
        :probe-deadline-ms 100
        :probe! (fn [_] {:status :online :output cached})
        :cold-compile! (fn [value]
                         (swap! compiles inc)
                         (compile-cold value))
        :transition! #(swap! transitions conj %)})]
  (check! "one complete healthy response is reused without cold fallback"
          (and (= cached (:output result))
               (= :store (:source result))
               (true? (:fact-backed? result))
               (zero? @compiles)
               (empty? @transitions)
               (= "ONLINE" (get-in result [:availability-receipt :mode]))
               (= "FACT-REUSE"
                  (get-in result [:availability-receipt :fallbackMode])))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp5-cold-fallback: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp5-cold-fallback: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
