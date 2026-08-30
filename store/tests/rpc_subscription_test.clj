;; JVM-only Store RPC subscription regression: OPEN, EVENT, ACK, generation
;; identity, expiry, disconnect, and the unchanged Native RPC boundary.
(require '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.rpc-subscription :as subscription]
         '[store.types :as t])

(load-file "server.clj")

(def failures (atom []))
(def request-sequence (atom 4100))
(def first-open-identity (atom nil))
(def last-observed-version (atom nil))

(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (when-not ok (swap! failures conj label)))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond
        value value
        (>= attempt 200) nil
        :else (do (Thread/sleep 25) (recur (inc attempt)))))))

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

(defn error-code [packet]
  (some-> packet response t/rpcresponse-error t/rpcerror-code))

(defn payload [packet]
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
  (check! "JVM listener starts"
          (some?
           (eventually
            #(let [packet
                   (request-response! port space :rpc/version wire/rpc-unit)]
               (when (and packet (nil? (error-code packet))) packet)))))

  (check! "subscription stays outside the exact fourteen Native RPC operations"
          (and (= 14 (count server/native-rpc-operations))
               (= :unsupported
                  (server/native-op-disposition :rpc/subscribe))
               (subscription/subscription-operation? :rpc/subscribe)
               (subscription/subscription-operation?
                :rpc/subscription-ack)))

  (let [subscriber (connect! port)]
    (try
      (let [open-id
            (send-request!
             subscriber
             (wire/rpc-request!
              space :rpc/subscribe nil nil nil
              (wire/rpc-subscription-request!
               "north-listener" "awaited-peer/run" "store-rpc-v2"
               "generation-a" -1 5000)))
            open-packet (read-packet! subscriber)
            open-response (response open-packet)
            [identity baseline acknowledged]
            (wire/rpc-subscription-open-fields! (payload open-packet))
            identity-fields
            (wire/rpc-subscription-identity-fields! identity)
            [recipient awaited transport generation observed-at expires-at]
            identity-fields]
        (reset! first-open-identity identity)
        (check! "OPEN returns the exact full-generation identity and baseline"
                (and (= :response (t/storerpcpacketv2-kind open-packet))
                     (= open-id (t/storerpcpacketv2-request-id open-packet))
                     (= :rpc/subscribe (t/rpcresponse-op open-response))
                     (nil? (t/rpcresponse-error open-response))
                     (= 6 (count identity-fields))
                     (= ["north-listener" "awaited-peer/run"
                         "store-rpc-v2" "generation-a"]
                        [recipient awaited transport generation])
                     (t/instant? observed-at)
                     (t/instant? expires-at)
                     (= baseline (t/rpcresponse-served-version open-response))
                     (= -1 acknowledged)))

        (with-open [collision (connect! port)]
          (send-request!
           collision
           (wire/rpc-request!
            space :rpc/subscribe nil nil nil
            (wire/rpc-subscription-request!
             "other-listener" "other-peer/run" "store-rpc-v2"
             "generation-a" -1 5000)))
          (check! "a live generation id cannot be opened twice"
                  (= :rpc/subscription-generation-active
                     (error-code (read-packet! collision))))

          (send-request!
           collision
           (wire/rpc-request!
            space :rpc/subscribe nil nil nil
            (wire/rpc-subscription-request!
             "other-listener" "other-peer/run" "store-rpc-v2"
             "generation-ahead" (inc baseline) 5000)))
          (check! "OPEN rejects a cursor ahead of Store publication"
                  (= :rpc/subscription-cursor-ahead
                     (error-code (read-packet! collision)))))

        (let [mutation
              (request-response!
               port space :rpc/assert
               (wire/rpc-write!
                (t/triple "subscription" :observed true)
                wire/rpc-subject-any nil))
              committed-version
              (some-> mutation response t/rpcresponse-served-version)
              event-packet (read-packet! subscriber)
              event-response (response event-packet)
              [event-identity event-acknowledged event-version]
              (wire/rpc-subscription-event-fields! (payload event-packet))]
          (reset! last-observed-version committed-version)
          (check! "a commit after OPEN emits one causally ordered EVENT"
                  (and mutation
                       (nil? (error-code mutation))
                       (> committed-version baseline)
                       (= :event (t/storerpcpacketv2-kind event-packet))
                       (= open-id
                          (t/storerpcpacketv2-request-id event-packet))
                       (= :rpc/subscription-event
                          (t/rpcresponse-op event-response))
                       (= committed-version
                          (t/rpcresponse-served-version event-response))
                       (= identity event-identity)
                       (= acknowledged event-acknowledged)
                       (= committed-version event-version)))

          (let [[recipient awaited transport generation observed-at expires-at]
                identity-fields
                wrong-identity
                (wire/rpc-subscription-identity!
                 (str recipient "-wrong") awaited transport generation
                 observed-at expires-at)]
            (send-request!
             subscriber
             (wire/rpc-request!
              space :rpc/subscription-ack nil nil nil
              (wire/rpc-subscription-ack!
               wrong-identity committed-version)))
            (check! "ACK rejects a different OPEN identity"
                    (= :rpc/subscription-identity-mismatch
                       (error-code (read-packet! subscriber)))))

          (send-request!
           subscriber
           (wire/rpc-request!
            space :rpc/subscription-ack nil nil nil
            (wire/rpc-subscription-ack!
             identity (inc committed-version))))
          (check! "ACK rejects an undelivered version"
                  (= :rpc/subscription-unobserved-ack
                     (error-code (read-packet! subscriber))))

          (send-request!
           subscriber
           (wire/rpc-request!
            space :rpc/subscription-ack nil nil nil
            (wire/rpc-subscription-ack!
             identity committed-version)))
          (let [ack-packet (read-packet! subscriber)
                [ack-identity ack-version]
                (wire/rpc-subscription-acknowledged-fields!
                 (payload ack-packet))]
            (check! "ACK advances only the delivered full-generation cursor"
                    (and (nil? (error-code ack-packet))
                         (= identity ack-identity)
                         (= committed-version ack-version))))

          (send-request!
           subscriber
           (wire/rpc-request!
            space :rpc/subscription-ack nil nil nil
            (wire/rpc-subscription-ack!
             identity (dec committed-version))))
          (check! "ACK rejects a stale cursor"
                  (= :rpc/subscription-stale-ack
                     (error-code (read-packet! subscriber))))))
      (finally
        (.close subscriber)))

    (check! "disconnect retires the exact generation"
            (some? (eventually #(when (zero?
                                       (subscription/active-generation-count
                                        server/subscription-registry))
                                  true)))))

  (with-open [reopened (connect! port)]
    (send-request!
     reopened
     (wire/rpc-request!
      space :rpc/subscribe nil nil nil
      (wire/rpc-subscription-request!
       "north-listener" "awaited-peer/run" "store-rpc-v2"
       "generation-a" @last-observed-version 5000)))
    (let [open-packet (read-packet! reopened)
          [reopened-identity _baseline _acknowledged]
          (wire/rpc-subscription-open-fields! (payload open-packet))]
      (check! "reopening a retired generation creates a new full identity"
              (and (nil? (error-code open-packet))
                   (not= @first-open-identity reopened-identity)))
      (send-request!
       reopened
       (wire/rpc-request!
        space :rpc/subscription-ack nil nil nil
        (wire/rpc-subscription-ack!
         @first-open-identity @last-observed-version)))
      (check! "an ACK from the retired generation cannot validate after reopen"
              (= :rpc/subscription-identity-mismatch
                 (error-code (read-packet! reopened))))))

  (eventually #(when (zero?
                      (subscription/active-generation-count
                       server/subscription-registry))
                 true))

  (with-open [expiring (connect! port)]
    (.setSoTimeout expiring 3000)
    (send-request!
     expiring
     (wire/rpc-request!
      space :rpc/subscribe nil nil nil
      (wire/rpc-subscription-request!
       "expiring-listener" "awaited-peer/run" "store-rpc-v2"
       "generation-expiring" 0 100)))
    (let [open-packet (read-packet! expiring)]
      (check! "short-lived generation opens before its deadline"
              (and open-packet (nil? (error-code open-packet)))))
    (check! "expiry retires the generation and closes its transport"
            (and
             (some? (eventually #(when (zero?
                                       (subscription/active-generation-count
                                        server/subscription-registry))
                                   true)))
             (try
               (nil? (read-packet! expiring))
               (catch java.net.SocketException _ true)))))

  (finally
    (server/shutdown!)
    (deref server-run 3000 nil)))

(check! "shutdown leaves no subscription generation"
        (zero? (subscription/active-generation-count
                server/subscription-registry)))

(shutdown-agents)

(if (seq @failures)
  (do
    (println "\nStore RPC subscription:" (count @failures) "FAILED")
    (System/exit 1))
  (println "\nStore RPC subscription: 16/16 PASS"))
