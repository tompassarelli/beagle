;; FACT-GC-V1: rooted mark/partition, re-derivation, cold compaction, CAS,
;; interruption preservation, inventory, budgets, and 1x/10x/100x fixtures.
(require '[clojure.edn :as edn]
         '[clojure.java.io :as io])

(load-file "retention.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))
(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:store/code (ex-data error)) (:type (ex-data error))))))
(def fixture (edn/read-string (slurp "tests/fixtures/fact-gc/cases.edn")))
(def now 1735689600000)

(defn root [id candidate kind created]
  (retention/fact-root-v1
   {:root-id id :git-repository "beagle" :git-commit "commit-source-v1"
    :fact-candidate-root candidate :root-kind kind :created-at created
    :expires-at nil :maintenance-policy {:retention :v1}}))

(defn derivation [id & [candidate]]
  (retention/fact-derivation-v1
   {:format retention/fact-derivation-format-v1
    :version 1 :source-commit "commit-source-v1" :source-digests {"a" "digest-a"}
    :candidate-root (or candidate "candidate-dead") :fact-ids [id]
    :verifier "verifier-v1"
    :policy "policy-v1" :importer "importer-v1" :compiler "compiler-v1"
    :predecessor-fact-ids [] :foreign-inputs [] :producer "gate-fact-producer"
    :producer-version "producer-v1" :deterministic? true
    :foreign-inputs-available? true :rederived-fact-id id}))

(def live-root (root "root-live" "candidate-live" "LIVE-COMMIT" now))
(def pin-root (root "root-pin" "candidate-pin" "PIN" (- now 900000000)))
(def recent-root (root "root-recent" "candidate-recent" "RECENT" (- now 1000)))
(def dead-root (assoc (root "root-dead" "candidate-dead" "LIVE-COMMIT" (- now 900000000))
                      :expires-at (- now 1000)))
(def rejected-root (assoc (root "root-rejected" "candidate-rejected" "RECENT" (- now 1000))
                          :rejected? true))
(defn fact [id candidate & [d]]
  (cond-> {:fact-id id :candidate-root candidate}
    d (assoc :derivation d)))
(def live-fact (fact "fact-live" "candidate-live"))
(def pin-fact (fact "fact-pin" "candidate-pin"))
(def recent-fact (fact "fact-recent" "candidate-recent"))
(def dead-good (fact "fact-dead-good" "candidate-dead" (derivation "fact-dead-good")))
(def dead-missing (fact "fact-dead-missing" "candidate-dead"
                        (assoc (derivation "fact-dead-missing")
                               :foreign-inputs-available? false)))
(def rejected-fact (fact "fact-rejected" "candidate-rejected"))
(def facts [live-fact pin-fact recent-fact dead-good dead-missing rejected-fact])
(def roots [live-root pin-root recent-root dead-root rejected-root])

(check! "FactRootV1 and FactDerivationV1 public identifiers are frozen"
        (and (= ["LIVE-COMMIT" "PIN" "CHECKPOINT" "SESSION" "RECENT"]
                retention/fact-root-kinds-v1)
             (= "beagle.store/FactRootV1" retention/fact-root-format-v1)
             (= "beagle.store/FactDerivationV1" retention/fact-derivation-format-v1)
             (= "beagle.store/RetentionReceiptV1" retention/retention-receipt-format-v1)))

(def partition
  (retention/mark-and-partition-v1
   {:facts facts :roots roots :now now :recency-days 7 :recency-count 100}))

(check! "live, pin, recent, and rejected roots are marked while dead roots partition"
        (and (= :live (get-in partition [:root-statuses "root-live"]))
             (= :live (get-in partition [:root-statuses "root-pin"]))
             (= :recent (get-in partition [:root-statuses "root-recent"]))
             (= :rejected (get-in partition [:root-statuses "root-rejected"]))
             (some #(= "fact-live" (:fact-id %))
                   (get-in partition [:partitions :marked]))
             (some #(= "fact-dead-good" (:fact-id %))
                   (get-in partition [:partitions :re-derivable]))
             (some #(= "fact-dead-missing" (:fact-id %))
                   (get-in partition [:partitions :archive-only]))))

(check! "a missing producer/input is never evictable"
        (not-any? #(= "fact-dead-missing" (:fact-id %))
                  (get-in partition [:partitions :re-derivable])))

(let [directory (.toFile (java.nio.file.Files/createTempDirectory
                          "fact-gc-v1" (make-array java.nio.file.attribute.FileAttribute 0)))
      path (.getPath (io/file directory "facts.edn"))]
  (retention/write-fact-log-v1! path {:revision 7 :facts facts :roots roots})
  (let [before (slurp path)
        interrupted
        (error-code #(retention/compact-fact-log-v1!
                      {:log-path path :now now :interrupt-after-write? true}))]
    (check! "interrupted compaction leaves the old log readable and unchanged"
            (and (= :fact-gc/interrupted interrupted)
                 (= before (slurp path))
                 (= 7 (:revision (read-string (slurp path)))))))
  (let [result (retention/compact-fact-log-v1!
                {:log-path path :now now :expected-revision 7})
        compacted (:log result)]
    (check! "cold compaction retains every live root and evicts only re-derivable facts"
            (and (= 8 (:revision compacted))
                 (some #(= "fact-live" (:fact-id %)) (:facts compacted))
                 (some #(= "fact-pin" (:fact-id %)) (:facts compacted))
                 (some #(= "fact-rejected" (:fact-id %)) (:facts compacted))
                 (not-any? #(= "fact-dead-good" (:fact-id %)) (:facts compacted))
                 (some #(= "fact-dead-missing" (:fact-id %)) (:facts compacted))
                 (= :published (get-in result [:receipt :cas :status]))
                 (= :pass (get-in result [:receipt :rehydration :status])))))
  (let [stale (error-code #(retention/compact-fact-log-v1!
                            {:log-path path :expected-revision 7 :now now}))]
    (check! "stale root/log CAS refuses replacement" (= :fact-gc/stale-cas stale)))
  (let [summary (retention/inventory-v1 {:log-path path})]
    (check! "inventory reports bytes, entries, roots, and free space"
            (and (= retention/inventory-format-v1 (:format summary))
                 (pos? (:store-log-bytes summary))
                 (= 5 (:operation-occurrences summary))
                 (= 3 (:live-fact-entries summary))
                 (= 5 (:root-count summary))
                 (integer? (:free-bytes summary)))))
  (doseq [{:keys [scale]} (:cases fixture)]
    (let [scaled (vec (mapcat (fn [n]
                                [(fact (str "scale-" scale "-" n)
                                       "candidate-dead"
                                       (derivation (str "scale-" scale "-" n)
                                                   "candidate-dead"))])
                              (range scale)))
          marked (retention/mark-and-partition-v1
                  {:facts scaled :roots [] :now now})]
      (check! (str "cold mark/partition is exact at " scale "x")
              (= scale (count (get-in marked [:partitions :re-derivable])))))))

(let [budget (retention/admission-budget-v1
              {:max-log-bytes 100 :max-fact-entries 10 :min-free-bytes 20})
      accepted (retention/admit-append-v1!
                {:inventory {:store-log-bytes 10 :live-fact-entries 1 :free-bytes 100}
                 :budget (select-keys budget [:max-log-bytes :max-fact-entries
                                               :min-free-bytes])
                 :append-bytes 10 :append-facts 1})
      refused (retention/admit-append-v1!
               {:inventory {:store-log-bytes 90 :live-fact-entries 10 :free-bytes 19}
                :budget (select-keys budget [:max-log-bytes :max-fact-entries
                                              :min-free-bytes])
                :append-bytes 11 :append-facts 1})]
  (check! "admission budgets accept within bounds and fail closed at a breach"
          (and (= :accepted (:status accepted))
               (= :refused (:status refused))
               (= #{:max-log-bytes :max-fact-entries :min-free-bytes}
                  (set (:breaches refused))))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nfact-gc-v1: " (count @checks) "/" (count @checks) " PASS"))
    (do
      (println (str "\nfact-gc-v1: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
