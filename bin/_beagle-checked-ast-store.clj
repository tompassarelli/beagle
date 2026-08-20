#!/usr/bin/env bb

(require '[clojure.edn :as edn]
         '[store.dev-compile-facts :as compile-facts])

(import '[java.nio.charset StandardCharsets]
        '[java.security MessageDigest])

(def fact-kind "DevCompileUnitResultV1")
(def fact-stage "typed")

(defn fail! [message status]
  (binding [*out* *err*]
    (println (str "beagle checked AST Store: " message)))
  (System/exit status))

(defn sha256 [^String value]
  (str
   "sha256:"
   (apply str
          (map #(format "%02x" (bit-and (int %) 255))
               (.digest (MessageDigest/getInstance "SHA-256")
                        (.getBytes value StandardCharsets/UTF_8))))))

(defn exact-sha256? [value]
  (and (string? value) (boolean (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn validate-identity! [result-key compiler-context profile unit-id]
  (when-not (and (exact-sha256? result-key)
                 (exact-sha256? compiler-context)
                 (string? profile) (not-empty profile)
                 (string? unit-id) (not-empty unit-id))
    (fail! "identity arguments are malformed" 2)))

(defn envelope [result-key compiler-context profile unit-id payload]
  [fact-kind
   fact-stage
   result-key
   compiler-context
   profile
   unit-id
   (alength (.getBytes ^String payload StandardCharsets/UTF_8))
   (sha256 payload)
   payload])

(defn exact-row-payload
  [row result-key compiler-context profile unit-id]
  (when (and (vector? row)
             (= 4 (count row))
             (= fact-stage (nth row 0))
             (= result-key (nth row 1))
             (string? (nth row 2))
             (string? (nth row 3)))
    (let [fact-id (nth row 2)
          encoding (nth row 3)
          parsed (edn/read-string encoding)]
      (compile-facts/compile-fact fact-id encoding)
      (when (and (vector? parsed)
                 (= 9 (count parsed))
                 (= fact-kind (nth parsed 0))
                 (= fact-stage (nth parsed 1))
                 (= result-key (nth parsed 2))
                 (= compiler-context (nth parsed 3))
                 (= profile (nth parsed 4))
                 (= unit-id (nth parsed 5)))
        (nth parsed 8)))))

(defn query! [store result-key compiler-context profile unit-id]
  (let [response
        (compile-facts/query!
         store [[fact-stage result-key compiler-context profile unit-id]])]
    (when-not (and (vector? response)
                   (= 5 (count response))
                   (= "store.dev-compile-facts/query-response-v1" (nth response 0))
                   (contains? #{"ONLINE" "COLD"} (nth response 1))
                   (vector? (nth response 4)))
      (fail! "query returned an invalid Store response" 2))
    (let [rows (nth response 4)]
      (when (empty? rows) (System/exit 1))
      (let [payloads
            (try
              (vec
               (keep #(exact-row-payload
                       % result-key compiler-context profile unit-id)
                     rows))
              (catch Exception error
                (fail! (str "stored envelope is invalid: " (.getMessage error)) 2)))]
        (when-not (and (= 1 (count rows)) (= 1 (count payloads)))
          (fail! "result key has duplicate, conflicting, or mismatched facts" 2))
        (print (first payloads))
        (flush)))))

(defn append! [store result-key compiler-context profile unit-id payload-path]
  (let [payload (slurp payload-path)
        value (envelope result-key compiler-context profile unit-id payload)
        encoding (pr-str value)
        fact-id (sha256 encoding)
        entry (compile-facts/compile-fact fact-id encoding)
        response (compile-facts/append! store [entry])]
    (when-not (and (vector? response)
                   (= 5 (count response))
                   (= "store.dev-compile-facts/append-response-v1" (nth response 0))
                   (= "ok" (nth response 1)))
      (fail! "append returned an invalid Store response" 2))))

(let [[command store result-key compiler-context profile unit-id payload-path
       & extra] *command-line-args*]
  (when (or (seq extra)
            (nil? command) (nil? store) (nil? result-key)
            (nil? compiler-context) (nil? profile) (nil? unit-id))
    (fail! "usage: query STORE KEY CONTEXT PROFILE UNIT | append STORE KEY CONTEXT PROFILE UNIT PAYLOAD" 2))
  (validate-identity! result-key compiler-context profile unit-id)
  (case command
    "query"
    (do
      (when payload-path (fail! "query accepts no payload path" 2))
      (query! store result-key compiler-context profile unit-id))

    "append"
    (do
      (when-not payload-path (fail! "append requires a payload path" 2))
      (append! store result-key compiler-context profile unit-id payload-path))

    (fail! (str "unknown command: " command) 2)))
