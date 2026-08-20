(ns store.rt
  "Host-interop runtime for Beagle Store's Beagle modules — the irreducible Clojure
  layer (file IO, string ops, and Store RPC transport) the .bclj
  `declare-extern`s bind to. Beagle owns the typed logic; this owns the host
  calls."
  (:refer-clojure :exclude [slurp])   ; store.rt/slurp wraps clojure.core/slurp; keep the JVM server's stderr clean
  (:require [clojure.string :as str]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [store.rpc :as rpc]
            [store.rt-core :as rtc]
            [store.types :as terms]))

;; --- file IO ----------------------------------------------------------------

(defn slurp [path] (clojure.core/slurp path))

(defn list-md
  "Absolute paths of *.md directly under dir, sorted, excluding CLAUDE.md."
  [dir]
  (->> (.listFiles (io/file dir))
       (map #(.getPath ^java.io.File %))
       (filter #(str/ends-with? % ".md"))
       (remove #(str/ends-with? % "CLAUDE.md"))
       sort
       vec))

(defn spit-file [path content]
  ;; exported .md are a read-only projection of the log: write 0444 so a hand-edit
  ;; fails loud (permission denied) instead of silently stranding the log/file sync.
  ;; setWritable first so re-export can overwrite its own prior read-only output.
  (let [f (io/file path)]
    (when (.exists f) (.setWritable f true))
    (spit path content)
    (.setReadOnly f))
  nil)
(defn ensure-dir [dir] (.mkdirs (io/file dir)) nil)
(defn file-slug
  "Slug portion of a thread filename: '<id>-<slug>.md' -> '<slug>'."
  [path]
  (let [base (str/replace (.getName (io/file path)) #"\.md$" "")
        dash (str/index-of base "-")]
    (if dash (subs base (inc dash)) base)))

;; --- string ops the parser needs -------------------------------------------

(defn split-on [s sep]
  (vec (str/split s (re-pattern (java.util.regex.Pattern/quote sep)) -1)))
(defn str-index-of [s sub] (rtc/str-index-of s sub))
(defn split-comma [s] (rtc/split-comma s))
(defn today-iso [] (str (java.time.LocalDate/now)))
(defn str-lt? [a b] (rtc/str-lt? a b))

;; split a triple line "<predicate><ws><object...>" into [pred obj]; obj may
;; contain spaces (it's the rest of the line). Blank/garbage -> [line ""].
(defn split-kv [line] (rtc/split-kv line))

;; --- fact-native triple-file value (de)serialization -----------------------
;; A fact in a triple file is either a ref (@id, handled by the caller)
;; or a literal. Literals are quoted/unquoted via EDN — bulletproof escaping
;; (the same pr-str/read-string pair the log uses), so no hand-rolled quoter can
;; ever emit something a real parser rejects.
(defn edn-quote [s] (pr-str s))
(defn edn-unquote [s] (edn/read-string s))

;; Parse an EDN string at a human-facing boundary; nil lets the caller report a
;; syntax error without turning malformed input into a runtime failure.
(defn parse-edn [s] (try (edn/read-string s) (catch Exception _ nil)))

;; --- thread id: human-grouped, fixed-width, opaque key ----------------------
;; 2026-06-15-150040 (yyyy-MM-dd-HHmmss). Dashes for glance-readability; fixed
;; width so id<->slug splits by position; sorts chronologically as a plain string.
(defn- fmt-id [n] (rtc/fmt-id n))

(defn now-id []
  (fmt-id (.format (java.time.LocalDateTime/now)
                   (java.time.format.DateTimeFormatter/ofPattern "yyyyMMddHHmmss"))))

;; Advance a dashed id by one second (same fixed-width format). Used to mint a
;; collision-free session id against the fact graph (sessions live in the log,
;; not as files, so they can't use the file-based reserve-id).
(defn bump-id [id]
  (let [fmt (java.time.format.DateTimeFormatter/ofPattern "yyyyMMddHHmmss")
        dt (java.time.LocalDateTime/parse (str/replace id "-" "") fmt)]
    (fmt-id (.format (.plusSeconds dt 1) fmt))))

;; The thread id, not the filename, is the entity key — two captures in the same
;; second produce distinct filenames (slugs differ) but would COLLIDE on id.
(defn- id-taken? [dir id]
  (let [f (io/file dir)]
    (boolean
     (when (.isDirectory f)
       (some (fn [n] (or (str/starts-with? n (str id "-")) (= n (str id ".md"))))
             (map #(.getName ^java.io.File %) (.listFiles f)))))))

;; Atomically reserve a free id ACROSS concurrent capture processes: bump past
;; any id already asserted by a file (id-taken?) AND any in-flight reservation —
;; the latter via an exclusive CREATE_NEW of a per-id lock dotfile, which two
;; racers in the same second cannot both win. Caller writes <id>-<slug>.md then
;; release-id. (A scan-then-write alone has a TOCTOU window two distinct-slug
;; captures slip through, silently folding into one entity on import.)
(defn- lock-path [dir id] (str dir "/." id ".lock"))
(defn reserve-id [dir]
  (loop [n (Long/parseLong (.format (java.time.LocalDateTime/now)
                                    (java.time.format.DateTimeFormatter/ofPattern "yyyyMMddHHmmss")))]
    (let [id (fmt-id n)
          ;; try returns the id on a clean exclusive create, nil if the id is
          ;; taken or a racer won the lock — recur OUTSIDE the try (recur cannot
          ;; cross a try/catch boundary).
          got (when-not (id-taken? dir id)
                (try (java.nio.file.Files/createFile
                      (.toPath (io/file (lock-path dir id)))
                      (make-array java.nio.file.attribute.FileAttribute 0))
                     id
                     (catch java.nio.file.FileAlreadyExistsException _ nil)))]
      (if got got (recur (inc n))))))
(defn release-id [dir id] (.delete (io/file (lock-path dir id))) nil)

(defn slugify [title] (rtc/slugify title))

;; --- Store RPC transport ----------------------------------------------------

;; client-side mutual TLS: present BEAGLE_STORE_SERVER_TLS_KEYSTORE, verify the server against
;; BEAGLE_STORE_SERVER_TLS_TRUSTSTORE. Works on babashka (client SSL classes are present; only the
;; SERVER-side SSLServerSocket is absent, which is why the server runs on the JVM).
(defn- client-ssl-context [ks ts pass]
  (let [pw (.toCharArray ^String pass)
        load (fn [p] (with-open [in (io/input-stream p)]
                       (doto (java.security.KeyStore/getInstance "PKCS12") (.load in pw))))
        kmf (doto (javax.net.ssl.KeyManagerFactory/getInstance (javax.net.ssl.KeyManagerFactory/getDefaultAlgorithm))
              (.init (load ks) pw))
        tmf (doto (javax.net.ssl.TrustManagerFactory/getInstance (javax.net.ssl.TrustManagerFactory/getDefaultAlgorithm))
              (.init (load ts)))]
    (doto (javax.net.ssl.SSLContext/getInstance "TLS")
      (.init (.getKeyManagers kmf) (.getTrustManagers tmf) nil))))

;; connect to the server: BEAGLE_STORE_SERVER_CONNECT host (default 127.0.0.1); mutual TLS when
;; BEAGLE_STORE_SERVER_TLS_* is set, else plaintext (the unchanged loopback default).
(defn- connect-host []
  (let [h (System/getenv "BEAGLE_STORE_SERVER_CONNECT")] (if (str/blank? h) "127.0.0.1" h)))

(defn- server-timeout-ms [name default]
  (let [raw (or (System/getenv name) (str default))]
    (when-not (re-matches #"[1-9][0-9]{0,5}" raw)
      (throw
       (ex-info
        (str name " must be an integer from 1 through 999999 milliseconds")
        {:type :invalid-server-timeout :name name :value raw})))
    (Integer/parseInt raw)))

(defn- run-with-server-watchdog!
  [closeable timeout timeout-message timeout-type operation]
  (let [state (atom :armed)
        watchdog
        (future
          (try
            (Thread/sleep timeout)
            (when (compare-and-set! state :armed :expired)
              (.close closeable))
            (catch InterruptedException _ nil)
            (catch Throwable _ nil)))]
    (try
      (let [result (operation)]
        (when-not (compare-and-set! state :armed :complete)
          (throw
           (ex-info timeout-message
                    {:type timeout-type
                     :timeout-ms timeout})))
        result)
      (catch Throwable error
        (if (= :expired @state)
          (throw
           (ex-info timeout-message
                    {:type timeout-type
                     :timeout-ms timeout}
                    error))
          (do
            (compare-and-set! state :armed :complete)
            (throw error))))
      (finally
        (future-cancel watchdog)))))

(defn- server-tls-handshake! [socket]
  (let [timeout (server-timeout-ms "BEAGLE_STORE_SERVER_HANDSHAKE_TIMEOUT_MS" 2000)]
    ;; SO_TIMEOUT bounds an individual SSL read and the watchdog bounds the
    ;; whole exchange. Store RPC installs its deadline after the handshake.
    (.setSoTimeout socket timeout)
    (run-with-server-watchdog!
     socket
     timeout
     "server TLS handshake deadline exceeded"
     :server-handshake-timeout
     (fn []
       (.startHandshake socket)
       nil))))

(defn- server-socket [host port]
  (let [ks (System/getenv "BEAGLE_STORE_SERVER_TLS_KEYSTORE") ts (System/getenv "BEAGLE_STORE_SERVER_TLS_TRUSTSTORE")
        pass (or (System/getenv "BEAGLE_STORE_SERVER_TLS_PASS")
                 (when-let [f (System/getenv "BEAGLE_STORE_SERVER_TLS_PASS_FILE")] (str/trim (slurp f))))]
    ;; fail CLOSED on a partial config — a typo'd/missing var must NOT silently
    ;; downgrade a "secure" link to plaintext.
    (when (and (or ks ts pass) (not (and ks ts pass)))
      (binding [*out* *err*]
        (println "FATAL: BEAGLE_STORE_SERVER_TLS_* partially set — need ALL of BEAGLE_STORE_SERVER_TLS_KEYSTORE / BEAGLE_STORE_SERVER_TLS_TRUSTSTORE / BEAGLE_STORE_SERVER_TLS_PASS (refusing to connect in plaintext)"))
      (System/exit 2))
    (if (and ks ts pass)
      (let [s (.createSocket (.getSocketFactory (client-ssl-context ks ts pass)))]
        (try
          (.connect s
                    (java.net.InetSocketAddress. ^String host (int port))
                    (server-timeout-ms "BEAGLE_STORE_SERVER_CONNECT_TIMEOUT_MS" 2000))
          (server-tls-handshake! s)
          s
          (catch Throwable error
            (try (.close s) (catch Throwable _ nil))
            (throw error))))
      (let [s (java.net.Socket.)]
        (try
          (.connect s
                    (java.net.InetSocketAddress. ^String host (int port))
                    (server-timeout-ms "BEAGLE_STORE_SERVER_CONNECT_TIMEOUT_MS" 2000))
          s
          (catch Throwable error
            (try (.close s) (catch Throwable _ nil))
            (throw error)))))))

(defn server-port []
  (if-let [port (System/getenv "BEAGLE_STORE_SERVER_PORT")]
    (Integer/parseInt port)
    7977))

;; --- Store RPC v2 client ----------------------------------------------------
;; Data clients share this one bounded binary implementation. Human-facing
;; commands may parse EDN before this boundary, but only recursive Terms and
;; closed RpcRequest records reach the socket.

(def ^:private rpc-request-sequence (java.util.concurrent.atomic.AtomicLong. 0))

(defn rpc-space-id []
  (let [space (System/getenv "BEAGLE_STORE_SPACE_ID")]
    (when (str/blank? space)
      (throw (ex-info "BEAGLE_STORE_SPACE_ID is required for Store RPC data requests"
                      {:type :rpc-space-id-required})))
    space))

(defn- next-rpc-request-id []
  (let [value (.incrementAndGet rpc-request-sequence)]
    (if (pos? value)
      value
      (do
        (.set rpc-request-sequence 1)
        1))))

(defn- read-rpc-exact! [input bytes offset length]
  (loop [position offset remaining length]
    (if (zero? remaining)
      true
      (let [read-count (.read input bytes position remaining)]
        (if (neg? read-count)
          false
          (recur (+ position read-count) (- remaining read-count)))))))

(defn- rpc-stream-body-length! [header]
  (dotimes [index 8]
    (when-not (= (bit-and 255 (int (aget header index)))
                 (bit-and 255 (int (aget rpc/store-rpc-v2-magic index))))
      (throw (ex-info "Store RPC response magic does not match"
                      {:type :rpc-invalid-magic}))))
  (let [buffer (doto (java.nio.ByteBuffer/wrap header)
                 (.order java.nio.ByteOrder/LITTLE_ENDIAN))]
    (.position buffer 8)
    (let [major (Short/toUnsignedInt (.getShort buffer))
          minor (Short/toUnsignedInt (.getShort buffer))
          kind (bit-and 255 (int (.get buffer)))
          flags (bit-and 255 (int (.get buffer)))
          body-length (Integer/toUnsignedLong (.getInt buffer))]
      (when-not (and (= major rpc/rpc-v2-major)
                     (= minor rpc/rpc-v2-minor))
        (throw (ex-info "Store RPC response version is unsupported"
                        {:type :rpc-unsupported-version
                         :major major :minor minor})))
      (when-not (contains? #{2 4} kind)
        (throw (ex-info "Store RPC client expected a response or event packet"
                        {:type :rpc-invalid-kind :kind kind})))
      (when-not (zero? flags)
        (throw (ex-info "Store RPC v2 response flags must be zero"
                        {:type :rpc-invalid-flags :flags flags})))
      (when (> body-length rpc/rpc-v2-max-body-bytes)
        (throw (ex-info "Store RPC response body exceeds the 1 MiB limit"
                        {:type :rpc-packet-too-large
                         :body-length body-length})))
      (int body-length))))

(defn store-rpc-read-packet! [input]
  (let [header (byte-array rpc/rpc-v2-header-bytes)]
    (when-not (read-rpc-exact! input header 0 rpc/rpc-v2-header-bytes)
      (throw (ex-info "Store RPC response ended inside its header"
                      {:type :rpc-truncated})))
    (let [body-length (rpc-stream-body-length! header)
          body (byte-array body-length)
          packet (byte-array (+ rpc/rpc-v2-header-bytes body-length))]
      (when-not (read-rpc-exact! input body 0 body-length)
        (throw (ex-info "Store RPC response ended inside its body"
                        {:type :rpc-truncated})))
      (System/arraycopy header 0 packet 0 rpc/rpc-v2-header-bytes)
      (System/arraycopy body 0 packet rpc/rpc-v2-header-bytes body-length)
      (rpc/store-rpc-decode-packet-v2! packet))))

(defn native-request-to!
  "Send one closed Store RPC request to host/port and return its RpcResponse.
   The response id, space, and operation must match the request exactly."
  [host port request]
  (let [request-id (next-rpc-request-id)]
    (with-open [socket (server-socket host port)]
      (let [timeout (max (server-timeout-ms "BEAGLE_STORE_SERVER_READ_TIMEOUT_MS" 15000)
                         (+ 1000 (or (terms/rpcrequest-timeout-ms request) 0)))
            output (.getOutputStream socket)]
        (.setSoTimeout socket timeout)
        (.write output
                (rpc/store-rpc-encode-packet-v2!
                 (rpc/store-rpc-request-packet request-id request)))
        (.flush output)
        (let [packet (store-rpc-read-packet! (.getInputStream socket))
              response (terms/storerpcpacketv2-response packet)]
          (when-not (= :response (terms/storerpcpacketv2-kind packet))
            (throw (ex-info "Store RPC request received a non-response packet"
                            {:type :rpc-invalid-kind})))
          (when-not (= request-id
                       (terms/storerpcpacketv2-request-id packet))
            (throw (ex-info "Store RPC response request-id does not match"
                            {:type :rpc-request-id-mismatch})))
          (when-not (and (= (terms/rpcrequest-space request)
                            (terms/rpcresponse-space response))
                         (= (terms/rpcrequest-op request)
                            (terms/rpcresponse-op response)))
            (throw (ex-info "Store RPC response identity does not match its request"
                            {:type :rpc-response-mismatch})))
          response)))))

(defn native-request! [port request]
  (native-request-to! (connect-host) port request))

(defn native-call!
  ([port operation payload]
   (native-call! port (rpc-space-id) operation payload nil nil nil))
  ([port space operation payload expected-version page timeout-ms]
   (native-request!
    port
    (rpc/rpc-request! space operation expected-version page timeout-ms
                           payload))))

(defn native-error [response] (terms/rpcresponse-error response))
(defn native-error-code [response]
  (some-> response native-error terms/rpcerror-code))
(defn native-payload [response]
  (terms/rpc-response-payload-value response))

(defn require-native-success! [response]
  (if-let [error (native-error response)]
    (throw (ex-info (terms/rpcerror-message error)
                    {:type (terms/rpcerror-code error)
                     :code (terms/rpcerror-code error)
                     :retryable (terms/rpcerror-retryable error)
                     :served-version (terms/rpcresponse-served-version response)
                     :detail (terms/rpc-error-detail-value error)}))
    response))

(defn rpc-record-fields! [value tag field-count]
  (rpc/rpc-record-fields! value tag field-count))

(defn rpc-list-values! [value]
  (rpc/rpc-list-values! value))

;; The human syntax is deliberately just a local lowering convenience. A
;; three-element vector is a Triple; {:instant [seconds nanos]} is an Instant;
;; symbols become String atoms. Maps and arbitrary sequences never cross the
;; data socket.
(declare lower-term!)

(defn lower-term! [value]
  (cond
    (terms/term? value) value
    (symbol? value) (str value)
    (and (vector? value) (= 3 (count value)))
    (terms/triple (lower-term! (nth value 0))
                  (lower-term! (nth value 1))
                  (lower-term! (nth value 2)))
    (and (map? value)
         (= #{:instant} (set (keys value)))
         (vector? (:instant value))
         (= 2 (count (:instant value))))
    (terms/instant (long (nth (:instant value) 0))
                   (long (nth (:instant value) 1)))
    :else
    (throw (ex-info "value cannot be lowered to Term"
                    {:type :invalid-term-input :value value}))))

(defn parse-human-term!
  "Parse one local EDN datum, falling back to the original text as a String.
   This parser is a CLI boundary only; its result is immediately lowered."
  [text]
  (let [parsed
        (try
          (with-open [reader (java.io.PushbackReader.
                              (java.io.StringReader. text))]
            (let [eof (Object.)
                  value (edn/read {:eof eof} reader)
                  trailing (edn/read {:eof eof} reader)]
              (when (or (identical? eof value)
                        (not (identical? eof trailing)))
                (throw (ex-info "expected exactly one EDN datum" {})))
              value))
          (catch Throwable _ text))]
    (try
      (lower-term! parsed)
      (catch Throwable _
        (if (string? parsed) parsed text)))))

(defn- query-field [value key]
  (if (contains? value key)
    (get value key)
    (get value (name key))))

(defn- query-has? [value key]
  (or (contains? value key) (contains? value (name key))))

(defn- require-query-field! [value key]
  (if (query-has? value key)
    (query-field value key)
    (throw (ex-info (str "query field " (name key) " is required")
                    {:type :query-invalid-syntax :field key}))))

(defn- query-name! [value label]
  (cond
    (string? value) value
    (keyword? value) (subs (str value) 1)
    (symbol? value) (str value)
    :else (throw (ex-info (str label " must be a name")
                          {:type :query-invalid-syntax :value value}))))

(defn- query-operation! [value label]
  (cond
    (keyword? value) value
    (string? value) (keyword value)
    (symbol? value) (keyword (str value))
    :else (throw (ex-info (str label " must be a keyword spelling")
                          {:type :query-invalid-syntax :value value}))))

(defn- lower-query-term! [value]
  (if (and (map? value)
           (= #{(if (contains? value :var) :var "var")}
              (set (keys value))))
    (rpc/rpc-query-variable!
     (query-name! (query-field value :var) "query variable"))
    (rpc/rpc-query-constant! (lower-term! value))))

(defn- lower-query-head! [value]
  (rpc/rpc-query-head!
   (query-name! (require-query-field! value :rel) "query relation")
   (mapv lower-query-term! (require-query-field! value :args))))

(defn- lower-query-clause! [value]
  (cond
    (query-has? value :rel)
    (rpc/rpc-query-relation!
     (query-name! (query-field value :rel) "query relation")
     (mapv lower-query-term! (require-query-field! value :args))
     (boolean (or (query-field value :neg)
                  (query-field value :not)
                  (query-field value :negated))))

    (query-has? value :pred)
    (let [arguments (vec (require-query-field! value :args))]
      (when-not (= 2 (count arguments))
        (throw (ex-info "query predicate requires exactly two arguments"
                        {:type :query-invalid-syntax})))
      (rpc/rpc-query-predicate!
       (query-operation! (query-field value :pred) "query predicate")
       (lower-query-term! (nth arguments 0))
       (lower-query-term! (nth arguments 1))))

    (query-has? value :fn)
    (rpc/rpc-query-function!
     (query-operation! (query-field value :fn) "query function")
     (mapv lower-query-term! (require-query-field! value :args))
     (query-name! (require-query-field! value :bind) "query binding"))

    :else
    (throw (ex-info "query clause must be relation, predicate, or function"
                    {:type :query-invalid-syntax :value value}))))

(defn- lower-query-rule! [value]
  (rpc/rpc-query-rule!
   (lower-query-head! (require-query-field! value :head))
   (mapv lower-query-clause! (require-query-field! value :body))))

(defn- lower-query-find! [value]
  (if (map? value)
    (rpc/rpc-query-find-aggregate!
     (query-name! (require-query-field! value :rel) "aggregate relation")
     (mapv long (or (query-field value :group) []))
     (mapv
      (fn [aggregate]
        (rpc/rpc-query-aggregate!
         (query-operation! (require-query-field! aggregate :op)
                           "aggregate operation")
         (when (query-has? aggregate :arg)
           (long (query-field aggregate :arg)))))
      (require-query-field! value :agg))
     (mapv
      (fn [having]
        (rpc/rpc-query-having!
         (query-operation! (require-query-field! having :op)
                           "having comparison")
         (long (require-query-field! having :agg))
         (lower-term! (require-query-field! having :val))))
      (or (query-field value :having) [])))
    (rpc/rpc-query-find-relation!
     (query-name! value "find relation"))))

(defn lower-query-plan!
  "Lower the public structured query syntax into the closed recursive-Term IR."
  [value]
  (when-not (map? value)
    (throw (ex-info "query must be a map"
                    {:type :query-invalid-syntax})))
  (let [rules? (query-has? value :rules)
        strata? (query-has? value :strata)]
    (when (= rules? strata?)
      (throw (ex-info "query requires exactly one of rules or strata"
                      {:type :query-invalid-syntax})))
    (rpc/rpc-ordered-query-plan!
     (lower-query-find! (require-query-field! value :find))
     (mapv (fn [rules]
             (rpc/rpc-query-stratum!
              (mapv lower-query-rule! rules)))
           (if rules?
             [(require-query-field! value :rules)]
             (require-query-field! value :strata)))
     (mapv
      (fn [clause]
        (rpc/rpc-query-order!
         (long (require-query-field! clause :column))
         (query-operation!
          (require-query-field! clause :direction)
          "query order direction")))
      (or (query-field value :order-by) []))
     (when (query-has? value :limit)
       (long (query-field value :limit))))))

(defn native-query-payload!
  ([query] (native-query-payload! query nil))
  ([query as-of]
   (rpc/rpc-query-request!
    (lower-query-plan! query)
    (if (nil? as-of)
      rpc/query-current
      (rpc/rpc-query-as-of! (long as-of))))))

;; --- time module runtime (ported from los.rt for `north clock`) -----------

(defn error-exit [msg]
  (binding [*out* *err*] (println (str "error: " msg)))
  (System/exit 1))

(defn now-iso []
  (.format (java.time.LocalDateTime/now)
           (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd'T'HH:mm:ss")))

;; Canonical timestamps are zone-less local ISO (now-iso above), but facts also
;; arrive hand-written with a Z/±hh:mm offset (e.g. reconstructed clock
;; sessions). Honor an explicit offset when present; anything zone-less stays
;; interpreted in the system zone as before.
(defn iso-to-seconds [s]
  (let [normalized (if (= 16 (count s)) (str s ":00") s)]
    (if (re-find #"(Z|[+-]\d\d:?\d\d)$" normalized)
      (.toEpochSecond (java.time.OffsetDateTime/parse normalized))
      (.toEpochSecond (.atZone (java.time.LocalDateTime/parse normalized)
                               (java.time.ZoneId/systemDefault))))))

;; tolerant int parse for fact literals (estimate_hours etc.); 0 on garbage.
(defn parse-int [s]
  (try (Integer/parseInt (str/trim s)) (catch Exception _ 0)))

(defn this-week-dates []
  (let [today (java.time.LocalDate/now)
        dow (.getValue (.getDayOfWeek today))]
    (mapv (fn [i] (.toString (.plusDays today (- i (dec dow))))) (vec (range 0 7)))))

(defn file-exists [p] (.exists (io/file p)))
(defn create-dirs [p] (.mkdirs (io/file p)) nil)
(defn delete-file [p] (when (.exists (io/file p)) (.delete (io/file p))) nil)
(defn spit-append [p content] (spit p content :append true) nil)
(defn getenv [nm] (System/getenv nm))
(defn filter-digits [s] (rtc/filter-digits s))
(defn is-iso-datetime-19 [s] (rtc/is-iso-datetime-19 s))
(defn is-iso-datetime-16 [s] (rtc/is-iso-datetime-16 s))
(defn repeat-str [s n] (rtc/repeat-str s n))

;; Clockify HTTP — lazy-resolve babashka.http-client so the AOT/native path
;; never references it at compile time (network/out-of-scope there).
(defn http-get [url api-key]
  (or (:body ((requiring-resolve 'babashka.http-client/get)
              url {:headers {"X-Api-Key" api-key}})) ""))
(defn http-post [url api-key body]
  (or (:body ((requiring-resolve 'babashka.http-client/post)
              url {:headers {"X-Api-Key" api-key "Content-Type" "application/json"}
                   :body body})) ""))
