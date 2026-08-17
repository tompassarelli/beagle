;; Paired cache-cold FRAMRPC query latency at head 3001 versus as-of 3000.
;;   BEAGLE_STORE_SERVER_QUIET=1 env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp out bench/time-travel-query.clj
(require '[clojure.java.io :as io]
         '[database]
         '[store.rpc :as wire]
         '[store.types :as t])

(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(def space "time-travel-bench")
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-time-travel-bench-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (.getPath (io/file scratch "history.framlog")))
(def request-id (atom 0))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn request! [port payload]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space :rpc/query nil nil 60000 payload)))

(defn query-plan [proposition]
  (let [coordinate (wire/rpc-query-variable! "coordinate")
        action (wire/rpc-query-variable! "action")
        constant (wire/rpc-query-constant! proposition)]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "matched")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "matched" [coordinate action constant])
         [(wire/rpc-query-relation!
           "occurrence" [coordinate action constant] false)])])])))

(defn elapsed-ms [f]
  (let [started (System/nanoTime)
        value (f)]
    [(/ (double (- (System/nanoTime) started)) 1000000.0) value]))

(defn p95 [samples]
  (nth (vec (sort samples)) (dec (int (Math/ceil (* 0.95 (count samples)))))))

(defn drop-result-cache! []
  (reset! server/query-result-cache
          ((var-get #'server/empty-query-result-cache)
           @server/server-generation)))

(database/create-triple-log! log-path space)
(let [marker (t/triple "marker" :bench/value "stable")
      filler (t/triple "unrelated" :bench/value "toggle")
      frames
      (mapv (fn [sequence]
              {:tx-seq sequence
               :operations
               [{:ordinal 0
                 :action (if (or (= sequence 1) (even? sequence)) 1 2)
                 :triple (if (= sequence 1) marker filler)}]})
            (range 1 3002))]
  ((var-get #'database/append-frame-cohort-durable!) log-path frames false)
  (let [port (free-port)
        server (future (server/serve! port log-path space :active))
        plan (query-plan marker)
        head-payload (wire/rpc-query-request! plan wire/query-current)
        as-of-payload
        (wire/rpc-query-request! plan (wire/rpc-query-as-of! 3000))]
    (try
      (loop [attempt 0]
        (when-not (try (request! port head-payload) true
                       (catch Throwable _ false))
          (when (>= attempt 200)
            (throw (ex-info "time-travel bench server did not start" {})))
          (Thread/sleep 25)
          (recur (inc attempt))))
      ;; Build and validate the exact 3000 prefix checkpoint before paired trials.
      (#'server/drop-query-caches!)
      (let [[cold-root-ms _] (elapsed-ms #(request! port as-of-payload))]
      (let [head-samples (atom [])
            as-of-samples (atom [])]
        (dotimes [trial 20]
          (let [order (if (even? trial)
                        [[:head head-payload] [:as-of as-of-payload]]
                        [[:as-of as-of-payload] [:head head-payload]])]
            (doseq [[kind payload] order]
              (drop-result-cache!)
              (let [[elapsed response] (elapsed-ms #(request! port payload))]
                (when (t/rpcresponse-error response)
                  (throw (ex-info "time-travel bench query failed"
                                  {:kind kind
                                   :error (t/rpcerror-code
                                           (t/rpcresponse-error response))})))
                (swap! (if (= kind :head) head-samples as-of-samples)
                       conj elapsed)))))
        (let [head-p95 (p95 @head-samples)
              as-of-p95 (p95 @as-of-samples)
              ratio (/ as-of-p95 head-p95)]
          (println (format "time-travel query: head@3001 p95=%.3fms as-of@3000 p95=%.3fms ratio=%.3fx N=20 paired cache-cold"
                           head-p95 as-of-p95 ratio))
          (println (format "  cold decoded-root load=%.3fms (reported separately; bounded validated root remains hot)"
                           cold-root-ms))
          (println "  head-ms " (pr-str (mapv #(Double/parseDouble (format "%.3f" %)) @head-samples)))
          (println "  as-of-ms" (pr-str (mapv #(Double/parseDouble (format "%.3f" %)) @as-of-samples)))
          (when (> ratio 2.0)
            (System/exit 1)))))
      (finally
        (server/shutdown!)
        (deref server 3000 nil)))))

(shutdown-agents)
