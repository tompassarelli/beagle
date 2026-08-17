;; Differential proof for server.clj query-cursor-position! (binary search).
;; Run: bb -cp out tests/query_cursor_binary_search_test.clj
(require '[clojure.java.io :as io]
         '[framrpc :as wire]
         '[fram.query :as query]
         '[fram.types :as t])

(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(def failures (atom []))
(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (when-not ok (swap! failures conj label)))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 200) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn fields [value tag count-value] (wire/rpc-record-fields! value tag count-value))
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
  (loop [cursor nil rows [] served nil]
    (let [response (request! port space :rpc/query
                             (wire/rpc-query-request! plan wire/query-current)
                             :page (wire/rpc-page-request! limit cursor))
          page (t/rpcresponse-page response)]
      (if (error-code response)
        {:error (error-code response) :rows rows}
        (let [rows' (into rows (query-rows response))
              served' (or served (t/rpcresponse-served-version response))]
          (if (t/rpcpageresponse-done page)
            {:error nil :rows rows' :served served'}
            (recur (t/rpc-page-response-cursor-value page) rows' served')))))))

(def row-count 1200)
(def scratch
  (.toFile (java.nio.file.Files/createTempDirectory
            "fram-query-cursor-binary-search-"
            (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (io/file scratch "history.framlog")))
(def space "query-cursor-binary-search")
(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(try
  (check! "listener starts" (some? (eventually #(request! port space :rpc/version wire/rpc-unit))))

  ;; bulk-load rows in bounded batches (1MiB request body ceiling per frame)
  (doseq [chunk (partition-all 200 (range row-count))]
    (let [actions (mapv (fn [i] (wire/rpc-action!
                                  :rpc/assert (t/triple (str "row-" i) :cursor-row i)
                                  wire/rpc-subject-any))
                         chunk)
          response (request! port space :rpc/batch (wire/rpc-batch! actions nil))]
      (check! (str "batch " (first chunk) " asserts cleanly") (nil? (error-code response)))))

  ;; Reference order computed independently of the server's own sort/cursor
  ;; code: query/row-key applied client-side to every inserted row.
  (let [expected (vec (sort-by query/row-key
                                (mapv (fn [i] [(str "row-" i) i]) (range row-count))))
        plan (row-plan)
        small-limit (drain-paged port space plan 7)
        large-limit (drain-paged port space plan 191)]
    (check! "small-limit (7) binary-search drain has no error"
            (nil? (:error small-limit)))
    (check! "large-limit (191) binary-search drain has no error"
            (nil? (:error large-limit)))
    (check! "small-limit drain returns every row exactly once, in row-key order"
            (= expected (:rows small-limit)))
    (check! "large-limit drain returns every row exactly once, in row-key order"
            (= expected (:rows large-limit)))
    (check! "two different page sizes locate identical cursors and rows"
            (= (:rows small-limit) (:rows large-limit))))

  ;; A cursor pins its snapshot version, so retraction after minting can't
  ;; make the boundary row absent; tamper a real cursor's row instead.
  (let [plan (row-plan)
        first-page (request! port space :rpc/query (wire/rpc-query-request! plan wire/query-current)
                             :page (wire/rpc-page-request! 5 nil))
        cursor (t/rpc-page-response-cursor-value (t/rpcresponse-page first-page))
        [snapshot-version digest ordinal _after-row]
        (fields cursor :query/cursor 4)
        tampered-cursor (wire/rpc-query-cursor!
                          snapshot-version digest ordinal
                          (wire/rpc-query-row! ["row-nonexistent" -1]))
        next-page (request! port space :rpc/query (wire/rpc-query-request! plan wire/query-current)
                            :page (wire/rpc-page-request! 5 tampered-cursor))]
    (check! "cursor pointing at a row absent from its snapshot fails :query-cursor-mismatch"
            (= :query-cursor-mismatch (error-code next-page))))

  (finally
    ;; serve! blocks in accept, which ignores interrupts: only shutdown! stops
    ;; the non-daemon connection workers, so cancelling the future can't exit.
    (server/shutdown!)
    (deref server 3000 nil)))

(shutdown-agents)

(let [failure-count (count @failures)]
  (if (pos? failure-count)
    (do (println "\nquery-cursor-binary-search:" failure-count "FAILED") (System/exit 1))
    (println "\nquery-cursor-binary-search: all checks PASS")))
