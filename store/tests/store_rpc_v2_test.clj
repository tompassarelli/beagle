(require '[store.rpc :as wire]
         '[store.types :as t])

(def failures (atom 0))

(defn check! [label ok]
  (println (str (if ok "[PASS] " "[FAIL] ") label))
  (when-not ok (swap! failures inc)))

(defn thrown-code [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo e
      (:store/code (ex-data e)))))

(defn hex-bytes [text]
  (byte-array
   (map (fn [pair]
          (unchecked-byte (Integer/parseInt (apply str pair) 16)))
        (partition 2 text))))

(defn bytes-hex [bytes]
  (apply str (map #(format "%02x" (bit-and 255 (int %))) bytes)))

(defn concat-bytes [parts]
  (let [out (java.io.ByteArrayOutputStream.)]
    (doseq [part parts] (.write out ^bytes part))
    (.toByteArray out)))

(defn altered-byte [bytes offset value]
  (let [copy (java.util.Arrays/copyOf ^bytes bytes (alength ^bytes bytes))]
    (aset-byte copy offset (unchecked-byte value))
    copy))

(defn appended-byte [bytes value]
  (let [copy (java.util.Arrays/copyOf ^bytes bytes (inc (alength ^bytes bytes)))]
    (aset-byte copy (dec (alength copy)) (unchecked-byte value))
    copy))

(defn put-u32-le! [bytes offset value]
  (dotimes [index 4]
    (aset-byte bytes (+ offset index)
               (unchecked-byte
                (bit-and 255 (unsigned-bit-shift-right value (* index 8))))))
  bytes)

(defn encode-term [value]
  (let [out (java.io.ByteArrayOutputStream.)]
    (wire/write-term-codec-v1!
     out value wire/rpc-v2-max-string-bytes
     wire/rpc-v2-max-term-nodes wire/rpc-v2-max-term-depth)
    (.toByteArray out)))

(defn decode-term [bytes]
  (let [buffer (doto (java.nio.ByteBuffer/wrap ^bytes bytes)
                 (.order java.nio.ByteOrder/LITTLE_ENDIAN))
        decoded
        (wire/decode-term-codec-v1!
         buffer wire/rpc-v2-max-string-bytes
         wire/rpc-v2-max-term-nodes wire/rpc-v2-max-term-depth)]
    (check! "Term golden is consumed exactly" (zero? (.remaining buffer)))
    (t/termcodecdecoded-value decoded)))

(def four-packet-golden
  (str
   "4652414d5250430002000000010077000000080706050403020101090000006d73612d737061636506050000007175657279012900000000000000011900000001070106000000637572736f720605000000616674657202070000000000000001dc050000070105000000416c6963650702d6ffffffffffffff03000000000000f83f08c059cc690000000015cd5b0705"
   "4652414d5250430002000000020096000000080706050403020101090000006d73612d7370616365060500000071756572792a00000000000000010200000001070106000000637572736f720605000000616674657202070000000000000000010608000000636f6e666c69637401010d00000076657273696f6e206d6f766564010401070105000000416c6963650702d6ffffffffffffff03000000000000f83f08c059cc690000000015cd5b0705"
   "4652414d52504300020000000300000000000900000000000000"
   "4652414d52504300020000000400250000000a0000000000000001090000006d73612d737061636506070000006368616e6765642b00000000000000000000"))

(def cursor (t/triple "cursor" :after 7))
(def payload
  (t/triple "Alice"
            (t/triple -42 1.5 (t/instant 1775000000 123456789))
            true))
(def request-id 0x0102030405060708)
(def request-packet
  (wire/rpc-request-packet
   request-id
   (wire/rpc-request!
    "msa-space" :query 41 (wire/rpc-page-request! 25 cursor) 1500 payload)))
(def response-packet
  (wire/rpc-response-packet
   request-id
   (wire/rpc-response!
    "msa-space" :query 42
    (wire/rpc-page-response! 2 cursor false)
    (wire/rpc-error! :conflict true "version moved" false)
    payload)))
(def cancel-packet (wire/rpc-cancel-packet 9))
(def event-packet
  (wire/rpc-event-packet
   10 (wire/rpc-response! "msa-space" :changed 43 nil nil nil)))
(def packets [request-packet response-packet cancel-packet event-packet])
(def encoded-packets (mapv wire/encode-rpc-packet-v2! packets))
(def encoded-golden (concat-bytes encoded-packets))

(let [actual (bytes-hex encoded-golden)
      mismatch
      (first
       (keep-indexed
        (fn [index pair] (when (not= (first pair) (second pair)) index))
        (map vector four-packet-golden actual)))]
  (check! (if mismatch
            (str "encoder matches the frozen four-packet golden; first mismatch " mismatch)
            "encoder matches the frozen four-packet golden byte-for-byte")
          (= four-packet-golden actual)))

(check! "all four packet kinds decode to their closed packets"
        (= packets (mapv wire/decode-rpc-packet-v2! encoded-packets)))
(check! "cancel has a zero-byte body"
        (= 26 (alength ^bytes (nth encoded-packets 2))))
(check! "request id preserves all signed-long bits"
        (= -1
           (t/rpcpacketv2-request-id
            (wire/decode-rpc-packet-v2!
             (wire/encode-rpc-packet-v2! (wire/rpc-cancel-packet -1))))))
(check! "false remains a present optional error-detail Term"
        (false?
         (t/rpc-error-detail-value
          (t/rpcresponse-error
           (t/rpcpacketv2-response
            (wire/decode-rpc-packet-v2! (nth encoded-packets 1)))))))

(doseq [[label value expected]
        [["String" "é" "0102000000c3a9"]
         ["Int" -42 "02d6ffffffffffffff"]
         ["Float" 1.5 "03000000000000f83f"]
         ["false" false "04"]
         ["true" true "05"]
         ["Keyword" :after "06050000006166746572"]
         ["Instant" (t/instant 1775000000 123456789)
          "08c059cc690000000015cd5b07"]
         ["recursive Triple" cursor
          "070106000000637572736f7206050000006166746572020700000000000000"]]]
  (let [encoded (encode-term value)]
    (check! (str label " has the canonical TermCodecV1 bytes")
            (= expected (bytes-hex encoded)))
    (check! (str label " round-trips through TermCodecV1")
            (= value (decode-term encoded)))))

(defn nested-term [levels]
  (loop [remaining levels value "leaf"]
    (if (zero? remaining)
      value
      (recur (dec remaining) (t/triple value 0 0)))))

(let [at-limit (nested-term 256)
      bytes (encode-term at-limit)]
  (check! "recursive Term depth 256 encodes and decodes"
          (= at-limit (decode-term bytes))))
(check! "recursive Term depth 257 is rejected"
        (= :term-depth-exceeded
           (thrown-code #(encode-term (nested-term 257)))))
(check! "batch action bound is derived from the mutation response envelope"
        (and (= 9 wire/rpc-v2-mutation-response-wrapper-depth)
             (= 247 wire/rpc-v2-max-batch-actions)
             (= wire/rpc-v2-max-term-depth
                (+ wire/rpc-v2-max-batch-actions
                   wire/rpc-v2-mutation-response-wrapper-depth))))

(defn shared-ternary-term [levels]
  (loop [remaining levels value "leaf"]
    (if (zero? remaining)
      value
      (recur (dec remaining) (t/triple value value value)))))

(check! "per-Term 65,536-node cap is enforced before body allocation"
        (= :term-codec-node-limit
           (thrown-code
            #(wire/encode-rpc-packet-v2!
              (wire/rpc-request-packet
               1 (wire/rpc-request! "s" :op nil nil nil
                                    (shared-ternary-term 10)))))))
(check! "SpaceId 4,096-byte cap is enforced during encode preflight"
        (= :term-codec-string-limit
           (thrown-code
            #(wire/encode-rpc-packet-v2!
              (wire/rpc-request-packet
               1 (wire/rpc-request! (apply str (repeat 4097 "s"))
                                    :op nil nil nil true))))))
(check! "one-MiB body cap is enforced before body allocation"
        (= :rpc-packet-too-large
           (thrown-code
            #(wire/encode-rpc-packet-v2!
              (wire/rpc-request-packet
               1 (wire/rpc-request! "s" :op nil nil nil
                                    (.repeat "x" wire/rpc-v2-max-string-bytes)))))))
(check! "open-map request payloads are rejected at the closed Term boundary"
        (= :rpc-invalid-term
           (thrown-code #(wire/rpc-request! "s" :op nil nil nil {}))))

(let [request-bytes (first encoded-packets)
      simple-page-response
      (wire/encode-rpc-packet-v2!
       (wire/rpc-response-packet
        1 (wire/rpc-response! "s" :op 0
                              (wire/rpc-page-response! 0 nil false)
                              nil nil)))
      truncated (java.util.Arrays/copyOf
                 ^bytes request-bytes (dec (alength ^bytes request-bytes)))
      extra (appended-byte request-bytes 0)
      extra-in-body (put-u32-le! (appended-byte request-bytes 0)
                                 14 (inc (- (alength ^bytes request-bytes) 26)))
      invalid-presence (altered-byte request-bytes 50 2)
      invalid-bool (altered-byte simple-page-response
                                 (- (alength ^bytes simple-page-response) 3) 2)]
  (check! "bad magic is typed"
          (= :rpc-invalid-magic
             (thrown-code #(wire/decode-rpc-packet-v2!
                            (altered-byte request-bytes 0 0)))))
  (check! "unsupported version is typed"
          (= :rpc-unsupported-version
             (thrown-code #(wire/decode-rpc-packet-v2!
                            (altered-byte request-bytes 8 1)))))
  (check! "unknown packet kind is typed"
          (= :rpc-invalid-kind
             (thrown-code #(wire/decode-rpc-packet-v2!
                            (altered-byte request-bytes 12 9)))))
  (check! "nonzero v2 flags are rejected"
          (= :rpc-invalid-flags
             (thrown-code #(wire/decode-rpc-packet-v2!
                            (altered-byte request-bytes 13 1)))))
  (check! "short declared body is typed as truncated"
          (= :rpc-truncated
             (thrown-code #(wire/decode-rpc-packet-v2! truncated))))
  (check! "bytes beyond declared body are rejected"
          (= :rpc-trailing-bytes
             (thrown-code #(wire/decode-rpc-packet-v2! extra))))
  (check! "bytes left by the body decoder are rejected"
          (= :rpc-trailing-bytes
             (thrown-code #(wire/decode-rpc-packet-v2! extra-in-body))))
  (check! "presence bytes accept only 0 or 1"
          (= :rpc-invalid-presence
             (thrown-code #(wire/decode-rpc-packet-v2! invalid-presence))))
  (check! "boolean bytes accept only 0 or 1"
          (= :rpc-invalid-boolean
             (thrown-code #(wire/decode-rpc-packet-v2! invalid-bool))))
  (check! "bad Term tag is typed"
          (= :term-codec-bad-tag
             (thrown-code #(wire/decode-rpc-packet-v2!
                            (altered-byte request-bytes 40 99)))))
  (check! "invalid UTF-8 is typed"
          (= :term-codec-invalid-utf8
             (thrown-code
              #(wire/decode-rpc-packet-v2!
                (-> request-bytes
                    (altered-byte 31 0xc3)
                    (altered-byte 32 0x28)))))))

(let [cancel (wire/encode-rpc-packet-v2! cancel-packet)
      nonempty (put-u32-le! (appended-byte cancel 0) 14 1)
      too-large-header (put-u32-le!
                        (java.util.Arrays/copyOf ^bytes cancel 26)
                        14 (inc wire/rpc-v2-max-body-bytes))
      space-prefix (byte-array [(unchecked-byte 1)
                                (unchecked-byte 1) (unchecked-byte 16)
                                (unchecked-byte 0) (unchecked-byte 0)])
      request-header (-> (java.util.Arrays/copyOf ^bytes cancel 26)
                         (altered-byte 12 1)
                         (put-u32-le! 14 5))
      oversized-space (concat-bytes [request-header space-prefix])]
  (check! "cancel rejects a nonempty body"
          (= :rpc-invalid-shape
             (thrown-code #(wire/decode-rpc-packet-v2! nonempty))))
  (check! "declared body cap is checked before truncation or allocation"
          (= :rpc-packet-too-large
             (thrown-code #(wire/decode-rpc-packet-v2! too-large-header))))
  (check! "SpaceId length is rejected before its bytes are allocated/read"
          (= :term-codec-string-limit
             (thrown-code #(wire/decode-rpc-packet-v2! oversized-space)))))

(let [oversized (byte-array (inc wire/rpc-v2-max-packet-bytes))]
  (check! "physical packet cap is checked before ByteBuffer/body allocation"
          (= :rpc-packet-too-large
             (thrown-code #(wire/decode-rpc-packet-v2! oversized)))))

(let [bad-instant (hex-bytes "08000000000000000000ca9a3b")]
  (check! "noncanonical Instant nanos are rejected"
          (= :term-codec-invalid-instant
             (thrown-code #(decode-term bad-instant)))))

(println (str "store_rpc_v2_test: "
              (if (zero? @failures) "PASS" (str @failures " FAIL"))))
(System/exit (if (zero? @failures) 0 1))
