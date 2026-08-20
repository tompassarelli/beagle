;; FRI2 cache binding and occurrence-history round trip.
;;   env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp out tests/fri_cache_v2_test.clj
(require '[fri :as fri]
         '[store.store :as store]
         '[store.types :as t]
         '[clojure.string :as str])

(defn error-type [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error (:type (ex-data error)))))

(def path "/tmp/store-fri-cache-v2.fri")
(def path-two "/tmp/store-fri-cache-v2-second.fri")
(def corrupt-path "/tmp/store-fri-cache-v2-corrupt.fri")
(def fingerprint (apply str (repeat 64 "a")))
(def cache-source (fri/source-binding "fri-space" fingerprint 4096))
(def proposition
  (t/triple (t/triple "Alice" :account "primary")
            (t/triple :slot "email" 2)
            (t/triple "alice@example.com" :observed-at (t/instant 1785561000 7))))
(def ctx (store/new-term-store "fri-space"))

;; Duplicate assertions are separate occurrences even though they share one
;; private structural triple handle.
(store/commit-transaction!
 ctx [(store/assert-operation proposition)
      (store/assert-operation proposition)])
(store/commit-transaction! ctx [(store/retract-operation proposition)])
(def dump (store/dump-term-store ctx))

(fri/write-fri! dump path cache-source)
(fri/write-fri! dump path-two cache-source)
(def image (fri/open-fri! path cache-source))
(def restored (store/new-term-store "fri-space"))
(fri/restore-store! image restored)

(def bytes-one (java.nio.file.Files/readAllBytes (.toPath (java.io.File. path))))
(def bytes-two (java.nio.file.Files/readAllBytes (.toPath (java.io.File. path-two))))
(def stale-source (fri/source-binding "fri-space" (apply str (repeat 64 "b")) 4096))
(def wrong-space (fri/source-binding "other-space" fingerprint 4096))
(def stale-position (fri/source-binding "fri-space" fingerprint 4095))
(def runtime-source
  (str/join "\n" (map slurp ["fri.clj" "rotations.clj"
                              "src/fri.bclj" "src/fri_port.bclj"
                              "out/fri.clj" "out/fri_port.clj"])))
(def decode-term-v1! (deref (ns-resolve 'fri-port 'decode-term-v1!)))
(def malformed-length (byte-array [1 5 0 0 0 65]))
(def malformed-tag (byte-array [-1]))
(def excessive-depth (byte-array (repeat 258 7)))
(def trailing-term-byte (byte-array [4 0]))
(java.nio.file.Files/copy
 (.toPath (java.io.File. path))
 (.toPath (java.io.File. corrupt-path))
 (into-array java.nio.file.CopyOption
             [java.nio.file.StandardCopyOption/REPLACE_EXISTING]))
(with-open [file (java.io.RandomAccessFile. corrupt-path "rw")]
  (let [position (dec (.length file))]
    (.seek file position)
    (let [value (.read file)]
      (.seek file position)
      (.write file (bit-xor value 1)))))

(def checks
  [["FRI2 magic/version are the only runtime format"
    (and (= "STOREFRI2" fri/MAGIC)
         (= 2 fri/FMT)
         (= [2 0 0 0]
            (mapv #(bit-and (int %) 255) (subvec (vec bytes-one) 8 12))))]
   ["TermCodecV1 rejects a truncated sized value"
    (= :invalid-fri-cache (error-type #(decode-term-v1! malformed-length)))]
   ["TermCodecV1 rejects an unknown tag"
    (= :invalid-fri-cache (error-type #(decode-term-v1! malformed-tag)))]
   ["TermCodecV1 rejects recursion beyond the STORELOG depth bound"
    (= :invalid-fri-cache (error-type #(decode-term-v1! excessive-depth)))]
   ["TermCodecV1 rejects trailing bytes inside a recordd row"
    (= :invalid-fri-cache (error-type #(decode-term-v1! trailing-term-byte)))]
   ["cache is deterministic for one dump and source prefix"
    (java.util.Arrays/equals bytes-one bytes-two)]
   ["cache binds immutable SpaceId and canonical-log prefix"
    (and (= "fri-space" (fri/space-id image))
         (= fingerprint (fri/source-fingerprint image))
         (= 4096 (fri/source-position image)))]
   ["TermStore rows restore exactly without exposing private handles"
    (= dump (store/dump-term-store restored))]
   ["duplicate occurrences survive while one retraction withdraws only the latest"
    (let [withdrawal (first (fri/withdrawals image))]
      (and (= 3 (fri/operation-count image))
           (= 3 (count (fri/occurrences image)))
           (= 1 (count (fri/withdrawals image)))
           (= (t/occurrence-coordinate
               (t/transaction-coordinate "fri-space" 2) 0)
              (t/operationoccurrence-coordinate
               (t/withdrawal-retraction withdrawal)))
           (= (t/occurrence-coordinate
               (t/transaction-coordinate "fri-space" 1) 1)
              (t/operationoccurrence-coordinate
               (t/withdrawal-assertion withdrawal)))
           (= 1 (count (fri/live-occurrences image)))
           (= [proposition] (fri/live-propositions image))))]
   ["nested recursive Triple and typed Instant survive cache decode"
    (= proposition (first (fri/live-propositions image)))]
   ["t1/t2/t3 indexes return recursive structural Triples"
    (and (= [proposition]
            (fri/by-t1 image (t/triple "Alice" :account "primary")))
         (= [(t/triple "Alice" :account "primary")]
            (fri/by-t2 image :account))
         (= [(t/triple "alice@example.com" :observed-at (t/instant 1785561000 7))]
            (fri/by-t3 image (t/instant 1785561000 7))))]
   ["pair indexes are slot-addressed without subject/predicate/object roles"
    (and (= [proposition]
            (fri/by-t12 image
                           (t/triple "Alice" :account "primary")
                           (t/triple :slot "email" 2)))
         (= [proposition]
            (fri/by-t23 image
                           (t/triple :slot "email" 2)
                           (t/triple "alice@example.com" :observed-at
                                     (t/instant 1785561000 7)))))]
   ["as-of projection preserves duplicate assertions before later withdrawal"
    (and (= [proposition proposition]
            (fri/live-propositions-as-of image 1))
         (= [proposition]
            (fri/live-propositions-as-of image 2)))]
   ["stale source fingerprint is rejected"
    (= :cache-source-mismatch (error-type #(fri/open-fri! path stale-source)))]
   ["stale source valid-byte position is rejected"
    (= :cache-source-mismatch (error-type #(fri/open-fri! path stale-position)))]
   ["wrong SpaceId is rejected"
    (= :cache-space-mismatch (error-type #(fri/open-fri! path wrong-space)))]
   ["payload corruption is rejected by checksum"
    (= :invalid-fri-cache (error-type #(fri/open-fri! corrupt-path cache-source)))]
   ["FRI runtime has no EDN parser or printer in its persistence spine"
    (nil? (re-find #"clojure\\.edn|pr-str|read-string" runtime-source))]] )

(fri/close-fri! image)
(doseq [p [path path-two corrupt-path]] (.delete (java.io.File. p)))

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\nFRI2 cache round trip:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\nFRI2 cache round trip:" (count failures) "FAILED")
      (System/exit 1))))
