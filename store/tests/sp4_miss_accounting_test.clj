;; SP4: pure observed/prepared differences, conservative statuses, durable
;; miss-before-fallback ordering, and exact typed Store error preservation.
(require '[clojure.edn :as edn])

(load-file "writer_authority.clj")
(load-file "miss_accounting.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(def fixture
  (edn/read-string (slurp "tests/fixtures/sp4/set_difference.edn")))

(check! "SP4 public identifiers and upstream fact kind remain frozen"
        (and (= 1 miss-accounting/miss-accounting-version-v1)
             (= "beagle.store/MissAccountingV1"
                miss-accounting/miss-accounting-format-v1)
             (= "beagle.store/FactMissEventV1"
                miss-accounting/fact-miss-event-format-v1)
             (= "FactMissEventV1"
                miss-accounting/fact-miss-event-kind-v1)
             (= "MISSING" miss-accounting/claim-status-missing-v1)
             (= "NOT-RUN" miss-accounting/observation-status-not-run-v1)
             (= 5 (get writer-authority/fact-kind-registry-v1
                       miss-accounting/fact-miss-event-kind-v1))
             (ifn? miss-accounting/observed-prepared-difference-v1)
             (ifn? miss-accounting/fact-miss-event-v1)
             (ifn? miss-accounting/account-misses-before-fallback-v1!)))

(def difference
  (miss-accounting/observed-prepared-difference-v1
   (:prepared-claim-ids fixture) (:observed-claim-ids fixture)))

(check! "pure set difference reports every missing and unexplained claim"
        (and (= (:expected-missing-claim-ids fixture)
                (:missing-claim-ids difference))
             (= (:expected-unexplained-claim-ids fixture)
                (:unexplained-claim-ids difference))
             (false? (:complete? difference))
             (= difference
                (miss-accounting/observed-prepared-difference-v1
                 (:prepared-claim-ids fixture)
                 (:observed-claim-ids fixture)))))

(def ordering (atom []))
(def accounted
  (miss-accounting/account-misses-before-fallback-v1!
   {:attempt-id (:attempt-id fixture)
    :prepared-claim-ids (:prepared-claim-ids fixture)
    :observed-claim-ids (:observed-claim-ids fixture)
    :persist-miss!
    (fn [miss]
      (swap! ordering conj [:persist (:id miss)])
      {:status :accepted :miss-id (:id miss)})
    :fallback!
    (fn [miss receipt]
      (swap! ordering conj [:fallback (:id miss)])
      {:status :completed
       :miss-id (:id miss)
       :receipt receipt})}))

(check! "missing observations remain NOT-RUN and unexplained claims remain MISSING"
        (let [by-class (group-by :miss-class (:misses accounted))]
          (and (every? #(= "NOT-RUN" (:observation-status %))
                       (get by-class
                            miss-accounting/missing-observation-class-v1))
               (every? #(= "MISSING" (:claim-status %))
                       (get by-class
                            miss-accounting/unexplained-claim-class-v1))
               (every? #(and (= "FactMissEventV1" (:kind %))
                             (re-matches #"sha256:[0-9a-f]{64}" (:id %)))
                       (:misses accounted)))))

(check! "Store ordering persists every miss before any fallback starts"
        (let [miss-count (count (:misses accounted))
              persist-events (take miss-count @ordering)
              fallback-events (drop miss-count @ordering)]
          (and (= miss-count (count (:durable-results accounted)))
               (= miss-count (count (:fallback-results accounted)))
               (every? #(= :persist (first %)) persist-events)
               (every? #(= :fallback (first %)) fallback-events)
               (= (mapv second persist-events)
                  (mapv second fallback-events)))))

(let [fallback-count (atom 0)
      typed-error (ex-info "forced typed Store failure"
                           {:type :store/wrapped
                            :fram/code :store/durability-ambiguous})
      observed-error
      (try
        (miss-accounting/account-misses-before-fallback-v1!
         {:attempt-id (:attempt-id fixture)
          :prepared-claim-ids ["claim-a"]
          :observed-claim-ids []
          :persist-miss! (fn [_] (throw typed-error))
          :fallback! (fn [_ _] (swap! fallback-count inc))})
        nil
        (catch clojure.lang.ExceptionInfo error error))]
  (check! "typed Store errors retain the exact code and prevent fallback"
          (and (identical? typed-error observed-error)
               (= :store/durability-ambiguous
                  (:fram/code (ex-data observed-error)))
               (zero? @fallback-count))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp4-miss-accounting: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp4-miss-accounting: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
