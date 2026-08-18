;; SP2: atomic maintenance batches, attempt isolation, revision CAS, and
;; preservation of durability ambiguity across the append boundary.
(require '[clojure.edn :as edn])

(load-file "writer_authority.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:fram/code (ex-data error)) (:type (ex-data error))))))

(def attempt-a "maintenance-attempt-a")
(def attempt-b "maintenance-attempt-b")
(defn fact [attempt role value]
  {:maintenance-attempt-id attempt :role role :value value})

(check! "FactEnvelopeV1 and WriterAdmissionV1 identifiers remain frozen"
        (and (= 1 writer-authority/fact-envelope-version-v1)
             (= "beagle.store/FactEnvelope"
                writer-authority/fact-envelope-domain-v1)
             (= 1 writer-authority/writer-admission-version-v1)
             (= "beagle.store/WriterAdmissionV1"
                writer-authority/writer-admission-format-v1)))

(check! "MaintenanceBatchV1 public identifiers are frozen"
        (and (= 1 writer-authority/maintenance-batch-version-v1)
             (= "beagle.store/MaintenanceBatchV1"
                writer-authority/maintenance-batch-format-v1)
             (= [:preparation :completion]
                writer-authority/maintenance-batch-kinds-v1)
             (= :maintenance-attempt-id
                writer-authority/maintenance-attempt-id-key-v1)
             (= :maintenance-batch/stale-revision
                writer-authority/maintenance-stale-conflict-code-v1)
             (ifn? writer-authority/maintenance-batch-v1)
             (ifn? writer-authority/apply-maintenance-batch-v1)
             (ifn? writer-authority/commit-maintenance-batch-v1!)
             (ifn? writer-authority/maintenance-receipt-v1)))

(def initial
  (writer-authority/maintenance-state-v1 "store-revision-0" "route-old"))
(def preparation
  {:kind :preparation
   :attempt-id attempt-a
   :expected-revision "store-revision-0"
   :facts [(fact attempt-a :candidate "candidate-a")
           (fact attempt-a :claim "claim-a")
           (fact attempt-a :miss "miss-a")]})
(def prepared
  (writer-authority/apply-maintenance-batch-v1
   initial preparation "store-revision-1"))

(check! "one preparation transaction installs every fact or none"
        (and (= :accepted (get-in prepared [:result :status]))
             (= "store-revision-1" (get-in prepared [:state :revision]))
             (= "route-old" (get-in prepared [:state :published-route]))
             (= (:facts preparation)
                (get-in prepared
                        [:state :attempts attempt-a :preparation :facts]))))

(def completion
  {:kind :completion
   :attempt-id attempt-a
   :expected-revision "store-revision-1"
   :published-route "route-new"
   :facts [(fact attempt-a :observation "observation-a")
           (fact attempt-a :fallback-link "fallback-a")
           (fact attempt-a :verdict :pass)
           (fact attempt-a :receipt "receipt-a")]})
(def completed
  (writer-authority/apply-maintenance-batch-v1
   (:state prepared) completion "store-revision-2"))

(check! "one completion transaction installs all facts and route together"
        (and (= :accepted (get-in completed [:result :status]))
             (= "route-new" (get-in completed [:state :published-route]))
             (= (:facts completion)
                (get-in completed
                        [:state :attempts attempt-a :completion :facts]))))

(def invalid-completion
  (assoc completion
         :expected-revision "store-revision-2"
         :facts [(fact attempt-a :observation "owned")
                 (fact attempt-b :receipt "foreign")]))

(check! "mixed attempts are rejected before any completion route can publish"
        (and (= :maintenance-batch/attempt-mismatch
                (error-code
                 #(writer-authority/apply-maintenance-batch-v1
                   (:state completed) invalid-completion "store-revision-3")))
             (= "route-new" (get-in completed [:state :published-route]))
             (= "store-revision-2" (get-in completed [:state :revision]))))

(def preparation-b
  {:kind :preparation
   :attempt-id attempt-b
   :expected-revision "store-revision-2"
   :facts [(fact attempt-b :candidate "candidate-b")
           (fact attempt-b :miss "miss-b")]})
(def prepared-b
  (writer-authority/apply-maintenance-batch-v1
   (:state completed) preparation-b "store-revision-3"))

(check! "MaintenanceAttemptId partitions facts across concurrent attempts"
        (let [attempts (get-in prepared-b [:state :attempts])]
          (and (= #{attempt-a attempt-b} (set (keys attempts)))
               (every? #(= attempt-a (:maintenance-attempt-id %))
                       (concat
                        (get-in attempts [attempt-a :preparation :facts])
                        (get-in attempts [attempt-a :completion :facts])))
               (every? #(= attempt-b (:maintenance-attempt-id %))
                       (get-in attempts [attempt-b :preparation :facts])))))

(def stale
  (writer-authority/apply-maintenance-batch-v1
   (:state prepared-b)
   (assoc completion
          :attempt-id attempt-b
          :expected-revision "store-revision-2"
          :facts [(fact attempt-b :receipt "stale")])
   "store-revision-4"))

(check! "stale expected revision returns typed conflict without route mutation"
        (and (= :stale-revision (get-in stale [:result :status]))
             (= :maintenance-batch/stale-revision
                (get-in stale [:result :code]))
             (= "store-revision-2"
                (get-in stale [:result :expected-revision]))
             (= "store-revision-3"
                (get-in stale [:result :current-revision]))
             (identical? (:state prepared-b) (:state stale))
             (= "route-new" (get-in stale [:state :published-route]))))

(let [append-count (atom 0)
      code
      (error-code
       #(writer-authority/commit-maintenance-batch-v1!
         (fn [_]
           (swap! append-count inc)
           (throw (ex-info "forced ambiguous append"
                           {:type :durability-ambiguous
                            :fram/code :durability-ambiguous})))
         preparation-b))]
  (check! "ambiguous append is preserved and never retried"
          (and (= :durability-ambiguous code) (= 1 @append-count))))

(def cold-receipt
  (edn/read-string (slurp "tests/fixtures/sp2/ambiguous_receipt.edn")))

(check! "cold receipt keeps old-gate and fact-maintenance status distinct"
        (and (= cold-receipt
                (writer-authority/maintenance-receipt-v1 cold-receipt))
             (= :pass (:old-gate-status cold-receipt))
             (= :durability-ambiguous
                (:fact-maintenance-status cold-receipt))
             (not= :pass (:fact-maintenance-status cold-receipt))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp2-atomic-batches: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp2-atomic-batches: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
