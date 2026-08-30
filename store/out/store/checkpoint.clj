(ns store.checkpoint
  (:require [store.packed :as packed]
            [store.store :as store]
            [store.types :as t]))

(defn- fail! [code ^String message data]
  (throw (ex-info message (assoc data :type code :store/code code))))

(defn- error-code [error]
  (let [data (ex-data error)
   code (or (:store/code data) (:type data))]
  (if (keyword? code) code :invalid-packed-checkpoint)))

(defn- rejection [^String manifest-path error]
  {:manifest manifest-path :code (error-code error) :message (or (.getMessage error) "packed checkpoint was rejected")})

(defn select-boot! [^String directory source-for-manifest tail-row-limit tail-byte-limit]
  (loop [candidates (seq (packed/candidate-manifests directory))
   rejections []]
  (if (nil? candidates) {:context nil :source :storelog-full-replay :source-record nil :selected-manifest nil :prefix-records 0 :rejections rejections} (let [manifest-path (first candidates)
   attempt (try
  (let [manifest (packed/read-manifest! manifest-path)
   source (source-for-manifest manifest)
   prefix (packed/open-checkpoint! manifest-path source)
   context (store/new-packed-term-store prefix tail-row-limit tail-byte-limit 0)]
  {:context context :source :packed-checkpoint :source-record source :selected-manifest manifest-path :prefix-records (packed/checkpointmanifest-transaction-count manifest) :rejections rejections})
  (catch Throwable error
    {:rejection (rejection manifest-path error)}))]
  (if (some? (:rejection attempt)) (recur (next candidates) (conj rejections (:rejection attempt))) attempt)))))

(defn publish! [context ^String directory source-for-revision]
  (let [revision (store/current-sequence context)
   source (source-for-revision revision)]
  (if (not (= revision (packed/checkpointsource-revision source))) (fail! :packed-source-mismatch "live Store revision is not the durable STORELOG prefix" {:store-revision revision :storelog-revision (packed/checkpointsource-revision source)}) nil)
  (let [manifest (packed/write-checkpoint! (store/packed-prefix context) (store/dump-term-store-tail context) directory source)
   prefix (packed/open-checkpoint! (packed/checkpointmanifest-path manifest) source)]
  (store/install-packed-prefix! context prefix)
  {:version revision :watermark (packed/checkpointsource-log-valid-bytes source) :created-at (System/currentTimeMillis) :manifest (packed/checkpointmanifest-path manifest) :component (packed/checkpointmanifest-component manifest) :page-sha256 (packed/checkpointmanifest-page-sha256 manifest) :bytes (packed/checkpointmanifest-mapped-bytes manifest)})))

(defn- ^Boolean rollover-required? [error]
  (= :packed-tail-rollover-required (error-code error)))

(defn prepare-write! [context operations ^String directory source-for-revision]
  (if (nil? (store/packed-prefix context)) (do
  (publish! context directory source-for-revision)
  nil) nil)
  (try
  (store/ensure-transaction-capacity! context operations)
  (catch clojure.lang.ExceptionInfo error
    (if (rollover-required? error) (do
  (publish! context directory source-for-revision)
  (try
  (store/ensure-transaction-capacity! context operations)
  (catch clojure.lang.ExceptionInfo capacity-error
    (if (rollover-required? capacity-error) (fail! :packed-tail-capacity-exceeded "one transaction exceeds the empty boxed-tail bound" (ex-data capacity-error)) (throw capacity-error))))) (throw error))))
  context)
