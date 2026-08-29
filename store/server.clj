;; server.clj — narrow TermStore v2 database server.
;;
;; Run long-lived servers with `clojure -M`, never Babashka. This surface stays
;; deliberately small until schema/query/pull projections consume TermStore
;; directly; it never reconstructs the removed fact-object APIs.
(ns server
  (:require [clojure.java.io :as io]
            [store.rpc :as rpc]
            [store.datalog :as datalog]
            [store.kernel :as kernel]
            [store.query :as query]
            [store.store :as term-store]
            [store.text-search :as text-search]
            [store.types :as t]
            [fri-port :as fri])
  (:import [java.net ServerSocket Socket SocketException SocketTimeoutException]
           [java.io ByteArrayOutputStream InputStream OutputStream Writer]
           [java.nio ByteBuffer ByteOrder]
           [java.security MessageDigest]
           [java.time Instant]
           [java.util.concurrent ArrayBlockingQueue LinkedBlockingQueue
            ThreadFactory ThreadPoolExecutor TimeUnit]
           [java.util.concurrent.atomic AtomicLong]
           [java.util.zip CRC32]))

(load-file "database.clj")
(load-file "writer_authority.clj")

(def active-store (atom nil))
(def server-role (atom nil))
(def writer-authority (atom nil))
(def listener (atom nil))
(def stopping? (atom false))
(def ^:private lifecycle-notification-state (atom :idle))
(def ^:private shutdown-monitor (Object.))
(def active-requests (atom {}))
(def connection-executor (atom nil))
(def connection-sockets (atom #{}))
(def active-connections (atom 0))
(def admission-rejections (atom 0))
(def ^:private connection-drain-monitor (Object.))
(def ^:private connection-thread-sequence (AtomicLong. 0))
(def published-snapshot (atom nil))
(def server-generation (atom 0))
(def commit-sequencer (atom nil))
(def commit-sequencer-stats
  (atom {:cohorts 0 :records 0 :barriers 0 :publications 0}))
(def ^:private commit-cohort-max-records 32)
(def ^:private commit-cohort-max-bytes (* 1024 1024))
(def ^:private commit-cohort-max-wait-ns 1000000)
(def ^:private query-page-snapshot-limit 4)
(def ^:private query-page-snapshots (atom {:order [] :by-version {}}))
(def ^:private query-result-version-limit 4)
(def ^:private query-result-per-version-limit 8)
(def ^:private query-result-byte-limit (* 64 1024 1024))
(def query-archive-manifest (atom []))
(def ^:private query-history-stores (atom {}))
(def ^:private query-archive-magic
  (.getBytes "STOREQAR1" java.nio.charset.StandardCharsets/UTF_8))
(def ^:private text-index-version-limit 4)
(def ^:private text-index-byte-limit (* 64 1024 1024))

(defn- empty-query-result-cache [generation]
  {:generation generation
   :entries {}
   :lru []
   :version-lru []
   :in-flight {}
   :bytes 0
   :hits 0
   :misses 0
   :evictions 0})

(def query-result-cache (atom (empty-query-result-cache 0)))

(defn- empty-text-index-cache [generation]
  {:generation generation
   :entries {}
   :lru []
   :in-flight {}
   :bytes 0
   :hits 0
   :misses 0
   :evictions 0})

(def text-index-cache (atom (empty-text-index-cache 0)))

(declare start-commit-sequencer! stop-commit-sequencer! sequence-commit!
         stop-connection-admission! serve-connection! response-version
         read-query-archive-manifest!)

;; Request observability: the slow threshold is checked before the quiet gate,
;; so a stalled request still leaves a trace under BEAGLE_STORE_SERVER_QUIET.

(defn- env-string [name]
  (not-empty (System/getenv name)))

(defn- env-long [name fallback]
  (or (when-let [raw (env-string name)]
        (try (Long/parseLong (.trim ^String raw)) (catch Throwable _ nil)))
      fallback))

(defn- bounded-positive-env-int [name fallback ceiling]
  (let [raw (env-string name)
        value (some-> raw parse-long)]
    (cond
      (nil? raw) fallback
      (or (nil? value) (not (pos? value)) (> value ceiling))
      (throw (ex-info (str name " must be an integer in [1," ceiling "]")
                      {:variable name :value raw :ceiling ceiling}))
      :else (int value))))

(def request-log-path (env-string "BEAGLE_STORE_SERVER_LOG"))
(def request-log-quiet? (= "1" (System/getenv "BEAGLE_STORE_SERVER_QUIET")))
(def slow-request-ms (env-long "BEAGLE_STORE_SLOW_MS" 1000))
(def connection-worker-limit
  (bounded-positive-env-int "BEAGLE_STORE_CONNECTION_WORKERS" 32 512))
(def connection-pending-limit
  (bounded-positive-env-int "BEAGLE_STORE_CONNECTION_QUEUE" 128 65536))
(def connection-first-packet-timeout-ms
  (bounded-positive-env-int "BEAGLE_STORE_CONNECTION_READ_TIMEOUT_MS" 5000 600000))
(def connection-drain-grace-ms
  (bounded-positive-env-int "BEAGLE_STORE_SHUTDOWN_CONNECTION_GRACE_MS" 3000 600000))
(def connection-stop-timeout-ms
  (bounded-positive-env-int "BEAGLE_STORE_SHUTDOWN_TIMEOUT_MS" 8000 600000))
(def runtime-engine (atom :rpc/jvm))
(def query-checkpoint-interval
  (max 1 (env-long "BEAGLE_STORE_QUERY_CHECKPOINT_INTERVAL" 1000)))

(def request-stats
  (atom {:requests 0 :errors 0 :slow 0 :ops {} :max-ms 0 :last-ms 0 :last nil}))

(def ^:private request-log-writer (atom nil))

(defn- request-log-sink []
  (when request-log-path
    (or @request-log-writer
        (swap! request-log-writer
               #(or % (try (io/writer (io/file request-log-path) :append true)
                           (catch Throwable _ nil)))))))

(defn- emit-log-line! [line]
  ;; System/err rather than *err*: a server thread must not inherit whatever
  ;; dynamic binding happened to be live when the connection thread forked.
  (if-let [^Writer writer (request-log-sink)]
    (locking request-log-writer
      (.write writer ^String line)
      (.write writer "\n")
      (.flush writer))
    (.println System/err line)))

(defn- close-request-log! []
  (locking request-log-writer
    (when-let [^Writer writer @request-log-writer]
      (try (.close writer) (catch Throwable _ nil)))
    (reset! request-log-writer nil)))

(defn- service-manager-notify! [state status]
  (when (env-string "NOTIFY_SOCKET")
    (let [command (or (env-string "BEAGLE_STORE_SD_NOTIFY") "systemd-notify")
          process (-> (ProcessBuilder.
                       (into-array String [command state (str "STATUS=" status)]))
                      (.inheritIO)
                      (.start))
          exit (.waitFor process)]
      (when-not (zero? exit)
        (throw
         (ex-info "systemd notification failed"
                  {:type :service-manager-notification-failed
                   :state state :exit exit :command command}))))))

(defn- notify-ready! []
  (locking lifecycle-notification-state
    (when-not (= :starting @lifecycle-notification-state)
      (throw
       (ex-info "server readiness notification is out of sequence"
                {:type :service-manager-notification-order
                 :state @lifecycle-notification-state})))
    (service-manager-notify!
     "READY=1" "Beagle Store restored, listening, and RPC-usable")
    (reset! lifecycle-notification-state :ready)))

(defn- notify-stopping! []
  (locking lifecycle-notification-state
    (when (contains? #{:starting :ready} @lifecycle-notification-state)
      (try
        (service-manager-notify! "STOPPING=1" "Beagle Store draining")
        (catch Throwable error
          (.println System/err
                    (str "beagle-store-server: STOPPING notification failed: "
                         (.getMessage error)))))
      (reset! lifecycle-notification-state :stopping))))

(defn record-request!
  "Account one served request and log it. `elapsed-ns` covers server-side work
   only — decode to response-written — so client send time never reads as
   database latency."
  [operation elapsed-ns outcome code response-bytes]
  (let [ms (quot (long elapsed-ns) 1000000)
        slow? (>= ms slow-request-ms)]
    (swap! request-stats
           (fn [stats]
             (cond-> stats
               true (update :requests inc)
               (= :error outcome) (update :errors inc)
               slow? (update :slow inc)
               true (update-in [:ops (or operation :unknown)] (fnil inc 0))
               true (update :max-ms max ms)
               true (assoc :last-ms ms
                           :last {:op operation :ms ms
                                  :outcome outcome :code code}))))
    (when (or slow? (not request-log-quiet?))
      (emit-log-line!
       (str "store-rpc ts=" (Instant/now)
            " op=" (or operation :unknown)
            " ms=" ms
            " outcome=" (name outcome)
            (when code (str " code=" code))
            (when response-bytes (str " bytes=" response-bytes))
            (when slow? " slow=1"))))
    ms))

(defn- response-outcome
  "Errors reach the client as a response field, not a thrown exception, so the
   only place an error code is observable is the encoded response packet."
  [packet]
  (if-let [error (some-> packet t/storerpcpacketv2-response t/rpcresponse-error)]
    [:error (t/rpcerror-code error)]
    [:ok nil]))

(def native-rpc-operations
  #{:rpc/version :rpc/status :rpc/assert :rpc/retract :rpc/batch :rpc/scan
    :rpc/query :rpc/occurrences :rpc/lease-acquire :rpc/lease-renew
    :rpc/lease-release :rpc/lease-check :rpc/validate :rpc/checkpoint})

(def paged-rpc-operations #{:rpc/query :rpc/scan :rpc/occurrences})

(def read-only-rpc-operations
  (apply disj native-rpc-operations
         [:rpc/assert :rpc/retract :rpc/batch :rpc/lease-acquire
          :rpc/lease-renew :rpc/lease-release :rpc/checkpoint]))

(defn- server-fail! [code message data]
  (throw (ex-info message (assoc data :type code :store/code code :code code))))

(defn- canonical-path [path]
  (.getPath (.getCanonicalFile (io/file (str path)))))

(defn writer-authority-status []
  (when @active-store
    (let [physical (writer-authority/status
                    @server-role @writer-authority (:log @active-store))
          lock-held (:write-authorized physical)
          recovery (database/database-recovery-state @active-store)]
      (assoc physical
             :lock-held lock-held
             :write-authorized (and lock-held
                                    (database/mutation-ready? @active-store))
             :database-recovery recovery))))

(defn- writer-lock-held? []
  (boolean (and (= :active @server-role)
                (writer-authority/held? @writer-authority))))

(defn write-authorized? []
  (boolean (and (writer-lock-held?)
                (database/mutation-ready? @active-store))))

;; A published snapshot has to stay frozen while later commits land, and a
;; TermStore is an identity the writer keeps mutating, so the read view is a
;; fork of the current state rather than the live store itself.
(defn- snapshot-of [db]
  (let [root (term-store/fork-state @(database/database-store db))]
    {:generation @server-generation
     :space (database/database-space db)
     :version (dec (deref (t/termstore-next-sequence root)))
     :root root}))

(defn- publish-snapshot! [db]
  (let [snapshot (snapshot-of db)]
    (reset! published-snapshot snapshot)
    snapshot))

(defn- drop-query-caches! []
  (reset! query-page-snapshots {:order [] :by-version {}})
  (reset! query-result-cache
          (empty-query-result-cache @server-generation))
  (reset! text-index-cache
          (empty-text-index-cache @server-generation)))

(defn- advance-server-generation! []
  (swap! server-generation inc)
  (drop-query-caches!))

(defn shutdown! []
  (locking shutdown-monitor
    ;; STOPPING is synchronous and precedes the first admission/drain mutation.
    (notify-stopping!)
    (reset! stopping? true)
    (when-let [^ServerSocket server @listener]
      (try (.close server) (catch Throwable _ nil)))
    (doseq [cancellation (vals @active-requests)]
      (reset! (:cancelled cancellation) true)
      (when-let [control @(:query-control cancellation)]
        (datalog/cancel-query! control :server-shutdown)))
    (stop-connection-admission!)
    (stop-commit-sequencer!)
    (reset! active-requests {})
    (drop-query-caches!)
    (reset! query-archive-manifest [])
    (reset! query-history-stores {})
    (reset! published-snapshot nil)
    (writer-authority/release! @writer-authority)
    (reset! writer-authority nil)
    (reset! active-store nil)
    (reset! server-role nil)
    (reset! listener nil)
    (close-request-log!)
    (reset! lifecycle-notification-state :idle))
  nil)

(defn boot!
  "Install one Store transaction log generation. Active boot acquires lifetime writer
   authority before creation or torn-tail repair; standby boot stays read-only."
  ([path expected-space]
   (boot! path expected-space (writer-authority/server-role-from-env)))
  ([path expected-space role]
   (shutdown!)
   (reset! stopping? false)
   (let [canonical (canonical-path path)
         file (io/file canonical)
         role (writer-authority/server-role-from (name role))
         authority (when (= :active role)
                     (writer-authority/acquire! canonical))]
     (try
       (when-not (.exists file)
         (when-not expected-space
           (server-fail! :space-id-required
                         "new Store transaction log generation requires an explicit SpaceId"
                         {:path canonical}))
         (database/create-triple-log! canonical expected-space))
       (let [opened (database/open-database!
                     canonical expected-space {:repair-torn? (= :active role)})]
         (advance-server-generation!)
         (reset! active-store opened)
         (read-query-archive-manifest! opened)
         (publish-snapshot! opened)
         (reset! server-role role)
         (reset! writer-authority authority)
         (when (= :active role)
           (start-commit-sequencer!))
         opened)
       (catch Throwable error
         (writer-authority/release! authority)
         (throw error))))))

(defn- refresh-standby! []
  (when (= :standby @server-role)
    (locking active-store
      (let [current @active-store
            opened (database/open-database! (:log current) (:space-id current))]
        (advance-server-generation!)
        (reset! active-store opened)
        (publish-snapshot! opened)))))

(defn native-op-disposition [operation]
  (if (contains? native-rpc-operations operation) :supported :unsupported))

(defn- current-version [db]
  (t/triple-t3 (database/current-transaction db)))

(defn- require-term! [value label]
  (when-not (t/term? value)
    (server-fail! :rpc-invalid-payload (str label " must be a Term") {}))
  value)

(defn- require-triple! [value label]
  (when-not (t/triple? value)
    (server-fail! :rpc-invalid-payload (str label " must be a Triple") {}))
  value)

(defn- require-keyword! [value label]
  (when-not (keyword? value)
    (server-fail! :rpc-invalid-payload (str label " must be a Keyword") {}))
  value)

(defn- require-string! [value label]
  (when-not (string? value)
    (server-fail! :rpc-invalid-payload (str label " must be a String") {}))
  value)

(defn- require-int! [value label]
  (when-not (integer? value)
    (server-fail! :rpc-invalid-payload (str label " must be an Int") {}))
  value)

(defn- require-bool! [value label]
  (when-not (boolean? value)
    (server-fail! :rpc-invalid-payload (str label " must be a Bool") {}))
  value)

(defn- record-fields! [value tag field-count]
  (rpc/rpc-record-fields! value tag field-count))

(defn- list-values! [value]
  (rpc/rpc-list-values! value))

(defn- option-value! [value]
  [(rpc/rpc-option-present?! value) (rpc/rpc-option-value! value)])

(defn- require-unit! [payload]
  (when-not (= rpc/rpc-unit payload)
    (server-fail! :rpc-invalid-payload "operation payload must be :rpc/unit" {})))

(defn- cancelled! [cancellation]
  (when @(:cancelled cancellation)
    (server-fail! :rpc/cancelled "request was cancelled before completion" {})))

(defn- require-writer! []
  (when-not (writer-lock-held?)
    (server-fail! :rpc/writer-authority-required
                  "active writer authority is required" {}))
  (database/require-mutation-ready! @active-store))

(defn- require-version-expected! [version expected]
  (when (and (some? expected) (not= expected version))
    (server-fail! :rpc/conflict "expected-version does not match current version" {})))

(defn- require-expected! [db expected]
  (require-version-expected! (current-version db) expected))

(defn- occurrence-epoch [coordinate]
  (t/triple-t3 (t/triple-t1 coordinate)))

(defn- millis->instant [value]
  (let [seconds (quot value 1000)
        millis (mod value 1000)]
    (t/instant seconds (* millis 1000000))))

(defn- parse-fence! [value]
  (let [[resource holder epoch] (record-fields! value :rpc/fence 3)]
    [(require-term! resource "fence resource")
     (require-term! holder "fence holder")
     (require-int! epoch "fence epoch")]))

(defn- current-fence [db resource]
  (when-let [lease (database/current-lease db resource)]
    [(:holder lease) (occurrence-epoch (:occurrence lease))
     (:occurrence lease) (:expires-ms lease)]))

(defn- valid-fence? [db resource holder epoch now-ms]
  (when-let [[current-holder current-epoch _ expires-ms]
             (current-fence db resource)]
    (and (= holder current-holder) (= epoch current-epoch)
         (> expires-ms now-ms))))

(defn- require-fence! [db fence]
  (when fence
    (let [[resource holder epoch] (parse-fence! fence)]
      (when-not (valid-fence? db resource holder epoch
                              (System/currentTimeMillis))
        (server-fail! :rpc/lease-fence-mismatch
                      "lease fence is not current and unexpired" {})))))

(defn- parse-policy! [value]
  (require-keyword! value "subject policy")
  (when-not (or (= value rpc/rpc-subject-any)
                (= value rpc/rpc-subject-existing))
    (server-fail! :rpc-invalid-policy "subject policy is unsupported" {}))
  value)

(defn- parse-action! [value]
  (let [[operation proposition policy] (record-fields! value :rpc/action 3)]
    (require-keyword! operation "action operation")
    (when-not (or (= operation :rpc/assert) (= operation :rpc/retract))
      (server-fail! :rpc-invalid-action "action operation is unsupported" {}))
    [operation (require-triple! proposition "action proposition")
     (parse-policy! policy)]))

(defn- remove-last-equal [values target]
  (let [position (last (keep-indexed (fn [index value]
                                       (when (= value target) index))
                                     values))]
    (if (nil? position)
      [values false]
      [(into (subvec values 0 position) (subvec values (inc position))) true])))

(defn- subject-known? [propositions proposition]
  (let [t1 (t/triple-t1 proposition)]
    (boolean (some #(= t1 (t/triple-t1 %)) propositions))))

(defn- prepare-actions! [propositions actions]
  (loop [remaining actions index 0 simulated propositions
         operations [] decisions []]
    (if (empty? remaining)
      [operations decisions]
      (let [[operation proposition policy] (first remaining)]
        (when (and (= policy rpc/rpc-subject-existing)
                   (not (subject-known? simulated proposition)))
          (server-fail! :rpc/subject-not-found
                        "subject-existing policy requires a live t1" {}))
        (if (= operation :rpc/assert)
          (recur (rest remaining) (inc index) (conj simulated proposition)
                 (conj operations {:action :assert :proposition proposition})
                 (conj decisions [index true]))
          (let [[next-propositions changed] (remove-last-equal simulated proposition)]
            (recur (rest remaining) (inc index) next-propositions
                   (conj operations {:action :retract :proposition proposition})
                   (conj decisions [index changed]))))))))

(defn- prepare-actions-on-store! [db actions]
  (if (every? (fn [[operation _ policy]]
                (and (= operation :rpc/assert)
                     (= policy rpc/rpc-subject-any)))
              actions)
    [(mapv (fn [[_ proposition _]]
             {:action :assert :proposition proposition})
           actions)
     (mapv (fn [index] [index true]) (range (count actions)))]
    (prepare-actions! (database/live-propositions db) actions)))

(defn- predicted-mutation-occurrences [db operations]
  (when (seq operations)
    (let [transaction
          (t/transaction-coordinate
           (database/database-space db)
           (term-store/next-sequence (database/database-store db)))]
      (mapv #(t/occurrence-coordinate transaction %) (range (count operations))))))

(defn- mutation-result [decisions occurrences]
  (loop [remaining decisions occurrences (vec occurrences) results []]
    (if (empty? remaining)
      (rpc/rpc-mutation-result! results)
      (let [[input-index changed] (first remaining)
            occurrence (first occurrences)]
        (recur (rest remaining)
               (subvec occurrences 1)
               (conj results
                     (rpc/rpc-action-result!
                      input-index changed occurrence)))))))

(defn- require-encodable-rpc-response!
  [request served-version payload]
  (rpc/store-rpc-encode-packet-v2!
   (rpc/store-rpc-response-packet
    0
    (rpc/rpc-response!
     (t/rpcrequest-space request)
     (t/rpcrequest-op request)
     served-version nil nil payload)))
  nil)

(defn- mutation-payload! [db request actions fence cancellation]
  (let [expected (t/rpcrequest-expected-version request)]
    (require-writer!)
    (require-expected! db expected)
    (require-fence! db fence)
    (cancelled! cancellation)
    (let [[operations decisions] (prepare-actions-on-store! db actions)
          base (when (some? expected)
                 (t/transaction-coordinate (database/database-space db) expected))
          occurrences (predicted-mutation-occurrences db operations)
          served-version
          (if (seq operations)
            (term-store/next-sequence (database/database-store db))
            (term-store/current-sequence (database/database-store db)))
          payload (mutation-result decisions occurrences)
          _ (require-encodable-rpc-response!
             request served-version payload)
          committed
          (when (seq operations)
            (cancelled! cancellation)
            (database/commit!
             db
             {:base base
              :operations operations
              :commit-metadata
              {:producer "store.rpc/v2"
               :shape-schema-id "store/CommitOperationV1"
               :profile "store-rpc-v2"
               :validation-attestation
               {:validator "store/canonical-validator-v1"
                :result :pending
                :attestation "store/canonical-validator-v1"}}}))]
      (when (:reject committed)
        (server-fail! :rpc/conflict "expected-version lost its commit race" {}))
      payload)))

(defn- handle-write! [request operation cancellation]
  (let [[proposition policy fence-option]
        (record-fields! (t/rpc-request-payload-value request) :rpc/write 3)
        [fence-present fence] (option-value! fence-option)]
    (sequence-commit!
     request cancellation
     (fn [db]
       (mutation-payload!
        db request [[operation (require-triple! proposition "write proposition")
                     (parse-policy! policy)]]
        (when fence-present (require-triple! fence "write fence")) cancellation)))))

(defn- handle-batch! [request cancellation]
  (let [[action-list fence-option]
        (record-fields! (t/rpc-request-payload-value request) :rpc/batch 2)
        action-values (list-values! action-list)
        _ (when (> (count action-values) rpc/rpc-v2-max-batch-actions)
            (server-fail!
             :term-depth-exceeded
             "batch action count exceeds the TermCodecV1 depth bound"
             {:actions (count action-values)
              :maximum rpc/rpc-v2-max-batch-actions}))
        actions (mapv parse-action! action-values)
        [fence-present fence] (option-value! fence-option)]
    (when (empty? actions)
      (server-fail! :rpc-invalid-action "batch requires at least one action" {}))
    (sequence-commit!
     request cancellation
     (fn [db]
       (mutation-payload!
        db request actions
        (when fence-present (require-triple! fence "batch fence"))
        cancellation)))))

(defn- scan-match? [options proposition]
  (every? identity
          (map-indexed
           (fn [index [present value]]
             (or (not present)
                 (= value ((case index
                             0 t/triple-t1
                             1 t/triple-t2
                             t/triple-t3)
                           proposition))))
           options)))

(defn- query-record-tag [value]
  (when (and (t/triple? value) (= :rpc/record (t/triple-t3 value)))
    (t/triple-t1 value)))

(defn- parse-query-term! [value]
  (case (query-record-tag value)
    :query/var
    (let [[name] (record-fields! value :query/var 1)]
      (datalog/variable (require-string! name "query variable")))

    :query/const
    (let [[constant] (record-fields! value :query/const 1)]
      (datalog/constant (require-term! constant "query constant")))

    (server-fail! :query-invalid-term
                  "query term must be query/var or query/const" {})))

(defn- parse-query-terms! [value]
  (mapv parse-query-term! (list-values! value)))

(defn- parse-query-head! [value]
  (let [[relation terms] (record-fields! value :query/head 2)]
    [(require-string! relation "query head relation")
     (parse-query-terms! terms)]))

(defn- parse-query-clause! [value]
  (case (query-record-tag value)
    :query/relation
    (let [[relation terms negated] (record-fields! value :query/relation 3)
          relation (require-string! relation "query relation")
          terms (parse-query-terms! terms)
          negated (require-bool! negated "query negation")]
      (if negated
        (datalog/negated-literal relation terms)
        (datalog/relation-literal relation terms)))

    :query/predicate
    (let [[operation left right]
          (record-fields! value :query/predicate 3)
          operation (require-keyword! operation "query predicate")]
      (when-not (contains? datalog/comparison-operators operation)
        (server-fail! :query-invalid-predicate
                      "query predicate operation is unsupported" {}))
      (datalog/comparison-literal
       operation [(parse-query-term! left) (parse-query-term! right)]))

    :query/function
    (let [[operation terms binding]
          (record-fields! value :query/function 3)
          operation (require-keyword! operation "query function")]
      (when-not (contains? datalog/builtin-operators operation)
        (server-fail! :query-invalid-function
                      "query function operation is unsupported" {}))
      (datalog/builtin-literal operation (parse-query-terms! terms)
                               (require-string! binding "query function binding")))

    (server-fail! :query-invalid-clause "query clause record is unsupported" {})))

(defn- parse-query-rule! [value]
  (let [[head clauses] (record-fields! value :query/rule 2)
        [relation terms] (parse-query-head! head)]
    (datalog/rule relation terms (mapv parse-query-clause! (list-values! clauses)))))

(defn- parse-query-stratum! [value]
  (let [[rules] (record-fields! value :query/stratum 1)]
    (mapv parse-query-rule! (list-values! rules))))

(defn- parse-query-aggregate! [value]
  (let [[operation argument-option]
        (record-fields! value :query/aggregate 2)
        operation (require-keyword! operation "query aggregate")
        [argument-present argument] (option-value! argument-option)]
    (when-not (contains? query/aggregate-operators operation)
      (server-fail! :query-invalid-aggregate
                    "query aggregate operation is unsupported" {}))
    (query/aggregate-spec operation
                          (when argument-present
                            (require-int! argument "aggregate argument index")))))

(defn- parse-query-having! [value]
  (let [[comparison aggregate-index comparison-value]
        (record-fields! value :query/having 3)
        comparison (require-keyword! comparison "having comparison")]
    (when-not (contains? datalog/comparison-operators comparison)
      (server-fail! :query-invalid-having
                    "having comparison operation is unsupported" {}))
    (query/having-clause comparison
                         (require-int! aggregate-index "having aggregate index")
                         (require-term! comparison-value "having value"))))

(defn- parse-query-find! [value]
  (case (query-record-tag value)
    :query/find-relation
    (let [[relation] (record-fields! value :query/find-relation 1)]
      (query/relation-find (require-string! relation "find relation")))

    :query/find-aggregate
    (let [[relation grouping aggregates having]
          (record-fields! value :query/find-aggregate 4)]
      (query/aggregate-find
       (require-string! relation "aggregate find relation")
       (mapv #(require-int! % "aggregate grouping index")
             (list-values! grouping))
       (mapv parse-query-aggregate! (list-values! aggregates))
       (mapv parse-query-having! (list-values! having))))

    (server-fail! :query-invalid-find "query find record is unsupported" {})))

(defn- parse-query-order! [value]
  (let [[column direction] (record-fields! value :query/order 2)]
    (query/order-clause
     (require-int! column "query order column")
     (require-keyword! direction "query order direction"))))

(defn- parse-query-plan! [value]
  (let [[find strata order limit-option]
        (record-fields! value :query/plan 4)
        [limit-present limit] (option-value! limit-option)
        plan (query/ordered-query-plan
              (parse-query-find! find)
              (mapv parse-query-stratum! (list-values! strata))
              (mapv parse-query-order! (list-values! order))
              (when limit-present
                (require-int! limit "query limit")))
        errors (query/validate-plan! plan)]
    (when-let [error (first errors)]
      (server-fail! (query/error-code error) (query/error-message error) {}))
    plan))

(defn- query-checkpoint-directory [db]
  (when-let [log (:log db)]
    (io/file (str log ".query-checkpoints"))))

(defn- query-checkpoint-version [^java.io.File file]
  (some->> (.getName file)
           (re-matches #"snapshot-([0-9]+)\.fri")
           second
           Long/parseLong))

(defn- query-checkpoint-files [db upper-inclusive]
  (if-let [directory (query-checkpoint-directory db)]
    (->> (or (.listFiles directory) (make-array java.io.File 0))
         (keep (fn [file]
                 (when-let [version (query-checkpoint-version file)]
                   (when (<= version upper-inclusive) [version file]))))
         (sort-by first >))
    []))

(defn- query-checkpoint-source! [db version]
  (let [{:keys [space-id fingerprint valid-bytes sequence]}
        (database/triple-log-prefix-source! (:log db) version)]
    {:binding (fri/source-binding space-id fingerprint valid-bytes)
     :sequence sequence}))

(defn- load-query-checkpoint-root! [db upper-inclusive]
  (some
   (fn [[version file]]
     (try
       (let [{:keys [binding sequence]}
             (query-checkpoint-source! db version)
             image (fri/open-fri! (.getPath ^java.io.File file) binding)
             context (term-store/new-term-store (database/database-space db))]
         (fri/restore-store! image context)
         (let [root @context]
           (when (= sequence (dec (deref (t/termstore-next-sequence root)))) root)))
       (catch Throwable _ nil)))
   (query-checkpoint-files db upper-inclusive)))

(defn- prune-query-checkpoints! [db]
  (doseq [[_ file] (drop query-page-snapshot-limit
                         (query-checkpoint-files db Long/MAX_VALUE))]
    (try (.delete ^java.io.File file) (catch Throwable _ nil))))

(defn- write-query-checkpoint! [db version root]
  (when (and (:log db)
             (pos? version)
             (zero? (mod version query-checkpoint-interval)))
    (try
      (let [directory (query-checkpoint-directory db)
            _ (.mkdirs ^java.io.File directory)
            path (.getPath (io/file directory (str "snapshot-" version ".fri")))
            {:keys [binding]} (query-checkpoint-source! db version)]
        (fri/write-fri! (term-store/dump-term-store (atom root)) path binding)
        (prune-query-checkpoints! db))
      (catch Throwable _ nil)))
  root)

(defn- query-archive-directory [db]
  (io/file (str (:log db) ".query-archives")))

(defn- query-archive-manifest-file [db]
  (io/file (query-archive-directory db) "ranges.v1"))

(defn- write-archive-text! [^java.io.DataOutputStream output value]
  (let [bytes (.getBytes (str value) java.nio.charset.StandardCharsets/UTF_8)]
    (.writeInt output (alength bytes))
    (.write output bytes)))

(defn- read-archive-text! [^java.io.DataInputStream input]
  (let [length (.readInt input)]
    (when (or (neg? length) (> length 1048576))
      (throw (ex-info "query archive manifest string is invalid"
                      {:type :query/archive-unavailable})))
    (let [bytes (byte-array length)]
      (.readFully input bytes)
      (String. bytes java.nio.charset.StandardCharsets/UTF_8))))

(defn- write-query-archive-manifest! [db entries]
  (let [directory (query-archive-directory db)
        _ (.mkdirs ^java.io.File directory)
        target (query-archive-manifest-file db)
        temporary (io/file directory "ranges.v1.tmp")]
    (with-open [file-output (java.io.FileOutputStream. temporary)
                output (java.io.DataOutputStream.
                        (java.io.BufferedOutputStream. file-output))]
      (.write output query-archive-magic)
      (.writeInt output (count entries))
      (doseq [{:keys [lower upper expired path fingerprint]} entries]
        (.writeLong output lower)
        (.writeLong output upper)
        (.writeBoolean output (boolean expired))
        (write-archive-text! output path)
        (write-archive-text! output fingerprint))
      (.flush output)
      (.force (.getChannel file-output) true))
    (java.nio.file.Files/move
     (.toPath temporary) (.toPath target)
     (into-array java.nio.file.CopyOption
                 [java.nio.file.StandardCopyOption/ATOMIC_MOVE
                  java.nio.file.StandardCopyOption/REPLACE_EXISTING]))
    (reset! query-archive-manifest entries)
    entries))

(defn- read-query-archive-manifest! [db]
  (let [file (query-archive-manifest-file db)]
    (if-not (.isFile file)
      (reset! query-archive-manifest [])
      (with-open [input (java.io.DataInputStream.
                         (java.io.BufferedInputStream.
                          (java.io.FileInputStream. file)))]
        (let [magic (byte-array (alength query-archive-magic))
              _ (.readFully input magic)
              count-value (.readInt input)]
          (when (or (not (java.util.Arrays/equals magic query-archive-magic))
                    (neg? count-value) (> count-value 100000))
            (server-fail! :query/archive-unavailable
                          "query archive range manifest is invalid" {}))
          (reset!
           query-archive-manifest
           (mapv (fn [_]
                   {:lower (.readLong input)
                    :upper (.readLong input)
                    :expired (.readBoolean input)
                    :path (read-archive-text! input)
                    :fingerprint (read-archive-text! input)})
                 (range count-value))))))))

(defn seal-query-epoch!
  "Seal a canonical inclusive prefix and publish its range before cache GC."
  [upper-inclusive]
  (let [db @active-store
        head (current-version db)]
    (when (or (neg? upper-inclusive) (> upper-inclusive head))
      (server-fail! :query-invalid-snapshot
                    "query epoch cut is outside available history" {}))
    (let [{:keys [valid-bytes fingerprint]}
          (database/triple-log-prefix-source! (:log db) upper-inclusive)
          directory (query-archive-directory db)
          _ (.mkdirs ^java.io.File directory)
          target (io/file directory (str "epoch-through-" upper-inclusive ".storelog"))
          temporary (io/file directory (str ".epoch-through-" upper-inclusive ".tmp"))
          bytes (java.nio.file.Files/readAllBytes
                 (.toPath (io/file (:log db))))
          prefix (java.util.Arrays/copyOfRange bytes 0 valid-bytes)
          prior (vec (remove #(= upper-inclusive (:upper %))
                             @query-archive-manifest))
          lower (if-let [previous (last (sort-by :upper prior))]
                  (inc (:upper previous)) 0)
          entry {:lower lower :upper upper-inclusive :expired false
                 :path (.getCanonicalPath target)
                 :fingerprint fingerprint}
          entries (vec (sort-by :lower (conj prior entry)))]
      (with-open [output (java.io.FileOutputStream. temporary)]
        (.write output prefix)
        (.flush output)
        (.force (.getChannel output) true))
      (java.nio.file.Files/move
       (.toPath temporary) (.toPath target)
       (into-array java.nio.file.CopyOption
                   [java.nio.file.StandardCopyOption/ATOMIC_MOVE
                    java.nio.file.StandardCopyOption/REPLACE_EXISTING]))
      (write-query-archive-manifest! db entries)
      (reset! query-history-stores {})
      (drop-query-caches!)
      entry)))

(defn expire-query-epoch!
  "Mark one sealed range unavailable by retention policy; canonical deletion is separate."
  [upper-inclusive]
  (let [db @active-store
        entries (mapv (fn [entry]
                        (cond-> entry
                          (= upper-inclusive (:upper entry))
                          (assoc :expired true)))
                      @query-archive-manifest)]
    (write-query-archive-manifest! db entries)
    (reset! query-history-stores {})
    (drop-query-caches!)
    entries))

(defn- query-archive-entry [version]
  (some #(when (<= (:lower %) version (:upper %)) %) @query-archive-manifest))

(defn- query-history-store! [active version]
  (if-let [{:keys [expired path fingerprint upper] :as entry}
           (query-archive-entry version)]
    (do
      (when expired
        (server-fail! :query/snapshot-expired
                      "query snapshot was removed by explicit retention policy"
                      {:range [(:lower entry) upper]}))
      (or (get @query-history-stores [path fingerprint])
          (try
            (let [source (database/triple-log-prefix-source! path upper)]
              (when-not (= fingerprint (:fingerprint source))
                (server-fail! :query/archive-unavailable
                              "query archive fingerprint does not match its manifest"
                              {:range [(:lower entry) upper]}))
              (let [opened (database/open-database!
                            path (database/database-space active))]
                (swap! query-history-stores
                       assoc [path fingerprint] opened)
                opened))
            (catch Throwable error
              (if (contains? #{:query/archive-unavailable
                               :query/snapshot-expired}
                             (:store/code (ex-data error)))
                (throw error)
                (server-fail! :query/archive-unavailable
                              "query archive is temporarily unavailable"
                              {:range [(:lower entry) upper]}))))))
    active))

(defn- replayed-store-root! [db version]
  (let [head (current-version db)]
    (when (or (neg? version) (> version head))
      (server-fail! :query-invalid-snapshot
                    "query snapshot is outside available history" {}))
    (if (= version head)
      @(database/database-store db)
      (let [history-store (query-history-store! db version)
            head-root @(database/database-store history-store)
            base (load-query-checkpoint-root! history-store version)
            context (if base
                      (atom base)
                      (term-store/new-term-store
                       (database/database-space history-store)))
            lower-exclusive (dec (deref (t/termstore-next-sequence @context)))]
        (doseq [record (term-store/transaction-records-between
                       head-root lower-exclusive version)]
          (term-store/replay-transaction! context record))
        (write-query-checkpoint! history-store version @context)))))

(defn- snapshot-image [version root]
  (let [context (atom root)]
    {:version version
     :store-root root
     :propositions (term-store/live-propositions context)}))

(defn- occurrence-candidate-source [root lower-exclusive upper-inclusive]
  (datalog/occurrence-candidate-source root lower-exclusive upper-inclusive))

(defn- withdrawal-candidate-source [root lower-exclusive upper-inclusive]
  (datalog/withdrawal-candidate-source root lower-exclusive upper-inclusive))

(defn- one-triple-pattern [plan]
  (let [find (query/queryplan-find plan)
        strata (query/queryplan-strata plan)
        rules (when (= 1 (count strata)) (first strata))
        rule (when (= 1 (count rules)) (first rules))
        body (when rule (datalog/rule-body rule))
        literal (when (= 1 (count body)) (first body))
        head-arguments (when rule (datalog/rule-head-arguments rule))
        arguments (when literal (datalog/literal-arguments literal))]
    (when (and (some? rule)
               (some? literal)
               (empty? (query/queryplan-order plan))
               (nil? (query/queryplan-limit plan))
               (not (query/aggregate-find? find))
               (= (query/findspec-relation find)
                  (datalog/rule-head-relation rule))
               (= :relation (datalog/literal-kind literal))
               (= datalog/triple-relation (datalog/literal-relation literal))
               (not (datalog/literal-negated literal))
               (= 3 (count arguments)))
      {:arguments arguments :head-arguments head-arguments})))

(defn- plan-uses-text? [plan]
  (boolean
   (some (fn [stratum]
           (some (fn [rule]
                   (some #(and (= :relation (datalog/literal-kind %))
                               (contains? datalog/text-relations
                                          (datalog/literal-relation %)))
                         (datalog/rule-body rule)))
                 stratum))
         (query/queryplan-strata plan))))

(def ^:private history-relations
  #{datalog/occurrence-relation datalog/withdrawal-relation})

(defn- plan-history-relations [plan]
  (into #{}
        (comp
         (mapcat identity)
         (mapcat datalog/rule-body)
         (filter #(= :relation (datalog/literal-kind %)))
         (map datalog/literal-relation)
         (filter history-relations))
        (query/queryplan-strata plan)))

(defn- plan-uses-only-text-base? [plan]
  (not
   (some (fn [stratum]
           (some (fn [rule]
                   (some #(and (= :relation (datalog/literal-kind %))
                               (contains? #{datalog/triple-relation
                                            datalog/occurrence-relation
                                            datalog/withdrawal-relation}
                                          (datalog/literal-relation %)))
                         (datalog/rule-body rule)))
                 stratum))
         (query/queryplan-strata plan))))

(defn- cached-query-page-root [version]
  (get-in @query-page-snapshots [:by-version version]))

;; A TermStore is an identity whose cells the writer keeps mutating, so the
;; live head root is never cacheable: only an independently replayed
;; historical root is frozen enough to survive in this map.
(defn- retain-query-page-root! [version root]
  (locking query-page-snapshots
    (let [{:keys [order by-version]} @query-page-snapshots
          order (conj (vec (remove #{version} order)) version)
          evict-count (max 0 (- (count order) query-page-snapshot-limit))
          evicted (take evict-count order)
          retained (vec (drop evict-count order))]
      (reset! query-page-snapshots
              {:order retained
               :by-version (reduce dissoc
                                   (assoc by-version version root)
                                   evicted)})
      root)))

(defn- query-page-root! [db version]
  (or (cached-query-page-root version)
      (let [root (replayed-store-root! db version)]
        (if (= version (current-version db))
          root
          (retain-query-page-root! version root)))))

(defn- native-term-slot [value width]
  (mod (hash value) width))

(defn- native-index-position [rows slots value]
  (let [positions @(nth slots (native-term-slot value (count slots)))]
    (some (fn [position]
            (when (and (< position (count rows)) (= value (nth rows position)))
              position))
          positions)))

(defn- native-atom-row [value]
  (cond
    (string? value) (t/->AtomRow :string value nil nil nil nil nil)
    (integer? value) (t/->AtomRow :int nil value nil nil nil nil)
    (number? value) (t/->AtomRow :float nil nil value nil nil nil)
    (boolean? value) (t/->AtomRow :bool nil nil nil value nil nil)
    (keyword? value) (t/->AtomRow :keyword nil nil nil nil value nil)
    (t/instant? value) (t/->AtomRow :instant nil nil nil nil nil value)))

(declare native-term-handle)

(defn- native-term-handle [root value]
  (if (t/triple? value)
    (let [t1 (native-term-handle root (t/triple-t1 value))
          t2 (native-term-handle root (t/triple-t2 value))
          t3 (native-term-handle root (t/triple-t3 value))]
      (when (every? some? [t1 t2 t3])
        (when-let [position
                   (native-index-position
                    (deref (t/termstore-triples root))
                    (deref (t/termstore-triple-slots root))
                    (t/->TripleRow t1 t2 t3))]
          (inc (* 2 position)))))
    (let [row (native-atom-row value)]
      (when row
        (when-let [position
                   (native-index-position
                    (deref (t/termstore-atoms root))
                    (deref (t/termstore-atom-slots root)) row)]
          (* 2 position))))))

(defn- native-atom-value [row]
  (case (t/atomrow-kind row)
    :string (t/atomrow-string-value row)
    :int (t/atomrow-int-value row)
    :float (t/atomrow-float-value row)
    :bool (t/atomrow-bool-value row)
    :keyword (t/atomrow-keyword-value row)
    :instant (t/atomrow-instant-value row)))

(defn- native-resolve-handle [root handle]
  (let [position (quot handle 2)]
    (if (zero? (mod handle 2))
      (native-atom-value (nth (deref (t/termstore-atoms root)) position))
      (let [row (nth (deref (t/termstore-triples root)) position)]
        (t/triple
         (native-resolve-handle root (t/triplerow-t1 row))
         (native-resolve-handle root (t/triplerow-t2 row))
         (native-resolve-handle root (t/triplerow-t3 row)))))))

(defn- native-active-handle? [root handle]
  (let [slots (deref (t/termstore-active-slots root))
        buckets (deref (t/termstore-active-buckets root))
        positions @(nth slots (native-term-slot handle (count slots)))]
    (boolean
     (some (fn [position]
             (when (< position (count buckets))
               (let [bucket (nth buckets position)]
                 (and (= handle (t/activebucket-triple-handle bucket))
                      (seq (t/activebucket-positions bucket))))))
           positions))))

(def ^:private native-unbound ::native-unbound)
(def ^:private native-missing ::native-missing)

(defn- native-pattern-handles [root arguments]
  (mapv (fn [argument]
          (if (some? (datalog/queryterm-variable argument))
            native-unbound
            (or (native-term-handle root (datalog/queryterm-value argument))
                native-missing)))
        arguments))

(defn- native-row-matches-handles? [expected row]
  (every? identity
          (map (fn [wanted actual]
                 (or (= native-unbound wanted) (= wanted actual)))
               expected
               [(t/triplerow-t1 row)
                (t/triplerow-t2 row)
                (t/triplerow-t3 row)])))

(defn- native-candidate-handles [root arguments cancellation]
  (let [expected (native-pattern-handles root arguments)]
    (cond
      (some #{native-missing} expected) []
      (not-any? #{native-unbound} expected)
      (let [row (apply t/->TripleRow expected)
            position (native-index-position
                      (deref (t/termstore-triples root))
                      (deref (t/termstore-triple-slots root)) row)
            handle (when (some? position) (inc (* 2 position)))]
        (if (and handle (native-active-handle? root handle)) [handle] []))
      :else
      (persistent!
       (reduce (fn [handles bucket]
                 (cancelled! cancellation)
                 (let [handle (t/activebucket-triple-handle bucket)]
                   (if (and (seq (t/activebucket-positions bucket))
                            (native-row-matches-handles?
                             expected
                             (nth (deref (t/termstore-triples root)) (quot handle 2))))
                     (conj! handles handle)
                     handles)))
               (transient [])
               (deref (t/termstore-active-buckets root)))))))

(defn- match-query-row [arguments row]
  (loop [position 0 bindings {}]
    (if (>= position (count arguments))
      bindings
      (let [term (nth arguments position)
            value (nth row position)
            variable (datalog/queryterm-variable term)]
        (if (some? variable)
          (if (contains? bindings variable)
            (when (= (get bindings variable) value)
              (recur (inc position) bindings))
            (recur (inc position) (assoc bindings variable value)))
          (when (= (datalog/queryterm-value term) value)
            (recur (inc position) bindings)))))))

(defn- ground-query-row [arguments bindings]
  (mapv (fn [term]
          (if-let [variable (datalog/queryterm-variable term)]
            (get bindings variable)
            (datalog/queryterm-value term)))
        arguments))

(defn- one-triple-query-rows [root pattern cancellation]
  (let [rows
        (persistent!
         (reduce (fn [acc handle]
                   (cancelled! cancellation)
                   (let [proposition (native-resolve-handle root handle)
                         row [(t/triple-t1 proposition)
                              (t/triple-t2 proposition)
                              (t/triple-t3 proposition)]]
                     (if-let [bindings (match-query-row (:arguments pattern) row)]
                       (conj! acc (ground-query-row
                                   (:head-arguments pattern) bindings))
                       acc)))
                 (transient #{})
                 (native-candidate-handles
                  root (:arguments pattern) cancellation)))]
    (cancelled! cancellation)
    (vec (sort-by query/row-key rows))))

(defn- term-sha256 [term]
  (let [out (ByteArrayOutputStream.)]
    (rpc/write-term-codec-v1! out term rpc/rpc-v2-max-string-bytes
                               rpc/rpc-v2-max-term-nodes
                               rpc/rpc-v2-max-term-depth)
    (let [digest (.digest (MessageDigest/getInstance "SHA-256")
                          (.toByteArray out))]
      (apply str (map #(format "%02x" (bit-and 255 (int %))) digest)))))

(defn- term-codec-v1-bytes [term]
  (t/termcodecmeasure-bytes
   (rpc/measure-term-codec-v1! term rpc/rpc-v2-max-string-bytes
                                rpc/rpc-v2-max-term-nodes
                                rpc/rpc-v2-max-term-depth)))

(defn- result-weight [rows shape]
  (+ 32 (* 8 (count rows))
     (reduce (fn [total row]
               (+ total (term-codec-v1-bytes ((:cache-term shape) row))))
             0 rows)))

(defn- result-snapshot-key [snapshot]
  [(:generation snapshot) (:space snapshot) (:version snapshot)
   (:lower-exclusive snapshot -1)])

(defn- remove-text-index-entry [state key]
  (if-let [entry (get-in state [:entries key])]
    (-> state
        (update :entries dissoc key)
        (update :lru #(vec (remove #{key} %)))
        (update :bytes - (:bytes entry))
        (update :evictions inc))
    state))

(defn- retain-text-index-entry [state key source]
  (let [bytes (text-search/source-weight source)]
    (loop [bounded (-> state
                       (assoc-in [:entries key]
                                 {:source source :bytes bytes})
                       (update :bytes + bytes)
                       (update :lru #(conj (vec (remove #{key} %)) key)))]
      (if (and (seq (:lru bounded))
               (or (> (count (:entries bounded)) text-index-version-limit)
                   (> (:bytes bounded) text-index-byte-limit)))
        (recur (remove-text-index-entry bounded (first (:lru bounded))))
        bounded))))

(defn- begin-text-index-access! [key]
  (locking text-index-cache
    (let [state @text-index-cache]
      (if-let [entry (get-in state [:entries key])]
        (do
          (reset! text-index-cache
                  (-> state
                      (update :hits inc)
                      (update :lru #(conj (vec (remove #{key} %)) key))))
          {:kind :hit :source (:source entry)})
        (if-let [flight (get-in state [:in-flight key])]
          (do
            (reset! text-index-cache (update state :hits inc))
            {:kind :wait :flight flight})
          (let [flight (promise)]
            (reset! text-index-cache
                    (-> state
                        (assoc-in [:in-flight key] flight)
                        (update :misses inc)))
            {:kind :build :flight flight}))))))

(defn- complete-text-index-flight! [key flight source]
  (locking text-index-cache
    (let [state (update @text-index-cache :in-flight dissoc key)]
      (reset! text-index-cache
              (if (= (first key) (:generation state))
                (retain-text-index-entry state key source)
                state))))
  (deliver flight {:source source}))

(defn- fail-text-index-flight! [key flight error]
  (locking text-index-cache
    (swap! text-index-cache update :in-flight dissoc key))
  (deliver flight {:error error}))

(def ^:private text-index-wait-pending (Object.))

(defn- wait-text-index-flight! [flight cancellation deadline-ns]
  (loop []
    (cancelled! cancellation)
    (let [remaining-ms (quot (- deadline-ns (System/nanoTime)) 1000000)]
      (when (<= remaining-ms 0)
        (server-fail! :query-time-limit "query exceeded its time limit" {}))
      (let [outcome (deref flight (long (min 25 remaining-ms))
                           text-index-wait-pending)]
        (if (identical? text-index-wait-pending outcome)
          (recur)
          (if-let [error (:error outcome)]
            (throw error)
            (:source outcome)))))))

(defn- cached-text-index!
  [snapshot cancellation deadline-ns propositions attributes]
  (let [scope-key (if (some? attributes)
                    (vec (sort (map query/term-key attributes)))
                    :all)
        key (conj (result-snapshot-key snapshot) scope-key)
        {:keys [kind source flight]} (begin-text-index-access! key)]
    (case kind
      :hit (do (cancelled! cancellation) source)
      :wait (wait-text-index-flight! flight cancellation deadline-ns)
      :build
      (try
        (let [rows (vec (propositions))
              source
              (if (some? attributes)
                (text-search/build-source-for-attributes!
                 rows attributes text-index-byte-limit)
                (text-search/build-source! rows text-index-byte-limit))]
          (complete-text-index-flight! key flight source)
          source)
        (catch Throwable error
          (fail-text-index-flight! key flight error)
          (throw error))))))

(defn- touch-result-entry [state key]
  (let [snapshot-key (first key)]
    (-> state
        (update :lru #(conj (vec (remove #{key} %)) key))
        (update :version-lru
                #(conj (vec (remove #{snapshot-key} %)) snapshot-key)))))

(defn- remove-result-entries [state candidate-keys]
  (let [evicted-keys (set (filter #(contains? (:entries state) %)
                                  candidate-keys))
        removed-bytes (reduce + 0
                              (map #(get-in state [:entries % :bytes])
                                   evicted-keys))
        entries (reduce dissoc (:entries state) evicted-keys)
        retained-versions (set (map first (keys entries)))]
    (-> state
        (assoc :entries entries)
        (update :lru #(vec (remove evicted-keys %)))
        (update :version-lru
                #(vec (filter retained-versions %)))
        (update :bytes - removed-bytes)
        (update :evictions + (count evicted-keys)))))

(defn- enforce-result-cache-bounds [state snapshot-key]
  (let [version-keys (filterv #(= snapshot-key (first %)) (:lru state))
        state (remove-result-entries
               state
               (take (max 0 (- (count version-keys)
                               query-result-per-version-limit))
                     version-keys))
        evicted-versions
        (set (take (max 0 (- (count (:version-lru state))
                            query-result-version-limit))
                   (:version-lru state)))
        state (remove-result-entries
               state
               (filterv #(contains? evicted-versions (first %))
                        (:lru state)))]
    (loop [bounded state]
      (if (and (> (:bytes bounded) query-result-byte-limit)
               (seq (:lru bounded)))
        (recur (remove-result-entries bounded [(first (:lru bounded))]))
        bounded))))

(defn- retain-result-entry [state key rows bytes]
  (let [snapshot-key (first key)
        state (-> state
                  (assoc-in [:entries key] {:rows rows :bytes bytes})
                  (update :bytes + bytes)
                  (touch-result-entry key))]
    (enforce-result-cache-bounds state snapshot-key)))

(defn- begin-result-access! [key]
  (locking query-result-cache
    (let [state @query-result-cache]
      (if-let [entry (get-in state [:entries key])]
        (do
          (reset! query-result-cache
                  (-> state (update :hits inc) (touch-result-entry key)))
          {:kind :hit :rows (:rows entry)})
        (if-let [flight (get-in state [:in-flight key])]
          (do
            (reset! query-result-cache (update state :hits inc))
            {:kind :wait :flight flight})
          (let [flight (promise)]
            (reset! query-result-cache
                    (-> state
                        (assoc-in [:in-flight key] flight)
                        (update :misses inc)))
            {:kind :build :flight flight}))))))

(defn- complete-result-flight! [key flight rows bytes]
  (locking query-result-cache
    (let [state @query-result-cache
          generation (ffirst key)
          state (update state :in-flight dissoc key)]
      (reset! query-result-cache
              (if (= generation (:generation state))
                (retain-result-entry state key rows bytes)
                state))))
  (deliver flight {:rows rows}))

(defn- fail-result-flight! [key flight error]
  (locking query-result-cache
    (swap! query-result-cache update :in-flight dissoc key))
  (deliver flight {:error error}))

(def ^:private result-wait-pending (Object.))

(defn- wait-result-flight! [flight cancellation deadline-ns]
  (loop []
    (cancelled! cancellation)
    (let [remaining-ms (when deadline-ns
                         (quot (- deadline-ns (System/nanoTime)) 1000000))]
      (when (and remaining-ms (<= remaining-ms 0))
        (server-fail! :query-time-limit "query exceeded its time limit" {}))
      (let [wait-ms (long (if remaining-ms (min 25 remaining-ms) 25))
            outcome (deref flight wait-ms result-wait-pending)]
        (if (identical? result-wait-pending outcome)
          (recur)
          (if-let [error (:error outcome)]
            (throw error)
            (:rows outcome)))))))

(defn- cached-result! [snapshot operation digest shape cancellation deadline-ns build]
  (let [key [(result-snapshot-key snapshot) operation digest]
        {:keys [kind rows flight]} (begin-result-access! key)]
    (case kind
      :hit (do (cancelled! cancellation) rows)
      :wait (wait-result-flight! flight cancellation deadline-ns)
      :build
      (try
        (let [rows (vec (build))
              bytes (result-weight rows shape)]
          (complete-result-flight! key flight rows bytes)
          rows)
        (catch Throwable error
          (fail-result-flight! key flight error)
          (throw error))))))

(defn- parse-query-row! [value]
  (let [[values] (record-fields! value :query/row 1)]
    (mapv #(require-term! % "query row value") (list-values! values))))

(defn- parse-query-cursor! [value]
  (let [[snapshot-version query-sha256 next-page-ordinal after-row]
        (record-fields! value :query/cursor 4)
        snapshot-version (require-int! snapshot-version "cursor snapshot version")
        next-page-ordinal (require-int! next-page-ordinal "cursor page ordinal")]
    (when (or (neg? snapshot-version) (neg? next-page-ordinal))
      (server-fail! :query-cursor-mismatch
                    "query cursor coordinates must be non-negative" {}))
    {:snapshot-version snapshot-version
     :query-sha256 (require-string! query-sha256 "cursor query digest")
     :next-page-ordinal next-page-ordinal
     :after-row (parse-query-row! after-row)}))

(defn- upper-snapshot-version! [snapshot cursor head]
  (cond
    (= snapshot rpc/query-current) (or (:snapshot-version cursor) head)
    (= :query/as-of (query-record-tag snapshot))
    (let [[version] (record-fields! snapshot :query/as-of 1)]
      (require-int! version "query snapshot version"))
    :else
    (server-fail! :query-invalid-snapshot
                  "query upper snapshot must be current or as-of" {})))

(defn- requested-query-view! [snapshot cursor head]
  (let [cursor-version (:snapshot-version cursor)
        [lower-exclusive requested]
        (if (= :query/since (query-record-tag snapshot))
          (let [[lower upper] (record-fields! snapshot :query/since 2)
                lower (require-int! lower "query since lower bound")]
            (when (neg? lower)
              (server-fail! :query-invalid-snapshot
                            "query since lower bound must be non-negative" {}))
            [lower (upper-snapshot-version! upper cursor head)])
          [-1 (upper-snapshot-version! snapshot cursor head)])]
    (when (and cursor-version (not= cursor-version requested))
      (server-fail! :query-cursor-mismatch
                    "query cursor belongs to a different snapshot" {}))
    (when (> lower-exclusive requested)
      (server-fail! :query-invalid-snapshot
                    "query since lower bound exceeds its upper snapshot" {}))
    {:version requested :lower-exclusive lower-exclusive}))

(defn- result-rows! [result]
  (when-let [error (first (query/result-errors result))]
    (server-fail! (query/error-code error) (query/error-message error) {}))
  (query/result-rows result))

;; Query plans may carry a custom order, so the cursor row is located by exact
;; equality rather than assuming canonical row-key order.
(defn- query-cursor-position! [rows after-row]
  (let [position (first (keep-indexed
                         (fn [index row]
                           (when (= row after-row) index))
                         rows))]
    (when (nil? position)
      (server-fail! :query-cursor-mismatch
                    "query cursor row is absent from its snapshot" {}))
    position))

;; Scan rows are a multiset — equal propositions may be live twice — so the
;; cursor carries the snapshot position alongside the row it must still hold.
(defn- indexed-cursor-position! [rows after-row]
  (let [[position value] after-row]
    (when-not (and (= 2 (count after-row))
                   (integer? position)
                   (< -1 position (count rows))
                   (= value (nth rows position)))
      (server-fail! :query-cursor-mismatch
                    "page cursor row is absent from its snapshot" {}))
    position))

;; A page shape adapts one operation's rows to the shared :query/cursor record:
;; :payload encodes a row vector, :cursor-row builds the cursor row for the last
;; served row, and :locate finds that row again in a re-read snapshot.
(def ^:private query-page-shape
  {:payload (fn [rows] (rpc/rpc-query-rows! (mapv rpc/rpc-query-row! rows)))
   :cursor-row (fn [_ row] row)
   :locate query-cursor-position!
   :cache-term rpc/rpc-query-row!})

(def ^:private triples-page-shape
  {:payload rpc/rpc-triples!
   :cursor-row (fn [position row] [position row])
   :locate indexed-cursor-position!
   :cache-term identity})

(defn- rpc-occurrence [occurrence]
  (rpc/rpc-occurrence!
   (t/operationoccurrence-coordinate occurrence)
   (t/operationoccurrence-action occurrence)
   (t/operationoccurrence-proposition occurrence)))

(defn- occurrence-cursor-position! [rows after-row]
  (let [[position value] after-row]
    (when-not (and (= 2 (count after-row))
                   (integer? position)
                   (< -1 position (count rows))
                   (= value (rpc-occurrence (nth rows position))))
      (server-fail! :query-cursor-mismatch
                    "page cursor occurrence is absent from its snapshot" {}))
    position))

(def ^:private occurrences-page-shape
  {:payload (fn [rows] (rpc/rpc-occurrences! (mapv rpc-occurrence rows)))
   :cursor-row (fn [position row] [position (rpc-occurrence row)])
   :locate occurrence-cursor-position!
   :cache-term rpc-occurrence})

(defn- paged-result! [rows page digest snapshot-version shape]
  (if (nil? page)
    {:payload ((:payload shape) rows)
     :page nil}
    (let [limit (t/rpcpagerequest-limit page)
          cursor-value (t/rpc-page-request-cursor-value page)
          cursor (when cursor-value (parse-query-cursor! cursor-value))]
      (when (or (< limit 1) (> limit query/max-page-limit))
        (server-fail! :query-page-limit "query page limit must be from 1 through 4096" {}))
      (when (and cursor (not= digest (:query-sha256 cursor)))
        (server-fail! :query-cursor-mismatch
                      "query cursor belongs to a different query" {}))
      (let [ordinal (or (:next-page-ordinal cursor) 0)
            start (if cursor
                    (inc ((:locate shape) rows (:after-row cursor)))
                    0)
            selected (vec (take limit (drop start rows)))
            next-position (+ start (count selected))
            done (>= next-position (count rows))
            next-cursor
            (when-not done
              (rpc/rpc-query-cursor!
               snapshot-version digest (inc ordinal)
               (rpc/rpc-query-row!
                ((:cursor-row shape) (dec next-position) (peek selected)))))]
        {:payload ((:payload shape) selected)
         :page (rpc/rpc-page-response! ordinal next-cursor done)}))))

;; An RPC list nests one Triple per row, so a response carrying max-term-depth
;; rows can never encode: an unpaged read stops there and still fails typed
;; instead of folding the whole corpus first.
(def ^:private unpaged-row-cutoff rpc/rpc-v2-max-term-depth)

(defn- collect-rows [source keep? cutoff cancellation]
  (reduce (fn [result value]
            (cancelled! cancellation)
            (if (keep? value)
              (let [result (conj result value)]
                (if (and cutoff (>= (count result) cutoff))
                  (reduced result)
                  result))
              result))
          [] source))

(defn- page-version [snapshot page]
  (or (some-> page t/rpc-page-request-cursor-value parse-query-cursor!
              :snapshot-version)
      (:version snapshot)))

(defn- handle-scan! [request cancellation snapshot]
  (let [payload (t/rpc-request-payload-value request)
        [t1-option t2-option t3-option]
        (record-fields! payload :rpc/triple-pattern 3)
        options (mapv option-value! [t1-option t2-option t3-option])
        page (t/rpcrequest-page request)
        version (page-version snapshot page)
        cache-snapshot (assoc (select-keys snapshot [:generation :space])
                              :version version)
        build #(let [db (database/store-view @active-store (:root snapshot))
                     root (query-page-root! db version)
                     view (database/store-view db root)]
                 (collect-rows (database/live-propositions view)
                               (fn [row] (scan-match? options row))
                               (when-not page unpaged-row-cutoff)
                               cancellation))
        digest (term-sha256 payload)
        rows (if page
               (cached-result! cache-snapshot :rpc/scan digest
                               triples-page-shape cancellation nil build)
               (build))]
    (assoc (paged-result! rows page digest version
                          triples-page-shape)
           :served version)))

(defn- handle-occurrences! [request cancellation snapshot]
  (require-unit! (t/rpc-request-payload-value request))
  (let [page (t/rpcrequest-page request)
        version (page-version snapshot page)
        cache-snapshot (assoc (select-keys snapshot [:generation :space])
                              :version version)
        build #(let [db (database/store-view @active-store (:root snapshot))
                     root (query-page-root! db version)
                     view (database/store-view db root)]
                 (collect-rows (database/occurrences view)
                               (constantly true)
                               (when-not page unpaged-row-cutoff)
                               cancellation))
        digest (term-sha256 rpc/rpc-unit)
        rows (if page
               (cached-result! cache-snapshot :rpc/occurrences digest
                               occurrences-page-shape cancellation nil build)
               (build))]
    (assoc (paged-result! rows page digest version
                          occurrences-page-shape)
           :served version)))

(defn- handle-query! [request cancellation published served-version]
  (let [[plan-term requested-snapshot]
        (record-fields! (t/rpc-request-payload-value request) :query/request 2)
        plan (parse-query-plan! plan-term)
        page (t/rpcrequest-page request)
        cursor-value (some-> page t/rpc-page-request-cursor-value)
        cursor (when cursor-value (parse-query-cursor! cursor-value))
        direct-pattern (one-triple-pattern plan)
        direct? (some? direct-pattern)
        db (database/store-view @active-store (:root published))
        view (requested-query-view!
              requested-snapshot cursor (:version published))
        version (:version view)
        lower-exclusive (:lower-exclusive view)
        query-digest
        (term-sha256 (t/triple plan-term lower-exclusive version))
        _ (vreset! served-version version)
        cache-snapshot {:generation (:generation published)
                        :space (:space published)
                        :version version
                        :lower-exclusive lower-exclusive}
        timeout (min 60000 (or (t/rpcrequest-timeout-ms request) 5000))
        deadline-ns (+ (System/nanoTime) (* timeout 1000000))
        control (datalog/query-control 10000000 timeout)
        build
        (if direct?
          #(let [root (query-page-root! db version)]
             (one-triple-query-rows root direct-pattern cancellation))
          #(do
             (reset! (:query-control cancellation) control)
             (when @(:cancelled cancellation)
               (datalog/cancel-query! control :request-cancelled))
             (try
               (let [root (query-page-root! db version)
                     text? (plan-uses-text? plan)
                     text-attributes
                     (when text? (query/plan-text-attribute-scope plan))
                     history (plan-history-relations plan)
                     only-text? (and text? (plan-uses-only-text-base? plan))
                     source
                     (when text?
                       (cached-text-index!
                        cache-snapshot cancellation deadline-ns
                        (fn [] (term-store/live-propositions (atom root)))
                        text-attributes))
                     candidates
                     (cond->
                      {}
                       (contains? history datalog/occurrence-relation)
                       (assoc datalog/occurrence-relation
                              (occurrence-candidate-source
                               root lower-exclusive version))
                       (contains? history datalog/withdrawal-relation)
                       (assoc datalog/withdrawal-relation
                              (withdrawal-candidate-source
                               root lower-exclusive version))
                       source (merge (datalog/text-candidate-sources source)))
                     snapshot-data (when-not only-text?
                                     (snapshot-image version root))
                     projection
                     (query/->Projection
                       (if only-text?
                         {}
                         (datalog/edb (:propositions snapshot-data)))
                       candidates)
                     result (binding [query/*query-control* control]
                              (query/run-plan-projected! projection plan))]
                 (result-rows! result))
               (finally
                 (reset! (:query-control cancellation) nil)))))
        rows (cached-result! cache-snapshot :rpc/query query-digest
                             query-page-shape cancellation deadline-ns build)
        paged (paged-result! rows page query-digest version
                             query-page-shape)]
    (cancelled! cancellation)
    (assoc paged :served version)))

(defn- lease-mutation-guard! [db request cancellation]
  (require-writer!)
  (require-expected! db (t/rpcrequest-expected-version request))
  (cancelled! cancellation))

(defn- predicted-next-lease-epoch [db]
  (let [sequence (term-store/next-sequence (database/database-store db))]
    (t/occurrence-coordinate
     (t/transaction-coordinate (database/database-space db) sequence) 0)))

(defn- handle-lease-acquire! [request cancellation]
  (let [[resource holder ttl-ms]
        (record-fields! (t/rpc-request-payload-value request) :lease/acquire 3)
        resource (require-term! resource "lease resource")
        holder (require-term! holder "lease holder")
        ttl-ms (require-int! ttl-ms "lease ttl-ms")]
    (when-not (pos? ttl-ms)
      (server-fail! :rpc-invalid-payload "lease ttl-ms must be positive" {}))
    (sequence-commit!
     request cancellation
     (fn [db]
       (lease-mutation-guard! db request cancellation)
       (let [now-ms (System/currentTimeMillis)
             [_ _ _ current-expires-ms]
             (or (current-fence db resource) [nil nil nil nil])]
         (when (and current-expires-ms (> current-expires-ms now-ms))
           (server-fail! :rpc/lease-held "lease resource is already held" {}))
         (let [epoch (predicted-next-lease-epoch db)
               expires-ms (+ now-ms ttl-ms)
               payload
               (rpc/rpc-lease-grant!
                (rpc/rpc-fence! resource holder (occurrence-epoch epoch))
                (millis->instant expires-ms))
               _ (require-encodable-rpc-response!
                  request (occurrence-epoch epoch) payload)
               result (database/acquire-lease!
                       db resource holder ttl-ms now-ms)]
         (when (:reject result)
           (server-fail! :rpc/lease-held "lease resource is already held" {}))
           payload))))))

(defn- handle-lease-renew! [request cancellation]
  (let [[fence ttl-ms]
        (record-fields! (t/rpc-request-payload-value request) :lease/renew 2)
        [resource holder epoch] (parse-fence! fence)
        ttl-ms (require-int! ttl-ms "lease ttl-ms")]
    (when-not (pos? ttl-ms)
      (server-fail! :rpc-invalid-payload "lease ttl-ms must be positive" {}))
    (sequence-commit!
     request cancellation
     (fn [db]
       (lease-mutation-guard! db request cancellation)
       (let [now-ms (System/currentTimeMillis)
             [current-holder current-epoch occurrence current-expires-ms]
             (or (current-fence db resource) [nil nil nil nil])]
         (when-not (and (= holder current-holder) (= epoch current-epoch)
                        (> (or current-expires-ms Long/MIN_VALUE) now-ms))
            (server-fail! :rpc/lease-fence-mismatch
                          "lease fence does not name the current lease" {}))
         (let [next-epoch (predicted-next-lease-epoch db)
               expires-ms (+ now-ms ttl-ms)
               payload
               (rpc/rpc-lease-grant!
                (rpc/rpc-fence!
                 resource holder (occurrence-epoch next-epoch))
                (millis->instant expires-ms))
               _ (require-encodable-rpc-response!
                  request (occurrence-epoch next-epoch) payload)
               result (database/renew-lease!
                       db resource holder occurrence ttl-ms now-ms)]
           (when (:reject result)
             (server-fail! :rpc/lease-fence-mismatch
                           "lease fence is stale or expired" {}))
           payload))))))

(defn- handle-lease-release! [request cancellation]
  (let [[resource holder epoch]
        (parse-fence! (t/rpc-request-payload-value request))]
    (sequence-commit!
     request cancellation
     (fn [db]
       (lease-mutation-guard! db request cancellation)
       (let [[current-holder current-epoch occurrence]
             (or (current-fence db resource) [nil nil nil nil])]
         (if-not (and (= holder current-holder) (= epoch current-epoch))
           (rpc/rpc-lease-released! false)
           (let [served-version
                 (term-store/next-sequence (database/database-store db))
                 payload (rpc/rpc-lease-released! true)
                 _ (require-encodable-rpc-response!
                    request served-version payload)
                 result (database/release-lease! db resource holder occurrence)]
             (when-not (:ok result)
               (server-fail! :rpc/lease-fence-mismatch
                             "lease fence is stale or expired" {}))
             payload)))))))

(defn- handle-lease-check! [payload cancellation snapshot]
  (let [[resource holder epoch] (parse-fence! payload)]
    (cancelled! cancellation)
    (let [view (database/store-view @active-store (:root snapshot))
          [current-holder current-epoch _ expires-ms]
          (or (current-fence view resource) [nil nil nil nil])
          matching (and (= holder current-holder) (= epoch current-epoch))
          valid (and matching (> expires-ms (System/currentTimeMillis)))]
      (rpc/rpc-lease-check!
       (boolean valid) (when matching (millis->instant expires-ms))))))

(defn- handle-validate! [payload cancellation snapshot]
  (require-unit! payload)
  (cancelled! cancellation)
  (try
    (let [db (database/store-view @active-store (:root snapshot))
          dump (term-store/dump-term-store (database/database-store db))
          space-id (database/database-space db)
          copy (term-store/new-term-store space-id)
          profile-violations
          (kernel/lint-declared-profile (database/live-propositions db) space-id)]
      (term-store/load-term-store! copy dump)
      (rpc/rpc-validation!
       true
       (mapv #(rpc/rpc-violation! :rpc/profile-violation %)
             profile-violations)))
    (catch Throwable error
      (let [code (or (:store/code (ex-data error))
                     (:type (ex-data error)) :rpc/validation-failed)]
        (rpc/rpc-validation!
         false [(rpc/rpc-violation!
                 (if (keyword? code) code :rpc/validation-failed)
                 (or (.getMessage error) "validation failed"))])))))

(defn- checkpoint-image-path [db]
  (str (:log db) ".snapshot"))

(defn- write-checkpoint-image!
  "Write one exact JVM snapshot at the commit-sequencer durability barrier.
   The STORELOG remains authoritative; FRI binds the image to its canonical
   prefix and atomically installs the derived file beside it."
  [db snapshot]
  (let [version (:version snapshot)
        {:keys [valid-bytes fingerprint space-id]}
        (database/triple-log-prefix-source! (:log db) version)
        binding (fri/source-binding space-id fingerprint valid-bytes)
        path (checkpoint-image-path db)
        _ (fri/write-fri!
           (term-store/dump-term-store (atom (:root snapshot)))
           path binding)
        ^bytes bytes (java.nio.file.Files/readAllBytes
                      (.toPath (io/file path)))
        crc (doto (CRC32.) (.update bytes))]
    {:version version
     :watermark valid-bytes
     :created-at (System/currentTimeMillis)
     :crc (.getValue crc)
     :bytes (alength bytes)}))

(defn- checkpoint-payload! [request snapshot]
  (require-unit! (t/rpc-request-payload-value request))
  (try
    (let [{:keys [version watermark created-at crc bytes]}
          (write-checkpoint-image! @active-store snapshot)]
      (rpc/rpc-record! :rpc/checkpoint
                       [version watermark created-at crc bytes]))
    (catch Throwable error
      (server-fail! :rpc/checkpoint-unavailable
                    "JVM Store snapshot image could not be written"
                    {:cause (.getMessage error)}))))

(defn- handle-checkpoint! [request cancellation]
  (require-unit! (t/rpc-request-payload-value request))
  (sequence-commit!
   request cancellation
   (fn [_db]
     {:kind :checkpoint})))

(defn- status-payload [snapshot]
  (let [db (database/store-view @active-store (:root snapshot))
        state (:status (database/database-recovery-state db))
        {:keys [hits misses bytes evictions]} @query-result-cache
        cache (rpc/rpc-record! :rpc/result-cache
                                [hits misses bytes evictions])]
    (rpc/rpc-status! state (count (database/live-propositions db))
                      @runtime-engine cache)))

(defn- request-body-bytes [request]
  (- (alength ^bytes
              (rpc/store-rpc-encode-packet-v2!
               (rpc/store-rpc-request-packet 0 request)))
     rpc/rpc-v2-header-bytes))

(defn- take-commit-cohort! [^LinkedBlockingQueue queue first-ticket]
  (let [deadline (+ (:enqueued-ns first-ticket) commit-cohort-max-wait-ns)]
    (loop [tickets [first-ticket] bytes (:bytes first-ticket)]
      (if (>= (count tickets) commit-cohort-max-records)
        [tickets nil]
        (let [ready (.poll queue)
              remaining (- deadline (System/nanoTime))
              ticket (or ready
                         (when (pos? remaining)
                           (.poll queue remaining TimeUnit/NANOSECONDS)))]
          (if ticket
            (if (or (:stop ticket)
                    (> (+ bytes (:bytes ticket)) commit-cohort-max-bytes))
              [tickets ticket]
              (recur (conj tickets ticket) (+ bytes (:bytes ticket))))
            [tickets nil]))))))

(defn- commit-sequencer-stopped-error []
  (ex-info "commit sequencer is not running"
           {:type :rpc/not-booted :store/code :rpc/not-booted}))

(defn- deliver-commit-cohort! [tickets]
  (try
    (let [db @active-store
          committed (database/commit-cohort! db (mapv :mutation tickets))
          record-count (:record-count committed)
          _ (swap! commit-sequencer-stats
                   (fn [stats]
                     (cond-> (-> stats
                                 (update :cohorts inc)
                                 (update :records + record-count))
                       (pos? record-count) (update :barriers inc))))
          snapshot (if (pos? (:record-count committed))
                     (let [published (publish-snapshot! db)]
                       (swap! commit-sequencer-stats update :publications inc)
                       published)
                     @published-snapshot)]
      (doseq [[ticket result] (map vector tickets (:results committed))]
        (deliver (:completion ticket)
                 (if-let [error (:error result)]
                   {:error error :version (:version result)}
                   (if (= :checkpoint (:kind (:value result)))
                     (try
                       {:value (checkpoint-payload!
                                (:request ticket) snapshot)
                        :version (:version snapshot)
                        :published-version (:version snapshot)}
                       (catch Throwable checkpoint-error
                         {:error checkpoint-error
                          :version (:version snapshot)}))
                     {:value (:value result) :version (:version result)
                      :published-version (:version snapshot)})))))
    (catch Throwable error
      (doseq [ticket tickets]
        (deliver (:completion ticket)
                 {:error error :version (response-version)})))))

(defn- commit-sequencer-loop! [^LinkedBlockingQueue queue]
  (try
    (loop [pending nil]
      (if (identical? queue (:queue @commit-sequencer))
        (let [first-ticket (or pending (.take queue))]
          (when-not (:stop first-ticket)
            (let [[tickets next-pending]
                  (take-commit-cohort! queue first-ticket)]
              (deliver-commit-cohort! tickets)
              (recur next-pending))))
        (when-let [completion (:completion pending)]
          (deliver completion
                   {:error (commit-sequencer-stopped-error)
                    :version (response-version)}))))
    (catch InterruptedException _ nil)
    (finally
      (let [error (commit-sequencer-stopped-error)]
        (loop []
          (when-let [ticket (.poll queue)]
            (when-let [completion (:completion ticket)]
              (deliver completion {:error error :version (response-version)}))
            (recur)))))))

(defn- start-commit-sequencer! []
  (let [queue (LinkedBlockingQueue.)
        thread (Thread. #(commit-sequencer-loop! queue) "store-commit-sequencer")]
    (.setDaemon thread true)
    (reset! commit-sequencer-stats
            {:cohorts 0 :records 0 :barriers 0 :publications 0})
    (reset! commit-sequencer {:queue queue :thread thread})
    (.start thread)
    nil))

(defn- stop-commit-sequencer! []
  (when-let [{:keys [^Thread thread ^LinkedBlockingQueue queue]}
             @commit-sequencer]
    (reset! commit-sequencer nil)
    (.put queue {:stop true})
    (when-not (identical? thread (Thread/currentThread))
      (.join thread 5000)))
  nil)

(defn- sequence-commit! [request cancellation mutation]
  (cancelled! cancellation)
  (require-writer!)
  (let [{:keys [^LinkedBlockingQueue queue]} @commit-sequencer]
    (when-not queue
      (throw (commit-sequencer-stopped-error)))
    (let [completion (promise)
          ticket {:mutation mutation
                  :request request
                  :completion completion
                  :bytes (request-body-bytes request)
                  :enqueued-ns (System/nanoTime)}]
      (.put queue ticket)
      (let [{:keys [value error version]} @completion]
        (if error
          (throw error)
          {:payload value :served version})))))

(defn- dispatch-request! [request cancellation snapshot served-version]
  (let [operation (t/rpcrequest-op request)
        payload (t/rpc-request-payload-value request)]
    (case operation
      :rpc/version (do (require-unit! payload) {:payload rpc/rpc-unit})
      :rpc/status (do (require-unit! payload) {:payload (status-payload snapshot)})
      :rpc/assert (handle-write! request :rpc/assert cancellation)
      :rpc/retract (handle-write! request :rpc/retract cancellation)
      :rpc/batch (handle-batch! request cancellation)
      :rpc/scan (handle-scan! request cancellation snapshot)
      :rpc/query (handle-query! request cancellation snapshot served-version)
      :rpc/occurrences (handle-occurrences! request cancellation snapshot)
      :rpc/lease-acquire (handle-lease-acquire! request cancellation)
      :rpc/lease-renew (handle-lease-renew! request cancellation)
      :rpc/lease-release (handle-lease-release! request cancellation)
      :rpc/lease-check {:payload (handle-lease-check! payload cancellation snapshot)}
      :rpc/validate {:payload (handle-validate! payload cancellation snapshot)}
      :rpc/checkpoint (handle-checkpoint! request cancellation)
      (server-fail! :rpc/unsupported-operation
                    "operation is not part of Store RPC v2" {}))))

(def ^:private retryable-error-codes
  #{:rpc/conflict :rpc/cancelled :query-cancelled :query-time-limit
    :query-work-limit :query/archive-unavailable :durability-ambiguous})

(defn- response-version []
  (or (:version @published-snapshot) 0))

(defn handle-rpc-request! [request cancellation]
  (let [space (t/rpcrequest-space request)
        operation (t/rpcrequest-op request)
        served-version (volatile! nil)]
    (try
      (when-not @active-store
        (server-fail! :rpc/not-booted "database is not booted" {}))
      (refresh-standby!)
      (when-not (= space (database/database-space @active-store))
        (server-fail! :rpc/space-mismatch
                      "request SpaceId does not match the served space" {}))
      (when (= :unsupported (native-op-disposition operation))
        (server-fail! :rpc/unsupported-operation
                      "operation is not part of Store RPC v2" {}))
      (when (and (not (contains? paged-rpc-operations operation))
                 (t/rpcrequest-page request))
        (server-fail! :rpc/unexpected-page
                      "paging is supported only by rpc/query, rpc/scan, and rpc/occurrences"
                      {}))
      (when (and (not= operation :rpc/query) (t/rpcrequest-timeout-ms request))
        (server-fail! :rpc/unexpected-timeout
                      "timeout-ms is supported only by rpc/query" {}))
      (let [result
            (if (contains? read-only-rpc-operations operation)
              (let [{:keys [version] :as snapshot} @published-snapshot]
                (vreset! served-version version)
                (require-version-expected!
                 version (t/rpcrequest-expected-version request))
                (let [dispatched (dispatch-request!
                                  request cancellation snapshot served-version)]
                  (assoc dispatched :served (or (:served dispatched) version))))
              (let [dispatched (dispatch-request!
                                request cancellation nil served-version)]
                (vreset! served-version (:served dispatched))
                dispatched))
            {:keys [payload page served]} result]
        (rpc/rpc-response! space operation served
                            page nil payload))
      (catch Throwable error
        (let [data (ex-data error)
              code (or (:store/code data) (:code data) (:type data)
                       :rpc/internal-error)
              code (if (keyword? code) code :rpc/internal-error)]
          (rpc/rpc-response!
           space operation (or @served-version (response-version)) nil
           (rpc/rpc-error! code (contains? retryable-error-codes code)
                            (or (.getMessage error) "native RPC request failed") nil)
           nil))))))

(defn- read-exact! [^InputStream input bytes offset length]
  (loop [position offset remaining length]
    (if (zero? remaining)
      true
      (let [read-count (.read input bytes position remaining)]
        (if (neg? read-count)
          false
          (recur (+ position read-count) (- remaining read-count)))))))

(defn- validate-stream-header! [header]
  (dotimes [index 8]
    (when-not (= (bit-and 255 (int (aget header index)))
                 (bit-and 255 (int (aget rpc/store-rpc-v2-magic index))))
      (server-fail! :rpc-invalid-magic "Store RPC magic does not match" {})))
  (let [buffer (doto (ByteBuffer/wrap header) (.order ByteOrder/LITTLE_ENDIAN))]
    (.position buffer 8)
    (let [major (Short/toUnsignedInt (.getShort buffer))
          minor (Short/toUnsignedInt (.getShort buffer))
          kind (bit-and 255 (int (.get buffer)))
          flags (bit-and 255 (int (.get buffer)))
          body-length (Integer/toUnsignedLong (.getInt buffer))]
      (when-not (and (= major rpc/rpc-v2-major)
                     (= minor rpc/rpc-v2-minor))
        (server-fail! :rpc-unsupported-version
                      "Store RPC major/minor version is unsupported" {}))
      (when-not (<= 1 kind 4)
        (server-fail! :rpc-invalid-kind "Store RPC packet kind is unknown" {}))
      (when-not (zero? flags)
        (server-fail! :rpc-invalid-flags "Store RPC v2 flags must be zero" {}))
      (when (> body-length rpc/rpc-v2-max-body-bytes)
        (server-fail! :rpc-packet-too-large
                      "Store RPC declared body exceeds the byte limit" {}))
      (int body-length))))

(defn read-rpc-packet! [^InputStream input]
  (let [first-byte (.read input)]
    (when-not (neg? first-byte)
      (when-not (= first-byte (bit-and 255 (int (aget rpc/store-rpc-v2-magic 0))))
        (server-fail! :rpc-invalid-magic "Store RPC magic does not match" {}))
      (let [header (byte-array rpc/rpc-v2-header-bytes)]
        (aset-byte header 0 (unchecked-byte first-byte))
        (when-not (read-exact! input header 1 (dec rpc/rpc-v2-header-bytes))
          (server-fail! :rpc-truncated "Store RPC packet ended inside its header" {}))
        (let [body-length (validate-stream-header! header)
              body (byte-array body-length)]
          (when-not (read-exact! input body 0 body-length)
            (server-fail! :rpc-truncated "Store RPC body is shorter than declared" {}))
          (let [packet (byte-array (+ rpc/rpc-v2-header-bytes body-length))]
            (System/arraycopy header 0 packet 0 rpc/rpc-v2-header-bytes)
            (System/arraycopy body 0 packet rpc/rpc-v2-header-bytes body-length)
            (rpc/store-rpc-decode-packet-v2! packet)))))))

(defn- write-rpc-packet! [^OutputStream output packet]
  (let [bytes
        (try
          (rpc/store-rpc-encode-packet-v2! packet)
          (catch Throwable error
            (let [response (t/storerpcpacketv2-response packet)
                  code (or (:store/code (ex-data error)) :rpc/internal-error)
                  fallback
                  (rpc/rpc-response!
                   (t/rpcresponse-space response) (t/rpcresponse-op response)
                   (t/rpcresponse-served-version response) nil
                   (rpc/rpc-error!
                    (if (keyword? code) code :rpc/internal-error) false
                    (or (.getMessage error)
                        "native RPC response is not encodable") nil)
                   nil)]
              (rpc/store-rpc-encode-packet-v2!
               (rpc/store-rpc-response-packet
                (t/storerpcpacketv2-request-id packet) fallback)))))]
    (.write output bytes)
    (.flush output)
    (alength ^bytes bytes)))

(defn- cancellation-state []
  {:cancelled (atom false) :query-control (atom nil)})

(defn- cancel-state! [cancellation reason]
  (reset! (:cancelled cancellation) true)
  (when-let [control @(:query-control cancellation)]
    (datalog/cancel-query! control reason)))

(defn- connection-thread-factory []
  (reify ThreadFactory
    (newThread [_ runnable]
      (doto (Thread. ^Runnable runnable
                     (str "store-rpc-connection-"
                          (.incrementAndGet connection-thread-sequence)))
        (.setDaemon false)))))

(defn- start-connection-admission! []
  (when-let [^ThreadPoolExecutor existing @connection-executor]
    (when-not (.isTerminated existing)
      (throw (ex-info "connection executor is already running" {}))))
  (let [executor
        (ThreadPoolExecutor.
         connection-worker-limit connection-worker-limit
         0 TimeUnit/MILLISECONDS
         (ArrayBlockingQueue. connection-pending-limit)
         (connection-thread-factory))]
    (reset! active-connections 0)
    (reset! connection-sockets #{})
    (reset! admission-rejections 0)
    (reset! connection-executor executor)
    executor))

(defn- finish-accepted-connection! [^Socket socket]
  (locking connection-drain-monitor
    (when (contains? @connection-sockets socket)
      (swap! connection-sockets disj socket)
      (swap! active-connections dec)
      (.notifyAll connection-drain-monitor))))

(defn- close-accepted-connections! []
  (let [sockets (locking connection-drain-monitor
                  (vec @connection-sockets))]
    (doseq [^Socket socket sockets]
      (try (.close socket) (catch Throwable _ nil)))
    (count sockets)))

(defn- remaining-stop-ms [started-ns]
  (max 0 (- (long connection-stop-timeout-ms)
            (quot (- (System/nanoTime) started-ns) 1000000))))

(defn- await-connection-executor! [^ThreadPoolExecutor executor timeout-ms]
  (try
    (.awaitTermination executor (max 0 (long timeout-ms)) TimeUnit/MILLISECONDS)
    (catch InterruptedException _ false)))

(defn- stop-connection-admission! []
  (when-let [^ThreadPoolExecutor executor @connection-executor]
    (let [started-ns (System/nanoTime)]
      (.shutdown executor)
      (when-not (await-connection-executor!
                 executor (min connection-drain-grace-ms
                               connection-stop-timeout-ms))
        (close-accepted-connections!)
        (when-not (await-connection-executor!
                   executor (remaining-stop-ms started-ns))
          (.shutdownNow executor)
          (close-accepted-connections!)
          (await-connection-executor! executor 250)))
      (when-not (.isTerminated executor)
        (emit-log-line!
         (str "store-rpc ts=" (Instant/now)
              " op=server/connection-stop outcome=timed-out"
              " active=" @active-connections
              " pending=" (.size (.getQueue executor)))))
      (compare-and-set! connection-executor executor nil)))
  nil)

(defn- admission-error-code [error]
  (cond
    (instance? SocketTimeoutException error) :rpc/read-timeout
    (instance? SocketException error) :rpc/connection-error
    :else
    (let [data (ex-data error)]
      (or (:store/code data) (:code data) (:type data) :rpc/internal-error))))

(defn- serve-accepted-connection! [^Socket socket]
  (try
    (.setSoTimeout socket connection-first-packet-timeout-ms)
    (serve-connection! socket)
    (catch Throwable error
      (when (= :rpc/internal-error (admission-error-code error))
        (.printStackTrace ^Throwable error System/err)))
    (finally
      (try (.close socket) (catch Throwable _ nil))
      (finish-accepted-connection! socket))))

(defn- record-admission-rejection! [^ThreadPoolExecutor executor]
  (let [rejections (swap! admission-rejections inc)]
    (when (or (= 1 rejections) (zero? (mod rejections 1024)))
      (emit-log-line!
       (str "store-rpc ts=" (Instant/now)
            " op=server/reject outcome=overloaded"
            " workers=" (.getActiveCount executor)
            " pending=" (.size (.getQueue executor))
            " rejected=" rejections)))))

(defn- admit-connection! [^Socket socket]
  (let [tracked?
        (locking connection-drain-monitor
          (when-not @stopping?
            (swap! connection-sockets conj socket)
            (swap! active-connections inc)
            true))]
    (if-not tracked?
      (try (.close socket) (catch Throwable _ nil))
      (let [^ThreadPoolExecutor executor @connection-executor]
        (try
          (.execute
           executor
           ^Runnable
           (reify Runnable
             (run [_]
               (if @stopping?
                 (do
                   (try (.close socket) (catch Throwable _ nil))
                   (finish-accepted-connection! socket))
                 (serve-accepted-connection! socket)))))
          (catch Throwable error
            (if (= "java.util.concurrent.RejectedExecutionException"
                   (.getName (class error)))
              (do
                (when-not @stopping?
                  (record-admission-rejection! executor))
                (try (.close socket) (catch Throwable _ nil))
                (finish-accepted-connection! socket))
              (do
                (try (.close socket) (catch Throwable _ nil))
                (finish-accepted-connection! socket)
                (throw error)))))))))

(defn- register-request! [request-id cancellation]
  (locking active-requests
    (when (contains? @active-requests request-id)
      (server-fail! :rpc/duplicate-request-id
                    "request id is already active" {}))
    (swap! active-requests assoc request-id cancellation)))

(defn handle-rpc-packet! [packet cancellation]
  (case (t/storerpcpacketv2-kind packet)
    :request
    (rpc/store-rpc-response-packet
     (t/storerpcpacketv2-request-id packet)
     (handle-rpc-request! (t/storerpcpacketv2-request packet) cancellation))
    :cancel
    (do
      (when-let [target (get @active-requests (t/storerpcpacketv2-request-id packet))]
        (cancel-state! target :client-cancelled))
      nil)
    (server-fail! :rpc-invalid-kind
                  "listener accepts request and cancel packets only" {})))

(defn- start-connection-request! [^Socket socket packet output started]
  (let [request-id (t/storerpcpacketv2-request-id packet)
        operation (t/rpcrequest-op (t/storerpcpacketv2-request packet))
        cancellation (cancellation-state)]
    (register-request! request-id cancellation)
    {:cancellation cancellation
     :task
     (future
       (try
         (let [response (handle-rpc-packet! packet cancellation)
               response-bytes (write-rpc-packet! output response)
               [outcome code] (response-outcome response)]
           (record-request! operation (- (System/nanoTime) started)
                            outcome code response-bytes))
         (catch Throwable error
           (record-request! operation (- (System/nanoTime) started)
                            :error (admission-error-code error) nil)
           ;; A failed response leaves no valid frame for this session. Closing
           ;; wakes the connection reader and makes the failure immediate.
           (try (.close socket) (catch Throwable _ nil))
           (throw error))
         (finally
           (swap! active-requests dissoc request-id))))}))

(defn- await-connection-request! [pending disconnected?]
  (when pending
    (when (and disconnected? (not (realized? (:task pending))))
      (cancel-state! (:cancellation pending) :client-disconnected))
    (try
      @(:task pending)
      (catch Throwable error
        (when-not disconnected?
          (throw error)))))
  nil)

(defn serve-connection! [^Socket socket]
  (with-open [socket socket]
    (.setTcpNoDelay socket true)
    (let [input (.getInputStream socket)
          output (.getOutputStream socket)
          opened (System/nanoTime)
          pending-request (atom nil)]
      (try
        (loop [first-packet? true]
          (let [packet (read-rpc-packet! input)
                started (System/nanoTime)]
            (when (and first-packet? (.isConnected socket))
              (.setSoTimeout socket 0))
            (if-not packet
              (do
                (await-connection-request! @pending-request true)
                (reset! pending-request nil))
              (if (= :cancel (t/storerpcpacketv2-kind packet))
                (do
                  (handle-rpc-packet! packet (cancellation-state))
                  (record-request! :rpc/cancel (- (System/nanoTime) started)
                                   :ok nil nil)
                  (recur false))
                (do
                  ;; A connection may carry many framed requests, but executes
                  ;; only one at a time so one client cannot bypass admission.
                  (await-connection-request! @pending-request false)
                  (reset! pending-request nil)
                  (reset! pending-request
                          (start-connection-request! socket packet output started))
                  (recur false))))))
        (catch Throwable error
          (await-connection-request! @pending-request true)
          (reset! pending-request nil)
          ;; Beagle Packet-level failures never reach handle-rpc-request!, so without
          ;; this arm a malformed or duplicated request is served invisibly.
          (let [code (admission-error-code error)]
            (record-request! nil (- (System/nanoTime) opened) :error code nil))
          (throw error))))))

(defn- readiness-probe-host [^java.net.InetAddress address]
  (if (.isAnyLocalAddress address)
    (if (= 16 (alength (.getAddress address))) "::1" "127.0.0.1")
    (.getHostAddress address)))

(defn- prove-rpc-ready! [^ServerSocket server]
  (let [request-id Long/MIN_VALUE
        space (database/database-space @active-store)
        request (rpc/rpc-request! space :rpc/version nil nil nil rpc/rpc-unit)
        request-packet (rpc/store-rpc-request-packet request-id request)
        host (readiness-probe-host (.getInetAddress server))
        port (.getLocalPort server)]
    (with-open [client (Socket.)]
      (.connect client (java.net.InetSocketAddress. host port) 5000)
      (.setSoTimeout client 5000)
      (let [accepted (.accept server)]
        (admit-connection! accepted))
      (let [output (.getOutputStream client)]
        (.write output (rpc/store-rpc-encode-packet-v2! request-packet))
        (.flush output))
      (let [packet (read-rpc-packet! (.getInputStream client))
            response (some-> packet t/storerpcpacketv2-response)]
        (when-not
         (and packet
              (= :response (t/storerpcpacketv2-kind packet))
              (= request-id (t/storerpcpacketv2-request-id packet))
              response
              (= space (t/rpcresponse-space response))
              (= :rpc/version (t/rpcresponse-op response))
              (nil? (t/rpcresponse-error response)))
          (throw
           (ex-info "Store RPC readiness probe failed"
                    {:type :rpc-readiness-probe-failed
                     :host host :port port})))))))

(defn serve!
  "Serve Store RPC v2 requests. The default bind is loopback; an authenticated
   private gateway may set BEAGLE_STORE_BIND explicitly. The active process holds
   writer authority for the full listener lifetime; a standby refreshes reads."
  [port path expected-space role]
  (boot! path expected-space role)
  (reset! lifecycle-notification-state :starting)
  (let [bind-host (or (not-empty (System/getenv "BEAGLE_STORE_BIND")) "127.0.0.1")
        runtime (Runtime/getRuntime)
        shutdown-hook (doto (Thread. shutdown!)
                        (.setName "beagle-store-shutdown"))]
    (.addShutdownHook runtime shutdown-hook)
    (try
      (let [server (ServerSocket. (int port) 128
                                  (java.net.InetAddress/getByName bind-host))
            actual-port (.getLocalPort server)]
        (reset! listener server)
        (start-connection-admission!)
        ;; The probe traverses the bound TCP listener, packet codec, admission
        ;; executor, and restored database before Type=notify may activate.
        (prove-rpc-ready! server)
        (notify-ready!)
        (println (str "Beagle Store server listening on " bind-host ":" actual-port
                      " space=" (database/database-space @active-store)
                      " role=" (name @server-role)))
        (flush)
        (emit-log-line!
         (str "store-rpc ts=" (Instant/now) " op=server/listen"
              " bind=" bind-host ":" actual-port
              " space=" (database/database-space @active-store)
              " role=" (name @server-role)
              " slow-ms=" slow-request-ms
              " quiet=" (if request-log-quiet? 1 0)
              " log=" (or request-log-path "stderr")
              " connection-workers=" connection-worker-limit
              " connection-queue=" connection-pending-limit
              " connection-read-timeout-ms=" connection-first-packet-timeout-ms
              " max-heap-mb=" (quot (.maxMemory runtime) 1048576)))
        (while (not @stopping?)
          (try
            (let [socket (.accept server)]
              (admit-connection! socket))
            (catch java.net.SocketException error
              (when-not @stopping? (throw error))))))
      (finally
        (shutdown!)
        (try
          (.removeShutdownHook runtime shutdown-hook)
          (catch IllegalStateException _ nil))))))

(defn -main [& arguments]
  (let [[command & command-arguments] arguments]
    (case command
      "serve"
      (let [[first-arg second-arg third-arg] command-arguments]
        (serve! (Integer/parseInt (or first-arg "7977"))
                (or second-arg
                    (str (System/getProperty "user.dir") "/data/history.storelog"))
                (or third-arg (System/getenv "BEAGLE_STORE_SPACE_ID"))
                (writer-authority/server-role-from-env)))

      (server-fail! :unknown-command
                    "expected serve"
                    {:command command}))))

(when (seq *command-line-args*)
  (apply -main *command-line-args*))
