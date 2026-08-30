(ns store.rpc-subscription-jvm
  (:require [store.rpc :as rpc]
            [store.rpc-subscription :as subscription]
            [store.types :as t])
  (:import [java.io OutputStream]
           [java.net Socket]
           [java.util UUID]))

(def expiry-poll-ceiling-ms 100)

(def writer-poll-ms 100)

(defrecord SubscriptionJvmConnection [session socket output open-request-id writer-future expiry-future])

(defn subscriptionjvmconnection-session [r] (:session r))

(defn subscriptionjvmconnection-socket [r] (:socket r))

(defn subscriptionjvmconnection-output [r] (:output r))

(defn subscriptionjvmconnection-open-request-id [r] (:open-request-id r))

(defn subscriptionjvmconnection-writer-future [r] (:writer-future r))

(defn subscriptionjvmconnection-expiry-future [r] (:expiry-future r))

(defrecord SubscriptionWriteResult [response byte-count])

(defn subscriptionwriteresult-response [r] (:response r))

(defn subscriptionwriteresult-byte-count [r] (:byte-count r))

(defn- adapter-fail! [code ^String message]
  (throw (ex-info message {:type code :store/code code :code code})))

(defn ^String new-store-incarnation! []
  (str (UUID/randomUUID)))

(defn monotonic-now-ns! []
  (System/nanoTime))

(defn ^SubscriptionJvmConnection new-connection [registry socket output]
  (->SubscriptionJvmConnection (subscription/new-session registry) socket output (atom nil) (atom nil) (atom nil)))

(defn connection-session [^SubscriptionJvmConnection connection]
  (subscriptionjvmconnection-session connection))

(defn- close-socket! [^SubscriptionJvmConnection connection]
  (try
  (.close (subscriptionjvmconnection-socket connection))
  (catch Throwable _
    nil))
  nil)

(defn- open-request-id! [^SubscriptionJvmConnection connection]
  (let [bind__0 (deref (subscriptionjvmconnection-open-request-id connection))]
  (if bind__0 (let [request-id bind__0]
  request-id) (adapter-fail! :rpc/subscription-invalid-state "subscription event has no OPEN request id"))))

(defn- write-bytes-under-lock! [^SubscriptionJvmConnection connection bytes]
  (let [output (subscriptionjvmconnection-output connection)]
  (.write output bytes)
  (.flush output)
  (alength bytes)))

(defn- write-event-under-lock! [^SubscriptionJvmConnection connection notice]
  (let [observed (subscription/subscriptionnotice-observed notice)
   coordinate (subscription/subscriptioncursor-coordinate observed)
   response (rpc/rpc-response! (subscription/storecoordinate-space coordinate) subscription/subscription-event-operation (subscription/storecoordinate-version coordinate) nil nil (subscription/notice-payload! notice))
   packet (rpc/store-rpc-event-packet (open-request-id! connection) response)
   bytes (rpc/store-rpc-encode-packet-v2! packet)]
  (write-bytes-under-lock! connection bytes)
  (subscription/mark-delivered! (subscriptionjvmconnection-session connection) notice)
  nil))

(defn- writer-loop! [^SubscriptionJvmConnection connection]
  (let [session (subscriptionjvmconnection-session connection)
   output (subscriptionjvmconnection-output connection)]
  (try
  (loop []
  (if (subscription/session-active? session) (do
  (let [bind__1 (subscription/poll-notice! session writer-poll-ms)]
  (if bind__1 (let [notice bind__1]
  (locking output (if (subscription/session-active? session) (do
  (write-event-under-lock! connection notice))))) nil))
  (recur))))
  (catch InterruptedException _
    nil)
  (catch Throwable _
    (subscription/retire-session! session subscription/adapter-failed-retirement)
    (close-socket! connection))))
  nil)

(defn- start-writer! [^SubscriptionJvmConnection connection]
  (let [future-cell (subscriptionjvmconnection-writer-future connection)]
  (if (nil? (deref future-cell)) (do
  (reset! future-cell (future-call (fn [] (writer-loop! connection)))))))
  nil)

(defn- expiry-sleep-ms [remaining-ns]
  (int (max 1 (min expiry-poll-ceiling-ms (quot (+ remaining-ns 999999) 1000000)))))

(defn- expiry-loop! [^SubscriptionJvmConnection connection]
  (let [session (subscriptionjvmconnection-session connection)]
  (try
  (loop []
  (let [remaining-ns (subscription/lease-remaining-ns! session)]
  (cond
  (subscription/retirement-closes-adapter? session) (close-socket! connection)
  (<= remaining-ns 0) (if (subscription/expire-if-due! session) (do
  (close-socket! connection)))
  :else (do
  (Thread/sleep (expiry-sleep-ms remaining-ns))
  (recur)))))
  (catch InterruptedException _
    nil)))
  nil)

(defn- start-expiry! [^SubscriptionJvmConnection connection]
  (let [future-cell (subscriptionjvmconnection-expiry-future connection)]
  (if (nil? (deref future-cell)) (do
  (reset! future-cell (future-call (fn [] (expiry-loop! connection)))))))
  nil)

(defn- ^Boolean successful-open? [^SubscriptionJvmConnection connection operation response]
  (and (= operation :rpc/subscribe) (and (nil? (t/rpcresponse-error response)) (subscription/session-opening? (subscriptionjvmconnection-session connection)))))

(defn- ^SubscriptionWriteResult write-response-under-lock! [^SubscriptionJvmConnection connection request-id operation response]
  (let [packet (rpc/store-rpc-response-packet request-id response)
   bytes (rpc/store-rpc-encode-packet-v2! packet)
   opening (successful-open? connection operation response)]
  (if opening (do
  (reset! (subscriptionjvmconnection-open-request-id connection) request-id)
  (start-expiry! connection)))
  (try
  (let [byte-count (write-bytes-under-lock! connection bytes)]
  (if (and opening (subscription/activate-open! (subscriptionjvmconnection-session connection))) (do
  (start-writer! connection)))
  (->SubscriptionWriteResult response byte-count))
  (catch Throwable error
    (subscription/retire-session! (subscriptionjvmconnection-session connection) subscription/adapter-failed-retirement)
    (close-socket! connection)
    (throw error)))))

(defn ^SubscriptionWriteResult handle-request-and-write! [^SubscriptionJvmConnection connection request-id request error-response]
  (let [output (subscriptionjvmconnection-output connection)
   space (t/rpcrequest-space request)
   operation (t/rpcrequest-op request)]
  (locking output (let [response (try
  (subscription/handle-rpc-request! (subscriptionjvmconnection-session connection) request)
  (catch Throwable error
    (error-response space operation error)))]
  (write-response-under-lock! connection request-id operation response)))))

(defn ^SubscriptionWriteResult write-response! [^SubscriptionJvmConnection connection request-id operation response]
  (locking (subscriptionjvmconnection-output connection) (write-response-under-lock! connection request-id operation response)))

(defn ^Boolean continue-reading? [^SubscriptionJvmConnection connection]
  (not (subscription/session-terminal? (subscriptionjvmconnection-session connection))))

(defn close-connection! [^SubscriptionJvmConnection connection]
  (subscription/retire-session! (subscriptionjvmconnection-session connection) subscription/disconnected-retirement)
  nil)
