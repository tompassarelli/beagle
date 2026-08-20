#!/usr/bin/env bb

;; Batch adapter for source-fact shards. The Store log retains only canonical
;; descriptors; the content-addressed payloads live beside it in STORE.objects.
(ns source-fact-store
  (:require [clojure.edn :as edn]
            [store.dev-compile-facts :as compile-facts])
  (:import [java.io FileOutputStream]
           [java.nio.charset StandardCharsets]
           [java.nio.file CopyOption FileAlreadyExistsException Files StandardCopyOption]
           [java.nio.file.attribute FileAttribute]
           [java.security MessageDigest]))


(def fact-kind "DevCompileUnitResultV1")
(def fact-stage "typed")
(def blob-kind "beagle.source-facts/blob-v1")

(defn fail! [message status]
  (binding [*out* *err*]
    (println (str "beagle source-fact Store: " message)))
  (System/exit status))

(defn sha256-bytes [^bytes value]
  (str "sha256:"
       (apply str (map #(format "%02x" (bit-and (int %) 255))
                       (.digest (MessageDigest/getInstance "SHA-256") value)))))

(defn sha256 [^String value]
  (sha256-bytes (.getBytes value StandardCharsets/UTF_8)))

(defn exact-sha256? [value]
  (and (string? value) (boolean (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn blob-path [store digest]
  (.resolve (.toPath (java.io.File. (str store ".objects"))) (subs digest 7)))

(defn read-valid-blob! [store byte-count digest]
  (let [bytes (Files/readAllBytes (blob-path store digest))]
    (when-not (and (= byte-count (alength bytes)) (= digest (sha256-bytes bytes)))
      (fail! "content-addressed source-fact blob is invalid" 2))
    bytes))

(defn publish-blob! [store ^bytes bytes]
  (let [digest (sha256-bytes bytes)
        path (blob-path store digest)
        directory (.getParent path)]
    (Files/createDirectories directory (make-array FileAttribute 0))
    (if (Files/isRegularFile path (make-array java.nio.file.LinkOption 0))
      (read-valid-blob! store (alength bytes) digest)
      (let [temporary (Files/createTempFile directory ".source-facts-" ".tmp"
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
          (finally (Files/deleteIfExists temporary)))
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

(defn envelope [key context profile source-id payload]
  [fact-kind fact-stage key context profile source-id
   (alength (.getBytes ^String payload StandardCharsets/UTF_8))
   (sha256 payload) payload])

(defn source-fact-entry [store [key context profile source-id payload]]
  (let [descriptor (pr-str (publish-blob! store (.getBytes ^String payload StandardCharsets/UTF_8)))
        encoding (pr-str (envelope key context profile source-id descriptor))]
    (compile-facts/compile-fact (sha256 encoding) encoding)))

(defn hydrate-row! [store row]
  (when-not (and (vector? row) (= 4 (count row))
                 (= fact-stage (nth row 0))
                 (string? (nth row 1)) (string? (nth row 2)) (string? (nth row 3)))
    (fail! "query returned a malformed source-fact row" 2))
  (let [[stage key fact-id encoding] row
        parsed (edn/read-string encoding)]
    (compile-facts/compile-fact fact-id encoding)
    (when-not (and (vector? parsed) (= 9 (count parsed))
                   (= fact-kind (nth parsed 0)) (= stage (nth parsed 1))
                   (= key (nth parsed 2)) (= fact-id (sha256 encoding)))
      (fail! "stored source-fact descriptor is invalid" 2))
    (let [bytes (exact-blob-payload store (nth parsed 8))]
      (when-not bytes (fail! "stored source-fact descriptor is invalid" 2))
      (let [payload (String. ^bytes bytes StandardCharsets/UTF_8)
            hydrated (pr-str (envelope key (nth parsed 3) (nth parsed 4)
                                      (nth parsed 5) payload))]
        [stage key (sha256 hydrated) hydrated]))))

(defn query! [store requests]
  (let [response (compile-facts/query! store requests)]
    (when-not (and (vector? response) (= 5 (count response))
                   (= "store.dev-compile-facts/query-response-v1" (nth response 0))
                   (contains? #{"ONLINE" "COLD"} (nth response 1))
                   (vector? (nth response 4)))
      (fail! "query returned an invalid Store response" 2))
    [(nth response 0) (nth response 1) (nth response 2) (nth response 3)
     (mapv #(hydrate-row! store %) (nth response 4))]))

(defn append! [store entries]
  (let [response (compile-facts/append! store (mapv #(source-fact-entry store %) entries))]
    (when-not (and (vector? response) (= 5 (count response))
                   (= "store.dev-compile-facts/append-response-v1" (nth response 0))
                   (= "ok" (nth response 1)))
      (fail! "append returned an invalid Store response" 2))
    response))

(defn -main [command]
  (try
    (let [[tag store value] (edn/read-string (read-line))]
      (println
       (pr-str
        (case command
          "query" (do (when-not (= tag "beagle.source-facts/query-v1")
                        (fail! "query request is invalid" 2))
                      (query! store value))
          "append" (do (when-not (= tag "beagle.source-facts/append-v1")
                         (fail! "append request is invalid" 2))
                       (append! store value))
          (fail! (str "unknown command: " command) 2)))))
    (catch Exception error
      (fail! (.getMessage error) 2))))
