;; Ack, live view, and durable FRAMLOG must agree on content, count, and
;; per-writer order under concurrent socket writers, and expected-version OCC
;; must still fire on the race.
;; Run from the repository root: bb -cp out tests/framrpc_write_conc_test.clj
(require '[store.rpc :as wire]
         '[store.types :as t])

(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(def checks (atom []))
(def request-id (atom 0))

(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean ok)]))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 200) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn request! [port space operation payload & {:keys [expected page]}]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space operation expected page nil payload)))

(defn payload [response] (t/rpc-response-payload-value response))
(defn error-code [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))
(defn fields [value tag count-value] (wire/rpc-record-fields! value tag count-value))
(defn values-list [value] (wire/rpc-list-values! value))

(defn action-results [response]
  (let [[results] (fields (payload response) :rpc/mutation-result 1)]
    (mapv #(fields % :rpc/action-result 3) (values-list results))))

(defn paged-scan [port space pattern limit]
  (loop [cursor nil rows []]
    (let [response (request! port space :rpc/scan pattern
                             :page (wire/rpc-page-request! limit cursor))
          page (t/rpcresponse-page response)]
      (if (or (error-code response) (nil? page))
        {:error (or (error-code response) :missing-page) :rows rows}
        (let [[values] (fields (payload response) :rpc/triples 1)
              all-rows (into rows (values-list values))]
          (if (t/rpcpageresponse-done page)
            {:error nil :rows all-rows}
            (recur (t/rpc-page-response-cursor-value page) all-rows)))))))

;; One acked write == one FRAMLOG frame carrying exactly that proposition.
(defn assert-frames [path]
  (let [parsed (database/read-triple-log! path)]
    (assoc parsed :asserts
           (vec (for [frame (:frames parsed)
                      operation (:operations frame)
                      :when (= :assert (:store-action operation))]
                  {:tx-seq (:tx-seq frame)
                   :ordinal (:ordinal operation)
                   :operations (count (:operations frame))
                   :triple (:triple operation)})))))

(def writers 8)
(def per-writer 25)
(def rounds 10)

(def space "framrpc-write-conc")
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-framrpc-write-conc-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (java.io.File. scratch "history.framlog")))
(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(def watchdog
  (future
    (Thread/sleep 110000)
    (binding [*out* *err*] (println "framrpc-write-conc: hard timeout"))
    (System/exit 124)))

(defn note-value [w i] (str "w" w "-i" i))
(defn note-triple [w i] (t/triple (str "writer-" w) :note (note-value w i)))

(defn write! [proposition & {:keys [expected]}]
  (request! port space :rpc/assert
            (wire/rpc-write! proposition wire/rpc-subject-any nil)
            :expected expected))

(defn ack-of [response proposition]
  (let [code (error-code response)]
    (if code
      {:error code}
      (let [[[input-index changed coordinate]] (action-results response)]
        {:error nil
         :version (t/rpcresponse-served-version response)
         :input-index input-index
         :changed changed
         :occurrence-count 1
         :coordinate? (and coordinate (t/occurrence-coordinate? coordinate))
         :coordinate-version
         (when coordinate (t/triple-t3 (t/triple-t1 coordinate)))
         :coordinate-ordinal (when coordinate (t/triple-t3 coordinate))
         :proposition proposition}))))

(try
  (check! "listener starts on FRAMRPC v2"
          (some? (eventually #(request! port space :rpc/version wire/rpc-unit))))

  ;; ---- A. disjoint subjects: 8 socket writers x 25 sequential writes --------
  (let [start (java.util.concurrent.CountDownLatch. 1)
        done (java.util.concurrent.CountDownLatch. writers)
        started-ns (volatile! 0)
        acks (atom {})
        failures (atom [])]
    (dotimes [w writers]
      (.start
       (Thread.
        (fn []
          (try
            (.await start)
            (let [results (vec (for [i (range per-writer)]
                                 (ack-of (write! (note-triple w i))
                                         (note-triple w i))))]
              (swap! acks assoc w results))
            (catch Throwable error
              (swap! failures conj [w (str error)]))
            (finally (.countDown done)))))))
    (vreset! started-ns (System/nanoTime))
    (.countDown start)
    (.await done)
    (let [issued (* writers per-writer)
          elapsed-s (/ (- (System/nanoTime) @started-ns) 1.0e9)
          per-writer-acks @acks
          all-acks (mapcat val per-writer-acks)]
      (println (format "  BENCH A: %.1f writes/s (%d writes, %.3f s, K=%d)"
                       (/ issued elapsed-s) issued elapsed-s writers))
      (check! "A: no writer thread threw on the socket path" (empty? @failures))
      (check! (str "A: every one of " issued " concurrent writes is acked exactly once")
              (and (= writers (count per-writer-acks))
                   (every? #(= per-writer (count (val %))) per-writer-acks)
                   (every? #(and (nil? (:error %))
                                 (= 0 (:input-index %))
                                 (true? (:changed %))
                                 (= 1 (:occurrence-count %))
                                 (:coordinate? %)
                                 (= (:version %) (:coordinate-version %))
                                 (= 0 (:coordinate-ordinal %)))
                           all-acks)))
      (check! "A: acks carry the full 1..N transaction sequence, none shared"
              (= (set (range 1 (inc issued)))
                 (set (map :version all-acks))))

      ;; live view
      (let [scanned (paged-scan port space (wire/rpc-triple-pattern! nil :note nil) 64)
            expected (set (for [w (range writers) i (range per-writer)]
                            (note-triple w i)))]
        (check! "A: live view holds every fact exactly once (no lost, no duplicate)"
                (and (nil? (:error scanned))
                     (= issued (count (:rows scanned)))
                     (= expected (set (:rows scanned)))
                     (= issued (count (distinct (:rows scanned)))))))

      ;; durable FRAMLOG bytes, read through the database log reader
      (let [durable (assert-frames log-path)
            noted (filterv #(= :note (t/triple-t2 (:triple %))) (:asserts durable))
            by-writer (group-by #(t/triple-t1 (:triple %)) noted)
            version-of (into {} (map (juxt :proposition :version) all-acks))
            sequencer @server/commit-sequencer-stats]
        (check! "A: FRAMLOG is a whole, untorn generation of one frame per write"
                (and (nil? (:torn-tail durable))
                     (= issued (count (:frames durable)))
                     (= (mapv inc (range issued))
                        (mapv :tx-seq (:frames durable)))
                     (= issued (:frames sequencer))
                     (< (:barriers sequencer) (:frames sequencer))
                     (= (:barriers sequencer) (:publications sequencer))))
        (check! "A: the durable log holds each acked fact exactly once"
                (and (= issued (count noted))
                     (= issued (count (distinct (map :triple noted))))
                     (every? #(and (= 1 (:operations %)) (= 0 (:ordinal %))) noted)))
        (check! "A: per-writer file order == issue order (no reorder within a subject)"
                (every? (fn [w]
                          (= (mapv #(note-value w %) (range per-writer))
                             (mapv #(t/triple-t3 (:triple %))
                                   (get by-writer (str "writer-" w)))))
                        (range writers)))
        (check! "A: per-writer :tx-seq is strictly increasing in the log"
                (every? (fn [w]
                          (let [sequences (mapv :tx-seq (get by-writer (str "writer-" w)))]
                            (and (= per-writer (count sequences))
                                 (apply < sequences))))
                        (range writers)))
        (check! "A: every ack names the exact FRAMLOG frame that carries its fact"
                (and (= issued (count version-of))
                     (every? #(= (get version-of (:triple %)) (:tx-seq %)) noted))))))

  ;; ---- B. same subject: expected-version OCC under a concurrent race --------
  (let [before (t/rpcresponse-served-version
                (request! port space :rpc/version wire/rpc-unit))
        start (java.util.concurrent.CountDownLatch. 1)
        done (java.util.concurrent.CountDownLatch. writers)
        outcomes (atom [])
        failures (atom [])]
    (dotimes [w writers]
      (.start
       (Thread.
        (fn []
          (try
            (.await start)
            (dotimes [i rounds]
              (let [head (t/rpcresponse-served-version
                          (request! port space :rpc/version wire/rpc-unit))
                    value (str "occ-" w "-" i)
                    proposition (t/triple "occ-target" :title value)
                    response (write! proposition :expected head)]
                (swap! outcomes conj
                       {:value value
                        :error (error-code response)
                        :version (t/rpcresponse-served-version response)
                        :proposition proposition})))
            (catch Throwable error
              (swap! failures conj [w (str error)]))
            (finally (.countDown done)))))))
    (.countDown start)
    (.await done)
    (let [attempts (* writers rounds)
          results @outcomes
          landed (filterv #(nil? (:error %)) results)
          rejected (filterv #(some? (:error %)) results)
          head (t/rpcresponse-served-version
                (request! port space :rpc/version wire/rpc-unit))
          durable (assert-frames log-path)
          titles (filterv #(= :title (t/triple-t2 (:triple %))) (:asserts durable))]
      (check! "B: no writer thread threw on the racing socket path" (empty? @failures))
      (check! (str "B: every one of " attempts
                   " racing attempts is acked or typed-conflict, none vanish")
              (and (= attempts (count results))
                   (every? #(or (nil? (:error %)) (= :rpc/conflict (:error %)))
                           results)))
      (check! (str "B: OCC still fires under the race (" (count rejected)
                   " conflicts of " attempts ")")
              (pos? (count rejected)))
      (check! "B: the head advanced by exactly the number of acked writes"
              (= (+ before (count landed)) head))
      (check! "B: the durable log holds every acked racer and no rejected one"
              (and (= (count landed) (count titles))
                   (= (set (map :proposition landed)) (set (map :triple titles)))
                   (= (set (map :version landed)) (set (map :tx-seq titles)))))
      (check! "B: a conflict reports a real head between the race's endpoints"
              (every? #(<= before (:version %) head) rejected))))

  ;; ---- C. explicit stale expected-version probe -----------------------------
  (let [stale-base (t/rpcresponse-served-version
                    (request! port space :rpc/version wire/rpc-unit))
        advanced (mapv #(write! (t/triple "stale-probe" :advance %)) (range 5))
        response (write! (t/triple "stale-probe" :title "stale-write")
                         :expected stale-base)
        head (t/rpcresponse-served-version
              (request! port space :rpc/version wire/rpc-unit))
        durable (assert-frames log-path)
        live (paged-scan port space
                         (wire/rpc-triple-pattern! "stale-probe" nil nil) 64)]
    (check! "C: the five advancing writes all landed"
            (every? #(nil? (error-code %)) advanced))
    (check! "C: a write on a five-commit-stale expected version is refused"
            (= :rpc/conflict (error-code response)))
    (check! "C: the refused write moved no version"
            (= (+ stale-base 5) head))
    (check! "C: the refused write left no trace in the durable log"
            (and (= head (count (:frames durable)))
                 (not-any? #(= "stale-write" (t/triple-t3 (:triple %)))
                           (:asserts durable))))
    (check! "C: the live view holds the five advances and not the stale write"
            (and (nil? (:error live))
                 (= (set (map #(t/triple "stale-probe" :advance %) (range 5)))
                    (set (:rows live))))))

  (finally
    (future-cancel watchdog)
    (server/shutdown!)
    (deref server 3000 nil)))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println (str "\nFRAMRPC concurrent writers: " (count @checks) "/"
                    (count @checks) " PASS ("
                    writers " writers x " per-writer " writes, "
                    writers " x " rounds " OCC racers)"))
      (shutdown-agents))
    (do
      (println (str "\nFRAMRPC concurrent writers: " (count failures)
                    " FAILED — log kept at " log-path))
      (shutdown-agents)
      (System/exit 1))))
