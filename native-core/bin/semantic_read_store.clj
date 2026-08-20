(ns semantic-read-store
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [source-fact-store :as blobs]
            [store.dev-compile-facts :as compile-facts])
  (:import [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

(def fact-kind "DevCompileUnitResultV1")
(def result-kind "SemanticReadClosureResultV1")
(def result-stage "typed")
(def result-profile "semantic-read-closure-v1")
(def query-kind "beagle.semantic-read-closure/query-v1")

(defn sha256 [^String value]
  (str "sha256:"
       (apply str
              (map #(format "%02x" (bit-and (int %) 255))
                   (.digest (MessageDigest/getInstance "SHA-256")
                            (.getBytes value StandardCharsets/UTF_8))))))

(defn- exact-digest? [value]
  (and (string? value)
       (boolean (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- source-rows [source-facts]
  (mapv
   (fn [line]
     (let [fields (str/split line #"\t" -1)]
       (when-not (= 4 (count fields))
         (throw (ex-info "semantic-read cache received malformed source facts"
                         {:line line})))
       fields))
   (remove str/blank? (str/split-lines source-facts))))

(defn- sole-text [by-subject subject predicate]
  (let [values (get-in by-subject [subject predicate] [])]
    (when-not (= 1 (count values))
      (throw (ex-info "semantic-read cache needs one module identity field"
                      {:subject subject :predicate predicate :values values})))
    (first values)))

(defn- module-identities [rows]
  (let [by-subject
        (reduce
         (fn [found [subject predicate kind object]]
           (if (= "t" kind)
             (update-in found [subject predicate] (fnil conj []) object)
             found))
         {}
         rows)
        roots
        (sort
         (for [[subject predicates] by-subject
               :when (= ["module-root"] (get predicates "form-kind"))]
           subject))]
    (mapv
     (fn [subject]
       (let [relative-path (sole-text by-subject subject "relative-path")
             source-digest (sole-text by-subject subject "source-sha256")
             projection-digest
             (sole-text by-subject subject "checked-projection-sha256")
             interface-digest
             (sole-text by-subject subject "interface-sha256")]
         (when-not (every? exact-digest?
                           [source-digest projection-digest interface-digest])
           (throw (ex-info "semantic-read cache received malformed module digests"
                           {:relative-path relative-path})))
         {:relative-path relative-path
          :source-digest source-digest
          :projection-digest projection-digest
          :interface-digest interface-digest}))
     roots)))

(defn request
  [source-facts compiler-projection-id rules-id entries strict-entry-abi?]
  (when-not (and (exact-digest? compiler-projection-id)
                 (exact-digest? rules-id))
    (throw (ex-info "semantic-read cache identities must be SHA-256 digests" {})))
  (let [source-facts-id (sha256 source-facts)
        modules (sort-by :relative-path (module-identities (source-rows source-facts)))
        base [[0 "query/kind" "query" 0 query-kind]
              [1 "query/source-facts" "query" 0 source-facts-id]
              [2 "query/compiler-projection" "query" 0 compiler-projection-id]
              [3 "query/rules" "query" 0 rules-id]
              [4 "query/strict-entry-abi" "query" 0
               (if strict-entry-abi? "true" "false")]]
        module-facts
        (mapcat
         (fn [position {:keys [relative-path source-digest projection-digest
                               interface-digest]}]
           (let [slot (+ 5 (* position 4))]
             [[slot "query/module" relative-path 0 relative-path]
              [(inc slot) "query/source-shard" relative-path 0 source-digest]
              [(+ slot 2) "query/checked-projection" relative-path 0
               projection-digest]
              [(+ slot 3) "query/interface" relative-path 0 interface-digest]]))
         (range)
         modules)
        entry-offset (+ 5 (* 4 (count modules)))
        entry-facts
        (map-indexed
         (fn [position entry]
           [(+ entry-offset position) "query/entry" "query" position entry])
         entries)
        facts (vec (concat base module-facts entry-facts))]
    {:key (sha256 (pr-str facts))
     :context rules-id
     :unit source-facts-id
     :facts facts}))

(defn- envelope [request wrapper]
  [fact-kind result-stage (:key request) (:context request) result-profile
   (:unit request)
   (alength (.getBytes ^String wrapper StandardCharsets/UTF_8))
   (sha256 wrapper) wrapper])

(defn- parse-result [store request row]
  (try
    (when (and (vector? row) (= 4 (count row))
               (= result-stage (nth row 0))
               (= (:key request) (nth row 1)))
      (let [[_ _ fact-id encoding] row
            value (compile-facts/compile-fact fact-id encoding)
            parsed (edn/read-string encoding)]
        (when (and value (vector? parsed) (= 9 (count parsed))
                   (= fact-kind (nth parsed 0))
                   (= result-stage (nth parsed 1))
                   (= (:key request) (nth parsed 2))
                   (= (:context request) (nth parsed 3))
                   (= result-profile (nth parsed 4))
                   (= (:unit request) (nth parsed 5))
                   (= fact-id (sha256 encoding)))
          (let [wrapper-text (nth parsed 8)
                wrapper (edn/read-string wrapper-text)]
            (when (and (= wrapper-text (pr-str wrapper))
                       (vector? wrapper) (= 5 (count wrapper))
                       (= result-kind (nth wrapper 0))
                       (= (:facts request) (nth wrapper 1)))
              (let [bytes
                    (blobs/exact-blob-payload store (pr-str (nth wrapper 4)))]
                (when (and bytes (= (nth wrapper 2) (alength ^bytes bytes)))
                  (let [payload (String. ^bytes bytes StandardCharsets/UTF_8)]
                    (when (= (nth wrapper 3) (sha256 payload)) payload)))))))))
    (catch Exception _ nil)))

(defn query! [store request]
  (let [response
        (compile-facts/query!
         store
         [[result-stage (:key request) (:context request) result-profile
           (:unit request)]])
        candidates
        (filterv #(and (= result-stage (nth % 0 nil))
                       (= (:key request) (nth % 1 nil)))
                 (nth response 4 []))]
    (when (= 1 (count candidates))
      (parse-result store request (first candidates)))))

(defn append! [store request payload]
  (let [descriptor
        (blobs/publish-blob!
         store (.getBytes ^String payload StandardCharsets/UTF_8))
        wrapper
        (pr-str [result-kind (:facts request)
                 (alength (.getBytes ^String payload StandardCharsets/UTF_8))
                 (sha256 payload) descriptor])
        encoding (pr-str (envelope request wrapper))]
    (compile-facts/append!
     store [(compile-facts/compile-fact (sha256 encoding) encoding)])))
