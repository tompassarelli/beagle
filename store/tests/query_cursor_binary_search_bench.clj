;; BENCH: time a full :rpc/query drain (10k rows, page limit 100).
;; Run: bb -cp out tests/query_cursor_binary_search_bench.clj
(require '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.types :as t])

(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 200) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn fields [value tag count-value] (wire/rpc-packet-fields! value tag count-value))
(defn values-list [value] (wire/rpc-list-values! value))
(defn payload [response] (t/rpc-response-payload-value response))
(defn error-code [response] (some-> response t/rpcresponse-error t/rpcerror-code))

(defn request! [port space operation payload & {:keys [page]}]
  (native-rpc-client/request!
   port 1 (wire/rpc-request! space operation nil page nil payload)))

(defn query-rows [response]
  (mapv (fn [row] (let [[values] (fields row :query/row 1)] (values-list values)))
        (let [[values] (fields (payload response) :query/rows 1)] (values-list values))))

(defn row-plan []
  (let [x (wire/rpc-query-variable! "x") y (wire/rpc-query-variable! "y")
        predicate (wire/rpc-query-constant! :cursor-row)]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "row")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "row" [x y])
         [(wire/rpc-query-relation! "triple" [x predicate y] false)])])])))

(defn drain-paged [port space plan limit]
  (loop [cursor nil rows 0]
    (let [response (request! port space :rpc/query
                             (wire/rpc-query-request! plan wire/query-current)
                             :page (wire/rpc-page-request! limit cursor))
          page (t/rpcresponse-page response)]
      (when (error-code response) (throw (ex-info "bench query failed" {:code (error-code response)})))
      (let [rows' (+ rows (count (query-rows response)))]
        (if (t/rpcpageresponse-done page)
          rows'
          (recur (t/rpc-page-response-cursor-value page) rows'))))))

(def row-count 10000)
(def scratch
  (.toFile (java.nio.file.Files/createTempDirectory
            "store-query-cursor-bench-"
            (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (io/file scratch "history.storelog")))
(def space "query-cursor-bench")
(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(eventually #(request! port space :rpc/version wire/rpc-unit))

(doseq [chunk (partition-all 200 (range row-count))]
  (request! port space :rpc/batch
           (wire/rpc-batch!
            (mapv (fn [i] (wire/rpc-action! :rpc/assert (t/triple (str "row-" i) :cursor-row i)
                                            wire/rpc-subject-any))
                  chunk)
            nil)))

(let [plan (row-plan)
      start (System/nanoTime)
      total (drain-paged port space plan 100)
      elapsed-ms (/ (- (System/nanoTime) start) 1e6)]
  (println (str "drained " total " rows at limit 100 in " (format "%.1f" elapsed-ms) " ms")))

;; serve! blocks in accept, which ignores interrupts: only shutdown! stops
;; the non-daemon connection workers, so cancelling the future can't exit.
(server/shutdown!)
(deref server 3000 nil)

(shutdown-agents)
