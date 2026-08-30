;; Focused JVM Store subscription regression. The durable Store history is the
;; replay authority; this gate covers cursor identity, bounded signalling,
;; adapter equivalence, lease expiry, and the unchanged Native RPC boundary.
(require '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.rpc-subscription :as subscription]
         '[store.rpc-subscription-jvm :as adapter]
         '[store.types :as t])

(load-file "server.clj")

(def failures (atom []))
(def passes (atom 0))
(def request-sequence (atom 4100))

(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (if ok
    (swap! passes inc)
    (swap! failures conj label)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond
        value value
        (>= attempt 240) nil
        :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn caught-code [f]
  (try
    (f)
    nil
    (catch Throwable error
      (let [data (ex-data error)]
        (or (:store/code data) (:code data) (:type data))))))

(defn cursor-version [cursor]
  (subscription/storecoordinate-version
   (subscription/subscriptioncursor-coordinate cursor)))

(defn cursor-generation [cursor]
  (subscription/subscriptioncursor-generation cursor))

(defn cursor-range [acknowledged observed]
  [(cursor-version acknowledged) (cursor-version observed)])

(defn normalized-summary [summary]
  (let [baseline (first (:open summary))
        normalize-range (fn [values] (mapv #(- % baseline) values))]
    {:open (normalize-range (:open summary))
     :event (normalize-range (:event summary))
     :errors (:errors summary)
     :resume (normalize-range (:resume summary))}))

(def subscription-surface-paths
  ["src/store/rpc.bclj"
   "src/store/rpc_subscription.bclj"
   "src/store/rpc_subscription_jvm.bclj"
   "out/store/rpc.clj"
   "out/store/rpc_subscription.clj"
   "out/store/rpc_subscription_jvm.clj"])

(def legacy-vocabulary
  #"(?i)(recipient|awaited|peer/run|transport|\bnorth\b|\bagent\b)")

(def vocabulary-hits
  (into {}
        (keep (fn [path]
                (let [hits (vec (re-seq legacy-vocabulary (slurp path)))]
                  (when (seq hits) [path hits]))))
        subscription-surface-paths))

(defn minted-generation-sample []
  (let [coordinate (subscription/store-coordinate!
                    "mint-incarnation" 7 "mint-space" 0)
        registry (subscription/new-registry! coordinate (constantly 0))
        generations
        (mapv (fn [_]
                (let [session (subscription/new-session registry)
                      opened (subscription/open-session! session nil 5000)]
                  (cursor-generation
                   (subscription/subscriptionopened-observed opened))))
              (range 256))]
    (subscription/reset-registry! registry)
    generations))

(defn embedded-equivalence []
  (let [coordinate-0 (subscription/store-coordinate!
                      "embedded-incarnation" 9 "equivalence-space" 0)
        coordinate-1 (subscription/store-coordinate!
                      "embedded-incarnation" 9 "equivalence-space" 1)
        coordinate-2 (subscription/store-coordinate!
                      "embedded-incarnation" 9 "equivalence-space" 2)
        registry (subscription/new-registry! coordinate-0 (constantly 0))
        session (subscription/new-session registry)
        opened (subscription/open-session! session nil 5000)
        opened-ack (subscription/subscriptionopened-acknowledged opened)
        opened-observed (subscription/subscriptionopened-observed opened)
        generation (cursor-generation opened-observed)
        _activated (subscription/activate-open! session)
        _published (subscription/publish-coordinate! registry coordinate-1)
        notice (subscription/poll-notice! session 0)
        event-ack (subscription/subscriptionnotice-acknowledged notice)
        event-observed (subscription/subscriptionnotice-observed notice)
        _delivered (subscription/mark-delivered! session notice)
        wrong-generation-code
        (caught-code
         #(subscription/acknowledge!
           session
           (subscription/->SubscriptionCursor
            (str generation "-wrong") coordinate-1)))
        ahead-code
        (caught-code
         #(subscription/acknowledge!
           session
           (subscription/->SubscriptionCursor generation coordinate-2)))
        acknowledged (subscription/acknowledge! session event-observed)
        acknowledged-cursor
        (subscription/subscriptionacknowledged-cursor acknowledged)
        stale-code
        (caught-code
         #(subscription/acknowledge!
           session
           (subscription/->SubscriptionCursor generation coordinate-0)))
        _retired
        (subscription/retire-session!
         session subscription/disconnected-retirement)
        disconnected-reason (subscription/session-retirement session)
        _advanced (subscription/publish-coordinate! registry coordinate-2)
        resumed-session (subscription/new-session registry)
        resumed (subscription/open-session!
                 resumed-session acknowledged-cursor 5000)
        resumed-ack (subscription/subscriptionopened-acknowledged resumed)
        resumed-observed (subscription/subscriptionopened-observed resumed)
        result
        {:summary
         {:open (cursor-range opened-ack opened-observed)
          :event (cursor-range event-ack event-observed)
          :errors [wrong-generation-code ahead-code stale-code]
          :resume (cursor-range resumed-ack resumed-observed)}
         :first-generation generation
         :resumed-generation (cursor-generation resumed-observed)
         :resume-cursor acknowledged-cursor
         :disconnected-reason disconnected-reason}]
    (subscription/reset-registry! registry)
    result))

(defn coalescing-observation []
  (let [coordinate (fn [version]
                     (subscription/store-coordinate!
                      "coalesce-incarnation" 3 "coalesce-space" version))
        registry (subscription/new-registry! (coordinate 0) (constantly 0))
        session (subscription/new-session registry)
        opened (subscription/open-session! session nil 5000)
        _activated (subscription/activate-open! session)
        _one (subscription/publish-coordinate! registry (coordinate 1))
        _two (subscription/publish-coordinate! registry (coordinate 2))
        _three (subscription/publish-coordinate! registry (coordinate 3))
        notice (subscription/poll-notice! session 0)
        second-notice (subscription/poll-notice! session 0)
        result {:range (cursor-range
                        (subscription/subscriptionnotice-acknowledged notice)
                        (subscription/subscriptionnotice-observed notice))
                :second second-notice
                :capacity subscription/subscription-handoff-capacity
                :opened-version
                (cursor-version
                 (subscription/subscriptionopened-observed opened))}]
    (subscription/reset-registry! registry)
    result))

(defn restart-rejection-code [resume-cursor]
  (let [restarted-coordinate
        (subscription/store-coordinate!
         "restarted-incarnation" 1 "equivalence-space" 2)
        registry (subscription/new-registry!
                  restarted-coordinate (constantly 0))
        session (subscription/new-session registry)]
    (caught-code #(subscription/open-session!
                  session resume-cursor 5000))))

(defn local-error-response [space operation error]
  (let [data (ex-data error)
        code (or (:store/code data) (:code data) (:type data)
                 :rpc/internal-error)]
    (wire/rpc-response!
     space operation 0 nil
     (wire/rpc-error!
      code false
      (or (.getMessage ^Throwable error) "subscription request failed")
      nil)
     nil)))

(defn blocked-writer-expiry []
  (let [coordinate
        (subscription/store-coordinate!
         "blocked-incarnation" 1 "blocked-space" 0)
        registry (subscription/new-registry!
                  coordinate adapter/monotonic-now-ns!)
        pipe-input (java.io.PipedInputStream. 1)
        pipe-output (java.io.PipedOutputStream. pipe-input)
        socket (java.net.Socket.)
        socket-close-forwarder
        (future
          (loop []
            (if (.isClosed socket)
              (try (.close pipe-output) (catch Throwable _ nil))
              (do
                (Thread/sleep 1)
                (recur)))))
        connection (adapter/new-connection registry socket pipe-output)
        request (wire/rpc-request!
                 "blocked-space" :rpc/subscribe nil nil nil
                 (wire/rpc-subscription-request! nil 100))
        started (System/nanoTime)
        writer
        (future
          (try
            (adapter/handle-request-and-write!
             connection 9901 request local-error-response)
            :returned
            (catch Throwable _ :unblocked)))
        result (deref writer 3000 :timed-out)
        elapsed-ms (quot (- (System/nanoTime) started) 1000000)
        retirement
        (subscription/session-retirement
         (adapter/connection-session connection))
        active (subscription/active-generation-count! registry)
        socket-closed (.isClosed socket)]
    (try (.close socket) (catch Throwable _ nil))
    (deref socket-close-forwarder 1000 nil)
    (try (.close pipe-input) (catch Throwable _ nil))
    (try (.close pipe-output) (catch Throwable _ nil))
    {:result result
     :elapsed-ms elapsed-ms
     :socket-closed socket-closed
     :retirement retirement
     :active active}))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)]
    (.getLocalPort socket)))

(defn connect! [port]
  (doto (java.net.Socket.)
    (.connect (java.net.InetSocketAddress. "127.0.0.1" port) 5000)
    (.setSoTimeout 5000)
    (.setTcpNoDelay true)))

(defn send-request! [socket request]
  (let [request-id (swap! request-sequence inc)
        packet (wire/store-rpc-request-packet request-id request)
        output (.getOutputStream socket)]
    (.write output (wire/store-rpc-encode-packet-v2! packet))
    (.flush output)
    request-id))

(defn read-packet! [socket]
  (server/read-rpc-packet! (.getInputStream socket)))

(defn response [packet]
  (some-> packet t/storerpcpacketv2-response))

(defn response-error-code [packet]
  (some-> packet response t/rpcresponse-error t/rpcerror-code))

(defn response-payload [packet]
  (some-> packet response t/rpc-response-payload-value))

(defn request-response! [port space operation request-payload]
  (with-open [socket (connect! port)]
    (let [request-id
          (send-request!
           socket
           (wire/rpc-request!
            space operation nil nil nil request-payload))
          packet (read-packet! socket)]
      (when (and packet
                 (= request-id (t/storerpcpacketv2-request-id packet)))
        packet))))

(defn decode-open [packet]
  (when-let [error-code (response-error-code packet)]
    (throw (ex-info "subscription OPEN failed" {:code error-code})))
  (let [[acknowledged-wire observed-wire]
        (wire/rpc-subscription-open-fields! (response-payload packet))]
    {:acknowledged (subscription/wire-cursor! acknowledged-wire)
     :observed (subscription/wire-cursor! observed-wire)}))

(defn open-socket! [socket space resume-cursor lease-ms]
  (let [request-id
        (send-request!
         socket
         (wire/rpc-request!
          space :rpc/subscribe nil nil nil
          (wire/rpc-subscription-request!
           (when resume-cursor
             (subscription/cursor-wire! resume-cursor))
           lease-ms)))
        packet (read-packet! socket)]
    (when-not (= request-id (t/storerpcpacketv2-request-id packet))
      (throw (ex-info "OPEN response request id mismatch" {})))
    (assoc (decode-open packet)
           :request-id request-id
           :packet packet)))

(defn decode-event [packet]
  (let [[acknowledged-wire observed-wire]
        (wire/rpc-subscription-event-fields! (response-payload packet))]
    {:acknowledged (subscription/wire-cursor! acknowledged-wire)
     :observed (subscription/wire-cursor! observed-wire)}))

(defn send-ack! [socket space cursor]
  (let [request-id
        (send-request!
         socket
         (wire/rpc-request!
          space :rpc/subscription-ack nil nil nil
          (wire/rpc-subscription-ack!
           (subscription/cursor-wire! cursor))))
        packet (read-packet! socket)]
    (when-not (= request-id (t/storerpcpacketv2-request-id packet))
      (throw (ex-info "ACK response request id mismatch" {})))
    packet))

(defn decode-acknowledged [packet]
  (let [[cursor-wire]
        (wire/rpc-subscription-acknowledged-fields!
         (response-payload packet))]
    (subscription/wire-cursor! cursor-wire)))

(defn commit! [port space marker]
  (let [packet
        (request-response!
         port space :rpc/assert
         (wire/rpc-write!
          (t/triple marker :subscription/value true)
          wire/rpc-subject-any nil))]
    (when-let [code (response-error-code packet)]
      (throw (ex-info "subscription fixture commit failed" {:code code})))
    (t/rpcresponse-served-version (response packet))))

(defn socket-equivalence! [port space]
  (let [subscriber (connect! port)]
    (try
      (let [opened (open-socket! subscriber space nil 5000)
            opened-ack (:acknowledged opened)
            opened-observed (:observed opened)
            generation (cursor-generation opened-observed)
            collision
            (with-open [other (connect! port)]
              (open-socket! other space nil 5000))
            collision-generation (cursor-generation (:observed collision))
            committed-version (commit! port space "socket-equivalence-1")
            event-packet (read-packet! subscriber)
            event (decode-event event-packet)
            event-ack (:acknowledged event)
            event-observed (:observed event)
            coordinate-1
            (subscription/subscriptioncursor-coordinate event-observed)
            coordinate-2
            (subscription/store-coordinate!
             (subscription/storecoordinate-incarnation coordinate-1)
             (subscription/storecoordinate-store-generation coordinate-1)
             (subscription/storecoordinate-space coordinate-1)
             (inc (subscription/storecoordinate-version coordinate-1)))
            wrong-code
            (response-error-code
             (send-ack!
              subscriber space
              (subscription/->SubscriptionCursor
               (str generation "-wrong") coordinate-1)))
            ahead-code
            (response-error-code
             (send-ack!
              subscriber space
              (subscription/->SubscriptionCursor generation coordinate-2)))
            acknowledged-packet (send-ack! subscriber space event-observed)
            acknowledged-cursor (decode-acknowledged acknowledged-packet)
            stale-code
            (response-error-code
             (send-ack! subscriber space opened-observed))
            _closed (.close subscriber)
            disconnected?
            (eventually
             #(when (zero?
                     (subscription/active-generation-count!
                      @server/subscription-registry))
                true))
            next-version (commit! port space "socket-equivalence-2")
            resumed-socket (connect! port)
            resumed
            (try
              (open-socket! resumed-socket space acknowledged-cursor 5000)
              (finally (.close resumed-socket)))
            resumed-ack (:acknowledged resumed)
            resumed-observed (:observed resumed)]
        {:summary
         {:open (cursor-range opened-ack opened-observed)
          :event (cursor-range event-ack event-observed)
          :errors [wrong-code ahead-code stale-code]
          :resume (cursor-range resumed-ack resumed-observed)}
         :generations-differ? (not= generation collision-generation)
         :resume-generation-new?
         (not= generation (cursor-generation resumed-observed))
         :disconnect-retired? (boolean disconnected?)
         :event-shape?
         (and (= :event (t/storerpcpacketv2-kind event-packet))
              (= (:request-id opened)
                 (t/storerpcpacketv2-request-id event-packet))
              (= :rpc/subscription-event
                 (t/rpcresponse-op (response event-packet)))
              (= committed-version (cursor-version event-observed)))
         :ack-shape?
         (and (nil? (response-error-code acknowledged-packet))
              (= acknowledged-cursor event-observed))
         :resume-current?
         (= next-version (cursor-version resumed-observed))})
      (finally
        (try (.close subscriber) (catch Throwable _ nil))))))

(check! "subscription surface contains no legacy listener-routing vocabulary"
        (empty? vocabulary-hits))

(def minted-generations (minted-generation-sample))
(check! "server-minted generation sequence is collision-free under one clock tick"
        (and (= 256 (count minted-generations))
             (= 256 (count (set minted-generations)))))

(def embedded (embedded-equivalence))
(check! "embedded ACK bounds reject wrong generation, ahead, and stale cursors"
        (= [:rpc/subscription-generation-mismatch
            :rpc/subscription-unobserved-ack
            :rpc/subscription-stale-ack]
           (get-in embedded [:summary :errors])))

(check! "disconnect preserves exactly the last ACK and resume mints a new generation"
        (and (= :disconnected (:disconnected-reason embedded))
             (not= (:first-generation embedded)
                   (:resumed-generation embedded))
             (= [1 2] (get-in embedded [:summary :resume]))))

(check! "a fresh Store incarnation rejects the old resume cursor before lookup"
        (= :rpc/subscription-incarnation-mismatch
           (restart-rejection-code (:resume-cursor embedded))))

(def coalesced (coalescing-observation))
(check! "one-slot nonblocking handoff coalesces commits to the newest coordinate"
        (and (= 1 (:capacity coalesced))
             (= [0 3] (:range coalesced))
             (nil? (:second coalesced))))

(def blocked (blocked-writer-expiry))
(check! "independent monotonic expiry closes a writer blocked on OPEN output"
        (and (= :unblocked (:result blocked))
             (:socket-closed blocked)
             (= :lease-expired (:retirement blocked))
             (zero? (:active blocked))
             (< (:elapsed-ms blocked) 2500)))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-rpc-subscription-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-path (str (io/file scratch "history.storelog")))
(def space "rpc-subscription-test")
(def port (free-port))
(def server-run (future (server/serve! port log-path space :active)))

(try
  (check! "JVM listener starts with a fresh subscription registry"
          (some?
           (eventually
            #(let [packet
                   (request-response! port space :rpc/version wire/rpc-unit)]
               (when (and packet
                          (nil? (response-error-code packet))
                          @server/subscription-registry)
                 packet)))))

  (check! "Native RPC remains exactly fourteen operations and excludes subscribe"
          (and (= 14 (count server/native-rpc-operations))
               (= :unsupported
                  (server/native-op-disposition :rpc/subscribe))
               (subscription/subscription-operation? :rpc/subscribe)
               (subscription/subscription-operation?
                :rpc/subscription-ack)))

  (let [socket-result (socket-equivalence! port space)]
    (check! "real socket OPEN generations are minted uniquely and disconnect retires"
            (and (:generations-differ? socket-result)
                 (:resume-generation-new? socket-result)
                 (:disconnect-retired? socket-result)))

    (check! "embedded and framed-socket cursor ranges and ACK errors are equivalent"
            (= (normalized-summary (:summary embedded))
               (normalized-summary (:summary socket-result))))

    (check! "socket EVENT/ACK framing preserves delivered and current coordinates"
            (and (:event-shape? socket-result)
                 (:ack-shape? socket-result)
                 (:resume-current? socket-result))))

  (finally
    (server/shutdown!)
    (deref server-run 3000 nil)))

(shutdown-agents)

(if (seq @failures)
  (do
    (println "\nStore RPC subscription:" (count @failures) "FAILED")
    (System/exit 1))
  (println "\nStore RPC subscription:" @passes "PASS"))
