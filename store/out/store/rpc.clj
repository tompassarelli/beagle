(ns store.rpc
  (:require [store.rpc-limits :as limits]
            [store.types :as t])
  (:import [java.io ByteArrayOutputStream]
           [java.io OutputStream]
           [java.nio ByteBuffer]
           [java.nio ByteOrder]
           [java.nio CharBuffer]
           [java.nio.charset CharacterCodingException]
           [java.nio.charset CodingErrorAction]
           [java.nio.charset StandardCharsets]))

(def term-codec-v1-depth-limit limits/term-codec-v1-max-depth)

(defn- codec-fail! [code ^String message]
  (throw (ex-info message {:type code :store-rpc/code code})))

(defn- require-codec-limits! [max-string-bytes max-nodes max-depth]
  (if (and (> max-string-bytes 0) (and (> max-nodes 0) (and (> max-depth 0) (<= max-depth 256)))) nil (codec-fail! :term-codec-invalid-limit "TermCodecV1 limits must be positive and depth at most 256")))

(defn- utf8-length! [^String value maximum ^String label]
  (loop [index 0
   total 0]
  (if (>= index (count value)) total (let [unit (int (.charAt value index))
   high? (and (>= unit 55296) (<= unit 56319))
   low? (and (>= unit 56320) (<= unit 57343))
   pair-unit (if (and high? (< (+ index 1) (count value))) (int (.charAt value (+ index 1))) -1)
   pair? (and high? (and (>= pair-unit 56320) (<= pair-unit 57343)))
   width (cond
  (<= unit 127) 1
  (<= unit 2047) 2
  pair? 4
  (or high? low?) -1
  :else 3)]
  (if (= width -1) (codec-fail! :term-codec-invalid-utf8 (str label " contains an unpaired UTF-16 surrogate")) (let [next-total (+ total width)]
  (if (> next-total maximum) (codec-fail! :term-codec-string-limit (str label " exceeds the UTF-8 byte limit")) (recur (+ index (if pair? 2 1)) next-total))))))))

(defn- strict-utf8-bytes! [^String value maximum ^String label]
  (let [expected (utf8-length! value maximum label)]
  (try
  (let [encoder (doto (.newEncoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))
   buffer (.encode encoder (CharBuffer/wrap value))
   bytes (byte-array (.remaining buffer))]
  (.get buffer bytes)
  (if (= expected (alength bytes)) bytes (codec-fail! :term-codec-invalid-utf8 (str label " encoded to an unexpected byte length"))))
  (catch CharacterCodingException _
    (codec-fail! :term-codec-invalid-utf8 (str label " is not valid UTF-8 text"))))))

(defn- ^String strict-utf8-string! [bytes ^String label]
  (try
  (let [decoder (doto (.newDecoder StandardCharsets/UTF_8)
  (.onMalformedInput CodingErrorAction/REPORT)
  (.onUnmappableCharacter CodingErrorAction/REPORT))]
  (str (.decode decoder (ByteBuffer/wrap bytes))))
  (catch CharacterCodingException _
    (codec-fail! :term-codec-invalid-utf8 (str label " is not valid UTF-8")))))

(defn- codec-write-u8! [out value]
  (.write out (int (bit-and 255 value)))
  nil)

(defn- codec-write-u32-le! [out value]
  (if (and (>= value 0) (<= value 4294967295)) (do
  (loop [offset 0]
  (if (< offset 4) (do
  (codec-write-u8! out (unsigned-bit-shift-right value (* offset 8)))
  (recur (+ offset 1))) nil))
  nil) (codec-fail! :term-codec-integer-range "u32 value is out of range")))

(defn- codec-write-i64-le! [out value]
  (loop [offset 0]
  (if (< offset 8) (do
  (codec-write-u8! out (unsigned-bit-shift-right value (* offset 8)))
  (recur (+ offset 1))) nil)))

(defn- codec-node! [counter maximum]
  (let [count-value (swap! counter inc)]
  (if (> count-value maximum) (codec-fail! :term-codec-node-limit "TermCodecV1 node count exceeds the configured bound") nil)))

(defn- measure-term-core! [term depth max-string-bytes max-nodes max-depth counter]
  (if (> depth max-depth) (codec-fail! :term-depth-exceeded "recursive Term exceeds the TermCodecV1 depth bound") (do
  (codec-node! counter max-nodes)
  (cond
  (t/triple? term) (+ 1 (+ (measure-term-core! (t/triple-t1 term) (+ depth 1) max-string-bytes max-nodes max-depth counter) (+ (measure-term-core! (t/triple-t2 term) (+ depth 1) max-string-bytes max-nodes max-depth counter) (measure-term-core! (t/triple-t3 term) (+ depth 1) max-string-bytes max-nodes max-depth counter))))
  (string? term) (+ 5 (utf8-length! term max-string-bytes "String atom"))
  (integer? term) 9
  (and (number? term) (not (integer? term))) 9
  (boolean? term) 1
  (keyword? term) (let [spelling (subs (str term) 1)]
  (if (empty? spelling) (codec-fail! :term-codec-invalid-keyword "Keyword atom spelling must be nonempty") (+ 5 (utf8-length! spelling max-string-bytes "Keyword atom"))))
  (t/instant? term) 13
  :else (codec-fail! :term-codec-unsupported-term "TermCodecV1 encountered a value outside Term")))))

(defn measure-term-codec-v1! [term max-string-bytes max-nodes max-depth]
  (require-codec-limits! max-string-bytes max-nodes max-depth)
  (let [counter (atom 0)
   byte-count (measure-term-core! term 0 max-string-bytes max-nodes max-depth counter)]
  (t/->TermCodecMeasure byte-count (deref counter))))

(defn- write-sized-text-core! [out ^String value max-string-bytes ^String label]
  (let [bytes (strict-utf8-bytes! value max-string-bytes label)]
  (codec-write-u32-le! out (alength bytes))
  (.write out bytes)
  nil))

(defn- write-term-core! [out term max-string-bytes]
  (cond
  (t/triple? term) (do
  (codec-write-u8! out 7)
  (write-term-core! out (t/triple-t1 term) max-string-bytes)
  (write-term-core! out (t/triple-t2 term) max-string-bytes)
  (write-term-core! out (t/triple-t3 term) max-string-bytes))
  (string? term) (do
  (codec-write-u8! out 1)
  (write-sized-text-core! out term max-string-bytes "String atom"))
  (integer? term) (do
  (codec-write-u8! out 2)
  (codec-write-i64-le! out term))
  (and (number? term) (not (integer? term))) (do
  (codec-write-u8! out 3)
  (codec-write-i64-le! out (Double/doubleToLongBits (double term))))
  (false? term) (codec-write-u8! out 4)
  (true? term) (codec-write-u8! out 5)
  (keyword? term) (do
  (codec-write-u8! out 6)
  (write-sized-text-core! out (subs (str term) 1) max-string-bytes "Keyword atom"))
  (t/instant? term) (do
  (codec-write-u8! out 8)
  (codec-write-i64-le! out (t/instant-epoch-seconds term))
  (codec-write-u32-le! out (t/instant-nanos term)))
  :else (codec-fail! :term-codec-unsupported-term "TermCodecV1 encountered a value outside Term")))

(defn write-term-codec-v1! [out term max-string-bytes max-nodes max-depth]
  (let [measure (measure-term-codec-v1! term max-string-bytes max-nodes max-depth)]
  (write-term-core! out term max-string-bytes)
  (t/termcodecmeasure-nodes measure)))

(defn- codec-ensure! [buffer count-value ^String context]
  (if (< (.remaining buffer) count-value) (codec-fail! :term-codec-truncated (str "TermCodecV1 ended inside " context)) nil))

(defn- codec-read-u8! [buffer ^String context]
  (codec-ensure! buffer 1 context)
  (let [one (byte-array 1)]
  (.get buffer one)
  (bit-and 255 (int (aget one 0)))))

(defn- codec-read-u32-le! [buffer ^String context]
  (codec-ensure! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer)))

(defn- ^String read-sized-text-core! [buffer max-string-bytes ^String context]
  (let [length (codec-read-u32-le! buffer context)]
  (if (> length max-string-bytes) (codec-fail! :term-codec-string-limit (str context " exceeds the UTF-8 byte limit")) (do
  (codec-ensure! buffer length context)
  (let [bytes (byte-array length)]
  (.get buffer bytes)
  (strict-utf8-string! bytes context))))))

(defn- triple-from-proven-terms [t1 t2 t3]
  (t/->Triple t1 t2 t3))

(defn- decode-term-core! [buffer depth max-string-bytes max-nodes max-depth counter]
  (if (> depth max-depth) (codec-fail! :term-depth-exceeded "recursive Term exceeds the TermCodecV1 depth bound") (do
  (codec-node! counter max-nodes)
  (let [tag (codec-read-u8! buffer "Term tag")]
  (cond
  (= tag 1) (read-sized-text-core! buffer max-string-bytes "String atom")
  (= tag 2) (do
  (codec-ensure! buffer 8 "Int atom")
  (.getLong buffer))
  (= tag 3) (do
  (codec-ensure! buffer 8 "Float atom")
  (Double/longBitsToDouble (.getLong buffer)))
  (= tag 4) false
  (= tag 5) true
  (= tag 6) (let [spelling (read-sized-text-core! buffer max-string-bytes "Keyword atom")]
  (if (empty? spelling) (codec-fail! :term-codec-invalid-keyword "Keyword atom spelling must be nonempty") (keyword spelling)))
  (= tag 7) (triple-from-proven-terms (decode-term-core! buffer (+ depth 1) max-string-bytes max-nodes max-depth counter) (decode-term-core! buffer (+ depth 1) max-string-bytes max-nodes max-depth counter) (decode-term-core! buffer (+ depth 1) max-string-bytes max-nodes max-depth counter))
  (= tag 8) (do
  (codec-ensure! buffer 12 "Instant atom")
  (let [seconds (.getLong buffer)
   nanos (codec-read-u32-le! buffer "Instant nanos")]
  (if (< nanos 1000000000) (t/instant seconds nanos) (codec-fail! :term-codec-invalid-instant "Instant nanoseconds are outside the canonical range"))))
  :else (codec-fail! :term-codec-bad-tag "TermCodecV1 contains an unknown tag"))))))

(defn decode-term-codec-v1! [buffer max-string-bytes max-nodes max-depth]
  (require-codec-limits! max-string-bytes max-nodes max-depth)
  (.order buffer ByteOrder/LITTLE_ENDIAN)
  (let [counter (atom 0)
   value (decode-term-core! buffer 0 max-string-bytes max-nodes max-depth counter)]
  (t/->TermCodecDecoded value (deref counter))))

(def rpc-v2-major 2)

(def rpc-v2-minor 0)

(def rpc-v2-header-bytes 26)

(def rpc-v2-max-body-bytes 1048576)

(def store-rpc-v2-max-packet-bytes 1048602)

(def rpc-v2-max-string-bytes 1048576)

(def rpc-v2-max-space-bytes 4096)

(def rpc-v2-max-term-nodes 65536)

(def rpc-v2-max-term-depth limits/term-codec-v1-max-depth)

(def store-rpc-v2-magic (.getBytes "STORERPC" StandardCharsets/UTF_8))

(defn- rpc-fail! [code ^String message]
  (throw (ex-info message {:type code :store-rpc/code code})))

(defn- ^Boolean rpc-u32? [value]
  (and (>= value 0) (<= value 4294967295)))

(defn- ^Boolean rpc-i64? [value]
  (and (>= value -9223372036854775808) (<= value 9223372036854775807)))

(defn- rpc-kind-code! [kind]
  (cond
  (= kind :request) 1
  (= kind :response) 2
  (= kind :cancel) 3
  (= kind :event) 4
  :else (rpc-fail! :rpc-invalid-kind "Store RPC packet kind is unknown")))

(defn- rpc-code-kind! [code]
  (cond
  (= code 1) :request
  (= code 2) :response
  (= code 3) :cancel
  (= code 4) :event
  :else (rpc-fail! :rpc-invalid-kind "Store RPC packet kind is unknown")))

(defn- require-rpc-term! [value ^String label]
  (if (t/term? value) nil (rpc-fail! :rpc-invalid-term (str label " must be a Term"))))

(defn- require-rpc-optional-term! [value ^String label]
  (if (or (nil? value) (t/term? value)) nil (rpc-fail! :rpc-invalid-term (str label " must be nil or a Term"))))

(defn- require-rpc-string! [value ^String label]
  (if (string? value) nil (rpc-fail! :rpc-invalid-field (str label " must be a String"))))

(defn- require-rpc-keyword! [value ^String label]
  (if (keyword? value) nil (rpc-fail! :rpc-invalid-field (str label " must be a Keyword"))))

(defn- require-rpc-u32! [value ^String label]
  (if (rpc-u32? value) nil (rpc-fail! :rpc-integer-range (str label " is outside u32"))))

(defn- require-rpc-i64! [value ^String label]
  (if (rpc-i64? value) nil (rpc-fail! :rpc-integer-range (str label " is outside i64"))))

(defn rpc-page-request! [limit cursor]
  (require-rpc-u32! limit "page limit")
  (require-rpc-optional-term! cursor "page cursor")
  (t/->RpcPageRequest limit cursor))

(defn rpc-page-response! [ordinal next-cursor ^Boolean done]
  (require-rpc-u32! ordinal "page ordinal")
  (require-rpc-optional-term! next-cursor "next cursor")
  (t/->RpcPageResponse ordinal next-cursor done))

(defn rpc-error! [code ^Boolean retryable ^String message detail]
  (require-rpc-keyword! code "error code")
  (require-rpc-string! message "error message")
  (require-rpc-optional-term! detail "error detail")
  (t/->RpcError code retryable message detail))

(defn rpc-request! [^String space op expected-version page timeout-ms payload]
  (require-rpc-string! space "request space")
  (require-rpc-keyword! op "request op")
  (if expected-version (require-rpc-i64! expected-version "expected version") nil)
  (if timeout-ms (require-rpc-u32! timeout-ms "timeout-ms") nil)
  (require-rpc-term! payload "request payload")
  (t/->RpcRequest space op expected-version page timeout-ms payload))

(defn rpc-response! [^String space op served-version page error payload]
  (require-rpc-string! space "response space")
  (require-rpc-keyword! op "response op")
  (require-rpc-i64! served-version "served version")
  (require-rpc-optional-term! payload "response payload")
  (t/->RpcResponse space op served-version page error payload))

(defn store-rpc-request-packet [request-id request]
  (t/->StoreRpcPacketV2 :request 0 request-id request nil))

(defn store-rpc-response-packet [request-id response]
  (t/->StoreRpcPacketV2 :response 0 request-id nil response))

(defn store-rpc-cancel-packet [request-id]
  (t/->StoreRpcPacketV2 :cancel 0 request-id nil nil))

(defn store-rpc-event-packet [request-id event]
  (t/->StoreRpcPacketV2 :event 0 request-id nil event))

(defn- validate-rpc-page-request! [page]
  (require-rpc-u32! (t/rpcpagerequest-limit page) "page limit")
  (require-rpc-optional-term! (t/rpc-page-request-cursor-value page) "page cursor"))

(defn- validate-rpc-page-response! [page]
  (require-rpc-u32! (t/rpcpageresponse-ordinal page) "page ordinal")
  (require-rpc-optional-term! (t/rpc-page-response-cursor-value page) "next cursor"))

(defn- validate-rpc-error! [error]
  (require-rpc-keyword! (t/rpcerror-code error) "error code")
  (require-rpc-string! (t/rpcerror-message error) "error message")
  (require-rpc-optional-term! (t/rpc-error-detail-value error) "error detail"))

(defn- validate-rpc-request! [request]
  (require-rpc-string! (t/rpcrequest-space request) "request space")
  (utf8-length! (t/rpcrequest-space request) rpc-v2-max-space-bytes "SpaceId")
  (require-rpc-keyword! (t/rpcrequest-op request) "request op")
  (let [expected (t/rpcrequest-expected-version request)
   page (t/rpcrequest-page request)
   timeout (t/rpcrequest-timeout-ms request)]
  (if expected (require-rpc-i64! expected "expected version") nil)
  (if page (validate-rpc-page-request! page) nil)
  (if timeout (require-rpc-u32! timeout "timeout-ms") nil)
  (require-rpc-term! (t/rpc-request-payload-value request) "request payload")))

(defn- validate-rpc-response! [response]
  (require-rpc-string! (t/rpcresponse-space response) "response space")
  (utf8-length! (t/rpcresponse-space response) rpc-v2-max-space-bytes "SpaceId")
  (require-rpc-keyword! (t/rpcresponse-op response) "response op")
  (require-rpc-i64! (t/rpcresponse-served-version response) "served version")
  (let [page (t/rpcresponse-page response)
   error (t/rpcresponse-error response)]
  (if page (validate-rpc-page-response! page) nil)
  (if error (validate-rpc-error! error) nil)
  (require-rpc-optional-term! (t/rpc-response-payload-value response) "response payload")))

(defn- validate-store-rpc-packet! [packet]
  (if (= 0 (t/storerpcpacketv2-flags packet)) nil (rpc-fail! :rpc-invalid-flags "Store RPC v2 flags must be zero"))
  (require-rpc-i64! (t/storerpcpacketv2-request-id packet) "request id")
  (let [kind (t/storerpcpacketv2-kind packet)
   request (t/storerpcpacketv2-request packet)
   response (t/storerpcpacketv2-response packet)]
  (cond
  (= kind :request) (if (and request (nil? response)) (validate-rpc-request! request) (rpc-fail! :rpc-invalid-shape "request packet must carry exactly one RpcRequest"))
  (or (= kind :response) (= kind :event)) (if (and response (nil? request)) (validate-rpc-response! response) (rpc-fail! :rpc-invalid-shape "response/event packet must carry exactly one RpcResponse"))
  (= kind :cancel) (if (and (nil? request) (nil? response)) nil (rpc-fail! :rpc-invalid-shape "cancel packet body must be empty"))
  :else (rpc-fail! :rpc-invalid-kind "Store RPC packet kind is unknown"))))

(defn- rpc-add-measured-term! [term nodes]
  (let [used (int (deref nodes))
   remaining (- rpc-v2-max-term-nodes used)]
  (if (<= remaining 0) (rpc-fail! :rpc-term-node-limit "Store RPC body exceeds the aggregate Term node limit") (let [measure (measure-term-codec-v1! term rpc-v2-max-string-bytes remaining rpc-v2-max-term-depth)]
  (swap! nodes + (t/termcodecmeasure-nodes measure))
  (t/termcodecmeasure-bytes measure)))))

(defn- rpc-page-request-bytes! [page nodes]
  (let [cursor (t/rpc-page-request-cursor-value page)]
  (+ 5 (if (nil? cursor) 0 (rpc-add-measured-term! cursor nodes)))))

(defn- rpc-page-response-bytes! [page nodes]
  (let [cursor (t/rpc-page-response-cursor-value page)]
  (+ 6 (if (nil? cursor) 0 (rpc-add-measured-term! cursor nodes)))))

(defn- rpc-error-bytes! [error nodes]
  (let [detail (t/rpc-error-detail-value error)]
  (+ 2 (+ (rpc-add-measured-term! (t/rpcerror-code error) nodes) (+ (rpc-add-measured-term! (t/rpcerror-message error) nodes) (if (nil? detail) 0 (rpc-add-measured-term! detail nodes)))))))

(defn- rpc-request-body-bytes! [request nodes]
  (let [expected (t/rpcrequest-expected-version request)
   page (t/rpcrequest-page request)
   timeout (t/rpcrequest-timeout-ms request)]
  (+ 3 (+ (rpc-add-measured-term! (t/rpcrequest-space request) nodes) (+ (rpc-add-measured-term! (t/rpcrequest-op request) nodes) (+ (if expected 8 0) (+ (if page (rpc-page-request-bytes! page nodes) 0) (+ (if timeout 4 0) (rpc-add-measured-term! (t/rpc-request-payload-value request) nodes)))))))))

(defn- rpc-response-body-bytes! [response nodes]
  (let [page (t/rpcresponse-page response)
   error (t/rpcresponse-error response)
   payload (t/rpc-response-payload-value response)]
  (+ 11 (+ (rpc-add-measured-term! (t/rpcresponse-space response) nodes) (+ (rpc-add-measured-term! (t/rpcresponse-op response) nodes) (+ (if page (rpc-page-response-bytes! page nodes) 0) (+ (if error (rpc-error-bytes! error nodes) 0) (if (nil? payload) 0 (rpc-add-measured-term! payload nodes)))))))))

(defn- store-rpc-body-bytes! [packet]
  (validate-store-rpc-packet! packet)
  (let [nodes (atom 0)
   kind (t/storerpcpacketv2-kind packet)
   request (t/storerpcpacketv2-request packet)
   response (t/storerpcpacketv2-response packet)
   size (cond
  (and (= kind :request) request) (rpc-request-body-bytes! request nodes)
  (and (or (= kind :response) (= kind :event)) response) (rpc-response-body-bytes! response nodes)
  :else 0)]
  (if (> size rpc-v2-max-body-bytes) (rpc-fail! :rpc-packet-too-large "Store RPC body exceeds the configured byte limit") size)))

(defn- rpc-write-u16-le! [out value]
  (codec-write-u8! out value)
  (codec-write-u8! out (unsigned-bit-shift-right value 8)))

(defn- rpc-write-present! [out value]
  (codec-write-u8! out (if (nil? value) 0 1)))

(defn- rpc-write-term! [out value]
  (write-term-codec-v1! out value rpc-v2-max-string-bytes rpc-v2-max-term-nodes rpc-v2-max-term-depth)
  nil)

(defn- write-rpc-page-request! [out page]
  (codec-write-u32-le! out (t/rpcpagerequest-limit page))
  (let [cursor (t/rpc-page-request-cursor-value page)]
  (rpc-write-present! out cursor)
  (if (nil? cursor) nil (rpc-write-term! out cursor))))

(defn- write-rpc-page-response! [out page]
  (codec-write-u32-le! out (t/rpcpageresponse-ordinal page))
  (let [cursor (t/rpc-page-response-cursor-value page)]
  (rpc-write-present! out cursor)
  (if (nil? cursor) nil (rpc-write-term! out cursor)))
  (codec-write-u8! out (if (t/rpcpageresponse-done page) 1 0)))

(defn- write-rpc-error! [out error]
  (rpc-write-term! out (t/rpcerror-code error))
  (codec-write-u8! out (if (t/rpcerror-retryable error) 1 0))
  (rpc-write-term! out (t/rpcerror-message error))
  (let [detail (t/rpc-error-detail-value error)]
  (rpc-write-present! out detail)
  (if (nil? detail) nil (rpc-write-term! out detail))))

(defn- write-rpc-request! [out request]
  (rpc-write-term! out (t/rpcrequest-space request))
  (rpc-write-term! out (t/rpcrequest-op request))
  (let [expected (t/rpcrequest-expected-version request)
   page (t/rpcrequest-page request)
   timeout (t/rpcrequest-timeout-ms request)]
  (rpc-write-present! out expected)
  (if expected (codec-write-i64-le! out expected) nil)
  (rpc-write-present! out page)
  (if page (write-rpc-page-request! out page) nil)
  (rpc-write-present! out timeout)
  (if timeout (codec-write-u32-le! out timeout) nil)
  (rpc-write-term! out (t/rpc-request-payload-value request))))

(defn- write-rpc-response! [out response]
  (rpc-write-term! out (t/rpcresponse-space response))
  (rpc-write-term! out (t/rpcresponse-op response))
  (codec-write-i64-le! out (t/rpcresponse-served-version response))
  (let [page (t/rpcresponse-page response)
   error (t/rpcresponse-error response)
   payload (t/rpc-response-payload-value response)]
  (rpc-write-present! out page)
  (if page (write-rpc-page-response! out page) nil)
  (rpc-write-present! out error)
  (if error (write-rpc-error! out error) nil)
  (rpc-write-present! out payload)
  (if (nil? payload) nil (rpc-write-term! out payload))))

(defn store-rpc-encode-packet-v2! [packet]
  (let [body-size (store-rpc-body-bytes! packet)
   body (ByteArrayOutputStream. body-size)
   kind (t/storerpcpacketv2-kind packet)
   request (t/storerpcpacketv2-request packet)
   response (t/storerpcpacketv2-response packet)]
  (cond
  (and (= kind :request) request) (write-rpc-request! body request)
  (and (or (= kind :response) (= kind :event)) response) (write-rpc-response! body response)
  :else nil)
  (if (= body-size (.size body)) (let [^ByteArrayOutputStream out (ByteArrayOutputStream. (+ rpc-v2-header-bytes body-size))]
  (.write out store-rpc-v2-magic)
  (rpc-write-u16-le! out rpc-v2-major)
  (rpc-write-u16-le! out rpc-v2-minor)
  (codec-write-u8! out (rpc-kind-code! kind))
  (codec-write-u8! out 0)
  (codec-write-u32-le! out body-size)
  (codec-write-i64-le! out (t/storerpcpacketv2-request-id packet))
  (.write out (.toByteArray body))
  (.toByteArray out)) (rpc-fail! :rpc-size-mismatch "Store RPC preflight size disagrees with encoded body"))))

(defn- rpc-ensure! [buffer count-value ^String context]
  (if (< (.remaining buffer) count-value) (rpc-fail! :rpc-truncated (str "Store RPC ended inside " context)) nil))

(defn- rpc-read-u8! [buffer ^String context]
  (rpc-ensure! buffer 1 context)
  (let [one (byte-array 1)]
  (.get buffer one)
  (bit-and 255 (int (aget one 0)))))

(defn- rpc-read-u16-le! [buffer ^String context]
  (rpc-ensure! buffer 2 context)
  (bit-and 65535 (int (.getShort buffer))))

(defn- rpc-read-u32-le! [buffer ^String context]
  (rpc-ensure! buffer 4 context)
  (Integer/toUnsignedLong (.getInt buffer)))

(defn- rpc-read-i64-le! [buffer ^String context]
  (rpc-ensure! buffer 8 context)
  (.getLong buffer))

(defn- ^Boolean rpc-read-presence! [buffer ^String context]
  (let [value (rpc-read-u8! buffer context)]
  (cond
  (= value 0) false
  (= value 1) true
  :else (rpc-fail! :rpc-invalid-presence (str context " must be the strict byte 0 or 1")))))

(defn- ^Boolean rpc-read-bool! [buffer ^String context]
  (let [value (rpc-read-u8! buffer context)]
  (cond
  (= value 0) false
  (= value 1) true
  :else (rpc-fail! :rpc-invalid-boolean (str context " must be the strict byte 0 or 1")))))

(defn- rpc-read-term! [buffer nodes]
  (let [used (int (deref nodes))
   remaining (- rpc-v2-max-term-nodes used)]
  (if (<= remaining 0) (rpc-fail! :rpc-term-node-limit "Store RPC body exceeds the aggregate Term node limit") (let [decoded (decode-term-codec-v1! buffer rpc-v2-max-string-bytes remaining rpc-v2-max-term-depth)]
  (swap! nodes + (t/termcodecdecoded-nodes decoded))
  (t/termcodecdecoded-value decoded)))))

(defn- ^String rpc-read-space-term! [buffer nodes]
  (if (>= (deref nodes) rpc-v2-max-term-nodes) (rpc-fail! :rpc-term-node-limit "Store RPC body exceeds the aggregate Term node limit") (do
  (swap! nodes inc)
  (let [tag (rpc-read-u8! buffer "SpaceId Term tag")]
  (if (= tag 1) (read-sized-text-core! buffer rpc-v2-max-space-bytes "SpaceId") (rpc-fail! :rpc-invalid-field "Store RPC SpaceId must be a String Term"))))))

(defn- rpc-read-keyword-term! [buffer nodes ^String context]
  (let [value (rpc-read-term! buffer nodes)]
  (if (keyword? value) value (rpc-fail! :rpc-invalid-field (str context " must be a Keyword Term")))))

(defn- ^String rpc-read-string-term! [buffer nodes ^String context]
  (let [value (rpc-read-term! buffer nodes)]
  (if (string? value) value (rpc-fail! :rpc-invalid-field (str context " must be a String Term")))))

(defn- read-rpc-page-request! [buffer nodes]
  (let [limit (rpc-read-u32-le! buffer "page limit")
   cursor? (rpc-read-presence! buffer "page cursor presence")
   cursor (if cursor? (rpc-read-term! buffer nodes) nil)]
  (rpc-page-request! limit cursor)))

(defn- read-rpc-page-response! [buffer nodes]
  (let [ordinal (rpc-read-u32-le! buffer "page ordinal")
   cursor? (rpc-read-presence! buffer "next cursor presence")
   cursor (if cursor? (rpc-read-term! buffer nodes) nil)
   done (rpc-read-bool! buffer "page done")]
  (rpc-page-response! ordinal cursor done)))

(defn- read-rpc-error! [buffer nodes]
  (let [code (rpc-read-keyword-term! buffer nodes "error code")
   retryable (rpc-read-bool! buffer "error retryable")
   message (rpc-read-string-term! buffer nodes "error message")
   detail? (rpc-read-presence! buffer "error detail presence")
   detail (if detail? (rpc-read-term! buffer nodes) nil)]
  (rpc-error! code retryable message detail)))

(defn- read-rpc-request! [buffer nodes]
  (let [space (rpc-read-space-term! buffer nodes)
   op (rpc-read-keyword-term! buffer nodes "request op")
   expected? (rpc-read-presence! buffer "expected-version presence")
   expected (if expected? (rpc-read-i64-le! buffer "expected-version") nil)
   page? (rpc-read-presence! buffer "request page presence")
   page (if page? (read-rpc-page-request! buffer nodes) nil)
   timeout? (rpc-read-presence! buffer "timeout-ms presence")
   timeout (if timeout? (rpc-read-u32-le! buffer "timeout-ms") nil)
   payload (rpc-read-term! buffer nodes)]
  (rpc-request! space op expected page timeout payload)))

(defn- read-rpc-response! [buffer nodes]
  (let [space (rpc-read-space-term! buffer nodes)
   op (rpc-read-keyword-term! buffer nodes "response op")
   served (rpc-read-i64-le! buffer "served-version")
   page? (rpc-read-presence! buffer "response page presence")
   page (if page? (read-rpc-page-response! buffer nodes) nil)
   error? (rpc-read-presence! buffer "response error presence")
   error (if error? (read-rpc-error! buffer nodes) nil)
   payload? (rpc-read-presence! buffer "response payload presence")
   payload (if payload? (rpc-read-term! buffer nodes) nil)]
  (rpc-response! space op served page error payload)))

(defn- ^Boolean rpc-magic-valid! [buffer]
  (loop [index 0
   ^Boolean valid true]
  (if (< index 8) (let [actual (rpc-read-u8! buffer "magic")
   expected (bit-and 255 (int (aget store-rpc-v2-magic index)))]
  (recur (+ index 1) (and valid (= actual expected)))) valid)))

(defn store-rpc-decode-packet-v2! [bytes]
  (let [byte-count (alength bytes)]
  (if (> byte-count store-rpc-v2-max-packet-bytes) (rpc-fail! :rpc-packet-too-large "Store RPC packet exceeds the configured byte limit") nil)
  (if (< byte-count rpc-v2-header-bytes) (rpc-fail! :rpc-truncated "Store RPC packet ended inside its header") nil)
  (let [buffer (doto (ByteBuffer/wrap bytes)
  (.order ByteOrder/LITTLE_ENDIAN))]
  (if (rpc-magic-valid! buffer) nil (rpc-fail! :rpc-invalid-magic "Store RPC magic does not match"))
  (let [major (rpc-read-u16-le! buffer "major version")
   minor (rpc-read-u16-le! buffer "minor version")
   kind (rpc-code-kind! (rpc-read-u8! buffer "packet kind"))
   flags (rpc-read-u8! buffer "packet flags")
   body-length (rpc-read-u32-le! buffer "body length")
   request-id (rpc-read-i64-le! buffer "request id")]
  (if (and (= major rpc-v2-major) (= minor rpc-v2-minor)) nil (rpc-fail! :rpc-unsupported-version "Store RPC major/minor version is unsupported"))
  (if (= flags 0) nil (rpc-fail! :rpc-invalid-flags "Store RPC v2 flags must be zero"))
  (if (> body-length rpc-v2-max-body-bytes) (rpc-fail! :rpc-packet-too-large "Store RPC declared body exceeds the configured byte limit") nil)
  (if (< (.remaining buffer) body-length) (rpc-fail! :rpc-truncated "Store RPC body is shorter than declared") nil)
  (if (> (.remaining buffer) body-length) (rpc-fail! :rpc-trailing-bytes "Store RPC packet has bytes beyond its declared body") nil)
  (let [nodes (atom 0)
   packet (cond
  (= kind :request) (store-rpc-request-packet request-id (read-rpc-request! buffer nodes))
  (= kind :response) (store-rpc-response-packet request-id (read-rpc-response! buffer nodes))
  (= kind :event) (store-rpc-event-packet request-id (read-rpc-response! buffer nodes))
  :else (if (= body-length 0) (store-rpc-cancel-packet request-id) (rpc-fail! :rpc-invalid-shape "Store RPC cancel body must be exactly empty")))]
  (if (zero? (.remaining buffer)) packet (rpc-fail! :rpc-trailing-bytes "Store RPC body decoder left trailing bytes")))))))

(def rpc-unit :rpc/unit)

(def rpc-list-end :rpc/list-end)

(def rpc-none :rpc/none)

(def rpc-subject-any :rpc/subject-any)

(def rpc-subject-existing :rpc/subject-existing)

(def query-current :query/current)

(def rpc-v2-list-envelope-depth limits/rpc-v2-list-envelope-depth)

(def rpc-v2-max-list-values limits/rpc-v2-max-list-values)

(def rpc-v2-mutation-response-wrapper-depth limits/rpc-v2-mutation-response-wrapper-depth)

(def rpc-v2-max-batch-actions limits/rpc-v2-max-batch-actions)

(defn rpc-list! [values]
  (if (> (count values) rpc-v2-max-list-values) (do
  (rpc-fail! :term-depth-exceeded "RPC list length exceeds the TermCodecV1 depth bound")))
  (reduce (fn [tail value] (require-rpc-term! value "RPC list value")
  (triple-from-proven-terms :rpc/list value tail)) rpc-list-end (reverse values)))

(defn rpc-list-values! [value]
  (loop [cursor value
   result []
   count-value 0]
  (cond
  (= cursor rpc-list-end) result
  (>= count-value rpc-v2-max-term-nodes) (rpc-fail! :rpc-invalid-list "RPC list exceeds the Term node bound")
  (and (t/triple? cursor) (= :rpc/list (t/triple-t1 cursor))) (let [head (t/triple-t2 cursor)
   tail (t/triple-t3 cursor)]
  (require-rpc-term! head "RPC list head")
  (recur tail (conj result head) (+ count-value 1)))
  :else (if (and (> count-value 0) (not (t/term? cursor))) (rpc-fail! :rpc-invalid-term "RPC list tail must be a Term") (rpc-fail! :rpc-invalid-list "RPC list must end with :rpc/list-end")))))

(defn rpc-some! [value]
  (require-rpc-term! value "RPC option value")
  (t/triple :rpc/some value :rpc/option))

(defn rpc-option! [value]
  (if (nil? value) rpc-none (rpc-some! value)))

(defn ^Boolean rpc-option-present?! [value]
  (cond
  (= value rpc-none) false
  (and (t/triple? value) (and (= :rpc/some (t/triple-t1 value)) (= :rpc/option (t/triple-t3 value)))) true
  :else (rpc-fail! :rpc-invalid-option "RPC option must be :rpc/none or (:rpc/some value :rpc/option)")))

(defn rpc-option-value! [value]
  (if (rpc-option-present?! value) (t/triple-t2 value) nil))

(defn rpc-record! [tag fields]
  (t/triple tag (rpc-list! fields) :rpc/record))

(defn rpc-record-fields! [value tag field-count]
  (if (and (t/triple? value) (and (= tag (t/triple-t1 value)) (= :rpc/record (t/triple-t3 value)))) (let [fields (rpc-list-values! (t/triple-t2 value))]
  (if (= field-count (count fields)) fields (rpc-fail! :rpc-invalid-record "RPC record contains the wrong number of fields"))) (rpc-fail! :rpc-invalid-record "RPC record tag or marker is invalid")))

(defn rpc-fence! [resource holder epoch]
  (require-rpc-term! resource "lease resource")
  (require-rpc-term! holder "lease holder")
  (rpc-record! :rpc/fence [resource holder epoch]))

(defn rpc-action! [operation proposition policy]
  (if (or (= operation :rpc/assert) (= operation :rpc/retract)) nil (rpc-fail! :rpc-invalid-action "RPC action operation is invalid"))
  (if (or (= policy rpc-subject-any) (= policy rpc-subject-existing)) nil (rpc-fail! :rpc-invalid-policy "RPC subject policy is invalid"))
  (rpc-record! :rpc/action [operation proposition policy]))

(defn rpc-action-result! [input-index ^Boolean changed occurrence]
  (if (t/occurrence-coordinate? occurrence) (rpc-record! :rpc/action-result [input-index changed occurrence]) (rpc-fail! :rpc-invalid-occurrence "RPC action result requires one occurrence coordinate")))

(defn rpc-mutation-result! [results]
  (rpc-record! :rpc/mutation-result [(rpc-list! results)]))

(defn rpc-write! [proposition policy fence]
  (if (or (= policy rpc-subject-any) (= policy rpc-subject-existing)) nil (rpc-fail! :rpc-invalid-policy "RPC subject policy is invalid"))
  (rpc-record! :rpc/write [proposition policy (rpc-option! fence)]))

(defn rpc-batch! [actions fence]
  (rpc-record! :rpc/batch [(rpc-list! actions) (rpc-option! fence)]))

(defn rpc-triple-pattern! [t1 t2 t3]
  (rpc-record! :rpc/triple-pattern [(rpc-option! t1) (rpc-option! t2) (rpc-option! t3)]))

(defn rpc-status! [state live-count engine cache]
  (rpc-record! :rpc/status [state live-count engine cache]))

(defn rpc-triples! [values]
  (rpc-record! :rpc/triples [(rpc-list! values)]))

(defn rpc-occurrence! [coordinate action proposition]
  (if (and (t/occurrence-coordinate? coordinate) (and (or (= action t/assert-action) (= action t/retract-action)) (t/triple? proposition))) (rpc-record! :rpc/occurrence [coordinate action proposition]) (rpc-fail! :rpc-invalid-occurrence "RPC occurrence requires a coordinate, :assert/:retract action, and Triple proposition")))

(defn rpc-occurrences! [values]
  (rpc-record! :rpc/occurrences [(rpc-list! values)]))

(defn rpc-lease-acquire! [resource holder ttl-ms]
  (rpc-record! :lease/acquire [resource holder ttl-ms]))

(defn rpc-lease-renew! [fence ttl-ms]
  (rpc-record! :lease/renew [fence ttl-ms]))

(defn rpc-lease-grant! [fence expires]
  (rpc-record! :lease/grant [fence expires]))

(defn rpc-lease-released! [^Boolean released]
  (rpc-record! :lease/released [released]))

(defn rpc-lease-check! [^Boolean valid expires]
  (rpc-record! :lease/check [valid (rpc-option! expires)]))

(defn rpc-violation! [code detail]
  (rpc-record! :rpc/violation [code detail]))

(defn rpc-validation! [^Boolean valid violations]
  (rpc-record! :rpc/validation [valid (rpc-list! violations)]))

(defn rpc-query-variable! [^String name]
  (rpc-record! :query/var [name]))

(defn rpc-query-constant! [value]
  (rpc-record! :query/const [value]))

(defn rpc-query-head! [^String relation terms]
  (rpc-record! :query/head [relation (rpc-list! terms)]))

(defn rpc-query-relation! [^String relation terms ^Boolean negated]
  (rpc-record! :query/relation [relation (rpc-list! terms) negated]))

(defn rpc-query-predicate! [operation left right]
  (rpc-record! :query/predicate [operation left right]))

(defn rpc-query-function! [operation terms ^String bind-variable]
  (rpc-record! :query/function [operation (rpc-list! terms) bind-variable]))

(defn rpc-query-rule! [head clauses]
  (rpc-record! :query/rule [head (rpc-list! clauses)]))

(defn rpc-query-stratum! [rules]
  (rpc-record! :query/stratum [(rpc-list! rules)]))

(defn rpc-query-find-relation! [^String relation]
  (rpc-record! :query/find-relation [relation]))

(defn rpc-query-aggregate! [operation argument-index]
  (rpc-record! :query/aggregate [operation (rpc-option! argument-index)]))

(defn rpc-query-having! [comparison aggregate-index value]
  (rpc-record! :query/having [comparison aggregate-index value]))

(defn rpc-query-find-aggregate! [^String relation grouping aggregates having]
  (rpc-record! :query/find-aggregate [relation (rpc-list! grouping) (rpc-list! aggregates) (rpc-list! having)]))

(defn rpc-query-order! [column direction]
  (rpc-record! :query/order [column direction]))

(defn rpc-ordered-query-plan! [find strata order limit]
  (rpc-record! :query/plan [find (rpc-list! strata) (rpc-list! order) (rpc-option! limit)]))

(defn rpc-query-plan! [find strata]
  (rpc-ordered-query-plan! find strata [] nil))

(defn rpc-query-as-of! [version]
  (rpc-record! :query/as-of [version]))

(defn rpc-query-since! [lower-exclusive upper]
  (rpc-record! :query/since [lower-exclusive upper]))

(defn rpc-query-request! [plan snapshot]
  (rpc-record! :query/request [plan snapshot]))

(defn rpc-query-row! [values]
  (rpc-record! :query/row [(rpc-list! values)]))

(defn rpc-query-rows! [rows]
  (rpc-record! :query/rows [(rpc-list! rows)]))

(defn rpc-query-cursor! [snapshot-version ^String query-sha256 next-page-ordinal after-row]
  (rpc-record! :query/cursor [snapshot-version query-sha256 next-page-ordinal after-row]))
