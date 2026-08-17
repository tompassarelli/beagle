;; Model-based generative gate: seeded op sequences compared against the pure
;; oracle after EVERY op and again after a cold FRAMLOG restart.
;;   env -u BEAGLE_STORE_TELEMETRY_LOG bb -cp out tests/model_generative_test.clj
;; BEAGLE_STORE_MODEL_SEEDS / BEAGLE_STORE_MODEL_OPS override the run; BEAGLE_STORE_MODEL_NEGATIVE=1
;; arms the oracle's negative control, which must make this gate FAIL.
(require '[clojure.string :as str]
         '[store.store :as store]
         '[store.types :as t])

(load-file "database.clj")
(load-file "tests/model/occurrence_model.clj")

(alias 'model 'occurrence-model)

(def space-id "model-generative-space")

(def default-seeds [0x5EED01 0x5EED02 0x5EED03 0x5EED04 0x5EED05])

(def seeds
  (if-let [override (System/getenv "BEAGLE_STORE_MODEL_SEEDS")]
    (mapv #(Long/decode ^String %)
          (remove str/blank? (str/split (str/trim override) #"[,\s]+")))
    default-seeds))

(def ops-per-seed
  (Long/parseLong (or (System/getenv "BEAGLE_STORE_MODEL_OPS") "110")))

(def negative-control?
  (= "1" (System/getenv "BEAGLE_STORE_MODEL_NEGATIVE")))

;; ------------------------------------------------------------- seeded rng

(def ^:private gamma (Long/parseUnsignedLong "9E3779B97F4A7C15" 16))
(def ^:private mix-a (Long/parseUnsignedLong "BF58476D1CE4E5B9" 16))
(def ^:private mix-b (Long/parseUnsignedLong "94D049BB133111EB" 16))

(defn splitmix64 [state]
  (let [next-state (unchecked-add state gamma)
        z1 (unchecked-multiply
            (bit-xor next-state (unsigned-bit-shift-right next-state 30))
            mix-a)
        z2 (unchecked-multiply
            (bit-xor z1 (unsigned-bit-shift-right z1 27))
            mix-b)]
    [next-state (bit-xor z2 (unsigned-bit-shift-right z2 31))]))

(defn rng [initial]
  (let [state (atom (long initial))]
    (fn [bound]
      (let [[next-state value] (splitmix64 @state)]
        (reset! state next-state)
        (int (Long/remainderUnsigned value (long bound)))))))

(defn pick [rand-int xs]
  (nth (vec xs) (rand-int (count xs))))

;; --------------------------------------------------------- term vocabulary

(def atom-vocabulary
  ["Alice" "Bob" "" "naïve λ" "CRM"
   :email :knows :status :kernel/tx-sequence :kernel/op-ordinal
   0 1 -1 42 9007199254740993 Long/MIN_VALUE
   1.5 -0.5 0.0
   true false
   (t/instant 1785560000 123456789)
   (t/instant 0 0)])

(defn gen-term [rand-int depth]
  (if (or (zero? depth) (< (rand-int 100) 62))
    (pick rand-int atom-vocabulary)
    (t/triple (gen-term rand-int (dec depth))
              (gen-term rand-int (dec depth))
              (gen-term rand-int (dec depth)))))

(defn gen-proposition [rand-int]
  (t/triple (gen-term rand-int 2) (gen-term rand-int 1) (gen-term rand-int 2)))

;; FRAMLOG's TermCodecV1 depth bound is 256; a deep proposition stays just
;; inside it so the harness probes the limit without asserting its error path.
(defn deep-proposition [rand-int depth]
  (loop [term (pick rand-int atom-vocabulary) level 0]
    (if (>= level depth)
      (t/triple term :chain depth)
      (recur (t/triple term :link level) (inc level)))))

(def actors ["Tom" "reviewer" :lane])
(def frames ["model-gen" "batch-frame" ""])
(def instants [(t/instant 1785560000 1) (t/instant 1785560001 999999999)])

(defn gen-options [rand-int]
  (cond-> {}
    (< (rand-int 100) 45) (assoc :actor (pick rand-int actors))
    (< (rand-int 100) 35) (assoc :source-frame (pick rand-int frames))
    (< (rand-int 100) 30) (assoc :recorded-at (pick rand-int instants))))

;; ----------------------------------------------------------- op generation

(defn- live-coordinates [m]
  (mapv t/operationoccurrence-coordinate (model/live-occurrences m)))

(defn- all-coordinates [m]
  (mapv t/operationoccurrence-coordinate (model/occurrences m)))

(defn- retraction-coordinates [m]
  (into []
        (comp (filter #(= :retract (t/operationoccurrence-action %)))
              (map t/operationoccurrence-coordinate))
        (model/occurrences m)))

(defn- unknown-coordinate [m]
  (model/occ-coordinate
   (model/tx-coordinate space-id (+ 10000 (:next-sequence m))) 0))

(defn- gen-target [rand-int m]
  (let [live (live-coordinates m)
        all (all-coordinates m)
        retractions (retraction-coordinates m)
        roll (rand-int 100)]
    (cond
      (and (< roll 60) (seq live)) (pick rand-int live)
      (and (< roll 75) (seq retractions)) (pick rand-int retractions)
      (and (< roll 90) (seq all)) (pick rand-int all)
      :else (unknown-coordinate m))))

(defn- gen-base [rand-int m]
  (let [current (model/current-transaction m)
        sequence (t/triple-t3 current)]
    (case (rand-int 3)
      0 current
      1 (model/tx-coordinate space-id (max 0 (- sequence 1 (rand-int 3))))
      2 (model/tx-coordinate space-id (+ sequence 1 (rand-int 4))))))

(defn- gen-pool-proposition [rand-int pool]
  (if (and (seq pool) (< (rand-int 100) 78))
    (pick rand-int pool)
    nil))

(defn gen-op [rand-int m pool]
  (let [roll (rand-int 100)
        proposition (or (gen-pool-proposition rand-int pool)
                        (gen-proposition rand-int))]
    (cond
      (< roll 30)
      {:kind :assert :proposition proposition :options (gen-options rand-int)}

      (< roll 46)
      {:kind :retract :proposition proposition :options (gen-options rand-int)}

      (< roll 58)
      {:kind :batch
       :operations (mapv (fn [_]
                           (cond-> {:action (if (< (rand-int 100) 60) :assert :retract)
                                    :proposition (or (gen-pool-proposition rand-int pool)
                                                     (gen-proposition rand-int))}
                             (< (rand-int 100) 40)
                             (assoc :source-frame (pick rand-int frames))
                             (< (rand-int 100) 25)
                             (assoc :recorded-at (pick rand-int instants))
                             (< (rand-int 100) 25)
                             (assoc :asserted-by (pick rand-int actors))))
                         (range (inc (rand-int 3))))
       :options (gen-options rand-int)}

      (< roll 68)
      {:kind :supersede :target (gen-target rand-int m)
       :replacement proposition :options (gen-options rand-int)}

      (< roll 78)
      {:kind :withdraw :target (gen-target rand-int m)
       :options (gen-options rand-int)}

      (< roll 88)
      {:kind :assert :proposition proposition
       :options (assoc (gen-options rand-int) :base (gen-base rand-int m))}

      ;; Supersession remains an ordinary asserted domain proposition. A
      ;; proposition with this shape suppresses its target in the effective
      ;; live projection; physical withdrawal is represented separately.
      (< roll 94)
      {:kind :assert
       :proposition (t/triple (gen-target rand-int m)
                              :kernel/supersedes
                              (gen-target rand-int m))
       :options {}}

      ;; Re-assert something already live: equal propositions must stay
      ;; separately occurrence-addressable.
      :else
      (let [live (model/live-propositions m)]
        {:kind :assert
         :proposition (if (seq live) (pick rand-int live) proposition)
         :options {}}))))

(defn model-apply [m op]
  (case (:kind op)
    :assert (model/assert-proposition m (:proposition op) (:options op))
    :retract (model/retract-proposition m (:proposition op) (:options op))
    :batch (model/commit m (assoc (:options op) :operations (:operations op)))
    :supersede (model/supersede m (:target op) (:replacement op) (:options op))
    :withdraw (model/withdraw-occurrence m (:target op) (:options op))))

(defn engine-apply [db op]
  (case (:kind op)
    :assert (database/assert! db (:proposition op) (:options op))
    :retract (database/retract! db (:proposition op) (:options op))
    :batch (database/commit! db (assoc (:options op) :operations (:operations op)))
    :supersede (database/supersede! db (:target op) (:replacement op) (:options op))
    :withdraw (database/withdraw-occurrence! db (:target op) (:options op))))

(defn generate-ops
  "Every sequence opens with a fixed nested-Term prelude — assert, equal
   re-assert, retract — so deep-Term encode, withdrawal, and replay are covered
   on every seed instead of by lottery. Near-limit depth lives in the separate
   deep arm: an engine projection rebuilds a Term in O(depth²), so a 240-deep
   proposition inside a 110-op sequence dominates the whole run."
  [seed op-count]
  (let [rand-int (rng seed)
        pool (vec (repeatedly 14 #(gen-proposition rand-int)))
        deep (deep-proposition rand-int (+ 24 (rand-int 16)))
        prelude (subvec [{:kind :assert :proposition deep
                          :options {:source-frame "deep-prelude"}}
                         {:kind :assert :proposition deep :options {}}
                         {:kind :retract :proposition deep :options {}}]
                        0 (min 3 op-count))]
    (loop [m (reduce (fn [acc op] (:model (model-apply acc op)))
                     (model/new-model space-id) prelude)
           ops prelude
           remaining (- op-count (count prelude))]
      (if (<= remaining 0)
        ops
        (let [op (gen-op rand-int m pool)]
          (recur (:model (model-apply m op)) (conj ops op) (dec remaining)))))))

;; ------------------------------------------------------------- comparison

(defn render-term [value]
  (cond
    (t/triple? value) (str "(" (render-term (t/triple-t1 value)) " "
                           (render-term (t/triple-t2 value)) " "
                           (render-term (t/triple-t3 value)) ")")
    (t/instant? value) (str "#inst[" (t/instant-epoch-seconds value) "."
                            (t/instant-nanos value) "]")
    :else (pr-str value)))

(defn render [value]
  (cond
    (t/operation-occurrence? value)
    (str "#occurrence[" (render-term (t/operationoccurrence-coordinate value))
         " " (pr-str (t/operationoccurrence-action value))
         " " (render-term (t/operationoccurrence-proposition value)) "]")
    (t/withdrawal? value)
    (str "#withdrawal["
         (render-term (t/operationoccurrence-coordinate
                       (t/withdrawal-retraction value)))
         " "
         (render-term (t/operationoccurrence-coordinate
                       (t/withdrawal-assertion value))) "]")
    (t/triple? value) (render-term value)
    (t/instant? value) (render-term value)
    (map? value) (str "{" (str/join ", " (map (fn [[k v]] (str (render k) " " (render v)))
                                              value)) "}")
    (sequential? value) (str "[" (str/join " " (map render value)) "]")
    (set? value) (str "#{" (str/join " " (map render value)) "}")
    :else (render-term value)))

(defn render-op [op]
  (case (:kind op)
    :assert (str "assert " (render-term (:proposition op)) " " (render (:options op)))
    :retract (str "retract " (render-term (:proposition op)) " " (render (:options op)))
    :batch (str "batch " (render (:operations op)) " " (render (:options op)))
    :supersede (str "supersede " (render-term (:target op)) " -> "
                    (render-term (:replacement op)) " " (render (:options op)))
    :withdraw (str "withdraw " (render-term (:target op)) " " (render (:options op)))))

(defn- diff [field expected actual]
  (when (not= expected actual)
    {:field field :expected expected :actual actual}))

(defn compare-projections
  "Every engine projection is a full-corpus rebuild, so each accessor is called
   once per comparison. EXHAUSTIVE? adds the accessors that are definitionally
   derived from one already checked here."
  ([m db] (compare-projections m db false))
  ([m db exhaustive?]
   (let [engine-occurrences (database/occurrences db)
         engine-withdrawals (database/withdrawals db)
         engine-live (database/live-occurrences db)
         model-occurrences (model/occurrences m)
         model-withdrawals (model/withdrawals m)
         model-live (model/live-occurrences m)
         model-live-propositions (model/live-propositions m)]
     (some identity
           [(diff :current-transaction
                  (model/current-transaction m) (database/current-transaction db))
            (diff :occurrence-count
                  (count model-occurrences) (count engine-occurrences))
            (diff :withdrawal-count
                  (count model-withdrawals) (count engine-withdrawals))
            (diff :live-proposition-count (count model-live-propositions)
                  (count engine-live))
            (diff :live-propositions model-live-propositions
                  (mapv t/operationoccurrence-proposition engine-live))
            (diff :live-occurrences model-live engine-live)
            (diff :occurrences model-occurrences engine-occurrences)
            (diff :withdrawals model-withdrawals engine-withdrawals)
            (diff :supersession-triples
                  (model/supersession-triples m) (database/supersession-triples db))
            (diff :store-live-propositions
                  (model/store-live-propositions m)
                  (store/live-propositions (database/database-store db)))
            (when exhaustive?
              (diff :public-live-propositions
                    model-live-propositions (database/live-propositions db)))]))))

(defn compare-occurrence-resolution [db receipt]
  (some (fn [occurrence]
          (let [coordinate (t/operationoccurrence-coordinate occurrence)]
            (diff :occurrence-resolution occurrence
                  (database/occurrence db coordinate))))
        (:occurrences receipt)))

(defn compare-temporal-projections [m db]
  (let [root @(database/database-store db)
        current (dec (:next-sequence m))
        upper (quot current 2)
        lower (max -1 (- upper 3))
        context (store/new-term-store space-id)
        _ (doseq [frame (store/transaction-frames-between root -1 upper)]
            (store/replay-transaction! context frame))
        postings (store/operation-postings root)
        positions (store/operation-candidate-positions
                   root lower upper nil nil postings)
        actual-occurrences
        (mapv (fn [position]
                (let [[coordinate action proposition]
                      (store/occurrence-tuple-at root position)]
                  (t/operation-occurrence coordinate action proposition)))
              positions)]
    (or (diff :as-of-live-propositions
              (model/store-live-propositions-as-of m upper)
              (store/live-propositions context))
        (diff :since-occurrences
              (model/occurrences-between m lower upper)
              actual-occurrences))))

(defn- guarded [f]
  (try
    {:value (f)}
    (catch clojure.lang.ExceptionInfo error
      {:threw (or (:fram/code (ex-data error)) (:type (ex-data error)))})
    (catch Throwable error
      {:threw (keyword (.getSimpleName (class error)))})))

;; ------------------------------------------------------------------- runner

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-model-generative-"
    (make-array java.nio.file.attribute.FileAttribute 0))))

(def run-counter (atom 0))

(defn- fresh-log! []
  (let [file (java.io.File. scratch (str "run-" (swap! run-counter inc) ".framlog"))]
    (database/create-triple-log! (.getPath file) space-id)
    file))

(defn run-sequence
  "Replay OPS against a fresh log-backed server and the oracle, comparing
   after every op and after a cold restart. Returns {:mismatch …} or {:stats …}."
  [ops]
  (let [file (fresh-log!)
        db (database/open-database! (.getPath file) space-id)]
    (loop [index 0
           m (model/new-model space-id
                              (when negative-control?
                                {:dedupe-live-assertions? true}))
           committed 0]
      (if (>= index (count ops))
        (let [restarted (database/open-database! (.getPath file) space-id)]
          (if-let [mismatch
                   (or (compare-projections m db true)
                       (compare-temporal-projections m db)
                       (compare-projections m restarted true)
                       (compare-temporal-projections m restarted)
                       ;; Replay determinism is byte-exact at the store level,
                       ;; not merely projection-equal.
                       (diff :cold-restart-term-store-dump
                             (store/dump-term-store (database/database-store db))
                             (store/dump-term-store
                              (database/database-store restarted))))]
            {:mismatch (assoc mismatch :index :cold-restart)}
            {:stats {:ops (count ops)
                     :committed committed
                     :occurrences (count (database/occurrences db))
                     :withdrawals (count (database/withdrawals db))
                     :live (count (database/live-propositions db))
                     :log-bytes (.length file)}}))
        (let [op (nth ops index)
              expected (guarded #(model-apply m op))
              actual (guarded #(engine-apply db op))
              receipt (:receipt (:value expected))]
          (if-let [mismatch
                   (or (diff :thrown (:threw expected) (:threw actual))
                       (when-not (:threw actual)
                         (or (diff :receipt receipt (:value actual))
                             (compare-projections (:model (:value expected)) db)
                             (compare-temporal-projections
                              (:model (:value expected)) db)
                             (compare-occurrence-resolution db receipt))))]
            {:mismatch (assoc mismatch :index index :op op)}
            (recur (inc index) (:model (:value expected))
                   (cond-> committed (:ok receipt) inc))))))))

(defn minimal-failing-prefix [ops]
  (loop [length 1]
    (cond
      (> length (count ops)) nil
      (:mismatch (run-sequence (subvec ops 0 length))) length
      :else (recur (inc length)))))

(defn- clip [s]
  (let [text (str s)]
    (if (> (count text) 600) (str (subs text 0 600) " …") text)))

(defn report-failure! [seed ops mismatch]
  (println)
  (println (format "  MISMATCH  seed=0x%X  op-index=%s  field=%s"
                   (long seed) (str (:index mismatch)) (name (:field mismatch))))
  (println "    expected (model) :" (clip (render (:expected mismatch))))
  (println "    actual   (engine):" (clip (render (:actual mismatch))))
  (when (:op mismatch)
    (println "    failing op       :" (clip (render-op (:op mismatch)))))
  (let [prefix (minimal-failing-prefix ops)]
    (println "    minimal failing prefix:" (str (or prefix "none")) "ops")
    (when prefix
      (println (format "    reproduce: BEAGLE_STORE_MODEL_SEEDS=0x%X BEAGLE_STORE_MODEL_OPS=%d bb -cp out tests/model_generative_test.clj"
                       (long seed) prefix))
      (doseq [[i op] (map-indexed vector (subvec ops 0 prefix))]
        (println (format "      %3d  %s" i (clip (render-op op))))))))

;; Near-limit depth arm: short on purpose, because every projection rebuild of a
;; 240-deep Term is quadratic in depth.
(defn deep-arm-ops []
  (let [rand-int (rng 0xDEE9)
        deep (deep-proposition rand-int 240)
        deeper (deep-proposition rand-int 248)
        opened [{:kind :assert :proposition deep
                 :options {:actor "deep" :source-frame "deep-arm"}}
                {:kind :assert :proposition deep :options {}}
                {:kind :batch
                 :operations [{:action :assert :proposition deeper
                               :source-frame "deep-batch"}
                              {:action :retract :proposition deeper}
                              {:action :assert :proposition deep}]
                 :options {:actor "deep" :recorded-at (first instants)}}]
        opened-model (reduce (fn [acc op] (:model (model-apply acc op)))
                             (model/new-model space-id) opened)
        latest (fn [m projection]
                 (some-> (filterv #(= deep
                                      (t/operationoccurrence-proposition %))
                                   (projection m))
                         peek
                         t/operationoccurrence-coordinate))
        withdrawn (conj opened {:kind :withdraw
                                :target (latest opened-model
                                                model/store-live-occurrences)
                                :options {:actor "deep"}})
        withdrawn-model (:model (model-apply opened-model (peek withdrawn)))]
    (conj withdrawn
          {:kind :supersede
           :target (latest withdrawn-model model/live-occurrences)
           :replacement deeper :options {}}
          {:kind :retract :proposition deep :options {}})))

(def failures (atom 0))

(println "model-based generative harness")
(println "  seeds:" (str/join " " (map #(format "0x%X" (long %)) seeds))
         " ops/seed:" ops-per-seed
         (if negative-control? " NEGATIVE-CONTROL ARMED" ""))

(def started (System/nanoTime))

(doseq [seed seeds]
  (let [ops (generate-ops seed ops-per-seed)
        {:keys [mismatch stats]} (run-sequence ops)]
    (if mismatch
      (do (swap! failures inc)
          (println (format "  [FAIL] seed 0x%X — %d ops" (long seed) (count ops)))
          (report-failure! seed ops mismatch))
      (println (format "  [PASS] seed 0x%X — %d ops, %d commits, %d occurrences, %d withdrawals, %d live, %d log bytes"
                       (long seed) (:ops stats) (:committed stats)
                       (:occurrences stats) (:withdrawals stats)
                       (:live stats) (:log-bytes stats))))))

(let [ops (deep-arm-ops)
      {:keys [mismatch stats]} (run-sequence ops)]
  (if mismatch
    (do (swap! failures inc)
        (println (format "  [FAIL] deep arm — %d ops" (count ops)))
        (report-failure! 0xDEE9 ops mismatch))
    (println (format "  [PASS] deep arm — %d ops at Term depth 240/248, %d occurrences, %d withdrawals, %d log bytes"
                     (:ops stats) (:occurrences stats) (:withdrawals stats)
                     (:log-bytes stats)))))

(def elapsed-ms (quot (- (System/nanoTime) started) 1000000))

(println)
(println (format "seeds=%d ops/seed=%d elapsed=%dms"
                 (count seeds) ops-per-seed elapsed-ms))

(if (zero? @failures)
  (do
    (println "model generative suite:" (count seeds) "/" (count seeds) "seeds PASS")
    (when negative-control?
      (println "NEGATIVE CONTROL DID NOT FAIL — the harness is not falsifiable")
      (System/exit 1)))
  (do
    (println "model generative suite:" @failures "seed(s) FAILED")
    (System/exit 1)))
