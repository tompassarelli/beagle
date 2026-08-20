;; SP1: deterministic contention, bounded deadlines, outside-lock derivation,
;; accepted-batch preservation, and stable SpaceId across compiler epochs.
(require '[clojure.edn :as edn]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.types :as t])

(load-file "writer_authority.clj")
(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn error-code [f]
  (try (f) nil
       (catch clojure.lang.ExceptionInfo error
         (or (:store/code (ex-data error)) (:type (ex-data error))))))

(defn eventually [f timeout-ms]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (let [value (f)]
        (cond value value
              (>= (System/currentTimeMillis) deadline) nil
              :else (do (Thread/sleep 5) (recur)))))))

(defn process! [arguments]
  (.start
   (doto (ProcessBuilder. (into-array String arguments))
     (.directory (io/file ".")))))

(defn process-result! [^Process process timeout-ms]
  (let [exited? (.waitFor process timeout-ms
                          java.util.concurrent.TimeUnit/MILLISECONDS)]
    (when-not exited? (.destroyForcibly process))
    {:exited? exited?
     :exit (when exited? (.exitValue process))
     :out (slurp (.getInputStream process))
     :err (slurp (.getErrorStream process))}))

(check! "WriterAdmissionV1 public identifiers are frozen"
        (and (= 1 writer-authority/writer-admission-version-v1)
             (= "beagle.store/WriterAdmissionV1"
                writer-authority/writer-admission-format-v1)
             (= [:deriving :derived :waiting :admitted :accepted
                 :deadline :failed]
                writer-authority/writer-admission-progress-phases-v1)
             (ifn? writer-authority/run-admitted-batch!)))

(let [clock (atom 0)
      progress (atom [])
      derived (atom 0)
      published (atom 0)
      code
      (error-code
       (fn []
         (writer-authority/run-admitted-batch!
          {:log "/definitely/not/opened/sp1.storelog"
           :space-id "stable-space"
           :batch-id "deadline-batch"
           :compiler-epoch-id "compiler-a"
           :timeout-ms 25
           :retry-ms 10
           :now-ms (fn [] @clock)
           :sleep-ms! #(swap! clock + %)
           :try-acquire-fn (constantly nil)
           :progress! #(swap! progress conj %)
           :derive! #(swap! derived inc)
           :publish! (fn [_ _] (swap! published inc))})))]
  (check! "deterministic authority deadline is bounded and visible"
          (and (= :writer-admission/deadline code)
               (= 1 @derived)
               (zero? @published)
               (= :deriving (:phase (first @progress)))
               (some #(= :waiting (:phase %)) @progress)
               (= :deadline (:phase (last @progress)))
               (= 25 (:elapsed-ms (last @progress))))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "sp1-writer-admission-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "facts.storelog")))
(def space-id "facts-authority-space-v1")
(def fixture "tests/fixtures/sp1/controlled_writer.clj")
(def worker-count 6)

(try
  (database/create-triple-log! log-path space-id)
  (let [holder-ready (.getPath (io/file scratch "holder.ready"))
        holder-release (.getPath (io/file scratch "holder.release"))
        holder (process! ["bb" "-cp" "out" fixture "hold"
                          log-path space-id "_" "_"
                          holder-ready "_" holder-release])]
    (check! "controlled lock holder establishes contention"
            (some? (eventually #(.exists (io/file holder-ready)) 2000)))
    (let [workers
          (mapv
           (fn [index]
             (let [batch (str "batch-" index)
                   epoch (if (even? index) "compiler-epoch-a"
                             "compiler-epoch-b")
                   marker (.getPath (io/file scratch (str batch ".derived")))
                   progress (.getPath (io/file scratch (str batch ".progress")))]
               {:batch batch
                :epoch epoch
                :marker marker
                :progress progress
                :process
                (process! ["bb" "-cp" "out" fixture "write"
                           log-path space-id batch epoch marker progress "_"])}))
           (range worker-count))]
      (check! "every concurrent batch derives while writer lock is unavailable"
              (some? (eventually
                      #(when (every? (fn [{:keys [marker]}]
                                       (.exists (io/file marker)))
                                     workers)
                         true)
                      3000)))
      (spit holder-release "release\n")
      (let [holder-result (process-result! holder 3000)
            results
            (mapv (fn [{:keys [process] :as worker}]
                    (assoc worker :result (process-result! process 6000)))
                  workers)
            receipts
            (mapv (fn [{:keys [result]}]
                    (when (and (:exited? result) (zero? (:exit result)))
                      (edn/read-string (:out result))))
                  results)
            progress-events
            (mapv (fn [{:keys [progress]}]
                    (mapv edn/read-string
                          (remove empty? (str/split-lines (slurp progress)))))
                  results)
            reopened (database/open-database! log-path space-id)
            durable-batches
            (into #{}
                  (keep (fn [proposition]
                          (when (and (t/triple? proposition)
                                     (= :sp1/accepted (t/triple-t2 proposition))
                                     (= true (t/triple-t3 proposition)))
                            (t/triple-t1 proposition))))
                  (database/live-propositions reopened))]
        (check! "lock holder releases cleanly"
                (and (:exited? holder-result)
                     (zero? (:exit holder-result))))
        (check! "all bounded concurrent admissions report accepted"
                (and (every? #(and (:exited? (:result %))
                                   (zero? (:exit (:result %)))
                                   (= "" (:err (:result %))))
                             results)
                     (every? #(= :accepted (:status %)) receipts)
                     (every? #(some (fn [event]
                                      (= :waiting (:phase event))) %)
                             progress-events)))
        (check! "cold reopen preserves every accepted batch exactly once"
                (= (set (map :batch workers)) durable-batches))
        (check! "compiler epochs reuse one stable authority SpaceId"
                (and (= space-id (database/database-space reopened))
                     (= #{"compiler-epoch-a" "compiler-epoch-b"}
                        (set (map :epoch workers)))
                     (every? #(= #{space-id}
                                  (set (map :space-id %)))
                             progress-events))))))
  (finally
    (doseq [file (reverse (file-seq scratch))]
      (io/delete-file file true))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (println (str "\nsp1-writer-admission: " (count @checks) "/"
                  (count @checks) " PASS"))
    (do
      (println (str "\nsp1-writer-admission: " (count failures) " FAILED"))
      (doseq [[label] failures] (println " -" label))
      (System/exit 1))))
