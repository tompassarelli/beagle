(ns database
  (:require [clojure.string :as str]
            [store.rpc :as rpc]
            [store.branch :as branch]
            [store.chain-rules :as chain-rules]
            [store.checkpoint :as checkpoint]
            [store.packed :as packed]
            [store.store :as term-store]
            [store.types :as t])
  (:import [java.io File]
           [java.io RandomAccessFile]
           [java.nio ByteBuffer]
           [java.nio ByteOrder]
           [java.nio CharBuffer]
           [java.nio.charset CodingErrorAction]
           [java.nio.charset StandardCharsets]
           [java.nio.file Files]
           [java.nio.file StandardCopyOption]
           [java.security MessageDigest]
           [java.time Instant]
           [java.util Arrays]
           [java.util.zip CRC32]))

(let [^File source-file (.getCanonicalFile (File. (str *file*)))
   parent (.getParentFile source-file)]
  (if parent (clojure.core/load-file (.getPath (File. parent "writer_authority.clj"))) (throw (ex-info "database source has no parent directory" {:source (.getPath source-file)}))))

(def triple-log-magic (.getBytes "STORELOG" StandardCharsets/UTF_8))

(def triple-log-version 1)

(def triple-log-flags 0)

(def deflate-flag 1)

(def continuation-flag 2)

(def max-term-depth 256)

(def ^String canonical-validator "store/canonical-validator-v1")

(def ^String canonical-shape-schema-id "store/CommitOperationV1")

(defn- default-commit-metadata [producer profile]
  {:producer producer :shape-schema-id canonical-shape-schema-id :profile profile :validation-attestation {:validator canonical-validator :result :pending :attestation canonical-validator}})

(defn- canonical-validate-commit! [operations metadata]
  (let [metadata (or metadata (default-commit-metadata "store.txn/v1" "store-schema-v1"))
   validation (:validation-attestation metadata)]
  (if (not (and (map? metadata) (string? (:producer metadata)) (pos? (count (:producer metadata))) (string? (:shape-schema-id metadata)) (pos? (count (:shape-schema-id metadata))) (or (nil? (:profile metadata)) (and (string? (:profile metadata)) (pos? (count (:profile metadata))))) (map? validation) (string? (:validator validation)) (keyword? (:result validation)) (string? (:attestation validation)))) (do
  (throw (ex-info "store: canonical commit validation rejected the write" {:type :canonical-commit-rejected :store/code :canonical-commit-rejected :metadata metadata}))))
  (assoc metadata :validation-attestation {:validator canonical-validator :result :accepted :attestation canonical-validator})))

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :store/code code))))

(defn- require-u32! [n label]
  (if (not (and (integer? n) (<= 0 n) (<= n 4294967295))) (do
  (fail! :invalid-integer (str label " is outside unsigned 32-bit range") {:label label :value n})))
  (long n))

(defn- require-i64! [n label]
  (if (not (and (integer? n) (<= Long/MIN_VALUE n) (<= n Long/MAX_VALUE))) (do
  (fail! :invalid-integer (str label " is outside signed 64-bit range") {:label label :value n})))
  (long n))

(defn- write-u8! [out n]
  (.write out (int (bit-and 255 (long n)))))

(defn- write-u16-le! [out n]
  (let [v (long n)]
  (doseq [i (range 2)]
  (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- write-u32-le! [out n]
  (let [v (require-u32! n "u32")]
  (doseq [i (range 4)]
  (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- write-i64-le! [out n]
  (let [v (require-i64! n "i64")]
  (doseq [i (range 8)]
  (write-u8! out (unsigned-bit-shift-right v (* i 8))))))

(defn- strict-utf8-bytes! [s label]
  (if (not (string? s)) (do
  (fail! :invalid-text (str label " must be a String") {:label label :value s})))
  (try
  (let [encoder (doto (.newEncoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))
   buffer (.encode encoder (CharBuffer/wrap s))
   bytes (byte-array (.remaining buffer))]
  (.get buffer bytes)
  bytes)
  (catch java.nio.charset.CharacterCodingException e
    (fail! :invalid-utf8 (str label " is not valid UTF-8 text") {:label label :cause (.getMessage e)}))))

(defn- strict-utf8-string! [bytes label]
  (try
  (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))]
  (str (.decode decoder (ByteBuffer/wrap bytes))))
  (catch java.nio.charset.CharacterCodingException e
    (fail! :invalid-utf8 (str label " is not valid UTF-8") {:label label :cause (.getMessage e)}))))

(defn- write-triple! [out value depth]
  (if (not (t/triple? value)) (do
  (fail! :invalid-triple "recursive encoder requires a Triple" {:value value})))
  (if (not (zero? depth)) (do
  (fail! :invalid-term-depth "Store transaction log Term encoding must begin at depth zero" {:depth depth})))
  (try
  (rpc/write-term-codec-v1! out value Integer/MAX_VALUE Integer/MAX_VALUE max-term-depth)
  (catch clojure.lang.ExceptionInfo e
    (let [code (:store/code (ex-data e))]
  (case code
    :term-depth-exceeded (throw e)
    :term-codec-invalid-utf8 (fail! :invalid-utf8 "Store transaction log Term contains invalid UTF-8" {:cause code})
    :term-codec-invalid-keyword (fail! :invalid-keyword "Store transaction log Keyword atom is empty" {:cause code})
    :term-codec-integer-range (fail! :invalid-integer "Store transaction log Term integer is out of range" {:cause code})
    :term-codec-unsupported-term (fail! :unsupported-term "Store transaction log encountered a value outside Term" {:value value :class (some-> value class str)})
    (throw e))))))

(defn- ensure-remaining! [^ByteBuffer buffer n ^String context]
  (if (< (.remaining buffer) n) (do
  (fail! :corrupt-triple-log "Store transaction log payload ended inside a value" {:context context :needed n :remaining (.remaining buffer)}))))

(defn- read-u32! [^ByteBuffer buffer ^String context]
  (ensure-remaining! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer)))

(defn- read-term! [^ByteBuffer buffer depth]
  (if (not (zero? depth)) (do
  (fail! :corrupt-triple-log "Store transaction log Term decoding must begin at depth zero" {:depth depth})))
  (try
  (t/termcodecdecoded-value (rpc/decode-term-codec-v1! buffer Integer/MAX_VALUE Integer/MAX_VALUE max-term-depth))
  (catch clojure.lang.ExceptionInfo e
    (if (= :term-depth-exceeded (:store/code (ex-data e))) (throw e) (fail! :corrupt-triple-log "Store transaction log contains a malformed Term" {:cause (:store/code (ex-data e))})))))

(defn- wire-action! [action]
  (case action
    :assert 1
    :retract 2
    (fail! :invalid-commit-operation "operation action must be :assert or :retract" {:action action})))

(defn- store-action! [action]
  (case action
    1 :assert
    2 :retract
    (fail! :corrupt-triple-log "Store transaction log contains an unknown operation action" {:action action})))

(defn- operation-map! [ordinal operation]
  {:ordinal ordinal :action (wire-action! (t/commitoperation-action operation)) :triple (t/commitoperation-proposition operation)})

(defn- deflate-bytes [bytes]
  (let [out (java.io.ByteArrayOutputStream. (alength bytes))]
  (with-open [gz (java.util.zip.GZIPOutputStream. out)]
  (.write gz bytes))
  (.toByteArray out)))

(defn- inflate-bytes! [bytes path offset]
  (try
  (let [out (java.io.ByteArrayOutputStream. (* 4 (alength bytes)))
   buffer (byte-array 8192)]
  (with-open [gz (java.util.zip.GZIPInputStream. (java.io.ByteArrayInputStream. bytes))]
  (loop []
  (let [n (.read gz buffer)]
  (if (pos? n) (do
  (.write out buffer 0 n)
  (recur))))))
  (.toByteArray out))
  (catch java.io.IOException error
    (fail! :corrupt-triple-log "Store transaction log deflate record is invalid" {:path path :offset offset :cause (.getMessage error)}))))

(defn- write-transaction-record! [out tx deflate?]
  (let [payload (java.io.ByteArrayOutputStream.)
   operations (:operations tx)]
  (write-i64-le! payload (:tx-seq tx))
  (write-u32-le! payload (count operations))
  (doseq [[expected operation] (map-indexed vector operations)]
  (if (not (= expected (:ordinal operation))) (do
  (fail! :noncontiguous-ordinal "transaction operation ordinals must be contiguous" {:tx-seq (:tx-seq tx) :expected expected :actual (:ordinal operation)})))
  (write-u32-le! payload (:ordinal operation))
  (write-u8! payload (:action operation))
  (write-triple! payload (:triple operation) 0))
  (let [bytes (let [raw (.toByteArray payload)]
  (if deflate? (deflate-bytes raw) raw))
   crc (doto (java.util.zip.CRC32.)
  (.update bytes))]
  (write-u32-le! out (alength bytes))
  (.write out bytes)
  (write-u32-le! out (.getValue crc)))))

(defn- decode-transaction-payload! [payload record-offset]
  (let [^ByteBuffer buffer (doto (ByteBuffer/wrap payload)
  (.order ByteOrder/LITTLE_ENDIAN))]
  (ensure-remaining! buffer 12 "transaction header")
  (let [sequence (.getLong buffer)
   operation-count (read-u32! buffer "operation count")]
  (if (neg? sequence) (do
  (fail! :corrupt-triple-log "Store transaction log transaction sequence is negative" {:offset record-offset :sequence sequence})))
  (if (or (zero? operation-count) (> operation-count Integer/MAX_VALUE)) (do
  (fail! :corrupt-triple-log "Store transaction log transaction operation count is invalid" {:offset record-offset :operation-count operation-count})))
  (let [operations (mapv (fn [expected] (let [ordinal (read-u32! buffer "operation ordinal")]
  (if (not (= expected ordinal)) (do
  (fail! :noncontiguous-ordinal "Store transaction log operation ordinals are not contiguous" {:offset record-offset :sequence sequence :expected expected :actual ordinal})))
  (ensure-remaining! buffer 1 "operation action")
  (let [action (bit-and 255 (int (.get buffer)))
   proposition (read-term! buffer 0)]
  (if (not (t/triple? proposition)) (do
  (fail! :corrupt-triple-log "Store transaction log operation proposition is not a Triple" {:offset record-offset :sequence sequence :ordinal ordinal})))
  {:ordinal ordinal :action action :store-action (store-action! action) :triple proposition}))) (vec (range (int operation-count))))]
  (if (not (zero? (.remaining buffer))) (do
  (fail! :corrupt-triple-log "Store transaction log transaction has trailing payload bytes" {:offset record-offset :sequence sequence :remaining (.remaining buffer)})))
  {:tx-seq sequence :operations operations}))))

(defn- bytes-prefix? [bytes prefix]
  (and (>= (alength bytes) (alength prefix)) (Arrays/equals prefix (Arrays/copyOfRange bytes 0 (alength prefix)))))

(defn- parse-triple-log-bytes!
  ([bytes path]
    (parse-triple-log-bytes! bytes path false))
  ([bytes path allow-continuation?]
    (if (not (bytes-prefix? bytes triple-log-magic)) (do
  (fail! :corrupt-triple-log "Store transaction log magic does not match" {:path path})))
    (let [^ByteBuffer buffer (doto (ByteBuffer/wrap bytes)
  (.order ByteOrder/LITTLE_ENDIAN))]
  (.position buffer (alength triple-log-magic))
  (try
  (ensure-remaining! buffer 8 "Store transaction log header")
  (let [version (bit-and 65535 (int (.getShort buffer)))
   flags (bit-and 65535 (int (.getShort buffer)))
   space-length (read-u32! buffer "SpaceId length")]
  (if (not (and (= triple-log-version version) (contains? (if allow-continuation? #{triple-log-flags deflate-flag continuation-flag (bit-or deflate-flag continuation-flag)} #{triple-log-flags deflate-flag}) flags))) (do
  (fail! :unsupported-log-version "Store transaction log version or flags are unsupported" {:path path :version version :flags flags})))
  (if (or (zero? space-length) (> space-length Integer/MAX_VALUE)) (do
  (fail! :corrupt-triple-log "Store transaction log SpaceId length is invalid" {:path path :length space-length})))
  (ensure-remaining! buffer (int space-length) "SpaceId")
  (let [space-bytes (byte-array (int space-length))
   _ (.get buffer space-bytes)
   space-id (strict-utf8-string! space-bytes "SpaceId")
   deflate? (pos? (bit-and deflate-flag flags))
   continuation? (pos? (bit-and continuation-flag flags))
   header-bytes (.position buffer)]
  (loop [records []
   valid-bytes header-bytes
   prefix-ends {}]
  (let [offset (.position buffer)
   remaining (.remaining buffer)]
  (cond
  (zero? remaining) {:space-id space-id :deflate? deflate? :records records :continuation? continuation? :valid-bytes valid-bytes :header-bytes header-bytes :prefix-ends prefix-ends :torn-tail nil}
  (< remaining 4) {:space-id space-id :deflate? deflate? :records records :continuation? continuation? :valid-bytes valid-bytes :header-bytes header-bytes :prefix-ends prefix-ends :torn-tail {:offset offset :bytes remaining :reason :torn-record-length}}
  :else (let [payload-length (read-u32! buffer "record payload length")]
  (if (> payload-length Integer/MAX_VALUE) (do
  (fail! :corrupt-triple-log "Store transaction log record exceeds JVM bounds" {:path path :offset offset :length payload-length})))
  (if (< (.remaining buffer) (+ payload-length 4)) {:space-id space-id :records records :continuation? continuation? :valid-bytes valid-bytes :header-bytes header-bytes :prefix-ends prefix-ends :torn-tail {:offset offset :bytes (- (alength bytes) offset) :reason :torn-transaction-record}} (let [payload (byte-array (int payload-length))
   _ (.get buffer payload)
   stored-crc (read-u32! buffer "record CRC")
   actual-crc (.getValue (doto (java.util.zip.CRC32.)
  (.update payload)))]
  (if (not (= stored-crc actual-crc)) (do
  (fail! :corrupt-triple-log "Store transaction log record CRC does not match" {:path path :offset offset :stored stored-crc :actual actual-crc})))
  (let [record (decode-transaction-payload! (if deflate? (inflate-bytes! payload path offset) payload) offset)
   end (.position buffer)]
  (recur (conj records record) end (assoc prefix-ends (:tx-seq record) end)))))))))))
  (catch Throwable error
    (if (instance? clojure.lang.ExceptionInfo error) (throw error) (fail! :corrupt-triple-log "Store transaction log header is truncated" {:path path :cause (.getMessage error)})))))))

(defn- ^String stream-hex [^bytes content]
  (apply str (map (fn [value] (format "%02x" (bit-and (int value) 255))) content)))

(defn- ^"[B" read-file-exact! [^RandomAccessFile input amount digest]
  (let [^bytes bytes (byte-array amount)]
  (.readFully input bytes 0 amount)
  (if digest (do
  (.update digest bytes 0 (alength bytes))))
  bytes))

(defn- bytes-u16-le [^bytes bytes]
  (+ (bit-and 255 (int (aget bytes 0))) (bit-shift-left (bit-and 255 (int (aget bytes 1))) 8)))

(defn- bytes-u32-le [^bytes bytes]
  (Integer/toUnsignedLong (.getInt (doto (ByteBuffer/wrap bytes)
  (.order ByteOrder/LITTLE_ENDIAN)))))

(defn- read-file-u16! [^RandomAccessFile input digest]
  (bytes-u16-le (read-file-exact! input 2 digest)))

(defn- read-file-u32! [^RandomAccessFile input digest]
  (bytes-u32-le (read-file-exact! input 4 digest)))

(defn- read-triple-log-header! [^RandomAccessFile input ^String path ^Boolean allow-continuation? digest]
  (try
  (.seek input 0)
  (let [^bytes magic (read-file-exact! input (alength triple-log-magic) digest)]
  (if (not (Arrays/equals triple-log-magic magic)) (do
  (fail! :corrupt-triple-log "Store transaction log magic does not match" {:path path}))))
  (let [version (read-file-u16! input digest)
   flags (read-file-u16! input digest)
   space-length (read-file-u32! input digest)]
  (if (not (and (= triple-log-version version) (contains? (if allow-continuation? #{triple-log-flags deflate-flag continuation-flag (bit-or deflate-flag continuation-flag)} #{triple-log-flags deflate-flag}) flags))) (do
  (fail! :unsupported-log-version "Store transaction log version or flags are unsupported" {:path path :version version :flags flags})))
  (if (or (zero? space-length) (> space-length Integer/MAX_VALUE)) (do
  (fail! :corrupt-triple-log "Store transaction log SpaceId length is invalid" {:path path :length space-length})))
  (let [^String space-id (strict-utf8-string! (read-file-exact! input space-length digest) "SpaceId")]
  {:space-id space-id :deflate? (pos? (bit-and deflate-flag flags)) :continuation? (pos? (bit-and continuation-flag flags)) :header-bytes (.getFilePointer input)}))
  (catch Throwable error
    (if (instance? clojure.lang.ExceptionInfo error) (throw error) (fail! :corrupt-triple-log "Store transaction log header is truncated" {:path path :cause (.getMessage error)})))))

(defn- prefix-source-result [header sequence valid-bytes ^MessageDigest digest]
  {:space-id (:space-id header) :sequence sequence :valid-bytes valid-bytes :fingerprint (stream-hex (.digest digest))})

(defn- scan-triple-log-prefix! [path upper-inclusive expected-valid-bytes]
  (if (not (and (integer? upper-inclusive) (<= 0 upper-inclusive Long/MAX_VALUE))) (do
  (fail! :invalid-prefix-revision "Store transaction log prefix revision is invalid" {:revision upper-inclusive})))
  (let [^File file (.getCanonicalFile (File. (str path)))]
  (if (not (.isFile file)) (do
  (fail! :triple-log-missing "Store transaction log source is missing" {:path (.getPath file)})))
  (with-open [input (RandomAccessFile. file "r")]
  (let [^MessageDigest digest (MessageDigest/getInstance "SHA-256")
   header (read-triple-log-header! input (.getPath file) false digest)
   file-length (.length input)]
  (loop [sequence 0]
  (let [offset (.getFilePointer input)]
  (cond
  (>= sequence upper-inclusive) (do
  (if (and (some? expected-valid-bytes) (not= (long expected-valid-bytes) offset)) (do
  (fail! :packed-source-mismatch "packed checkpoint byte boundary does not match STORELOG framing" {:path (.getPath file) :revision sequence :expected expected-valid-bytes :actual offset})))
  (prefix-source-result header sequence offset digest))
  (= offset file-length) (if (some? expected-valid-bytes) (fail! :packed-source-mismatch "packed checkpoint revision is beyond the STORELOG" {:path (.getPath file) :revision upper-inclusive :available sequence}) (prefix-source-result header sequence offset digest))
  (< (- file-length offset) 4) (fail! :corrupt-triple-log "Store transaction log prefix ends inside a record length" {:path (.getPath file) :offset offset})
  :else (let [^bytes length-bytes (read-file-exact! input 4 nil)
   payload-length (bytes-u32-le length-bytes)
   after-length (.getFilePointer input)]
  (if (> payload-length Integer/MAX_VALUE) (do
  (fail! :corrupt-triple-log "Store transaction log record exceeds JVM bounds" {:path (.getPath file) :offset offset :length payload-length})))
  (if (< (- file-length after-length) (+ payload-length 4)) (do
  (fail! :corrupt-triple-log "Store transaction log prefix ends inside a transaction record" {:path (.getPath file) :offset offset :length payload-length})))
  (let [^bytes payload (read-file-exact! input payload-length nil)
   ^bytes stored-crc-bytes (read-file-exact! input 4 nil)
   stored-crc (bytes-u32-le stored-crc-bytes)
   actual-crc (.getValue (doto (CRC32.)
  (.update payload)))
   record (decode-transaction-payload! (if (:deflate? header) (inflate-bytes! payload (.getPath file) offset) payload) offset)
   candidate (:tx-seq record)
   end (.getFilePointer input)]
  (if (not (= stored-crc actual-crc)) (do
  (fail! :corrupt-triple-log "Store transaction log record CRC does not match" {:path (.getPath file) :offset offset :stored stored-crc :actual actual-crc})))
  (if (<= candidate sequence) (do
  (fail! :nonmonotonic-transaction-sequence "Store transaction log transaction sequence is not monotonic" {:path (.getPath file) :offset offset :previous sequence :actual candidate})))
  (if (> candidate upper-inclusive) (do
  (if (and (some? expected-valid-bytes) (not= (long expected-valid-bytes) offset)) (do
  (fail! :packed-source-mismatch "packed checkpoint byte boundary does not match STORELOG framing" {:path (.getPath file) :revision sequence :expected expected-valid-bytes :actual offset})))
  (prefix-source-result header sequence offset digest)) (do
  (.update digest length-bytes)
  (.update digest payload)
  (.update digest stored-crc-bytes)
  (recur candidate))))))))))))

(defn- read-triple-log-records! [^RandomAccessFile input ^String path header start-offset]
  (let [file-length (.length input)]
  (if (not (and (integer? start-offset) (<= (:header-bytes header) start-offset file-length))) (do
  (fail! :corrupt-triple-log "Store transaction log decode offset is invalid" {:path path :offset start-offset :length file-length})))
  (.seek input start-offset)
  (loop [records []
   valid-bytes start-offset
   prefix-ends {}]
  (let [offset (.getFilePointer input)
   remaining (- file-length offset)]
  (cond
  (zero? remaining) (merge header {:records records :valid-bytes valid-bytes :prefix-ends prefix-ends :torn-tail nil :decoded-from-byte start-offset :decoded-record-count (count records)})
  (< remaining 4) (merge header {:records records :valid-bytes valid-bytes :prefix-ends prefix-ends :decoded-from-byte start-offset :decoded-record-count (count records) :torn-tail {:offset offset :bytes remaining :reason :torn-record-length}})
  :else (let [payload-length (read-file-u32! input nil)
   after-length (.getFilePointer input)]
  (if (> payload-length Integer/MAX_VALUE) (do
  (fail! :corrupt-triple-log "Store transaction log record exceeds JVM bounds" {:path path :offset offset :length payload-length})))
  (if (< (- file-length after-length) (+ payload-length 4)) (merge header {:records records :valid-bytes valid-bytes :prefix-ends prefix-ends :decoded-from-byte start-offset :decoded-record-count (count records) :torn-tail {:offset offset :bytes (- file-length offset) :reason :torn-transaction-record}}) (let [^bytes payload (read-file-exact! input payload-length nil)
   stored-crc (read-file-u32! input nil)
   actual-crc (.getValue (doto (CRC32.)
  (.update payload)))]
  (if (not (= stored-crc actual-crc)) (do
  (fail! :corrupt-triple-log "Store transaction log record CRC does not match" {:path path :offset offset :stored stored-crc :actual actual-crc})))
  (let [record (decode-transaction-payload! (if (:deflate? header) (inflate-bytes! payload path offset) payload) offset)
   end (.getFilePointer input)]
  (recur (conj records record) end (assoc prefix-ends (:tx-seq record) end)))))))))))

(defn read-triple-log!
  "Read and validate a Store transaction log generation without accepting any legacy shape."
  ([path]
    (read-triple-log! path false))
  ([path allow-continuation?]
    (let [^File file (.getCanonicalFile (File. (str path)))]
  (if (not (.isFile file)) (do
  (fail! :triple-log-missing "Store transaction log source is missing" {:path (.getPath file)})))
  (with-open [input (RandomAccessFile. file "r")]
  (let [header (read-triple-log-header! input (.getPath file) allow-continuation? nil)]
  (read-triple-log-records! input (.getPath file) header (:header-bytes header)))))))

(defn require-triple-log-header!
  "Return the immutable SpaceId of a validated Store transaction log generation." [path]
  (let [^File file (.getCanonicalFile (File. (str path)))]
  (if (not (.isFile file)) (do
  (fail! :triple-log-missing "Store transaction log source is missing" {:path (.getPath file)})))
  (with-open [input (RandomAccessFile. file "r")]
  (:space-id (read-triple-log-header! input (.getPath file) false nil)))))

(defn triple-log-prefix-source!
  "Bind an inclusive transaction-sequence prefix to its exact canonical bytes." [path upper-inclusive]
  (scan-triple-log-prefix! path upper-inclusive nil))

(defn- triple-log-prefix-source-at! [path revision valid-bytes]
  (scan-triple-log-prefix! path revision valid-bytes))

(defn- read-triple-log-suffix! [path source]
  (let [^File file (.getCanonicalFile (File. (str path)))]
  (if (not (.isFile file)) (do
  (fail! :triple-log-missing "Store transaction log source is missing" {:path (.getPath file)})))
  (with-open [input (RandomAccessFile. file "r")]
  (let [header (read-triple-log-header! input (.getPath file) false nil)
   ^String expected-space (packed/checkpointsource-space-id source)]
  (if (not (= expected-space (:space-id header))) (do
  (fail! :packed-source-mismatch "packed checkpoint SpaceId does not match STORELOG header" {:path (.getPath file) :expected expected-space :actual (:space-id header)})))
  (read-triple-log-records! input (.getPath file) header (packed/checkpointsource-log-valid-bytes source))))))

(defn- write-header!
  ([out space-id]
    (write-header! out space-id triple-log-flags))
  ([out space-id flags]
    (let [space-bytes (strict-utf8-bytes! space-id "SpaceId")]
  (if (zero? (alength space-bytes)) (do
  (fail! :space-id-required "SpaceId must be nonempty" {})))
  (.write out triple-log-magic)
  (write-u16-le! out triple-log-version)
  (write-u16-le! out flags)
  (write-u32-le! out (alength space-bytes))
  (.write out space-bytes))))

(defn create-triple-log!
  "Atomically create a header-only Store transaction log generation for SPACE-ID.\n   {:deflate? true} creates a generation whose records are Deflate-compressed."
  ([path space-id]
    (create-triple-log! path space-id {}))
  ([path space-id {:keys [deflate? continuation?] :or {deflate? false continuation? false}}]
    (let [target (.getCanonicalFile (java.io.File. (str path)))
   parent (.getParentFile target)]
  (if (not (and (.isAbsolute target) parent (.isDirectory parent))) (do
  (fail! :triple-log-target-invalid "Store transaction log target must be an absolute path in an existing directory" {:path (.getPath target)})))
  (if (.exists target) (do
  (fail! :triple-log-exists "Store transaction log target already exists" {:path (.getPath target)})))
  (let [tmp (Files/createTempFile (.toPath parent) ".storelog-header-" ".tmp" (make-array java.nio.file.attribute.FileAttribute 0))]
  (try
  (with-open [file-out (java.io.FileOutputStream. (.toFile tmp))
   out (java.io.BufferedOutputStream. file-out)]
  (write-header! out space-id (bit-or (if deflate? deflate-flag triple-log-flags) (if continuation? continuation-flag triple-log-flags)))
  (.flush out)
  (.force (.getChannel file-out) true))
  (Files/move tmp (.toPath target) (into-array java.nio.file.CopyOption [StandardCopyOption/ATOMIC_MOVE]))
  (.getPath target)
  (finally
    (Files/deleteIfExists tmp)))))))

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
  (term-store/transaction-record (:tx-seq record) (mapv (fn [{:keys [store-action triple]}] (case store-action
    :assert (term-store/assert-operation triple)
    :retract (term-store/retract-operation triple))) (:operations record))))

(defn- replay-records! [context records]
  (doseq [record records]
  (term-store/replay-transaction! context (record->store-record record)))
  context)

(defn- ^String packed-checkpoint-directory [^String path]
  (str path ".packed"))

(defn- checkpoint-source-for-manifest! [^String canonical manifest]
  (let [revision (packed/checkpointmanifest-revision manifest)
   expected-valid-bytes (packed/checkpointmanifest-log-valid-bytes manifest)
   source (triple-log-prefix-source-at! canonical revision expected-valid-bytes)
   ^String space-id (:space-id source)
   sequence (:sequence source)
   valid-bytes (:valid-bytes source)
   ^String fingerprint (:fingerprint source)]
  (if (not (= sequence revision)) (do
  (fail! :packed-source-mismatch "packed checkpoint revision is not a STORELOG boundary" {:manifest (packed/checkpointmanifest-path manifest) :revision revision :storelog-sequence sequence})))
  (packed/checkpoint-source! space-id revision valid-bytes fingerprint)))

(defn- checkpoint-source-for-revision! [^String canonical revision]
  (let [source (triple-log-prefix-source! canonical revision)
   ^String space-id (:space-id source)
   sequence (:sequence source)
   valid-bytes (:valid-bytes source)
   ^String fingerprint (:fingerprint source)]
  (if (not (= sequence revision)) (do
  (fail! :packed-source-mismatch "live Store revision is not a STORELOG boundary" {:revision revision :storelog-sequence sequence})))
  (packed/checkpoint-source! space-id revision valid-bytes fingerprint)))

(defn- truncate-log! [path length]
  (with-open [file (java.io.RandomAccessFile. (str path) "rw")]
  (.setLength file length)
  (.force (.getChannel file) true)))

(def ^String fork-marker-suffix ".fork")

(def ^String fork-pending-suffix ".fork-new")

(def ^String reseal-marker-suffix ".reseal")

(def ^String reseal-pending-suffix ".reseal-new")

(defn- fork-marker-path [store]
  (str store fork-marker-suffix))

(defn- fork-pending-path [path]
  (str path fork-pending-suffix))

(defn- reseal-marker-path [store]
  (str store reseal-marker-suffix))

(defn- reseal-pending-path [path]
  (str path reseal-pending-suffix))

(defn- read-fork-marker! [store]
  (let [file (java.io.File. (str (fork-marker-path store)))]
  (if (.isFile file) (do
  (branch/parse-fork-marker (strict-utf8-string! (Files/readAllBytes (.toPath file)) "fork marker"))))))

(defn- read-reseal-marker! [store]
  (let [file (java.io.File. (str (reseal-marker-path store)))]
  (if (.isFile file) (do
  (branch/parse-reseal-marker (strict-utf8-string! (Files/readAllBytes (.toPath file)) "reseal marker"))))))

(defn- require-no-pending-fork! [store]
  (if (.exists (java.io.File. (str (fork-marker-path store)))) (do
  (fail! :fork-incomplete "a fork of this store was interrupted and has not been completed" {:path (str store) :marker (fork-marker-path store)})))
  (if (.exists (java.io.File. (str (reseal-marker-path store)))) (do
  (fail! :reseal-incomplete "a reseal of this store was interrupted and has not been completed" {:path (str store) :marker (reseal-marker-path store)}))))

(defn open-database!
  "Open a Store transaction log-backed TermStore. A passive reader reports a torn trailing\n   record and refuses later writes. An authority-holding caller may pass\n   {:repair-torn? true}; only the last incomplete record is truncated."
  ([path]
    (open-database! path nil {}))
  ([path expected-space]
    (open-database! path expected-space {}))
  ([path expected-space {:keys [repair-torn? tail-row-limit tail-byte-limit] :or {repair-torn? false tail-row-limit term-store/default-tail-row-limit tail-byte-limit term-store/default-tail-byte-limit}}]
    (let [^String canonical (.getPath (.getCanonicalFile (java.io.File. (str path))))
   _ (require-no-pending-fork! canonical)
   selected (checkpoint/select-boot! (packed-checkpoint-directory canonical) (fn [manifest] (checkpoint-source-for-manifest! canonical manifest)) tail-row-limit tail-byte-limit)
   packed-context (:context selected)
   source-record (:source-record selected)
   parsed (if packed-context (read-triple-log-suffix! canonical source-record) (read-triple-log! canonical))
   ^String space-id (:space-id parsed)
   context (or packed-context (term-store/new-term-store-with-tail-limits space-id tail-row-limit tail-byte-limit))]
  (if (and expected-space (not= expected-space space-id)) (do
  (fail! :space-mismatch "Store transaction log belongs to a different SpaceId" {:expected expected-space :actual space-id :path canonical})))
  (let [_replay (replay-records! context (:records parsed))]
  (if (and (:torn-tail parsed) repair-torn?) (do
  (truncate-log! canonical (:valid-bytes parsed))))
  {:term-store context :space-id space-id :deflate? (:deflate? parsed) :log canonical :lock (Object.) :mutation-state (atom {:status :ready}) :storage-source (:source selected) :packed-manifest (:selected-manifest selected) :packed-prefix-records (:prefix-records selected) :packed-suffix-records (count (:records parsed)) :packed-decoded-from-byte (:decoded-from-byte parsed) :packed-decoded-record-count (:decoded-record-count parsed) :packed-rejections (:rejections selected) :torn-tail (if (not repair-torn?) (do
  (:torn-tail parsed))) :recovered-tail (if repair-torn? (do
  (:torn-tail parsed)))}))))

(defn- bytes-hex [content]
  (apply str (map (fn [%1] (format "%02x" (bit-and %1 255))) content)))

(defn- sha256-hex [content]
  (bytes-hex (.digest (MessageDigest/getInstance "SHA-256") content)))

(defn- ensure-directory! [path]
  (Files/createDirectories (.toPath (java.io.File. (str path))) (make-array java.nio.file.attribute.FileAttribute 0))
  (str path))

(defn- move-atomically! [source target]
  (Files/move (.toPath (java.io.File. (str source))) (.toPath (java.io.File. (str target))) (into-array java.nio.file.CopyOption [StandardCopyOption/ATOMIC_MOVE StandardCopyOption/REPLACE_EXISTING]))
  (str target))

(defn- write-text-durable! [path text]
  (let [content (strict-utf8-bytes! text "branch ref")
   temporary (str path ".tmp")]
  (with-open [file-out (java.io.FileOutputStream. (str temporary))
   out (java.io.BufferedOutputStream. file-out)]
  (.write out content)
  (.flush out)
  (.force (.getChannel file-out) true))
  (move-atomically! temporary path)))

(defn- write-bytes-durable! [path content]
  (let [temporary (str path ".tmp")]
  (with-open [file-out (java.io.FileOutputStream. (str temporary))
   out (java.io.BufferedOutputStream. file-out)]
  (.write out content)
  (.flush out)
  (.force (.getChannel file-out) true))
  (move-atomically! temporary path)))

(defn- branch-control-path [store]
  (str store ".branch-control"))

(def ^String branch-watch-format "store-watch/v1")

(defn- branch-watch-path [store branch-name]
  (str store ".watches/" (branch/require-branch-name! branch-name)))

(defn- valid-ref-identity? [value]
  (and (string? value) (some? (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- watch-head [document]
  (let [event (last (:events document))]
  (if event (:current event) (:anchor document))))

(defn- watch-line [kind event]
  (str kind " " (:cursor event) " " (:previous event) " " (:current event) "\n"))

(defn- print-watch-document! [document]
  (let [body (str branch-watch-format "\n" "anchor " (:anchor document) "\n" (apply str (map (fn [%1] (watch-line "event" %1)) (:events document))) (let [pending (:pending document)]
  (if pending (do
  (watch-line "pending" pending)))))]
  (str body "sha256 " (sha256-hex (strict-utf8-bytes! body "branch watch")) "\n")))

(defn- parse-watch-cursor! [value]
  (if (not (some? (re-matches #"(?:0|[1-9][0-9]{0,17})" value))) (do
  (fail! :invalid-branch-watch "branch watch cursor is not canonical" {:cursor value})))
  (Long/parseLong value))

(defn- parse-watch-transition! [line expected-kind]
  (let [fields (vec (str/split line #" "))]
  (if (not (and (= 4 (count fields)) (= expected-kind (nth fields 0)))) (do
  (fail! :invalid-branch-watch "branch watch transition is malformed" {:line line})))
  (let [event {:cursor (parse-watch-cursor! (nth fields 1)) :previous (nth fields 2) :current (nth fields 3)}]
  (if (not (and (valid-ref-identity? (:previous event)) (valid-ref-identity? (:current event)) (not= (:previous event) (:current event)))) (do
  (fail! :invalid-branch-watch "branch watch transition identities are invalid" {:line line})))
  event)))

(defn- parse-watch-document! [text]
  (let [lines (vec (str/split-lines text))]
  (if (< (count lines) 3) (do
  (fail! :invalid-branch-watch "branch watch document is incomplete" {})))
  (if (not (= branch-watch-format (first lines))) (do
  (fail! :unsupported-branch-watch-version "branch watch document version is unsupported" {:format (first lines)})))
  (if (not (str/starts-with? (nth lines 1) "anchor ")) (do
  (fail! :invalid-branch-watch "branch watch document has no anchor" {})))
  (let [anchor (subs (nth lines 1) 7)
   digest-line (last lines)
   content-lines (subvec lines 2 (dec (count lines)))
   body (apply str (map (fn [%1] (str %1 "\n")) (butlast lines)))]
  (if (not (valid-ref-identity? anchor)) (do
  (fail! :invalid-branch-watch "branch watch anchor is invalid" {:anchor anchor})))
  (if (not (= digest-line (str "sha256 " (sha256-hex (strict-utf8-bytes! body "branch watch"))))) (do
  (fail! :invalid-branch-watch "branch watch digest does not match" {})))
  (loop [remaining content-lines
   previous anchor
   cursor 0
   events []]
  (if (empty? remaining) {:anchor anchor :events events :pending nil} (let [line (first remaining)
   pending? (str/starts-with? line "pending ")
   event (parse-watch-transition! line (if pending? "pending" "event"))]
  (if (not (and (= (:cursor event) (inc cursor)) (= (:previous event) previous))) (do
  (fail! :invalid-branch-watch "branch watch transitions are not contiguous" {:cursor (:cursor event) :previous (:previous event)})))
  (if pending? (if (next remaining) (fail! :invalid-branch-watch "branch watch pending transition is not last" {}) {:anchor anchor :events events :pending event}) (recur (next remaining) (:current event) (:cursor event) (conj events event)))))))))

(defn- read-watch-document! [store branch-name]
  (let [path (branch-watch-path store branch-name)
   file (java.io.File. path)]
  (if (.isFile file) (do
  (parse-watch-document! (strict-utf8-string! (Files/readAllBytes (.toPath file)) "branch watch"))))))

(defn- write-watch-document! [store branch-name document]
  (ensure-directory! (str store ".watches"))
  (write-text-durable! (branch-watch-path store branch-name) (print-watch-document! document))
  document)

(defn- reconcile-watch! [store branch-name current-identity]
  (let [stored (read-watch-document! store branch-name)
   document (or stored {:anchor current-identity :events [] :pending nil})
   pending (:pending document)
   resolved (cond
  (nil? pending) document
  (= current-identity (:current pending)) (-> document (update :events conj pending) (assoc :pending nil))
  (= current-identity (:previous pending)) (assoc document :pending nil)
  :else (fail! :invalid-branch-watch "branch ref matches neither side of its pending watch transition" {:branch branch-name :current current-identity :pending pending}))
   head (watch-head resolved)
   reconciled (if (= head current-identity) resolved (update resolved :events conj {:cursor (inc (long (or (:cursor (last (:events resolved))) 0))) :previous head :current current-identity}))]
  (if (= stored reconciled) reconciled (write-watch-document! store branch-name reconciled))))

(defn- prepare-watch-transition! [store branch-name current candidate]
  (let [document (reconcile-watch! store branch-name current)]
  (if (= current candidate) document (write-watch-document! store branch-name (assoc document :pending {:cursor (inc (long (or (:cursor (last (:events document))) 0))) :previous current :current candidate})))))

(defn- acquire-branch-control! [store]
  (let [deadline (+ (System/nanoTime) 2000000000)]
  (loop []
  (let [held (writer-authority/try-acquire! (branch-control-path store))]
  (if held held (if (>= (System/nanoTime) deadline) (fail! :writer-authority-held "another branch operation holds this store" {:path store :lock (writer-authority/authority-path (branch-control-path store))}) (do
  (Thread/sleep 1)
  (recur))))))))

(defn read-branch-ref!
  "Read a branch ref, or nil when the branch has no sealed chain on disk." [store-path branch]
  (let [file (java.io.File. (str (branch/ref-path! (str store-path) branch)))]
  (if (.isFile file) (do
  (branch/parse-ref (strict-utf8-string! (Files/readAllBytes (.toPath file)) "branch ref"))))))

(defn branch-ref-identity!
  "Name the exact canonical bytes of a branch's current ref document." [store-path branch-name]
  (let [document (read-branch-ref! store-path branch-name)]
  (if document (do
  (branch/ref-identity document)))))

(defn branch-transitions-since!
  "Read durable ref transitions after CURSOR. A missing journal is anchored at\n   the current ref; a prepared transition becomes visible only after its ref is\n   durable. The returned cursor may be supplied unchanged to resume without a\n   gap or duplicate." [store-path branch-name cursor]
  (if (not (and (integer? cursor) (<= 0 cursor) (<= cursor Long/MAX_VALUE))) (do
  (fail! :invalid-watch-cursor "branch watch cursor must be non-negative" {:cursor cursor})))
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   selected (branch/require-branch-name! branch-name)
   held (acquire-branch-control! store)]
  (try
  (require-no-pending-fork! store)
  (let [current (branch-ref-identity! store selected)]
  (if (nil? current) (do
  (fail! :branch-missing "branch has no ref" {:branch selected :path (branch/ref-path! store selected)})))
  (let [document (reconcile-watch! store selected current)
   head-cursor (long (or (:cursor (last (:events document))) 0))]
  (if (> cursor head-cursor) (do
  (fail! :watch-cursor-ahead "branch watch cursor is ahead of durable history" {:cursor cursor :head head-cursor})))
  {:cursor head-cursor :transitions (vec (filter (fn [%1] (> (:cursor %1) cursor)) (:events document)))}))
  (finally
    (writer-authority/release! held)))))

(defn watch-branch!
  "Wait up to TIMEOUT-MS for at least one durable transition after CURSOR." [store-path branch-name cursor timeout-ms]
  (if (not (and (integer? timeout-ms) (<= 0 timeout-ms) (<= timeout-ms 60000))) (do
  (fail! :invalid-watch-timeout "branch watch timeout must be between zero and 60000 milliseconds" {:timeout-ms timeout-ms})))
  (let [deadline (+ (System/nanoTime) (* (long timeout-ms) 1000000))]
  (loop []
  (let [result (branch-transitions-since! store-path branch-name cursor)]
  (if (or (seq (:transitions result)) (>= (System/nanoTime) deadline)) result (do
  (Thread/sleep 5)
  (recur)))))))

(defn- chain-member [parsed byte-count]
  (branch/->ChainMember (long (or (:tx-seq (first (:records parsed))) 0)) (long (or (:tx-seq (last (:records parsed))) 0)) (long byte-count) (boolean (:continuation? parsed)) (:space-id parsed) (some? (:torn-tail parsed))))

(defn branch-chain-fault
  "Validate hosted branch metadata through the canonical Native Core rules." [document members tail]
  (if (not= (count (branch/refdocument-segments document)) (count members)) "Store transaction log branch ref does not name the segments that were read" (loop [index 0
   expected-next 1]
  (if (>= index (count members)) (chain-rules/tail-member-fault (count members) (branch/refdocument-space-id document) (branch/chainmember-space-id tail) (branch/chainmember-start-sequence tail) (branch/chainmember-continuation tail) expected-next) (let [segment (nth (branch/refdocument-segments document) index)
   member (nth members index)
   fault (chain-rules/sealed-member-fault index (branch/refdocument-space-id document) (branch/chainmember-space-id member) (branch/segmentrecord-start-sequence segment) (branch/chainmember-start-sequence member) (branch/segmentrecord-end-sequence segment) (branch/chainmember-end-sequence member) (branch/segmentrecord-byte-count segment) (branch/chainmember-byte-count member) (branch/chainmember-continuation member) (branch/chainmember-torn member) expected-next)]
  (if fault fault (recur (inc index) (chain-rules/next-expected (branch/chainmember-end-sequence member) expected-next))))))))

(defn- read-chain-source! [path allow-continuation?]
  (let [file (.getCanonicalFile (java.io.File. (str path)))]
  (if (not (.isFile file)) (do
  (fail! :triple-log-missing "Store transaction log source is missing" {:path (.getPath file)})))
  (let [bytes (Files/readAllBytes (.toPath file))
   parsed (parse-triple-log-bytes! bytes (.getPath file) allow-continuation?)]
  {:path (.getPath file) :bytes bytes :parsed parsed :member (chain-member parsed (alength bytes))})))

(defn- read-chain-member! [path]
  (let [source (read-chain-source! path true)]
  [(:parsed source) (:member source)]))

(defn- require-segment-identity! [segment source]
  (let [expected (branch/segmentrecord-sha256 segment)
   actual (sha256-hex (:bytes source))]
  (if (not (= expected actual)) (do
  (fail! :segment-digest-mismatch "sealed Store transaction log segment does not match its content address" {:path (:path source) :expected expected :actual actual})))))

(defn- require-uncompressed-branch-source! [source]
  (if (:deflate? (:parsed source)) (do
  (fail! :unsupported-branch-chain-encoding "branch routing does not support Deflate-compressed Store transaction log members" {:path (:path source)})))
  source)

(defn- require-ref-chain! [store selected document]
  (let [segments (branch/refdocument-segments document)
   sealed (mapv (fn [segment] [segment (read-chain-source! (branch/segment-path store (branch/segmentrecord-sha256 segment)) true)]) segments)
   tail (read-chain-source! (branch/branch-tail-path! store selected) true)
   fault (branch-chain-fault document (mapv (comp :member second) sealed) (:member tail))]
  (doseq [[_ source] sealed]
  (require-uncompressed-branch-source! source))
  (require-uncompressed-branch-source! tail)
  (if fault (do
  (fail! :invalid-branch-chain fault {:branch selected :path (:path tail) :ref (branch/ref-path! store selected)})))
  (doseq [[segment source] sealed]
  (require-segment-identity! segment source))
  {:sealed sealed :tail tail}))

(defn- history-sha256 [sources]
  (let [^MessageDigest digest (MessageDigest/getInstance "SHA-256")]
  (doseq [source sources]
  (let [parsed (:parsed source)
   start (int (:header-bytes parsed))
   end (int (:valid-bytes parsed))]
  (.update digest (:bytes source) start (- end start))))
  (bytes-hex (.digest digest))))

(defn compare-and-set-branch-ref!
  "Replace one branch ref only when EXPECTED-IDENTITY still names its exact\n   canonical bytes. CANDIDATE is verified against every content-addressed\n   segment and the branch's current tail before the durable ref replacement." [store-path branch-name expected-identity candidate]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   selected (branch/require-branch-name! branch-name)
   held (acquire-branch-control! store)]
  (try
  (require-no-pending-fork! store)
  (let [current (read-branch-ref! store selected)]
  (if (nil? current) (do
  (fail! :branch-missing "branch has no ref" {:branch selected :path (branch/ref-path! store selected)})))
  (let [current-identity (branch/ref-identity current)]
  (if (not= expected-identity current-identity) {:swapped? false :expected expected-identity :current current-identity} (do
  (if (not= (branch/refdocument-space-id current) (branch/refdocument-space-id candidate)) (do
  (fail! :space-mismatch "candidate branch ref belongs to a different SpaceId" {:expected (branch/refdocument-space-id current) :actual (branch/refdocument-space-id candidate) :branch selected})))
  (require-ref-chain! store selected candidate)
  (let [candidate-identity (branch/ref-identity candidate)]
  (prepare-watch-transition! store selected current-identity candidate-identity)
  (write-text-durable! (branch/ref-path! store selected) (branch/print-ref candidate))
  (reconcile-watch! store selected candidate-identity)
  {:swapped? true :expected expected-identity :previous current-identity :current candidate-identity})))))
  (finally
    (writer-authority/release! held)))))

(defn branch-revision!
  "Name one exact committed point on a branch from durable history. The branch\n   name is routing, not identity: equal sealed chains and tail prefixes have the\n   same revision even when reached through different refs."
  ([store-path]
    (branch-revision! store-path branch/default-branch))
  ([store-path branch-name]
    (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   selected (branch/require-branch-name! branch-name)
   _ (require-no-pending-fork! store)
   document (read-branch-ref! store selected)]
  (cond
  (and (nil? document) (= selected branch/default-branch)) (let [tail (read-chain-source! store false)
   parsed (:parsed tail)
   sequence (long (or (:tx-seq (last (:records parsed))) 0))]
  (require-uncompressed-branch-source! tail)
  (branch/branch-revision! (:space-id parsed) (history-sha256 [tail]) sequence))
  (nil? document) (fail! :branch-missing "branch has no ref" {:branch selected :path (branch/ref-path! store selected)})
  :else (let [segments (branch/refdocument-segments document)
   sealed (mapv (fn [segment] [segment (read-chain-source! (branch/segment-path store (branch/segmentrecord-sha256 segment)) true)]) segments)
   tail (read-chain-source! (branch/branch-tail-path! store selected) true)
   parsed (:parsed tail)
   fault (branch-chain-fault document (mapv (comp :member second) sealed) (:member tail))]
  (doseq [[_ source] sealed]
  (require-uncompressed-branch-source! source))
  (require-uncompressed-branch-source! tail)
  (if fault (do
  (fail! :invalid-branch-chain fault {:branch selected :path (:path tail) :ref (branch/ref-path! store selected)})))
  (doseq [[segment source] sealed]
  (require-segment-identity! segment source))
  (let [sequence (long (or (:tx-seq (last (:records parsed))) (branch/chain-end-sequence document)))]
  (branch/branch-revision! (branch/refdocument-space-id document) (history-sha256 (conj (mapv second sealed) tail)) sequence)))))))

(defn open-branch!
  "Open one branch of a store: fold its sealed segment chain in ref order, then\n   its tail. A store with no ref for the default branch boots exactly as an\n   unforked Store transaction log does."
  ([store-path branch]
    (open-branch! store-path branch nil {}))
  ([store-path branch expected-space]
    (open-branch! store-path branch expected-space {}))
  ([store-path branch expected-space {:keys [repair-torn?] :or {repair-torn? false}}]
    (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   _ (require-no-pending-fork! store)
   document (read-branch-ref! store branch)]
  (cond
  (and (nil? document) (= branch branch/default-branch)) (do
  (require-uncompressed-branch-source! (read-chain-source! store false))
  (open-database! store expected-space {:repair-torn? repair-torn?}))
  (nil? document) (fail! :branch-missing "branch has no ref" {:branch branch :path (branch/ref-path! store branch)})
  :else (let [tail-path (branch/branch-tail-path! store branch)
   space-id (branch/refdocument-space-id document)
   {:keys [sealed tail]} (require-ref-chain! store branch document)
   tail-parsed (:parsed tail)]
  (if (and expected-space (not= expected-space space-id)) (do
  (fail! :space-mismatch "Store transaction log belongs to a different SpaceId" {:expected expected-space :actual space-id :branch branch})))
  (let [context (term-store/new-term-store space-id)]
  (doseq [[_ source] sealed]
  (replay-records! context (:records (:parsed source))))
  (replay-records! context (:records tail-parsed))
  (if (and (:torn-tail tail-parsed) repair-torn?) (do
  (truncate-log! tail-path (:valid-bytes tail-parsed))))
  {:term-store context :space-id space-id :deflate? (:deflate? tail-parsed) :log tail-path :branch branch :segments (mapv branch/segmentrecord-sha256 (branch/refdocument-segments document)) :lock (Object.) :mutation-state (atom {:status :ready}) :torn-tail (if (not repair-torn?) (do
  (:torn-tail tail-parsed))) :recovered-tail (if repair-torn? (do
  (:torn-tail tail-parsed)))}))))))

(defn- delete-file! [path]
  (Files/deleteIfExists (.toPath (java.io.File. (str path)))))

(defn- install-pending! [pending target]
  (if (.exists (java.io.File. (str pending))) (do
  (move-atomically! pending target))))

(defn- complete-reseal! [store marker]
  (let [selected (branch/resealmarker-branch marker)
   tail-path (branch/branch-tail-path! store selected)
   ref-path (branch/ref-path! store selected)
   pending-tail (reseal-pending-path tail-path)
   pending-ref (reseal-pending-path ref-path)
   candidate-tail-path (if (.isFile (java.io.File. pending-tail)) pending-tail tail-path)
   candidate-ref-path (if (.isFile (java.io.File. pending-ref)) pending-ref ref-path)
   document (branch/parse-ref (strict-utf8-string! (Files/readAllBytes (.toPath (java.io.File. candidate-ref-path))) "reseal candidate ref"))
   expected-segment (branch/resealmarker-segment marker)
   expected-ref (branch/resealmarker-ref-identity marker)
   segments (branch/refdocument-segments document)]
  (if (not (and (= expected-ref (branch/ref-identity document)) (= 1 (count segments)) (= expected-segment (branch/segmentrecord-sha256 (first segments))))) (do
  (fail! :invalid-reseal-recovery "reseal recovery files do not match the durable marker" {:branch selected :segment expected-segment :ref-identity expected-ref})))
  (let [segment (first segments)
   segment-source (read-chain-source! (branch/segment-path store expected-segment) true)
   tail-source (read-chain-source! candidate-tail-path true)
   fault (branch-chain-fault document [(:member segment-source)] (:member tail-source))]
  (require-segment-identity! segment segment-source)
  (if fault (do
  (fail! :invalid-reseal-recovery fault {:branch selected :segment expected-segment :ref-identity expected-ref}))))
  (install-pending! pending-tail tail-path)
  (install-pending! pending-ref ref-path)
  (require-ref-chain! store selected document)
  (reconcile-watch! store selected expected-ref)
  (delete-file! (branch/snapshot-path tail-path))
  (delete-file! (reseal-marker-path store))
  {:branch selected :segments 1 :segment expected-segment :ref-identity expected-ref :recovered? true}))

(defn- complete-fork! [store marker]
  (let [parent (branch/forkmarker-parent marker)
   child (branch/forkmarker-child marker)
   parent-tail (branch/branch-tail-path! store parent)
   child-tail (branch/branch-tail-path! store child)
   parent-ref (branch/ref-path! store parent)
   child-ref (branch/ref-path! store child)
   sealed (branch/segment-path store (branch/forkmarker-segment marker))]
  (if (not (.exists (java.io.File. (str sealed)))) (do
  (move-atomically! parent-tail sealed)))
  (install-pending! (fork-pending-path parent-tail) parent-tail)
  (install-pending! (fork-pending-path parent-ref) parent-ref)
  (install-pending! (fork-pending-path child-ref) child-ref)
  (install-pending! (fork-pending-path child-tail) child-tail)
  (delete-file! (branch/snapshot-path parent-tail))
  (delete-file! (fork-marker-path store))
  nil))

(defn- acquire-fork-authority! [paths]
  (reduce (fn [held path] (let [handle (writer-authority/try-acquire! path)]
  (if handle (conj held handle) (do
  (doseq [previous held]
  (writer-authority/release! previous))
  (fail! :writer-authority-held "a writer holds this store; fork runs offline only" {:path path :lock (writer-authority/authority-path path)}))))) [] paths))

(def retention-root-kinds {:pin "pins" :checkpoint "checkpoints" :session "sessions"})

(defn- require-retention-root-kind! [kind]
  (let [directory (get retention-root-kinds kind)]
  (if directory directory (fail! :invalid-retention-root-kind "retention root kind must be :pin, :checkpoint, or :session" {:kind kind}))))

(defn- require-retention-root-name! [root-name]
  (if (and (string? root-name) (branch/valid-branch-name? root-name)) root-name (fail! :invalid-retention-root-name "retention root name is not a usable durable file name" {:name root-name})))

(defn- retention-roots-directory [store]
  (str store ".roots"))

(defn- retention-kind-directory! [store kind]
  (str (retention-roots-directory store) "/" (require-retention-root-kind! kind)))

(defn- retention-root-path! [store kind root-name]
  (str (retention-kind-directory! store kind) "/" (require-retention-root-name! root-name)))

(defn- directory-entries! [path label]
  (let [directory (java.io.File. (str path))]
  (cond
  (not (.exists directory)) []
  (not (.isDirectory directory)) (fail! :invalid-retention-layout (str label " is not a directory") {:path (.getPath directory)})
  :else (let [entries (.listFiles directory)]
  (if (nil? entries) (do
  (fail! :retention-io-failure (str label " could not be enumerated") {:path (.getPath directory)})))
  (vec entries)))))

(defn- regular-document-files! [path label]
  (let [entries (directory-entries! path label)]
  (doseq [entry entries]
  (if (not (.isFile entry)) (do
  (fail! :invalid-retention-layout (str label " contains a non-document entry") {:path (.getPath entry)}))))
  (vec (sort-by (fn [%1] (.getName %1)) entries))))

(defn- read-ref-document-file! [^File file label]
  (branch/parse-ref (strict-utf8-string! (Files/readAllBytes (.toPath file)) label)))

(defn- require-sealed-document! [store store-space source document]
  (if (not (= store-space (branch/refdocument-space-id document))) (do
  (fail! :space-mismatch "retention root belongs to a different SpaceId" {:path source :expected store-space :actual (branch/refdocument-space-id document)})))
  (loop [index 0
   expected-next 1
   segments (branch/refdocument-segments document)]
  (let [segment (first segments)]
  (if segment (do
  (let [segment-source (read-chain-source! (branch/segment-path store (branch/segmentrecord-sha256 segment)) true)
   member (:member segment-source)
   fault (chain-rules/sealed-member-fault index store-space (branch/chainmember-space-id member) (branch/segmentrecord-start-sequence segment) (branch/chainmember-start-sequence member) (branch/segmentrecord-end-sequence segment) (branch/chainmember-end-sequence member) (branch/segmentrecord-byte-count segment) (branch/chainmember-byte-count member) (branch/chainmember-continuation member) (branch/chainmember-torn member) expected-next)]
  (if fault (do
  (fail! :invalid-retention-root fault {:path source :segment (branch/segmentrecord-sha256 segment)})))
  (require-segment-identity! segment segment-source)
  (recur (inc index) (chain-rules/next-expected (branch/chainmember-end-sequence member) expected-next) (next segments)))))))
  document)

(defn- store-space-id! [store]
  (:space-id (:parsed (read-chain-source! store true))))

(defn- with-retention-authority! [store operation]
  (let [held (acquire-fork-authority! [store])]
  (try
  (let [held-control (acquire-branch-control! store)]
  (try
  (operation)
  (finally
    (writer-authority/release! held-control))))
  (finally
    (doseq [handle held]
  (writer-authority/release! handle))))))

(defn retain-branch-root!
  "Durably retain every sealed segment named by DOCUMENT as a pin, checkpoint,\n   or active session root. The root stores canonical store-ref/v1 facts rather\n   than a pointer to mutable branch routing." [store-path kind root-name document]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   selected-kind (keyword kind)
   selected-name (require-retention-root-name! root-name)]
  (with-retention-authority! store (fn [] (require-no-pending-fork! store)
  (let [root-path (retention-root-path! store selected-kind selected-name)
   store-space (store-space-id! store)
   canonical (branch/parse-ref (branch/print-ref document))
   verified (require-sealed-document! store store-space root-path canonical)]
  (ensure-directory! (retention-kind-directory! store selected-kind))
  (write-text-durable! root-path (branch/print-ref verified))
  {:kind selected-kind :name selected-name :ref-identity (branch/ref-identity verified) :segments (mapv branch/segmentrecord-sha256 (branch/refdocument-segments verified))})))))

(defn release-branch-root!
  "Release one named durable pin, checkpoint, or active session root. Segments\n   become reclaimable only after a later reachability collection proves that no\n   remaining root names them." [store-path kind root-name]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   selected-kind (keyword kind)
   selected-name (require-retention-root-name! root-name)]
  (with-retention-authority! store (fn [] (require-no-pending-fork! store)
  {:kind selected-kind :name selected-name :released? (boolean (delete-file! (retention-root-path! store selected-kind selected-name)))}))))

(defn- reachability-documents! [store]
  (let [heads (mapv (fn [file] (branch/require-branch-name! (.getName file))
  [(.getPath file) (read-ref-document-file! file "branch head")]) (regular-document-files! (branch/refs-directory store) "branch refs directory"))
   roots-directory (retention-roots-directory store)
   root-entries (directory-entries! roots-directory "retention roots directory")
   known-directories (set (vals retention-root-kinds))]
  (doseq [entry root-entries]
  (if (not (and (.isDirectory entry) (contains? known-directories (.getName entry)))) (do
  (fail! :invalid-retention-layout "retention roots directory contains an unknown entry" {:path (.getPath entry)}))))
  (into heads (mapcat (fn [[kind directory]] (mapv (fn [file] (require-retention-root-name! (.getName file))
  [(.getPath file) (read-ref-document-file! file (str (name kind) " retention root"))]) (regular-document-files! (str roots-directory "/" directory) (str (name kind) " retention roots directory")))) (sort-by (comp str key) retention-root-kinds)))))

(defn collect-unreachable-segments!
  "Delete content-addressed segment objects unreachable from every current\n   branch head, durable pin, checkpoint, and active session root. Every root\n   document and every segment it names is parsed and verified before the first\n   deletion. Files outside the 64-hex segment namespace are never collected." [store-path]
  (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))]
  (with-retention-authority! store (fn [] (require-no-pending-fork! store)
  (let [store-space (store-space-id! store)
   documents (reachability-documents! store)
   verified (mapv (fn [[source document]] (require-sealed-document! store store-space source document)) documents)
   reachable (->> verified (mapcat branch/refdocument-segments) (map branch/segmentrecord-sha256) set)
   segment-files (->> (directory-entries! (branch/segments-directory store) "segments directory") (filter (fn [%1] (.isFile %1))) (filter (fn [%1] (branch/valid-segment-name? (.getName %1)))) (sort-by (fn [%1] (.getName %1))) vec)
   collected (->> segment-files (remove (fn [%1] (contains? reachable (.getName %1)))) (mapv (fn [%1] (.getName %1))))]
  (doseq [segment collected]
  (delete-file! (branch/segment-path store segment)))
  {:reachable (vec (sort reachable)) :collected collected :retained (count reachable)})))))

(defn- combined-history-bytes! [sources]
  (let [first-source (first sources)
   first-parsed (:parsed first-source)
   deflate? (:deflate? first-parsed)
   out (java.io.ByteArrayOutputStream.)]
  (if (some (fn [%1] (not= deflate? (:deflate? (:parsed %1)))) sources) (do
  (fail! :incompatible-chain-encoding "reseal requires one record encoding across the branch chain" {})))
  (.write out (:bytes first-source) 0 (int (:header-bytes first-parsed)))
  (doseq [source sources]
  (let [parsed (:parsed source)
   start (int (:header-bytes parsed))
   end (int (:valid-bytes parsed))]
  (.write out (:bytes source) start (- end start))))
  (.toByteArray out)))

(defn- reseal-branch-under-authority! [store selected]
  (let [held-control (acquire-branch-control! store)]
  (try
  (let [pending (read-reseal-marker! store)]
  (if pending (if (= selected (branch/resealmarker-branch pending)) (complete-reseal! store pending) (fail! :reseal-incomplete "another branch has an interrupted reseal" {:branch selected :pending-branch (branch/resealmarker-branch pending) :marker (reseal-marker-path store)})) (do
  (require-no-pending-fork! store)
  (let [document (read-branch-ref! store selected)]
  (if (nil? document) (do
  (fail! :branch-missing "reseal requires a branch ref" {:branch selected :path (branch/ref-path! store selected)})))
  (let [{:keys [sealed tail]} (require-ref-chain! store selected document)
   sources (conj (mapv second sealed) tail)
   tail-parsed (:parsed tail)]
  (if (:torn-tail tail-parsed) (do
  (fail! :torn-tail-repair-required "reseal requires a branch tail with no torn trailing record" {:branch selected :path (:path tail)})))
  (let [content (combined-history-bytes! sources)
   parsed (parse-triple-log-bytes! content "resealed segment")
   records (:records parsed)
   record (branch/->SegmentRecord (sha256-hex content) (long (or (:tx-seq (first records)) 0)) (long (or (:tx-seq (last records)) 0)) (long (alength content)))
   candidate (branch/->RefDocument (branch/refdocument-space-id document) [record])
   current-identity (branch/ref-identity document)
   candidate-identity (branch/ref-identity candidate)
   marker (branch/->ResealMarker selected (branch/segmentrecord-sha256 record) candidate-identity)
   tail-path (branch/branch-tail-path! store selected)
   ref-path (branch/ref-path! store selected)
   pending-tail (reseal-pending-path tail-path)
   pending-ref (reseal-pending-path ref-path)
   segment-path (branch/segment-path store (branch/segmentrecord-sha256 record))]
  (ensure-directory! (branch/segments-directory store))
  (doseq [path [pending-tail pending-ref]]
  (delete-file! path))
  (write-bytes-durable! segment-path content)
  (create-triple-log! pending-tail (branch/refdocument-space-id document) {:deflate? (:deflate? parsed) :continuation? true})
  (write-text-durable! pending-ref (branch/print-ref candidate))
  (prepare-watch-transition! store selected current-identity candidate-identity)
  (write-text-durable! (reseal-marker-path store) (branch/print-reseal-marker marker))
  (assoc (complete-reseal! store marker) :previous-segments (count (branch/refdocument-segments document)) :sequence (long (or (:tx-seq (last records)) 0)) :recovered? false)))))))
  (finally
    (writer-authority/release! held-control)))))

(defn reseal-branch!
  "Compact one branch's complete committed history into one content-addressed\n   base segment and a fresh continuation tail. Runs offline under store and\n   tail writer authority; the v2 branch revision is unchanged."
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
    (doseq [handle held]
  (writer-authority/release! handle)))))))

(defn fork-store!
  "Seal the parent branch's tail into the shared segment chain and give parent\n   and child fresh continuation tails that both begin at the next sequence.\n   Offline: fork holds writer authority over the store and both tails for its\n   whole run, and refuses rather than rename a log a writer still holds."
  ([store-path child-branch]
    (fork-store! store-path branch/default-branch child-branch))
  ([store-path parent-branch child-branch]
    (let [store (.getPath (.getCanonicalFile (java.io.File. (str store-path))))
   parent (branch/require-branch-name! parent-branch)
   child (branch/require-branch-name! child-branch)
   parent-tail (branch/branch-tail-path! store parent)
   child-tail (branch/branch-tail-path! store child)]
  (if (= parent child) (do
  (fail! :invalid-branch-name "fork requires two different branch names" {:branch parent})))
  (let [held (acquire-fork-authority! (distinct [store parent-tail child-tail]))]
  (try
  (let [pending (read-reseal-marker! store)]
  (if pending (do
  (if (= parent (branch/resealmarker-branch pending)) (let [held-control (acquire-branch-control! store)]
  (try
  (complete-reseal! store pending)
  (finally
    (writer-authority/release! held-control)))) (fail! :reseal-incomplete "another branch has an interrupted reseal" {:branch parent :pending-branch (branch/resealmarker-branch pending) :marker (reseal-marker-path store)})))))
  (let [pending (read-fork-marker! store)]
  (if pending (do
  (complete-fork! store pending))))
  (doseq [path [child-tail (branch/ref-path! store child)]]
  (if (.exists (java.io.File. (str path))) (do
  (fail! :branch-exists "fork child branch already exists" {:branch child :path path}))))
  (let [known (read-branch-ref! store parent)
   _ (if (and known (>= (count (branch/refdocument-segments known)) branch/reseal-chain-length)) (do
  (reseal-branch-under-authority! store parent)))
   document (read-branch-ref! store parent)]
  (if (and (nil? document) (not= parent branch/default-branch)) (do
  (fail! :branch-missing "branch has no ref" {:branch parent :path (branch/ref-path! store parent)})))
  (let [parsed (read-triple-log! parent-tail true)
   space-id (:space-id parsed)
   records (:records parsed)
   base (or document (branch/empty-ref space-id))
   chained? (pos? (count (branch/refdocument-segments base)))]
  (if (:deflate? parsed) (do
  (fail! :unsupported-branch-chain-encoding "branch routing does not support Deflate-compressed Store transaction log members" {:path parent-tail :branch parent})))
  (if (:torn-tail parsed) (do
  (fail! :torn-tail-repair-required "fork requires a parent tail with no torn trailing record" {:branch parent :path parent-tail})))
  (if (not= space-id (branch/refdocument-space-id base)) (do
  (fail! :space-mismatch "Store transaction log belongs to a different SpaceId" {:expected (branch/refdocument-space-id base) :actual space-id :branch parent})))
  (if (not= chained? (boolean (:continuation? parsed))) (do
  (fail! :invalid-branch-chain (if chained? "Store transaction log branch tail must carry the continuation flag" "Store transaction log base chain segment must not carry the continuation flag") {:branch parent :path parent-tail})))
  (let [content (Files/readAllBytes (.toPath (java.io.File. (str parent-tail))))
   record (branch/->SegmentRecord (sha256-hex content) (long (or (:tx-seq (first records)) 0)) (long (or (:tx-seq (last records)) 0)) (long (alength content)))
   plan (branch/fork-plan base record (long (or (:tx-seq (last records)) (branch/chain-end-sequence base))))
   chain (branch/forkplan-document plan)
   text (branch/print-ref chain)
   marker (branch/->ForkMarker parent child (branch/segmentrecord-sha256 record))
   parent-ref (branch/ref-path! store parent)
   child-ref (branch/ref-path! store child)]
  (ensure-directory! (branch/segments-directory store))
  (ensure-directory! (branch/refs-directory store))
  (if (not= child-tail store) (do
  (ensure-directory! (branch/branches-directory store))))
  (doseq [path [parent-tail child-tail parent-ref child-ref]]
  (delete-file! (fork-pending-path path)))
  (doseq [tail [parent-tail child-tail]]
  (create-triple-log! (fork-pending-path tail) space-id {:deflate? (:deflate? parsed) :continuation? true}))
  (doseq [ref [parent-ref child-ref]]
  (write-text-durable! (fork-pending-path ref) text))
  (write-text-durable! (fork-marker-path store) (branch/print-fork-marker marker))
  (complete-fork! store marker)
  {:space-id space-id :fork-sequence (branch/forkplan-fork-sequence plan) :segment (branch/segmentrecord-sha256 record) :chain (mapv branch/segmentrecord-sha256 (branch/refdocument-segments chain)) :parent {:branch parent :tail parent-tail :ref parent-ref} :child {:branch child :tail child-tail :ref child-ref}})))
  (finally
    (doseq [handle held]
  (writer-authority/release! handle))))))))

(defn new-database
  "Create an in-memory authoritative database for one immutable SpaceId." [space-id]
  {:term-store (term-store/new-term-store space-id) :space-id space-id :log nil :lock (Object.) :mutation-state (atom {:status :ready}) :torn-tail nil :recovered-tail nil})

(defn database-recovery-state [db]
  (deref (:mutation-state db)))

(defn mutation-ready? [db]
  (= :ready (:status (database-recovery-state db))))

(defn require-mutation-ready! [db]
  (let [{:keys [status] :as state} (database-recovery-state db)]
  (case status
    :ready true
    :recovery-required (fail! :recovery-required "database is fenced after a durability-ambiguous commit" {:recovery state})
    :corrupt (fail! :database-corrupt "database is permanently fenced because durable history is corrupt" {:recovery state})
    (fail! :database-state-invalid "database mutation state is invalid" {:recovery state}))))

(defn- require-readable! [db]
  (let [{:keys [status reconciled?] :as state} (database-recovery-state db)]
  (case status
    :ready true
    :recovery-required (if reconciled? true (fail! :recovery-required "durable history reconciliation has not completed" {:recovery state}))
    :corrupt (fail! :database-corrupt "durable history could not be reconciled" {:recovery state})
    (fail! :database-state-invalid "database mutation state is invalid" {:recovery state}))))

(defn database-store! [db]
  (require-readable! db)
  (:term-store db))

(defn ^String database-space [db]
  (:space-id db))

(defn store-view
  "Read-only database over an immutable TermStore root: every read accessor\n   below works against the pinned root instead of the live store." [db root]
  (assoc db :term-store (atom root)))

(defn current-transaction! [db]
  (t/transaction-coordinate (database-space db) (term-store/current-sequence (database-store! db))))

(defn checkpoint-packed!
  "Publish and install a manifest-last packed checkpoint for the exact durable\n   STORELOG prefix currently represented by DB. STORELOG remains authoritative." [db]
  (locking (:lock db) (require-readable! db) (if (not (:log db)) (do
  (fail! :packed-checkpoint-unavailable "packed checkpoints require an authoritative STORELOG" {}))) (checkpoint/publish! (database-store! db) (packed-checkpoint-directory (:log db)) (fn [revision] (checkpoint-source-for-revision! (:log db) revision)))))

(defn- ensure-packed-write-capacity! [db operations]
  (if *deferred-records* (do
  (if (and (:log db) (nil? (term-store/packed-prefix (database-store! db)))) (do
  (reset! term-store/*deferred-packed-rollover* true)))
  (term-store/ensure-transaction-capacity! (database-store! db) operations)
  (database-store! db)) (if (:log db) (checkpoint/prepare-write! (database-store! db) operations (packed-checkpoint-directory (:log db)) (fn [revision] (checkpoint-source-for-revision! (:log db) revision))) (do
  (term-store/ensure-transaction-capacity! (database-store! db) operations)
  (database-store! db)))))

(defn database-status! [db]
  (locking (:lock db) (let [{:keys [status reconciled?] :as recovery} (database-recovery-state db)
   readable? (or (= :ready status) (and (= :recovery-required status) reconciled?))
   context (database-store! db)]
  {:space-id (database-space db) :version (if readable? (do
  (t/transaction-coordinate (database-space db) (term-store/current-sequence context)))) :transactions (if readable? (do
  (term-store/transaction-count context))) :operations (if readable? (do
  (term-store/operation-count context))) :terms (if readable? (do
  (term-store/term-count context))) :storage (if readable? (do
  (assoc (term-store/storage-diagnostics context) :boot-source (:storage-source db) :selected-manifest (:packed-manifest db) :prefix-records (:packed-prefix-records db) :suffix-records (:packed-suffix-records db) :decoded-from-byte (:packed-decoded-from-byte db) :decoded-record-count (:packed-decoded-record-count db) :rejections (:packed-rejections db)))) :readable readable? :mutation-ready (= :ready status) :recovery recovery})))

(defn instant-now []
  (let [^Instant now (Instant/now)]
  (t/instant (.getEpochSecond now) (.getNano now))))

(defn occurrences! [db]
  (term-store/occurrences (database-store! db)))

(defn- occurrences-range! [db from to]
  (let [store (deref (database-store! db))]
  (mapv (fn [position] (let [slots (term-store/occurrence-tuple-at store position)]
  (t/operation-occurrence (nth slots 0) (nth slots 1) (nth slots 2)))) (range from to))))

(defn occurrence! [db coordinate]
  (some (fn [%1] (if (= coordinate (t/operationoccurrence-coordinate %1)) (do
  %1))) (occurrences! db)))

(defn- relation-proposition? [predicate value]
  (and (t/triple? value) (t/occurrence-coordinate? (t/triple-t1 value)) (= predicate (t/triple-t2 value)) (t/occurrence-coordinate? (t/triple-t3 value))))

(defn supersession-triples! [db]
  (filterv (fn [%1] (relation-proposition? :kernel/supersedes %1)) (term-store/live-propositions (database-store! db))))

(defn withdrawals! [db]
  (term-store/withdrawals (database-store! db)))

(defn- suppressed-occurrences! [db]
  (into #{} (map t/triple-t3) (supersession-triples! db)))

(defn live-occurrences! [db]
  (let [suppressed (suppressed-occurrences! db)]
  (filterv (fn [%1] (not (contains? suppressed (t/operationoccurrence-coordinate %1)))) (term-store/live-occurrences (database-store! db)))))

(defn live-propositions! [db]
  (mapv t/operationoccurrence-proposition (live-occurrences! db)))

(defn matching-live-propositions! [db t1 t2 t3 maximum]
  (let [store (deref (database-store! db))
   suppressed (suppressed-occurrences! db)]
  (if (empty? suppressed) (term-store/matching-live-propositions store t1 t2 t3 maximum) (let [matching (filterv (fn [occurrence] (not (contains? suppressed (t/operationoccurrence-coordinate occurrence)))) (term-store/matching-live-occurrences store t1 t2 t3 nil))
   propositions (mapv t/operationoccurrence-proposition matching)]
  (if maximum (vec (take maximum propositions)) propositions)))))

(defn- validate-base! [db base]
  (if base (do
  (if (not (t/transaction-coordinate? base)) (do
  (fail! :invalid-base "OCC base must be a transaction-coordinate Triple" {:base base})))
  (if (not (= (database-space db) (t/triple-t1 base))) (do
  (fail! :space-mismatch "OCC base belongs to a different SpaceId" {:base base :space-id (database-space db)})))))
  base)

(def occurrence-metadata-order [:kernel/recorded-at :kernel/asserted-by :kernel/source-record :kernel/supersedes])

(defn- canonical-term! [value]
  (cond
  (t/triple? value) (t/triple (canonical-term! (t/triple-t1 value)) (canonical-term! (t/triple-t2 value)) (canonical-term! (t/triple-t3 value)))
  (integer? value) (long (require-i64! value "Int atom"))
  (and (number? value) (not (integer? value))) (double value)
  (t/instant? value) (t/instant (require-i64! (t/instant-epoch-seconds value) "Instant epoch seconds") (t/instant-nanos value))
  (t/atom? value) value
  :else (fail! :invalid-term "value is outside Term" {:value value})))

(defn- commit-operation! [{:keys [action proposition] :as operation}]
  (if (not (t/triple? proposition)) (do
  (fail! :invalid-commit-operation "operation proposition must be a Triple" {:operation operation})))
  (let [canonical (canonical-term! proposition)]
  (case action
    :assert (term-store/assert-operation canonical)
    :retract (term-store/retract-operation canonical)
    (fail! :invalid-commit-operation "operation action must be :assert or :retract" {:operation operation}))))

(defn- validate-occurrence-reference! [db coordinate field]
  (if coordinate (do
  (if (not (t/occurrence-coordinate? coordinate)) (do
  (fail! :invalid-occurrence-coordinate (str field " must be an occurrence-coordinate Triple") {field coordinate})))
  (let [tx (t/triple-t1 coordinate)]
  (if (not (= (database-space db) (t/triple-t1 tx))) (do
  (fail! :space-mismatch "occurrence coordinate belongs to another SpaceId" {field coordinate :space-id (database-space db)}))))
  (if (not (occurrence! db coordinate)) (do
  (fail! :unknown-occurrence "occurrence coordinate does not resolve" {field coordinate})))))
  coordinate)

(defn- metadata-operations! [db tx-coordinate source-operations request]
  (let [source-count (count source-operations)
   per-source (mapcat (fn [[ordinal operation]] (let [source (t/occurrence-coordinate tx-coordinate ordinal)
   values {:kernel/recorded-at (some-> (:recorded-at operation) canonical-term!) :kernel/asserted-by (some-> (:asserted-by operation) canonical-term!) :kernel/source-record (some-> (:source-record operation) canonical-term!) :kernel/supersedes (:supersedes operation)}]
  (validate-occurrence-reference! db (:supersedes operation) :supersedes)
  (if (and (:recorded-at operation) (not (t/instant? (:recorded-at operation)))) (do
  (fail! :invalid-instant "operation recorded-at must be a typed Instant" {:recorded-at (:recorded-at operation)})))
  (mapv (fn [predicate] (term-store/assert-operation (t/triple source predicate (get values predicate)))) (filter (fn [%1] (some? (get values %1))) occurrence-metadata-order)))) (map-indexed vector source-operations))
   tx-metadata (cond-> [] (:recorded-at request) (conj (term-store/assert-operation (t/triple tx-coordinate :kernel/recorded-at (canonical-term! (:recorded-at request))))) (:actor request) (conj (term-store/assert-operation (t/triple tx-coordinate :kernel/asserted-by (canonical-term! (:actor request))))))]
  (if (and (:recorded-at request) (not (t/instant? (:recorded-at request)))) (do
  (fail! :invalid-instant "recorded-at must be a typed Instant" {:recorded-at (:recorded-at request)})))
  (if (and (:actor request) (not (t/term? (:actor request)))) (do
  (fail! :invalid-term "actor must be a Term" {:actor (:actor request)})))
  (vec (concat per-source tx-metadata))))

(defn- append-and-replay! [db sequence operations metadata]
  (let [record (term-store/transaction-record sequence operations)
   serializable {:tx-seq sequence :commit-metadata metadata :operations (vec (map-indexed operation-map! operations))}]
  (if *deferred-records* (swap! *deferred-records* conj serializable) (let [path (:log db)]
  (if path (do
  (append-record-durable! path serializable (:deflate? db))))))
  (term-store/replay-transaction! (database-store! db) record)))

(defn- throwable-code [error]
  (let [data (ex-data error)]
  (or (:store/code data) (:type data) (:code data) (keyword (.getSimpleName (class error))))))

(defn- fence-and-reconcile! [db before-store error]
  (let [cause {:code (throwable-code error) :message (.getMessage error)}]
  (reset! (:mutation-state db) {:status :recovery-required :reconciled? false :cause cause})
  (try
  (let [publish! (fn [context torn-tail valid-bytes source] (let [sequence (term-store/current-sequence context)
   recovery {:status :recovery-required :reconciled? true :source source :cause cause :version (t/transaction-coordinate (database-space db) sequence) :torn-tail torn-tail :valid-bytes valid-bytes}]
  (reset! (:term-store db) (deref context))
  (reset! (:mutation-state db) recovery)
  recovery))]
  (let [path (:log db)]
  (if path (let [parsed (read-triple-log! path)
   space-id (:space-id parsed)
   context (term-store/new-term-store space-id)]
  (if (not (= (database-space db) space-id)) (do
  (fail! :space-mismatch "durable history changed SpaceId during reconciliation" {:expected (database-space db) :actual space-id})))
  (replay-records! context (:records parsed))
  (publish! context (:torn-tail parsed) (:valid-bytes parsed) :durable-prefix)) (let [context (term-store/new-term-store (database-space db))]
  (reset! context before-store)
  (publish! context nil nil :memory-snapshot)))))
  (catch Throwable reconciliation-error
    (let [corruption {:status :corrupt :reconciled? false :cause cause :corruption {:code (throwable-code reconciliation-error) :message (.getMessage reconciliation-error)}}]
  (reset! (:mutation-state db) corruption)
  corruption)))))

(defn- propagate-ambiguous-commit! [recovery error]
  (if (= :corrupt (:status recovery)) (throw (ex-info "durable history is corrupt after a commit failure" {:type :database-corrupt :store/code :database-corrupt :recovery recovery} error)) (throw (ex-info "commit outcome is durability-ambiguous; restart is required" {:type :durability-ambiguous :store/code :durability-ambiguous :recovery recovery} error))))

(defn commit!
  "Commit one ordered transaction. REQUEST contains :operations and may contain\n   :base, :actor, and typed :recorded-at. The response exposes transaction and\n   occurrence coordinates; no physical row handle is public." [db {:keys [operations base] :as request}]
  (locking (:lock db) (require-mutation-ready! db) (validate-base! db base) (let [current (current-transaction! db)]
  (if (and base (not= base current)) {:reject :conflict :expected base :current current} (do
  (if (not (and (vector? operations) (seq operations))) (do
  (fail! :invalid-transaction-record "transaction requires a nonempty operation vector" {})))
  (if (:torn-tail db) (do
  (fail! :torn-tail-repair-required "Store transaction log has a torn trailing record; writer authority must repair it" {:path (:log db) :torn-tail (:torn-tail db)})))
  (let [context (database-store! db)
   sequence (term-store/next-sequence context)
   tx-coordinate (t/transaction-coordinate (database-space db) sequence)
   source-operations (mapv commit-operation! operations)
   metadata (metadata-operations! db tx-coordinate operations request)
   all-operations (into source-operations metadata)
   commit-metadata (canonical-validate-commit! all-operations (:commit-metadata request))
   _capacity (ensure-packed-write-capacity! db all-operations)
   before (term-store/operation-count context)
   before-store (term-store/fork-state (deref context))]
  (try
  (let [committed (append-and-replay! db sequence all-operations commit-metadata)
   events (occurrences-range! db before (+ before (count source-operations)))
   event-coordinates (into #{} (map t/operationoccurrence-coordinate) events)
   withdrawals (filterv (fn [%1] (contains? event-coordinates (t/operationoccurrence-coordinate (t/withdrawal-retraction %1)))) (withdrawals! db))]
  {:ok committed :occurrences events :withdrawals withdrawals :operation-count (count all-operations)})
  (catch Throwable error
    (propagate-ambiguous-commit! (fence-and-reconcile! db before-store error) error)))))))))

(defn commit-cohort!
  "Run mutation functions in FIFO order against a private store root, append\n   every resulting Store transaction log record under one durability barrier, and publish the\n   root atomically. Individual pre-append failures are returned without\n   aborting later functions; a barrier failure fences the whole database." [db mutation-functions]
  (locking (:lock db) (require-mutation-ready! db) (let [context (database-store! db)
   before-store (deref context)
   scratch (assoc db :term-store (term-store/fork-store context) :mutation-state (atom (deref (:mutation-state db))))
   records (atom [])
   deferred-packed-rollover (atom false)
   results (binding [*deferred-records* records
   term-store/*deferred-packed-rollover* (if (:log db) deferred-packed-rollover nil)]
  (mapv (fn [mutation] (try
  (let [value (mutation scratch)]
  {:value value :version (term-store/current-sequence (database-store! scratch))})
  (catch Throwable error
    {:error error :version (term-store/current-sequence (database-store! scratch))}))) mutation-functions))]
  (if (empty? (deref records)) {:results results :record-count 0 :root before-store :version (current-transaction! db)} (try
  (let [path (:log db)]
  (if path (do
  (append-record-cohort-durable! path (deref records) (:deflate? db)))))
  (if (deref deferred-packed-rollover) (do
  (checkpoint/publish! (database-store! scratch) (packed-checkpoint-directory (:log db)) (fn [revision] (checkpoint-source-for-revision! (:log db) revision)))))
  (let [root (deref (database-store! scratch))]
  (reset! context root)
  {:results results :record-count (count (deref records)) :root root :version (current-transaction! db)})
  (catch Throwable error
    (propagate-ambiguous-commit! (fence-and-reconcile! db before-store error) error)))))))

(defn assert!
  ([db proposition]
    (assert! db proposition {}))
  ([db proposition options]
    (commit! db (assoc options :operations [{:action :assert :proposition proposition :supersedes (:supersedes options) :source-record (:source-record options)}]))))

(defn retract!
  ([db proposition]
    (retract! db proposition {}))
  ([db proposition options]
    (commit! db (assoc options :operations [{:action :retract :proposition proposition :source-record (:source-record options)}]))))

(defn withdraw-occurrence!
  "Withdraw one exact currently-effective occurrence. TermStore's physical\n   retraction targets the most recent equal live proposition; rejecting any\n   other coordinate keeps the public target exact." [db target options]
  (locking (:lock db) (let [event (occurrence! db target)
   effective (into #{} (map t/operationoccurrence-coordinate) (live-occurrences! db))]
  (cond
  (nil? event) {:reject :unknown-occurrence :occurrence target}
  (not (t/assertion-occurrence? event)) {:reject :not-assertion-occurrence :occurrence target}
  (not (contains? effective target)) {:reject :occurrence-not-live :occurrence target}
  :else (let [proposition (t/operationoccurrence-proposition event)
   matching (filterv (fn [%1] (= proposition (t/operationoccurrence-proposition %1))) (term-store/live-occurrences (database-store! db)))
   current (some-> matching peek t/operationoccurrence-coordinate)]
  (if (not= target current) {:reject :withdrawal-target-not-current :occurrence target :current current} (retract! db proposition options)))))))

(defn supersede!
  "Assert REPLACEMENT while relating its new occurrence to exact TARGET." [db target replacement options]
  (locking (:lock db) (if (some #{target} (map t/operationoccurrence-coordinate (live-occurrences! db))) (assert! db replacement (assoc options :supersedes target)) {:reject :occurrence-not-live :occurrence target})))

(defn view-select! [db view target options]
  (locking (:lock db) (validate-occurrence-reference! db target :target) (let [selection (t/triple view :kernel/selects target)]
  (if (some #{selection} (live-propositions! db)) {:idempotent true :selection selection} (assert! db selection options)))))

(defn view-deselect! [db view target options]
  (retract! db (t/triple view :kernel/selects target) options))

(defn view-occurrences! [db view]
  (let [effective (live-occurrences! db)
   by-coordinate (into {} (map (juxt t/operationoccurrence-coordinate identity)) effective)
   selected (for [event effective
   :let [proposition (t/operationoccurrence-proposition event)]
   :when (and (= view (t/triple-t1 proposition)) (= :kernel/selects (t/triple-t2 proposition)) (t/occurrence-coordinate? (t/triple-t3 proposition)))]
  (t/triple-t3 proposition))]
  (into [] (keep by-coordinate) selected)))

(defn- lease-value [holder expires-ms]
  (t/triple holder :kernel/expires-at expires-ms))

(defn- lease-record [event]
  (let [proposition (t/operationoccurrence-proposition event)
   value (t/triple-t3 proposition)]
  (if (and (= :kernel/lease (t/triple-t2 proposition)) (t/triple? value) (= :kernel/expires-at (t/triple-t2 value)) (integer? (t/triple-t3 value))) (do
  {:resource (t/triple-t1 proposition) :holder (t/triple-t1 value) :expires-ms (t/triple-t3 value) :occurrence (t/operationoccurrence-coordinate event) :proposition proposition}))))

(defn current-lease! [db resource]
  (some->> (live-occurrences! db) (keep lease-record) (filter (fn [%1] (= resource (:resource %1)))) last))

(defn acquire-lease! [db resource holder ttl-ms now-ms]
  (locking (:lock db) (if (not (and (t/term? resource) (t/term? holder) (integer? ttl-ms) (pos? ttl-ms) (integer? now-ms))) (do
  (fail! :invalid-lease-request "lease requires Term resource/holder and positive ttl" {:resource resource :holder holder :ttl-ms ttl-ms :now-ms now-ms}))) (let [prior (current-lease! db resource)]
  (if (and prior (> (:expires-ms prior) now-ms)) {:reject :lease-held :holder (:holder prior) :epoch (:occurrence prior) :expires-ms (:expires-ms prior)} (let [result (assert! db (t/triple resource :kernel/lease (lease-value holder (+ now-ms ttl-ms))) (cond-> {:actor holder} prior (assoc :supersedes (:occurrence prior))))
   epoch (some-> result :occurrences first t/operationoccurrence-coordinate)]
  {:ok epoch :expires-ms (+ now-ms ttl-ms) :transaction (:ok result)})))))

(defn renew-lease! [db resource holder epoch ttl-ms now-ms]
  (locking (:lock db) (let [prior (current-lease! db resource)]
  (if (and prior (= holder (:holder prior)) (= epoch (:occurrence prior)) (> (:expires-ms prior) now-ms)) (let [result (assert! db (t/triple resource :kernel/lease (lease-value holder (+ now-ms ttl-ms))) {:actor holder :supersedes epoch})
   next-epoch (some-> result :occurrences first t/operationoccurrence-coordinate)]
  {:ok next-epoch :expires-ms (+ now-ms ttl-ms) :transaction (:ok result)}) {:reject :lease-fence-mismatch :current prior}))))

(defn release-lease! [db resource holder epoch]
  (locking (:lock db) (let [prior (current-lease! db resource)]
  (if (and prior (= holder (:holder prior)) (= epoch (:occurrence prior))) (let [result (withdraw-occurrence! db epoch {:actor holder})]
  (if (:ok result) {:ok true :transaction (:ok result) :withdrawals (:withdrawals result)} result)) {:reject :lease-fence-mismatch :current prior}))))

(defn lease-fence-valid?! [db resource holder epoch now-ms]
  (let [lease (current-lease! db resource)]
  (boolean (and lease (= holder (:holder lease)) (= epoch (:occurrence lease)) (> (:expires-ms lease) now-ms)))))
