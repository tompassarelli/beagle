;; writer_authority.clj — cross-generation database writer authority.
;;
;; A systemd unit name or a generation-local launcher lock cannot fence two
;; overlapping deployments: blue and green necessarily have different process
;; identities and runtime directories.  This lock is instead named by the
;; canonical log itself and held for the active database's entire lifetime.
;; Standbys do not acquire it and therefore cannot mutate canonical state.
(ns writer-authority
  (:require [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.nio.channels FileChannel]
           [java.nio ByteBuffer]
           [java.nio.charset CodingErrorAction StandardCharsets]
           [java.nio.file Files StandardOpenOption]
           [java.security MessageDigest]))

(def authority-format "store-writer-authority/v1")

;; FactEnvelopeV1 is an immutable identity contract. Existing IDs keep this
;; byte meaning forever; a semantic correction starts a new envelope version.
(def fact-envelope-version-v1 1)
(def fact-envelope-domain-v1 "beagle.store/FactEnvelope")
(def fact-kind-registry-v1
  {"GateCandidateV1" 1
   "GatePhaseClaimV1" 2
   "GatePhaseObservationV1" 3
   "GateCandidateVerdictV1" 4
   "FactMissEventV1" 5
   "GateMaintenanceReceiptV1" 6
   "DevCompileUnitResultV1" 7})

(def ^:private fact-kind-names-v1
  (into {} (map (fn [[name id]] [id name]) fact-kind-registry-v1)))
(def ^:private fact-envelope-domain-bytes-v1
  (mapv #(bit-and (int %) 255)
        (.getBytes fact-envelope-domain-v1 StandardCharsets/UTF_8)))
(def ^:private fact-envelope-max-bytes 1048576)
(def ^:private fact-value-max-nodes 65536)
(def ^:private fact-value-max-depth 256)

(defn- fact-fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- byte-value? [value]
  (and (integer? value) (<= 0 value 255)))

(defn- bytes-vector! [value]
  (let [bytes (cond
                (instance? (Class/forName "[B") value)
                (mapv #(bit-and (int %) 255) value)

                (sequential? value) (vec value)
                :else nil)]
    (when-not (and bytes
                   (<= (count bytes) fact-envelope-max-bytes)
                   (every? byte-value? bytes))
      (fact-fail! :fact-envelope/invalid-bytes
                  "fact envelope must be at most 1 MiB of u8 values"
                  {:value-type (some-> value class str)}))
    bytes))

(defn- signed-byte-array [bytes]
  (byte-array (map #(byte (if (> % 127) (- % 256) %)) bytes)))

(defn- sha256-id [bytes]
  (str "sha256:"
       (apply str
              (map #(format "%02x" (bit-and (int %) 255))
                   (.digest (MessageDigest/getInstance "SHA-256")
                            (signed-byte-array bytes))))))

(defn- unicode-scalar-string? [value]
  (and
   (string? value)
   (loop [index 0]
     (if (>= index (count value))
       true
       (let [unit (int (.charAt ^String value index))]
         (cond
           (<= 55296 unit 56319)
           (and (< (inc index) (count value))
                (let [next-unit (int (.charAt ^String value (inc index)))]
                  (and (<= 56320 next-unit 57343)
                       (recur (+ index 2)))))

           (<= 56320 unit 57343) false
           :else (recur (inc index))))))))

(defn- u16-bytes [value]
  [(bit-and 255 (unsigned-bit-shift-right (long value) 8))
   (bit-and 255 (long value))])

(defn- u32-bytes [value]
  (mapv #(bit-and 255 (unsigned-bit-shift-right (long value) %))
        [24 16 8 0]))

(defn- i64-bytes [value]
  (mapv #(bit-and 255 (unsigned-bit-shift-right (long value) %))
        [56 48 40 32 24 16 8 0]))

(defn- lexicographic-bytes [left right]
  (loop [index 0]
    (cond
      (= index (min (count left) (count right)))
      (compare (count left) (count right))

      (= (nth left index) (nth right index)) (recur (inc index))
      :else (compare (nth left index) (nth right index)))))

(declare canonical-value-bytes!)

(defn- counted-bytes [tag parts]
  (when (> (count parts) fact-value-max-nodes)
    (fact-fail! :fact-envelope/value-too-large
                "fact payload collection exceeds the V1 element bound"
                {:count (count parts)}))
  (into [tag] (concat (u32-bytes (count parts)) (mapcat identity parts))))

(defn- canonical-value-bytes!
  ([value] (canonical-value-bytes! value 0))
  ([value depth]
   (when (> depth fact-value-max-depth)
     (fact-fail! :fact-envelope/value-too-deep
                 "fact payload exceeds the V1 nesting bound"
                 {:depth depth}))
   (cond
     (nil? value) [0]
     (false? value) [1]
     (true? value) [2]

     (integer? value)
     (if (<= Long/MIN_VALUE value Long/MAX_VALUE)
       (into [3] (i64-bytes value))
       (fact-fail! :fact-envelope/invalid-value
                   "fact payload integer is outside signed 64-bit range"
                   {:value value}))

     (or (instance? Double value) (instance? Float value))
     (into [4] (i64-bytes (Double/doubleToLongBits (double value))))

     (string? value)
     (if (unicode-scalar-string? value)
       (let [bytes (mapv #(bit-and (int %) 255)
                         (.getBytes ^String value StandardCharsets/UTF_8))]
         (into [5] (concat (u32-bytes (count bytes)) bytes)))
       (fact-fail! :fact-envelope/invalid-value
                   "fact payload string contains an unpaired surrogate"
                   {}))

     (keyword? value)
     (let [spelling (subs (str value) 1)]
       (into [6] (rest (canonical-value-bytes! spelling (inc depth)))))

     (vector? value)
     (counted-bytes 7 (mapv #(canonical-value-bytes! % (inc depth)) value))

     (map? value)
     (let [entries
           (sort
            #(lexicographic-bytes (first %1) (first %2))
            (mapv (fn [[key item]]
                    [(canonical-value-bytes! key (inc depth))
                     (canonical-value-bytes! item (inc depth))])
                  value))
           duplicate
           (some (fn [[left right]]
                   (zero? (lexicographic-bytes (first left) (first right))))
                 (partition 2 1 entries))]
       (when duplicate
         (fact-fail! :fact-envelope/duplicate
                     "fact payload map has duplicate canonical keys" {}))
       (counted-bytes 8 (mapv #(into (first %) (second %)) entries)))

     (set? value)
     (let [items (sort lexicographic-bytes
                       (mapv #(canonical-value-bytes! % (inc depth)) value))
           duplicate (some #(zero? (lexicographic-bytes (first %) (second %)))
                           (partition 2 1 items))]
       (when duplicate
         (fact-fail! :fact-envelope/duplicate
                     "fact payload set has duplicate canonical values" {}))
       (counted-bytes 9 items))

     :else
     (fact-fail! :fact-envelope/invalid-value
                 "fact payload contains a value outside the V1 domain"
                 {:value-type (some-> value class str)}))))

(defn- require-kind-id! [kind]
  (or (get fact-kind-registry-v1 kind)
      (fact-fail! :fact-envelope/unknown-kind
                  "fact envelope kind is not registered for V1"
                  {:kind kind :version fact-envelope-version-v1})))

(defn fact-envelope-v1-bytes
  "Encode one registered fact kind and its ordered field vector canonically."
  [kind payload]
  (when-not (vector? payload)
    (fact-fail! :fact-envelope/invalid-payload
                "FactEnvelopeV1 payload must be an ordered vector"
                {:kind kind}))
  (let [kind-id (require-kind-id! kind)
        payload-bytes (canonical-value-bytes! payload)
        bytes (vec (concat fact-envelope-domain-bytes-v1
                           (u16-bytes fact-envelope-version-v1)
                           (u16-bytes kind-id)
                           (u32-bytes (count payload-bytes))
                           payload-bytes))]
    (when (> (count bytes) fact-envelope-max-bytes)
      (fact-fail! :fact-envelope/value-too-large
                  "FactEnvelopeV1 exceeds the 1 MiB byte bound"
                  {:bytes (count bytes)}))
    bytes))

(defn fact-id-v1 [kind payload]
  (sha256-id (fact-envelope-v1-bytes kind payload)))

(defn fact-envelope-v1 [kind payload]
  (let [bytes (fact-envelope-v1-bytes kind payload)]
    {:version fact-envelope-version-v1
     :kind kind
     :kind-id (get fact-kind-registry-v1 kind)
     :payload payload
     :bytes bytes
     :id (sha256-id bytes)}))

(defn- read-unsigned! [bytes position width limit label]
  (when (> (+ position width) limit)
    (fact-fail! :fact-envelope/corrupt
                (str "fact envelope ends inside " label)
                {:offset position :needed width :limit limit}))
  [(loop [offset 0 value 0]
     (if (= offset width)
       value
       (recur (inc offset)
              (bit-or (bit-shift-left value 8)
                      (nth bytes (+ position offset))))))
   (+ position width)])

(defn- read-i64! [bytes position limit]
  (let [[high next] (read-unsigned! bytes position 4 limit "signed integer")
        [low end] (read-unsigned! bytes next 4 limit "signed integer")]
    [(bit-or (bit-shift-left (long high) 32) (long low)) end]))

(defn- strict-utf8! [bytes start length limit]
  (when (> (+ start length) limit)
    (fact-fail! :fact-envelope/corrupt
                "fact envelope ends inside UTF-8 text"
                {:offset start :length length :limit limit}))
  (try
    (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
                    (.onMalformedInput CodingErrorAction/REPORT)
                    (.onUnmappableCharacter CodingErrorAction/REPORT))]
      [(str (.decode decoder
                     (ByteBuffer/wrap
                      (signed-byte-array (subvec bytes start (+ start length))))))
       (+ start length)])
    (catch java.nio.charset.CharacterCodingException _
      (fact-fail! :fact-envelope/corrupt
                  "fact envelope contains invalid UTF-8"
                  {:offset start :length length}))))

(declare decode-value-at!)

(defn- decode-counted!
  [bytes position limit depth collection-kind]
  (let [[amount start] (read-unsigned! bytes position 4 limit "collection count")]
    (when (> amount fact-value-max-nodes)
      (fact-fail! :fact-envelope/value-too-large
                  "fact payload collection exceeds the V1 element bound"
                  {:count amount}))
    (loop [index 0 cursor start values [] encodings []]
      (if (= index amount)
        (case collection-kind
          :vector {:value values :next cursor}
          :set (do
                 (when (not= encodings (sort lexicographic-bytes encodings))
                   (fact-fail! :fact-envelope/reordered
                               "fact payload set values are not in canonical order"
                               {:index index}))
                 (when (some #(zero? (lexicographic-bytes (first %) (second %)))
                             (partition 2 1 encodings))
                   (fact-fail! :fact-envelope/duplicate
                               "fact payload set repeats a canonical value" {}))
                 {:value (set values) :next cursor}))
        (let [decoded (decode-value-at! bytes cursor limit (inc depth))
              next (:next decoded)]
          (recur (inc index) next (conj values (:value decoded))
                 (conj encodings (subvec bytes cursor next))))))))

(defn- decode-map! [bytes position limit depth]
  (let [[amount start] (read-unsigned! bytes position 4 limit "map count")]
    (when (> amount fact-value-max-nodes)
      (fact-fail! :fact-envelope/value-too-large
                  "fact payload map exceeds the V1 element bound"
                  {:count amount}))
    (loop [index 0 cursor start result {} previous nil]
      (if (= index amount)
        {:value result :next cursor}
        (let [key-result (decode-value-at! bytes cursor limit (inc depth))
              key-end (:next key-result)
              key-bytes (subvec bytes cursor key-end)
              ordering (when previous (lexicographic-bytes previous key-bytes))]
          (when (and ordering (zero? ordering))
            (fact-fail! :fact-envelope/duplicate
                        "fact payload map repeats a canonical key"
                        {:index index}))
          (when (and ordering (pos? ordering))
            (fact-fail! :fact-envelope/reordered
                        "fact payload map keys are not in canonical order"
                        {:index index}))
          (let [value-result
                (decode-value-at! bytes key-end limit (inc depth))]
            (recur (inc index) (:next value-result)
                   (assoc result (:value key-result) (:value value-result))
                   key-bytes)))))))

(defn- decode-value-at! [bytes position limit depth]
  (when (> depth fact-value-max-depth)
    (fact-fail! :fact-envelope/value-too-deep
                "fact payload exceeds the V1 nesting bound"
                {:depth depth}))
  (let [[tag cursor] (read-unsigned! bytes position 1 limit "value tag")]
    (case tag
      0 {:value nil :next cursor}
      1 {:value false :next cursor}
      2 {:value true :next cursor}
      3 (let [[value next] (read-i64! bytes cursor limit)]
          {:value value :next next})
      4 (let [[bits next] (read-i64! bytes cursor limit)]
          (when (and (Double/isNaN (Double/longBitsToDouble bits))
                     (not= bits (Double/doubleToLongBits Double/NaN)))
            (fact-fail! :fact-envelope/noncanonical
                        "fact payload contains a noncanonical NaN" {}))
          {:value (Double/longBitsToDouble bits) :next next})
      5 (let [[length start] (read-unsigned! bytes cursor 4 limit "string length")
              [value next] (strict-utf8! bytes start length limit)]
          {:value value :next next})
      6 (let [[length start] (read-unsigned! bytes cursor 4 limit "keyword length")
              [spelling next] (strict-utf8! bytes start length limit)]
          (when (empty? spelling)
            (fact-fail! :fact-envelope/corrupt
                        "fact payload keyword spelling is empty" {}))
          (let [value (keyword spelling)]
            (when (not= spelling (subs (str value) 1))
              (fact-fail! :fact-envelope/noncanonical
                          "fact payload keyword spelling is not canonical"
                          {:spelling spelling}))
            {:value value :next next}))
      7 (decode-counted! bytes cursor limit depth :vector)
      8 (decode-map! bytes cursor limit depth)
      9 (decode-counted! bytes cursor limit depth :set)
      (fact-fail! :fact-envelope/corrupt
                  "fact payload contains an unknown value tag"
                  {:tag tag :offset position}))))

(defn decode-fact-envelope!
  "Decode one exact canonical envelope. Unknown versions never fall through."
  [value]
  (let [bytes (bytes-vector! value)
        domain-size (count fact-envelope-domain-bytes-v1)
        minimum (+ domain-size 8)]
    (when (< (count bytes) minimum)
      (fact-fail! :fact-envelope/corrupt
                  "fact envelope is shorter than the V1 header"
                  {:bytes (count bytes)}))
    (when-not (= fact-envelope-domain-bytes-v1 (subvec bytes 0 domain-size))
      (fact-fail! :fact-envelope/corrupt
                  "fact envelope domain separator is corrupt" {}))
    (let [[version after-version]
          (read-unsigned! bytes domain-size 2 (count bytes) "version")]
      (when-not (= fact-envelope-version-v1 version)
        (fact-fail! :fact-envelope/unknown-version
                    "fact envelope version is not supported"
                    {:version version}))
      (let [[kind-id after-kind]
            (read-unsigned! bytes after-version 2 (count bytes) "kind")
            kind (get fact-kind-names-v1 kind-id)]
        (when-not kind
          (fact-fail! :fact-envelope/unknown-kind
                      "fact envelope kind ID is not registered for V1"
                      {:kind-id kind-id :version version}))
        (let [[payload-size payload-start]
              (read-unsigned! bytes after-kind 4 (count bytes) "payload length")
              payload-end (+ payload-start payload-size)]
          (when (> payload-end (count bytes))
            (fact-fail! :fact-envelope/corrupt
                        "fact envelope payload is truncated"
                        {:declared payload-size
                         :available (- (count bytes) payload-start)}))
          (when (< payload-end (count bytes))
            (fact-fail! :fact-envelope/trailing-data
                        "fact envelope has trailing data"
                        {:trailing (- (count bytes) payload-end)}))
          (let [decoded (decode-value-at! bytes payload-start payload-end 0)
                payload (:value decoded)]
            (when-not (= payload-end (:next decoded))
              (fact-fail! :fact-envelope/trailing-data
                          "fact envelope payload has trailing data"
                          {:trailing (- payload-end (:next decoded))}))
            (when-not (vector? payload)
              (fact-fail! :fact-envelope/invalid-payload
                          "FactEnvelopeV1 payload must be an ordered vector"
                          {:kind kind}))
            (when-not (= bytes (fact-envelope-v1-bytes kind payload))
              (fact-fail! :fact-envelope/noncanonical
                          "fact envelope bytes are not canonical V1"
                          {:kind kind}))
            {:version version
             :kind kind
             :kind-id kind-id
             :payload payload
             :bytes bytes
             :id (sha256-id bytes)}))))))

(defn validate-fact-envelope! [bytes expected-id]
  (let [decoded (decode-fact-envelope! bytes)]
    (when-not (= expected-id (:id decoded))
      (fact-fail! :fact-envelope/id-mismatch
                  "fact ID does not match the canonical envelope"
                  {:expected expected-id :actual (:id decoded)}))
    decoded))

(defn server-role-from
  "Parse a server role. nil/empty preserves the existing active default."
  [raw]
  (case (str/lower-case (str/trim (or raw "")))
    ("" "active") :active
    "standby" :standby
    (throw
     (ex-info
      "BEAGLE_STORE_SERVER_ROLE must be active or standby"
      {:code :invalid-server-role :value raw}))))

(defn server-role-from-env []
  (server-role-from (System/getenv "BEAGLE_STORE_SERVER_ROLE")))

(defn authority-path
  "Stable, cross-generation lock path for one canonical log."
  [log]
  (str (.getCanonicalPath (io/file (str log))) ".writer-authority.lock"))

(defn- open-channel [path]
  (let [p (.toPath (io/file path))]
    (when (Files/isSymbolicLink p)
      (throw
       (ex-info
        "writer authority path must not be a symlink"
        {:code :unsafe-writer-authority-path :path path})))
    (FileChannel/open
     p
     (into-array
      java.nio.file.OpenOption
      [StandardOpenOption/CREATE StandardOpenOption/WRITE]))))

(defn try-acquire!
  "Try to acquire the lifetime writer lock for LOG. Returns a handle or nil.
   Closing/releasing the handle is the only way to relinquish authority."
  [log]
  (let [path (authority-path log)
        parent (.getParentFile (io/file path))]
    (when parent (.mkdirs parent))
    (let [^FileChannel channel (open-channel path)]
      (try
        (if-let [lock (.tryLock channel)]
          {:format authority-format
           :log (.getCanonicalPath (io/file (str log)))
           :path path
           :channel channel
           :lock lock}
          (do (.close channel) nil))
        (catch Throwable t
          (.close channel)
          ;; Babashka deliberately does not expose the JVM exception class as a
          ;; resolvable symbol, but both runtimes preserve its exact class name.
          (if (= "OverlappingFileLockException"
                 (.getSimpleName (class t)))
            nil
            (throw t)))))))

(defn acquire!
  "Acquire writer authority or fail closed without waiting."
  [log]
  (or (try-acquire! log)
      (throw
       (ex-info
        (str "another database generation holds writer authority for "
             (.getCanonicalPath (io/file (str log))))
        {:code :writer-authority-held
         :log (.getCanonicalPath (io/file (str log)))
         :path (authority-path log)}))))

(defn held? [handle]
  (boolean
   (and handle
        (:lock handle)
        (:channel handle)
        (.isOpen ^FileChannel (:channel handle)))))

(defn release!
  "Release HANDLE idempotently. Closing the channel is the kernel backstop."
  [handle]
  (when handle
    ;; Closing the channel is the portable release primitive (and is the only
    ;; FileLock lifecycle operation Babashka intentionally exposes).
    (when (and (:channel handle)
               (.isOpen ^FileChannel (:channel handle)))
      (.close ^FileChannel (:channel handle))))
  nil)

(defn status [role handle log]
  {:format authority-format
   :role role
   :write-authorized (and (= role :active) (held? handle))
   :log (.getCanonicalPath (io/file (str log)))
   :lock (authority-path log)})
