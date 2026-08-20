;; W25 memory/build and warm end-to-end STORERPC query bars.
(require '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.rpc :as wire]
         '[store.store :as store]
         '[store.text-search :as text-search]
         '[store.types :as t])
(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(defn p95 [values]
  (nth (vec (sort values))
       (dec (int (Math/ceil (* 0.95 (count values)))))))

(defn heap-used []
  (let [runtime (Runtime/getRuntime)]
    (- (.totalMemory runtime) (.freeMemory runtime))))

(defn collect-heap! []
  (System/gc)
  (Thread/sleep 150)
  (heap-used))

(def corpus-50k
  (vec (for [i (range 50000)]
         (t/triple (str "@m" i) "body"
                   (str "common group" (mod i 500) " unique" i)))))

(def build-ms
  (vec
   (for [_ (range 10)]
     (let [started (System/nanoTime)
           source (text-search/build-source! corpus-50k (* 64 1024 1024))
           elapsed (/ (- (System/nanoTime) started) 1000000.0)]
       (when (zero? (text-search/source-weight source))
         (throw (ex-info "impossible empty text index" {})))
       elapsed))))
(def build-p95 (p95 build-ms))

(def heap-before (collect-heap!))
(def retained-source
  (text-search/build-source! corpus-50k (* 64 1024 1024)))
(def heap-after (collect-heap!))
(def heap-delta (max 0 (- heap-after heap-before)))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond
        value value
        (>= attempt 200) nil
        :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(def request-id (atom 0))
(defn request! [port space operation payload]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space operation nil nil
                      (when (= operation :rpc/query) 5000)
                      payload)))

(defn text-plan [needle]
  (let [entity (wire/rpc-query-variable! "entity")
        attribute (wire/rpc-query-variable! "attribute")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "hit")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "hit" [entity attribute])
         [(wire/rpc-query-relation!
           "text-match"
           [entity attribute (wire/rpc-query-constant! needle)] false)])])])))

(defn query-payload [needle]
  (wire/rpc-query-request! (text-plan needle) wire/query-current))

(defn error-code [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))

(defn row-count [response]
  (let [[rows] (wire/rpc-packet-fields!
                (t/rpc-response-payload-value response) :query/rows 1)]
    (count (wire/rpc-list-values! rows))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-text-perf-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (io/file scratch "text-perf.storelog")))
(def space "text-perf")
(def corpus-10k
  (vec (for [i (range 10000)]
         (t/triple (str "@e" i) "body"
                   (str "common group" (mod i 500) " unique" i)))))

(database/create-triple-log! log-path space)
(def seed-server (database/open-database! log-path space))
(def seed-result
  (database/commit!
   seed-server
   {:operations (mapv store/assert-operation corpus-10k)}))
(when-not (:ok seed-result)
  (throw (ex-info "failed to seed text performance corpus" seed-result)))
(def log-bytes-before-query (.length (io/file log-path)))

(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(defn timed-query [needle]
  (let [started (System/nanoTime)
        response (request! port space :rpc/query (query-payload needle))
        elapsed (/ (- (System/nanoTime) started) 1000000.0)]
    (when-let [code (error-code response)]
      (throw (ex-info "text performance query failed" {:code code})))
    [elapsed (row-count response)]))

(def rpc-results
  (try
    (when-not (eventually #(request! port space :rpc/version wire/rpc-unit))
      (throw (ex-info "text performance daemon did not start" {})))
    ;; The first text query owns the lazy index build; measured requests hit the
    ;; index cache but carry distinct query terms, so none can hit result cache.
    (timed-query "warmup-absent")
    (doseq [i (range 31 41)]
      (timed-query (str/join " " (repeat i "group42")))
      (timed-query
       (str "group42 " (str/join " " (repeat i "unique42")))))
    (reset! server/query-result-cache
            ((var server/empty-query-result-cache)
             @server/server-generation))
    (let [missing
          (vec (for [i (range 30)] (timed-query (str "absent" i))))
          one-token
          (vec (for [i (range 1 31)]
                 (timed-query (str/join " " (repeat i "group42")))))
          two-token
          (vec (for [i (range 1 31)]
                 (timed-query
                  (str "group42 " (str/join " " (repeat i "unique42"))))))]
      {:missing missing :one-token one-token :two-token two-token
       :cache @server/query-result-cache})
    (finally
      (server/shutdown!)
      (deref server 5000 nil))))

(def missing-p95 (p95 (mapv first (:missing rpc-results))))
(def one-token-p95 (p95 (mapv first (:one-token rpc-results))))
(def two-token-p95 (p95 (mapv first (:two-token rpc-results))))
(def result-counts
  [(set (map second (:missing rpc-results)))
   (set (map second (:one-token rpc-results)))
   (set (map second (:two-token rpc-results)))])
(def result-cache (:cache rpc-results))
(def log-bytes-after-query (.length (io/file log-path)))

(println
 (format "text-index perf: build-50k-p95=%.2fms heap-delta-50k=%.2fMiB estimated=%.2fMiB"
         build-p95 (/ heap-delta 1048576.0)
         (/ (text-search/source-weight retained-source) 1048576.0)))
(println
 (format "text-index perf: rpc/query warm p95 missing=%.2fms one-token=%.2fms two-token=%.2fms N=30"
         missing-p95 one-token-p95 two-token-p95))
(println
 (format "text-index perf: rows missing=%s one-token=%s two-token=%s result-cache misses=%d hits=%d (distinct needles by design: hits must be 0)"
         (nth result-counts 0) (nth result-counts 1) (nth result-counts 2)
         (:misses result-cache) (:hits result-cache)))

(def failures
  (cond-> []
    (>= build-p95 1000.0) (conj "50k build p95 is not under 1000ms")
    (>= heap-delta (* 32 1024 1024)) (conj "50k heap delta is not under 32MiB")
    (not (every? #(< % 50.0) [missing-p95 one-token-p95 two-token-p95]))
    (conj "warm rpc/query p95 is not under 50ms")
    (not= [#{0} #{20} #{1}] result-counts)
    (conj "query result counts do not match the bounded corpus")
    (not= 90 (:misses result-cache))
    (conj "measured requests did not all miss the result cache")
    (not= log-bytes-before-query log-bytes-after-query)
    (conj "text queries appended canonical log bytes")))

(if (empty? failures)
  (do
    (println "text-index perf: PASS")
    (shutdown-agents))
  (do
    (doseq [failure failures] (println "text-index perf: FAIL" failure))
    (System/exit 1)))
