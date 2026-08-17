;; Writer authority and FRAMRPC v2 JVM server integration.
(require '[babashka.process :as process]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.rpc :as wire]
         '[store.types :as t])

(load-file "writer_authority.clj")
(load-file "server.clj")
(load-file "tests/native_rpc_client.clj")

(when (= "hold" (first *command-line-args*))
  (let [[_ log ready] *command-line-args*
        handle (writer-authority/acquire! log)]
    (try
      (spit ready "ready\n")
      (Thread/sleep 30000)
      (finally (writer-authority/release! handle))))
  (System/exit 0))

(def failures (atom []))
(def request-id (atom 1000))

(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (when-not ok (swap! failures conj label)))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 240) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn response-error [response]
  (some-> response t/rpcresponse-error t/rpcerror-code))

(defn request! [port space operation payload]
  (native-rpc-client/request!
   port (swap! request-id inc)
   (wire/rpc-request! space operation nil nil nil payload)))

(defn direct-request! [space operation payload]
  (server/handle-rpc-request!
   (wire/rpc-request! space operation nil nil nil payload)
   {:cancelled (atom false) :query-control (atom nil)}))

(defn scan-values [response]
  (let [[values] (wire/rpc-record-fields!
                  (t/rpc-response-payload-value response) :rpc/triples 1)]
    (wire/rpc-list-values! values)))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-term-authority-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(let [log (str (io/file scratch "lock-only.framlog"))]
  (spit log "")
  (check! "nil role preserves active default"
          (= :active (writer-authority/server-role-from nil)))
  (check! "standby role is explicit"
          (= :standby (writer-authority/server-role-from "standby")))
  (check! "unknown role fails closed"
          (= :invalid-server-role
             (try (writer-authority/server-role-from "writer-ish") nil
                  (catch clojure.lang.ExceptionInfo error
                    (:code (ex-data error))))))
  (let [first (writer-authority/acquire! log)]
    (try
      (check! "first generation holds canonical-log authority"
              (writer-authority/held? first))
      (check! "overlapping generation cannot acquire the same log"
              (nil? (writer-authority/try-acquire! log)))
      (finally (writer-authority/release! first))))
  (let [successor (writer-authority/acquire! log)]
    (check! "successor acquires after predecessor release"
            (writer-authority/held? successor))
    (writer-authority/release! successor)))

;; Host-level native dispatcher: physical authority gates a typed occurrence
;; write before the durable transaction frame is appended.
(let [log (str (io/file scratch "direct.framlog"))
      space "direct-space"]
  (server/boot! log space :active)
  (try
    (check! "active server holds TermStore writer authority"
            (true? (:write-authorized (server/writer-authority-status))))
    (let [proposition (t/triple "A" :email "a@example.com")
          response (direct-request!
                    space :rpc/assert
                    (wire/rpc-write! proposition wire/rpc-subject-any nil))
          [[_ changed coordinate]]
          (let [[results]
                (wire/rpc-record-fields!
                 (t/rpc-response-payload-value response) :rpc/mutation-result 1)]
            (mapv #(wire/rpc-record-fields! % :rpc/action-result 3)
                  (wire/rpc-list-values! results)))]
      (check! "active write returns logical version and occurrence coordinate"
              (and changed (= 1 (t/rpcresponse-served-version response))
                   (t/occurrence-coordinate? coordinate)
                   (= space (t/triple-t1 (t/triple-t1 coordinate)))
                   (= 1 (t/triple-t3 (t/triple-t1 coordinate)))
                   (= 0 (t/triple-t3 coordinate)))))
    (let [append-var (ns-resolve 'database 'append-frame-cohort-durable!)
          original @append-var
          failure
          (with-redefs-fn
            {append-var
             (fn [path frames deflate?]
               (original path frames deflate?)
               (throw (ex-info "injected after force"
                               {:type :injected-post-force})))}
            #(direct-request!
              space :rpc/assert
              (wire/rpc-write! (t/triple "A" :email "second@example.com")
                               wire/rpc-subject-any nil)))
          status (server/writer-authority-status)]
      (check! "ambiguous native append fails closed after durable force"
              (= :durability-ambiguous (response-error failure)))
      (check! "reconciled ambiguity retains lock but removes write authority"
              (and (= :recovery-required
                      (get-in status [:database-recovery :status]))
                   (true? (:lock-held status))
                   (false? (:write-authorized status))))
      (check! "retry remains fenced while physical writer lock is held"
              (= :recovery-required
                 (response-error
                  (direct-request!
                   space :rpc/assert
                   (wire/rpc-write! (t/triple "A" :email "retry@example.com")
                                    wire/rpc-subject-any nil)))))
      (check! "ambiguity writes one tx2 frame, never duplicate tx2"
              (= [1 2] (mapv :tx-seq (:frames (database/read-triple-log! log))))))
    (finally (server/shutdown!))))

;; One active JVM writer, one JVM standby, and a refused duplicate active over
;; the same canonical FRAMLOG. All client traffic is FRAMRPC v2 binary.
(let [log (str (io/file scratch "shared.framlog"))
      space "shared-space"
      active-port (free-port)
      duplicate-port (free-port)
      standby-port (free-port)
      active
      (process/process
       ["clojure" "-M" "server.clj" "serve"
        (str active-port) log space]
       {:out :string :err :string
        :extra-env {"BEAGLE_STORE_SERVER_ROLE" "active"
                    "BEAGLE_STORE_TELEMETRY_LOG" nil}})]
  (try
    (check! "active JVM generation starts on the native listener"
            (some? (eventually #(request! active-port space :rpc/version
                                          wire/rpc-unit))))
    (let [duplicate
          (process/process
           ["clojure" "-M" "server.clj" "serve"
            (str duplicate-port) log space]
           {:out :string :err :string
            :extra-env {"BEAGLE_STORE_SERVER_ROLE" "active"
                        "BEAGLE_STORE_TELEMETRY_LOG" nil}})
          exited? (.waitFor ^Process (:proc duplicate)
                            6 java.util.concurrent.TimeUnit/SECONDS)
          result (when exited? @duplicate)]
      (when-not exited? (process/destroy-tree duplicate))
      (check! "second active JVM generation fails before serving"
              (and exited? (not (zero? (:exit result)))
                   (str/includes? (str (:out result) (:err result))
                                  "holds writer authority"))))
    (let [standby
          (process/process
           ["clojure" "-M" "server.clj" "serve"
            (str standby-port) log space]
           {:out :string :err :string
            :extra-env {"BEAGLE_STORE_SERVER_ROLE" "standby"
                        "BEAGLE_STORE_TELEMETRY_LOG" nil}})]
      (try
        (check! "standby JVM generation serves native reads"
                (some? (eventually #(request! standby-port space :rpc/status
                                              wire/rpc-unit))))
        (let [proposition (t/triple "blue-green" :status "visible")
              asserted
              (request! active-port space :rpc/assert
                        (wire/rpc-write! proposition wire/rpc-subject-any nil))]
          (check! "active JVM generation appends a typed transaction"
                  (and (nil? (response-error asserted))
                       (pos? (t/rpcresponse-served-version asserted))))
          (check! "standby rejects the same native mutation"
                  (= :rpc/writer-authority-required
                     (response-error
                      (request! standby-port space :rpc/assert
                                (wire/rpc-write!
                                 (t/triple "blue-green" :status "forbidden")
                                 wire/rpc-subject-any nil)))))
          (check! "standby refresh observes the active append"
                  (some? (eventually
                          #(let [response
                                 (request! standby-port space :rpc/scan
                                           (wire/rpc-triple-pattern!
                                            "blue-green" :status nil))]
                             (when (some #{proposition} (scan-values response))
                               response))))))
        (finally
          (process/destroy-tree standby)
          @standby)))
    (finally
      (process/destroy-tree active)
      @active)))

(shutdown-agents)

(if (seq @failures)
  (do
    (println (str "\n" (count @failures) " writer-authority checks failed"))
    (System/exit 1))
  (println "\nTermStore writer authority: all checks passed"))
