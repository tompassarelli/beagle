(ns cold-fallback
  (:require [clojure.string :as str])
  (:import [java.nio.charset StandardCharsets]
           [java.security MessageDigest]
           [java.util.concurrent Callable ExecutionException Executors
            ThreadFactory TimeUnit TimeoutException]))

;; These strings and field order are the Store-facing SP5 contract.
(def store-availability-version-v1 1)
(def store-availability-format-v1
  "beagle.store/StoreAvailabilityReceiptV1")
(def store-availability-receipt-fields-v1
  [:receiptId
   :factStoreSpaceId
   :requestedSnapshotId
   :requestedBranchRevisionId
   :probeDeadlineClass
   :mode
   :failureClass
   :fallbackMode
   :maintenanceStatus])
(def store-availability-modes-v1 ["ONLINE" "COLD" "DEGRADED"])
(def store-failure-classes-v1
  ["NONE" "UNREACHABLE" "QUEUE-DEADLINE" "CORRUPT" "TORN-TAIL"
   "PARTIAL-COMMIT" "BUDGET" "STALE-REVISION" "DURABILITY-UNKNOWN"])
(def store-fallback-modes-v1 ["FACT-REUSE" "COLD-COMPILATION"])
(def store-maintenance-statuses-v1
  ["PUBLISHED" "DEFERRED" "UNAVAILABLE"])

(def store-failure-contract-v1
  {:absent                    ["COLD" "UNREACHABLE" "UNAVAILABLE"]
   :unreachable               ["COLD" "UNREACHABLE" "UNAVAILABLE"]
   :deadline                  ["COLD" "QUEUE-DEADLINE" "UNAVAILABLE"]
   :full-queue                ["COLD" "QUEUE-DEADLINE" "DEFERRED"]
   :stale-revision            ["COLD" "STALE-REVISION" "DEFERRED"]
   :corrupt-frame             ["DEGRADED" "CORRUPT" "UNAVAILABLE"]
   :torn-tail                 ["DEGRADED" "TORN-TAIL" "UNAVAILABLE"]
   :partial-transaction       ["DEGRADED" "PARTIAL-COMMIT" "UNAVAILABLE"]
   :ambiguous-commit-response ["DEGRADED" "DURABILITY-UNKNOWN" "DEFERRED"]
   :budget                     ["COLD" "BUDGET" "DEFERRED"]})

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- nonblank-string? [value]
  (and (string? value) (not (str/blank? value))))

(defn- u32-bytes [value]
  (mapv #(bit-and 255 (unsigned-bit-shift-right (long value) %))
        [24 16 8 0]))

(defn- signed-byte-array [bytes]
  (byte-array (map #(byte (if (> % 127) (- % 256) %)) bytes)))

(defn- content-id [domain values]
  (let [parts (cons domain values)
        bytes
        (vec
         (mapcat
          (fn [value]
            (let [encoded (mapv #(bit-and (int %) 255)
                                (.getBytes ^String value
                                           StandardCharsets/UTF_8))]
              (concat (u32-bytes (count encoded)) encoded)))
          parts))]
    (str "sha256:"
         (apply str
                (map #(format "%02x" (bit-and (int %) 255))
                     (.digest (MessageDigest/getInstance "SHA-256")
                              (signed-byte-array bytes)))))))

(defn store-availability-receipt-v1
  "Validate and content-address one StoreAvailabilityReceiptV1."
  [receipt]
  (let [content-fields (vec (rest store-availability-receipt-fields-v1))
        expected-keys (set (concat [:format :version] content-fields))]
    (when-not (and (map? receipt) (= expected-keys (set (keys receipt))))
      (fail! :cold-fallback/invalid-receipt
             "StoreAvailabilityReceiptV1 must contain exactly its V1 fields"
             {:fields (when (map? receipt) (set (keys receipt)))}))
    (when-not (and (= store-availability-format-v1 (:format receipt))
                   (= store-availability-version-v1 (:version receipt)))
      (fail! :cold-fallback/invalid-receipt
             "Store availability receipt format is not V1" {}))
    (doseq [field content-fields]
      (when-not (nonblank-string? (get receipt field))
        (fail! :cold-fallback/invalid-receipt
               "Store availability receipt fields must be nonempty strings"
               {:field field})))
    (when-not (some #{(:mode receipt)} store-availability-modes-v1)
      (fail! :cold-fallback/invalid-receipt "invalid Store availability mode"
             {:mode (:mode receipt)}))
    (when-not (some #{(:failureClass receipt)} store-failure-classes-v1)
      (fail! :cold-fallback/invalid-receipt "invalid Store failure class"
             {:failureClass (:failureClass receipt)}))
    (when-not (some #{(:fallbackMode receipt)} store-fallback-modes-v1)
      (fail! :cold-fallback/invalid-receipt "invalid Store fallback mode"
             {:fallbackMode (:fallbackMode receipt)}))
    (when-not (some #{(:maintenanceStatus receipt)}
                    store-maintenance-statuses-v1)
      (fail! :cold-fallback/invalid-receipt "invalid Store maintenance status"
             {:maintenanceStatus (:maintenanceStatus receipt)}))
    (let [receipt-id
          (content-id store-availability-format-v1
                      (mapv #(get receipt %) content-fields))]
      (assoc receipt :receiptId receipt-id))))

(defn- receipt-v1 [route mode failure-class fallback-mode maintenance-status]
  (store-availability-receipt-v1
   (merge {:format store-availability-format-v1
           :version store-availability-version-v1
           :mode mode
           :failureClass failure-class
           :fallbackMode fallback-mode
           :maintenanceStatus maintenance-status}
          (select-keys route [:factStoreSpaceId :requestedSnapshotId
                              :requestedBranchRevisionId
                              :probeDeadlineClass]))))

(defn- require-route! [route]
  (doseq [field [:factStoreSpaceId :requestedSnapshotId
                 :requestedBranchRevisionId :probeDeadlineClass]]
    (when-not (nonblank-string? (get route field))
      (fail! :cold-fallback/invalid-route
             "cold fallback requires the complete Store route tuple"
             {:field field})))
  route)

(defn- code->failure [code]
  (let [spelling (some-> code name str/lower-case)]
    (cond
      (nil? spelling) nil
      (str/includes? spelling "torn") :torn-tail
      (or (str/includes? spelling "partial")
          (str/includes? spelling "incomplete")) :partial-transaction
      (or (str/includes? spelling "ambiguous")
          (str/includes? spelling "durability-unknown"))
      :ambiguous-commit-response
      (str/includes? spelling "stale") :stale-revision
      (str/includes? spelling "corrupt") :corrupt-frame
      (str/includes? spelling "budget") :budget
      (or (str/includes? spelling "queue")
          (str/includes? spelling "full")) :full-queue
      (str/includes? spelling "deadline") :deadline
      (or (str/includes? spelling "unreachable")
          (str/includes? spelling "absent")
          (str/includes? spelling "permission")) :unreachable
      :else nil)))

(defn- throwable->failure [error]
  (or (some-> error ex-data :cold-fallback/failure)
      (some-> error ex-data :failure)
      (code->failure (or (some-> error ex-data :fram/code)
                         (some-> error ex-data :type)))
      (when (instance? java.io.IOException error) :unreachable)
      :unreachable))

(defn- daemon-thread-factory []
  (reify ThreadFactory
    (newThread [_ runnable]
      (doto (Thread. runnable "beagle-store-probe-v1")
        (.setDaemon true)))))

(defn- bounded-probe! [probe! route deadline-ms]
  (let [executor (Executors/newSingleThreadExecutor (daemon-thread-factory))
        future (.submit executor
                        ^Callable
                        (reify Callable
                          (call [_]
                            (probe! (assoc route :deadlineMs deadline-ms)))))]
    (try
      (.get future deadline-ms TimeUnit/MILLISECONDS)
      (catch TimeoutException _
        (.cancel future true)
        {:status :failure :failure :deadline})
      (catch ExecutionException wrapped
        {:status :failure :failure (throwable->failure (.getCause wrapped))})
      (catch InterruptedException interrupted
        (.cancel future true)
        (.interrupt (Thread/currentThread))
        (throw interrupted))
      (finally
        (.shutdownNow executor)))))

(defn store-disabled-baseline-v1!
  "Run the ordinary source-driven compiler without contacting Store."
  [cold-compile! input]
  (when-not (ifn? cold-compile!)
    (fail! :cold-fallback/invalid-cold-compiler
           "cold compiler callback must be callable" {}))
  (cold-compile! input))

(defn- cold-result! [route input cold-compile! transition! failure]
  (let [[mode failure-class maintenance-status]
        (or (get store-failure-contract-v1 failure)
            (fail! :cold-fallback/invalid-failure
                   "adapter returned an unknown Store failure"
                   {:failure failure}))
        event {:phase :cold
               :mode mode
               :failure failure
               :failureClass failure-class}]
    (transition! event)
    {:output (store-disabled-baseline-v1! cold-compile! input)
     :source :cold
     :fact-backed? false
     :transition event
     :availability-receipt
     (receipt-v1 route mode failure-class "COLD-COMPILATION"
                 maintenance-status)}))

(defn run-with-cold-fallback-v1!
  "Probe one exact Store route once, then reuse it or compile cold once.

   PROBE! receives only the immutable route tuple plus :deadlineMs. It returns
   {:status :online :output value} or {:status :failure :failure keyword}.
   The compiler path has no Store mutation callback and performs no retry."
  [{:keys [input probe! cold-compile! transition! probe-deadline-ms]
    :or {transition! (fn [_] nil)}
    :as request}]
  (let [route (require-route!
               (select-keys
                (merge (or (when (map? input) (:store-route input)) {})
                       request)
                [:factStoreSpaceId :requestedSnapshotId
                 :requestedBranchRevisionId :probeDeadlineClass]))]
    (when-not (ifn? probe!)
      (fail! :cold-fallback/invalid-probe "Store probe must be callable" {}))
    (when-not (ifn? transition!)
      (fail! :cold-fallback/invalid-transition
             "cold transition callback must be callable" {}))
    (when-not (and (integer? probe-deadline-ms)
                   (pos? probe-deadline-ms))
      (fail! :cold-fallback/invalid-deadline
             "Store probe deadline must be a positive integer" {}))
    (let [probe-result (bounded-probe! probe! route probe-deadline-ms)]
      (if (and (map? probe-result) (= :online (:status probe-result))
               (contains? probe-result :output))
        {:output (:output probe-result)
         :source :store
         :fact-backed? true
         :transition nil
         :availability-receipt
         (receipt-v1 route "ONLINE" "NONE" "FACT-REUSE" "PUBLISHED")}
        (cold-result! route input cold-compile! transition!
                      (if (and (map? probe-result)
                               (= :failure (:status probe-result)))
                        (:failure probe-result)
                        :corrupt-frame))))))
