#!/usr/bin/env bb

(require '[clojure.edn :as edn]
         '[store.dev-compile-facts :as compile-facts])

(import '[java.io FileOutputStream]
        '[java.nio.charset StandardCharsets]
        '[java.nio.file CopyOption FileAlreadyExistsException Files StandardCopyOption]
        '[java.nio.file.attribute FileAttribute]
        '[java.security MessageDigest])

(def fact-kind "DevCompileUnitResultV1")
(def fact-stage "typed")
(def blob-kind "beagle.checked-ast/blob-v1")

(defn fail! [message status]
  (binding [*out* *err*]
    (println (str "beagle checked AST Store: " message)))
  (System/exit status))

(defn sha256-bytes [^bytes value]
  (str
   "sha256:"
   (apply str
          (map #(format "%02x" (bit-and (int %) 255))
               (.digest (MessageDigest/getInstance "SHA-256")
                        value)))))

(defn sha256 [^String value]
  (sha256-bytes (.getBytes value StandardCharsets/UTF_8)))

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

(defn blob-path [store digest]
  (let [directory (.toPath (java.io.File. (str store ".objects")))]
    (.resolve directory (subs digest 7))))

(defn read-valid-blob! [store byte-count digest]
  (let [path (blob-path store digest)
        bytes (Files/readAllBytes path)]
    (when-not (and (= byte-count (alength bytes))
                   (= digest (sha256-bytes bytes)))
      (fail! "content-addressed checked AST blob is invalid" 2))
    bytes))

(defn publish-blob! [store ^bytes bytes]
  (let [digest (sha256-bytes bytes)
        path (blob-path store digest)
        directory (.getParent path)]
    (Files/createDirectories directory (make-array FileAttribute 0))
    (if (Files/isRegularFile path (make-array java.nio.file.LinkOption 0))
      (read-valid-blob! store (alength bytes) digest)
      (let [temporary (Files/createTempFile
                       directory ".checked-ast-" ".tmp"
                       (make-array FileAttribute 0))]
        (try
          (with-open [output (FileOutputStream. (.toFile temporary))]
            (.write output bytes)
            (.force (.getChannel output) true))
          (try
            (Files/move temporary path
                        (into-array CopyOption [StandardCopyOption/ATOMIC_MOVE]))
            (catch FileAlreadyExistsException _
              (Files/deleteIfExists temporary)))
          (finally
            (Files/deleteIfExists temporary)))
        (read-valid-blob! store (alength bytes) digest)))
    [blob-kind (alength bytes) digest]))

(defn exact-blob-payload [store payload]
  (let [descriptor (edn/read-string payload)]
    (when (and (vector? descriptor)
               (= 3 (count descriptor))
               (= blob-kind (nth descriptor 0))
               (integer? (nth descriptor 1))
               (<= 0 (nth descriptor 1))
               (exact-sha256? (nth descriptor 2))
               (= payload (pr-str descriptor)))
      (read-valid-blob! store (nth descriptor 1) (nth descriptor 2)))))

(defn exact-row-payload
  [store row result-key compiler-context profile unit-id]
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
        (exact-blob-payload store (nth parsed 8))))))

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
                       store % result-key compiler-context profile unit-id)
                     rows))
              (catch Exception error
                (fail! (str "stored envelope is invalid: " (.getMessage error)) 2)))]
        (when-not (and (= 1 (count rows)) (= 1 (count payloads)))
          (fail! "result key has duplicate, conflicting, or mismatched facts" 2))
        (.write System/out ^bytes (first payloads))
        (flush)))))

(defn append! [store result-key compiler-context profile unit-id payload-path]
  (let [payload-bytes (Files/readAllBytes (.toPath (java.io.File. payload-path)))
        payload (pr-str (publish-blob! store payload-bytes))
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
