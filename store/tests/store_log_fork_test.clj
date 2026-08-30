;; Fork seals the parent tail into the shared chain and hands both branches a
;; fresh tail: no triple is copied, both branches see the pre-fork history, and
;; neither branch's later writes are visible to the other.
;; Run from the repository root: bb -cp out tests/store-log_fork_test.clj
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
    "store-store-log-fork-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(defn- store-path [name] (.getPath (java.io.File. scratch name)))

(defn- read-all ^bytes [path]
  (java.nio.file.Files/readAllBytes (.toPath (java.io.File. (str path)))))

(defn- write-all! [path ^bytes content]
  (java.nio.file.Files/write
   (.toPath (java.io.File. (str path))) content
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))

(defn- sha256-hex [^bytes content]
  (apply str (map #(format "%02x" (bit-and % 255))
                  (.digest (java.security.MessageDigest/getInstance "SHA-256")
                           content))))

(defn- image [db] (store/dump-term-store (database/database-store! db)))

(defn- live? [db proposition]
  (boolean (some #{proposition} (database/live-propositions! db))))

(def space "store-log-fork-space")

;; ---------------------------------------------------------------- fork at S
(def log (store-path "store-log"))
(database/create-triple-log! log space)
(def origin (database/open-database! log space))
(database/assert! origin (t/triple "Alice" :email "alice@example.com") {})
(database/commit! origin
                  {:actor "batcher"
                   :operations
                   [{:action :assert :proposition (t/triple "A" :count 1)}
                    {:action :assert :proposition (t/triple "B" :count 2)}]})
(database/assert! origin (t/triple "Task" :status "draft") {})
(def pre-fork-image (image origin))
(def pre-fork-bytes (read-all log))
(def pre-fork-sequence
  (:tx-seq (last (:records (database/read-triple-log! log)))))

;; A derived image beside the parent tail is stale the moment the tail is
;; sealed; the fork must remove it rather than let a later boot install it.
(def stale-image (branch/snapshot-path log))
(java.nio.file.Files/write
 (.toPath (java.io.File. stale-image)) (byte-array 8)
 (into-array java.nio.file.OpenOption
             [java.nio.file.StandardOpenOption/CREATE
              java.nio.file.StandardOpenOption/WRITE]))

(def receipt (database/fork-store! log "lane"))
(def sealed-path (branch/segment-path log (:segment receipt)))

(println "STORELOG fork:")
(println (str "  forked at sequence " (:fork-sequence receipt)
              " into " (count (:chain receipt)) " sealed segment(s)"))

(check! "fork reports the parent's last committed sequence"
        (= pre-fork-sequence (:fork-sequence receipt)))
(check! "the sealed segment is the parent tail's exact bytes"
        (java.util.Arrays/equals pre-fork-bytes (read-all sealed-path)))
(check! "the sealed segment is named by the SHA-256 of those bytes"
        (= (sha256-hex pre-fork-bytes)
           (.getName (java.io.File. sealed-path))))
(check! "fork deletes the stale parent image"
        (not (.exists (java.io.File. stale-image))))

(def parent-ref (database/read-branch-ref! log branch/default-branch))
(def child-ref (database/read-branch-ref! log "lane"))

(check! "parent and child refs name the identical sealed chain"
        (and (= parent-ref child-ref)
             (= [(:segment receipt)]
                (mapv branch/segmentrecord-sha256
                      (branch/refdocument-segments parent-ref)))))
(check! "the sealed record carries the segment's sequence span and size"
        (let [record (first (branch/refdocument-segments parent-ref))]
          (and (= 1 (branch/segmentrecord-start-sequence record))
               (= pre-fork-sequence (branch/segmentrecord-end-sequence record))
               (= (alength pre-fork-bytes)
                  (branch/segmentrecord-byte-count record)))))

(def parent-tail (branch/branch-tail-path! log branch/default-branch))
(def child-tail (branch/branch-tail-path! log "lane"))

(check! "both branches get a fresh tail carrying the continuation flag"
        (every? (fn [path]
                  (let [parsed (database/read-triple-log! path true)]
                    (and (:continuation? parsed)
                         (empty? (:records parsed))
                         (= space (:space-id parsed)))))
                [parent-tail child-tail]))
(check! "a continuation tail opened without its ref is refused"
        (= [:unsupported-log-version :unsupported-log-version]
           [(error-code #(database/open-database! parent-tail space))
            (error-code #(database/open-database! child-tail space))]))

(def parent (database/open-branch! log branch/default-branch space))
(def child (database/open-branch! log "lane" space))

(check! "both branches fold to the exact pre-fork image"
        (= [pre-fork-image pre-fork-image] [(image parent) (image child)]))
(check! "two refs at the same exact history share one branch revision"
        (= (database/branch-revision! log branch/default-branch)
           (database/branch-revision! log "lane")))

(def parent-write (database/assert! parent (t/triple "parent" :wrote 1) {}))
(def child-write (database/assert! child (t/triple "child" :wrote 1) {}))
(def parent-coordinate
  (t/operationoccurrence-coordinate (first (:occurrences parent-write))))
(def child-coordinate
  (t/operationoccurrence-coordinate (first (:occurrences child-write))))
(def parent-revision
  (database/branch-revision! log branch/default-branch))
(def child-revision (database/branch-revision! log "lane"))

(check! "each branch's first append lands at the fork sequence plus one"
        (= [(inc pre-fork-sequence) (inc pre-fork-sequence)]
           [(:tx-seq (first (:records (database/read-triple-log! parent-tail true))))
            (:tx-seq (first (:records (database/read-triple-log! child-tail true))))]))
(check! "sibling post-fork occurrences can have the same coordinate"
        (= parent-coordinate child-coordinate))
(check! "coordinate-colliding sibling appends have distinct branch revisions"
        (and (= (branch/branchrevision-sequence parent-revision)
                (branch/branchrevision-sequence child-revision))
             (not= (branch/branchrevision-history-sha256 parent-revision)
                   (branch/branchrevision-history-sha256 child-revision))
             (not= (branch/branchrevision-identity parent-revision)
                   (branch/branchrevision-identity child-revision))))
(check! "a durable branch revision repeats exactly without intervening writes"
        (= parent-revision
           (database/branch-revision! log branch/default-branch)))

(def parent-cold (database/open-branch! log branch/default-branch space))
(def child-cold (database/open-branch! log "lane" space))

(check! "a parent append is invisible to the child"
        (and (live? parent-cold (t/triple "parent" :wrote 1))
             (not (live? child-cold (t/triple "parent" :wrote 1)))))
(check! "a child append is invisible to the parent"
        (and (live? child-cold (t/triple "child" :wrote 1))
             (not (live? parent-cold (t/triple "child" :wrote 1)))))
(check! "both branches still carry the whole pre-fork history"
        (every? (fn [db]
                  (and (live? db (t/triple "Alice" :email "alice@example.com"))
                       (live? db (t/triple "A" :count 1))
                       (live? db (t/triple "Task" :status "draft"))))
                [parent-cold child-cold]))
(check! "the sealed segment is shared, not copied per branch"
        (= 1 (count (.listFiles
                     (java.io.File. (branch/segments-directory log))))))

;; ------------------------------------------------------------- fork of fork
(def grand (database/fork-store! log "lane" "lane-2"))
(check! "a fork of a fork extends the chain by exactly one segment"
        (= 2 (count (:chain grand))))
(check! "the child chain keeps the parent chain as its prefix"
        (= (:segment receipt) (first (:chain grand))))
(def grand-db (database/open-branch! log "lane-2" space))
(check! "the grandchild folds both sealed segments and sees the child's write"
        (and (live? grand-db (t/triple "child" :wrote 1))
             (live? grand-db (t/triple "Alice" :email "alice@example.com"))
             (not (live? grand-db (t/triple "parent" :wrote 1)))))
(check! "the grandchild's base segment stays the only non-continuation member"
        (let [chain (branch/refdocument-segments
                     (database/read-branch-ref! log "lane-2"))]
          (= [false true]
             (mapv (fn [record]
                     (boolean
                      (:continuation?
                       (database/read-triple-log!
                        (branch/segment-path
                         log (branch/segmentrecord-sha256 record))
                        true))))
                   chain))))

;; ---------------------------------------------------------- fork of nothing
(def empty-log (store-path "empty.storelog"))
(database/create-triple-log! empty-log space)
(def empty-receipt (database/fork-store! empty-log "lane"))
(check! "forking an empty store reports sequence zero"
        (zero? (:fork-sequence empty-receipt)))
(check! "an empty store's sealed segment records no start sequence"
        (zero? (branch/segmentrecord-start-sequence
                (first (branch/refdocument-segments
                        (database/read-branch-ref! empty-log "lane"))))))
(def empty-child (database/open-branch! empty-log "lane" space))
(database/assert! empty-child (t/triple "first" :after "fork") {})
(check! "a branch of an empty store begins at sequence one"
        (= 1 (:tx-seq (first (:records
                              (database/read-triple-log!
                               (branch/branch-tail-path! empty-log "lane")
                               true))))))
(check! "a branch of an empty store cold-replays its first write"
        (live? (database/open-branch! empty-log "lane" space)
               (t/triple "first" :after "fork")))

;; ------------------------------------------------------------ fork refusals
(check! "fork refuses a child branch that already exists"
        (= :branch-exists (error-code #(database/fork-store! log "lane"))))
(check! "fork refuses a parent and child with the same name"
        (= :invalid-branch-name
           (error-code #(database/fork-store! log "lane" "lane"))))
(check! "fork refuses a branch name that cannot address a ref file"
        (= :invalid-branch-name
           (error-code #(database/fork-store! log "../escape"))))
(check! "fork leaves the store untouched when it refuses"
        (= 2 (count (.listFiles
                     (java.io.File. (branch/segments-directory log))))))

(def torn-log (store-path "torn.storelog"))
(database/create-triple-log! torn-log space)
(def torn-db (database/open-database! torn-log space))
(database/assert! torn-db (t/triple "torn" :n 1) {})
(let [content (read-all torn-log)]
  (java.nio.file.Files/write
   (.toPath (java.io.File. torn-log))
   (java.util.Arrays/copyOfRange content 0 (dec (alength content)))
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))
(check! "fork refuses a parent tail with a torn trailing record"
        (= :torn-tail-repair-required
           (error-code #(database/fork-store! torn-log "lane"))))
(check! "a refused fork never seals the torn tail"
        (not (.exists (java.io.File. (branch/segments-directory torn-log)))))

;; ------------------------------------------------------ fork of a sealed tail
;; A branch whose tail was just sealed holds no transaction of its own, so the
;; sequence a second fork reports can only come from the ref it already has.
(def resumed-log (store-path "resumed.storelog"))
(database/create-triple-log! resumed-log space)
(let [db (database/open-database! resumed-log space)]
  (database/assert! db (t/triple "seed" :n 1) {})
  (database/assert! db (t/triple "seed" :n 2) {}))
(def first-fork (database/fork-store! resumed-log "lane"))
(def second-fork (database/fork-store! resumed-log "lane" "lane-2"))

(check! "a fork of an already-sealed branch resumes the recorded sequence"
        (= [2 2] [(:fork-sequence first-fork) (:fork-sequence second-fork)]))
(check! "the second fork extends the chain by exactly one empty segment"
        (= [2 [2 0]]
           [(count (:chain second-fork))
            (mapv branch/segmentrecord-end-sequence
                  (branch/refdocument-segments
                   (database/read-branch-ref! resumed-log "lane-2")))]))
(check! "a further fork with no write between refuses rather than seal twice"
        (= :segment-already-sealed
           (error-code #(database/fork-store! resumed-log "lane" "lane-3"))))
(check! "the refused fork leaves the branch openable and unnamed"
        (and (live? (database/open-branch! resumed-log "lane" space)
                    (t/triple "seed" :n 2))
             (nil? (database/read-branch-ref! resumed-log "lane-3"))))

;; ---------------------------------------------------------- writer authority
(def locked-log (store-path "locked.storelog"))
(database/create-triple-log! locked-log space)
(let [db (database/open-database! locked-log space)]
  (database/assert! db (t/triple "locked" :n 1) {}))
(def held (writer-authority/acquire! locked-log))

(check! "fork refuses while a writer holds the store"
        (= :writer-authority-held
           (error-code #(database/fork-store! locked-log "lane"))))
(check! "the refused fork sealed nothing"
        (not (.exists (java.io.File. (branch/segments-directory locked-log)))))
(writer-authority/release! held)
(check! "fork proceeds once writer authority is released"
        (= 1 (count (:chain (database/fork-store! locked-log "lane")))))

;; A replacement sealed segment can be a wholly valid STORELOG with the same
;; SpaceId, byte count, and sequence span. Its content address must still fail.
(def tampered-log (store-path "tampered.storelog"))
(def replacement-log (store-path "replacement.storelog"))
(database/create-triple-log! tampered-log space)
(database/create-triple-log! replacement-log space)
(database/assert! (database/open-database! tampered-log space)
                  (t/triple "tamper" :value "aaaa") {})
(database/assert! (database/open-database! replacement-log space)
                  (t/triple "tamper" :value "bbbb") {})
(def tampered-receipt (database/fork-store! tampered-log "lane"))
(def tampered-segment
  (branch/segment-path tampered-log (:segment tampered-receipt)))
(def replacement-bytes (read-all replacement-log))

(check! "the tamper witness preserves size, SpaceId, and transaction sequence"
        (let [record
              (first
               (branch/refdocument-segments
                (database/read-branch-ref! tampered-log "lane")))
              parsed (database/read-triple-log! replacement-log)]
          (and (= (branch/segmentrecord-byte-count record)
                  (alength replacement-bytes))
               (= space (:space-id parsed))
               (= [1] (mapv :tx-seq (:records parsed)))
               (not= (:segment tampered-receipt)
                     (sha256-hex replacement-bytes)))))
(write-all! tampered-segment replacement-bytes)
(check! "a well-formed sealed segment under the wrong content address is refused"
        (= :segment-digest-mismatch
           (error-code #(database/branch-revision! tampered-log "lane"))))
(check! "cold branch open also verifies every sealed content address"
        (= :segment-digest-mismatch
           (error-code #(database/open-branch! tampered-log "lane" space))))

;; ------------------------------------------------------ interrupted forks
;; Put a completed fork back to the state it passes through between writing its
;; marker and its last rename: every file it installs is at its pending name.
(defn- derail-fork! [log child segment]
  (doseq [path [log
                (branch/ref-path! log branch/default-branch)
                (branch/ref-path! log child)
                (branch/branch-tail-path! log child)]]
    (java.nio.file.Files/move
     (.toPath (java.io.File. (str path)))
     (.toPath (java.io.File. (str path ".fork-new")))
     (into-array java.nio.file.CopyOption [])))
  (java.nio.file.Files/write
   (.toPath (java.io.File. (str log ".fork")))
   (.getBytes (branch/print-fork-marker
               (branch/->ForkMarker branch/default-branch child segment))
              java.nio.charset.StandardCharsets/UTF_8)
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))

(defn- interrupted-store! [name unseal?]
  (let [log (store-path name)]
    (database/create-triple-log! log space)
    (let [db (database/open-database! log space)]
      (database/assert! db (t/triple "before" :crash 1) {}))
    (let [receipt (database/fork-store! log "lane")]
      (derail-fork! log "lane" (:segment receipt))
      (when unseal?
        (java.nio.file.Files/move
         (.toPath (java.io.File. (branch/segment-path log (:segment receipt))))
         (.toPath (java.io.File. (str log)))
         (into-array java.nio.file.CopyOption [])))
      log)))

(def sealed-crash (interrupted-store! "crash-sealed.storelog" false))
(def unsealed-crash (interrupted-store! "crash-unsealed.storelog" true))

(check! "an interrupted fork is named on open rather than read as a lost log"
        (= [:fork-incomplete :fork-incomplete]
           [(error-code #(database/open-database! sealed-crash space))
            (error-code #(database/open-branch! sealed-crash "lane" space))]))
(check! "an interrupted fork that had not sealed yet is named the same way"
        (= :fork-incomplete
           (error-code #(database/open-database! unsealed-crash space))))
(check! "a later fork finishes the interrupted one before refusing a repeat"
        (= [:branch-exists :branch-exists]
           [(error-code #(database/fork-store! sealed-crash "lane"))
            (error-code #(database/fork-store! unsealed-crash "lane"))]))
(check! "both branches of a resumed fork carry the pre-fork history"
        (every? (fn [[log name]]
                  (live? (database/open-branch! log name space)
                         (t/triple "before" :crash 1)))
                [[sealed-crash branch/default-branch] [sealed-crash "lane"]
                 [unsealed-crash branch/default-branch] [unsealed-crash "lane"]]))
(check! "a resumed fork leaves no marker or pending file behind"
        (every? (fn [log]
                  (and (not (.exists (java.io.File. (str log ".fork"))))
                       (not (.exists (java.io.File. (str log ".fork-new"))))))
                [sealed-crash unsealed-crash]))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nSTORELOG fork:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nSTORELOG fork:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
