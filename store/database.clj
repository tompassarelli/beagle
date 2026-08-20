;; database.clj — authoritative TermStore v2 database.
;;
;; Semantic values use the recursive-Term kernel; occurrence and withdrawal
;; history uses the store's structural records. Schema, query, pull, and
;; codegraph remain downstream projections; none may restore the removed
;; fact-object store beneath this boundary.
(ns database
  (:require [clojure.string :as str]
            [store.rpc :as rpc]
            [store.branch :as branch]
            [store.chain-rules :as chain-rules]
            [store.store :as term-store]
            [store.types :as t]))

;; Fork renames a live log, so it takes the same lifetime lock the server does.
;; Callers reach this file from their own working directory, so the sibling is
;; located from this file rather than from the process's.
(load-file
 (.getPath (java.io.File.
            (.getParentFile (.getCanonicalFile (java.io.File. (str *file*))))
            "writer_authority.clj")))

(def ^:private ^"[B" triple-log-magic
  (.getBytes "__Store transaction log_MAGIC__" java.nio.charset.StandardCharsets/UTF_8))
(def ^:private triple-log-version 1)
(def ^:private triple-log-flags 0)
;; Header flag bit 0: every record payload in this generation is
;; Deflate-compressed; the CRC still covers the stored (compressed) bytes.
(def ^:private deflate-flag 1)
;; Header flag bit 1: this generation continues a sealed segment chain and is
;; not a whole store on its own, so every single-file open must refuse it.
(def ^:private continuation-flag 2)
(def ^:private max-term-depth 256)
(def ^:private canonical-validator "store/canonical-validator-v1")
(def ^:private canonical-shape-schema-id "store/CommitOperationV1")

(defn- default-commit-metadata [producer profile]
  {:producer producer
   :shape-schema-id canonical-shape-schema-id
   :profile profile
   :validation-attestation
   {:validator canonical-validator
    :result :pending
    :attestation canonical-validator}})

(defn- canonical-validate-commit! [operations metadata]
  (let [metadata (or metadata (default-commit-metadata "store.legacy-api/v1" nil))
        validation (:validation-attestation metadata)]
    (when-not (and (map? metadata)
                   (string? (:producer metadata))
                   (pos? (count (:producer metadata)))
                   (string? (:shape-schema-id metadata))
                   (pos? (count (:shape-schema-id metadata)))
                   (or (nil? (:profile metadata))
                       (and (string? (:profile metadata))
                            (pos? (count (:profile metadata)))))
                   (map? validation)
                   (string? (:validator validation))
                   (keyword? (:result validation))
                   (string? (:attestation validation)))
      (throw (ex-info
              "store: canonical commit validation rejected the write"
              {:type :canonical-commit-rejected
               :store/code :canonical-commit-rejected
               :metadata metadata})))
    (assoc metadata
           :validation-attestation
           {:validator canonical-validator
            :result :accepted
            :attestation canonical-validator})))

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :store/code code))))

(defn- require-u32! [n label]
  (when-not (and (integer? n) (<= 0 n 4294967295))
    (fail! :invalid-integer
           (str label " is outside unsigned 32-bit range")
           {:label label :value n}))
  (long n))

(defn- require-i64! [n label]
  (when-not (and (integer? n) (<= Long/MIN_VALUE n Long/MAX_VALUE))
    (fail! :invalid-integer
           (str label " is outside signed 64-bit range")
           {:label label :value n}))
  (long n))

(defn- write-u8! [^java.io.OutputStream out n]
  (.write out (int (bit-and 255 (long n)))))

(defn- write-u16-le! [^java.io.OutputStream out n]
  (let [v (long n)]
    (dotimes [i 2]
      (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- write-u32-le! [^java.io.OutputStream out n]
  (let [v (require-u32! n "u32")]
    (dotimes [i 4]
      (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- write-i64-le! [^java.io.OutputStream out n]
  (let [v (require-i64! n "i64")]
    (dotimes [i 8]
      (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- strict-utf8-bytes [s label]
  (when-not (string? s)
    (fail! :invalid-text (str label " must be a String")
           {:label label :value s}))
  (try
    (let [encoder (doto (.newEncoder java.nio.charset.StandardCharsets/UTF_8)
                    (.onMalformedInput java.nio.charset.CodingErrorAction/REPORT)
                    (.onUnmappableCharacter java.nio.charset.CodingErrorAction/REPORT))
          buffer (.encode encoder (java.nio.CharBuffer/wrap ^String s))
          bytes (byte-array (.remaining buffer))]
      (.get buffer bytes)
      bytes)
    (catch java.nio.charset.CharacterCodingException e
      (fail! :invalid-utf8 (str label " is not valid UTF-8 text")
             {:label label :cause (.getMessage e)}))))

(defn- strict-utf8-string [^bytes bytes label]
  (try
    (let [decoder (doto (.newDecoder java.nio.charset.StandardCharsets/UTF_8)
                    (.onMalformedInput java.nio.charset.CodingErrorAction/REPORT)
                    (.onUnmappableCharacter java.nio.charset.CodingErrorAction/REPORT))]
      (str (.decode decoder (java.nio.ByteBuffer/wrap bytes))))
    (catch java.nio.charset.CharacterCodingException e
      (fail! :invalid-utf8 (str label " is not valid UTF-8")
             {:label label :cause (.getMessage e)}))))

(defn- write-triple! [^java.io.OutputStream out value depth]
  (when-not (t/triple? value)
    (fail! :invalid-triple "recursive encoder requires a Triple" {:value value}))
  (when-not (zero? depth)
    (fail! :invalid-term-depth "Store transaction log Term encoding must begin at depth zero"
           {:depth depth}))
  (try
    (rpc/write-term-codec-v1!
     out value Integer/MAX_VALUE Integer/MAX_VALUE max-term-depth)
    (catch clojure.lang.ExceptionInfo e
      (let [code (:store/code (ex-data e))]
        (case code
          :term-depth-exceeded (throw e)
          :term-codec-invalid-utf8
          (fail! :invalid-utf8 "Store transaction log Term contains invalid UTF-8" {:cause code})
          :term-codec-invalid-keyword
          (fail! :invalid-keyword "Store transaction log Keyword atom is empty" {:cause code})
          :term-codec-integer-range
          (fail! :invalid-integer "Store transaction log Term integer is out of range" {:cause code})
          :term-codec-unsupported-term
          (fail! :unsupported-term "Store transaction log encountered a value outside Term"
                 {:value value :class (some-> value class str)})
          (throw e))))))

(defn- ensure-remaining! [^java.nio.ByteBuffer buffer n context]
  (when (< (.remaining buffer) n)
    (fail! :corrupt-triple-log "Store transaction log payload ended inside a value"
           {:context context :needed n :remaining (.remaining buffer)})))

(defn- read-u32 [^java.nio.ByteBuffer buffer context]
  (ensure-remaining! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer)))

(defn- read-term [^java.nio.ByteBuffer buffer depth]
  (when-not (zero? depth)
    (fail! :corrupt-triple-log "Store transaction log Term decoding must begin at depth zero"
           {:depth depth}))
  (try
    (t/termcodecdecoded-value
     (rpc/decode-term-codec-v1!
      buffer Integer/MAX_VALUE Integer/MAX_VALUE max-term-depth))
    (catch clojure.lang.ExceptionInfo e
      (if (= :term-depth-exceeded (:store/code (ex-data e)))
        (throw e)
        (fail! :corrupt-triple-log "Store transaction log contains a malformed Term"
               {:cause (:store/code (ex-data e))})))))

(defn- wire-action [action]
  (case action :assert 1 :retract 2
        (fail! :invalid-commit-operation "operation action must be :assert or :retract"
               {:action action})))

(defn- store-action [action]
  (case action
    1 :assert
    2 :retract
    (fail! :corrupt-triple-log "Store transaction log contains an unknown operation action"
           {:action action})))

(defn- operation-map [ordinal operation]
  {:ordinal ordinal
   :action (wire-action (t/commitoperation-action operation))
   :triple (t/commitoperation-proposition operation)})

(defn- deflate-bytes ^bytes [^bytes bytes]
  (let [out (java.io.ByteArrayOutputStream. (alength bytes))]
    (with-open [gz (java.util.zip.GZIPOutputStream. out)]
      (.write gz bytes))
    (.toByteArray out)))

(defn- inflate-bytes ^bytes [^bytes bytes path offset]
  (try
    (let [out (java.io.ByteArrayOutputStream. (* 4 (alength bytes)))
          buffer (byte-array 8192)]
      (with-open [gz (java.util.zip.GZIPInputStream.
                      (java.io.ByteArrayInputStream. bytes))]
        (loop []
          (let [n (.read gz buffer)]
            (when (pos? n)
              (.write out buffer 0 n)
              (recur)))))
      (.toByteArray out))
    (catch java.io.IOException error
      (fail! :corrupt-triple-log "Store transaction log deflate record is invalid"
             {:path path :offset offset :cause (.getMessage error)}))))

(defn- write-transaction-record! [^java.io.OutputStream out tx deflate?]
  (let [payload (java.io.ByteArrayOutputStream.)
        operations (:operations tx)]
    (write-i64-le! payload (:tx-seq tx))
    (write-u32-le! payload (count operations))
    (doseq [[expected operation] (map-indexed vector operations)]
      (when-not (= expected (:ordinal operation))
        (fail! :noncontiguous-ordinal
               "transaction operation ordinals must be contiguous"
               {:tx-seq (:tx-seq tx) :expected expected
                :actual (:ordinal operation)}))
      (write-u32-le! payload (:ordinal operation))
      (write-u8! payload (:action operation))
      (write-triple! payload (:triple operation) 0))
    (let [bytes (let [^bytes raw (.toByteArray payload)]
                  (if deflate? (deflate-bytes raw) raw))
          crc (doto (java.util.zip.CRC32.) (.update ^bytes bytes))]
      (write-u32-le! out (alength ^bytes bytes))
      (.write out ^bytes bytes)
      (write-u32-le! out (.getValue crc)))))

(defn- decode-transaction-payload [^bytes payload record-offset]
  (let [buffer (doto (java.nio.ByteBuffer/wrap payload)
                 (.order java.nio.ByteOrder/LITTLE_ENDIAN))]
    (ensure-remaining! buffer 12 "transaction header")
    (let [sequence (.getLong buffer)
          operation-count (read-u32 buffer "operation count")]
      (when (neg? sequence)
        (fail! :corrupt-triple-log "Store transaction log transaction sequence is negative"
               {:offset record-offset :sequence sequence}))
      (when (or (zero? operation-count) (> operation-count Integer/MAX_VALUE))
        (fail! :corrupt-triple-log "Store transaction log transaction operation count is invalid"
               {:offset record-offset :operation-count operation-count}))
      (let [operations
            (mapv
             (fn [expected]
               (let [ordinal (read-u32 buffer "operation ordinal")]
                 (when-not (= expected ordinal)
                   (fail! :noncontiguous-ordinal
                          "Store transaction log operation ordinals are not contiguous"
                          {:offset record-offset :sequence sequence
                           :expected expected :actual ordinal}))
                 (ensure-remaining! buffer 1 "operation action")
                 (let [action (bit-and 255 (int (.get buffer)))
                       proposition (read-term buffer 0)]
                   (when-not (t/triple? proposition)
                     (fail! :corrupt-triple-log
                            "Store transaction log operation proposition is not a Triple"
                            {:offset record-offset :sequence sequence
                             :ordinal ordinal}))
                   {:ordinal ordinal :action action
                    :store-action (store-action action)
                    :triple proposition})))
             (range (int operation-count)))]
        (when-not (zero? (.remaining buffer))
          (fail! :corrupt-triple-log "Store transaction log transaction has trailing payload bytes"
                 {:offset record-offset :sequence sequence
                  :remaining (.remaining buffer)}))
        {:tx-seq sequence :operations operations}))))

(defn- bytes-prefix? [^bytes bytes ^bytes prefix]
  (and (>= (alength bytes) (alength prefix))
       (java.util.Arrays/equals
        prefix (java.util.Arrays/copyOfRange bytes 0 (alength prefix)))))

(defn- parse-triple-log-bytes
  ([^bytes bytes path] (parse-triple-log-bytes bytes path false))
  ([^bytes bytes path allow-continuation?]
  (when-not (bytes-prefix? bytes triple-log-magic)
    (fail! :corrupt-triple-log
           "Store transaction log magic does not match"
           {:path path}))
  (let [^java.nio.ByteBuffer buffer
        (doto (java.nio.ByteBuffer/wrap bytes)
          (.order java.nio.ByteOrder/LITTLE_ENDIAN))]
    (.position buffer (alength triple-log-magic))
    (try
      (ensure-remaining! buffer 8 "Store transaction log header")
      (let [version (bit-and 65535 (int (.getShort buffer)))
            flags (bit-and 65535 (int (.getShort buffer)))
            space-length (read-u32 buffer "SpaceId length")]
        (when-not (and (= triple-log-version version)
                       (contains? (if allow-continuation?
                                    #{triple-log-flags deflate-flag
                                      continuation-flag
                                      (bit-or deflate-flag continuation-flag)}
                                    #{triple-log-flags deflate-flag})
                                  flags))
          (fail! :unsupported-log-version
                 "Store transaction log version or flags are unsupported"
                 {:path path :version version :flags flags}))
        (when (or (zero? space-length) (> space-length Integer/MAX_VALUE))
          (fail! :corrupt-triple-log "Store transaction log SpaceId length is invalid"
                 {:path path :length space-length}))
        (ensure-remaining! buffer (int space-length) "SpaceId")
        (let [space-bytes (byte-array (int space-length))
              _ (.get buffer space-bytes)
              space-id (strict-utf8-string space-bytes "SpaceId")
              deflate? (pos? (bit-and deflate-flag flags))
              continuation? (pos? (bit-and continuation-flag flags))
              header-bytes (.position buffer)]
          (loop [records [] valid-bytes header-bytes prefix-ends {}]
            (let [offset (.position buffer)
                  remaining (.remaining buffer)]
              (cond
                (zero? remaining)
                {:space-id space-id :deflate? deflate? :records records
                 :continuation? continuation?
                 :valid-bytes valid-bytes
                 :header-bytes header-bytes :prefix-ends prefix-ends
                 :torn-tail nil}

                (< remaining 4)
                {:space-id space-id :deflate? deflate? :records records
                 :continuation? continuation?
                 :valid-bytes valid-bytes
                 :header-bytes header-bytes :prefix-ends prefix-ends
                 :torn-tail {:offset offset :bytes remaining
                             :reason :torn-record-length}}

                :else
                (let [payload-length (read-u32 buffer "record payload length")]
                  (when (> payload-length Integer/MAX_VALUE)
                    (fail! :corrupt-triple-log "Store transaction log record exceeds JVM bounds"
                           {:path path :offset offset :length payload-length}))
                  (if (< (.remaining buffer) (+ payload-length 4))
                    {:space-id space-id :records records
                     :continuation? continuation?
                     :valid-bytes valid-bytes
                     :header-bytes header-bytes :prefix-ends prefix-ends
                     :torn-tail {:offset offset :bytes (- (alength bytes) offset)
                                 :reason :torn-transaction-record}}
                    (let [payload (byte-array (int payload-length))
                          _ (.get buffer payload)
                          stored-crc (read-u32 buffer "record CRC")
                          actual-crc (.getValue
                                      (doto (java.util.zip.CRC32.)
                                        (.update payload)))]
                      (when-not (= stored-crc actual-crc)
                        (fail! :corrupt-triple-log "Store transaction log record CRC does not match"
                               {:path path :offset offset
                                :stored stored-crc :actual actual-crc}))
                      (let [record (decode-transaction-payload
                                   (if deflate?
                                     (inflate-bytes payload path offset)
                                     payload)
                                   offset)
                            end (.position buffer)]
                        (recur (conj records record) end
                               (assoc prefix-ends (:tx-seq record) end)))))))))))
      (catch Throwable error
        (if (instance? clojure.lang.ExceptionInfo error)
          (throw error)
          (fail! :corrupt-triple-log "Store transaction log header is truncated"
                 {:path path :cause (.getMessage error)})))))))

(defn read-triple-log!
  "Read and validate a Store transaction log generation without accepting any legacy shape."
  ([path] (read-triple-log! path false))
  ([path allow-continuation?]
   (let [file (.getCanonicalFile (java.io.File. (str path)))]
     (when-not (.isFile file)
       (fail! :triple-log-missing "Store transaction log source is missing"
              {:path (.getPath file)}))
     (parse-triple-log-bytes
      (java.nio.file.Files/readAllBytes (.toPath file)) (.getPath file)
      allow-continuation?))))

(defn require-triple-log-header!
  "Return the immutable SpaceId of a validated Store transaction log generation."
  [path]
  (:space-id (read-triple-log! path)))

(defn triple-log-prefix-source!
  "Bind an inclusive transaction-sequence prefix to its exact canonical bytes."
  [path upper-inclusive]
  (let [file (.getCanonicalFile (java.io.File. (str path)))
        parsed (read-triple-log! (.getPath file))
        sequence (reduce (fn [known record]
                           (let [candidate (:tx-seq record)]
                             (if (<= candidate upper-inclusive) candidate known)))
                         nil (:records parsed))
        valid-bytes (if (some? sequence)
                      (get (:prefix-ends parsed) sequence)
                      (:header-bytes parsed))
        bytes (java.nio.file.Files/readAllBytes (.toPath file))
        ^bytes prefix (java.util.Arrays/copyOfRange bytes 0 (int valid-bytes))
        digest (.digest (java.security.MessageDigest/getInstance "SHA-256") prefix)
        fingerprint (apply str (map #(format "%02x" (bit-and % 255)) digest))]
    {:space-id (:space-id parsed)
     :sequence (or sequence 0)
     :valid-bytes valid-bytes
     :fingerprint fingerprint}))

(defn- write-header!
  ([out space-id] (write-header! out space-id triple-log-flags))
  ([^java.io.OutputStream out space-id flags]
   (let [space-bytes (strict-utf8-bytes space-id "SpaceId")]
     (when (zero? (alength ^bytes space-bytes))
       (fail! :space-id-required "SpaceId must be nonempty" {}))
     (.write out triple-log-magic)
     (write-u16-le! out triple-log-version)
     (write-u16-le! out flags)
     (write-u32-le! out (alength ^bytes space-bytes))
     (.write out ^bytes space-bytes))))

(defn create-triple-log!
  "Atomically create a header-only Store transaction log generation for SPACE-ID.
   {:deflate? true} creates a generation whose records are Deflate-compressed."
  ([path space-id] (create-triple-log! path space-id {}))
  ([path space-id {:keys [deflate? continuation?]
                   :or {deflate? false continuation? false}}]
  (let [target (.getCanonicalFile (java.io.File. (str path)))
        parent (.getParentFile target)]
    (when-not (and (.isAbsolute target) parent (.isDirectory parent))
      (fail! :triple-log-target-invalid
             "Store transaction log target must be an absolute path in an existing directory"
             {:path (.getPath target)}))
    (when (.exists target)
      (fail! :triple-log-exists "Store transaction log target already exists"
             {:path (.getPath target)}))
    (let [tmp (java.nio.file.Files/createTempFile
               (.toPath parent) ".storelog-header-" ".tmp"
               (make-array java.nio.file.attribute.FileAttribute 0))]
      (try
        (with-open [file-out (java.io.FileOutputStream. (.toFile tmp))
                    out (java.io.BufferedOutputStream. file-out)]
          (write-header! out space-id
                         (bit-or (if deflate? deflate-flag triple-log-flags)
                                 (if continuation?
                                   continuation-flag triple-log-flags)))
          (.flush out)
          (.force (.getChannel file-out) true))
        (java.nio.file.Files/move
         tmp (.toPath target)
         (into-array java.nio.file.CopyOption
                     [java.nio.file.StandardCopyOption/ATOMIC_MOVE]))
        (.getPath target)
        (finally (java.nio.file.Files/deleteIfExists tmp)))))))

(defn- append-record-durable! [path record deflate?]
  (with-open [file-out (java.io.FileOutputStream. (str path) true)
              out (java.io.BufferedOutputStream. file-out)]
    (write-transaction-record! out record deflate?)
    (.flush out)
    (.force (.getChannel file-out) true)))

(defn- append-record-cohort-durable! [path records deflate?]
  (with-open [file-out (java.io.FileOutputStream. (str path) true)
              out (java.io.BufferedOutputStream. file-out)]
    (doseq [record records]
      (write-transaction-record! out record deflate?))
    (.flush out)
    (.force (.getChannel file-out) true)))

(def ^:dynamic *deferred-records* nil)

(defn- record->store-record [record]
  (term-store/transaction-record
   (:tx-seq record)
   (mapv (fn [{:keys [store-action triple]}]
           (case store-action
             :assert (term-store/assert-operation triple)
             :retract (term-store/retract-operation triple)))
         (:operations record))))

(defn- replay-records! [context records]
  (doseq [record records]
    (term-store/replay-transaction! context (record->store-record record)))
  context)

(defn- truncate-log! [path length]
  (with-open [file (java.io.RandomAccessFile. (str path) "rw")]
    (.setLength file length)
    (.force (.getChannel file) true)))

(def ^:private fork-marker-suffix ".fork")
(def ^:private fork-pending-suffix ".fork-new")
(def ^:private reseal-marker-suffix ".reseal")
(def ^:private reseal-pending-suffix ".reseal-new")

(defn- fork-marker-path [store] (str store fork-marker-suffix))
(defn- fork-pending-path [path] (str path fork-pending-suffix))
(defn- reseal-marker-path [store] (str store reseal-marker-suffix))
(defn- reseal-pending-path [path] (str path reseal-pending-suffix))

(defn- read-fork-marker [store]
  (let [file (java.io.File. (str (fork-marker-path store)))]
    (when (.isFile file)
      (branch/parse-fork-marker
       (strict-utf8-string (java.nio.file.Files/readAllBytes (.toPath file))
                           "fork marker")))))

(defn- read-reseal-marker [store]
  (let [file (java.io.File. (str (reseal-marker-path store)))]
    (when (.isFile file)
      (branch/parse-reseal-marker
       (strict-utf8-string (java.nio.file.Files/readAllBytes (.toPath file))
                           "reseal marker")))))

(defn- require-no-pending-fork! [store]
  (when (.exists (java.io.File. (str (fork-marker-path store))))
    (fail! :fork-incomplete
           "a fork of this store was interrupted and has not been completed"
           {:path (str store) :marker (fork-marker-path store)}))
  (when (.exists (java.io.File. (str (reseal-marker-path store))))
    (fail! :reseal-incomplete
           "a reseal of this store was interrupted and has not been completed"
           {:path (str store) :marker (reseal-marker-path store)})))

(defn open-database!
  "Open a Store transaction log-backed TermStore. A passive reader reports a torn trailing
   record and refuses later writes. An authority-holding caller may pass
   {:repair-torn? true}; only the last incomplete record is truncated."
  ([path] (open-database! path nil {}))
  ([path expected-space] (open-database! path expected-space {}))
  ([path expected-space {:keys [repair-torn?] :or {repair-torn? false}}]
   (let [canonical (.getPath (.getCanonicalFile (java.io.File. (str path))))
         _ (require-no-pending-fork! canonical)
         parsed (read-triple-log! canonical)
         space-id (:space-id parsed)]
     (when (and expected-space (not= expected-space space-id))
       (fail! :space-mismatch "Store transaction log belongs to a different SpaceId"
              {:expected expected-space :actual space-id :path canonical}))
     (let [context (term-store/new-term-store space-id)]
       (replay-records! context (:records parsed))
       (when (and (:torn-tail parsed) repair-torn?)
         (truncate-log! canonical (:valid-bytes parsed)))
       {:term-store context
        :space-id space-id
        :deflate? (:deflate? parsed)
        :log canonical
        :lock (Object.)
        :mutation-state (atom {:status :ready})
        :torn-tail (when-not repair-torn? (:torn-tail parsed))
        :recovered-tail (when repair-torn? (:torn-tail parsed))}))))

(defn- bytes-hex [^bytes content]
  (apply str (map #(format "%02x" (bit-and % 255)) content)))

(defn- sha256-hex [^bytes content]
  (bytes-hex
   (.digest (java.security.MessageDigest/getInstance "SHA-256") content)))

(defn- ensure-directory! [path]
  (java.nio.file.Files/createDirectories
   (.toPath (java.io.File. (str path)))
   (make-array java.nio.file.attribute.FileAttribute 0))
  (str path))

(defn- move-atomically! [source target]
  (java.nio.file.Files/move
   (.toPath (java.io.File. (str source))) (.toPath (java.io.File. (str target)))
   (into-array java.nio.file.CopyOption
               [java.nio.file.StandardCopyOption/ATOMIC_MOVE
                java.nio.file.StandardCopyOption/REPLACE_EXISTING]))
  (str target))

(defn- write-text-durable! [path text]
  (let [^bytes content (strict-utf8-bytes text "branch ref")
        temporary (str path ".tmp")]
    (with-open [file-out (java.io.FileOutputStream. (str temporary))
                out (java.io.BufferedOutputStream. file-out)]
      (.write out content)
      (.flush out)
      (.force (.getChannel file-out) true))
    (move-atomically! temporary path)))

(defn- write-bytes-durable! [path ^bytes content]
  (let [temporary (str path ".tmp")]
    (with-open [file-out (java.io.FileOutputStream. (str temporary))
                out (java.io.BufferedOutputStream. file-out)]
      (.write out content)
      (.flush out)
      (.force (.getChannel file-out) true))
    (move-atomically! temporary path)))

(defn- branch-control-path [store]
  (str store ".branch-control"))

(def ^:private branch-watch-format "store-watch/v1")

(defn- branch-watch-path [store branch-name]
  (str store ".watches/" (branch/require-branch-name! branch-name)))

(defn- valid-ref-identity? [value]
  (and (string? value)
       (some? (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- watch-head [document]
  (if-let [event (last (:events document))]
    (:current event)
    (:anchor document)))

(defn- watch-line [kind event]
  (str kind " " (:cursor event) " " (:previous event) " "
       (:current event) "\n"))

(defn- print-watch-document [document]
  (let [body (str branch-watch-format "\n"
                  "anchor " (:anchor document) "\n"
                  (apply str (map #(watch-line "event" %)
                                  (:events document)))
                  (when-let [pending (:pending document)]
                    (watch-line "pending" pending)))]
    (str body "sha256 " (sha256-hex (strict-utf8-bytes body "branch watch"))
         "\n")))

(defn- parse-watch-cursor [value]
  (when-not (some? (re-matches #"(?:0|[1-9][0-9]{0,17})" value))
    (fail! :invalid-branch-watch "branch watch cursor is not canonical"
           {:cursor value}))
  (Long/parseLong value))

(defn- parse-watch-transition [line expected-kind]
  (let [fields (vec (str/split line #" "))]
    (when-not (and (= 4 (count fields))
                   (= expected-kind (nth fields 0)))
      (fail! :invalid-branch-watch "branch watch transition is malformed"
             {:line line}))
    (let [event {:cursor (parse-watch-cursor (nth fields 1))
                 :previous (nth fields 2)
                 :current (nth fields 3)}]
      (when-not (and (valid-ref-identity? (:previous event))
                     (valid-ref-identity? (:current event))
                     (not= (:previous event) (:current event)))
        (fail! :invalid-branch-watch
               "branch watch transition identities are invalid"
               {:line line}))
      event)))

(defn- parse-watch-document [text]
  (let [lines (vec (str/split-lines text))]
    (when (< (count lines) 3)
      (fail! :invalid-branch-watch "branch watch document is incomplete" {}))
    (when-not (= branch-watch-format (first lines))
      (fail! :unsupported-branch-watch-version
             "branch watch document version is unsupported"
             {:format (first lines)}))
    (when-not (str/starts-with? (nth lines 1) "anchor ")
      (fail! :invalid-branch-watch "branch watch document has no anchor" {}))
    (let [anchor (subs (nth lines 1) 7)
          digest-line (last lines)
          content-lines (subvec lines 2 (dec (count lines)))
          body (apply str (map #(str % "\n") (butlast lines)))]
      (when-not (valid-ref-identity? anchor)
        (fail! :invalid-branch-watch "branch watch anchor is invalid"
               {:anchor anchor}))
      (when-not (= digest-line
                   (str "sha256 "
                        (sha256-hex
                         (strict-utf8-bytes body "branch watch"))))
        (fail! :invalid-branch-watch "branch watch digest does not match" {}))
      (loop [remaining content-lines
             previous anchor
             cursor 0
             events []]
        (if (empty? remaining)
          {:anchor anchor :events events :pending nil}
          (let [line (first remaining)
                pending? (str/starts-with? line "pending ")
                event (parse-watch-transition
                       line (if pending? "pending" "event"))]
            (when-not (and (= (:cursor event) (inc cursor))
                           (= (:previous event) previous))
              (fail! :invalid-branch-watch
                     "branch watch transitions are not contiguous"
                     {:cursor (:cursor event) :previous (:previous event)}))
            (if pending?
              (if (next remaining)
                (fail! :invalid-branch-watch
                       "branch watch pending transition is not last" {})
                {:anchor anchor :events events :pending event})
              (recur (next remaining) (:current event) (:cursor event)
                     (conj events event)))))))))

(defn- read-watch-document [store branch-name]
  (let [path (branch-watch-path store branch-name)
        file (java.io.File. path)]
    (when (.isFile file)
      (parse-watch-document
       (strict-utf8-string (java.nio.file.Files/readAllBytes (.toPath file))
                           "branch watch")))))

(defn- write-watch-document! [store branch-name document]
  (ensure-directory! (str store ".watches"))
  (write-text-durable! (branch-watch-path store branch-name)
                       (print-watch-document document))
  document)

(defn- reconcile-watch! [store branch-name current-identity]
  (let [stored (read-watch-document store branch-name)
        document (or stored {:anchor current-identity :events [] :pending nil})
        pending (:pending document)
        resolved
        (cond
          (nil? pending) document
          (= current-identity (:current pending))
          (-> document
              (update :events conj pending)
              (assoc :pending nil))
          (= current-identity (:previous pending))
          (assoc document :pending nil)
          :else
          (fail! :invalid-branch-watch
                 "branch ref matches neither side of its pending watch transition"
                 {:branch branch-name :current current-identity
                  :pending pending}))
        head (watch-head resolved)
        reconciled
        (if (= head current-identity)
          resolved
          (update resolved :events conj
                  {:cursor (inc (long (or (:cursor (last (:events resolved))) 0)))
                   :previous head
                   :current current-identity}))]
    (if (= stored reconciled)
      reconciled
      (write-watch-document! store branch-name reconciled))))

(defn- prepare-watch-transition! [store branch-name current candidate]
  (let [document (reconcile-watch! store branch-name current)]
    (if (= current candidate)
      document
      (write-watch-document!
       store branch-name
       (assoc document :pending
              {:cursor (inc (long (or (:cursor (last (:events document))) 0)))
               :previous current
               :current candidate})))))

(defn- acquire-branch-control! [store]
  (let [deadline (+ (System/nanoTime) 2000000000)]
    (loop []
      (if-let [held (writer-authority/try-acquire! (branch-control-path store))]
        held
        (if (>= (System/nanoTime) deadline)
          (fail! :writer-authority-held
                 "another branch operation holds this store"
                 {:path store
                  :lock (writer-authority/authority-path
                         (branch-control-path store))})
          (do (Thread/sleep 1) (recur)))))))

(defn read-branch-ref
  "Read a branch ref, or nil when the branch has no sealed chain on disk."
  [store-path branch]
  (let [file (java.io.File. (str (branch/ref-path! (str store-path) branch)))]
    (when (.isFile file)
      (branch/parse-ref
       (strict-utf8-string (java.nio.file.Files/readAllBytes (.toPath file))
                           "branch ref")))))

(defn branch-ref-identity
  "Name the exact canonical bytes of a branch's current ref document."
  [store-path branch-name]
  (when-let [document (read-branch-ref store-path branch-name)]
    (branch/ref-identity document)))

(defn branch-transitions-since!
  "Read durable ref transitions after CURSOR. A missing journal is anchored at
   the current ref; a prepared transition becomes visible only after its ref is
   durable. The returned cursor may be supplied unchanged to resume without a
   gap or duplicate."
  [store-path branch-name cursor]
  (when-not (and (integer? cursor) (<= 0 cursor Long/MAX_VALUE))
    (fail! :invalid-watch-cursor "branch watch cursor must be non-negative"
           {:cursor cursor}))
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
        selected (branch/require-branch-name! branch-name)
        held (acquire-branch-control! store)]
    (try
      (require-no-pending-fork! store)
      (let [current (branch-ref-identity store selected)]
        (when (nil? current)
          (fail! :branch-missing "branch has no ref"
                 {:branch selected :path (branch/ref-path! store selected)}))
        (let [document (reconcile-watch! store selected current)
              head-cursor (long (or (:cursor (last (:events document))) 0))]
          (when (> cursor head-cursor)
            (fail! :watch-cursor-ahead
                   "branch watch cursor is ahead of durable history"
                   {:cursor cursor :head head-cursor}))
          {:cursor head-cursor
           :transitions (vec (filter #(> (:cursor %) cursor)
                                     (:events document)))}))
      (finally
        (writer-authority/release! held)))))

(defn watch-branch!
  "Wait up to TIMEOUT-MS for at least one durable transition after CURSOR."
  [store-path branch-name cursor timeout-ms]
  (when-not (and (integer? timeout-ms) (<= 0 timeout-ms 60000))
    (fail! :invalid-watch-timeout
           "branch watch timeout must be between zero and 60000 milliseconds"
           {:timeout-ms timeout-ms}))
  (let [deadline (+ (System/nanoTime) (* (long timeout-ms) 1000000))]
    (loop []
      (let [result (branch-transitions-since! store-path branch-name cursor)]
        (if (or (seq (:transitions result))
                (>= (System/nanoTime) deadline))
          result
          (do (Thread/sleep 5) (recur)))))))

(defn- chain-member [parsed byte-count]
  (branch/->ChainMember
   (long (or (:tx-seq (first (:records parsed))) 0))
   (long (or (:tx-seq (last (:records parsed))) 0))
   (long byte-count)
   (boolean (:continuation? parsed))
   (:space-id parsed)
   (some? (:torn-tail parsed))))

(defn branch-chain-fault
  "Validate hosted branch metadata through the canonical Native Core rules."
  [document members tail]
  (if (not= (count (branch/refdocument-segments document)) (count members))
    "Store transaction log branch ref does not name the segments that were read"
    (loop [index 0 expected-next 1]
      (if (>= index (count members))
        (chain-rules/tail-member-fault
         (count members)
         (branch/refdocument-space-id document)
         (branch/chainmember-space-id tail)
         (branch/chainmember-start-sequence tail)
         (branch/chainmember-continuation tail)
         expected-next)
        (let [segment (nth (branch/refdocument-segments document) index)
              member (nth members index)
              fault
              (chain-rules/sealed-member-fault
               index
               (branch/refdocument-space-id document)
               (branch/chainmember-space-id member)
               (branch/segmentrecord-start-sequence segment)
               (branch/chainmember-start-sequence member)
               (branch/segmentrecord-end-sequence segment)
               (branch/chainmember-end-sequence member)
               (branch/segmentrecord-byte-count segment)
               (branch/chainmember-byte-count member)
               (branch/chainmember-continuation member)
               (branch/chainmember-torn member)
               expected-next)]
          (if fault
            fault
            (recur (inc index)
                   (chain-rules/next-expected
                    (branch/chainmember-end-sequence member)
                    expected-next))))))))

(defn- read-chain-source! [path allow-continuation?]
  (let [file (.getCanonicalFile (java.io.File. (str path)))]
    (when-not (.isFile file)
      (fail! :triple-log-missing "Store transaction log source is missing"
             {:path (.getPath file)}))
    (let [bytes (java.nio.file.Files/readAllBytes (.toPath file))
          parsed (parse-triple-log-bytes
                  bytes (.getPath file) allow-continuation?)]
      {:path (.getPath file)
       :bytes bytes
       :parsed parsed
       :member (chain-member parsed (alength ^bytes bytes))})))

(defn- read-chain-member! [path]
  (let [source (read-chain-source! path true)]
    [(:parsed source) (:member source)]))

(defn- require-segment-identity! [segment source]
  (let [expected (branch/segmentrecord-sha256 segment)
        actual (sha256-hex (:bytes source))]
    (when-not (= expected actual)
      (fail! :segment-digest-mismatch
             "sealed Store transaction log segment does not match its content address"
             {:path (:path source) :expected expected :actual actual}))))

(defn- require-uncompressed-branch-source! [source]
  (when (:deflate? (:parsed source))
    (fail! :unsupported-branch-chain-encoding
           "branch routing does not support Deflate-compressed Store transaction log members"
           {:path (:path source)}))
  source)

(defn- require-ref-chain! [store selected document]
  (let [segments (branch/refdocument-segments document)
        sealed
        (mapv (fn [segment]
                [segment
                 (read-chain-source!
                  (branch/segment-path
                   store (branch/segmentrecord-sha256 segment))
                  true)])
              segments)
        tail (read-chain-source!
              (branch/branch-tail-path! store selected) true)
        fault (branch-chain-fault
               document (mapv (comp :member second) sealed) (:member tail))]
    (doseq [[_ source] sealed]
      (require-uncompressed-branch-source! source))
    (require-uncompressed-branch-source! tail)
    (when fault
      (fail! :invalid-branch-chain fault
             {:branch selected :path (:path tail)
              :ref (branch/ref-path! store selected)}))
    (doseq [[segment source] sealed]
      (require-segment-identity! segment source))
    {:sealed sealed :tail tail}))

(defn- history-sha256 [sources]
  (let [digest (java.security.MessageDigest/getInstance "SHA-256")]
    (doseq [source sources]
      (let [parsed (:parsed source)
            start (int (:header-bytes parsed))
            end (int (:valid-bytes parsed))]
        (.update digest ^bytes (:bytes source) start (- end start))))
    (bytes-hex (.digest digest))))

(defn compare-and-set-branch-ref!
  "Replace one branch ref only when EXPECTED-IDENTITY still names its exact
   canonical bytes. CANDIDATE is verified against every content-addressed
   segment and the branch's current tail before the durable ref replacement."
  [store-path branch-name expected-identity candidate]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
        selected (branch/require-branch-name! branch-name)
        held (acquire-branch-control! store)]
    (try
      (require-no-pending-fork! store)
      (let [current (read-branch-ref store selected)]
        (when (nil? current)
          (fail! :branch-missing "branch has no ref"
                 {:branch selected :path (branch/ref-path! store selected)}))
        (let [current-identity (branch/ref-identity current)]
          (if (not= expected-identity current-identity)
            {:swapped? false
             :expected expected-identity
             :current current-identity}
            (do
              (when (not= (branch/refdocument-space-id current)
                          (branch/refdocument-space-id candidate))
                (fail! :space-mismatch
                       "candidate branch ref belongs to a different SpaceId"
                       {:expected (branch/refdocument-space-id current)
                        :actual (branch/refdocument-space-id candidate)
                        :branch selected}))
              (require-ref-chain! store selected candidate)
              (let [candidate-identity (branch/ref-identity candidate)]
                (prepare-watch-transition! store selected current-identity
                                           candidate-identity)
                (write-text-durable! (branch/ref-path! store selected)
                                     (branch/print-ref candidate))
                (reconcile-watch! store selected candidate-identity)
                {:swapped? true
                 :expected expected-identity
                 :previous current-identity
                 :current candidate-identity})))))
      (finally
        (writer-authority/release! held)))))

(defn branch-revision!
  "Name one exact committed point on a branch from durable history. The branch
   name is routing, not identity: equal sealed chains and tail prefixes have the
   same revision even when reached through different refs."
  ([store-path]
   (branch-revision! store-path branch/default-branch))
  ([store-path branch-name]
   (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
         selected (branch/require-branch-name! branch-name)
         _ (require-no-pending-fork! store)
         document (read-branch-ref store selected)]
     (cond
       (and (nil? document) (= selected branch/default-branch))
       (let [tail (read-chain-source! store false)
             parsed (:parsed tail)
             sequence (long (or (:tx-seq (last (:records parsed))) 0))]
         (require-uncompressed-branch-source! tail)
         (branch/branch-revision!
          (:space-id parsed) (history-sha256 [tail]) sequence))

       (nil? document)
       (fail! :branch-missing "branch has no ref"
              {:branch selected :path (branch/ref-path! store selected)})

       :else
       (let [segments (branch/refdocument-segments document)
             sealed
             (mapv (fn [segment]
                     [segment
                      (read-chain-source!
                       (branch/segment-path
                        store (branch/segmentrecord-sha256 segment))
                       true)])
                   segments)
             tail (read-chain-source!
                   (branch/branch-tail-path! store selected) true)
             parsed (:parsed tail)
             fault (branch-chain-fault
                    document (mapv (comp :member second) sealed)
                    (:member tail))]
         (doseq [[_ source] sealed]
           (require-uncompressed-branch-source! source))
         (require-uncompressed-branch-source! tail)
         (when fault
           (fail! :invalid-branch-chain fault
                  {:branch selected :path (:path tail)
                   :ref (branch/ref-path! store selected)}))
         (doseq [[segment source] sealed]
           (require-segment-identity! segment source))
         (let [sequence
               (long (or (:tx-seq (last (:records parsed)))
                         (branch/chain-end-sequence document)))]
           (branch/branch-revision!
            (branch/refdocument-space-id document)
            (history-sha256 (conj (mapv second sealed) tail))
            sequence)))))))

(defn open-branch!
  "Open one branch of a store: fold its sealed segment chain in ref order, then
   its tail. A store with no ref for the default branch boots exactly as an
   unforked Store transaction log does."
  ([store-path branch] (open-branch! store-path branch nil {}))
  ([store-path branch expected-space]
   (open-branch! store-path branch expected-space {}))
  ([store-path branch expected-space
    {:keys [repair-torn?] :or {repair-torn? false}}]
   (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
         _ (require-no-pending-fork! store)
         document (read-branch-ref store branch)]
     (cond
       (and (nil? document) (= branch branch/default-branch))
       (do
         ;; Reject the branch-only encoding boundary before open-database! can
         ;; honor repair-torn? and mutate the file.
         (require-uncompressed-branch-source!
          (read-chain-source! store false))
         (open-database! store expected-space
                         {:repair-torn? repair-torn?}))

       (nil? document)
       (fail! :branch-missing "branch has no ref"
              {:branch branch :path (branch/ref-path! store branch)})

       :else
       (let [tail-path (branch/branch-tail-path! store branch)
             space-id (branch/refdocument-space-id document)
             {:keys [sealed tail]} (require-ref-chain! store branch document)
             tail-parsed (:parsed tail)]
         (when (and expected-space (not= expected-space space-id))
           (fail! :space-mismatch "Store transaction log belongs to a different SpaceId"
                  {:expected expected-space :actual space-id :branch branch}))
         (let [context (term-store/new-term-store space-id)]
           (doseq [[_ source] sealed]
             (replay-records! context (:records (:parsed source))))
           (replay-records! context (:records tail-parsed))
           (when (and (:torn-tail tail-parsed) repair-torn?)
             (truncate-log! tail-path (:valid-bytes tail-parsed)))
           {:term-store context
            :space-id space-id
            :deflate? (:deflate? tail-parsed)
            :log tail-path
            :branch branch
            :segments (mapv branch/segmentrecord-sha256
                            (branch/refdocument-segments document))
            :lock (Object.)
            :mutation-state (atom {:status :ready})
            :torn-tail (when-not repair-torn? (:torn-tail tail-parsed))
            :recovered-tail (when repair-torn? (:torn-tail tail-parsed))}))))))

(defn- delete-file! [path]
  (java.nio.file.Files/deleteIfExists (.toPath (java.io.File. (str path)))))

(defn- install-pending! [pending target]
  (when (.exists (java.io.File. (str pending)))
    (move-atomically! pending target)))

(defn- complete-reseal! [store marker]
  (let [selected (branch/resealmarker-branch marker)
        tail-path (branch/branch-tail-path! store selected)
        ref-path (branch/ref-path! store selected)
        pending-tail (reseal-pending-path tail-path)
        pending-ref (reseal-pending-path ref-path)
        candidate-tail-path
        (if (.isFile (java.io.File. pending-tail)) pending-tail tail-path)
        candidate-ref-path
        (if (.isFile (java.io.File. pending-ref)) pending-ref ref-path)
        document
        (branch/parse-ref
         (strict-utf8-string
          (java.nio.file.Files/readAllBytes
           (.toPath (java.io.File. candidate-ref-path)))
          "reseal candidate ref"))
        expected-segment (branch/resealmarker-segment marker)
          expected-ref (branch/resealmarker-ref-identity marker)
        segments (branch/refdocument-segments document)]
    (when-not (and (= expected-ref (branch/ref-identity document))
                     (= 1 (count segments))
                     (= expected-segment
                        (branch/segmentrecord-sha256 (first segments))))
      (fail! :invalid-reseal-recovery
             "reseal recovery files do not match the durable marker"
             {:branch selected :segment expected-segment
              :ref-identity expected-ref}))
    ;; Validate every candidate byte before the first recovery rename. A stale
    ;; or corrupt marker therefore cannot replace either live routing file.
    (let [segment (first segments)
          segment-source
          (read-chain-source!
           (branch/segment-path store expected-segment) true)
          tail-source (read-chain-source! candidate-tail-path true)
          fault (branch-chain-fault
                 document [(:member segment-source)] (:member tail-source))]
      (require-segment-identity! segment segment-source)
      (when fault
        (fail! :invalid-reseal-recovery fault
               {:branch selected :segment expected-segment
                :ref-identity expected-ref})))
    (install-pending! pending-tail tail-path)
    (install-pending! pending-ref ref-path)
    (require-ref-chain! store selected document)
    (reconcile-watch! store selected expected-ref)
    (delete-file! (branch/snapshot-path tail-path))
    (delete-file! (reseal-marker-path store))
    {:branch selected
     :segments 1
     :segment expected-segment
     :ref-identity expected-ref
     :recovered? true}))

;; Every file a fork installs is prepared before its marker is written, so a
;; fork interrupted at any point finishes by replaying the renames below in
;; this order; each one is skipped when its prepared file is already consumed.
(defn- complete-fork! [store marker]
  (let [parent (branch/forkmarker-parent marker)
        child (branch/forkmarker-child marker)
        parent-tail (branch/branch-tail-path! store parent)
        child-tail (branch/branch-tail-path! store child)
        parent-ref (branch/ref-path! store parent)
        child-ref (branch/ref-path! store child)
        sealed (branch/segment-path store (branch/forkmarker-segment marker))]
    (when-not (.exists (java.io.File. (str sealed)))
      (move-atomically! parent-tail sealed))
    (install-pending! (fork-pending-path parent-tail) parent-tail)
    (install-pending! (fork-pending-path parent-ref) parent-ref)
    (install-pending! (fork-pending-path child-ref) child-ref)
    (install-pending! (fork-pending-path child-tail) child-tail)
    ;; The parent's image is derived state whose watermark no longer names the
    ;; tail it was built beside.
    (delete-file! (branch/snapshot-path parent-tail))
    (delete-file! (fork-marker-path store))
    nil))

(defn- acquire-fork-authority! [paths]
  (reduce
   (fn [held path]
     (if-let [handle (writer-authority/try-acquire! path)]
       (conj held handle)
       (do
         (doseq [previous held] (writer-authority/release! previous))
         (fail! :writer-authority-held
                "a writer holds this store; fork runs offline only"
                {:path path :lock (writer-authority/authority-path path)}))))
   [] paths))

(def ^:private retention-root-kinds
  {:pin "pins" :checkpoint "checkpoints" :session "sessions"})

(defn- require-retention-root-kind! [kind]
  (if-let [directory (get retention-root-kinds kind)]
    directory
    (fail! :invalid-retention-root-kind
           "retention root kind must be :pin, :checkpoint, or :session"
           {:kind kind})))

(defn- require-retention-root-name! [root-name]
  (if (and (string? root-name) (branch/valid-branch-name? root-name))
    root-name
    (fail! :invalid-retention-root-name
           "retention root name is not a usable durable file name"
           {:name root-name})))

(defn- retention-roots-directory [store]
  (str store ".roots"))

(defn- retention-kind-directory [store kind]
  (str (retention-roots-directory store) "/"
       (require-retention-root-kind! kind)))

(defn- retention-root-path [store kind root-name]
  (str (retention-kind-directory store kind) "/"
       (require-retention-root-name! root-name)))

(defn- directory-entries! [path label]
  (let [directory (java.io.File. (str path))]
    (cond
      (not (.exists directory)) []
      (not (.isDirectory directory))
      (fail! :invalid-retention-layout
             (str label " is not a directory")
             {:path (.getPath directory)})
      :else
      (let [entries (.listFiles directory)]
        (when (nil? entries)
          (fail! :retention-io-failure
                 (str label " could not be enumerated")
                 {:path (.getPath directory)}))
        (vec entries)))))

(defn- regular-document-files! [path label]
  (let [entries (directory-entries! path label)]
    (doseq [^java.io.File entry entries]
      (when-not (.isFile entry)
        (fail! :invalid-retention-layout
               (str label " contains a non-document entry")
               {:path (.getPath entry)})))
    (vec (sort-by #(.getName ^java.io.File %) entries))))

(defn- read-ref-document-file! [^java.io.File file label]
  (branch/parse-ref
   (strict-utf8-string (java.nio.file.Files/readAllBytes (.toPath file))
                       label)))

(defn- require-sealed-document! [store store-space source document]
  (when-not (= store-space (branch/refdocument-space-id document))
    (fail! :space-mismatch
           "retention root belongs to a different SpaceId"
           {:path source :expected store-space
            :actual (branch/refdocument-space-id document)}))
  (loop [index 0 expected-next 1
         segments (branch/refdocument-segments document)]
    (when-let [segment (first segments)]
      (let [segment-source
            (read-chain-source!
             (branch/segment-path
              store (branch/segmentrecord-sha256 segment)) true)
            member (:member segment-source)
            fault
            (chain-rules/sealed-member-fault
             index store-space (branch/chainmember-space-id member)
             (branch/segmentrecord-start-sequence segment)
             (branch/chainmember-start-sequence member)
             (branch/segmentrecord-end-sequence segment)
             (branch/chainmember-end-sequence member)
             (branch/segmentrecord-byte-count segment)
             (branch/chainmember-byte-count member)
             (branch/chainmember-continuation member)
             (branch/chainmember-torn member)
             expected-next)]
        (when fault
          (fail! :invalid-retention-root fault
                 {:path source
                  :segment (branch/segmentrecord-sha256 segment)}))
        (require-segment-identity! segment segment-source)
        (recur (inc index)
               (chain-rules/next-expected
                (branch/chainmember-end-sequence member) expected-next)
               (next segments)))))
  document)

(defn- store-space-id! [store]
  (:space-id (:parsed (read-chain-source! store true))))

(defn- with-retention-authority [store operation]
  (let [held (acquire-fork-authority! [store])]
    (try
      (let [held-control (acquire-branch-control! store)]
        (try
          (operation)
          (finally
            (writer-authority/release! held-control))))
      (finally
        (doseq [handle held] (writer-authority/release! handle))))))

(defn retain-branch-root!
  "Durably retain every sealed segment named by DOCUMENT as a pin, checkpoint,
   or active session root. The root stores canonical store-ref/v1 facts rather
   than a pointer to mutable branch routing."
  [store-path kind root-name document]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
        selected-kind (keyword kind)
        selected-name (require-retention-root-name! root-name)]
    (with-retention-authority
      store
      (fn []
        (require-no-pending-fork! store)
        (let [root-path (retention-root-path
                         store selected-kind selected-name)
              store-space (store-space-id! store)
              canonical
              (branch/parse-ref (branch/print-ref document))
              verified
              (require-sealed-document!
               store store-space root-path canonical)]
          (ensure-directory! (retention-kind-directory store selected-kind))
          (write-text-durable! root-path (branch/print-ref verified))
          {:kind selected-kind
           :name selected-name
           :ref-identity (branch/ref-identity verified)
           :segments
           (mapv branch/segmentrecord-sha256
                 (branch/refdocument-segments verified))})))))

(defn release-branch-root!
  "Release one named durable pin, checkpoint, or active session root. Segments
   become reclaimable only after a later reachability collection proves that no
   remaining root names them."
  [store-path kind root-name]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
        selected-kind (keyword kind)
        selected-name (require-retention-root-name! root-name)]
    (with-retention-authority
      store
      (fn []
        (require-no-pending-fork! store)
        {:kind selected-kind
         :name selected-name
         :released?
         (boolean
          (delete-file!
           (retention-root-path store selected-kind selected-name)))}))))

(defn- reachability-documents! [store]
  (let [heads
        (mapv (fn [^java.io.File file]
                (branch/require-branch-name! (.getName file))
                [(.getPath file)
                 (read-ref-document-file! file "branch head")])
              (regular-document-files!
               (branch/refs-directory store) "branch refs directory"))
        roots-directory (retention-roots-directory store)
        root-entries (directory-entries!
                      roots-directory "retention roots directory")
        known-directories (set (vals retention-root-kinds))]
    (doseq [^java.io.File entry root-entries]
      (when-not (and (.isDirectory entry)
                     (contains? known-directories (.getName entry)))
        (fail! :invalid-retention-layout
               "retention roots directory contains an unknown entry"
               {:path (.getPath entry)})))
    (into
     heads
     (mapcat
      (fn [[kind directory]]
        (mapv (fn [^java.io.File file]
                (require-retention-root-name! (.getName file))
                [(.getPath file)
                 (read-ref-document-file!
                  file (str (name kind) " retention root"))])
              (regular-document-files!
               (str roots-directory "/" directory)
               (str (name kind) " retention roots directory"))))
      (sort-by (comp str key) retention-root-kinds)))))

(defn collect-unreachable-segments!
  "Delete content-addressed segment objects unreachable from every current
   branch head, durable pin, checkpoint, and active session root. Every root
   document and every segment it names is parsed and verified before the first
   deletion. Files outside the 64-hex segment namespace are never collected."
  [store-path]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))]
    (with-retention-authority
      store
      (fn []
        (require-no-pending-fork! store)
        (let [store-space (store-space-id! store)
              documents (reachability-documents! store)
              verified
              (mapv (fn [[source document]]
                      (require-sealed-document!
                       store store-space source document))
                    documents)
              reachable
              (->> verified
                   (mapcat branch/refdocument-segments)
                   (map branch/segmentrecord-sha256)
                   set)
              segment-files
              (->> (directory-entries!
                    (branch/segments-directory store) "segments directory")
                   (filter #(.isFile ^java.io.File %))
                   (filter #(branch/valid-segment-name?
                             (.getName ^java.io.File %)))
                   (sort-by #(.getName ^java.io.File %))
                   vec)
              collected
              (->> segment-files
                   (remove #(contains? reachable (.getName ^java.io.File %)))
                   (mapv #(.getName ^java.io.File %)))]
          (doseq [segment collected]
            (delete-file! (branch/segment-path store segment)))
          {:reachable (vec (sort reachable))
           :collected collected
           :retained (count reachable)})))))

(defn- combined-history-bytes [sources]
  (let [first-source (first sources)
        first-parsed (:parsed first-source)
        deflate? (:deflate? first-parsed)
        out (java.io.ByteArrayOutputStream.)]
    (when (some #(not= deflate? (:deflate? (:parsed %))) sources)
      (fail! :incompatible-chain-encoding
             "reseal requires one record encoding across the branch chain" {}))
    (.write out ^bytes (:bytes first-source) 0
            (int (:header-bytes first-parsed)))
    (doseq [source sources]
      (let [parsed (:parsed source)
            start (int (:header-bytes parsed))
            end (int (:valid-bytes parsed))]
        (.write out ^bytes (:bytes source) start (- end start))))
    (.toByteArray out)))

(defn- reseal-branch-under-authority! [store selected]
  (let [held-control (acquire-branch-control! store)]
    (try
      (if-let [pending (read-reseal-marker store)]
        (if (= selected (branch/resealmarker-branch pending))
          (complete-reseal! store pending)
          (fail! :reseal-incomplete
                 "another branch has an interrupted reseal"
                 {:branch selected
                  :pending-branch (branch/resealmarker-branch pending)
                  :marker (reseal-marker-path store)}))
        (do
          (require-no-pending-fork! store)
          (let [document (read-branch-ref store selected)]
        (when (nil? document)
          (fail! :branch-missing "reseal requires a branch ref"
                 {:branch selected :path (branch/ref-path! store selected)}))
        (let [{:keys [sealed tail]}
              (require-ref-chain! store selected document)
              sources (conj (mapv second sealed) tail)
              tail-parsed (:parsed tail)]
          (when (:torn-tail tail-parsed)
            (fail! :torn-tail-repair-required
                   "reseal requires a branch tail with no torn trailing record"
                   {:branch selected :path (:path tail)}))
          (let [^bytes content (combined-history-bytes sources)
                parsed (parse-triple-log-bytes content "resealed segment")
                records (:records parsed)
                record (branch/->SegmentRecord
                        (sha256-hex content)
                        (long (or (:tx-seq (first records)) 0))
                        (long (or (:tx-seq (last records)) 0))
                        (long (alength content)))
                candidate (branch/->RefDocument
                           (branch/refdocument-space-id document) [record])
                current-identity (branch/ref-identity document)
                candidate-identity (branch/ref-identity candidate)
                marker (branch/->ResealMarker
                        selected (branch/segmentrecord-sha256 record)
                        candidate-identity)
                tail-path (branch/branch-tail-path! store selected)
                ref-path (branch/ref-path! store selected)
                pending-tail (reseal-pending-path tail-path)
                pending-ref (reseal-pending-path ref-path)
                segment-path
                (branch/segment-path store
                                     (branch/segmentrecord-sha256 record))]
            (ensure-directory! (branch/segments-directory store))
            (doseq [path [pending-tail pending-ref]] (delete-file! path))
            (write-bytes-durable! segment-path content)
            (create-triple-log! pending-tail
                                (branch/refdocument-space-id document)
                                {:deflate? (:deflate? parsed)
                                 :continuation? true})
            (write-text-durable! pending-ref (branch/print-ref candidate))
            (prepare-watch-transition! store selected current-identity
                                       candidate-identity)
            (write-text-durable!
             (reseal-marker-path store)
             (branch/print-reseal-marker marker))
            (assoc (complete-reseal! store marker)
                   :previous-segments
                   (count (branch/refdocument-segments document))
                   :sequence (long (or (:tx-seq (last records)) 0))
                   :recovered? false))))))
      (finally
        (writer-authority/release! held-control)))))

(defn reseal-branch!
  "Compact one branch's complete committed history into one content-addressed
   base segment and a fresh continuation tail. Runs offline under store and
   tail writer authority; the v2 branch revision is unchanged."
  ([store-path]
   (reseal-branch! store-path branch/default-branch))
  ([store-path branch-name]
   (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
         selected (branch/require-branch-name! branch-name)
         tail (branch/branch-tail-path! store selected)
         held (acquire-fork-authority! (distinct [store tail]))]
     (try
       (reseal-branch-under-authority! store selected)
       (finally
         (doseq [handle held] (writer-authority/release! handle)))))))

(defn fork-store!
  "Seal the parent branch's tail into the shared segment chain and give parent
   and child fresh continuation tails that both begin at the next sequence.
   Offline: fork holds writer authority over the store and both tails for its
   whole run, and refuses rather than rename a log a writer still holds."
  ([store-path child-branch]
   (fork-store! store-path branch/default-branch child-branch))
  ([store-path parent-branch child-branch]
   (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
         parent (branch/require-branch-name! parent-branch)
         child (branch/require-branch-name! child-branch)
         parent-tail (branch/branch-tail-path! store parent)
         child-tail (branch/branch-tail-path! store child)]
     (when (= parent child)
       (fail! :invalid-branch-name "fork requires two different branch names"
              {:branch parent}))
     (let [held (acquire-fork-authority!
                 (distinct [store parent-tail child-tail]))]
       (try
         (when-let [pending (read-reseal-marker store)]
           (if (= parent (branch/resealmarker-branch pending))
             (let [held-control (acquire-branch-control! store)]
               (try
                 (complete-reseal! store pending)
                 (finally
                   (writer-authority/release! held-control))))
             (fail! :reseal-incomplete
                    "another branch has an interrupted reseal"
                    {:branch parent
                     :pending-branch (branch/resealmarker-branch pending)
                     :marker (reseal-marker-path store)})))
         (when-let [pending (read-fork-marker store)]
           (complete-fork! store pending))
         (doseq [path [child-tail (branch/ref-path! store child)]]
           (when (.exists (java.io.File. (str path)))
             (fail! :branch-exists "fork child branch already exists"
                    {:branch child :path path})))
         (let [known (read-branch-ref store parent)
               _ (when (and known
                            (>= (count (branch/refdocument-segments known))
                                branch/reseal-chain-length))
                   (reseal-branch-under-authority! store parent))
               document (read-branch-ref store parent)]
           (when (and (nil? document) (not= parent branch/default-branch))
             (fail! :branch-missing "branch has no ref"
                    {:branch parent :path (branch/ref-path! store parent)}))
           (let [parsed (read-triple-log! parent-tail true)
                 space-id (:space-id parsed)
                 records (:records parsed)
                 base (or document (branch/empty-ref space-id))
                 chained? (pos? (count (branch/refdocument-segments base)))]
             (when (:deflate? parsed)
               (fail! :unsupported-branch-chain-encoding
                      "branch routing does not support Deflate-compressed Store transaction log members"
                      {:path parent-tail :branch parent}))
             (when (:torn-tail parsed)
               (fail! :torn-tail-repair-required
                      "fork requires a parent tail with no torn trailing record"
                      {:branch parent :path parent-tail}))
             (when (not= space-id (branch/refdocument-space-id base))
               (fail! :space-mismatch "Store transaction log belongs to a different SpaceId"
                      {:expected (branch/refdocument-space-id base)
                       :actual space-id :branch parent}))
             (when (not= chained? (boolean (:continuation? parsed)))
               (fail! :invalid-branch-chain
                      (if chained?
                        "Store transaction log branch tail must carry the continuation flag"
                        "Store transaction log base chain segment must not carry the continuation flag")
                      {:branch parent :path parent-tail}))
             (let [^bytes content (java.nio.file.Files/readAllBytes
                                   (.toPath (java.io.File. (str parent-tail))))
                   record (branch/->SegmentRecord
                           (sha256-hex content)
                           (long (or (:tx-seq (first records)) 0))
                           (long (or (:tx-seq (last records)) 0))
                           (long (alength content)))
                   ;; The tail's own last record, else the chain's recorded end:
                   ;; a fork reads no sealed segment to learn where it forked.
                   plan (branch/fork-plan
                         base record
                         (long (or (:tx-seq (last records))
                                   (branch/chain-end-sequence base))))
                   chain (branch/forkplan-document plan)
                   text (branch/print-ref chain)
                   marker (branch/->ForkMarker
                           parent child (branch/segmentrecord-sha256 record))
                   parent-ref (branch/ref-path! store parent)
                   child-ref (branch/ref-path! store child)]
               (ensure-directory! (branch/segments-directory store))
               (ensure-directory! (branch/refs-directory store))
               (when (not= child-tail store)
                 (ensure-directory! (branch/branches-directory store)))
               (doseq [path [parent-tail child-tail parent-ref child-ref]]
                 (delete-file! (fork-pending-path path)))
               (doseq [tail [parent-tail child-tail]]
                 (create-triple-log! (fork-pending-path tail) space-id
                                     {:deflate? (:deflate? parsed)
                                      :continuation? true}))
               (doseq [ref [parent-ref child-ref]]
                 (write-text-durable! (fork-pending-path ref) text))
               (write-text-durable! (fork-marker-path store)
                                    (branch/print-fork-marker marker))
               (complete-fork! store marker)
               {:space-id space-id
                :fork-sequence (branch/forkplan-fork-sequence plan)
                :segment (branch/segmentrecord-sha256 record)
                :chain (mapv branch/segmentrecord-sha256
                             (branch/refdocument-segments chain))
                :parent {:branch parent :tail parent-tail :ref parent-ref}
                :child {:branch child :tail child-tail :ref child-ref}})))
         (finally
           (doseq [handle held] (writer-authority/release! handle))))))))

(defn new-database
  "Create an in-memory authoritative database for one immutable SpaceId."
  [space-id]
  {:term-store (term-store/new-term-store space-id)
   :space-id space-id :log nil :lock (Object.)
   :mutation-state (atom {:status :ready})
   :torn-tail nil :recovered-tail nil})

(defn database-recovery-state [db]
  @(:mutation-state db))

(defn mutation-ready? [db]
  (= :ready (:status (database-recovery-state db))))

(defn require-mutation-ready! [db]
  (let [{:keys [status] :as state} (database-recovery-state db)]
    (case status
      :ready true
      :recovery-required
      (fail! :recovery-required
             "database is fenced after a durability-ambiguous commit"
             {:recovery state})
      :corrupt
      (fail! :database-corrupt
             "database is permanently fenced because durable history is corrupt"
             {:recovery state})
      (fail! :database-state-invalid "database mutation state is invalid"
             {:recovery state}))))

(defn- require-readable! [db]
  (let [{:keys [status reconciled?] :as state}
        (database-recovery-state db)]
    (case status
      :ready true
      :recovery-required
      (if reconciled?
        true
        (fail! :recovery-required
               "durable history reconciliation has not completed"
               {:recovery state}))
      :corrupt
      (fail! :database-corrupt
             "durable history could not be reconciled"
             {:recovery state})
      (fail! :database-state-invalid "database mutation state is invalid"
             {:recovery state}))))

(defn database-store [db]
  (require-readable! db)
  (:term-store db))

(defn database-space [db] (:space-id db))

(defn store-view
  "Read-only database over an immutable TermStore root: every read accessor
   below works against the pinned root instead of the live store."
  [db root]
  (assoc db :term-store (atom root)))

(defn current-transaction [db]
  (t/transaction-coordinate
   (database-space db)
   (term-store/current-sequence (database-store db))))

(defn database-status [db]
  (locking (:lock db)
    (let [{:keys [status reconciled?] :as recovery}
          (database-recovery-state db)
          readable? (or (= :ready status)
                        (and (= :recovery-required status) reconciled?))
          context (:term-store db)]
      {:space-id (database-space db)
       :version (when readable?
                  (t/transaction-coordinate
                   (database-space db)
                   (term-store/current-sequence context)))
       :transactions (when readable? (term-store/transaction-count context))
       :operations (when readable? (term-store/operation-count context))
       :terms (when readable? (term-store/term-count context))
       :readable readable?
       :mutation-ready (= :ready status)
       :recovery recovery})))

(defn instant-now []
  (let [now (java.time.Instant/now)]
    (t/instant (.getEpochSecond now) (.getNano now))))

(defn occurrences [db]
  (term-store/occurrences (database-store db)))

;; Ranged: the whole-history occurrences scan costs O(all operations)
;; per commit, making a corpus fold O(n^2) in propositions.
(defn- occurrences-range [db from to]
  (let [store @(database-store db)]
    (mapv (fn [position]
            (let [slots (term-store/occurrence-tuple-at store position)]
              (t/operation-occurrence
               (nth slots 0) (nth slots 1) (nth slots 2))))
          (range from to))))

(defn occurrence [db coordinate]
  (some #(when (= coordinate (t/operationoccurrence-coordinate %)) %)
        (occurrences db)))

(defn- relation-proposition? [predicate value]
  (and (t/triple? value)
       (t/occurrence-coordinate? (t/triple-t1 value))
       (= predicate (t/triple-t2 value))
       (t/occurrence-coordinate? (t/triple-t3 value))))

(defn supersession-triples [db]
  (filterv #(relation-proposition? :kernel/supersedes %)
           (term-store/live-propositions (database-store db))))

(defn withdrawals [db]
  (term-store/withdrawals (database-store db)))

(defn- suppressed-occurrences [db]
  (into #{}
        (map t/triple-t3)
        (supersession-triples db)))

(defn live-occurrences [db]
  (let [suppressed (suppressed-occurrences db)]
    (filterv #(not (contains? suppressed
                              (t/operationoccurrence-coordinate %)))
             (term-store/live-occurrences (database-store db)))))

(defn live-propositions [db]
  (mapv t/operationoccurrence-proposition (live-occurrences db)))

(defn- validate-base [db base]
  (when base
    (when-not (t/transaction-coordinate? base)
      (fail! :invalid-base "OCC base must be a transaction-coordinate Triple"
             {:base base}))
    (when-not (= (database-space db) (t/triple-t1 base))
      (fail! :space-mismatch "OCC base belongs to a different SpaceId"
             {:base base :space-id (database-space db)})))
  base)

(def ^:private occurrence-metadata-order
  [:kernel/recorded-at :kernel/asserted-by :kernel/source-record
   :kernel/supersedes])

(defn- canonical-term! [value]
  (cond
    (t/triple? value)
    (t/triple (canonical-term! (t/triple-t1 value))
              (canonical-term! (t/triple-t2 value))
              (canonical-term! (t/triple-t3 value)))
    (integer? value) (long (require-i64! value "Int atom"))
    (and (number? value) (not (integer? value))) (double value)
    (t/instant? value)
    (t/instant (require-i64! (t/instant-epoch-seconds value)
                             "Instant epoch seconds")
               (t/instant-nanos value))
    (t/atom? value) value
    :else (fail! :invalid-term "value is outside Term" {:value value})))

(defn- commit-operation! [{:keys [action proposition] :as operation}]
  (when-not (t/triple? proposition)
    (fail! :invalid-commit-operation "operation proposition must be a Triple"
           {:operation operation}))
  (let [canonical (canonical-term! proposition)]
    (case action
    :assert (term-store/assert-operation canonical)
    :retract (term-store/retract-operation canonical)
    (fail! :invalid-commit-operation "operation action must be :assert or :retract"
           {:operation operation}))))

(defn- validate-occurrence-reference! [db coordinate field]
  (when coordinate
    (when-not (t/occurrence-coordinate? coordinate)
      (fail! :invalid-occurrence-coordinate
             (str field " must be an occurrence-coordinate Triple")
             {field coordinate}))
    (let [tx (t/triple-t1 coordinate)]
      (when-not (= (database-space db) (t/triple-t1 tx))
        (fail! :space-mismatch "occurrence coordinate belongs to another SpaceId"
               {field coordinate :space-id (database-space db)})))
    (when-not (occurrence db coordinate)
      (fail! :unknown-occurrence "occurrence coordinate does not resolve"
             {field coordinate})))
  coordinate)

(defn- metadata-operations [db tx-coordinate source-operations request]
  (let [source-count (count source-operations)
        per-source
        (mapcat
         (fn [[ordinal operation]]
           (let [source (t/occurrence-coordinate tx-coordinate ordinal)
                 values {:kernel/recorded-at (some-> (:recorded-at operation)
                                                     canonical-term!)
                         :kernel/asserted-by (some-> (:asserted-by operation)
                                                    canonical-term!)
                         :kernel/source-record (some-> (:source-record operation)
                                                     canonical-term!)
                         :kernel/supersedes (:supersedes operation)}]
             (validate-occurrence-reference! db (:supersedes operation) :supersedes)
             (when (and (:recorded-at operation)
                        (not (t/instant? (:recorded-at operation))))
               (fail! :invalid-instant
                      "operation recorded-at must be a typed Instant"
                      {:recorded-at (:recorded-at operation)}))
             (mapv (fn [predicate]
                     (term-store/assert-operation
                      (t/triple source predicate (get values predicate))))
                   (filter #(some? (get values %)) occurrence-metadata-order))))
         (map-indexed vector source-operations))
        tx-metadata
        (cond-> []
          (:recorded-at request)
          (conj (term-store/assert-operation
                 (t/triple tx-coordinate :kernel/recorded-at
                           (canonical-term! (:recorded-at request)))))
          (:actor request)
          (conj (term-store/assert-operation
                 (t/triple tx-coordinate :kernel/asserted-by
                           (canonical-term! (:actor request))))))]
    (when (and (:recorded-at request)
               (not (t/instant? (:recorded-at request))))
      (fail! :invalid-instant "recorded-at must be a typed Instant"
             {:recorded-at (:recorded-at request)}))
    (when (and (:actor request) (not (t/term? (:actor request))))
      (fail! :invalid-term "actor must be a Term" {:actor (:actor request)}))
    (vec (concat per-source tx-metadata))))

(defn- append-and-replay! [db sequence operations metadata]
  (let [record (term-store/transaction-record sequence operations)
        serializable {:tx-seq sequence
                      :commit-metadata metadata
                      :operations (mapv operation-map (range) operations)}]
    (if *deferred-records*
      (swap! *deferred-records* conj serializable)
      (when-let [path (:log db)]
        (append-record-durable! path serializable (:deflate? db))))
    (term-store/replay-transaction! (database-store db) record)))

(defn- throwable-code [error]
  (let [data (ex-data error)]
    (or (:store/code data) (:type data) (:code data)
        (keyword (.getSimpleName (class error))))))

(defn- fence-and-reconcile! [db before-store ^Throwable error]
  ;; No caller may observe the pre-append version as writable while the log is
  ;; being resolved after a write whose durable outcome is unknown.
  (let [cause {:code (throwable-code error) :message (.getMessage error)}]
    (reset! (:mutation-state db)
            {:status :recovery-required :reconciled? false :cause cause})
    (try
      (let [{:keys [context torn-tail valid-bytes source]}
            (if-let [path (:log db)]
              (let [parsed (read-triple-log! path)
                    space-id (:space-id parsed)
                    context (term-store/new-term-store space-id)]
                (when-not (= (database-space db) space-id)
                  (fail! :space-mismatch
                         "durable history changed SpaceId during reconciliation"
                         {:expected (database-space db) :actual space-id}))
                (replay-records! context (:records parsed))
                {:context context :torn-tail (:torn-tail parsed)
                 :valid-bytes (:valid-bytes parsed) :source :durable-prefix})
              (let [context (term-store/new-term-store (database-space db))]
                (reset! context before-store)
                {:context context :torn-tail nil :valid-bytes nil
                 :source :memory-snapshot}))
            sequence (term-store/current-sequence context)
            recovery {:status :recovery-required
                      :reconciled? true
                      :source source
                      :cause cause
                      :version (t/transaction-coordinate
                                (database-space db) sequence)
                      :torn-tail torn-tail
                      :valid-bytes valid-bytes}]
        (reset! (:term-store db) @context)
        (reset! (:mutation-state db) recovery)
        recovery)
      (catch Throwable reconciliation-error
        (let [corruption {:status :corrupt
                          :reconciled? false
                          :cause cause
                          :corruption
                          {:code (throwable-code reconciliation-error)
                           :message (.getMessage reconciliation-error)}}]
          (reset! (:mutation-state db) corruption)
          corruption)))))

(defn- propagate-ambiguous-commit! [recovery error]
  (if (= :corrupt (:status recovery))
    (throw
     (ex-info "durable history is corrupt after a commit failure"
              {:type :database-corrupt :store/code :database-corrupt
               :recovery recovery}
              error))
    (throw
     (ex-info "commit outcome is durability-ambiguous; restart is required"
              {:type :durability-ambiguous :store/code :durability-ambiguous
               :recovery recovery}
              error))))

(defn commit!
  "Commit one ordered transaction. REQUEST contains :operations and may contain
   :base, :actor, and typed :recorded-at. The response exposes transaction and
   occurrence coordinates; no physical row handle is public."
  [db {:keys [operations base] :as request}]
  (locking (:lock db)
    (require-mutation-ready! db)
    (validate-base db base)
    (let [current (current-transaction db)]
      (if (and base (not= base current))
        {:reject :conflict :expected base :current current}
        (do
          (when-not (and (vector? operations) (seq operations))
            (fail! :invalid-transaction-record
                   "transaction requires a nonempty operation vector" {}))
          (when (:torn-tail db)
            (fail! :torn-tail-repair-required
                   "Store transaction log has a torn trailing record; writer authority must repair it"
                   {:path (:log db) :torn-tail (:torn-tail db)}))
          (let [context (database-store db)
                sequence (term-store/next-sequence context)
                tx-coordinate (t/transaction-coordinate
                               (database-space db) sequence)
                source-operations (mapv commit-operation! operations)
                metadata (metadata-operations db tx-coordinate operations request)
                all-operations (into source-operations metadata)
                commit-metadata (canonical-validate-commit!
                                 all-operations (:commit-metadata request))
                before (term-store/operation-count context)
                ;; A store is an identity: the rollback point has to be a fork
                ;; taken before append-and-replay! mutates the live one.
                before-store (term-store/fork-state @context)]
            (try
              (let [committed (append-and-replay!
                               db sequence all-operations commit-metadata)
                    events (occurrences-range
                            db before (+ before (count source-operations)))
                    event-coordinates
                    (into #{} (map t/operationoccurrence-coordinate) events)
                    withdrawals
                    (filterv
                     #(contains?
                       event-coordinates
                       (t/operationoccurrence-coordinate
                        (t/withdrawal-retraction %)))
                     (withdrawals db))]
                {:ok committed
                 :occurrences events
                 :withdrawals withdrawals
                 :operation-count (count all-operations)})
              (catch Throwable error
                (propagate-ambiguous-commit!
                 (fence-and-reconcile! db before-store error)
                 error)))))))))

(defn commit-cohort!
  "Run mutation functions in FIFO order against a private store root, append
   every resulting Store transaction log record under one durability barrier, and publish the
   root atomically. Individual pre-append failures are returned without
   aborting later functions; a barrier failure fences the whole database."
  [db mutation-functions]
  (locking (:lock db)
    (require-mutation-ready! db)
    (let [context (database-store db)
          before-store @context
          scratch (assoc db
                         :term-store (term-store/fork-store context)
                         :mutation-state (atom @(:mutation-state db)))
          records (atom [])
          results
          (binding [*deferred-records* records]
            (mapv (fn [mutation]
                    (try
                      (let [value (mutation scratch)]
                        {:value value
                         :version (term-store/current-sequence
                                   (database-store scratch))})
                      (catch Throwable error
                        {:error error
                         :version (term-store/current-sequence
                                   (database-store scratch))})))
                  mutation-functions))]
      (if (empty? @records)
        {:results results :record-count 0 :root before-store
         :version (term-store/current-sequence context)}
        (try
          (when-let [path (:log db)]
            (append-record-cohort-durable! path @records (:deflate? db)))
          (let [root @(database-store scratch)]
            (reset! context root)
            {:results results :record-count (count @records) :root root
             :version (term-store/current-sequence context)})
          (catch Throwable error
            (propagate-ambiguous-commit!
             (fence-and-reconcile! db before-store error)
             error)))))))

(defn assert!
  ([db proposition] (assert! db proposition {}))
  ([db proposition options]
   (commit! db (assoc options :operations
                      [{:action :assert :proposition proposition
                        :supersedes (:supersedes options)
                        :source-record (:source-record options)}]))))

(defn retract!
  ([db proposition] (retract! db proposition {}))
  ([db proposition options]
   (commit! db (assoc options :operations
                      [{:action :retract :proposition proposition
                        :source-record (:source-record options)}]))))

(defn withdraw-occurrence!
  "Withdraw one exact currently-effective occurrence. TermStore's physical
   retraction targets the most recent equal live proposition; rejecting any
   other coordinate keeps the public target exact."
  [db target options]
  (locking (:lock db)
    (let [event (occurrence db target)
          effective (into #{} (map t/operationoccurrence-coordinate)
                          (live-occurrences db))]
      (cond
        (nil? event) {:reject :unknown-occurrence :occurrence target}
        (not (t/assertion-occurrence? event))
        {:reject :not-assertion-occurrence :occurrence target}
        (not (contains? effective target))
        {:reject :occurrence-not-live :occurrence target}
        :else
        (let [proposition (t/operationoccurrence-proposition event)
              matching (filterv #(= proposition
                                    (t/operationoccurrence-proposition %))
                                (term-store/live-occurrences
                                 (database-store db)))
              current (some-> matching peek
                              t/operationoccurrence-coordinate)]
          (if (not= target current)
            {:reject :withdrawal-target-not-current
             :occurrence target :current current}
            (retract! db proposition options)))))))

(defn supersede!
  "Assert REPLACEMENT while relating its new occurrence to exact TARGET."
  [db target replacement options]
  (locking (:lock db)
    (if-not (some #{target} (map t/operationoccurrence-coordinate
                                 (live-occurrences db)))
      {:reject :occurrence-not-live :occurrence target}
      (assert! db replacement (assoc options :supersedes target)))))

(defn view-select! [db view target options]
  (locking (:lock db)
    (validate-occurrence-reference! db target :target)
    (let [selection (t/triple view :kernel/selects target)]
      (if (some #{selection} (live-propositions db))
        {:idempotent true :selection selection}
        (assert! db selection options)))))

(defn view-deselect! [db view target options]
  (retract! db (t/triple view :kernel/selects target) options))

(defn view-occurrences [db view]
  (let [effective (live-occurrences db)
        by-coordinate
        (into {} (map (juxt t/operationoccurrence-coordinate identity)) effective)
        selected (for [event effective
                       :let [proposition
                             (t/operationoccurrence-proposition event)]
                       :when (and (= view (t/triple-t1 proposition))
                                  (= :kernel/selects (t/triple-t2 proposition))
                                  (t/occurrence-coordinate?
                                   (t/triple-t3 proposition)))]
                   (t/triple-t3 proposition))]
    (into [] (keep by-coordinate) selected)))

(defn- lease-value [holder expires-ms]
  (t/triple holder :kernel/expires-at expires-ms))

(defn- lease-record [event]
  (let [proposition (t/operationoccurrence-proposition event)
        value (t/triple-t3 proposition)]
    (when (and (= :kernel/lease (t/triple-t2 proposition))
               (t/triple? value)
               (= :kernel/expires-at (t/triple-t2 value))
               (integer? (t/triple-t3 value)))
      {:resource (t/triple-t1 proposition)
       :holder (t/triple-t1 value)
       :expires-ms (t/triple-t3 value)
       :occurrence (t/operationoccurrence-coordinate event)
       :proposition proposition})))

(defn current-lease [db resource]
  (some->> (live-occurrences db)
           (keep lease-record)
           (filter #(= resource (:resource %)))
           last))

(defn acquire-lease! [db resource holder ttl-ms now-ms]
  (locking (:lock db)
    (when-not (and (t/term? resource) (t/term? holder)
                   (integer? ttl-ms) (pos? ttl-ms)
                   (integer? now-ms))
      (fail! :invalid-lease-request "lease requires Term resource/holder and positive ttl"
             {:resource resource :holder holder :ttl-ms ttl-ms :now-ms now-ms}))
    (let [prior (current-lease db resource)]
      (if (and prior (> (:expires-ms prior) now-ms))
        {:reject :lease-held :holder (:holder prior)
         :epoch (:occurrence prior) :expires-ms (:expires-ms prior)}
        (let [result (assert! db
                              (t/triple resource :kernel/lease
                                        (lease-value holder (+ now-ms ttl-ms)))
                              (cond-> {:actor holder}
                                prior (assoc :supersedes (:occurrence prior))))
              epoch (some-> result :occurrences first
                            t/operationoccurrence-coordinate)]
          {:ok epoch :expires-ms (+ now-ms ttl-ms)
           :transaction (:ok result)})))))

(defn renew-lease! [db resource holder epoch ttl-ms now-ms]
  (locking (:lock db)
    (let [prior (current-lease db resource)]
      (if-not (and prior (= holder (:holder prior))
                   (= epoch (:occurrence prior))
                   (> (:expires-ms prior) now-ms))
        {:reject :lease-fence-mismatch :current prior}
        (let [result (assert! db
                              (t/triple resource :kernel/lease
                                        (lease-value holder (+ now-ms ttl-ms)))
                              {:actor holder :supersedes epoch})
              next-epoch (some-> result :occurrences first
                                 t/operationoccurrence-coordinate)]
          {:ok next-epoch :expires-ms (+ now-ms ttl-ms)
           :transaction (:ok result)})))))

(defn release-lease! [db resource holder epoch]
  (locking (:lock db)
    (let [prior (current-lease db resource)]
      (if-not (and prior (= holder (:holder prior)) (= epoch (:occurrence prior)))
        {:reject :lease-fence-mismatch :current prior}
        (let [result (withdraw-occurrence! db epoch {:actor holder})]
          (if (:ok result)
            {:ok true :transaction (:ok result) :withdrawals (:withdrawals result)}
            result))))))

(defn lease-fence-valid? [db resource holder epoch now-ms]
  (let [lease (current-lease db resource)]
    (boolean (and lease (= holder (:holder lease))
                  (= epoch (:occurrence lease))
                  (> (:expires-ms lease) now-ms)))))
