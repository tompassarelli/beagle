;; Scratch-only STORERPC workload driver for the JVM resource harness.
;; The Store engine remains in typed Beagle; this file is an irreducible JVM
;; benchmark/client boundary, like store/bench/in-class/adapters/store.clj.
(require '[cheshire.core :as json]
         '[clojure.string :as str]
         '[store.rpc :as wire]
         '[store.rt :as rt]
         '[store.types :as t])

(import '[java.nio.charset StandardCharsets]
        '[java.security MessageDigest]
        '[java.util BitSet]
        '[java.util.concurrent Callable ConcurrentLinkedQueue Executors TimeUnit]
        '[java.util.concurrent.atomic AtomicBoolean AtomicInteger AtomicLong])

(defn fail! [message data]
  (throw (ex-info message data)))

(defn parse-positive-long [label value]
  (let [parsed (parse-long value)]
    (when-not (and parsed (pos? parsed))
      (fail! (str label " must be a positive integer")
             {:label label :value value}))
    parsed))

(defn corpus-triple [index]
  (let [subject-index (quot index 3)
        slot (mod index 3)
        [predicate value]
        (case slot
          0 [:kind "thread"]
          1 [:title (str "title-" subject-index)]
          2 [:owner (str "@owner-" (mod subject-index 32))])]
    (t/triple (str "@resource-" subject-index) predicate value)))

(defn update-digest! [^MessageDigest digest index]
  (.update digest
           (.getBytes (str index "\t" (pr-str (corpus-triple index)) "\n")
                      StandardCharsets/UTF_8)))

(defn hex [bytes]
  (apply str (map #(format "%02x" (bit-and 0xff %)) bytes)))

(defn corpus-digest [triple-count]
  (let [digest (MessageDigest/getInstance "SHA-256")]
    (dotimes [index (int triple-count)]
      (update-digest! digest index))
    (hex (.digest digest))))

(defn response-error [response]
  (some-> response t/rpcresponse-error))

(defn checked-response! [response context]
  (when-let [error (response-error response)]
    (fail! (str context " failed")
           {:context context
            :code (t/rpcerror-code error)
            :message (t/rpcerror-message error)
            :retryable (t/rpcerror-retryable error)}))
  response)

(defn request! [session space operation payload]
  (checked-response!
   (rt/native-session-request!
    session (wire/rpc-request! space operation nil nil nil payload))
   (name operation)))

(defn record-fields! [value tag count-value]
  (wire/rpc-record-fields! value tag count-value))

(defn payload [response]
  (t/rpc-response-payload-value response))

(defn mutation-count! [response expected]
  (let [[encoded-results]
        (record-fields! (payload response) :rpc/mutation-result 1)
        results (wire/rpc-list-values! encoded-results)]
    (when-not (= expected (count results))
      (fail! "mutation acknowledgement count differs from request"
             {:expected expected :observed (count results)}))
    (doseq [result results]
      (let [[_index changed _occurrence]
            (record-fields! result :rpc/action-result 3)]
        (when-not changed
          (fail! "mutation acknowledgement reported unchanged data" {}))))
    (count results)))

(defn status! [session space]
  (let [[state live-count engine _cache]
        (record-fields!
         (payload (request! session space :rpc/status wire/rpc-unit))
         :rpc/status 4)]
    {:state (name state) :liveTriples live-count :engine (name engine)}))

(defn command-probe [port space]
  (with-open [session (rt/open-native-session! port)]
    (let [version (request! session space :rpc/version wire/rpc-unit)]
      (merge {:mode "probe" :servedVersion (t/rpcresponse-served-version version)}
             (status! session space)))))

(defn batch-actions [start end]
  (mapv (fn [index]
          (wire/rpc-action! :rpc/assert (corpus-triple index)
                            wire/rpc-subject-any))
        (range start end)))

(defn seed-worker [port space triple-count next-batch batch-size]
  (reify Callable
    (call [_]
      (with-open [session (rt/open-native-session! port)]
        (loop [acknowledged 0]
          (let [batch-index (.getAndIncrement ^AtomicInteger next-batch)
                start (* batch-index batch-size)]
            (if (>= start triple-count)
              acknowledged
              (let [end (min triple-count (+ start batch-size))
                    actions (batch-actions start end)
                    response
                    (request! session space :rpc/batch
                              (wire/rpc-batch! actions nil))]
                (mutation-count! response (count actions))
                (recur (+ acknowledged (count actions)))))))))))

(defn command-seed [port space triple-count workers]
  (let [batch-size (min 200 wire/rpc-v2-max-batch-actions)
        next-batch (AtomicInteger. 0)
        executor (Executors/newFixedThreadPool workers)
        started (System/nanoTime)]
    (try
      (let [tasks (mapv (fn [_]
                          (seed-worker port space triple-count
                                       next-batch batch-size))
                        (range workers))
            futures (.invokeAll executor tasks)
            acknowledged (reduce + (map #(.get %) futures))
            elapsed-ms (/ (- (System/nanoTime) started) 1e6)]
        (when-not (= triple-count acknowledged)
          (fail! "seed acknowledgement count differs from corpus"
                 {:expected triple-count :acknowledged acknowledged}))
        {:mode "seed"
         :triples triple-count
         :acknowledged acknowledged
         :workers workers
         :maxActive workers
         :batchSize batch-size
         :elapsedMs elapsed-ms
         :logicalDigest (corpus-digest triple-count)})
      (finally
        (.shutdownNow executor)
        (.awaitTermination executor 5 TimeUnit/SECONDS)))))

(defn expected-index [triple triple-count]
  (let [subject (t/triple-t1 triple)
        predicate (t/triple-t2 triple)
        value (t/triple-t3 triple)
        matched (and (string? subject)
                     (re-matches #"@resource-([0-9]+)" subject))]
    (when-not matched
      (fail! "scan returned a non-corpus subject" {:triple triple}))
    (let [subject-index (parse-long (second matched))
          slot (case predicate :kind 0 :title 1 :owner 2 nil)]
      (when (nil? slot)
        (fail! "scan returned a non-corpus predicate" {:triple triple}))
      (let [index (+ (* subject-index 3) slot)]
        (when (or (neg? index) (>= index triple-count)
                  (not= triple (corpus-triple index)))
          (fail! "scan returned a malformed corpus triple"
                 {:index index :triple triple}))
        index))))

(defn response-triples! [response]
  (let [[encoded]
        (record-fields! (payload response) :rpc/triples 1)]
    (wire/rpc-list-values! encoded)))

(defn scan-page! [session space pattern cursor]
  (checked-response!
   (rt/native-session-request!
    session
    (wire/rpc-request!
     space :rpc/scan nil (wire/rpc-page-request! 200 cursor) nil pattern))
   "rpc/scan"))

(defn scan-corpus! [session space triple-count]
  (let [seen (BitSet. (int triple-count))
        pattern (wire/rpc-triple-pattern! nil nil nil)]
    (loop [cursor nil observed 0 pages 0]
      (let [response (scan-page! session space pattern cursor)
            rows (response-triples! response)]
        (doseq [row rows]
          (let [index (expected-index row triple-count)]
            (when (.get seen (int index))
              (fail! "scan returned a duplicate corpus triple" {:index index}))
            (.set seen (int index))))
        (let [next-observed (+ observed (count rows))
              page (t/rpcresponse-page response)]
          (when-not page
            (fail! "paged scan response omitted page metadata" {}))
          (if (t/rpcpageresponse-done page)
            (do
              (when-not (and (= triple-count next-observed)
                             (= triple-count (.cardinality seen)))
                (fail! "scanned corpus count differs from expected"
                       {:expected triple-count
                        :observed next-observed
                        :unique (.cardinality seen)}))
              {:observed next-observed
               :unique (.cardinality seen)
               :pages (inc pages)})
            (let [next-cursor (t/rpc-page-response-cursor-value page)]
              (when-not next-cursor
                (fail! "nonterminal scan page omitted its cursor" {}))
              (recur next-cursor next-observed (inc pages)))))))))

(defn validate! [session space]
  (let [[valid encoded-violations]
        (record-fields!
         (payload (request! session space :rpc/validate wire/rpc-unit))
         :rpc/validation 2)
        violations (wire/rpc-list-values! encoded-violations)]
    (when-not (and valid (empty? violations))
      (fail! "Store validation reported corruption"
             {:valid valid :violations violations}))
    {:valid valid :violations (count violations)}))

(defn command-verify [port space triple-count]
  (with-open [session (rt/open-native-session! port)]
    (let [started (System/nanoTime)
          status-before (status! session space)
          scan (scan-corpus! session space triple-count)
          validation (validate! session space)
          status-after (status! session space)
          elapsed-ms (/ (- (System/nanoTime) started) 1e6)]
      (when-not (and (= triple-count (:liveTriples status-before))
                     (= triple-count (:liveTriples status-after)))
        (fail! "status live count differs from corpus"
               {:expected triple-count
                :before (:liveTriples status-before)
                :after (:liveTriples status-after)}))
      {:mode "verify"
       :expected triple-count
       :observed (:observed scan)
       :unique (:unique scan)
       :pages (:pages scan)
       :logicalDigest (corpus-digest triple-count)
       :validationValid (:valid validation)
       :validationViolations (:violations validation)
       :elapsedMs elapsed-ms})))

(defn command-checkpoint [port space]
  (with-open [session (rt/open-native-session! port)]
    (let [started (System/nanoTime)
          response (request! session space :rpc/checkpoint wire/rpc-unit)
          [version watermark created-at crc bytes]
          (record-fields! (payload response) :rpc/checkpoint 5)]
      {:mode "checkpoint"
       :version version
       :watermarkBytes watermark
       :createdAtMs created-at
       :crc32 crc
       :snapshotBytes bytes
       :elapsedMs (/ (- (System/nanoTime) started) 1e6)})))

(defn active-call [^AtomicInteger active ^AtomicInteger maximum f]
  (let [now (.incrementAndGet active)]
    (loop []
      (let [prior (.get maximum)]
        (when (and (> now prior) (not (.compareAndSet maximum prior now)))
          (recur))))
    (try (f) (finally (.decrementAndGet active)))))

(defn percentile [values fraction]
  (if (empty? values)
    nil
    (let [sorted (vec (sort values))
          index (min (dec (count sorted))
                     (int (Math/floor (* fraction (count sorted)))))]
      (/ (nth sorted index) 1e6))))

(defn exact-subject-read! [session space triple-count sequence]
  (let [subject-count (inc (quot (dec triple-count) 3))
        subject-index (mod sequence subject-count)
        expected (min 3 (- triple-count (* subject-index 3)))
        pattern (wire/rpc-triple-pattern!
                 (str "@resource-" subject-index) nil nil)
        response (request! session space :rpc/scan pattern)
        rows (response-triples! response)]
    (when-not (= expected (count rows))
      (fail! "agent-shaped read returned the wrong row count"
             {:subject subject-index :expected expected :observed (count rows)}))
    (doseq [row rows] (expected-index row triple-count))
    (count rows)))

(defn writer-pair! [session space writer-index sequence]
  (let [triple (t/triple (str "@resource-ephemeral-" writer-index "-" sequence)
                         :bench/value (str "value-" sequence))]
    (mutation-count!
     (request! session space :rpc/assert
               (wire/rpc-write! triple wire/rpc-subject-any nil)) 1)
    (mutation-count!
     (request! session space :rpc/retract
               (wire/rpc-write! triple wire/rpc-subject-any nil)) 1)
    2))

(defn command-agent [port space triple-count duration-seconds]
  (let [sessions (mapv (fn [_] (rt/open-native-session! port)) (range 32))
        executor (Executors/newFixedThreadPool 8)
        stop (AtomicBoolean. false)
        active (AtomicInteger. 0)
        maximum (AtomicInteger. 0)
        read-latencies (ConcurrentLinkedQueue.)
        read-requests (AtomicLong. 0)
        write-operations (AtomicLong. 0)
        listener-requests (AtomicLong. 0)
        started (System/nanoTime)
        deadline (+ started (* duration-seconds 1000000000))
        reader-tasks
        (mapv
         (fn [reader-index]
           (reify Callable
             (call [_]
               (let [session (nth sessions (inc reader-index))]
                 (loop [sequence reader-index]
                   (when (< (System/nanoTime) deadline)
                     (let [request-start (System/nanoTime)]
                       (active-call active maximum
                                    #(exact-subject-read!
                                      session space triple-count sequence))
                       (.add read-latencies (- (System/nanoTime) request-start))
                       (.incrementAndGet read-requests)
                       (recur (+ sequence 4)))))))))
         (range 4))
        writer-tasks
        (mapv
         (fn [writer-index]
           (reify Callable
             (call [_]
               (let [session (nth sessions (+ 5 writer-index))]
                 (loop [sequence 0]
                   (when (< (System/nanoTime) deadline)
                     (.addAndGet
                      write-operations
                      (long (active-call
                             active maximum
                             #(writer-pair! session space writer-index sequence))))
                     (recur (inc sequence))))))))
         (range 3))
        listener-task
        (reify Callable
          (call [_]
            (let [session (first sessions)]
              (loop []
                (when (< (System/nanoTime) deadline)
                  (active-call active maximum #(status! session space))
                  (.incrementAndGet listener-requests)
                  (Thread/sleep 250)
                  (recur))))))
        tasks (into [listener-task] (concat reader-tasks writer-tasks))]
    (try
      (let [futures (mapv #(.submit executor ^Callable %) tasks)]
        (doseq [future futures] (.get future))
        (.set stop true)
        (let [ended (System/nanoTime)
              elapsed-ms (/ (- ended started) 1e6)
              latencies (vec read-latencies)
              writes (.get write-operations)]
          (when (or (not= 32 (count sessions)) (> (.get maximum) 8)
                    (zero? (.get read-requests)) (zero? writes)
                    (zero? (.get listener-requests)))
            (fail! "agent-shaped workload did not exercise its declared shape"
                   {:connections (count sessions)
                    :max-active (.get maximum)
                    :reads (.get read-requests)
                    :writes writes
                    :listener (.get listener-requests)}))
          {:mode "agent"
           :connections 32
           :activeWorkers 8
           :maxActive (.get maximum)
           :listenerConnections 1
           :listenerRequests (.get listener-requests)
           :readRequests (.get read-requests)
           :readP50Ms (percentile latencies 0.50)
           :readP95Ms (percentile latencies 0.95)
           :readP99Ms (percentile latencies 0.99)
           :durableWriteOperations writes
           :durableWriteOpsPerSecond (/ writes (/ elapsed-ms 1000.0))
           :elapsedMs elapsed-ms
           :errors 0}))
      (finally
        (.set stop true)
        (.shutdownNow executor)
        (.awaitTermination executor 5 TimeUnit/SECONDS)
        (doseq [session sessions]
          (try (.close session) (catch Throwable _ nil)))))))

(defn dispatch [arguments]
  (let [[command port-value space & rest-values] arguments
        port (int (parse-positive-long "port" port-value))]
    (case command
      "probe" (command-probe port space)
      "seed" (let [[count-value workers-value] rest-values]
               (command-seed port space
                             (parse-positive-long "triple count" count-value)
                             (int (parse-positive-long "workers" workers-value))))
      "verify" (command-verify port space
                               (parse-positive-long "triple count"
                                                    (first rest-values)))
      "checkpoint" (command-checkpoint port space)
      "agent" (let [[count-value duration-value] rest-values]
                (command-agent port space
                               (parse-positive-long "triple count" count-value)
                               (parse-positive-long "duration" duration-value)))
      (fail! "unknown resource workload command" {:command command}))))

(try
  (println (json/generate-string (dispatch *command-line-args*)))
  (catch Throwable error
    (binding [*out* *err*]
      (println (json/generate-string
                {:mode "failure"
                 :message (.getMessage error)
                 :data (ex-data error)}))
      (.printStackTrace error))
    (System/exit 1))
  (finally
    (shutdown-agents)))
