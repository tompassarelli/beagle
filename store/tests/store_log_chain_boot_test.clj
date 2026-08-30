;; Folding a sealed chain plus its tail must produce exactly the store the same
;; records produce in one file, and must refuse every chain it cannot vouch for
;; rather than fold a shorter history that still looks well formed.
;; Run from the repository root: bb -cp out tests/store-log_chain_boot_test.clj
(require '[store.branch :as branch]
         '[store.store :as store]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(defn error-code [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error
      (or (:store/code (ex-data error)) (:type (ex-data error))))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-store-log-chain-boot-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(defn- store-path [name] (.getPath (java.io.File. scratch name)))

(defn- read-all ^bytes [path]
  (java.nio.file.Files/readAllBytes (.toPath (java.io.File. (str path)))))

(defn- write-bytes! [path ^bytes content]
  (java.nio.file.Files/write
   (.toPath (java.io.File. (str path))) content
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))

(defn- image [db] (store/dump-term-store (database/database-store! db)))

(def space "store-log-chain-boot-space")

;; The commit script both arms replay, in order.
(def script
  [(fn [db] (database/assert! db (t/triple "Alice" :email "a@example.com") {}))
   (fn [db] (database/commit! db {:actor "batcher"
                                  :operations
                                  [{:action :assert
                                    :proposition (t/triple "A" :count 1)}
                                   {:action :assert
                                    :proposition (t/triple "B" :count 2)}]}))
   (fn [db] (database/assert!
             db (t/triple (t/triple "Dana" :saw "Alice")
                          :at (t/instant 1785560000 123456789)) {}))
   (fn [db] (database/assert! db (t/triple "Task" :status "draft") {}))
   (fn [db] (database/retract! db (t/triple "A" :count 1) {:actor "Tom"}))
   (fn [db] (database/assert! db (t/triple "Task" :owner "Tom") {}))])

;; Arm 1 — one file, no fork.
(def flat-log (store-path "flat.storelog"))
(database/create-triple-log! flat-log space)
(def flat (database/open-database! flat-log space))
(doseq [step script] (step flat))
(def flat-image (image flat))

;; Arm 2 — the same script, forked after the third commit.
(def chained-log (store-path "chained.storelog"))
(database/create-triple-log! chained-log space)
(def head (database/open-database! chained-log space))
(doseq [step (take 3 script)] (step head))
(database/fork-store! chained-log "lane")
(def lane (database/open-branch! chained-log "lane" space))
(doseq [step (drop 3 script)] (step lane))

(def lane-tail (branch/branch-tail-path! chained-log "lane"))
(def lane-ref (database/read-branch-ref! chained-log "lane"))
(def sealed-path
  (branch/segment-path
   chained-log
   (branch/segmentrecord-sha256 (first (branch/refdocument-segments lane-ref)))))

(println "STORELOG chain boot:")
(println (str "  flat log " (alength (read-all flat-log)) " bytes; chain "
              (count (branch/refdocument-segments lane-ref))
              " segment + tail " (alength (read-all lane-tail)) " bytes"))

(check! "a chain fold equals the single-file fold of the same records"
        (= flat-image (image (database/open-branch! chained-log "lane" space))))
(check! "the chain and the flat log agree on their transaction sequences"
        (= (mapv :tx-seq (:records (database/read-triple-log! flat-log)))
           (into (mapv :tx-seq (:records (database/read-triple-log!
                                         sealed-path true)))
                 (mapv :tx-seq (:records (database/read-triple-log!
                                         lane-tail true))))))
(check! "a continuation tail opened without its ref is refused"
        (= :unsupported-log-version
           (error-code #(database/open-database! lane-tail space))))
(check! "opening an unknown branch is refused"
        (= :branch-missing
           (error-code #(database/open-branch! chained-log "absent" space))))
(check! "a branch whose SpaceId is not the caller's is refused"
        (= :space-mismatch
           (error-code
            #(database/open-branch! chained-log "lane" "another-space"))))

;; Every negative case below gets its own store so one break never masks another.
(defn- forked-store! [name]
  (let [log (store-path name)]
    (database/create-triple-log! log space)
    (let [db (database/open-database! log space)]
      (doseq [step (take 3 script)] (step db)))
    (database/fork-store! log "lane")
    (let [db (database/open-branch! log "lane" space)]
      (doseq [step (drop 3 script)] (step db)))
    log))

(defn- sealed-of [log]
  (branch/segment-path
   log
   (branch/segmentrecord-sha256
    (first (branch/refdocument-segments
            (database/read-branch-ref! log "lane"))))))

(def missing-log (forked-store! "missing.storelog"))
(java.nio.file.Files/delete (.toPath (java.io.File. (sealed-of missing-log))))
(check! "a missing segment fails the boot closed"
        (= :triple-log-missing
           (error-code #(database/open-branch! missing-log "lane" space))))

(def short-log (forked-store! "short.storelog"))
(let [content (read-all (sealed-of short-log))]
  (write-bytes! (sealed-of short-log)
                (java.util.Arrays/copyOfRange content 0 (dec (alength content)))))
(check! "a truncated segment fails the boot closed"
        (= :invalid-branch-chain
           (error-code #(database/open-branch! short-log "lane" space))))

(def flipped-log (forked-store! "flipped.storelog"))
(let [content (read-all (sealed-of flipped-log))
      copy (java.util.Arrays/copyOf content (alength content))
      offset (dec (alength content))]
  (aset-byte copy offset
             (unchecked-byte (bit-xor (bit-and 255 (aget copy offset)) 1)))
  (write-bytes! (sealed-of flipped-log) copy))
(check! "a corrupted segment byte fails the boot closed"
        (= :corrupt-triple-log
           (error-code #(database/open-branch! flipped-log "lane" space))))

(def alien-log (forked-store! "alien.storelog"))
(let [other (store-path "other.storelog")]
  (database/create-triple-log! other "another-space")
  (let [db (database/open-database! other "another-space")]
    (doseq [step (take 3 script)] (step db)))
  (write-bytes! (sealed-of alien-log) (read-all other)))
(check! "a segment from another SpaceId fails the boot closed"
        (= :invalid-branch-chain
           (error-code #(database/open-branch! alien-log "lane" space))))

;; A ref that skips a segment leaves a sequence hole at the boundary the fold
;; would otherwise cross without noticing.
(def hole-log (forked-store! "hole.storelog"))
(database/fork-store! hole-log "lane" "lane-2")
(let [db (database/open-branch! hole-log "lane-2" space)]
  (database/assert! db (t/triple "after" :second-fork 1) {}))
(database/fork-store! hole-log "lane-2" "lane-3")
(def full-chain
  (branch/refdocument-segments (database/read-branch-ref! hole-log "lane-3")))
(check! "the three-fork fixture really has three sealed segments"
        (= 3 (count full-chain)))
(java.nio.file.Files/write
 (.toPath (java.io.File. (branch/ref-path! hole-log "lane-3")))
 (.getBytes (branch/print-ref
             (branch/->RefDocument space [(nth full-chain 0)
                                          (nth full-chain 2)]))
            java.nio.charset.StandardCharsets/UTF_8)
 (into-array java.nio.file.OpenOption
             [java.nio.file.StandardOpenOption/CREATE
              java.nio.file.StandardOpenOption/WRITE
              java.nio.file.StandardOpenOption/TRUNCATE_EXISTING]))
(check! "a sequence discontinuity between two segments fails the boot closed"
        (= :invalid-branch-chain
           (error-code #(database/open-branch! hole-log "lane-3" space))))

(def gap-log (forked-store! "gap.storelog"))
(database/fork-store! gap-log "lane" "lane-2")
(let [db (database/open-branch! gap-log "lane-2" space)]
  (database/assert! db (t/triple "after" :second-fork 1) {}))
(def gap-chain
  (branch/refdocument-segments (database/read-branch-ref! gap-log "lane-2")))
(java.nio.file.Files/write
 (.toPath (java.io.File. (branch/ref-path! gap-log "lane-2")))
 (.getBytes (branch/print-ref
             (branch/->RefDocument space [(first gap-chain)]))
            java.nio.charset.StandardCharsets/UTF_8)
 (into-array java.nio.file.OpenOption
             [java.nio.file.StandardOpenOption/CREATE
              java.nio.file.StandardOpenOption/WRITE
              java.nio.file.StandardOpenOption/TRUNCATE_EXISTING]))
(check! "a tail that does not continue the sealed chain fails the boot closed"
        (= :invalid-branch-chain
           (error-code #(database/open-branch! gap-log "lane-2" space))))

;; Every byte cut of the tail must fold to an exact committed image or fail
;; loudly; a third image across the segment boundary is a durability defect.
(def sweep-log (store-path "sweep.storelog"))
(database/create-triple-log! sweep-log space)
(let [db (database/open-database! sweep-log space)]
  (doseq [step (take 3 script)] (step db)))
(database/fork-store! sweep-log "lane")
(def sweep-tail (branch/branch-tail-path! sweep-log "lane"))
(def sweep-images
  (let [db (database/open-branch! sweep-log "lane" space)]
    (into [(image db)]
          (mapv (fn [step] (step db) (image db)) (drop 3 script)))))
(def sweep-boundaries
  (let [parsed (database/read-triple-log! sweep-tail true)]
    (into [(long (:header-bytes parsed))]
          (sort (map long (vals (:prefix-ends parsed)))))))
(def sweep-bytes (read-all sweep-tail))

(defn- image-at [cut]
  (loop [index 0 result 0]
    (if (>= index (count sweep-boundaries))
      result
      (recur (inc index)
             (if (<= (nth sweep-boundaries index) cut) index result)))))

(def sweep
  (reduce
   (fn [acc cut]
     (write-bytes! sweep-tail (java.util.Arrays/copyOfRange sweep-bytes 0 cut))
     (let [expected (nth sweep-images (image-at cut))
           outcome
           (try
             (let [db (database/open-branch! sweep-log "lane" space)]
               (if (= expected (image db)) :exact :divergent))
             (catch clojure.lang.ExceptionInfo error
               (or (:store/code (ex-data error)) :unknown))
             (catch Throwable error :non-store-throwable))]
       (update acc outcome (fnil conj []) cut)))
   {} (range (long (:header-bytes (database/read-triple-log! sweep-tail true)))
             (inc (alength sweep-bytes)))))
(write-bytes! sweep-tail sweep-bytes)

(println (str "  tail sweep: " (alength sweep-bytes) " bytes, "
              (count sweep-boundaries) " record boundaries, outcomes "
              (pr-str (into {} (map (fn [[k v]] [k (count v)]) sweep)))))

(check! "the sweep fixture appended records after the segment boundary"
        (and (> (count sweep-boundaries) 1) (= 4 (count sweep-images))))
(check! "every cut of a continuation tail folds to an exact committed image"
        (= (set (keys sweep)) #{:exact}))

;; The header itself is the boundary the chain cannot cross without its ref.
(def headless (java.util.Arrays/copyOfRange sweep-bytes 0 4))
(write-bytes! sweep-tail headless)
(check! "a tail cut inside its header fails the boot closed"
        (contains? #{:corrupt-triple-log :unsupported-log-version}
                   (error-code #(database/open-branch! sweep-log "lane" space))))
(write-bytes! sweep-tail sweep-bytes)

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nSTORELOG chain boot:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nSTORELOG chain boot:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
