;; Every byte cut and every byte flip inside a committed record must fold to an
;; exact committed image or fail loudly; a third image is a durability defect.
;; Run from the repository root: bb -cp out tests/store-log_torn_sweep_test.clj
(require '[store.store :as store]
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

(defn- read-all ^bytes [path]
  (java.nio.file.Files/readAllBytes (.toPath (java.io.File. (str path)))))

(defn- write-bytes! [path ^bytes content]
  (java.nio.file.Files/write
   (.toPath (java.io.File. (str path))) content
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))

(defn- prefix-bytes ^bytes [^bytes content n]
  (java.util.Arrays/copyOfRange content 0 (int n)))

(defn- flipped-bytes ^bytes [^bytes content offset mask]
  (let [copy (java.util.Arrays/copyOf content (alength content))]
    (aset-byte copy (int offset)
               (unchecked-byte (bit-xor (bit-and 255 (aget copy (int offset))) mask)))
    copy))

(def space "torn-sweep-space")
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-store-log-torn-sweep-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def source-path (.getPath (java.io.File. scratch "source.storelog")))
(def cut-path (.getPath (java.io.File. scratch "cut.storelog")))
(def passive-path (.getPath (java.io.File. scratch "passive.storelog")))

(database/create-triple-log! source-path space)
(def db (database/open-database! source-path space))
(def empty-image (store/dump-term-store (database/database-store! db)))

(def nested-2
  (t/triple (t/triple "Alice" :knows "Bob")
            :reported-by
            (t/triple "CRM" :batch 71)))
(def nested-3
  (t/triple nested-2
            :corroborated-by
            (t/triple (t/triple "Dana" :saw "Alice")
                      :at (t/instant 1785560000 123456789))))

(def draft (t/triple "Task" :status "draft"))

(def boundaries (atom []))
(defn step! [label thunk]
  (let [file (java.io.File. source-path)
        start (.length file)
        result (thunk)
        end (.length file)]
    (swap! boundaries conj
           {:label label :start start :end end
            :image (store/dump-term-store (database/database-store! db))})
    result))

(step! "single assert"
       #(database/assert! db (t/triple "Alice" :email "alice@example.com")
                       {:actor "Tom"
                        :recorded-at (t/instant 1785560000 123456789)
                        :source-record "store-log-torn-sweep"}))
(step! "batch of three asserts"
       #(database/commit! db {:actor "batcher"
                           :operations
                           [{:action :assert :proposition (t/triple "A" :count 1)}
                            {:action :assert :proposition (t/triple "B" :count 2)}
                            {:action :assert :proposition (t/triple "C" :count 3)}]}))
(step! "depth-2 recursive term" #(database/assert! db nested-2 {:actor "recorder"}))
(step! "depth-3 recursive term" #(database/assert! db nested-3 {}))
(def draft-occurrence
  (t/operationoccurrence-coordinate
   (first (:occurrences (step! "draft assert" #(database/assert! db draft {}))))))
(step! "retraction" #(database/retract! db (t/triple "A" :count 1) {:actor "Tom"}))
(step! "supersession"
       #(database/supersede! db draft-occurrence (t/triple "Task" :status "final")
                          {:actor "reviewer"}))
;; This record must exceed dense-limit so the strided sweep path is exercised.
(step! "wide batch"
       #(database/commit! db {:actor "wide"
                           :operations
                           (mapv (fn [n]
                                   {:action :assert
                                    :proposition (t/triple (str "wide-subject-" n)
                                                           :measurement
                                                           (t/triple "sensor" :reading n))})
                                 (range 32))}))

(def records (vec @boundaries))
(def images (into [empty-image] (map :image) records))
(def source-bytes (read-all source-path))
(def parsed-source (database/read-triple-log! source-path))

;; Both ends stay dense; only a large record's middle is strided, to hold the
;; whole sweep inside the CI per-test budget.
(def dense-limit 512)
(def stride 7)
(def edge 64)

(defn- sampled [start end]
  (if (<= (- end start) dense-limit)
    (vec (range start end))
    (vec (sort (distinct (concat (range start (+ start edge))
                                 (range (+ start edge) (- end edge) stride)
                                 (range (- end edge) end)))))))

;; Cut offsets include the record end: the untruncated record is the endpoint the
;; sweep must fold to the post-record image.
(defn- cut-offsets [{:keys [start end]}] (conj (sampled start end) end))
(defn- flip-offsets [{:keys [start end]}] (sampled start end))

;; Arm 1 — writer authority: repair to the pre-record image, then keep writing.
(defn- sweep-cut-authority [index record cut]
  (let [{:keys [start end]} record
        before (nth images index)
        after (nth images (inc index))
        complete? (= cut end)
        expect-torn? (and (not complete?) (> cut start))
        expected-image (if complete? after before)
        expected-kept (if complete? (inc index) index)]
    (write-bytes! cut-path (prefix-bytes source-bytes cut))
    (try
      (let [opened (database/open-database! cut-path space {:repair-torn? true})
            image (store/dump-term-store (database/database-store! opened))
            reported (:recovered-tail opened)
            repaired (database/read-triple-log! cut-path)
            marker (database/assert! opened (t/triple "sweep-marker" :cut cut) {})
            cold (database/open-database! cut-path space)]
        (cond-> {}
          (not= expected-image image) (assoc :divergent true)
          (and expect-torn? (nil? reported)) (assoc :missing-torn true)
          (and (not expect-torn?) (some? reported)) (assoc :spurious-torn true)
          (some? (:torn-tail repaired)) (assoc :unrepaired true)
          (not= expected-kept (count (:records repaired))) (assoc :wrong-record-count true)
          (not= (t/transaction-coordinate space (inc expected-kept)) (:ok marker))
          (assoc :write-rejected true)
          (not (some #{(t/triple "sweep-marker" :cut cut)}
                     (database/live-propositions! cold)))
          (assoc :marker-not-durable true)))
      (catch Throwable error
        {:threw (or (:store/code (ex-data error)) (str error))}))))

;; Arm 2 — passive standby: report the tear, never rewrite the file.
(defn- sweep-cut-passive [index record cut]
  (let [{:keys [start end]} record
        complete? (= cut end)
        expect-torn? (and (not complete?) (> cut start))
        expected-image (if complete? (nth images (inc index)) (nth images index))
        written (prefix-bytes source-bytes cut)]
    (write-bytes! passive-path written)
    (try
      (let [opened (database/open-database! passive-path space)
            image (store/dump-term-store (database/database-store! opened))
            reported (:torn-tail opened)
            write-code (when expect-torn?
                         (error-code #(database/assert! opened nested-2 {})))]
        (cond-> {}
          (not= expected-image image) (assoc :divergent true)
          (and expect-torn? (nil? reported)) (assoc :missing-torn true)
          (and (not expect-torn?) (some? reported)) (assoc :spurious-torn true)
          (and expect-torn? (not= :torn-tail-repair-required write-code))
          (assoc :accepted-write true)
          (not (java.util.Arrays/equals written (read-all passive-path)))
          (assoc :rewrote true)))
      (catch Throwable error
        {:threw (or (:store/code (ex-data error)) (str error))}))))

;; Arm 3 — the record under test is made final, then one byte of it is flipped.
(def corruption-codes
  #{:corrupt-triple-log :noncontiguous-ordinal :invalid-utf8 :invalid-keyword
    :invalid-integer :unsupported-term :term-depth-exceeded})

(defn- sweep-flip [index record offset mask]
  (let [before (nth images index)
        after (nth images (inc index))
        truncated (prefix-bytes source-bytes (:end record))
        written (flipped-bytes truncated offset mask)]
    (write-bytes! cut-path written)
    (try
      (let [opened (database/open-database! cut-path space {:repair-torn? true})
            image (store/dump-term-store (database/database-store! opened))]
        (condp = image
          before {:outcome :repaired-to-prefix}
          after {:outcome :flip-was-benign}
          {:outcome :divergent-image :divergent true}))
      (catch clojure.lang.ExceptionInfo error
        (let [code (or (:store/code (ex-data error)) (:type (ex-data error)))]
          (cond-> {:outcome code}
            (not (contains? corruption-codes code)) (assoc :unknown-code true)
            (not (java.util.Arrays/equals written (read-all cut-path)))
            (assoc :mutated true))))
      (catch Throwable error
        {:outcome :non-store-throwable :threw (str error) :unknown-code true}))))

(defn- accumulate [acc index record offset result]
  (reduce (fn [m [k v]]
            (update m k (fnil conj [])
                    (cond-> {:record index :label (:label record) :offset offset}
                      (not (true? v)) (assoc :detail v))))
          (update acc :count inc)
          result))

(def authority-sweep
  (reduce (fn [acc [index record]]
            (reduce (fn [a cut] (accumulate a index record cut
                                            (sweep-cut-authority index record cut)))
                    acc (cut-offsets record)))
          {:count 0} (map-indexed vector records)))

(def passive-sweep
  (reduce (fn [acc [index record]]
            (reduce (fn [a cut] (accumulate a index record cut
                                            (sweep-cut-passive index record cut)))
                    acc (cut-offsets record)))
          {:count 0} (map-indexed vector records)))

(def flip-sweep
  (reduce (fn [acc [index record]]
            (reduce (fn [a offset]
                      (reduce (fn [b mask]
                                (let [result (sweep-flip index record offset mask)]
                                  (-> (accumulate b index record offset
                                                  (dissoc result :outcome))
                                      (update-in [:outcomes (:outcome result)]
                                                 (fnil inc 0)))))
                              a [1 128]))
                    acc (flip-offsets record)))
          {:count 0} (map-indexed vector records)))

(defn- report [label sweep]
  (println (str "\n" label " detail:"))
  (doseq [[k v] (dissoc sweep :count :outcomes)]
    (println (str "  " k " " (count v) " e.g. " (pr-str (take 5 v))))))

(println "STORELOG torn-write sweep:")
(println (str "  fixture: " (count records) " committed records, "
              (alength source-bytes) " bytes; cuts " (:count authority-sweep)
              " authority + " (:count passive-sweep) " passive; flips "
              (:count flip-sweep)))
(doseq [[index record] (map-indexed vector records)]
  (println (str "    record " index " " (:label record) ": "
                (- (:end record) (:start record)) " bytes, "
                (count (cut-offsets record)) " cuts")))

(check! "fixture committed every record shape under test"
        (and (= (count records) (count (:records parsed-source)))
             (= (mapv inc (range (count records)))
                (mapv :tx-seq (:records parsed-source)))
             (nil? (:torn-tail parsed-source))
             (= (alength source-bytes) (:valid-bytes parsed-source))))
(check! "positive control: every record moves the store image"
        (and (= (inc (count records)) (count images))
             (= (count images) (count (distinct images)))))
(check! "the wide batch record exceeds the dense-sweep limit"
        (some #(> (- (:end %) (:start %)) dense-limit) records))
(check! "sweep covered every record boundary including both endpoints"
        (= (:count authority-sweep)
           (reduce + (map #(count (cut-offsets %)) records))))

(check! "authority: no cut threw during replay"
        (nil? (:threw authority-sweep)))
(check! "authority: every cut folds to an exact committed image"
        (nil? (:divergent authority-sweep)))
(check! "authority: every torn cut is reported as a recovered tail"
        (nil? (:missing-torn authority-sweep)))
(check! "authority: a whole-record prefix reports no torn tail"
        (nil? (:spurious-torn authority-sweep)))
(check! "authority: repair leaves no torn tail on disk"
        (and (nil? (:unrepaired authority-sweep))
             (nil? (:wrong-record-count authority-sweep))))
(check! "authority: the next write is accepted at the exact next sequence"
        (nil? (:write-rejected authority-sweep)))
(check! "authority: the post-repair write cold-replays from the repaired log"
        (nil? (:marker-not-durable authority-sweep)))

(check! "passive: no cut threw during replay"
        (nil? (:threw passive-sweep)))
(check! "passive: every cut folds to an exact committed image"
        (nil? (:divergent passive-sweep)))
(check! "passive: every torn cut is reported without authority"
        (and (nil? (:missing-torn passive-sweep))
             (nil? (:spurious-torn passive-sweep))))
(check! "passive: a torn generation refuses the next write"
        (nil? (:accepted-write passive-sweep)))
(check! "passive: a standby boot never rewrites the file"
        (nil? (:rewrote passive-sweep)))

(check! "corruption: no flip silently produces a divergent image"
        (nil? (:divergent flip-sweep)))
(check! "corruption: every rejected flip names a recognized corruption state"
        (nil? (:unknown-code flip-sweep)))
(check! "corruption: a rejected flip leaves the generation untouched"
        (nil? (:mutated flip-sweep)))
(check! "corruption: flips reached both the rejection and the repair path"
        (and (pos? (get-in flip-sweep [:outcomes :corrupt-triple-log] 0))
             (pos? (get-in flip-sweep [:outcomes :repaired-to-prefix] 0))))

(let [failures (remove second @checks)]
  (println (str "\n  flip outcomes: " (pr-str (:outcomes flip-sweep))))
  (if (empty? failures)
    (do
      (println "\nSTORELOG torn sweep:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (report "authority" authority-sweep)
      (report "passive" passive-sweep)
      (report "corruption" flip-sweep)
      (println "\nSTORELOG torn sweep:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
