#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="PROJECTION-SEQUENCE-BUCKETING"
store_fixture="${BEAGLE_PROJECTION_STORE_FIXTURE:-}"

if [[ -n "$store_fixture" && ! -f "$store_fixture" ]]; then
    echo "$gate: Store fixture is not a file: $store_fixture" >&2
    exit 2
fi

bb /dev/stdin "$root/bin/beagle-build-core" "$store_fixture" <<'CLJ'
(ns projection-sequence-bucketing.gate
  (:require [clojure.string :as str])
  (:import [java.math BigInteger]
           [java.security MessageDigest]))

(def calls (atom {:subject 0 :node-order []}))

(defn fail! [label actual expected]
  (throw (ex-info (str label " actual=" (pr-str actual)
                       " expected=" (pr-str expected)) {})))

(defn assert= [label actual expected]
  (when-not (= actual expected)
    (fail! label actual expected)))

(let [slice-ns (or (find-ns 'slice) (create-ns 'slice))]
  (doseq [[symbol operation]
          {'slicefactv0-subject
           (fn [row]
             (swap! calls update :subject (fnil inc 0))
             (:subject row))
           'slicefactv0-predicate :predicate
           'slicefactv0-kind :kind
           'slicefactv0-object :object
           'node-id
           (fn [object]
             (swap! calls update :node-order conj object)
             (when (str/starts-with? object "invalid:")
               (throw (ex-info object {})))
             object)
           '->SliceFactV0
           (fn [subject predicate kind object]
             {:subject subject :predicate predicate :kind kind :object object})}]
    (intern slice-ns symbol operation))
  (alias 'slice slice-ns))

(defn id-value [value] value)

(defn load-production! [path]
  (let [source (slurp path)
        start (.indexOf source "(defn definition-sequence-names")
        end (.indexOf source "(defn rows-text" start)]
    (when (or (neg? start) (neg? end))
      (throw (ex-info "could not extract projection functions" {:path path})))
    (load-string (subs source start end))))

(load-production! (first *command-line-args*))

(defn row [subject predicate kind object]
  {:subject subject :predicate predicate :kind kind :object object})

(defn reference-replacement [rows definition-sequences selected]
  (vec
   (mapcat
    (fn [sequence-name]
      (map-indexed
       (fn [position definition-name]
         (slice/->SliceFactV0 sequence-name (str "f" position) "n" definition-name))
       (for [row rows
             :when (and (= sequence-name (slice/slicefactv0-subject row))
                        (some? (re-matches #"[fa][0-9]+"
                                           (slice/slicefactv0-predicate row)))
                        (= "n" (slice/slicefactv0-kind row))
                        (contains? selected
                                   (id-value
                                    (slice/node-id (slice/slicefactv0-object row)))))]
         (slice/slicefactv0-object row))))
    (sort definition-sequences))))

(defn reference-projected [rows selected]
  (let [sequences (definition-sequence-names rows)
        without-definitions (remove #(sequence-row? sequences %) rows)
        candidate (vec (concat without-definitions
                               (reference-replacement rows sequences selected)))
        reached (reachable-node-names candidate)]
    (filterv #(contains? reached (slice/slicefactv0-subject %)) candidate)))

(defn rows-text* [rows]
  (apply str
         (map #(str (:subject %) "\t" (:predicate %) "\t" (:kind %) "\t"
                    (:object %) "\n") rows)))

(defn sha256 [text]
  (str "sha256:"
       (format "%064x"
               (BigInteger. 1 (.digest (MessageDigest/getInstance "SHA-256")
                                        (.getBytes text "UTF-8"))))))

(defn reset-calls! []
  (reset! calls {:subject 0 :node-order []}))

(defn thrown-message [operation]
  (try
    (operation)
    nil
    (catch Exception error
      (ex-message error))))

(defn timed [operation]
  (let [started (System/nanoTime)
        value (operation)]
    {:value value :elapsed-ms (/ (- (System/nanoTime) started) 1000000.0)}))

(defn raw-rows [path]
  (mapv
   (fn [line]
     (let [[subject predicate kind object] (str/split line #"\t" 4)]
       (when-not object
         (throw (ex-info "malformed Store fixture row" {:line line})))
       (row subject predicate kind object)))
   (str/split-lines (slurp path))))

(let [names (mapv #(format "seq-%02d" %) (range 23))
      missing "seq-missing"
      definitions (mapv #(row "0" "definitions" "n" %) (conj names missing))
      interleaved
      (vec
       (mapcat
        (fn [[predicate kind object]]
          (map (fn [name]
                 (row name predicate kind (format object name)))
               (reverse names)))
        [["a8" "n" "skip-%s"]
         ["f3" "t" "non-node-%s"]
         ["f9" "n" "keep-f-%s"]
         ["a0" "n" "keep-a-%s"]
         ["metadata" "t" "text-%s"]]))
      rows (vec (concat definitions
                        [(row "0" "notice" "t" "text-distractor")]
                        interleaved))
      selected (into #{} (mapcat (fn [name]
                                   [(str "keep-f-" name) (str "keep-a-" name)])
                                 names))
      sequences (definition-sequence-names rows)
      expected-replacement
      (vec
       (mapcat
        (fn [name]
          [(row name "f0" "n" (str "keep-f-" name))
           (row name "f1" "n" (str "keep-a-" name))])
        names))]
  (assert= "fixture sequence subjects" (count sequences) 24)
  (assert= "fixture replacement rows"
           (replacement-sequence-rows rows sequences selected)
           expected-replacement)
  (assert= "fixture replacement reference"
           (replacement-sequence-rows rows sequences selected)
           (reference-replacement rows sequences selected))
  (let [reference (reference-projected rows selected)
        candidate (projected-rows rows selected)
        reference-text (rows-text* reference)
        candidate-text (rows-text* candidate)]
    (assert= "fixture projected rows" candidate reference)
    (assert= "fixture projected text" candidate-text reference-text)
    (assert= "fixture projected digest"
             (sha256 candidate-text)
             "sha256:9c6c088dd6474eef61a515fda95c99b821ba786fa6978eef446831ab9892f1c7")
    (println (str "fixture rows=" (count candidate)
                  " bytes=" (count (.getBytes candidate-text "UTF-8"))
                  " digest=" (sha256 candidate-text)))))

(let [diagnostic-rows [(row "0" "definitions" "n" "seq-00")
                       (row "0" "definitions" "n" "seq-22")
                       (row "seq-22" "f0" "n" "invalid:seq-22")
                       (row "seq-00" "a9" "n" "invalid:seq-00")]
      sequences (definition-sequence-names diagnostic-rows)
      selected #{"invalid:seq-00" "invalid:seq-22"}]
  (reset-calls!)
  (let [reference-message
        (thrown-message #(reference-replacement diagnostic-rows sequences selected))]
    (assert= "reference first diagnostic" reference-message "invalid:seq-00"))
  (reset-calls!)
  (let [candidate-message
        (thrown-message #(replacement-sequence-rows diagnostic-rows sequences selected))]
    (assert= "candidate first diagnostic" candidate-message "invalid:seq-00")
    (assert= "candidate diagnostic object order" (:node-order @calls)
             ["invalid:seq-00"])))

(let [measure
      (fn [operation sequence-count row-count]
        (let [rows (vec (repeat row-count (row "seq-00" "f0" "n" "keep")))
              sequences (set (map #(format "seq-%02d" %) (range sequence-count)))]
          (reset-calls!)
          (operation rows sequences #{"keep"})
          (:subject @calls)))
      reference-small (measure reference-replacement 23 4096)
      reference-large (measure reference-replacement 46 8192)
      candidate-small (measure replacement-sequence-rows 23 4096)
      candidate-large (measure replacement-sequence-rows 46 8192)]
  (assert= "reference 23x traversal" reference-small (* 23 4096))
  (assert= "reference 46x traversal" reference-large (* 46 8192))
  (assert= "candidate raw traversal small" candidate-small 4096)
  (assert= "candidate raw traversal large" candidate-large 8192)
  (println (str "scaling old=" reference-small "," reference-large
                " new=" candidate-small "," candidate-large)))

(when-let [path (second *command-line-args*)]
  (when-not (str/blank? path)
    (let [raw-text (slurp path)
          rows (raw-rows path)
          sequences (definition-sequence-names rows)
          selected
          (into #{}
                (for [row rows
                      :when (and (contains? sequences (:subject row))
                                 (some? (re-matches #"[fa][0-9]+" (:predicate row)))
                                 (= "n" (:kind row)))]
                  (:object row)))
          reference-run (timed #(reference-projected rows selected))
          candidate-run (timed #(projected-rows rows selected))
          reference (:value reference-run)
          candidate (:value candidate-run)
          reference-text (rows-text* reference)
          candidate-text (rows-text* candidate)]
      (assert= "Store fixture projected rows" candidate reference)
      (assert= "Store fixture projected text" candidate-text reference-text)
      (println (str "store-fixture raw-rows=" (count rows)
                    " sequences=" (count sequences)
                    " selected=" (count selected)
                    " rows=" (count candidate)
                    " bytes=" (count (.getBytes candidate-text "UTF-8"))
                    " digest=" (sha256 candidate-text)
                    " raw-digest=" (sha256 raw-text)
                    " old-ms=" (:elapsed-ms reference-run)
                    " new-ms=" (:elapsed-ms candidate-run))))))

(println "PROJECTION-SEQUENCE-BUCKETING: PASS")
CLJ
