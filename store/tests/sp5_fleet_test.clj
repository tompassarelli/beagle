;; SP5: one supervised eight-worker release fleet sharing one Store revision.
(require '[clojure.edn :as edn]
         '[clojure.java.io :as io])

(import '(java.util.concurrent Callable CountDownLatch Executors TimeUnit))

(load-file "writer_authority.clj")
(load-file "materialization.clj")
(load-file "conflict.clj")
(load-file "miss_accounting.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(def fixture
  (edn/read-string (slurp "tests/fixtures/sp5/fleet.edn")))

(defn envelope-fact [attempt-id role kind payload]
  (let [envelope (writer-authority/fact-envelope-v1 kind payload)]
    {:maintenance-attempt-id attempt-id
     :role role
     :fact-id (:id envelope)
     :bytes (:bytes envelope)
     :value payload}))

(defn derive-attempt [worker]
  (let [{:keys [attempt-id candidate-root claim-label missing-claim-label
                published-route evidence-digest]} worker
        attestation-id (:expected-attestation-id fixture)
        observation-value {:attempt-id attempt-id
                           :claim-label claim-label
                           :status "OBSERVED"}
        proof-pack (assoc (:proof-pack fixture) :observation observation-value)
        observed (atom [])
        verification
        (materialization/verify-materialization-proof-pack-v1!
         proof-pack
         {:expected-attestation-id attestation-id
          :launcher-public-key (:launcher-public-key fixture)
          :observe! #(do (swap! observed conj %) %)})
        candidate
        (envelope-fact attempt-id :candidate "GateCandidateV1"
                       [attempt-id candidate-root])
        claim
        (envelope-fact attempt-id :claim "GatePhaseClaimV1"
                       [attempt-id claim-label])
        missing-claim
        (envelope-fact attempt-id :claim "GatePhaseClaimV1"
                       [attempt-id missing-claim-label])
        observation
        (envelope-fact attempt-id :observation "GatePhaseObservationV1"
                       [attempt-id (:fact-id claim) attestation-id
                        observation-value])
        miss-order (atom [])
        accounted
        (miss-accounting/account-misses-before-fallback-v1!
         {:attempt-id attempt-id
          :prepared-claim-ids [(:fact-id claim) (:fact-id missing-claim)]
          :observed-claim-ids [(:fact-id claim)]
          :persist-miss!
          (fn [miss]
            (swap! miss-order conj [:persist (:id miss)])
            {:status :accepted :miss-id (:id miss)})
          :fallback!
          (fn [miss durable-receipt]
            (swap! miss-order conj [:fallback (:id miss)])
            {:maintenance-attempt-id attempt-id
             :role :fallback-link
             :miss-id (:id miss)
             :observation-fact-id (:fact-id observation)
             :durable-receipt durable-receipt})})
        miss (assoc (first (:misses accounted)) :role :miss
                    :fact-id (:id (first (:misses accounted))))
        fallback-link (first (:fallback-results accounted))
        conflict-key
        (conflict/fact-conflict-key-v1
         {:candidateRoot candidate-root
          :claimId (:fact-id claim)
          :verifierMaterializationId attestation-id
          :compilerEpochId
          (get-in proof-pack [:attestation :compiler-epoch-id])
          :policyId (get-in proof-pack [:attestation :policy-id])
          :targetAbiProfile "native-linux-x86_64-v1"
          :factSchemaId (get-in proof-pack [:attestation :schema-id])})
        decision (conflict/decision-fact-v1 conflict-key :pass evidence-digest)
        resolution
        (conflict/resolve-conflict-set-v1
         {:key conflict-key :facts [decision]})
        preparation-revision (str "store-revision-prepared-" attempt-id)
        completion-revision (str "store-revision-complete-" attempt-id)
        receipt-value
        (writer-authority/maintenance-receipt-v1
         {:attempt-id attempt-id
          :old-gate-status :pass
          :fact-maintenance-status :accepted
          :revision completion-revision})
        verdict (assoc decision
                       :maintenance-attempt-id attempt-id
                       :role :verdict
                       :value resolution)
        receipt
        (envelope-fact attempt-id :receipt "GateMaintenanceReceiptV1"
                       [attempt-id :accepted completion-revision])]
    {:attempt-id attempt-id
     :published-route published-route
     :preparation-revision preparation-revision
     :completion-revision completion-revision
     :verification verification
     :observed @observed
     :miss-order @miss-order
     :resolution resolution
     :preparation-facts [candidate claim missing-claim miss]
     :completion-facts [observation fallback-link verdict
                        (assoc receipt :receipt receipt-value)]}))

(defn apply-once! [state request next-revision]
  (let [snapshot @state
        outcome
        (writer-authority/apply-maintenance-batch-v1
         snapshot request next-revision)]
    (if (and (= :accepted (get-in outcome [:result :status]))
             (not (compare-and-set! state snapshot (:state outcome))))
      (writer-authority/apply-maintenance-batch-v1
       @state request next-revision)
      outcome)))

(defn run-worker!
  [worker state ready start preparation-finished]
  (.countDown ready)
  (when-not (.await start (:worker-budget-ms fixture)
                    TimeUnit/MILLISECONDS)
    (throw (ex-info "fleet start barrier exceeded worker budget"
                    {:type :sp5/start-timeout})))
  (let [started (System/nanoTime)
        derived (derive-attempt worker)
        preparation
        {:kind :preparation
         :attempt-id (:attempt-id derived)
         :expected-revision (:initial-revision fixture)
         :facts (:preparation-facts derived)}
        preparation-outcome
        (try
          (apply-once! state preparation (:preparation-revision derived))
          (finally (.countDown preparation-finished)))
        preparation-status (get-in preparation-outcome [:result :status])]
    (if (= :accepted preparation-status)
      (do
        (when-not (.await preparation-finished (:worker-budget-ms fixture)
                          TimeUnit/MILLISECONDS)
          (throw (ex-info "preparation barrier exceeded worker budget"
                          {:type :sp5/preparation-timeout
                           :attempt-id (:attempt-id derived)})))
        (let [completion
              {:kind :completion
               :attempt-id (:attempt-id derived)
               :expected-revision (:preparation-revision derived)
               :published-route (:published-route derived)
               :facts (:completion-facts derived)}
              completion-outcome
              (apply-once! state completion (:completion-revision derived))]
          {:attempt-id (:attempt-id derived)
           :status (if (= :accepted
                          (get-in completion-outcome [:result :status]))
                     :completed
                     :typed-conflict)
           :elapsed-ms (quot (- (System/nanoTime) started) 1000000)
           :derived derived
           :preparation-result (:result preparation-outcome)
           :completion-result (:result completion-outcome)
           :receipt (get-in derived [:completion-facts 3 :receipt])}))
      {:attempt-id (:attempt-id derived)
       :status :typed-conflict
       :elapsed-ms (quot (- (System/nanoTime) started) 1000000)
       :derived derived
       :preparation-result (:result preparation-outcome)
       :receipt
       (writer-authority/maintenance-receipt-v1
        {:attempt-id (:attempt-id derived)
         :old-gate-status :pass
         :fact-maintenance-status :stale-revision
         :revision (get-in preparation-outcome [:result :current-revision])})})))

(defn supervise-fleet! []
  (let [worker-count (:worker-count fixture)
        pool (Executors/newFixedThreadPool worker-count)
        ready (CountDownLatch. worker-count)
        start (CountDownLatch. 1)
        preparation-finished (CountDownLatch. worker-count)
        state (atom (writer-authority/maintenance-state-v1
                     (:initial-revision fixture) (:initial-route fixture)))]
    (try
      (let [futures
            (mapv
             (fn [worker]
               (.submit pool
                        ^Callable
                        (reify Callable
                          (call [_]
                            (run-worker! worker state ready start
                                         preparation-finished)))))
             (:workers fixture))]
        (when-not (.await ready (:worker-budget-ms fixture)
                          TimeUnit/MILLISECONDS)
          (throw (ex-info "fleet readiness exceeded worker budget"
                          {:type :sp5/readiness-timeout})))
        (let [deadline (+ (System/nanoTime)
                          (* 1000000 (:fleet-budget-ms fixture)))]
          (.countDown start)
          (let [results
                (mapv
                 (fn [future]
                   (let [remaining-ms
                         (max 1 (quot (- deadline (System/nanoTime)) 1000000))]
                     (.get future remaining-ms TimeUnit/MILLISECONDS)))
                 futures)]
            {:state @state :results results})))
      (finally
        (.shutdownNow pool)
        (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))

(check! "SP1-SP4 public identifiers remain frozen"
        (and (= "beagle.store/WriterAdmissionV1"
                writer-authority/writer-admission-format-v1)
             (= "beagle.store/MaintenanceBatchV1"
                writer-authority/maintenance-batch-format-v1)
             (= "beagle.store/MaterializationAttestationV1"
                materialization/materialization-attestation-format-v1)
             (= "beagle.store/FactConflictKeyV1"
                conflict/fact-conflict-key-format-v1)
             (= "beagle.store/MissAccountingV1"
                miss-accounting/miss-accounting-format-v1)
             (= :maintenance-batch/stale-revision
                writer-authority/maintenance-stale-conflict-code-v1)))

(check! "fleet fixture freezes eight unique attempts and budgets"
        (and (= "beagle.store/SP5FleetFixtureV1" (:format fixture))
             (= 1 (:version fixture))
             (= 8 (:worker-count fixture) (count (:workers fixture)))
             (= 8 (count (set (map :attempt-id (:workers fixture)))))
             (pos? (:worker-budget-ms fixture))
             (<= (:worker-budget-ms fixture) (:fleet-budget-ms fixture))))

(def fleet (supervise-fleet!))
(def results (:results fleet))
(def completed (filterv #(= :completed (:status %)) results))
(def conflicted (filterv #(= :typed-conflict (:status %)) results))
(def winner (first completed))

(check! "supervisor accounts for all eight workers within fixed budgets"
        (and (= 8 (count results))
             (= (set (map :attempt-id (:workers fixture)))
                (set (map :attempt-id results)))
             (every? #(< (:elapsed-ms %) (:worker-budget-ms fixture)) results)
             (= 1 (count completed))
             (= 7 (count conflicted))))

(check! "every non-winner returns the exact typed Store revision conflict"
        (every?
         #(and (= :stale-revision
                  (get-in % [:preparation-result :status]))
               (= writer-authority/maintenance-stale-conflict-code-v1
                  (get-in % [:preparation-result :code]))
               (= :stale-revision
                  (get-in % [:receipt :fact-maintenance-status])))
         conflicted))

(check! "each attempt has exact claim, miss, observation, link, verdict, and receipt accounting"
        (every?
         (fn [{:keys [derived]}]
           (let [preparation (:preparation-facts derived)
                 completion (:completion-facts derived)
                 by-role (frequencies (map :role (concat preparation completion)))
                 miss (first (filter #(= :miss (:role %)) preparation))
                 observation (first (filter #(= :observation (:role %)) completion))
                 link (first (filter #(= :fallback-link (:role %)) completion))]
             (and (= {:candidate 1 :claim 2 :miss 1 :observation 1
                      :fallback-link 1 :verdict 1 :receipt 1}
                     by-role)
                 (= [[:persist (:fact-id miss)] [:fallback (:fact-id miss)]]
                     (:miss-order derived))
                  (= {:attempt-id (:attempt-id derived)
                      :old-gate-status :pass
                      :fact-maintenance-status :accepted
                      :revision (:completion-revision derived)}
                     (select-keys
                      (:receipt (first (filter #(= :receipt (:role %))
                                               completion)))
                      [:attempt-id :old-gate-status
                       :fact-maintenance-status :revision]))
                  (= (:fact-id miss) (:miss-id link))
                  (= (:fact-id observation) (:observation-fact-id link))
                  (= :pass (get-in derived [:verification :status]))
                  (= 1 (count (:observed derived)))
                  (= :pass (get-in derived [:resolution :status])))))
         results))

(def cold-file
  (.toFile
   (java.nio.file.Files/createTempFile
    "sp5-fleet-cold-" ".edn"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(try
  (spit cold-file (pr-str (:state fleet)))
  (let [cold (edn/read-string (slurp cold-file))
        attempt-id (:attempt-id winner)
        stored (get-in cold [:attempts attempt-id])
        stored-facts (concat (get-in stored [:preparation :facts])
                             (get-in stored [:completion :facts]))
        stored-roles (frequencies (map :role stored-facts))]
    (check! "cold audit has one complete attempt and no torn batch"
            (and (= #{attempt-id} (set (keys (:attempts cold))))
                 (= #{:preparation :completion} (set (keys stored)))
                 (= 4 (count (get-in stored [:preparation :facts])))
                 (= 4 (count (get-in stored [:completion :facts])))
                 (= {:candidate 1 :claim 2 :miss 1 :observation 1
                     :fallback-link 1 :verdict 1 :receipt 1}
                    stored-roles)
                 (every? #(= attempt-id (:maintenance-attempt-id %))
                         stored-facts)
                 (= (:completion-revision (:derived winner)) (:revision cold))
                 (= (:published-route (:derived winner))
                    (:published-route cold))))
    (check! "cold audit has no false success"
            (and (= :accepted
                    (get-in winner [:completion-result :status]))
                 (= :accepted
                    (get-in winner [:receipt :fact-maintenance-status]))
                 (some #(and (= :receipt (:role %))
                             (= :accepted
                                (get-in % [:receipt
                                           :fact-maintenance-status])))
                       stored-facts)
                 (every? #(not (contains? (:attempts cold) (:attempt-id %)))
                         conflicted))))
  (finally
    (io/delete-file cold-file true)))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp5-fleet: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp5-fleet: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
