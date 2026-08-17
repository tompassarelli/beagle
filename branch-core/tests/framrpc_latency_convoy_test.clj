;; A slow read must not convoy FRAMRPC writers, and a client disconnect must
;; stop the delayed work instead of leaving it running for a caller that is gone.
;; Run from the repository root: bb -cp out tests/framrpc_latency_convoy_test.clj
(require '[framrpc :as wire]
         '[fram.datalog :as datalog]
         '[fram.query :as query]
         '[fram.store :as store]
         '[fram.types :as t])

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
            (>= attempt 400) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn request! [port space operation payload & {:keys [expected page timeout]}]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space operation expected page timeout payload)))

(defn error-code [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))

(defn elapsed-ms [f]
  (let [started (System/nanoTime)
        value (f)]
    [(/ (- (System/nanoTime) started) 1e6) value]))

(defn shown [latencies] (mapv #(Double/parseDouble (format "%.1f" %)) latencies))

(def space "framrpc-latency-convoy")
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-framrpc-latency-convoy-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (java.io.File. scratch "history.framlog")))
(def port (free-port))
(def server (future (server/serve! port log-path space :active)))

(def watchdog
  (future
    (Thread/sleep 100000)
    (binding [*out* *err*] (println "framrpc-latency-convoy: hard timeout"))
    (System/exit 124)))

(def fixture-count 400)
(def delay-ms 2000)
(def fan-out 10)
(def solo-bound-ms 250.0)
(def fan-bound-ms 1000.0)

(defn write! [label index]
  (request! port space :rpc/assert
            (wire/rpc-write! (t/triple (str label "-" index) :convoy index)
                             wire/rpc-subject-any nil)))

(defn fan-writes [label]
  (let [pending (mapv (fn [index] (future (elapsed-ms #(write! label index))))
                      (range fan-out))
        results (mapv deref pending)]
    {:latencies (mapv first results) :responses (mapv second results)}))

;; Two body literals keep the plan off the direct one-triple path, so the read
;; runs through the whole-corpus projection the delay is injected into.
(defn joined-plan [relation predicate]
  (let [subject (wire/rpc-query-variable! "subject")
        value (wire/rpc-query-variable! "value")
        other (wire/rpc-query-variable! "other")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! relation)
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! relation [value])
         [(wire/rpc-query-relation!
           "triple" [subject (wire/rpc-query-constant! predicate) value] false)
          (wire/rpc-query-relation!
           "triple" [other (wire/rpc-query-constant! predicate) value] false)])])])))

(defn cross-plan [predicate]
  (let [left-subject (wire/rpc-query-variable! "left-subject")
        left-value (wire/rpc-query-variable! "left-value")
        right-subject (wire/rpc-query-variable! "right-subject")
        right-value (wire/rpc-query-variable! "right-value")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "cross")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "cross" [left-value right-value])
         [(wire/rpc-query-relation!
           "triple" [left-subject (wire/rpc-query-constant! predicate) left-value]
           false)
          (wire/rpc-query-relation!
           "triple" [right-subject (wire/rpc-query-constant! predicate) right-value]
           false)])])])))

(try
  (check! "listener starts on FRAMRPC v2"
          (some? (eventually #(request! port space :rpc/version wire/rpc-unit))))

  (doseq [batch (partition-all 100 (range fixture-count))]
    (request! port space :rpc/batch
              (wire/rpc-batch!
               (mapv (fn [index]
                       (wire/rpc-action! :rpc/assert
                                         (t/triple (str "fixture-" index) :fixture index)
                                         wire/rpc-subject-any))
                     batch)
               nil)))
  ;; The marked subset keeps the delayed read's reply under the unpaged row
  ;; bound while its projection still folds the whole corpus.
  (request! port space :rpc/batch
            (wire/rpc-batch!
             (mapv (fn [index]
                     (wire/rpc-action! :rpc/assert
                                       (t/triple (str "marker-" index) :marker index)
                                       wire/rpc-subject-any))
                   (range 3))
             nil))

  (let [baseline (fan-writes "baseline")
        baseline-max (apply max (:latencies baseline))]
    (check! (str "baseline: " fan-out " undisturbed concurrent writes all commit; observed "
                 (pr-str (shown (:latencies baseline))) "ms")
            (every? #(nil? (error-code %)) (:responses baseline)))

    ;; ---- A. a two-second read delay must not convoy the writer lock ---------
    (let [original query/run-plan-projected!
          entered (promise)]
      (with-redefs [query/run-plan-projected!
                    (fn [projection plan]
                      (deliver entered true)
                      (Thread/sleep delay-ms)
                      (original projection plan))]
        (let [slow (future
                     (elapsed-ms
                      #(request! port space :rpc/query
                                 (wire/rpc-query-request! (joined-plan "markers" :marker)
                                                          wire/query-current)
                                 :timeout 30000)))]
          (check! "A: the two-second read delay is observably in flight"
                  (and (deref entered 10000 nil)
                       (some? (eventually #(pos? (count @server/active-requests))))))
          (let [[solo-ms solo] (elapsed-ms #(write! "during-delay-solo" 0))]
            (check! (format "A: a lone write acks in %.1fms during the %dms read delay (<=%.0fms)"
                            solo-ms delay-ms solo-bound-ms)
                    (and (nil? (error-code solo)) (<= solo-ms solo-bound-ms))))
          (let [{:keys [latencies responses]} (fan-writes "during-delay")
                observed-max (apply max latencies)]
            (check! (str "A: all " fan-out " concurrent writes commit during the slow read")
                    (every? #(nil? (error-code %)) responses))
            (check! (str "A: every ack lands inside the delay; observed "
                         (pr-str (shown latencies)) "ms")
                    (every? #(<= % fan-bound-ms) latencies))
            (check! (format "A: the delay adds no write cost (max %.1fms vs %.1fms baseline)"
                            observed-max baseline-max)
                    (<= observed-max (+ (* 1.5 baseline-max) 100.0))))
          (let [[query-ms response] @slow]
            (check! (format "A: the read delay really executed outside the writer lock (%.1fms)"
                            query-ms)
                    (and (nil? (error-code response))
                         (>= query-ms (- delay-ms 100)))))))))

  ;; ---- B. a disconnect must cancel the running read, not orphan it ----------
  (let [original datalog/query-control
        captured (atom nil)]
    (with-redefs [datalog/query-control (fn [max-steps timeout-ms]
                                          (let [control (original max-steps timeout-ms)]
                                            (reset! captured control)
                                            control))]
      (with-open [socket (java.net.Socket.)]
        (.connect socket (java.net.InetSocketAddress. "127.0.0.1" (int port)) 1000)
        (let [output (.getOutputStream socket)]
          (.write output (wire/encode-rpc-frame-v2!
                          (wire/rpc-request-frame
                           900001
                           (wire/rpc-request!
                            space :rpc/query nil nil 60000
                            (wire/rpc-query-request! (cross-plan :fixture)
                                                     wire/query-current)))))
          (.flush output))
        (check! "B: the expensive read is observably running for the connected client"
                (some? (eventually #(and @captured
                                         (pos? (datalog/query-steps @captured))
                                         (pos? (count @server/active-requests))))))
        (.close socket)
        (let [[cancel-ms reason]
              (elapsed-ms #(eventually (fn [] @(datalog/querycontrol-cancelled @captured))))
              ;; The runner notices the cancel on its next step; sample after it lands.
              _ (Thread/sleep 200)
              steps (datalog/query-steps @captured)
              _ (Thread/sleep 400)
              settled (datalog/query-steps @captured)]
          (check! (format "B: the disconnect cancels the read in %.1fms (%s)"
                          cancel-ms (pr-str reason))
                  (= :client-disconnected reason))
          (check! (str "B: the cancelled read stops stepping (" steps " -> " settled ")")
                  (= steps settled))
          (check! "B: the abandoned request drains from the active set"
                  (some? (eventually #(empty? @server/active-requests))))))
      (let [[post-ms response] (elapsed-ms #(write! "after-disconnect" 0))]
        (check! (format "B: a post-disconnect write still acks in %.1fms (<=%.0fms)"
                        post-ms solo-bound-ms)
                (and (nil? (error-code response)) (<= post-ms solo-bound-ms))))))

  ;; ---- C. O(corpus) validation must not convoy writers ---------------------
  (let [original store/dump-term-store
        entered (promise)
        pinned-version (t/rpcresponse-served-version
                        (request! port space :rpc/version wire/rpc-unit))]
    (with-redefs [store/dump-term-store (fn [& arguments]
                                          (deliver entered true)
                                          (Thread/sleep delay-ms)
                                          (apply original arguments))]
      (let [slow (future (elapsed-ms #(request! port space :rpc/validate wire/rpc-unit)))]
        (check! "C: the two-second validate delay is observably in flight"
                (deref entered 10000 nil))
        (let [[solo-ms solo] (elapsed-ms #(write! "during-validate-solo" 0))]
          (check! (format "C: a lone write acks in %.1fms during the %dms validate (<=%.0fms)"
                          solo-ms delay-ms solo-bound-ms)
                  (and (nil? (error-code solo)) (<= solo-ms solo-bound-ms))))
        (let [{:keys [latencies responses]} (fan-writes "during-validate")]
          (check! (str "C: all " fan-out " concurrent writes commit during validate")
                  (every? #(nil? (error-code %)) responses))
          (check! (str "C: every validate-overlapped ack lands within "
                       (long fan-bound-ms) "ms; observed "
                       (pr-str (shown latencies)) "ms")
                  (every? #(<= % fan-bound-ms) latencies)))
        (let [[validate-ms validated] @slow]
          (check! (format "C: the slow validate completes from its pinned snapshot (%.1fms)"
                          validate-ms)
                  (and (nil? (error-code validated))
                       (= pinned-version (t/rpcresponse-served-version validated))
                       (>= validate-ms (- delay-ms 100))))))))

  (finally
    (future-cancel watchdog)
    (server/shutdown!)
    (deref server 3000 nil)))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println (str "\nFRAMRPC latency convoy: " (count @checks) "/" (count @checks)
                    " PASS"))
      (shutdown-agents))
    (do
      (println (str "\nFRAMRPC latency convoy: " (count failures) " FAILED"))
      (shutdown-agents)
      (System/exit 1))))
