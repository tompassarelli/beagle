;; SP6: complete volume accounting and fail-closed routine append budgets.
(require '[clojure.edn :as edn]
         '[clojure.set :as set])

(load-file "budget_accounting.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(def fixture
  (edn/read-string (slurp "tests/fixtures/sp6/budgets.edn")))

(defn repeat-facts [template scale]
  (vec (repeat scale template)))

(defn operation-for [case]
  (let [facts (repeat-facts (:fact-template fixture) (:scale case))]
    {:append-facts facts
     :replay-facts facts
     :read-facts facts
     :transaction-count (:transaction-count case)
     :fsync-count (:fsync-count case)}))

(def budget
  (budget-accounting/routine-budget-v1
   (assoc (:budget fixture)
          :format budget-accounting/budget-accounting-format-v1
          :version budget-accounting/budget-accounting-version-v1)))

(check! "SP6 public identifiers and all declared metric fields are frozen"
        (and (= 1 budget-accounting/budget-accounting-version-v1)
             (= "beagle.store/BudgetAccountingV1"
                budget-accounting/budget-accounting-format-v1)
             (= [:packed-volume-bytes :append-bytes :fact-count
                 :replay-bytes :replay-fact-count :read-bytes
                 :read-fact-count :transaction-count :fsync-count]
                budget-accounting/budget-metric-fields-v1)
             (= (set (map #(keyword (str "max-" (name %)))
                          budget-accounting/budget-metric-fields-v1))
                (set budget-accounting/routine-budget-fields-v1))))

(check! "fixture freezes representative 1x, 10x, and 100x cases"
        (and (= budget-accounting/budget-accounting-fixture-format-v1
                (:format fixture))
             (= 1 (:version fixture))
             (= [1 10 100] (mapv :scale (:cases fixture)))))

(doseq [case (:cases fixture)]
  (let [operation (operation-for case)
        metrics (budget-accounting/measure-routine-v1 operation)
        scale (:scale case)]
    (check! (str (name (:name case)) " reports every byte, fact, replay, read, transaction, and fsync metric")
            (and (set/subset? (set budget-accounting/budget-metric-fields-v1)
                              (set (keys metrics)))
                 (= (* 17 scale) (:packed-volume-bytes metrics))
                 (= (* 23 scale) (:append-bytes metrics))
                 (= scale (:fact-count metrics))
                 (= (* 11 scale) (:replay-bytes metrics))
                 (= scale (:replay-fact-count metrics))
                 (= (* 7 scale) (:read-bytes metrics))
                 (= scale (:read-fact-count metrics))
                 (= (:transaction-count case) (:transaction-count metrics))
                 (= (:fsync-count case) (:fsync-count metrics))))
    (let [state (atom (budget-accounting/empty-state-v1))
          result (budget-accounting/append-with-budget-v1!
                  state operation budget)]
      (check! (str (name (:name case)) " is admitted within the routine budget")
              (and (= :accepted (:status result))
                   (= budget-accounting/budget-accepted-code-v1 (:code result))
                   (= metrics (:metrics result))
                   (= scale (count (:facts @state)))
                   (= (:total-metrics result) (:metrics @state)))))))

(let [state (atom (budget-accounting/empty-state-v1))
      hundred (last (:cases fixture))
      one (first (:cases fixture))
      first-result (budget-accounting/append-with-budget-v1!
                    state (operation-for hundred) budget)
      breach-operation (operation-for (assoc one :name :breach :scale 1))
      before @state
      second-result (budget-accounting/append-with-budget-v1!
                     state breach-operation budget)]
  (check! "a breach refuses append and leaves the durable state unchanged"
          (and (= :accepted (:status first-result))
               (= :refused (:status second-result))
               (= budget-accounting/budget-breach-code-v1 (:code second-result))
               (seq (:breaches second-result))
               (= before @state)
               (= 100 (count (:facts @state)))
               (= 101 (:fact-count (:total-metrics second-result)))
               (some #(= :fact-count (:metric %)) (:breaches second-result)))))

(let [state (atom (budget-accounting/empty-state-v1))
      invalid-budget (dissoc budget :max-fsync-count)
      before @state
      result
      (try
        (budget-accounting/append-with-budget-v1!
         state (operation-for (first (:cases fixture))) invalid-budget)
        nil
        (catch clojure.lang.ExceptionInfo error error))]
  (check! "an incomplete budget fails closed before any append"
          (and result
               (= budget-accounting/budget-invalid-code-v1
                  (:fram/code (ex-data result)))
               (= before @state))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp6-budgets: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp6-budgets: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
