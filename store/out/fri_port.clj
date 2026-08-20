(ns fri-port
  (:require [store.store :as store]
            [store.types :as t])
  (:import [java.io ByteArrayOutputStream]
           [java.io File]
           [java.io FileOutputStream]
           [java.nio ByteBuffer]
           [java.nio ByteOrder]
           [java.nio CharBuffer]
           [java.nio.charset CodingErrorAction]
           [java.nio.charset StandardCharsets]
           [java.nio.file Files]
           [java.nio.file StandardCopyOption]
           [java.security MessageDigest]
           [java.util Arrays]
           [java.util HexFormat]))

(def ^String MAGIC "BEAGLEFRI2")

(def FMT 2)

(def FLAGS 0)

(def PAYLOAD-FLAGS 0)

(def MAX-TERM-DEPTH 256)

(def FINGERPRINT-BYTES 32)

(defrecord CacheSource [space-id fingerprint valid-bytes])

(defn cachesource-space-id [r] (:space-id r))

(defn cachesource-fingerprint [r] (:fingerprint r))

(defn cachesource-valid-bytes [r] (:valid-bytes r))

(defrecord CacheReceipt [format space-id source-fingerprint source-position sha256])

(defn cachereceipt-format [r] (:format r))

(defn cachereceipt-space-id [r] (:space-id r))

(defn cachereceipt-source-fingerprint [r] (:source-fingerprint r))

(defn cachereceipt-source-position [r] (:source-position r))

(defn cachereceipt-sha256 [r] (:sha256 r))

(defrecord CacheImage [source dump indexes store])

(defn cacheimage-source [r] (:source r))

(defn cacheimage-dump [r] (:dump r))

(defn cacheimage-indexes [r] (:indexes r))

(defn cacheimage-store [r] (:store r))

(defn- fail [^String message type]
  (throw (ex-info message {:type type})))

(defn- ^Boolean valid-fingerprint? [^String value]
  (some? (re-matches #"[0-9a-f]{64}" value)))

(defn ^CacheSource source-binding [^String space-id ^String fingerprint valid-bytes]
  (if (and (pos? (count space-id)) (and (valid-fingerprint? fingerprint) (>= valid-bytes 0))) (->CacheSource space-id fingerprint valid-bytes) (fail "fri: source binding requires SpaceId, sha256, and non-negative valid-byte position" :invalid-cache-source)))

(defn- ^String hex [bytes]
  (apply str (map (fn [value] (format "%02x" (bit-and value 255))) bytes)))

(defn- sha256-bytes [bytes]
  (.digest (MessageDigest/getInstance "SHA-256") bytes))

(defn- ^String sha256 [bytes]
  (hex (sha256-bytes bytes)))

(defn- strict-utf8 [^String value ^String context]
  (try
  (let [encoder (doto (.newEncoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))
   buffer (.encode encoder (CharBuffer/wrap value))
   bytes (byte-array (.remaining buffer))]
  (.get buffer bytes)
  bytes)
  (catch java.nio.charset.CharacterCodingException error
    (fail (str "fri: invalid UTF-8 in " context) :invalid-fri-cache))))

(defn- ^String strict-utf8-string [bytes ^String context]
  (try
  (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))]
  (str (.decode decoder (ByteBuffer/wrap bytes))))
  (catch java.nio.charset.CharacterCodingException error
    (fail (str "fri: invalid UTF-8 in " context) :invalid-fri-cache))))

(defn- require-u32 [value ^String context]
  (if (and (>= value 0) (<= value 4294967295)) value (fail (str "fri: " context " exceeds u32") :invalid-fri-cache)))

(defn- require-i64 [value ^String context]
  (if (and (>= value -9223372036854775808) (<= value 9223372036854775807)) value (fail (str "fri: " context " exceeds i64") :invalid-fri-cache)))

(defn- write-u8! [out value]
  (do
  (.write out (int (bit-and value 255)))
  nil))

(defn- write-u16-le! [out value]
  (do
  (doseq [position (range 2)]
  (write-u8! out (unsigned-bit-shift-right value (* position 8))))
  nil))

(defn- write-u32-le! [out value ^String context]
  (let [checked (require-u32 value context)]
  (doseq [position (range 4)]
  (write-u8! out (unsigned-bit-shift-right checked (* position 8))))
  nil))

(defn- write-i64-le! [out value ^String context]
  (let [checked (require-i64 value context)]
  (doseq [position (range 8)]
  (write-u8! out (unsigned-bit-shift-right checked (* position 8))))
  nil))

(defn- ensure-remaining! [buffer amount ^String context]
  (if (and (>= amount 0) (>= (.remaining buffer) amount)) nil (fail (str "fri: truncated " context) :invalid-fri-cache)))

(defn- read-u8! [buffer ^String context]
  (do
  (ensure-remaining! buffer 1 context)
  (let [position (.position buffer)
   value (.get buffer position)]
  (.position buffer (inc position))
  (bit-and 255 (int value)))))

(defn- read-u16-le! [buffer ^String context]
  (do
  (ensure-remaining! buffer 2 context)
  (bit-and 65535 (int (.getShort buffer)))))

(defn- read-u32-le! [buffer ^String context]
  (do
  (ensure-remaining! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer))))

(defn- read-i64-le! [buffer ^String context]
  (do
  (ensure-remaining! buffer 8 context)
  (.getLong buffer)))

(defn- read-fixed! [buffer amount ^String context]
  (do
  (ensure-remaining! buffer amount context)
  (let [bytes (byte-array amount)]
  (.get buffer bytes)
  bytes)))

(defn- write-sized-text! [out ^String value ^String context]
  (let [bytes (strict-utf8 value context)]
  (write-u32-le! out (alength bytes) context)
  (.write out bytes)
  nil))

(defn- read-sized-bytes! [buffer ^String context]
  (let [amount (read-u32-le! buffer context)]
  (if (> amount 2147483647) (fail (str "fri: " context " length exceeds JVM bounds") :invalid-fri-cache) (read-fixed! buffer amount context))))

(defn- ^String read-sized-text! [buffer ^String context]
  (strict-utf8-string (read-sized-bytes! buffer context) context))

(declare write-term-v1!)

(defn- write-triple-v1! [out value depth]
  (do
  (if (not (t/triple? value)) (do
  (fail "fri: TermCodecV1 expected Triple" :invalid-fri-cache)))
  (if (> depth MAX-TERM-DEPTH) (do
  (fail "fri: TermCodecV1 depth exceeds 256" :invalid-fri-cache)))
  (write-u8! out 7)
  (write-term-v1! out (t/triple-t1 value) (inc depth))
  (write-term-v1! out (t/triple-t2 value) (inc depth))
  (write-term-v1! out (t/triple-t3 value) (inc depth))))

(defn- write-term-v1! [out term depth]
  (cond
  (t/triple? term) (write-triple-v1! out term depth)
  (string? term) (do
  (write-u8! out 1)
  (write-sized-text! out term "String atom"))
  (integer? term) (do
  (write-u8! out 2)
  (write-i64-le! out term "Int atom"))
  (and (number? term) (not (integer? term))) (do
  (write-u8! out 3)
  (write-i64-le! out (Double/doubleToLongBits (double term)) "Float atom"))
  (false? term) (write-u8! out 4)
  (true? term) (write-u8! out 5)
  (keyword? term) (let [spelling (subs (str term) 1)]
  (if (empty? spelling) (do
  (fail "fri: TermCodecV1 Keyword is empty" :invalid-fri-cache)))
  (write-u8! out 6)
  (write-sized-text! out spelling "Keyword atom"))
  (t/instant? term) (do
  (write-u8! out 8)
  (write-i64-le! out (t/instant-epoch-seconds term) "Instant seconds")
  (write-u32-le! out (t/instant-nanos term) "Instant nanos"))
  :else (fail "fri: value outside TermCodecV1" :invalid-fri-cache)))

(declare read-term-v1!)

(defn- read-term-v1! [buffer depth]
  (do
  (if (> depth MAX-TERM-DEPTH) (do
  (fail "fri: TermCodecV1 depth exceeds 256" :invalid-fri-cache)))
  (let [tag (read-u8! buffer "Term tag")]
  (cond
  (= tag 1) (read-sized-text! buffer "String atom")
  (= tag 2) (read-i64-le! buffer "Int atom")
  (= tag 3) (Double/longBitsToDouble (read-i64-le! buffer "Float atom"))
  (= tag 4) false
  (= tag 5) true
  (= tag 6) (let [spelling (read-sized-text! buffer "Keyword atom")]
  (if (empty? spelling) (fail "fri: TermCodecV1 Keyword is empty" :invalid-fri-cache) (keyword spelling)))
  (= tag 7) (t/triple (read-term-v1! buffer (inc depth)) (read-term-v1! buffer (inc depth)) (read-term-v1! buffer (inc depth)))
  (= tag 8) (t/instant (read-i64-le! buffer "Instant seconds") (read-u32-le! buffer "Instant nanos"))
  :else (fail "fri: unknown TermCodecV1 tag" :invalid-fri-cache)))))

(defn- encode-term-v1! [term]
  (let [out (ByteArrayOutputStream.)]
  (write-term-v1! out term 0)
  (.toByteArray out)))

(defn- decode-term-v1! [bytes]
  (let [buffer (doto (ByteBuffer/wrap bytes)
  (.order ByteOrder/LITTLE_ENDIAN))
   term (read-term-v1! buffer 0)]
  (if (= 0 (.remaining buffer)) term (fail "fri: trailing bytes inside TermCodecV1 row" :invalid-fri-cache))))

(defn- atom-row [value]
  (cond
  (string? value) (t/->AtomRow :string value nil nil nil nil nil)
  (integer? value) (t/->AtomRow :int nil value nil nil nil nil)
  (and (number? value) (not (integer? value))) (t/->AtomRow :float nil nil (double value) nil nil nil)
  (boolean? value) (t/->AtomRow :bool nil nil nil value nil nil)
  (keyword? value) (t/->AtomRow :keyword nil nil nil nil value nil)
  (t/instant? value) (t/->AtomRow :instant nil nil nil nil nil value)
  :else (fail "fri: TermCodecV1 AtomRow contains a Triple" :invalid-fri-cache)))

(defn- action-code [action]
  (cond
  (= action t/assert-action) 1
  (= action t/retract-action) 2
  :else (fail "fri: operation has an unknown action" :invalid-fri-cache)))

(defn- code-action [code]
  (cond
  (= code 1) t/assert-action
  (= code 2) t/retract-action
  :else (fail "fri: operation has an unknown action code" :invalid-fri-cache)))

(defn- atom-handle [position]
  (* 2 position))

(defn- triple-handle [position]
  (inc (* 2 position)))

(defn- index-data [rows]
  (let [with-handles (map-indexed (fn [position row] [(triple-handle position) row]) rows)]
  [(vec (sort (map (fn [entry] [(t/triplerow-t1 (nth entry 1)) (nth entry 0)]) with-handles))) (vec (sort (map (fn [entry] [(t/triplerow-t2 (nth entry 1)) (nth entry 0)]) with-handles))) (vec (sort (map (fn [entry] [(t/triplerow-t3 (nth entry 1)) (nth entry 0)]) with-handles))) (vec (sort (map (fn [entry] [(t/triplerow-t1 (nth entry 1)) (t/triplerow-t2 (nth entry 1)) (nth entry 0)]) with-handles))) (vec (sort (map (fn [entry] [(t/triplerow-t2 (nth entry 1)) (t/triplerow-t3 (nth entry 1)) (nth entry 0)]) with-handles))) (vec (sort (map (fn [entry] [(t/triplerow-t1 (nth entry 1)) (t/triplerow-t3 (nth entry 1)) (nth entry 0)]) with-handles)))]))

(declare atom-value resolve-handle)

(defn- write-term-row! [out term]
  (let [bytes (encode-term-v1! term)]
  (write-u32-le! out (alength bytes) "Term row length")
  (.write out bytes)
  nil))

(defn- write-payload! [dump]
  (let [out (ByteArrayOutputStream.)
   atoms (t/termstoredump-atoms dump)
   triples (t/termstoredump-triples dump)
   transactions (t/termstoredump-transactions dump)
   operations (t/termstoredump-operations dump)
   indexes (index-data triples)]
  (write-u16-le! out store/term-store-dump-version)
  (write-u16-le! out PAYLOAD-FLAGS)
  (write-i64-le! out (t/termstoredump-next-sequence dump) "next sequence")
  (write-u32-le! out (count atoms) "AtomRow count")
  (doseq [row atoms]
  (write-term-row! out (atom-value row)))
  (write-u32-le! out (count triples) "TripleRow count")
  (doseq [position (range (count triples))]
  (write-term-row! out (resolve-handle dump (triple-handle position))))
  (write-u32-le! out (count transactions) "TransactionRow count")
  (doseq [row transactions]
  (write-i64-le! out (t/transactionrow-sequence row) "transaction sequence")
  (write-i64-le! out (t/transactionrow-first-operation row) "first operation")
  (write-i64-le! out (t/transactionrow-operation-count row) "operation count"))
  (write-u32-le! out (count operations) "OperationRow count")
  (doseq [row operations]
  (write-i64-le! out (t/operationrow-tx-sequence row) "operation transaction")
  (write-i64-le! out (t/operationrow-ordinal row) "operation ordinal")
  (write-u8! out (action-code (t/operationrow-action row)))
  (write-i64-le! out (t/operationrow-triple-handle row) "operation handle"))
  (doseq [entries indexes]
  (write-u32-le! out (count entries) "slot index row count")
  (doseq [entry entries]
  (doseq [handle entry]
  (write-i64-le! out handle "slot index handle"))))
  (.toByteArray out)))

(defn- read-count! [buffer ^String context minimum-row]
  (let [row-count (read-u32-le! buffer context)]
  (if (or (> row-count 2147483647) (> (* row-count minimum-row) (.remaining buffer))) (fail (str "fri: impossible " context) :invalid-fri-cache) row-count)))

(defn- read-term-row! [buffer]
  (decode-term-v1! (read-sized-bytes! buffer "Term row")))

(defn- read-atoms! [buffer]
  (let [row-count (read-count! buffer "AtomRow count" 5)]
  (mapv (fn [position] (let [term (read-term-row! buffer)]
  (if (t/triple? term) (fail "fri: AtomRow decoded as Triple" :invalid-fri-cache) (atom-row term)))) (vec (range row-count)))))

(defn- initial-handles [atoms]
  (into {} (map-indexed (fn [position row] [(atom-value row) (atom-handle position)]) atoms)))

(defn- required-handle [handles term]
  (if (contains? handles term) (get handles term) (fail "fri: TripleRow references a term absent from prior rows" :invalid-fri-cache)))

(defn- read-triples! [buffer atoms]
  (let [row-count (read-count! buffer "TripleRow count" 8)]
  (loop [position 0
   rows []
   handles (initial-handles atoms)]
  (if (>= position row-count) rows (let [term (read-term-row! buffer)]
  (if (not (t/triple? term)) (fail "fri: TripleRow decoded as Atom" :invalid-fri-cache) (if (contains? handles term) (fail "fri: duplicate structural TripleRow" :invalid-fri-cache) (let [row (t/->TripleRow (required-handle handles (t/triple-t1 term)) (required-handle handles (t/triple-t2 term)) (required-handle handles (t/triple-t3 term)))]
  (recur (inc position) (conj rows row) (assoc handles term (triple-handle position)))))))))))

(defn- read-transactions! [buffer]
  (let [row-count (read-count! buffer "TransactionRow count" 24)]
  (mapv (fn [position] (t/->TransactionRow (read-i64-le! buffer "transaction sequence") (read-i64-le! buffer "first operation") (read-i64-le! buffer "operation count"))) (vec (range row-count)))))

(defn- read-operations! [buffer]
  (let [row-count (read-count! buffer "OperationRow count" 25)]
  (mapv (fn [position] (t/->OperationRow (read-i64-le! buffer "operation transaction") (read-i64-le! buffer "operation ordinal") (code-action (read-u8! buffer "operation action")) (read-i64-le! buffer "operation handle"))) (vec (range row-count)))))

(defn- read-index! [buffer width]
  (let [row-count (read-count! buffer "slot index row count" (* width 8))]
  (mapv (fn [position] (mapv (fn [field] (read-i64-le! buffer "slot index handle")) (vec (range width)))) (vec (range row-count)))))

(defn- read-indexes! [buffer]
  (mapv (fn [width] (read-index! buffer width)) [2 2 2 3 3 3]))

(defn- read-payload! [payload ^String space-id]
  (let [buffer (doto (ByteBuffer/wrap payload)
  (.order ByteOrder/LITTLE_ENDIAN))
   dump-version (read-u16-le! buffer "TermStoreDump version")
   payload-flags (read-u16-le! buffer "payload flags")]
  (if (not (= dump-version store/term-store-dump-version)) (fail "fri: invalid TermStore payload version" :invalid-fri-cache) (if (not (= payload-flags PAYLOAD-FLAGS)) (fail "fri: unsupported payload flags" :invalid-fri-cache) (let [next-sequence (read-i64-le! buffer "next sequence")
   atoms (read-atoms! buffer)
   triples (read-triples! buffer atoms)
   transactions (read-transactions! buffer)
   operations (read-operations! buffer)
   indexes (read-indexes! buffer)
   dump (t/->TermStoreDump dump-version space-id next-sequence atoms triples transactions operations)]
  (if (not (= 0 (.remaining buffer))) (fail "fri: trailing bytes in binary payload" :invalid-fri-cache) (if (not (= indexes (index-data triples))) (fail "fri: slot index does not match TripleRow table" :invalid-fri-cache) {:dump dump :indexes indexes})))))))

(defn- validate-dump! [dump ^CacheSource source]
  (if (not (t/term-store-dump? dump)) (fail "fri: invalid cache input" :invalid-fri-cache) (if (not (= store/term-store-dump-version (t/termstoredump-version dump))) (fail "fri: invalid cache input" :invalid-fri-cache) (if (not (= (cachesource-space-id source) (t/termstoredump-space-id dump))) (fail "fri: cache source and TermStore belong to different spaces" :cache-space-mismatch) (let [ctx (store/new-term-store (cachesource-space-id source))]
  (store/load-term-store! ctx dump)
  ctx)))))

(defn- write-bytes! [^String path bytes]
  (let [target (File. path)
   parent (.getParentFile target)
   temporary (File. (str path ".tmp"))]
  (if (some? parent) (do
  (.mkdirs parent)))
  (with-open [stream (FileOutputStream. temporary)]
  (.write stream bytes)
  (.flush stream)
  (.force (.getChannel stream) true))
  (Files/move (.toPath temporary) (.toPath target) (into-array StandardCopyOption [StandardCopyOption/ATOMIC_MOVE StandardCopyOption/REPLACE_EXISTING]))
  nil))

(defn write-fri! [dump ^String path ^CacheSource source]
  (do
  (validate-dump! dump source)
  (let [payload (write-payload! dump)
   payload-sha (sha256-bytes payload)
   buffer (ByteArrayOutputStream.)]
  (.write buffer (strict-utf8 MAGIC "magic"))
  (write-u16-le! buffer FMT)
  (write-u16-le! buffer FLAGS)
  (write-sized-text! buffer (cachesource-space-id source) "SpaceId")
  (.write buffer (.parseHex (HexFormat/of) (cachesource-fingerprint source)))
  (write-i64-le! buffer (cachesource-valid-bytes source) "source position")
  (.write buffer payload-sha)
  (write-i64-le! buffer (alength payload) "payload length")
  (.write buffer payload)
  (let [bytes (.toByteArray buffer)]
  (write-bytes! path bytes)
  (->CacheReceipt FMT (cachesource-space-id source) (cachesource-fingerprint source) (cachesource-valid-bytes source) (sha256 bytes))))))

(defn- read-envelope! [^String path]
  (try
  (let [bytes (Files/readAllBytes (.toPath (File. path)))
   buffer (doto (ByteBuffer/wrap bytes)
  (.order ByteOrder/LITTLE_ENDIAN))
   magic (strict-utf8-string (read-fixed! buffer (count MAGIC) "cache magic") "cache magic")]
  (if (not (= magic MAGIC)) (fail "fri: invalid cache magic" :invalid-fri-cache) (let [format (read-u16-le! buffer "cache format")
   flags (read-u16-le! buffer "cache flags")]
  (if (not (= format FMT)) (fail "fri: unsupported cache format" :invalid-fri-cache) (if (not (= flags FLAGS)) (fail "fri: unsupported cache flags" :invalid-fri-cache) (let [space-id (read-sized-text! buffer "SpaceId")
   fingerprint (hex (read-fixed! buffer FINGERPRINT-BYTES "source fingerprint"))
   source-position (read-i64-le! buffer "source position")
   payload-sha (read-fixed! buffer FINGERPRINT-BYTES "payload checksum")
   payload-length (read-i64-le! buffer "payload length")]
  (if (or (< source-position 0) (or (< payload-length 0) (> payload-length 2147483647))) (fail "fri: invalid source position or payload length" :invalid-fri-cache) (let [payload (read-fixed! buffer payload-length "cache payload")]
  (if (not (= 0 (.remaining buffer))) (fail "fri: cache has trailing bytes" :invalid-fri-cache) {:space-id space-id :fingerprint fingerprint :source-position source-position :payload-sha payload-sha :payload payload})))))))))
  (catch clojure.lang.ExceptionInfo error
    (throw error))
  (catch Throwable error
    (throw (ex-info "fri: cache is truncated or malformed" {:type :invalid-fri-cache :cause (str error)})))))

(defn open-fri! [^String path ^CacheSource source]
  (let [envelope (read-envelope! path)
   payload (:payload envelope)
   stored-space (:space-id envelope)
   stored-fingerprint (:fingerprint envelope)
   stored-position (:source-position envelope)
   stored-sha (:payload-sha envelope)]
  (if (not (= stored-space (cachesource-space-id source))) (fail "fri: cache belongs to a different SpaceId" :cache-space-mismatch) (if (not (and (= stored-fingerprint (cachesource-fingerprint source)) (= stored-position (cachesource-valid-bytes source)))) (fail "fri: cache does not match the canonical Beagle Store log prefix" :cache-source-mismatch) (if (not (Arrays/equals stored-sha (sha256-bytes payload))) (fail "fri: cache payload checksum mismatch" :invalid-fri-cache) (let [cache-data (read-payload! payload stored-space)
   dump (:dump cache-data)
   ctx (validate-dump! dump source)]
  (->CacheImage source dump (:indexes cache-data) ctx)))))))

(defn- atom-value [row]
  (let [kind (t/atomrow-kind row)]
  (cond
  (= kind :string) (t/atomrow-string-value row)
  (= kind :int) (t/atomrow-int-value row)
  (= kind :float) (t/atomrow-float-value row)
  (= kind :bool) (t/atomrow-bool-value row)
  (= kind :keyword) (t/atomrow-keyword-value row)
  (= kind :instant) (t/atomrow-instant-value row)
  :else (fail "fri: AtomRow has an unknown kind" :invalid-fri-cache))))

(defn- ^Boolean atom-handle? [handle]
  (= 0 (mod handle 2)))

(defn- handle-position [handle]
  (quot handle 2))

(defn- resolve-handle [dump handle]
  (let [position (handle-position handle)]
  (if (atom-handle? handle) (atom-value (nth (t/termstoredump-atoms dump) position)) (let [row (nth (t/termstoredump-triples dump) position)]
  (t/triple (resolve-handle dump (t/triplerow-t1 row)) (resolve-handle dump (t/triplerow-t2 row)) (resolve-handle dump (t/triplerow-t3 row)))))))

(defn- term-handles [dump]
  (into {} (concat (map-indexed (fn [position row] [(atom-value row) (atom-handle position)]) (t/termstoredump-atoms dump)) (map-indexed (fn [position row] [(resolve-handle dump (triple-handle position)) (triple-handle position)]) (t/termstoredump-triples dump)))))

(defn- index-matches [image index-position keys]
  (let [dump (cacheimage-dump image)
   handles (term-handles dump)
   key-handles (mapv (fn [term] (get handles term)) keys)]
  (if (some nil? key-handles) [] (let [entries (nth (cacheimage-indexes image) index-position)
   key-count (count key-handles)]
  (mapv (fn [entry] (resolve-handle dump (nth entry key-count))) (filter (fn [entry] (= key-handles (subvec entry 0 key-count))) entries))))))

(defn- live-positions-as-of [image sequence]
  (if (< sequence 0) (fail "fri: as-of sequence must be non-negative" :invalid-as-of-sequence) (let [dump (cacheimage-dump image)
   operations (t/termstoredump-operations dump)]
  (loop [position 0
   active {}
   live []]
  (if (or (>= position (count operations)) (> (t/operationrow-tx-sequence (nth operations position)) sequence)) (vec (keep-indexed (fn [index ^Boolean present?] (if present? (do
  index))) live)) (let [row (nth operations position)
   handle (t/operationrow-triple-handle row)
   positions (get active handle [])]
  (if (= t/assert-action (t/operationrow-action row)) (recur (inc position) (assoc active handle (conj positions position)) (conj live true)) (if (empty? positions) (recur (inc position) active (conj live false)) (let [target (peek positions)]
  (recur (inc position) (assoc active handle (pop positions)) (conj (assoc live target false) false)))))))))))

(defn- occurrence-event [dump position]
  (let [row (nth (t/termstoredump-operations dump) position)
   transaction (t/transaction-coordinate (t/termstoredump-space-id dump) (t/operationrow-tx-sequence row))
   occurrence (t/occurrence-coordinate transaction (t/operationrow-ordinal row))
   proposition (resolve-handle dump (t/operationrow-triple-handle row))]
  (t/operation-occurrence occurrence (t/operationrow-action row) proposition)))

(defn close-fri! [image]
  nil)

(defn restore-store! [image target]
  (store/load-term-store! target (cacheimage-dump image)))

(defn ^String space-id [image]
  (cachesource-space-id (cacheimage-source image)))

(defn ^String source-fingerprint [image]
  (cachesource-fingerprint (cacheimage-source image)))

(defn source-position [image]
  (cachesource-valid-bytes (cacheimage-source image)))

(defn transaction-count [image]
  (store/transaction-count (cacheimage-store image)))

(defn operation-count [image]
  (store/operation-count (cacheimage-store image)))

(defn occurrences [image]
  (store/occurrences (cacheimage-store image)))

(defn withdrawals [image]
  (store/withdrawals (cacheimage-store image)))

(defn live-occurrences [image]
  (store/live-occurrences (cacheimage-store image)))

(defn live-propositions [image]
  (store/live-propositions (cacheimage-store image)))

(defn by-t1 [image term]
  (index-matches image 0 [term]))

(defn by-t2 [image term]
  (index-matches image 1 [term]))

(defn by-t3 [image term]
  (index-matches image 2 [term]))

(defn by-t12 [image t1 t2]
  (index-matches image 3 [t1 t2]))

(defn by-t23 [image t2 t3]
  (index-matches image 4 [t2 t3]))

(defn by-t13 [image t1 t3]
  (index-matches image 5 [t1 t3]))

(defn live-occurrences-as-of [image sequence]
  (let [dump (cacheimage-dump image)]
  (mapv (fn [position] (occurrence-event dump position)) (live-positions-as-of image sequence))))

(defn live-propositions-as-of [image sequence]
  (let [dump (cacheimage-dump image)]
  (mapv (fn [position] (resolve-handle dump (t/operationrow-triple-handle (nth (t/termstoredump-operations dump) position)))) (live-positions-as-of image sequence))))
