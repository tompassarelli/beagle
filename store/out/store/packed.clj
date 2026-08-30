(ns store.packed
  (:require [store.rpc :as rpc]
            [store.types :as t])
  (:import [java.io ByteArrayOutputStream]
           [java.io File]
           [java.io RandomAccessFile]
           [java.nio ByteBuffer]
           [java.nio ByteOrder]
           [java.nio CharBuffer]
           [java.nio.channels FileChannel$MapMode]
           [java.nio.charset CodingErrorAction]
           [java.nio.charset StandardCharsets]
           [java.nio.file Files]
           [java.nio.file StandardCopyOption]
           [java.security MessageDigest]
           [java.util Arrays]))

(def ^String magic "BEAGLEPACKEDV1")

(def ^String manifest-magic "BEAGLEPKMANV1")

(def format-version 1)

(def page-bytes 65536)

(def ^String schema-id "store/packed-checkpoint-v1+TermStoreDumpV2+TermCodecV1")

(def max-term-bytes 1073741824)

(def max-term-nodes 1048576)

(def max-term-depth 256)

(def digest-bytes 32)

(def ^String manifest-suffix ".manifest")

(def ^String page-suffix ".pages")

(def atom-offsets-section 1)

(def atom-payload-section 2)

(def atom-lookup-section 3)

(def triple-t1-section 4)

(def triple-t2-section 5)

(def triple-t3-section 6)

(def transaction-sequence-section 7)

(def transaction-first-operation-section 8)

(def transaction-operation-count-section 9)

(def operation-sequence-section 10)

(def operation-ordinal-section 11)

(def operation-action-section 12)

(def operation-triple-section 13)

(def withdrawal-target-section 14)

(def active-handle-section 15)

(def active-offset-section 16)

(def active-count-section 17)

(def active-run-section 18)

(def spo-section 19)

(def pos-section 20)

(def osp-section 21)

(def section-count 21)

(defrecord CheckpointSource [space-id revision schema log-valid-bytes log-prefix-sha256])

(defn checkpointsource-space-id [r] (:space-id r))

(defn checkpointsource-revision [r] (:revision r))

(defn checkpointsource-schema [r] (:schema r))

(defn checkpointsource-log-valid-bytes [r] (:log-valid-bytes r))

(defn checkpointsource-log-prefix-sha256 [r] (:log-prefix-sha256 r))

(defrecord CheckpointManifest [path component space-id revision next-sequence schema log-valid-bytes log-prefix-sha256 page-sha256 atom-count triple-count transaction-count operation-count active-count active-run-count mapped-bytes])

(defn checkpointmanifest-path [r] (:path r))

(defn checkpointmanifest-component [r] (:component r))

(defn checkpointmanifest-space-id [r] (:space-id r))

(defn checkpointmanifest-revision [r] (:revision r))

(defn checkpointmanifest-next-sequence [r] (:next-sequence r))

(defn checkpointmanifest-schema [r] (:schema r))

(defn checkpointmanifest-log-valid-bytes [r] (:log-valid-bytes r))

(defn checkpointmanifest-log-prefix-sha256 [r] (:log-prefix-sha256 r))

(defn checkpointmanifest-page-sha256 [r] (:page-sha256 r))

(defn checkpointmanifest-atom-count [r] (:atom-count r))

(defn checkpointmanifest-triple-count [r] (:triple-count r))

(defn checkpointmanifest-transaction-count [r] (:transaction-count r))

(defn checkpointmanifest-operation-count [r] (:operation-count r))

(defn checkpointmanifest-active-count [r] (:active-count r))

(defn checkpointmanifest-active-run-count [r] (:active-run-count r))

(defn checkpointmanifest-mapped-bytes [r] (:mapped-bytes r))

(defrecord Section [id width offset bytes])

(defn section-id [r] (:id r))

(defn section-width [r] (:width r))

(defn section-offset [r] (:offset r))

(defn section-bytes [r] (:bytes r))

(defrecord PackedPrefix [manifest buffers])

(defn packedprefix-manifest [r] (:manifest r))

(defn packedprefix-buffers [r] (:buffers r))

(defn- fail! [code ^String message]
  (throw (ex-info message {:type code :store/code code})))

(defn- ^Boolean valid-fingerprint? [^String value]
  (some? (re-matches #"[0-9a-f]{64}" value)))

(defn ^CheckpointSource checkpoint-source! [^String space-id revision log-valid-bytes ^String log-prefix-sha256]
  (if (and (pos? (count space-id)) (and (>= revision 0) (and (>= log-valid-bytes 0) (valid-fingerprint? log-prefix-sha256)))) (->CheckpointSource space-id revision schema-id log-valid-bytes log-prefix-sha256) (fail! :invalid-packed-source "packed Store source requires SpaceId, revision, byte position, and sha256")))

(defn- atom-value! [row]
  (let [kind (t/atomrow-kind row)]
  (cond
  (= kind :string) (t/atomrow-string-value row)
  (= kind :int) (t/atomrow-int-value row)
  (= kind :float) (t/atomrow-float-value row)
  (= kind :bool) (t/atomrow-bool-value row)
  (= kind :keyword) (t/atomrow-keyword-value row)
  (= kind :instant) (t/atomrow-instant-value row)
  :else (fail! :invalid-packed-checkpoint "packed Store AtomRow has an unknown kind"))))

(defn- atom-row! [value]
  (cond
  (string? value) (t/->AtomRow :string value nil nil nil nil nil)
  (integer? value) (t/->AtomRow :int nil value nil nil nil nil)
  (and (number? value) (not (integer? value))) (t/->AtomRow :float nil nil (double value) nil nil nil)
  (boolean? value) (t/->AtomRow :bool nil nil nil value nil nil)
  (keyword? value) (t/->AtomRow :keyword nil nil nil nil value nil)
  (t/instant? value) (t/->AtomRow :instant nil nil nil nil nil value)
  :else (fail! :invalid-packed-checkpoint "packed Store atom payload decoded outside Atom")))

(defn- encode-term [value]
  (let [^ByteArrayOutputStream out (ByteArrayOutputStream.)]
  (rpc/write-term-codec-v1! out value max-term-bytes max-term-nodes max-term-depth)
  (.toByteArray out)))

(defn term-byte-count! [value]
  (alength (encode-term value)))

(defn- ^String hex [bytes]
  (apply str (map (fn [value] (format "%02x" (bit-and 255 (int value)))) bytes)))

(defn- sha256-bytes [bytes]
  (.digest (MessageDigest/getInstance "SHA-256") bytes))

(defn- ^String sha256-file [^String path]
  (let [^MessageDigest digest (MessageDigest/getInstance "SHA-256")
   ^bytes chunk (byte-array page-bytes)]
  (with-open [input (RandomAccessFile. path "r")]
  (loop [read-count (.read input chunk 0 page-bytes)]
  (if (< read-count 0) nil (do
  (.update digest chunk 0 read-count)
  (recur (.read input chunk 0 page-bytes))))))
  (hex (.digest digest))))

(defn- hash64 [bytes]
  (.getLong (doto (ByteBuffer/wrap (sha256-bytes bytes))
  (.order ByteOrder/LITTLE_ENDIAN))))

(defn- align-page [value]
  (* page-bytes (quot (+ value (dec page-bytes)) page-bytes)))

(defn- checked-i32! [value]
  (if (and (>= value -2147483648) (<= value 2147483647)) value (fail! :packed-capacity-exceeded "packed Store term identifier exceeds signed 32-bit capacity")))

(defn- ^ByteBuffer bytes-buffer [size]
  (doto (ByteBuffer/allocate size)
  (.order ByteOrder/LITTLE_ENDIAN)))

(defn- buffer-bytes [^ByteBuffer buffer]
  (let [^bytes bytes (byte-array (.limit buffer))
   ^ByteBuffer view (.duplicate buffer)]
  (.position view 0)
  (.get view bytes)
  bytes))

(defn- long-column [values]
  (let [^ByteBuffer buffer (bytes-buffer (* 8 (count values)))]
  (doseq [value values]
  (.putLong buffer value))
  (buffer-bytes buffer)))

(defn- int-column! [values]
  (let [^ByteBuffer buffer (bytes-buffer (* 4 (count values)))]
  (doseq [value values]
  (.putInt buffer (int (checked-i32! value))))
  (buffer-bytes buffer)))

(defn- action-code! [action]
  (cond
  (= action t/assert-action) 1
  (= action t/retract-action) 2
  :else (fail! :invalid-packed-checkpoint "packed Store operation action is invalid")))

(defn- code-action! [value]
  (cond
  (= value 1) t/assert-action
  (= value 2) t/retract-action
  :else (fail! :invalid-packed-checkpoint "packed Store operation action code is invalid")))

(defn- prefix-count [prefix section]
  (if (nil? prefix) 0 (let [^CheckpointManifest manifest (packedprefix-manifest prefix)]
  (cond
  (= section :atoms) (checkpointmanifest-atom-count manifest)
  (= section :triples) (checkpointmanifest-triple-count manifest)
  (= section :transactions) (checkpointmanifest-transaction-count manifest)
  (= section :operations) (checkpointmanifest-operation-count manifest)
  :else 0))))

(declare atom-row-at! triple-row-at! transaction-row-at! operation-row-at!)

(defn- merged-atom-count [prefix tail]
  (+ (prefix-count prefix :atoms) (count (t/termstoredump-atoms tail))))

(defn- merged-triple-count [prefix tail]
  (+ (prefix-count prefix :triples) (count (t/termstoredump-triples tail))))

(defn- merged-transaction-count [prefix tail]
  (+ (prefix-count prefix :transactions) (count (t/termstoredump-transactions tail))))

(defn- merged-operation-count [prefix tail]
  (+ (prefix-count prefix :operations) (count (t/termstoredump-operations tail))))

(defn- merged-atom-at! [prefix tail position]
  (let [base (prefix-count prefix :atoms)]
  (if (< position base) (atom-row-at! prefix position) (nth (t/termstoredump-atoms tail) (- position base)))))

(defn- merged-triple-at! [prefix tail position]
  (let [base (prefix-count prefix :triples)]
  (if (< position base) (triple-row-at! prefix position) (nth (t/termstoredump-triples tail) (- position base)))))

(defn- merged-transaction-at! [prefix tail position]
  (let [base (prefix-count prefix :transactions)]
  (if (< position base) (transaction-row-at! prefix position) (nth (t/termstoredump-transactions tail) (- position base)))))

(defn- merged-operation-at! [prefix tail position]
  (let [base (prefix-count prefix :operations)]
  (if (< position base) (operation-row-at! prefix position) (nth (t/termstoredump-operations tail) (- position base)))))

(defn- atom-sections! [prefix tail]
  (let [total (merged-atom-count prefix tail)
   ^longs offsets (long-array (+ total 1))
   ^ByteArrayOutputStream payload (ByteArrayOutputStream.)
   lookups (loop [position 0
   entries []]
  (if (>= position total) entries (let [bytes (encode-term (atom-value! (merged-atom-at! prefix tail position)))]
  (aset-long offsets position (.size payload))
  (.write payload bytes)
  (recur (+ position 1) (conj entries [(hash64 bytes) position])))))]
  (aset-long offsets total (.size payload))
  (let [^ByteBuffer lookup-buffer (bytes-buffer (* total 12))]
  (doseq [entry (sort-by (fn [entry] [(nth entry 0) (nth entry 1)]) lookups)]
  (.putLong lookup-buffer (nth entry 0))
  (.putInt lookup-buffer (int (nth entry 1))))
  {:offsets (long-column offsets) :payload (.toByteArray payload) :lookup (buffer-bytes lookup-buffer)})))

(defn- triple-columns! [prefix tail]
  (let [total (merged-triple-count prefix tail)
   ^ints t1 (int-array total)
   ^ints t2 (int-array total)
   ^ints t3 (int-array total)]
  (loop [position 0]
  (if (>= position total) nil (let [row (merged-triple-at! prefix tail position)]
  (aset-int t1 position (int (checked-i32! (t/triplerow-t1 row))))
  (aset-int t2 position (int (checked-i32! (t/triplerow-t2 row))))
  (aset-int t3 position (int (checked-i32! (t/triplerow-t3 row))))
  (recur (+ position 1)))))
  {:t1 t1 :t2 t2 :t3 t3}))

(defn- history-columns! [prefix tail]
  (let [transactions (merged-transaction-count prefix tail)
   operations (merged-operation-count prefix tail)
   ^longs tx-seq (long-array transactions)
   ^longs tx-first (long-array transactions)
   ^ints tx-count (int-array transactions)
   ^longs op-seq (long-array operations)
   ^ints op-ordinal (int-array operations)
   ^bytes op-action (byte-array operations)
   ^ints op-triple (int-array operations)]
  (loop [position 0]
  (if (>= position transactions) nil (let [row (merged-transaction-at! prefix tail position)]
  (aset-long tx-seq position (t/transactionrow-sequence row))
  (aset-long tx-first position (t/transactionrow-first-operation row))
  (aset-int tx-count position (int (checked-i32! (t/transactionrow-operation-count row))))
  (recur (+ position 1)))))
  (loop [position 0]
  (if (>= position operations) nil (let [row (merged-operation-at! prefix tail position)]
  (aset-long op-seq position (t/operationrow-tx-sequence row))
  (aset-int op-ordinal position (int (checked-i32! (t/operationrow-ordinal row))))
  (aset-byte op-action position (byte (action-code! (t/operationrow-action row))))
  (aset-int op-triple position (int (checked-i32! (t/operationrow-triple-handle row))))
  (recur (+ position 1)))))
  {:tx-seq tx-seq :tx-first tx-first :tx-count tx-count :op-seq op-seq :op-ordinal op-ordinal :op-action op-action :op-triple op-triple}))

(defn- active-columns! [history]
  (let [op-seq (:op-seq history)
   op-action (:op-action history)
   op-triple (:op-triple history)
   total (alength op-action)
   derived (loop [position 0
   active {}
   withdrawals []]
  (if (>= position total) {:active active :withdrawals withdrawals} (let [handle (aget op-triple position)
   positions (get active handle [])
   action (bit-and 255 (int (aget op-action position)))]
  (if (= action 1) (recur (+ position 1) (assoc active handle (conj positions position)) (conj withdrawals -1)) (if (empty? positions) (recur (+ position 1) active (conj withdrawals -1)) (recur (+ position 1) (assoc active handle (pop positions)) (conj withdrawals (peek positions))))))))
   entries (sort-by first (filter (fn [entry] (pos? (count (second entry)))) (:active derived)))
   ^ints handles (int-array (count entries))
   ^longs offsets (long-array (count entries))
   ^ints counts (int-array (count entries))
   run-count (reduce + (map (fn [entry] (count (second entry))) entries))
   ^longs runs (long-array run-count)]
  (loop [entry-position 0
   run-position 0]
  (if (>= entry-position (count entries)) nil (let [entry (nth entries entry-position)
   handle (first entry)
   positions (second entry)]
  (aset-int handles entry-position (int (checked-i32! handle)))
  (aset-long offsets entry-position run-position)
  (aset-int counts entry-position (int (checked-i32! (count positions))))
  (loop [source-position 0]
  (if (>= source-position (count positions)) nil (do
  (aset-long runs (+ run-position source-position) (nth positions source-position))
  (recur (+ source-position 1)))))
  (recur (+ entry-position 1) (+ run-position (count positions))))))
  {:withdrawals (long-column (:withdrawals derived)) :handles handles :offsets offsets :counts counts :runs runs :active-count (count entries) :run-count run-count}))

(defn- index-bytes! [prefix tail order]
  (let [total (merged-triple-count prefix tail)
   entries (loop [position 0
   collected []]
  (if (>= position total) collected (let [row (merged-triple-at! prefix tail position)
   a (t/triplerow-t1 row)
   b (t/triplerow-t2 row)
   c (t/triplerow-t3 row)
   key (cond
  (= order :spo) [a b c position]
  (= order :pos) [b c a position]
  :else [c a b position])]
  (recur (+ position 1) (conj collected [key position row])))))
   ordered (sort-by first entries)
   ^ByteBuffer buffer (bytes-buffer (* total 16))]
  (doseq [entry ordered]
  (let [position (second entry)
   row (nth entry 2)
   a (t/triplerow-t1 row)
   b (t/triplerow-t2 row)
   c (t/triplerow-t3 row)]
  (cond
  (= order :spo) (do
  (.putInt buffer (int a))
  (.putInt buffer (int b))
  (.putInt buffer (int c)))
  (= order :pos) (do
  (.putInt buffer (int b))
  (.putInt buffer (int c))
  (.putInt buffer (int a)))
  :else (do
  (.putInt buffer (int c))
  (.putInt buffer (int a))
  (.putInt buffer (int b))))
  (.putInt buffer (int position))))
  (buffer-bytes buffer)))

(defn- ^Section section [id width bytes]
  (->Section id width 0 bytes))

(defn- place-sections [sections]
  (loop [remaining sections
   offset page-bytes
   placed []]
  (if (empty? remaining) placed (let [^Section current (first remaining)
   aligned (align-page offset)
   bytes (section-bytes current)]
  (recur (next remaining) (+ aligned (alength bytes)) (conj placed (->Section (section-id current) (section-width current) aligned bytes)))))))

(defn- page-header [sections atoms triples transactions operations next-sequence active-count active-run-count]
  (let [^ByteBuffer buffer (bytes-buffer page-bytes)
   magic-bytes (.getBytes magic StandardCharsets/UTF_8)]
  (.put buffer magic-bytes)
  (.position buffer 16)
  (.putInt buffer format-version)
  (.putInt buffer page-bytes)
  (.putInt buffer section-count)
  (.putInt buffer 0)
  (.putLong buffer atoms)
  (.putLong buffer triples)
  (.putLong buffer transactions)
  (.putLong buffer operations)
  (.putLong buffer next-sequence)
  (.putLong buffer active-count)
  (.putLong buffer active-run-count)
  (.position buffer 128)
  (doseq [entry sections]
  (.putInt buffer (section-id entry))
  (.putInt buffer (section-width entry))
  (.putLong buffer (section-offset entry))
  (.putLong buffer (alength (section-bytes entry))))
  (buffer-bytes buffer)))

(defn- zero-fill! [^RandomAccessFile file amount]
  (let [^bytes zeroes (byte-array page-bytes)]
  (loop [remaining amount]
  (if (<= remaining 0) nil (let [chunk (min remaining page-bytes)]
  (.write file zeroes 0 chunk)
  (recur (- remaining chunk)))))))

(defn- write-page-file! [^String path header sections]
  (with-open [file (RandomAccessFile. path "rw")]
  (.setLength file 0)
  (.write file header 0 (alength header))
  (loop [remaining sections
   position page-bytes]
  (if (empty? remaining) nil (let [^Section entry (first remaining)
   offset (section-offset entry)
   bytes (section-bytes entry)]
  (zero-fill! file (- offset position))
  (.write file bytes 0 (alength bytes))
  (recur (next remaining) (+ offset (alength bytes))))))
  (.force (.getChannel file) true)
  (.length file)))

(defn- write-u8! [out value]
  (.write out (int (bit-and 255 value)))
  nil)

(defn- write-u32-le! [out value]
  (loop [offset 0]
  (if (>= offset 4) nil (do
  (write-u8! out (unsigned-bit-shift-right value (* offset 8)))
  (recur (+ offset 1))))))

(defn- write-i64-le! [out value]
  (loop [offset 0]
  (if (>= offset 8) nil (do
  (write-u8! out (unsigned-bit-shift-right value (* offset 8)))
  (recur (+ offset 1))))))

(defn- strict-utf8 [^String value]
  (let [encoder (doto (.newEncoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))
   ^ByteBuffer buffer (.encode encoder (CharBuffer/wrap value))
   ^bytes bytes (byte-array (.remaining buffer))]
  (.get buffer bytes)
  bytes))

(defn- write-text! [out ^String value]
  (let [bytes (strict-utf8 value)]
  (write-u32-le! out (alength bytes))
  (.write out bytes)
  nil))

(declare read-manifest! hex-bytes!)

(defn- manifest-bytes! [^CheckpointManifest manifest]
  (let [^ByteArrayOutputStream out (ByteArrayOutputStream.)]
  (.write out (.getBytes manifest-magic StandardCharsets/UTF_8))
  (loop [position (count manifest-magic)]
  (if (>= position 16) nil (do
  (write-u8! out 0)
  (recur (+ position 1)))))
  (write-u32-le! out format-version)
  (write-u32-le! out page-bytes)
  (write-i64-le! out (checkpointmanifest-revision manifest))
  (write-i64-le! out (checkpointmanifest-next-sequence manifest))
  (write-i64-le! out (checkpointmanifest-log-valid-bytes manifest))
  (write-i64-le! out (checkpointmanifest-atom-count manifest))
  (write-i64-le! out (checkpointmanifest-triple-count manifest))
  (write-i64-le! out (checkpointmanifest-transaction-count manifest))
  (write-i64-le! out (checkpointmanifest-operation-count manifest))
  (write-i64-le! out (checkpointmanifest-active-count manifest))
  (write-i64-le! out (checkpointmanifest-active-run-count manifest))
  (write-i64-le! out (checkpointmanifest-mapped-bytes manifest))
  (.write out (hex-bytes! (checkpointmanifest-log-prefix-sha256 manifest)))
  (.write out (hex-bytes! (checkpointmanifest-page-sha256 manifest)))
  (write-text! out (checkpointmanifest-space-id manifest))
  (write-text! out (checkpointmanifest-schema manifest))
  (write-text! out (checkpointmanifest-component manifest))
  (let [body (.toByteArray out)]
  (.write out (sha256-bytes body))
  (.toByteArray out))))

(defn- hex-value! [value]
  (cond
  (and (>= value 48) (<= value 57)) (- value 48)
  (and (>= value 97) (<= value 102)) (+ 10 (- value 97))
  :else (fail! :invalid-packed-manifest "packed Store manifest digest is not lowercase hexadecimal")))

(defn- hex-bytes! [^String value]
  (if (not (valid-fingerprint? value)) (fail! :invalid-packed-manifest "packed Store manifest digest is invalid") (let [^bytes bytes (byte-array digest-bytes)]
  (loop [position 0]
  (if (>= position digest-bytes) bytes (let [left (int (.charAt value (* position 2)))
   right (int (.charAt value (+ (* position 2) 1)))]
  (aset-byte bytes position (unchecked-byte (+ (* 16 (hex-value! left)) (hex-value! right))))
  (recur (+ position 1))))))))

(defn- atomic-move! [^String source ^String target]
  (Files/move (.toPath (File. source)) (.toPath (File. target)) (into-array StandardCopyOption [StandardCopyOption/ATOMIC_MOVE StandardCopyOption/REPLACE_EXISTING]))
  nil)

(defn- write-manifest-last! [^String path ^CheckpointManifest manifest]
  (let [^String temporary (str path ".tmp")
   bytes (manifest-bytes! manifest)]
  (with-open [file (RandomAccessFile. temporary "rw")]
  (.setLength file 0)
  (.write file bytes 0 (alength bytes))
  (.force (.getChannel file) true))
  (atomic-move! temporary path)))

(defn- ensure-directory! [^String path]
  (Files/createDirectories (.toPath (File. path)) (make-array java.nio.file.attribute.FileAttribute 0))
  nil)

(defn ^CheckpointManifest write-checkpoint! [prefix tail ^String directory ^CheckpointSource source]
  (if (not (= (checkpointsource-space-id source) (t/termstoredump-space-id tail))) (fail! :packed-space-mismatch "packed Store source and tail belong to different spaces") nil)
  (if (not (= schema-id (checkpointsource-schema source))) (fail! :packed-schema-mismatch "packed Store source uses another schema") nil)
  (let [atoms (merged-atom-count prefix tail)
   triples (merged-triple-count prefix tail)
   transactions (merged-transaction-count prefix tail)
   operations (merged-operation-count prefix tail)]
  (if (or (> atoms 1073741823) (> triples 1073741823)) (fail! :packed-capacity-exceeded "packed Store term table exceeds the 32-bit identifier envelope") nil)
  (ensure-directory! directory)
  (let [atom-data (atom-sections! prefix tail)
   triple-data (triple-columns! prefix tail)
   history (history-columns! prefix tail)
   active (active-columns! history)
   sections (place-sections [(section atom-offsets-section 8 (:offsets atom-data)) (section atom-payload-section 0 (:payload atom-data)) (section atom-lookup-section 12 (:lookup atom-data)) (section triple-t1-section 4 (int-column! (:t1 triple-data))) (section triple-t2-section 4 (int-column! (:t2 triple-data))) (section triple-t3-section 4 (int-column! (:t3 triple-data))) (section transaction-sequence-section 8 (long-column (:tx-seq history))) (section transaction-first-operation-section 8 (long-column (:tx-first history))) (section transaction-operation-count-section 4 (int-column! (:tx-count history))) (section operation-sequence-section 8 (long-column (:op-seq history))) (section operation-ordinal-section 4 (int-column! (:op-ordinal history))) (section operation-action-section 1 (:op-action history)) (section operation-triple-section 4 (int-column! (:op-triple history))) (section withdrawal-target-section 8 (:withdrawals active)) (section active-handle-section 4 (int-column! (:handles active))) (section active-offset-section 8 (long-column (:offsets active))) (section active-count-section 4 (int-column! (:counts active))) (section active-run-section 8 (long-column (:runs active))) (section spo-section 16 (index-bytes! prefix tail :spo)) (section pos-section 16 (index-bytes! prefix tail :pos)) (section osp-section 16 (index-bytes! prefix tail :osp))])
   header (page-header sections atoms triples transactions operations (t/termstoredump-next-sequence tail) (:active-count active) (:run-count active))
   revision (checkpointsource-revision source)
   ^String stem (format "checkpoint-%019d" revision)
   ^String temporary (str directory "/." stem ".pages.tmp")
   mapped-bytes (write-page-file! temporary header sections)
   ^String page-sha (sha256-file temporary)
   ^String component (str stem "-" (subs page-sha 0 16) page-suffix)
   ^String final-page (str directory "/" component)
   ^String manifest-path (str directory "/" stem manifest-suffix)
   ^CheckpointManifest manifest (->CheckpointManifest manifest-path component (checkpointsource-space-id source) revision (t/termstoredump-next-sequence tail) schema-id (checkpointsource-log-valid-bytes source) (checkpointsource-log-prefix-sha256 source) page-sha atoms triples transactions operations (:active-count active) (:run-count active) mapped-bytes)]
  (atomic-move! temporary final-page)
  (write-manifest-last! manifest-path manifest)
  manifest)))

(defn- ensure-remaining! [^ByteBuffer buffer amount ^String context]
  (if (and (>= amount 0) (>= (.remaining buffer) amount)) nil (fail! :invalid-packed-manifest (str "packed Store manifest is truncated in " context))))

(defn- read-u32! [^ByteBuffer buffer ^String context]
  (ensure-remaining! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer)))

(defn- read-i64! [^ByteBuffer buffer ^String context]
  (ensure-remaining! buffer 8 context)
  (.getLong buffer))

(defn- read-fixed! [^ByteBuffer buffer amount ^String context]
  (ensure-remaining! buffer amount context)
  (let [^bytes bytes (byte-array amount)]
  (.get buffer bytes)
  bytes))

(defn- ^String read-text! [^ByteBuffer buffer ^String context]
  (let [amount (read-u32! buffer context)]
  (if (> amount 1048576) (fail! :invalid-packed-manifest "packed Store manifest text exceeds its bound") (let [bytes (read-fixed! buffer amount context)
   decoder (doto (.newDecoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))]
  (str (.decode decoder (ByteBuffer/wrap bytes)))))))

(defn- ^Boolean magic-valid? [bytes ^String expected]
  (= expected (String. bytes StandardCharsets/UTF_8)))

(defn- manifest-filename-revision! [^String path]
  (let [^String name (.getName (File. path))
   matched (re-matches #"checkpoint-([0-9]{19})\.manifest" name)]
  (if (nil? matched) (fail! :invalid-packed-manifest "packed Store manifest filename is invalid") (try
  (Long/parseLong (nth matched 1))
  (catch Throwable _error
    (fail! :invalid-packed-manifest "packed Store manifest filename revision is invalid"))))))

(defn ^CheckpointManifest read-manifest! [^String path]
  (let [filename-revision (manifest-filename-revision! path)
   bytes (Files/readAllBytes (.toPath (File. path)))
   total (alength bytes)]
  (if (< total (+ 160 digest-bytes)) (fail! :invalid-packed-manifest "packed Store manifest is too short") nil)
  (let [body-length (- total digest-bytes)
   body (Arrays/copyOfRange bytes 0 body-length)
   stored (Arrays/copyOfRange bytes body-length total)]
  (if (not (Arrays/equals stored (sha256-bytes body))) (fail! :invalid-packed-manifest "packed Store manifest checksum does not match") nil)
  (let [^ByteBuffer buffer (doto (ByteBuffer/wrap body)
  (.order ByteOrder/LITTLE_ENDIAN))
   magic-bytes (read-fixed! buffer (count manifest-magic) "magic")]
  (if (not (magic-valid? magic-bytes manifest-magic)) (fail! :invalid-packed-manifest "packed Store manifest magic does not match") nil)
  (ensure-remaining! buffer (- 16 (count manifest-magic)) "magic padding")
  (.position buffer 16)
  (let [version (read-u32! buffer "version")
   page-size (read-u32! buffer "page size")
   revision (read-i64! buffer "revision")
   next-sequence (read-i64! buffer "next sequence")
   valid-bytes (read-i64! buffer "log byte position")
   atoms (read-i64! buffer "atom count")
   triples (read-i64! buffer "triple count")
   transactions (read-i64! buffer "transaction count")
   operations (read-i64! buffer "operation count")
   active-count (read-i64! buffer "active count")
   active-runs (read-i64! buffer "active run count")
   mapped-bytes (read-i64! buffer "mapped byte count")
   ^String prefix-sha (hex (read-fixed! buffer digest-bytes "log prefix checksum"))
   ^String page-sha (hex (read-fixed! buffer digest-bytes "page checksum"))
   ^String space (read-text! buffer "SpaceId")
   ^String schema (read-text! buffer "schema")
   ^String component (read-text! buffer "component")]
  (if (not (= 0 (.remaining buffer))) (fail! :invalid-packed-manifest "packed Store manifest has trailing bytes") nil)
  (if (not (= filename-revision revision)) (fail! :invalid-packed-manifest "packed Store manifest filename revision does not match its body") nil)
  (if (not (and (= version format-version) (and (= page-size page-bytes) (and (= schema schema-id) (and (>= revision 0) (and (= next-sequence (+ revision 1)) (and (>= valid-bytes 0) (and (>= atoms 0) (and (>= triples 0) (and (>= transactions 0) (and (>= operations 0) (and (>= active-count 0) (and (>= active-runs 0) (>= mapped-bytes page-bytes)))))))))))))) (fail! :invalid-packed-manifest "packed Store manifest fields are inconsistent") nil)
  (if (not (and (pos? (count space)) (and (valid-fingerprint? prefix-sha) (and (valid-fingerprint? page-sha) (some? (re-matches #"checkpoint-[0-9]{19}-[0-9a-f]{16}\.pages" component)))))) (fail! :invalid-packed-manifest "packed Store manifest identity is invalid") nil)
  (->CheckpointManifest path component space revision next-sequence schema valid-bytes prefix-sha page-sha atoms triples transactions operations active-count active-runs mapped-bytes))))))

(defn candidate-manifests [^String directory]
  (let [^File folder (File. directory)
   files (if (.isDirectory folder) (or (.listFiles folder) (make-array File 0)) (make-array File 0))]
  (mapv (fn [^File file] (.getPath file)) (sort-by (fn [^File file] (.getName file)) (fn [left right] (compare right left)) (filter (fn [^File file] (some? (re-matches #"checkpoint-[0-9]{19}\.manifest" (.getName file)))) files)))))

(defn ^CheckpointSource manifest-source! [^CheckpointManifest manifest]
  (checkpoint-source! (checkpointmanifest-space-id manifest) (checkpointmanifest-revision manifest) (checkpointmanifest-log-valid-bytes manifest) (checkpointmanifest-log-prefix-sha256 manifest)))

(defn- ^ByteBuffer buffer [^PackedPrefix prefix id]
  (get (packedprefix-buffers prefix) id))

(defn- section-long [^PackedPrefix prefix id position]
  (.getLong (buffer prefix id) (* position 8)))

(defn- section-int [^PackedPrefix prefix id position]
  (.getInt (buffer prefix id) (* position 4)))

(defn- section-byte [^PackedPrefix prefix id position]
  (bit-and 255 (int (.get (buffer prefix id) position))))

(defn- ^ByteBuffer map-section [^String file offset length]
  (if (= length 0) (bytes-buffer 0) (with-open [random (RandomAccessFile. file "r")]
  (let [channel (.getChannel random)
   mapped (.map channel FileChannel$MapMode/READ_ONLY offset length)]
  (.order mapped ByteOrder/LITTLE_ENDIAN)
  mapped))))

(defn- read-page-table! [^String path ^CheckpointManifest manifest]
  (let [^File file (File. path)
   length (.length file)]
  (if (not (= length (checkpointmanifest-mapped-bytes manifest))) (fail! :invalid-packed-checkpoint "packed Store page length does not match its manifest") nil)
  (with-open [random (RandomAccessFile. file "r")]
  (let [^bytes header (byte-array page-bytes)]
  (.readFully random header)
  (let [^ByteBuffer view (doto (ByteBuffer/wrap header)
  (.order ByteOrder/LITTLE_ENDIAN))
   stored-magic (read-fixed! view (count magic) "page magic")]
  (if (not (magic-valid? stored-magic magic)) (fail! :invalid-packed-checkpoint "packed Store page magic does not match") nil)
  (.position view 16)
  (let [version (.getInt view)
   page-size (.getInt view)
   count-value (.getInt view)
   _reserved (.getInt view)
   atoms (.getLong view)
   triples (.getLong view)
   transactions (.getLong view)
   operations (.getLong view)
   next-sequence (.getLong view)
   active-count (.getLong view)
   active-runs (.getLong view)]
  (if (not (and (= version format-version) (and (= page-size page-bytes) (and (= count-value section-count) (and (= atoms (checkpointmanifest-atom-count manifest)) (and (= triples (checkpointmanifest-triple-count manifest)) (and (= transactions (checkpointmanifest-transaction-count manifest)) (and (= operations (checkpointmanifest-operation-count manifest)) (and (= next-sequence (checkpointmanifest-next-sequence manifest)) (and (= active-count (checkpointmanifest-active-count manifest)) (= active-runs (checkpointmanifest-active-run-count manifest)))))))))))) (fail! :invalid-packed-checkpoint "packed Store page header does not match its manifest") nil)
  (.position view 128)
  (loop [position 0
   prior-end page-bytes
   table {}]
  (if (>= position section-count) table (let [id (.getInt view)
   width (.getInt view)
   offset (.getLong view)
   section-length (.getLong view)
   end (+ offset section-length)]
  (if (not (and (= id (+ position 1)) (and (>= width 0) (and (= offset (align-page offset)) (and (>= offset (align-page prior-end)) (and (>= section-length 0) (<= end length))))))) (fail! :invalid-packed-checkpoint "packed Store page section table is invalid") (recur (+ position 1) end (assoc table id [offset section-length]))))))))))))

(defn- expected-section-length [^CheckpointManifest manifest id]
  (let [atoms (checkpointmanifest-atom-count manifest)
   triples (checkpointmanifest-triple-count manifest)
   transactions (checkpointmanifest-transaction-count manifest)
   operations (checkpointmanifest-operation-count manifest)
   active (checkpointmanifest-active-count manifest)
   runs (checkpointmanifest-active-run-count manifest)]
  (cond
  (= id atom-offsets-section) (* 8 (+ atoms 1))
  (= id atom-payload-section) nil
  (= id atom-lookup-section) (* 12 atoms)
  (or (= id triple-t1-section) (or (= id triple-t2-section) (= id triple-t3-section))) (* 4 triples)
  (or (= id transaction-sequence-section) (= id transaction-first-operation-section)) (* 8 transactions)
  (= id transaction-operation-count-section) (* 4 transactions)
  (= id operation-sequence-section) (* 8 operations)
  (= id operation-ordinal-section) (* 4 operations)
  (= id operation-action-section) operations
  (= id operation-triple-section) (* 4 operations)
  (= id withdrawal-target-section) (* 8 operations)
  (= id active-handle-section) (* 4 active)
  (= id active-offset-section) (* 8 active)
  (= id active-count-section) (* 4 active)
  (= id active-run-section) (* 8 runs)
  (or (= id spo-section) (or (= id pos-section) (= id osp-section))) (* 16 triples)
  :else nil)))

(defn- validate-section-lengths! [table ^CheckpointManifest manifest]
  (loop [id 1]
  (if (> id section-count) nil (let [expected (expected-section-length manifest id)
   entry (get table id)
   actual (nth entry 1)]
  (if (and (some? expected) (not (= expected actual))) (fail! :invalid-packed-checkpoint "packed Store column length is inconsistent") (recur (+ id 1)))))))

(defn- validate-source! [^CheckpointManifest manifest ^CheckpointSource source]
  (cond
  (not (= (checkpointmanifest-space-id manifest) (checkpointsource-space-id source))) (fail! :packed-space-mismatch "packed Store checkpoint belongs to another SpaceId")
  (not (= (checkpointmanifest-revision manifest) (checkpointsource-revision source))) (fail! :packed-source-mismatch "packed Store checkpoint revision does not match STORELOG")
  (not (= (checkpointmanifest-schema manifest) (checkpointsource-schema source))) (fail! :packed-schema-mismatch "packed Store checkpoint schema does not match")
  (not (and (= (checkpointmanifest-log-valid-bytes manifest) (checkpointsource-log-valid-bytes source)) (= (checkpointmanifest-log-prefix-sha256 manifest) (checkpointsource-log-prefix-sha256 source)))) (fail! :packed-source-mismatch "packed Store checkpoint does not match the exact STORELOG prefix")
  :else nil))

(defn ^PackedPrefix open-checkpoint! [^String manifest-path ^CheckpointSource source]
  (let [^CheckpointManifest manifest (read-manifest! manifest-path)]
  (validate-source! manifest source)
  (let [directory (.getParentFile (File. manifest-path))
   ^String component (checkpointmanifest-component manifest)
   ^String page-file (str directory "/" component)]
  (if (not (.isFile (File. page-file))) (fail! :packed-component-missing "packed Store manifest component is missing") nil)
  (if (not (= (checkpointmanifest-page-sha256 manifest) (sha256-file page-file))) (fail! :invalid-packed-checkpoint "packed Store page checksum does not match its manifest") nil)
  (let [table (read-page-table! page-file manifest)]
  (validate-section-lengths! table manifest)
  (let [buffers (into {} (map (fn [id] (let [entry (get table id)]
  [id (map-section page-file (nth entry 0) (nth entry 1))])) (range 1 (+ section-count 1))))]
  (->PackedPrefix manifest buffers))))))

(defn close-checkpoint! [^PackedPrefix prefix]
  nil)

(defn ^String space-id [^PackedPrefix prefix]
  (checkpointmanifest-space-id (packedprefix-manifest prefix)))

(defn revision [^PackedPrefix prefix]
  (checkpointmanifest-revision (packedprefix-manifest prefix)))

(defn next-sequence [^PackedPrefix prefix]
  (checkpointmanifest-next-sequence (packedprefix-manifest prefix)))

(defn atom-count [^PackedPrefix prefix]
  (checkpointmanifest-atom-count (packedprefix-manifest prefix)))

(defn triple-count [^PackedPrefix prefix]
  (checkpointmanifest-triple-count (packedprefix-manifest prefix)))

(defn transaction-count [^PackedPrefix prefix]
  (checkpointmanifest-transaction-count (packedprefix-manifest prefix)))

(defn operation-count [^PackedPrefix prefix]
  (checkpointmanifest-operation-count (packedprefix-manifest prefix)))

(defn mapped-bytes [^PackedPrefix prefix]
  (checkpointmanifest-mapped-bytes (packedprefix-manifest prefix)))

(defn ^String manifest-path [^PackedPrefix prefix]
  (checkpointmanifest-path (packedprefix-manifest prefix)))

(defn atom-row-at! [^PackedPrefix prefix position]
  (if (or (< position 0) (>= position (atom-count prefix))) (fail! :invalid-packed-position "packed Store atom position is outside the prefix") (let [start (section-long prefix atom-offsets-section position)
   end (section-long prefix atom-offsets-section (+ position 1))
   ^ByteBuffer payload (buffer prefix atom-payload-section)]
  (if (not (and (>= start 0) (and (>= end start) (<= end (.limit payload))))) (fail! :invalid-packed-checkpoint "packed Store atom offsets are invalid") (let [^ByteBuffer view (.duplicate payload)]
  (.position view (int start))
  (.limit view (int end))
  (let [^ByteBuffer slice (.slice view)
   decoded (rpc/decode-term-codec-v1! slice max-term-bytes max-term-nodes max-term-depth)
   value (t/termcodecdecoded-value decoded)]
  (if (or (not (= 0 (.remaining slice))) (t/triple? value)) (fail! :invalid-packed-checkpoint "packed Store atom payload is invalid") (atom-row! value))))))))

(defn triple-row-at! [^PackedPrefix prefix position]
  (if (or (< position 0) (>= position (triple-count prefix))) (fail! :invalid-packed-position "packed Store triple position is outside the prefix") (t/->TripleRow (section-int prefix triple-t1-section position) (section-int prefix triple-t2-section position) (section-int prefix triple-t3-section position))))

(defn transaction-row-at! [^PackedPrefix prefix position]
  (if (or (< position 0) (>= position (transaction-count prefix))) (fail! :invalid-packed-position "packed Store transaction position is outside the prefix") (t/->TransactionRow (section-long prefix transaction-sequence-section position) (section-long prefix transaction-first-operation-section position) (section-int prefix transaction-operation-count-section position))))

(defn operation-row-at! [^PackedPrefix prefix position]
  (if (or (< position 0) (>= position (operation-count prefix))) (fail! :invalid-packed-position "packed Store operation position is outside the prefix") (t/->OperationRow (section-long prefix operation-sequence-section position) (section-int prefix operation-ordinal-section position) (code-action! (section-byte prefix operation-action-section position)) (section-int prefix operation-triple-section position))))

(defn withdrawal-target-at! [^PackedPrefix prefix position]
  (if (or (< position 0) (>= position (operation-count prefix))) (fail! :invalid-packed-position "packed Store withdrawal position is outside the prefix") (section-long prefix withdrawal-target-section position)))

(defn- compare-three [a1 a2 a3 b1 b2 b3]
  (cond
  (< a1 b1) -1
  (> a1 b1) 1
  (< a2 b2) -1
  (> a2 b2) 1
  (< a3 b3) -1
  (> a3 b3) 1
  :else 0))

(defn find-triple-position [^PackedPrefix prefix t1 t2 t3]
  (let [^ByteBuffer index (buffer prefix spo-section)
   total (triple-count prefix)]
  (loop [low 0
   high (- total 1)]
  (if (> low high) -1 (let [middle (quot (+ low high) 2)
   base (* middle 16)
   comparison (compare-three (.getInt index base) (.getInt index (+ base 4)) (.getInt index (+ base 8)) t1 t2 t3)]
  (cond
  (= comparison 0) (.getInt index (+ base 12))
  (< comparison 0) (recur (+ middle 1) high)
  :else (recur low (- middle 1))))))))

(defn- compare-index-prefix [^ByteBuffer index position prefix]
  (let [base (* position 16)]
  (loop [offset 0]
  (if (>= offset (count prefix)) 0 (let [actual (.getInt index (+ base (* offset 4)))
   wanted (nth prefix offset)]
  (cond
  (< actual wanted) -1
  (> actual wanted) 1
  :else (recur (+ offset 1))))))))

(defn- index-prefix-positions [^PackedPrefix prefix-store index-id wanted]
  (let [^ByteBuffer index (buffer prefix-store index-id)
   total (triple-count prefix-store)
   first-position (loop [low 0
   high total]
  (if (>= low high) low (let [middle (quot (+ low high) 2)]
  (if (< (compare-index-prefix index middle wanted) 0) (recur (+ middle 1) high) (recur low middle)))))]
  (loop [position first-position
   matches []]
  (if (or (>= position total) (not (= 0 (compare-index-prefix index position wanted)))) matches (recur (+ position 1) (conj matches (.getInt index (+ (* position 16) 12))))))))

(defn matching-triple-positions [^PackedPrefix prefix t1 t2 t3]
  (cond
  (and (some? t1) (and (some? t2) (some? t3))) (index-prefix-positions prefix spo-section [t1 t2 t3])
  (and (some? t1) (some? t2)) (index-prefix-positions prefix spo-section [t1 t2])
  (and (some? t2) (some? t3)) (index-prefix-positions prefix pos-section [t2 t3])
  (and (some? t3) (some? t1)) (index-prefix-positions prefix osp-section [t3 t1])
  (some? t1) (index-prefix-positions prefix spo-section [t1])
  (some? t2) (index-prefix-positions prefix pos-section [t2])
  (some? t3) (index-prefix-positions prefix osp-section [t3])
  :else []))

(defn- ^Boolean bytes-equal-range? [^ByteBuffer payload start end bytes]
  (if (not (= (- end start) (alength bytes))) false (loop [position 0]
  (if (>= position (alength bytes)) true (if (= (bit-and 255 (int (.get payload (+ start position)))) (bit-and 255 (int (aget bytes position)))) (recur (+ position 1)) false)))))

(defn find-atom-position [^PackedPrefix prefix value]
  (let [bytes (encode-term value)
   wanted (hash64 bytes)
   ^ByteBuffer index (buffer prefix atom-lookup-section)
   total (atom-count prefix)
   first-hit (loop [low 0
   high (- total 1)
   found -1]
  (if (> low high) found (let [middle (quot (+ low high) 2)
   current (.getLong index (* middle 12))]
  (cond
  (< current wanted) (recur (+ middle 1) high found)
  (> current wanted) (recur low (- middle 1) found)
  :else (recur low (- middle 1) middle)))))
   ^ByteBuffer payload (buffer prefix atom-payload-section)]
  (if (< first-hit 0) -1 (loop [lookup-position first-hit]
  (if (>= lookup-position total) -1 (let [base (* lookup-position 12)
   current (.getLong index base)]
  (if (not (= current wanted)) -1 (let [position (.getInt index (+ base 8))
   start (section-long prefix atom-offsets-section position)
   end (section-long prefix atom-offsets-section (+ position 1))]
  (if (bytes-equal-range? payload start end bytes) position (recur (+ lookup-position 1)))))))))))

(defn- active-entry [^PackedPrefix prefix handle]
  (let [total (checkpointmanifest-active-count (packedprefix-manifest prefix))]
  (loop [low 0
   high (- total 1)]
  (if (> low high) -1 (let [middle (quot (+ low high) 2)
   current (section-int prefix active-handle-section middle)]
  (cond
  (= current handle) middle
  (< current handle) (recur (+ middle 1) high)
  :else (recur low (- middle 1))))))))

(defn active-handle-count [^PackedPrefix prefix]
  (checkpointmanifest-active-count (packedprefix-manifest prefix)))

(defn active-handle-at! [^PackedPrefix prefix position]
  (if (and (>= position 0) (< position (active-handle-count prefix))) (section-int prefix active-handle-section position) (fail! :invalid-packed-position "packed Store active handle position is out of range")))

(defn active-position-count [^PackedPrefix prefix handle]
  (let [entry (active-entry prefix handle)]
  (if (< entry 0) 0 (section-int prefix active-count-section entry))))

(defn active-position-at! [^PackedPrefix prefix handle position]
  (let [entry (active-entry prefix handle)
   count-value (if (< entry 0) 0 (section-int prefix active-count-section entry))]
  (if (and (>= position 0) (< position count-value)) (let [offset (section-long prefix active-offset-section entry)]
  (section-long prefix active-run-section (+ offset position))) (fail! :invalid-packed-position "packed Store active operation position is out of range"))))

(defn ^Boolean active-prefix-operation? [^PackedPrefix prefix handle count-limit operation-position]
  (let [entry (active-entry prefix handle)]
  (if (< entry 0) false (let [offset (section-long prefix active-offset-section entry)
   stored-count (section-int prefix active-count-section entry)
   count-value (min stored-count count-limit)]
  (loop [low 0
   high (- count-value 1)]
  (if (> low high) false (let [middle (quot (+ low high) 2)
   current (section-long prefix active-run-section (+ offset middle))]
  (cond
  (= current operation-position) true
  (< current operation-position) (recur (+ middle 1) high)
  :else (recur low (- middle 1))))))))))

(defn active-positions [^PackedPrefix prefix handle]
  (let [entry (active-entry prefix handle)]
  (if (< entry 0) [] (let [offset (section-long prefix active-offset-section entry)
   count-value (section-int prefix active-count-section entry)]
  (loop [position 0
   positions []]
  (if (>= position count-value) positions (recur (+ position 1) (conj positions (section-long prefix active-run-section (+ offset position))))))))))

(defn ^Boolean operation-live? [^PackedPrefix prefix handle operation-position]
  (let [entry (active-entry prefix handle)]
  (if (< entry 0) false (let [offset (section-long prefix active-offset-section entry)
   count-value (section-int prefix active-count-section entry)]
  (loop [low 0
   high (- count-value 1)]
  (if (> low high) false (let [middle (quot (+ low high) 2)
   current (section-long prefix active-run-section (+ offset middle))]
  (cond
  (= current operation-position) true
  (< current operation-position) (recur (+ middle 1) high)
  :else (recur low (- middle 1))))))))))
