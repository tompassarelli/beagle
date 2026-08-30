;; Authoritative database gate: occurrence identity, OCC, durable STORELOG,
;; recursive terms, views, supersession, withdrawal, and lease fencing.
(require '[store.store :as store]
         '[store.types :as t]
         '[store.graph-control-mcp])

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
    "store-term-database-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log-file (java.io.File. scratch "history.storelog"))
(database/create-triple-log! (.getPath log-file) "database-space")
(def store-log-magic
  (.getBytes "STORELOG" java.nio.charset.StandardCharsets/UTF_8))
(def fresh-log-bytes
  (java.nio.file.Files/readAllBytes (.toPath log-file)))
(check! "fresh database writes the exact eight-byte STORELOG magic"
        (and (= 8 (alength store-log-magic))
             (java.util.Arrays/equals
              store-log-magic
              (java.util.Arrays/copyOfRange fresh-log-bytes 0 8))))
(def db (database/open-database! (.getPath log-file) "database-space"))
(def reopened-empty
  (database/open-database! (.getPath log-file) "database-space"))
(check! "fresh STORELOG opens and reopens under the same SpaceId"
        (= "database-space" (:space-id db) (:space-id reopened-empty)))
(def graph-control-space-id!
  (ns-resolve 'store.graph-control-mcp 'space-id!))
(check! "graph control parses the database STORELOG at the shared magic offset"
        (= "database-space" (graph-control-space-id! (.getPath log-file))))

(def email (t/triple "Alice" :email "alice@example.com"))
(def nested
  (t/triple (t/triple "Alice" :knows "Bob")
            :reported-by
            (t/triple "CRM" :batch 71)))
(def recorded (t/instant 1785560000 123456789))

(def first-assertion
  (database/assert! db email {:actor "Tom" :recorded-at recorded
                           :source-record "database-test"}))
(def first-event (first (:occurrences first-assertion)))
(def first-coordinate (t/operationoccurrence-coordinate first-event))
(def first-tx (:ok first-assertion))

(check! "first commit returns a transaction-coordinate Triple"
        (= (t/transaction-coordinate "database-space" 1) first-tx))
(check! "first assertion returns its exact occurrence coordinate"
        (= (t/occurrence-coordinate first-tx 0) first-coordinate))
(check! "transaction time is an ordinary typed metadata Triple"
        (some #{(t/triple first-tx :kernel/recorded-at recorded)}
              (database/live-propositions! db)))
(check! "actor and source record are ordinary metadata propositions"
        (and (some #{(t/triple first-tx :kernel/asserted-by "Tom")}
                   (database/live-propositions! db))
             (some #{(t/triple first-coordinate :kernel/source-record "database-test")}
                   (database/live-propositions! db))))

(def duplicate (database/assert! db email {}))
(def duplicate-coordinate
  (t/operationoccurrence-coordinate (first (:occurrences duplicate))))
(check! "equal propositions remain separately occurrence-addressable"
        (and (not= first-coordinate duplicate-coordinate)
             (= 2 (count (filter #{email} (database/live-propositions! db))))))

(def withdrawn
  (database/withdraw-occurrence! db duplicate-coordinate {:actor "Tom"}))
(check! "exact withdrawal removes only the named equal occurrence"
        (and (:ok withdrawn)
             (= [first-coordinate]
                (mapv t/operationoccurrence-coordinate
                      (filter #(= email (t/operationoccurrence-proposition %))
                              (database/live-occurrences! db))))))
(check! "withdrawal history points to the exact occurrence coordinate"
        (some #(= duplicate-coordinate
                  (t/operationoccurrence-coordinate
                   (t/withdrawal-assertion %)))
              (:withdrawals withdrawn)))

(def draft (t/triple "Task" :status "draft"))
(def final (t/triple "Task" :status "final"))
(def draft-result (database/assert! db draft {}))
(def draft-coordinate
  (t/operationoccurrence-coordinate (first (:occurrences draft-result))))
(def superseded (database/supersede! db draft-coordinate final {:actor "reviewer"}))
(def final-coordinate
  (t/operationoccurrence-coordinate (first (:occurrences superseded))))
(check! "supersession is an ordinary occurrence-to-occurrence Triple"
        (some #{(t/triple final-coordinate :kernel/supersedes draft-coordinate)}
              (database/supersession-triples! db)))
(check! "effective liveness follows supersession without mutating identity"
        (and (not (some #{draft} (database/live-propositions! db)))
             (some #{final} (database/live-propositions! db))
             (some #{draft} (store/live-propositions
                             (database/database-store! db)))))

;; Global transaction-coordinate OCC is conservative until schema-specific
;; conflict domains migrate; every accepted write still advances one exact tx.
(def race-base (database/current-transaction! db))
(def race-results
  (mapv deref
        (mapv (fn [n]
                (future
                  (database/assert! db (t/triple "race" :winner n)
                                 {:base race-base :actor (str "writer-" n)})))
              (range 24))))
(check! "one same-base racer wins"
        (= 1 (count (filter :ok race-results))))
(check! "all other same-base racers receive an OCC conflict"
        (= 23 (count (filter #(= :conflict (:reject %)) race-results))))
(let [before (store/operation-count (database/database-store! db))
      stale (database/assert! db nested {:base race-base})]
  (check! "stale OCC rejection leaks no TermStore operation"
          (and (= :conflict (:reject stale))
               (= before (store/operation-count
                          (database/database-store! db))))))

(def view-result (database/view-select! db "review-view" first-coordinate {}))
(check! "view selection names an occurrence using an ordinary Triple"
        (and (:ok view-result)
             (= [first-coordinate]
                (mapv t/operationoccurrence-coordinate
                      (database/view-occurrences! db "review-view")))))
(database/view-deselect! db "review-view" first-coordinate {})
(check! "withdrawing the selection empties the view without touching its target"
        (and (empty? (database/view-occurrences! db "review-view"))
             (some #{first-coordinate}
                   (map t/operationoccurrence-coordinate
                        (database/live-occurrences! db)))))

(def lease-1 (database/acquire-lease! db "resource-A" "worker-A" 1000 10000))
(def lease-epoch-1 (:ok lease-1))
(check! "lease epoch is its assertion occurrence coordinate"
        (and (t/occurrence-coordinate? lease-epoch-1)
             (database/lease-fence-valid?! db "resource-A" "worker-A"
                                       lease-epoch-1 10500)))
(check! "unexpired lease rejects a rival holder"
        (= :lease-held
           (:reject (database/acquire-lease! db "resource-A" "worker-B"
                                         1000 10500))))
(def lease-2
  (database/renew-lease! db "resource-A" "worker-A" lease-epoch-1 2000 10500))
(def lease-epoch-2 (:ok lease-2))
(check! "renewal rotates the occurrence fence and supersedes the old lease"
        (and (not= lease-epoch-1 lease-epoch-2)
             (not (database/lease-fence-valid?! db "resource-A" "worker-A"
                                            lease-epoch-1 10600))
             (database/lease-fence-valid?! db "resource-A" "worker-A"
                                       lease-epoch-2 10600)))
(check! "stale release cannot cross the occurrence fence"
        (= :lease-fence-mismatch
           (:reject (database/release-lease! db "resource-A" "worker-A"
                                         lease-epoch-1))))
(check! "epoch-exact release withdraws the current lease"
        (and (:ok (database/release-lease! db "resource-A" "worker-A"
                                       lease-epoch-2))
             (nil? (database/current-lease! db "resource-A"))))

(def numeric-result
  (database/assert! db (t/triple "measurement" :value (float 1.5)) {}))
(check! "commit canonicalizes Float atoms before memory and STORELOG diverge"
        (instance? Double
                   (t/triple-t3
                    (t/operationoccurrence-proposition
                     (first (:occurrences numeric-result))))))

(def before-restart (store/dump-term-store (database/database-store! db)))
(def restarted (database/open-database! (.getPath log-file) "database-space"))
(check! "cold STORELOG replay reconstructs the exact TermStore v2 dump"
        (= before-restart
           (store/dump-term-store (database/database-store! restarted))))
(check! "cold replay preserves system history and effective projections"
        (and (= (database/occurrences! db) (database/occurrences! restarted))
             (= (database/withdrawals! db) (database/withdrawals! restarted))
             (= (database/live-occurrences! db)
                (database/live-occurrences! restarted))))

;; A torn trailing record is dropped as a whole. Passive readers report it and
;; cannot append; an authority-holding boot truncates exactly to valid-bytes.
(with-open [out (java.io.FileOutputStream. log-file true)]
  (.write out (byte-array [(byte 40) (byte 0) (byte 0) (byte 0)
                           (byte 1) (byte 2) (byte 3)]))
  (.force (.getChannel out) true))
(def passive (database/open-database! (.getPath log-file) "database-space"))
(check! "passive boot drops and reports a torn trailing transaction record"
        (and (:torn-tail passive)
             (= before-restart
                (store/dump-term-store (database/database-store! passive)))))
(check! "passive torn generation refuses concatenating a later transaction"
        (= :torn-tail-repair-required
           (error-code #(database/assert! passive nested {}))))
(def repaired
  (database/open-database! (.getPath log-file) "database-space"
                           {:repair-torn? true}))
(check! "authority repair reports and truncates only the torn record"
        (and (:recovered-tail repaired)
             (nil? (:torn-tail (database/read-triple-log! (.getPath log-file))))))
(database/assert! repaired nested {})
(def after-repair (database/open-database! (.getPath log-file) "database-space"))
(check! "a repaired generation accepts and cold-replays the next whole record"
        (some #{nested} (database/live-propositions! after-repair)))

;; A thrown append cannot reveal whether the record reached stable storage. The
;; database rebuilds its readable state from disk but stays mutation-fenced.
(def append-record-var
  (ns-resolve 'database 'append-record-durable!))
(def append-record-original @append-record-var)

(def pre-append-file (java.io.File. scratch "pre-append-failure.storelog"))
(database/create-triple-log! (.getPath pre-append-file) "pre-append-space")
(def pre-append-db
  (database/open-database! (.getPath pre-append-file) "pre-append-space"))
(def pre-append-error
  (with-redefs-fn
    {append-record-var
     (fn [_ _ _]
       (throw (ex-info "injected before append" {:type :injected-pre-append})))}
    #(error-code
      (fn [] (database/assert! pre-append-db (t/triple "pre" :state "attempted") {})))))
(check! "pre-append exception is reported as durability-ambiguous"
        (= :durability-ambiguous pre-append-error))
(check! "pre-append reconciliation preserves the exact durable version"
        (and (= :recovery-required
                (:status (database/database-recovery-state pre-append-db)))
             (= (t/transaction-coordinate "pre-append-space" 0)
                (database/current-transaction! pre-append-db))
             (empty? (:records
                      (database/read-triple-log! (.getPath pre-append-file))))))
(check! "pre-append database rejects retry until restart"
        (= :recovery-required
           (error-code
            #(database/assert! pre-append-db (t/triple "pre" :state "retry") {}))))

(def append-cohort-var
  (ns-resolve 'database 'append-record-cohort-durable!))
(def append-cohort-original @append-cohort-var)
(def cohort-file (java.io.File. scratch "cohort.storelog"))
(database/create-triple-log! (.getPath cohort-file) "cohort-space")
(def cohort-db (database/open-database! (.getPath cohort-file) "cohort-space"))
(def cohort-barriers (atom 0))
(def cohort-result
  (with-redefs-fn
    {append-cohort-var
     (fn [path records deflate?]
       (swap! cohort-barriers inc)
       (append-cohort-original path records deflate?))}
    #(database/commit-cohort!
      cohort-db
      [(fn [db] (database/assert! db (t/triple "group" :item 1) {}))
       (fn [db] (database/assert! db (t/triple "group" :item 2) {}))])))
(check! "a cohort keeps two logical transaction records under one barrier"
        (and (= 1 @cohort-barriers)
             (= 2 (:record-count cohort-result))
             (= [1 2]
                (mapv :tx-seq
                      (:records (database/read-triple-log! (.getPath cohort-file)))))))
(check! "a successful cohort publishes its final private root atomically"
        (and (= (t/transaction-coordinate "cohort-space" 2)
                (database/current-transaction! cohort-db))
             (= #{(t/triple "group" :item 1) (t/triple "group" :item 2)}
                (set (database/live-propositions! cohort-db)))))

(def checkpoint-publish-var
  (ns-resolve 'store.checkpoint 'publish!))
(def checkpoint-publish-original @checkpoint-publish-var)
(def rollover-cohort-file
  (java.io.File. scratch "rollover-cohort.storelog"))
(database/create-triple-log!
 (.getPath rollover-cohort-file) "rollover-cohort-space")
(def rollover-cohort-db
  (database/open-database!
   (.getPath rollover-cohort-file) "rollover-cohort-space"
   {:tail-row-limit 217 :tail-byte-limit 1048576}))
(def rollover-seed (t/triple "rollover-seed-left" :edge "rollover-seed-right"))
(def rollover-first (t/triple "rollover-first-left" :edge "rollover-first-right"))
(def rollover-second (t/triple "rollover-second-left" :edge "rollover-second-right"))
(database/assert! rollover-cohort-db rollover-seed {})
(def rollover-events (atom []))
(def rollover-barriers (atom 0))
(def rollover-record-counts (atom []))
(def rollover-checkpoints (atom []))
(def rollover-cohort-result
  (with-redefs-fn
    {append-cohort-var
     (fn [path records deflate?]
       (swap! rollover-barriers inc)
       (swap! rollover-record-counts conj (count records))
       (let [result (append-cohort-original path records deflate?)]
         (swap! rollover-events conj :cohort-force-returned)
         result))
     checkpoint-publish-var
     (fn [context directory source-for-revision]
       (swap! rollover-events conj :checkpoint-publish)
       (let [result
             (checkpoint-publish-original
              context directory source-for-revision)]
         (swap! rollover-checkpoints conj result)
         result))}
    #(database/commit-cohort!
      rollover-cohort-db
      [(fn [db] (database/assert! db rollover-first {}))
       (fn [db] (database/assert! db rollover-second {}))])))
(def rollover-storage
  (:storage (database/database-status! rollover-cohort-db)))
(def rollover-reopened
  (database/open-database!
   (.getPath rollover-cohort-file) "rollover-cohort-space"
   {:tail-row-limit 217 :tail-byte-limit 1048576}))
(check! "cohort rollover publishes only after its durable record barrier"
        (and (= [:cohort-force-returned :checkpoint-publish]
                @rollover-events)
             (= 1 @rollover-barriers)
             (= [2] @rollover-record-counts)
             (= 2 (:record-count rollover-cohort-result))))
(check! "cohort rollover publishes only its final revision with an empty bounded suffix"
        (and (= (t/transaction-coordinate "rollover-cohort-space" 3)
                (:version rollover-cohort-result))
             (= [3] (mapv :version @rollover-checkpoints))
             (= 3 (:prefix-transactions rollover-storage))
             (= 0 (:suffix-transactions rollover-storage))
             (<= (:tail-rows rollover-storage)
                 (:tail-row-limit rollover-storage))))
(check! "cohort rollover reopens with the exact published live state"
        (and (= #{rollover-seed rollover-first rollover-second}
                (set (database/live-propositions! rollover-cohort-db)))
             (= (store/dump-term-store
                 (database/database-store! rollover-cohort-db))
                (store/dump-term-store
                 (database/database-store! rollover-reopened)))))

(def failed-cohort-file (java.io.File. scratch "failed-cohort.storelog"))
(database/create-triple-log! (.getPath failed-cohort-file) "failed-cohort-space")
(def failed-cohort-db
  (database/open-database! (.getPath failed-cohort-file) "failed-cohort-space"))
(def failed-cohort-error
  (with-redefs-fn
    {append-cohort-var
     (fn [_ _ _]
       (throw (ex-info "injected cohort barrier failure"
                       {:type :injected-cohort-barrier})))}
    #(error-code
      (fn []
        (database/commit-cohort!
         failed-cohort-db
         [(fn [db] (database/assert! db (t/triple "group" :failed 1) {}))
          (fn [db] (database/assert! db (t/triple "group" :failed 2) {}))])))))
(check! "a cohort barrier failure publishes nothing and fences all retries"
        (and (= :durability-ambiguous failed-cohort-error)
             (= :recovery-required
                (:status (database/database-recovery-state failed-cohort-db)))
             (= (t/transaction-coordinate "failed-cohort-space" 0)
                (database/current-transaction! failed-cohort-db))
             (empty? (:records
                      (database/read-triple-log! (.getPath failed-cohort-file))))))

(def post-force-file (java.io.File. scratch "post-force-failure.storelog"))
(database/create-triple-log! (.getPath post-force-file) "post-force-space")
(def post-force-db
  (database/open-database! (.getPath post-force-file) "post-force-space"))
(def post-force-error
  (with-redefs-fn
    {append-record-var
     (fn [path record deflate?]
       (append-record-original path record deflate?)
       (throw (ex-info "injected after force" {:type :injected-post-force})))}
    #(error-code
      (fn []
        (database/assert! post-force-db (t/triple "post" :state "durable") {})))))
(check! "post-force exception is reported as durability-ambiguous"
        (= :durability-ambiguous post-force-error))
(check! "post-force reconciliation advances readable memory to durable tx1"
        (and (= :recovery-required
                (:status (database/database-recovery-state post-force-db)))
             (= (t/transaction-coordinate "post-force-space" 1)
                (database/current-transaction! post-force-db))
             (= [1] (mapv :tx-seq
                           (:records
                            (database/read-triple-log!
                             (.getPath post-force-file)))))))
(check! "post-force database rejects a stale-sequence retry"
        (= :recovery-required
           (error-code
            #(database/assert! post-force-db (t/triple "post" :state "retry") {}))))
(def post-force-restarted
  (database/open-database! (.getPath post-force-file) "post-force-space"))
(def post-force-next
  (database/assert! post-force-restarted (t/triple "post" :state "next") {}))
(check! "restart resumes at tx2 without duplicate tx1"
        (and (= (t/transaction-coordinate "post-force-space" 2)
                (:ok post-force-next))
             (= [1 2]
                (mapv :tx-seq
                      (:records
                       (database/read-triple-log! (.getPath post-force-file)))))
             (= (t/transaction-coordinate "post-force-space" 2)
                (database/current-transaction!
                 (database/open-database! (.getPath post-force-file)
                                          "post-force-space")))))

(def corrupt-file (java.io.File. scratch "reconcile-corrupt.storelog"))
(database/create-triple-log! (.getPath corrupt-file) "corrupt-space")
(def corrupt-db (database/open-database! (.getPath corrupt-file) "corrupt-space"))
(def corrupt-error
  (with-redefs-fn
    {append-record-var
     (fn [path record deflate?]
       (append-record-original path record deflate?)
       (with-open [file (java.io.RandomAccessFile. (str path) "rw")]
         (.seek file (dec (.length file)))
         (let [last-byte (.read file)]
           (.seek file (dec (.length file)))
           (.write file (bit-xor last-byte 1))
           (.force (.getChannel file) true)))
       (throw (ex-info "injected corrupt durable record"
                       {:type :injected-corruption})))}
    #(error-code
      (fn [] (database/assert! corrupt-db (t/triple "bad" :record true) {})))))
(check! "failed durable replay permanently fences the database as corrupt"
        (and (= :database-corrupt corrupt-error)
             (= :corrupt (:status (database/database-recovery-state corrupt-db)))
             (= :database-corrupt
                (error-code
                 #(database/assert! corrupt-db (t/triple "bad" :retry true) {})))
             (= :database-corrupt
                (error-code #(database/current-transaction! corrupt-db)))))

(check! "public write responses expose no cid handle"
        (not-any? #(and (map? %) (contains? % :cid))
                  (tree-seq coll? seq first-assertion)))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nTermStore database:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nTermStore database:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
