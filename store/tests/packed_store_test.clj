;; Packed Store checkpoint, indexed prefix+tail reads, rollover, and recovery.
(require '[store.datalog :as d]
         '[store.packed :as packed]
         '[store.query :as q]
         '[store.store :as store]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label value]
  (println (str (if value "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(defn exception-data [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error (ex-data error))))

(defn scratch-directory [prefix]
  (.toFile
   (java.nio.file.Files/createTempDirectory
    prefix
    (make-array java.nio.file.attribute.FileAttribute 0))))

(defn page-section-entry [file section-id]
  (with-open [input (java.io.RandomAccessFile. file "r")]
    (let [bytes (byte-array 24)]
      (.seek input (+ 128 (* 24 (dec section-id))))
      (.readFully input bytes)
      (let [view (doto (java.nio.ByteBuffer/wrap bytes)
                   (.order java.nio.ByteOrder/LITTLE_ENDIAN))]
        {:id (.getInt view)
         :width (.getInt view)
         :offset (.getLong view)
         :length (.getLong view)}))))

(defn corrupt-section! [file section-id]
  (let [{:keys [id offset length] :as entry}
        (page-section-entry file section-id)]
    (when-not (and (= section-id id) (pos? length))
      (throw (ex-info "test selected an absent packed section" entry)))
    (with-open [output (java.io.RandomAccessFile. file "rw")]
      (.seek output offset)
      (let [value (.read output)]
        (.seek output offset)
        (.write output (bit-xor value 1)))
      (.force (.getChannel output) true))
    entry))

(defn v [name] (d/variable name))
(defn c [value] (d/constant value))
(defn rel [name arguments] (d/relation-literal name arguments))
(defn rule [name head body] (d/rule name head body))
(defn plan [name rules] (q/query-plan (q/relation-find name) [rules]))
(defn result-rows [result] (set (q/result-rows result)))

;; The first unique transaction fits a small configured tail. The second does
;; not fit beside it, so database commit must checkpoint, install, and retry it
;; against an empty tail without exposing a rollover error to the caller.
(def undersized-scratch (scratch-directory "store-packed-undersized-tail-"))
(def undersized-log (java.io.File. undersized-scratch "history.storelog"))
(database/create-triple-log! (.getPath undersized-log) "undersized-tail-space")
(def undersized-db
  (database/open-database!
   (.getPath undersized-log) "undersized-tail-space"
   {:tail-row-limit 217 :tail-byte-limit 1048576}))
(def undersized-error
  (exception-data
   #(database/assert!
     undersized-db
     (t/triple "undersized-left" :edge "undersized-right")
     {})))
(check! "the former 217-row fixture cannot hold the empty seven-table tail"
        (and (= :packed-tail-capacity-exceeded
                (or (:store/code undersized-error) (:type undersized-error)))
             (= 448 (:tail-rows undersized-error))
             (= 217 (:row-limit undersized-error))))

(def rollover-scratch (scratch-directory "store-packed-rollover-"))
(def rollover-log (java.io.File. rollover-scratch "history.storelog"))
(database/create-triple-log! (.getPath rollover-log) "rollover-space")
(def rollover-db
  (database/open-database!
   (.getPath rollover-log) "rollover-space"
   {:tail-row-limit 477 :tail-byte-limit 1048576}))
(def rollover-first (t/triple "rollover-left-a" :edge "rollover-right-a"))
(def rollover-second (t/triple "rollover-left-b" :edge "rollover-right-b"))
(def rollover-first-result (database/assert! rollover-db rollover-first {}))
(def rollover-after-first
  (:storage (database/database-status! rollover-db)))
(def rollover-second-result (database/assert! rollover-db rollover-second {}))
(def rollover-after-second
  (:storage (database/database-status! rollover-db)))

(check! "the first unique transaction fits the configured boxed tail"
        (and (= (t/transaction-coordinate "rollover-space" 1)
                (:ok rollover-first-result))
             (<= (:tail-rows rollover-after-first)
                 (:tail-row-limit rollover-after-first))))
(check! "the second unique transaction forces rollover and still commits"
        (and (= (t/transaction-coordinate "rollover-space" 2)
                (:ok rollover-second-result))
             (= (inc (:tail-rollovers rollover-after-first))
                (:tail-rollovers rollover-after-second))
             (= 1 (:prefix-transactions rollover-after-second))
             (= 1 (:suffix-transactions rollover-after-second))
             (<= (:tail-rows rollover-after-second)
                 (:tail-row-limit rollover-after-second))))

;; The first assertion is now in the packed prefix. Its retraction must move
;; only the prefix-count cursor; no packed active-position run may be copied
;; into the boxed overlay.
(def rollover-retract-result
  (database/retract! rollover-db rollover-first {}))
(def rollover-after-retract
  (:storage (database/database-status! rollover-db)))
(check! "cross-boundary retraction changes liveness without copying the prefix run"
        (and (:ok rollover-retract-result)
             (not (some #{rollover-first}
                        (database/live-propositions! rollover-db)))
             (some #{rollover-second}
                   (database/live-propositions! rollover-db))
             (<= (:active-overlay-positions rollover-after-retract) 1)
             (<= (:tail-rows rollover-after-retract)
                 (:tail-row-limit rollover-after-retract))))
(check! "packed live count matches the materialized effective view"
        (= (count (database/live-propositions! rollover-db))
           (database/live-proposition-count! rollover-db)))

;; Three prefix rows and three tail rows each form one two-column partial match
;; for SPO, POS, and OSP respectively.
(def scratch (scratch-directory "store-packed-indexes-"))
(def log-file (java.io.File. scratch "history.storelog"))
(database/create-triple-log! (.getPath log-file) "packed-space")
(def db (database/open-database! (.getPath log-file) "packed-space"))

(def prefix-spo (t/triple "shared-spo-subject" :shared-spo "prefix-spo"))
(def prefix-pos (t/triple "prefix-pos" :shared-pos "shared-pos-object"))
(def prefix-osp (t/triple "shared-osp-subject" :prefix-osp "shared-osp-object"))
(doseq [proposition [prefix-spo prefix-pos prefix-osp]]
  (database/assert! db proposition {}))
(def prior-checkpoint (database/checkpoint-packed! db))

(def tail-spo (t/triple "shared-spo-subject" :shared-spo "tail-spo"))
(def tail-pos (t/triple "tail-pos" :shared-pos "shared-pos-object"))
(def tail-osp (t/triple "shared-osp-subject" :tail-osp "shared-osp-object"))
(doseq [proposition [tail-spo tail-pos tail-osp]]
  (database/assert! db proposition {}))

(def indexed-root @(database/database-store! db))
(defn matching-propositions [t1 t2 t3]
  (set (store/matching-live-propositions indexed-root t1 t2 t3 nil)))

(check! "SPO partial lookup merges packed prefix and bounded tail"
        (= #{prefix-spo tail-spo}
           (matching-propositions "shared-spo-subject" :shared-spo nil)))
(check! "POS partial lookup merges packed prefix and bounded tail"
        (= #{prefix-pos tail-pos}
           (matching-propositions nil :shared-pos "shared-pos-object")))
(check! "OSP partial lookup merges packed prefix and bounded tail"
        (= #{prefix-osp tail-osp}
           (matching-propositions "shared-osp-subject" nil
                                  "shared-osp-object")))

(def indexed-plan
  (plan
   "indexed"
   [(rule "indexed" [(c :spo) (v "value")]
          [(rel d/triple-relation
                [(c "shared-spo-subject") (c :shared-spo) (v "value")])])
    (rule "indexed" [(c :pos) (v "value")]
          [(rel d/triple-relation
                [(v "value") (c :shared-pos) (c "shared-pos-object")])])
    (rule "indexed" [(c :osp) (v "value")]
          [(rel d/triple-relation
                [(c "shared-osp-subject") (v "value")
                 (c "shared-osp-object")])])]))
(def indexed-propositions (database/live-propositions! db))
(def materialized-result (q/run! indexed-propositions indexed-plan))
(def store-result
  (q/run-plan-projected!
   (q/->Projection
    {}
    {d/triple-relation (d/triple-candidate-source indexed-root)})
   indexed-plan))
(check! "Store-backed Datalog candidates preserve materialized query results"
        (= (result-rows materialized-result) (result-rows store-result)))

;; A two-literal Store join must keep private handles across the join. This
;; corpus crosses packed-prefix and boxed-tail rows, includes a recursive Term
;; key, and forces repeated-variable equality before final-row decoding.
(def join-scratch (scratch-directory "store-packed-handle-join-"))
(def join-log (java.io.File. join-scratch "history.storelog"))
(database/create-triple-log! (.getPath join-log) "join-space")
(def join-db (database/open-database! (.getPath join-log) "join-space"))
(def nested-subject (t/triple "nested" :id 1))
(doseq [proposition [(t/triple "@join-prefix" :kind "thread")
                     (t/triple "@join-prefix" :title "Prefix title")
                     (t/triple "@join-cross" :kind "thread")
                     (t/triple nested-subject :kind "thread")
                     (t/triple "same" :self "same")]]
  (database/assert! join-db proposition {}))
(database/checkpoint-packed! join-db)
(doseq [proposition [(t/triple "@join-cross" :title "Cross title")
                     (t/triple "@join-tail" :kind "thread")
                     (t/triple "@join-tail" :title "Tail title")
                     (t/triple nested-subject :title "Nested title")
                     (t/triple "same" :label "Same label")]]
  (database/assert! join-db proposition {}))

(def join-root @(database/database-store! join-db))
(def join-projection
  (q/->Projection
   {}
   {d/triple-relation (d/triple-candidate-source join-root)}))
(def binary-join-plan
  (plan
   "binary-join"
   [(rule "binary-join" [(v "subject") (v "title")]
          [(rel d/triple-relation
                [(v "subject") (c :kind) (c "thread")])
           (rel d/triple-relation
                [(v "subject") (c :title) (v "title")])])]))
(def binary-join-store-result
  (q/run-plan-projected! join-projection binary-join-plan))
(def binary-join-materialized-result
  (q/run! (database/live-propositions! join-db) binary-join-plan))
(def expected-binary-join-rows
  #{["@join-prefix" "Prefix title"]
    ["@join-cross" "Cross title"]
    ["@join-tail" "Tail title"]
    [nested-subject "Nested title"]})
(check! "handle-domain binary join spans prefix and tail and decodes final rows"
        (and (= expected-binary-join-rows
                (result-rows binary-join-store-result))
             (= (result-rows binary-join-materialized-result)
                (result-rows binary-join-store-result))))

(def repeated-handle-plan
  (plan
   "repeated-handle"
   [(rule "repeated-handle" [(v "same") (v "label")]
          [(rel d/triple-relation
                [(v "same") (c :self) (v "same")])
           (rel d/triple-relation
                [(v "same") (c :label) (v "label")])])]))
(check! "handle-domain join preserves repeated-variable equality"
        (= #{["same" "Same label"]}
           (result-rows
            (q/run-plan-projected! join-projection repeated-handle-plan))))

(def missing-handle-plan
  (plan
   "missing-handle"
   [(rule "missing-handle" [(v "subject") (v "title")]
          [(rel d/triple-relation
                [(v "subject") (c :kind) (c "absent-kind")])
           (rel d/triple-relation
                [(v "subject") (c :title) (v "title")])])]))
(check! "missing Store constant is empty rather than an unbound wildcard"
        (empty?
         (result-rows
          (q/run-plan-projected! join-projection missing-handle-plan))))

;; A malformed dump could once preserve two equal Atom values under different
;; handles. The handle-domain join then disagreed with materialized equality:
;; its retained index rejected the rewritten row even though both handles
;; resolved to the same value.
(def equality-context (store/new-term-store "duplicate-equality-space"))
(def equality-kind (t/triple "same" :kind "thread"))
(def equality-title (t/triple "same" :title "Title"))
(store/commit-transaction!
 equality-context
 [(store/assert-operation equality-kind)
  (store/assert-operation equality-title)])
(def equality-dump (store/dump-term-store equality-context))
(def equality-atoms (t/termstoredump-atoms equality-dump))
(def equality-triples (t/termstoredump-triples equality-dump))
(def duplicate-same-row (first equality-atoms))
(def duplicate-same-handle (* 2 (count equality-atoms)))
(def rewritten-title-row
  (assoc (second equality-triples) :t1 duplicate-same-handle))
(def malformed-equality-dump
  (assoc equality-dump
         :atoms (conj equality-atoms duplicate-same-row)
         :triples (assoc equality-triples 1 rewritten-title-row)))
(def malformed-equality-root
  (assoc @equality-context
         :atoms (atom (t/termstoredump-atoms malformed-equality-dump))
         :triples (atom (t/termstoredump-triples malformed-equality-dump))))
(def equality-plan
  (plan
   "duplicate-equality"
   [(rule "duplicate-equality" [(v "subject") (v "title")]
          [(rel d/triple-relation
                [(v "subject") (c :kind) (c "thread")])
           (rel d/triple-relation
                [(v "subject") (c :title) (v "title")])])]))
(def malformed-equality-projection
  (q/->Projection
   {}
   {d/triple-relation (d/triple-candidate-source malformed-equality-root)}))
(def malformed-optimized-result
  (result-rows
   (q/run-plan-projected! malformed-equality-projection equality-plan)))
(def malformed-materialized-result
  (result-rows
   (q/run! (store/live-propositions (atom malformed-equality-root))
           equality-plan)))
(check! "duplicate-equal handles reproduce the historical join differential"
        (and (empty? malformed-optimized-result)
             (= #{["same" "Title"]} malformed-materialized-result)))

(def malformed-equality-target
  (store/new-term-store "duplicate-equality-space"))
(def malformed-equality-before
  (store/dump-term-store malformed-equality-target))
(def malformed-equality-load
  (store/load-term-store-result!
   malformed-equality-target malformed-equality-dump))
(check! "dump load rejects duplicate-equal Atom rows before building indexes"
        (and (not (store/termstoreloadresult-ok malformed-equality-load))
             (= :invalid-term-store-dump
                (store/termstoreloadresult-code malformed-equality-load))
             (= malformed-equality-before
                (store/dump-term-store malformed-equality-target))))

(def duplicate-triple-dump
  (assoc equality-dump :triples (conj equality-triples
                                      (first equality-triples))))
(def duplicate-triple-load
  (store/load-term-store-result!
   (store/new-term-store "duplicate-equality-space")
   duplicate-triple-dump))
(check! "dump load rejects duplicate structural Triple rows"
        (and (not (store/termstoreloadresult-ok duplicate-triple-load))
             (= :invalid-term-store-dump
                (store/termstoreloadresult-code duplicate-triple-load))))
(check! "validated replay roots enforce the same canonical Term rows as load"
        (= :invalid-term-store-dump
           (:type
            (exception-data
             #(store/validated-store! (atom malformed-equality-root))))))

;; Database-level matching must apply supersession liveness after the packed
;; index lookup, including before a caller's maximum truncates the result.
(def matching-scratch (scratch-directory "store-packed-effective-match-"))
(def matching-log (java.io.File. matching-scratch "history.storelog"))
(database/create-triple-log! (.getPath matching-log) "matching-space")
(def matching-db
  (database/open-database! (.getPath matching-log) "matching-space"))
(def historical-proposition
  (t/triple "matching-subject" :matching-state "historical"))
(def replacement-proposition
  (t/triple "matching-subject" :matching-state "replacement"))
(def historical-result
  (database/assert! matching-db historical-proposition {}))
(def historical-coordinate
  (t/operationoccurrence-coordinate
   (first (:occurrences historical-result))))
(database/checkpoint-packed! matching-db)
(database/supersede! matching-db historical-coordinate replacement-proposition {})
(def effective-matches
  (database/matching-live-propositions!
   matching-db "matching-subject" :matching-state nil nil))
(def bounded-effective-matches
  (database/matching-live-propositions!
   matching-db "matching-subject" :matching-state nil 1))
(check! "indexed matching excludes superseded occurrences before limiting"
        (and (= [replacement-proposition] effective-matches)
             (= [replacement-proposition] bounded-effective-matches)))
(check! "effective live count excludes superseded prefix occurrences"
        (= (count (database/live-propositions! matching-db))
           (database/live-proposition-count! matching-db)))

;; A STORELOG revision is its decoded transaction sequence, not its record
;; count. Deflated records with sequence gaps must bind a checkpoint to the
;; exact byte prefix and reopen without replaying an already-packed record.
(def gapped-scratch (scratch-directory "store-packed-gapped-prefix-"))
(def gapped-log (java.io.File. gapped-scratch "history.storelog"))
(database/create-triple-log!
 (.getPath gapped-log) "gapped-space" {:deflate? true})
(def append-record! @(ns-resolve 'database 'append-record-durable!))
(def gap-ten (t/triple "gap" :sequence 10))
(def gap-twelve (t/triple "gap" :sequence 12))
(append-record!
 (.getPath gapped-log)
 {:tx-seq 10
  :operations [{:ordinal 0 :action 1 :triple gap-ten}]}
 true)
(append-record!
 (.getPath gapped-log)
 {:tx-seq 12
  :operations [{:ordinal 0 :action 1 :triple gap-twelve}]}
 true)
(def gapped-db
  (database/open-database! (.getPath gapped-log) "gapped-space"))
(def gapped-checkpoint (database/checkpoint-packed! gapped-db))
(def gapped-reopened
  (database/open-database! (.getPath gapped-log) "gapped-space"))
(def gapped-status (database/database-status! gapped-reopened))
(def gapped-storage (:storage gapped-status))
(check! "deflated gapped transaction sequences publish and reopen exactly"
        (and (= 12 (:version gapped-checkpoint))
             (= (t/transaction-coordinate "gapped-space" 12)
                (:version gapped-status))
             (= #{gap-ten gap-twelve}
                (set (database/live-propositions! gapped-reopened)))
             (= :packed-checkpoint (:boot-source gapped-storage))
             (= 2 (:prefix-records gapped-storage))
             (zero? (:suffix-records gapped-storage))
             (zero? (:decoded-record-count gapped-storage))))

(def expected-live (database/live-propositions! db))
(def expected-occurrences (database/occurrences! db))
(def expected-withdrawals (database/withdrawals! db))
(def newest-checkpoint (database/checkpoint-packed! db))
(def checkpoint-directory
  (.getParentFile (java.io.File. (:manifest newest-checkpoint))))

;; A pages file without a manifest models interruption before publication.
(spit (java.io.File. checkpoint-directory
                     "checkpoint-9999999999999999999-deadbeefdeadbeef.pages")
      "orphan")

;; A renamed manifest is newer by filename but still carries revision 3 in its
;; body. Candidate selection must reject that identity mismatch explicitly.
(def mismatched-manifest
  (java.io.File. checkpoint-directory
                 (format "checkpoint-%019d.manifest" 7)))
(java.nio.file.Files/copy
 (.toPath (java.io.File. (:manifest prior-checkpoint)))
 (.toPath mismatched-manifest)
 (into-array java.nio.file.CopyOption
             [java.nio.file.StandardCopyOption/REPLACE_EXISTING]))

;; Damage the actual SPO, POS, and OSP sections of the newest page. The offsets
;; come from the packed header table; padding corruption is not evidence.
(def newest-page
  (java.io.File. checkpoint-directory (:component newest-checkpoint)))
(def corrupted-indexes
  (mapv #(corrupt-section! newest-page %)
        [packed/spo-section packed/pos-section packed/osp-section]))
(check! "corruption targets the three nonempty packed index sections"
        (= #{packed/spo-section packed/pos-section packed/osp-section}
           (set (map :id corrupted-indexes))))

(def reopened
  (database/open-database! (.getPath log-file) "packed-space"))
(def storage (:storage (database/database-status! reopened)))

(check! "newest index corruption falls back without semantic drift"
        (and (= expected-live (database/live-propositions! reopened))
             (= expected-occurrences (database/occurrences! reopened))
             (= expected-withdrawals (database/withdrawals! reopened))))
(check! "warm boot validates the prefix and decodes only the exact suffix"
        (and (= :packed-checkpoint (:boot-source storage))
             (= 3 (:prefix-records storage))
             (= 3 (:suffix-records storage))
             (= (:watermark prior-checkpoint) (:decoded-from-byte storage))
             (= 3 (:decoded-record-count storage))
             (pos? (:mapped-bytes storage))))
(check! "filename/body mismatch and corrupted indexes have rejection receipts"
        (and (= 2 (count (:rejections storage)))
             (= #{:invalid-packed-manifest :invalid-packed-checkpoint}
                (set (map :code (:rejections storage))))))
(check! "interrupted pages-only publication is ignored"
        (= (:manifest prior-checkpoint) (:active-manifest storage)))

;; Successful publication keeps the newest recovery fallback while removing
;; every older manifest and every pages file that neither retained manifest
;; names. Repeated checkpoints must therefore converge on a fixed file count.
(def retention-checkpoints
  (mapv
   (fn [position]
     (database/assert!
      reopened
      (t/triple (str "retention-left-" position)
                :retention-edge
                (str "retention-right-" position))
      {})
     (database/checkpoint-packed! reopened))
   (range 3)))

(def retained-manifests
  (packed/candidate-manifests (.getPath checkpoint-directory)))
(def retained-records
  (mapv packed/read-manifest! retained-manifests))
(def retained-components
  (set (map packed/checkpointmanifest-component retained-records)))
(def retained-revisions
  (set (map packed/checkpointmanifest-revision retained-records)))
(def expected-retained-revisions
  (set (map :version (take-last packed/checkpoint-retention-count
                                retention-checkpoints))))
(def retained-pages
  (->> (or (.listFiles checkpoint-directory)
           (make-array java.io.File 0))
       (filter #(re-matches
                 #"checkpoint-[0-9]{19}-[0-9a-f]{16}\.pages"
                 (.getName ^java.io.File %)))
       (map #(.getName ^java.io.File %))
       set))

(check! "repeated checkpoints retain exactly the newest fallback pair"
        (and (= packed/checkpoint-retention-count
                (count retained-manifests))
             (= expected-retained-revisions retained-revisions)))
(check! "checkpoint pruning removes every orphan packed page"
        (and (= retained-components retained-pages)
             (not (.exists
                   (java.io.File.
                    checkpoint-directory
                    "checkpoint-9999999999999999999-deadbeefdeadbeef.pages")))))

(when (some (fn [[_ ok]] (not ok)) @checks)
  (System/exit 1))

(println (str "packed store: " (count @checks) " checks passed"))
