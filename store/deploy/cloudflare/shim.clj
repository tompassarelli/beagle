#!/usr/bin/env bb
;; Authenticated JSON gateway for the private Store RPC server socket.
;; JSON is an edge representation only: the server receives one closed binary
;; RpcRequest, and its typed RpcResponse is rendered back to strict JSON.
(require '[org.httpkit.server :as srv]
         '[cheshire.core :as json]
         '[cheshire.factory :as json-factory]
         '[clojure.string :as str]
         '[store.rpc :as rpc]
         '[store.rt :as rt]
         '[store.types :as terms])
(import '[java.io ByteArrayOutputStream InputStream]
        '[java.nio ByteBuffer]
        '[java.nio.charset CodingErrorAction StandardCharsets])

(def store-host (or (System/getenv "BEAGLE_STORE_SERVER_CONNECT") "127.0.0.1"))
(def store-port (parse-long (or (System/getenv "BEAGLE_STORE_SERVER_PORT") "7977")))
(def shim-port (parse-long (or (System/getenv "SHIM_PORT") "8787")))
(def max-body-bytes (* 1024 1024))

(def token
  (or (System/getenv "SHIM_TOKEN")
      (some-> (System/getenv "SHIM_TOKEN_FILE") slurp str/trim not-empty)
      (when-not (= "1" (System/getenv "SHIM_LIBRARY"))
        (binding [*out* *err*]
          (println "FATAL: set SHIM_TOKEN or SHIM_TOKEN_FILE"))
        (System/exit 2))))

(def allowed-ops
  {"/q" #{:rpc/version :rpc/status :rpc/scan :rpc/query :rpc/occurrences
           :rpc/lease-check :rpc/validate}
   "/assert" #{:rpc/assert :rpc/retract :rpc/batch :rpc/lease-acquire
                 :rpc/lease-renew :rpc/lease-release}})

(def strict-json-factory
  (json-factory/make-json-factory
   (assoc json-factory/default-factory-options
          :strict-duplicate-detection true
          :max-input-nesting-depth 300
          :max-input-document-length max-body-bytes
          :max-input-string-length max-body-bytes
          :max-input-token-count 200000)))

(defn- fail! [code message]
  (throw (ex-info message {:shim/code code})))

(defn- keyword-text [value]
  (subs (str value) 1))

(defn- canonical-keyword? [value]
  (and (string? value)
       (boolean (re-matches #"[A-Za-z0-9*+!_?<>=$%&.-]+(?:/[A-Za-z0-9*+!_?<>=$%&.-]+)?"
                            value))))

(defn- parse-i64! [value label]
  (when-not (and (string? value)
                 (re-matches #"(?:0|-[1-9][0-9]*|[1-9][0-9]*)" value))
    (fail! "shim/noncanonical-integer" (str label " must be a canonical decimal i64 string")))
  (try
    (Long/parseLong value)
    (catch Throwable _
      (fail! "shim/integer-range" (str label " is outside i64")))))

(defn- parse-u32! [value label]
  (let [parsed (parse-i64! value label)]
    (when-not (<= 0 parsed 4294967295)
      (fail! "shim/integer-range" (str label " is outside u32")))
    parsed))

(defn- parse-float64! [value]
  (when-not (and (string? value) (re-matches #"[0-9a-f]{16}" value))
    (fail! "shim/noncanonical-float64" "float64 bits must be exactly 16 lowercase hexadecimal digits"))
  (let [bits (try
               (Long/parseUnsignedLong value 16)
               (catch Throwable _
                 (fail! "shim/noncanonical-float64" "invalid float64 bits")))
        decoded (Double/longBitsToDouble bits)
        canonical (format "%016x" (Double/doubleToLongBits decoded))]
    (when-not (= value canonical)
      (fail! "shim/noncanonical-float64" "noncanonical NaN payload"))
    decoded))

(defn- count-node! [nodes]
  (when (> (swap! nodes inc) rpc/rpc-v2-max-term-nodes)
    (fail! "shim/term-node-limit" "Term exceeds the node limit")))

(declare decode-term!)

(defn- decode-term! [value nodes depth]
  (when (> depth rpc/rpc-v2-max-term-depth)
    (fail! "shim/term-depth-limit" "Term exceeds the nesting limit"))
  (count-node! nodes)
  (when-not (vector? value)
    (fail! "shim/invalid-term" "Term must be one exact tagged JSON array"))
  (let [tag (first value)]
    (when-not (string? tag)
      (fail! "shim/invalid-term" "Term tag must be a string"))
    (case tag
      "string"
      (do (when-not (and (= 2 (count value)) (string? (second value)))
            (fail! "shim/invalid-term" "string Term must be [\"string\", value]"))
          (second value))

      "integer"
      (do (when-not (= 2 (count value))
            (fail! "shim/invalid-term" "integer Term has the wrong arity"))
          (parse-i64! (second value) "integer Term"))

      "float64"
      (do (when-not (= 2 (count value))
            (fail! "shim/invalid-term" "float64 Term has the wrong arity"))
          (parse-float64! (second value)))

      "boolean"
      (do (when-not (and (= 2 (count value)) (boolean? (second value)))
            (fail! "shim/invalid-term" "boolean Term must contain one JSON boolean"))
          (second value))

      "keyword"
      (let [text (second value)]
        (when-not (and (= 2 (count value)) (canonical-keyword? text))
          (fail! "shim/noncanonical-keyword" "keyword Term is not canonical"))
        (keyword text))

      "instant"
      (do (when-not (= 3 (count value))
            (fail! "shim/invalid-term" "instant Term has the wrong arity"))
          (let [seconds (parse-i64! (nth value 1) "instant seconds")
                nanos (parse-u32! (nth value 2) "instant nanoseconds")]
            (when (>= nanos 1000000000)
              (fail! "shim/invalid-instant" "instant nanoseconds must be below 1000000000"))
            (terms/instant seconds nanos)))

      "triple"
      (do (when-not (= 4 (count value))
            (fail! "shim/invalid-term" "triple Term has the wrong arity"))
          (terms/triple (decode-term! (nth value 1) nodes (inc depth))
                        (decode-term! (nth value 2) nodes (inc depth))
                        (decode-term! (nth value 3) nodes (inc depth))))

      (fail! "shim/unknown-term-tag" (str "unknown Term tag " (pr-str tag))))))

(defn decode-json-term! [value]
  (decode-term! value (atom 0) 0))

(declare encode-json-term)

(defn encode-json-term [value]
  (cond
    (string? value) ["string" value]
    (integer? value) ["integer" (str value)]
    (and (number? value) (not (integer? value)))
    ["float64" (format "%016x" (Double/doubleToLongBits (double value)))]
    (boolean? value) ["boolean" value]
    (keyword? value) ["keyword" (keyword-text value)]
    (terms/instant? value)
    ["instant" (str (terms/instant-epoch-seconds value))
     (str (terms/instant-nanos value))]
    (terms/triple? value)
    ["triple" (encode-json-term (terms/triple-t1 value))
     (encode-json-term (terms/triple-t2 value))
     (encode-json-term (terms/triple-t3 value))]
    :else (fail! "shim/invalid-upstream-term"
                 (str "server returned a value outside Term: " (class value)))))

(defn- exact-keys! [value required allowed label]
  (when-not (map? value)
    (fail! "shim/invalid-envelope" (str label " must be a JSON object")))
  (let [actual (set (keys value))
        missing (seq (remove actual required))
        extra (seq (remove allowed actual))]
    (when missing
      (fail! "shim/invalid-envelope" (str label " is missing keys " (pr-str (vec missing)))))
    (when extra
      (fail! "shim/unknown-key" (str label " contains unknown keys " (pr-str (vec extra))))))
  value)

(defn- request-page! [value]
  (exact-keys! value #{"limit"} #{"limit" "cursor"} "page")
  (let [limit (parse-u32! (get value "limit") "page.limit")]
    (when (zero? limit)
      (fail! "shim/invalid-page" "page.limit must be positive"))
    (rpc/rpc-page-request!
     limit
     (when (contains? value "cursor")
       (decode-json-term! (get value "cursor"))))))

(defn- request-op! [value]
  (when-not (and (string? value) (re-matches #"rpc/[a-z][a-z0-9-]*" value))
    (fail! "shim/noncanonical-operation" "op must be a canonical rpc/... string"))
  (keyword value))

(defn- request-space! [value]
  (when-not (and (string? value) (not (str/blank? value)))
    (fail! "shim/invalid-space" "space must be a non-empty string"))
  (when (> (alength (.getBytes ^String value StandardCharsets/UTF_8))
           rpc/rpc-v2-max-space-bytes)
    (fail! "shim/invalid-space" "space exceeds the Store RPC byte limit"))
  value)

(defn json-request! [value]
  (exact-keys! value #{"space" "op" "payload"}
               #{"space" "op" "payload" "expectedVersion" "page" "timeoutMs"}
               "request")
  (rpc/rpc-request!
   (request-space! (get value "space"))
   (request-op! (get value "op"))
   (when (contains? value "expectedVersion")
     (let [version (parse-i64! (get value "expectedVersion") "expectedVersion")]
       (when (neg? version)
         (fail! "shim/invalid-version" "expectedVersion must be non-negative"))
       version))
   (when (contains? value "page") (request-page! (get value "page")))
   (when (contains? value "timeoutMs")
     (parse-u32! (get value "timeoutMs") "timeoutMs"))
   (decode-json-term! (get value "payload"))))

(defn- page-json [page]
  (cond-> {"ordinal" (str (terms/rpcpageresponse-ordinal page))
           "done" (terms/rpcpageresponse-done page)}
    (some? (terms/rpc-page-response-cursor-value page))
    (assoc "nextCursor"
           (encode-json-term (terms/rpc-page-response-cursor-value page)))))

(defn- error-json [error]
  (cond-> {"code" (keyword-text (terms/rpcerror-code error))
           "retryable" (terms/rpcerror-retryable error)
           "message" (terms/rpcerror-message error)}
    (some? (terms/rpc-error-detail-value error))
    (assoc "detail" (encode-json-term (terms/rpc-error-detail-value error)))))

(defn response-json [response]
  (cond-> {"space" (terms/rpcresponse-space response)
           "op" (keyword-text (terms/rpcresponse-op response))
           "servedVersion" (str (terms/rpcresponse-served-version response))}
    (some? (terms/rpcresponse-page response))
    (assoc "page" (page-json (terms/rpcresponse-page response)))
    (some? (terms/rpcresponse-error response))
    (assoc "error" (error-json (terms/rpcresponse-error response)))
    (some? (terms/rpc-response-payload-value response))
    (assoc "payload" (encode-json-term (terms/rpc-response-payload-value response)))))

(defn- shim-error [code retryable message]
  {"error" {"code" code "retryable" retryable "message" message}})

(defn- json-bytes [value]
  (.getBytes ^String (str (json/generate-string value) "\n") StandardCharsets/UTF_8))

(defn- json-response [status value]
  (let [bytes (json-bytes value)]
    (if (> (alength bytes) max-body-bytes)
      {:status 502
       :headers {"content-type" "application/json"}
       :body (String. (json-bytes (shim-error "shim/response-too-large" false
                                              "JSON response exceeds 1 MiB"))
                      StandardCharsets/UTF_8)}
      {:status status
       :headers {"content-type" "application/json"}
       :body (String. bytes StandardCharsets/UTF_8)})))

(defn- authorized? [request]
  (let [header (get (:headers request) "authorization" "")
        presented (if (str/starts-with? header "Bearer ") (subs header 7) "")]
    (and token
         (java.security.MessageDigest/isEqual
          (.getBytes ^String presented StandardCharsets/UTF_8)
          (.getBytes ^String token StandardCharsets/UTF_8)))))

(defn- bounded-bytes! [body]
  (cond
    (nil? body) (fail! "shim/empty-body" "request body is empty")
    (string? body)
    (let [bytes (.getBytes ^String body StandardCharsets/UTF_8)]
      (when (> (alength bytes) max-body-bytes)
        (fail! "shim/body-too-large" "request body exceeds 1 MiB"))
      bytes)
    (instance? (Class/forName "[B") body)
    (do (when (> (alength ^bytes body) max-body-bytes)
          (fail! "shim/body-too-large" "request body exceeds 1 MiB"))
        body)
    (instance? InputStream body)
    (with-open [input ^InputStream body
                output (ByteArrayOutputStream.)]
      (let [chunk (byte-array 8192)]
        (loop [total 0]
          (let [n (.read input chunk)]
            (if (neg? n)
              (.toByteArray output)
              (let [next-total (+ total n)]
                (when (> next-total max-body-bytes)
                  (fail! "shim/body-too-large" "request body exceeds 1 MiB"))
                (.write output chunk 0 n)
                (recur next-total)))))))
    :else (fail! "shim/invalid-body" "request body is not a byte stream")))

(defn- utf8! [bytes]
  (try
    (str (.decode (doto (.newDecoder StandardCharsets/UTF_8)
                    (.onMalformedInput CodingErrorAction/REPORT)
                    (.onUnmappableCharacter CodingErrorAction/REPORT))
                  (ByteBuffer/wrap bytes)))
    (catch Throwable _
      (fail! "shim/invalid-utf8" "request body is not valid UTF-8"))))

(defn- single-json-object! [text]
  (let [s (str/trim text)]
    (when (str/blank? s)
      (fail! "shim/empty-body" "request body is empty"))
    (when-not (= \{ (first s))
      (fail! "shim/invalid-json" "request must be one JSON object"))
    (loop [index 0 depth 0 in-string false escape false]
      (when (>= index (count s))
        (fail! "shim/invalid-json" "unterminated JSON object"))
      (let [ch (.charAt s index)]
        (cond
          escape (recur (inc index) depth in-string false)
          (and in-string (= ch \\)) (recur (inc index) depth true true)
          (= ch \") (recur (inc index) depth (not in-string) false)
          in-string (recur (inc index) depth true false)
          (or (= ch \{) (= ch \[)) (recur (inc index) (inc depth) false false)
          (or (= ch \}) (= ch \]))
          (let [next-depth (dec depth)]
            (if (zero? next-depth)
              (when-not (str/blank? (subs s (inc index)))
                (fail! "shim/invalid-json" "trailing data after JSON object"))
              (recur (inc index) next-depth false false)))
          :else (recur (inc index) depth false false))))
    s))

(defn parse-json-request! [body]
  (let [text (-> body bounded-bytes! utf8! single-json-object!)
        value (try
                (binding [json-factory/*json-factory* strict-json-factory]
                  (json/parse-string-strict text))
                (catch Throwable error
                  (fail! "shim/invalid-json" (str "invalid JSON: " (.getMessage error)))))]
    (json-request! value)))

(defn handler [request]
  (let [path (:uri request)]
    (cond
      (not (authorized? request))
      (json-response 401 (shim-error "shim/unauthorized" false "unauthorized"))

      (not= :post (:request-method request))
      (json-response 405 (shim-error "shim/method-not-allowed" false "POST only"))

      (not (contains? allowed-ops path))
      (json-response 404 (shim-error "shim/unknown-path" false
                                     "known paths are POST /q and POST /assert"))

      (not= "application/json"
            (some-> (get (:headers request) "content-type" "")
                    (str/split #";" 2) first str/trim str/lower-case))
      (json-response 415 (shim-error "shim/content-type" false
                                     "content-type must be application/json"))

      :else
      (try
        (let [rpc-request (parse-json-request! (:body request))
              operation (terms/rpcrequest-op rpc-request)]
          (if-not (contains? (get allowed-ops path) operation)
            (json-response 403 (shim-error "shim/operation-not-allowed" false
                                           (str (keyword-text operation)
                                                " is not allowed on " path)))
            (json-response 200
                           (response-json
                            (rt/native-request-to! store-host store-port rpc-request)))))
        (catch clojure.lang.ExceptionInfo error
          (if-let [code (:shim/code (ex-data error))]
            (json-response 400 (shim-error code false (.getMessage error)))
            (json-response 502 (shim-error "shim/upstream-failure" true
                                           "server request failed"))))
        (catch Throwable _
          (json-response 502 (shim-error "shim/upstream-failure" true
                                         "server request failed")))))))

(when-not (= "1" (System/getenv "SHIM_LIBRARY"))
  (srv/run-server handler {:ip "0.0.0.0" :port shim-port})
  (println (str "store-shim listening on 0.0.0.0:" shim-port
                " -> Store RPC " store-host ":" store-port))
  @(promise))
