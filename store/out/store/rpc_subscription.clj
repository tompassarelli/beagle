(ns store.rpc-subscription
  (:require [store.rpc :as rpc]
            [store.types :as t])
  (:import [java.io OutputStream]
           [java.net Socket]
           [java.util.concurrent ArrayBlockingQueue]
           [java.util.concurrent TimeUnit]))

(def subscription-max-ttl-ms 86400000)

(def subscription-event-operation :rpc/subscription-event)

(def subscription-operations #{:rpc/subscribe :rpc/subscription-ack})

(defrecord SubscriptionRegistry [lock generations published-version last-observed-ms now-ms])

(defn subscriptionregistry-lock [r] (:lock r))

(defn subscriptionregistry-generations [r] (:generations r))

(defn subscriptionregistry-published-version [r] (:published-version r))

(defn subscriptionregistry-last-observed-ms [r] (:last-observed-ms r))

(defn subscriptionregistry-now-ms [r] (:now-ms r))

(defrecord SubscriptionConnection [registry socket output generation])

(defn subscriptionconnection-registry [r] (:registry r))

(defn subscriptionconnection-socket [r] (:socket r))

(defn subscriptionconnection-output [r] (:output r))

(defn subscriptionconnection-generation [r] (:generation r))

(defrecord SubscriptionResult [payload served-version])

(defn subscriptionresult-payload [r] (:payload r))

(defn subscriptionresult-served-version [r] (:served-version r))

(defn- subscription-fail! [code ^String message]
  (throw (ex-info message {:type code :store/code code :code code})))

(defn ^SubscriptionRegistry new-registry! [now-ms]
  (if (fn? now-ms) (->SubscriptionRegistry (Object.) (atom {}) (atom -1) (atom nil) now-ms) (subscription-fail! :rpc/subscription-invalid-clock "subscription registry requires a clock function")))

(def ^SubscriptionRegistry default-registry (new-registry! (fn [] (System/currentTimeMillis))))

(defn ^SubscriptionConnection new-connection [^SubscriptionRegistry registry ^Socket socket ^OutputStream output]
  (->SubscriptionConnection registry socket output (atom nil)))

(defn ^Boolean subscription-operation? [operation]
  (contains? subscription-operations operation))

(defn- registry-now-ms! [^SubscriptionRegistry registry]
  (let [value ((subscriptionregistry-now-ms registry))]
  (if (integer? value) value (subscription-fail! :rpc/subscription-invalid-clock "subscription registry clock must return Int"))))

(defn- millis->instant [value]
  (let [seconds (quot value 1000)
   millis (mod value 1000)]
  (t/instant seconds (* millis 1000000))))

(defn- ^String require-nonempty-string! [value ^String label]
  (if (and (string? value) (not (empty? value))) value (subscription-fail! :rpc/invalid-subscription (str label " must be a nonempty String"))))

(defn- require-version! [value ^String label]
  (if (and (integer? value) (>= value -1)) value (subscription-fail! :rpc/invalid-subscription (str label " must be an Int at least -1"))))

(defn- require-ttl! [value]
  (if (and (integer? value) (and (> value 0) (<= value subscription-max-ttl-ms))) value (subscription-fail! :rpc/invalid-subscription (str "subscription ttl-ms must be in [1," subscription-max-ttl-ms "]"))))

(defn- generation-state [^SubscriptionConnection connection]
  (deref (subscriptionconnection-generation connection)))

(defn- state-expires-ms! [state]
  (let [value (:expires-ms state)]
  (if (integer? value) value (subscription-fail! :rpc/subscription-invalid-state "subscription expires-ms must be an Int"))))

(defn- next-observed-ms-under-lock! [^SubscriptionRegistry registry]
  (let [now-ms (registry-now-ms! registry)
   previous (deref (subscriptionregistry-last-observed-ms registry))
   observed-ms (if (nil? previous) now-ms (if (integer? previous) (if (> now-ms previous) now-ms (+ previous 1)) (subscription-fail! :rpc/subscription-invalid-state "subscription last-observed-ms must be an Int")))]
  (reset! (subscriptionregistry-last-observed-ms registry) observed-ms)
  observed-ms))

(defn- ^Boolean same-live-generation? [^SubscriptionRegistry registry state]
  (identical? state (get (deref (subscriptionregistry-generations registry)) (:generation state))))

(defn- retire-under-lock! [^SubscriptionRegistry registry state reason ^Boolean close-socket]
  (if (same-live-generation? registry state) (do
  (swap! (subscriptionregistry-generations registry) dissoc (:generation state))))
  (let [connection (:connection state)]
  (if (identical? state (generation-state connection)) (do
  (reset! (subscriptionconnection-generation connection) nil))))
  (reset! (:state state) reason)
  (.offer ^ArrayBlockingQueue (:notifications state) -2)
  (if close-socket (do
  (try
  (.close ^Socket (:socket state))
  (catch Throwable _
    nil))))
  nil)

(defn- retire-generation! [state reason ^Boolean close-socket]
  (let [registry (:registry state)]
  (locking (subscriptionregistry-lock registry) (retire-under-lock! registry state reason close-socket))))

(defn reset-registry! [^SubscriptionRegistry registry]
  (locking (subscriptionregistry-lock registry) (let [states (vals (deref (subscriptionregistry-generations registry)))]
  (doseq [state states]
  (retire-under-lock! registry state :closed true))
  (reset! (subscriptionregistry-generations registry) {})
  (reset! (subscriptionregistry-published-version registry) -1)))
  nil)

(defn active-generation-count [^SubscriptionRegistry registry]
  (count (deref (subscriptionregistry-generations registry))))

(defn- ^Boolean signal-version-under-lock! [state version]
  (let [acknowledged (deref (:acknowledged-version state))
   offered (deref (:offered-version state))]
  (if (and (> version acknowledged) (> version offered)) (do
  (reset! (:offered-version state) version)
  (.poll ^ArrayBlockingQueue (:notifications state))
  (.offer ^ArrayBlockingQueue (:notifications state) version)
  true) false)))

(defn publish-version! [^SubscriptionRegistry registry version]
  (require-version! version "published version")
  (locking (subscriptionregistry-lock registry) (let [previous (deref (subscriptionregistry-published-version registry))]
  (if (< version previous) (do
  (subscription-fail! :rpc/subscription-version-regressed "published Store version regressed")))
  (reset! (subscriptionregistry-published-version registry) version)
  (let [now-ms (registry-now-ms! registry)]
  (reduce (fn [signalled state] (if (>= now-ms (state-expires-ms! state)) (do
  (retire-under-lock! registry state :expired true)
  signalled) (if (signal-version-under-lock! state version) (+ signalled 1) signalled))) 0 (vec (vals (deref (subscriptionregistry-generations registry)))))))))

(defn- ^SubscriptionResult open-generation! [^SubscriptionConnection connection request-id ^String space payload]
  (let [[recipient-value awaited-value transport-value generation-value acknowledged-value ttl-value] (rpc/rpc-subscription-request-fields! payload)
   recipient (require-nonempty-string! recipient-value "subscription recipient")
   awaited (require-nonempty-string! awaited-value "subscription awaited peer/run")
   transport (require-nonempty-string! transport-value "subscription transport")
   generation (require-nonempty-string! generation-value "subscription generation")
   acknowledged (require-version! acknowledged-value "subscription acknowledged-version")
   ttl-ms (require-ttl! ttl-value)
   registry (subscriptionconnection-registry connection)]
  (locking (subscriptionregistry-lock registry) (if (generation-state connection) (do
  (subscription-fail! :rpc/subscription-already-open "connection already owns a subscription generation"))) (if (contains? (deref (subscriptionregistry-generations registry)) generation) (do
  (subscription-fail! :rpc/subscription-generation-active "subscription generation is already active"))) (let [baseline (deref (subscriptionregistry-published-version registry))]
  (if (> acknowledged baseline) (do
  (subscription-fail! :rpc/subscription-cursor-ahead "subscription acknowledged-version is ahead of Store publication")))
  (let [observed-ms (next-observed-ms-under-lock! registry)
   expires-ms (+ observed-ms ttl-ms)
   identity (rpc/rpc-subscription-identity! recipient awaited transport generation (millis->instant observed-ms) (millis->instant expires-ms))
   state {:registry registry :connection connection :socket (subscriptionconnection-socket connection) :output (subscriptionconnection-output connection) :space space :request-id request-id :generation generation :identity identity :baseline-version baseline :observed-ms observed-ms :expires-ms expires-ms :acknowledged-version (atom acknowledged) :offered-version (atom baseline) :delivered-version (atom acknowledged) :notifications (ArrayBlockingQueue. 1) :delivery-lock (Object.) :state (atom :opening) :writer (atom nil)}]
  (swap! (subscriptionregistry-generations registry) assoc generation state)
  (reset! (subscriptionconnection-generation connection) state)
  (->SubscriptionResult (rpc/rpc-subscription-open! identity baseline acknowledged) baseline))))))

(defn- write-event! [state version]
  (locking (:delivery-lock state) (let [acknowledged (deref (:acknowledged-version state))]
  (if (and (= :active (deref (:state state))) (> version acknowledged)) (do
  (let [response (rpc/rpc-response! (:space state) subscription-event-operation version nil nil (rpc/rpc-subscription-event! (:identity state) acknowledged version))
   packet (rpc/store-rpc-event-packet (:request-id state) response)
   bytes (rpc/store-rpc-encode-packet-v2! packet)
   output ^OutputStream (:output state)]
  (locking output (.write output bytes) (.flush output))
  (reset! (:delivered-version state) version))))))
  nil)

(defn- writer-loop! [state]
  (try
  (loop []
  (let [registry (:registry state)
   remaining (- (state-expires-ms! state) (registry-now-ms! registry))]
  (if (and (= :active (deref (:state state))) (> remaining 0)) (let [version (.poll ^ArrayBlockingQueue (:notifications state) remaining TimeUnit/MILLISECONDS)]
  (cond
  (nil? version) (retire-generation! state :expired true)
  (neg? version) nil
  :else (do
  (write-event! state version)
  (recur)))) (retire-generation! state :expired true))))
  (catch InterruptedException _
    (retire-generation! state :closed false))
  (catch Throwable _
    (retire-generation! state :transport-closed true)))
  nil)

(defn activate-open! [^SubscriptionConnection connection operation]
  (if (= operation :rpc/subscribe) (do
  (let [state (generation-state connection)]
  (if state (do
  (locking (:delivery-lock state) (if (= :opening (deref (:state state))) (do
  (reset! (:delivered-version state) (:baseline-version state))
  (reset! (:state state) :active)
  (reset! (:writer state) (future-call (fn [] (writer-loop! state))))))))))))
  nil)

(defn- ^SubscriptionResult acknowledge-generation! [^SubscriptionConnection connection payload]
  (let [[identity observed-value] (rpc/rpc-subscription-ack-fields! payload)
   _ (rpc/rpc-subscription-identity-fields! identity)
   observed (require-version! observed-value "subscription observed-version")
   registry (subscriptionconnection-registry connection)
   state (generation-state connection)]
  (if (not state) (do
  (subscription-fail! :rpc/subscription-unavailable "connection has no active subscription generation")))
  (locking (subscriptionregistry-lock registry) (if (not (same-live-generation? registry state)) (do
  (subscription-fail! :rpc/subscription-unavailable "subscription generation is no longer active"))) (if (>= (registry-now-ms! registry) (state-expires-ms! state)) (do
  (retire-under-lock! registry state :expired true)
  (subscription-fail! :rpc/subscription-expired "subscription generation has expired"))))
  (if (not (= identity (:identity state))) (do
  (subscription-fail! :rpc/subscription-identity-mismatch "subscription ACK identity does not match OPEN")))
  (locking (:delivery-lock state) (if (not (= :active (deref (:state state)))) (do
  (subscription-fail! :rpc/subscription-unavailable "subscription generation is not active"))) (let [acknowledged (deref (:acknowledged-version state))
   delivered (deref (:delivered-version state))]
  (if (< observed acknowledged) (do
  (subscription-fail! :rpc/subscription-stale-ack "subscription ACK regresses the replay cursor")))
  (if (> observed delivered) (do
  (subscription-fail! :rpc/subscription-unobserved-ack "subscription ACK names an undelivered version")))
  (reset! (:acknowledged-version state) observed)))
  (->SubscriptionResult (rpc/rpc-subscription-acknowledged! (:identity state) observed) (deref (subscriptionregistry-published-version registry)))))

(defn ^SubscriptionResult handle-request! [^SubscriptionConnection connection request-id ^String space operation payload]
  (cond
  (= operation :rpc/subscribe) (open-generation! connection request-id space payload)
  (= operation :rpc/subscription-ack) (acknowledge-generation! connection payload)
  :else (subscription-fail! :rpc/unsupported-operation "operation is not a subscription operation")))

(defn handle-rpc-request! [^SubscriptionConnection connection request-id request]
  (let [space (t/rpcrequest-space request)
   operation (t/rpcrequest-op request)]
  (if (t/rpcrequest-expected-version request) (do
  (subscription-fail! :rpc/unexpected-expected-version "subscription requests carry their cursor in the typed payload")))
  (if (t/rpcrequest-page request) (do
  (subscription-fail! :rpc/unexpected-page "subscription requests do not support paging")))
  (if (t/rpcrequest-timeout-ms request) (do
  (subscription-fail! :rpc/unexpected-timeout "subscription requests use the generation TTL")))
  (let [result (handle-request! connection request-id space operation (t/rpc-request-payload-value request))]
  (rpc/rpc-response! space operation (subscriptionresult-served-version result) nil nil (subscriptionresult-payload result)))))

(defn read-timeout-ms! [^SubscriptionConnection connection default-timeout-ms]
  (let [state (generation-state connection)]
  (if state (let [remaining (- (state-expires-ms! state) (registry-now-ms! (subscriptionconnection-registry connection)))]
  (if (> remaining 0) (int (max 1 (min 2147483647 remaining))) default-timeout-ms)) default-timeout-ms)))

(defn ^Boolean continue-after-read-timeout?! [^SubscriptionConnection connection]
  (let [state (generation-state connection)]
  (if state (let [registry (subscriptionconnection-registry connection)]
  (if (< (registry-now-ms! registry) (state-expires-ms! state)) true (do
  (retire-generation! state :expired true)
  false))) false)))

(defn close-connection! [^SubscriptionConnection connection]
  (let [state (generation-state connection)]
  (if state (do
  (retire-generation! state :closed false))))
  nil)
