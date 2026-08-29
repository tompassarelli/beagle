(ns store.branch
  (:require [clojure.string :as str])
  (:import [java.io ByteArrayOutputStream]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]
           [java.util.zip CRC32]))

(def ^String ref-format "revision-ref/v1")

(def ^String fork-marker-format "branch-fork/v1")

(def ^String reseal-marker-format "branch-reseal/v1")

(def ^String branch-revision-format "branch-revision/v2")

(def ^String default-branch "main")

(def max-branch-name-length 64)

(def reseal-chain-length 64)

(defrecord SegmentRecord [sha256 start-sequence end-sequence byte-count])

(defn segmentrecord-sha256 [r] (:sha256 r))

(defn segmentrecord-start-sequence [r] (:start-sequence r))

(defn segmentrecord-end-sequence [r] (:end-sequence r))

(defn segmentrecord-byte-count [r] (:byte-count r))

(defrecord RefDocument [space-id segments])

(defn refdocument-space-id [r] (:space-id r))

(defn refdocument-segments [r] (:segments r))

(defrecord BranchRevision [space-id history-sha256 sequence identity])

(defn branchrevision-space-id [r] (:space-id r))

(defn branchrevision-history-sha256 [r] (:history-sha256 r))

(defn branchrevision-sequence [r] (:sequence r))

(defn branchrevision-identity [r] (:identity r))

(defrecord ChainMember [start-sequence end-sequence byte-count continuation space-id torn])

(defn chainmember-start-sequence [r] (:start-sequence r))

(defn chainmember-end-sequence [r] (:end-sequence r))

(defn chainmember-byte-count [r] (:byte-count r))

(defn chainmember-continuation [r] (:continuation r))

(defn chainmember-space-id [r] (:space-id r))

(defn chainmember-torn [r] (:torn r))

(defrecord ForkPlan [document sealed fork-sequence])

(defn forkplan-document [r] (:document r))

(defn forkplan-sealed [r] (:sealed r))

(defn forkplan-fork-sequence [r] (:fork-sequence r))

(defrecord ForkMarker [parent child segment])

(defn forkmarker-parent [r] (:parent r))

(defn forkmarker-child [r] (:child r))

(defn forkmarker-segment [r] (:segment r))

(defrecord ResealMarker [branch segment ref-identity])

(defn resealmarker-branch [r] (:branch r))

(defn resealmarker-segment [r] (:segment r))

(defn resealmarker-ref-identity [r] (:ref-identity r))

(defn- fail [^String message code]
  (throw (ex-info message {:type code :store-log/code code})))

(defn ^Boolean valid-segment-name? [^String value]
  (some? (re-matches #"[0-9a-f]{64}" value)))

(defn ^Boolean valid-branch-name? [^String value]
  (and (pos? (count value)) (<= (count value) max-branch-name-length) (some? (re-matches #"[A-Za-z0-9][A-Za-z0-9._-]*" value)) (not (str/includes? value ".."))))

(defn ^String require-branch-name! [^String value]
  (if (valid-branch-name? value) value (fail (str "branch name is not a usable ref file name: " value) :invalid-branch-name)))

(defn ^String segments-directory [^String store-path]
  (str store-path ".segments"))

(defn ^String refs-directory [^String store-path]
  (str store-path ".refs"))

(defn ^String branches-directory [^String store-path]
  (str store-path ".branches"))

(defn ^String segment-path [^String store-path ^String sha256]
  (if (valid-segment-name? sha256) (str (segments-directory store-path) "/" sha256) (fail (str "segment name is not a SHA-256 hex digest: " sha256) :invalid-segment-name)))

(defn ^String ref-path! [^String store-path ^String branch]
  (str (refs-directory store-path) "/" (require-branch-name! branch)))

(defn ^String branch-tail-path! [^String store-path ^String branch]
  (if (= (require-branch-name! branch) default-branch) store-path (str (branches-directory store-path) "/" branch)))

(defn ^String snapshot-path [^String tail-path]
  (str tail-path ".snapshot"))

(defn- crc32-of [^String text]
  (let [digest (CRC32.)]
  (.update digest (.getBytes text StandardCharsets/UTF_8))
  (long (.getValue digest))))

(defn- revision-write-u8! [out value]
  (do
  (.write out (int (bit-and value 255)))
  nil))

(defn- revision-write-u32-le! [out value]
  (do
  (doseq [position (range 4)]
  (revision-write-u8! out (unsigned-bit-shift-right value (* position 8))))
  nil))

(defn- revision-write-i64-le! [out value]
  (do
  (doseq [position (range 8)]
  (revision-write-u8! out (unsigned-bit-shift-right value (* position 8))))
  nil))

(defn- revision-write-text! [out ^String value]
  (let [bytes (.getBytes value StandardCharsets/UTF_8)]
  (revision-write-u32-le! out (alength bytes))
  (.write out bytes)
  nil))

(defn- ^String sha256-hex [bytes]
  (apply str (mapv (fn [value] (format "%02x" (bit-and (int value) 255))) (vec (.digest (MessageDigest/getInstance "SHA-256") bytes)))))

(defn- branch-revision-preimage! [^String space-id ^String history-sha256 sequence]
  (let [^ByteArrayOutputStream out (ByteArrayOutputStream.)]
  (revision-write-text! out branch-revision-format)
  (revision-write-text! out space-id)
  (revision-write-text! out history-sha256)
  (revision-write-i64-le! out sequence)
  (.toByteArray out)))

(defn ^BranchRevision branch-revision! [^String space-id ^String history-sha256 sequence]
  (cond
  (zero? (count space-id)) (fail "branch revision SpaceId must be nonempty" :invalid-branch-revision)
  (not (valid-segment-name? history-sha256)) (fail "branch revision history is not a SHA-256 hex digest" :invalid-branch-revision)
  (neg? sequence) (fail "branch revision sequence must not be negative" :invalid-branch-revision)
  :else (let [^String identity (str "sha256:" (sha256-hex (branch-revision-preimage! space-id history-sha256 sequence)))]
  (->BranchRevision space-id history-sha256 sequence identity))))

(defn- ^String segment-line [^SegmentRecord segment]
  (str "segment " (segmentrecord-sha256 segment) " " (segmentrecord-start-sequence segment) " " (segmentrecord-end-sequence segment) " " (segmentrecord-byte-count segment) "\n"))

(defn ^String print-ref [^RefDocument document]
  (let [^String body (str ref-format "\n" "space " (refdocument-space-id document) "\n" (apply str (mapv (fn [^SegmentRecord segment] (segment-line segment)) (refdocument-segments document))))]
  (str body "crc " (format "%08x" (crc32-of body)) "\n")))

(defn ^String ref-identity [^RefDocument document]
  (str "sha256:" (sha256-hex (.getBytes (print-ref document) StandardCharsets/UTF_8))))

(defn- parse-count [^String value ^String label]
  (if (some? (re-matches #"(?:0|[1-9][0-9]{0,17})" value)) (Long/parseLong value) (fail (str "branch ref " label " is not a decimal count: " value) :invalid-branch-ref)))

(defn- ^SegmentRecord parse-segment-line [^String line known]
  (let [fields (vec (str/split line #" "))]
  (if (not= 5 (count fields)) (fail (str "branch ref segment line is malformed: " line) :invalid-branch-ref) (let [^String sha256 (nth fields 1)]
  (cond
  (not (valid-segment-name? sha256)) (fail (str "branch ref segment name is not a SHA-256 hex digest: " sha256) :invalid-branch-ref)
  (contains? known sha256) (fail (str "branch ref lists the same segment twice: " sha256) :invalid-branch-ref)
  :else (let [start (parse-count (nth fields 2) "segment start sequence")
   end (parse-count (nth fields 3) "segment end sequence")]
  (if (or (< end start) (not= (zero? start) (zero? end))) (fail (str "branch ref segment has an invalid transaction range: " sha256) :invalid-branch-ref) (->SegmentRecord sha256 start end (parse-count (nth fields 4) "segment byte count")))))))))

(defn ^RefDocument parse-ref [^String text]
  (let [lines (vec (str/split-lines text))]
  (cond
  (< (count lines) 3) (fail "branch ref is missing its format, space, or CRC line" :invalid-branch-ref)
  (not= ref-format (nth lines 0)) (fail (str "branch ref format is unsupported: " (nth lines 0)) :unsupported-branch-ref-version)
  (not (str/starts-with? (nth lines 1) "space ")) (fail "branch ref does not name its SpaceId" :invalid-branch-ref)
  (not (str/starts-with? (nth lines (dec (count lines))) "crc ")) (fail "branch ref does not end with its CRC line" :invalid-branch-ref)
  :else (let [^String space-id (subs (nth lines 1) 6)
   ^String body (apply str (mapv (fn [^String line] (str line "\n")) (subvec lines 0 (dec (count lines)))))
   ^String stored (subs (nth lines (dec (count lines))) 4)]
  (cond
  (zero? (count space-id)) (fail "branch ref SpaceId must be nonempty" :invalid-branch-ref)
  (not= stored (format "%08x" (crc32-of body))) (fail "branch ref CRC does not match" :invalid-branch-ref)
  :else (let [segments (loop [index 2
   known #{}
   acc []]
  (if (>= index (dec (count lines))) acc (let [^String line (nth lines index)]
  (if (not (str/starts-with? line "segment ")) (fail (str "branch ref contains an unknown line: " line) :invalid-branch-ref) (let [^SegmentRecord segment (parse-segment-line line known)]
  (recur (inc index) (conj known (segmentrecord-sha256 segment)) (conj acc segment)))))))]
  (->RefDocument space-id segments)))))))

(defn ^RefDocument empty-ref [^String space-id]
  (->RefDocument space-id []))

(defn chain-end-sequence [^RefDocument document]
  (let [segments (refdocument-segments document)]
  (loop [index (dec (count segments))]
  (if (neg? index) 0 (let [end (segmentrecord-end-sequence (nth segments index))]
  (if (pos? end) end (recur (dec index))))))))

(defn ^String print-fork-marker [^ForkMarker marker]
  (let [^String body (str fork-marker-format "\n" "parent " (forkmarker-parent marker) "\n" "child " (forkmarker-child marker) "\n" "segment " (forkmarker-segment marker) "\n")]
  (str body "crc " (format "%08x" (crc32-of body)) "\n")))

(defn ^ForkMarker parse-fork-marker [^String text]
  (let [lines (vec (str/split-lines text))]
  (cond
  (not= 5 (count lines)) (fail "fork marker does not carry its three fields and CRC" :invalid-fork-marker)
  (not= fork-marker-format (nth lines 0)) (fail (str "fork marker format is unsupported: " (nth lines 0)) :unsupported-fork-marker-version)
  (not (and (str/starts-with? (nth lines 1) "parent ") (str/starts-with? (nth lines 2) "child ") (str/starts-with? (nth lines 3) "segment "))) (fail "fork marker does not name its parent, child, and segment" :invalid-fork-marker)
  :else (let [^String body (apply str (mapv (fn [^String line] (str line "\n")) (subvec lines 0 4)))
   ^String parent (subs (nth lines 1) 7)
   ^String child (subs (nth lines 2) 6)
   ^String segment (subs (nth lines 3) 8)]
  (cond
  (not= (nth lines 4) (str "crc " (format "%08x" (crc32-of body)))) (fail "fork marker CRC does not match" :invalid-fork-marker)
  (not (and (valid-branch-name? parent) (valid-branch-name? child) (not= parent child))) (fail "fork marker does not name two usable branches" :invalid-fork-marker)
  (not (valid-segment-name? segment)) (fail "fork marker segment is not a SHA-256 hex digest" :invalid-fork-marker)
  :else (->ForkMarker parent child segment))))))

(defn ^String print-reseal-marker [^ResealMarker marker]
  (let [^String body (str reseal-marker-format "\n" "branch " (resealmarker-branch marker) "\n" "segment " (resealmarker-segment marker) "\n" "ref " (resealmarker-ref-identity marker) "\n")]
  (str body "crc " (format "%08x" (crc32-of body)) "\n")))

(defn ^ResealMarker parse-reseal-marker [^String text]
  (let [lines (vec (str/split-lines text))]
  (cond
  (not= 5 (count lines)) (fail "reseal marker does not carry its three fields and CRC" :invalid-reseal-marker)
  (not= reseal-marker-format (nth lines 0)) (fail (str "reseal marker format is unsupported: " (nth lines 0)) :unsupported-reseal-marker-version)
  (not (and (str/starts-with? (nth lines 1) "branch ") (str/starts-with? (nth lines 2) "segment ") (str/starts-with? (nth lines 3) "ref "))) (fail "reseal marker does not name its branch, segment, and ref" :invalid-reseal-marker)
  :else (let [^String body (apply str (mapv (fn [^String line] (str line "\n")) (subvec lines 0 4)))
   ^String branch (subs (nth lines 1) 7)
   ^String segment (subs (nth lines 2) 8)
   ^String identity (subs (nth lines 3) 4)]
  (cond
  (not= (nth lines 4) (str "crc " (format "%08x" (crc32-of body)))) (fail "reseal marker CRC does not match" :invalid-reseal-marker)
  (not (valid-branch-name? branch)) (fail "reseal marker does not name a usable branch" :invalid-reseal-marker)
  (not (valid-segment-name? segment)) (fail "reseal marker segment is not a SHA-256 hex digest" :invalid-reseal-marker)
  (not (some? (re-matches #"sha256:[0-9a-f]{64}" identity))) (fail "reseal marker ref identity is not a SHA-256 digest" :invalid-reseal-marker)
  :else (->ResealMarker branch segment identity))))))

(defn ^ForkPlan fork-plan [^RefDocument parent ^SegmentRecord sealed fork-sequence]
  (let [segments (refdocument-segments parent)]
  (cond
  (not (valid-segment-name? (segmentrecord-sha256 sealed))) (fail "sealed segment name is not a SHA-256 hex digest" :invalid-segment-name)
  (some (fn [^SegmentRecord segment] (= (segmentrecord-sha256 segment) (segmentrecord-sha256 sealed))) segments) (fail "sealed segment is already named by the parent chain" :segment-already-sealed)
  (neg? fork-sequence) (fail "fork sequence must not be negative" :invalid-fork-sequence)
  :else (->ForkPlan (->RefDocument (refdocument-space-id parent) (conj segments sealed)) sealed fork-sequence))))
