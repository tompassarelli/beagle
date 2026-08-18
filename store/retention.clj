;; Rooted, re-derivable fact compaction and inventory.
(ns retention
  (:require [clojure.java.io :as io]
            [clojure.set :as set]
            [clojure.string :as str])
  (:import [java.nio.charset StandardCharsets]
           [java.nio.file Files StandardCopyOption]
           [java.security MessageDigest]
           [java.time Instant]
           [java.util UUID]))

(def fact-gc-version-v1 1)
(def fact-gc-format-v1 "beagle.store/FactGcV1")
(def fact-root-format-v1 "beagle.store/FactRootV1")
(def fact-derivation-format-v1 "beagle.store/FactDerivationV1")
(def retention-receipt-format-v1 "beagle.store/RetentionReceiptV1")
(def inventory-format-v1 "beagle.store/FactInventoryV1")
(def budget-format-v1 "beagle.store/FactAdmissionBudgetV1")

(def fact-root-kinds-v1
  ["LIVE-COMMIT" "PIN" "CHECKPOINT" "SESSION" "RECENT"])
(def fact-root-live-kinds-v1
  #{"LIVE-COMMIT" "PIN" "CHECKPOINT" "SESSION"})
(def fact-root-statuses-v1 [:live :recent :dead :rejected])
(def fact-partition-classes-v1
  [:marked :re-derivable :archive-only :unsafe])

(defn- fail! [code message data]
  (throw (ex-info message (assoc data :type code :fram/code code))))

(defn- nonblank? [value]
  (and (string? value) (not (str/blank? value))))

(defn- exact-keys! [value expected label]
  (when-not (and (map? value) (= expected (set (keys value))))
    (fail! :fact-gc/invalid-value
           (str label " must contain exactly its V1 fields")
           {:label label :fields (when (map? value) (set (keys value)))}))
  value)

(defn- root-kind [kind]
  (let [kind (if (keyword? kind) (str/upper-case (name kind)) kind)]
    (if (some #{kind} fact-root-kinds-v1)
      kind
      (fail! :fact-gc/invalid-root-kind
             "FactRootV1 root-kind is not recognized" {:root-kind kind}))))

(defn- millis [value]
  (cond
    (nil? value) nil
    (integer? value) (long value)
    (instance? Instant value) (.toEpochMilli ^Instant value)
    (string? value)
    (try (.toEpochMilli (Instant/parse value))
         (catch Exception _
           (fail! :fact-gc/invalid-time
                  "FactRootV1 time must be an ISO-8601 instant"
                  {:value value})))
    :else (fail! :fact-gc/invalid-time
                 "FactRootV1 time must be an ISO-8601 instant"
                 {:value value})))

(defn fact-root-v1
  "Validate one durable root manifest without inferring liveness from mtime."
  [root]
  (when-not (and (map? root)
                 (set/subset?
                  #{:root-id :git-repository :git-commit :fact-candidate-root
                    :root-kind :created-at :expires-at :maintenance-policy}
                  (set (keys root)))
                 (set/subset? (set (keys root))
                              #{:root-id :git-repository :git-commit
                                :fact-candidate-root :root-kind :created-at
                                :expires-at :maintenance-policy :rejected?}))
    (fail! :fact-gc/invalid-value
           "FactRootV1 must contain exactly its V1 fields"
           {:label "FactRootV1" :fields (when (map? root) (set (keys root)))}))
  (doseq [field [:root-id :git-repository :git-commit :fact-candidate-root]]
    (when-not (nonblank? (get root field))
      (fail! :fact-gc/invalid-root
             "FactRootV1 identity fields must be nonempty strings"
             {:field field})))
  (let [created (millis (:created-at root))
        expires (millis (:expires-at root))]
    (when (and expires created (<= expires created))
      (fail! :fact-gc/invalid-root
             "FactRootV1 expires-at must be after created-at" {}))
    (assoc root :root-kind (root-kind (:root-kind root)))) )

(defn fact-derivation-v1
  "Bind a fact to the complete deterministic input closure that can re-mint it."
  [derivation]
  (exact-keys! derivation
               #{:format :version :source-commit :source-digests
                 :candidate-root :fact-ids :verifier :policy :importer
                 :compiler :predecessor-fact-ids :foreign-inputs
                 :producer :producer-version :deterministic?
                 :foreign-inputs-available? :rederived-fact-id}
               "FactDerivationV1")
  (when-not (= fact-derivation-format-v1 (:format derivation))
    (fail! :fact-gc/invalid-derivation "FactDerivationV1 format is invalid" {}))
  (when-not (= fact-gc-version-v1 (:version derivation))
    (fail! :fact-gc/invalid-derivation "FactDerivationV1 version is invalid" {}))
  (doseq [field [:source-commit :candidate-root :verifier :policy :importer
                 :compiler :producer :producer-version]]
    (when-not (nonblank? (get derivation field))
      (fail! :fact-gc/invalid-derivation
             "FactDerivationV1 required identity is empty" {:field field})))
  (when-not (and (map? (:source-digests derivation))
                 (every? nonblank? (keys (:source-digests derivation)))
                 (every? nonblank? (vals (:source-digests derivation))))
    (fail! :fact-gc/invalid-derivation
           "FactDerivationV1 source-digests must map names to nonempty digests" {}))
  (doseq [field [:fact-ids :predecessor-fact-ids :foreign-inputs]]
    (when-not (and (coll? (get derivation field))
                   (every? nonblank? (get derivation field)))
      (fail! :fact-gc/invalid-derivation
             "FactDerivationV1 dependency fields must be collections of strings"
             {:field field})))
  (when-not (and (boolean? (:deterministic? derivation))
                 (boolean? (:foreign-inputs-available? derivation)))
    (fail! :fact-gc/invalid-derivation
           "FactDerivationV1 determinism flags must be booleans" {}))
  (when-not (nonblank? (:rederived-fact-id derivation))
    (fail! :fact-gc/invalid-derivation
           "FactDerivationV1 must record the exact re-derived fact ID" {}))
  derivation)

(defn- fact-id [fact]
  (when-not (and (map? fact) (nonblank? (:fact-id fact))
                 (nonblank? (:candidate-root fact)))
    (fail! :fact-gc/invalid-fact
           "a fact requires fact-id and candidate-root" {:fact fact}))
  (:fact-id fact))

(defn- derivation-of [fact]
  (when-let [derivation (:derivation fact)]
    (fact-derivation-v1 derivation)))

(defn- replayable?
  [fact rederive!]
  (let [derivation (derivation-of fact)
        rebuilt (when (and derivation (:deterministic? derivation)
                           (:foreign-inputs-available? derivation))
                  (if rederive!
                    (rederive! fact)
                    (:rederived-fact-id derivation)))]
    (and derivation
         (= (:fact-id fact) rebuilt)
         (= (:source-commit derivation)
            (or (:source-commit fact) (:git-commit fact)
                (:source-commit derivation)))
         (= (:candidate-root derivation) (:candidate-root fact)))))

(defn- root-recent?
  [root now recency-days]
  (let [created (millis (:created-at root))
        expires (millis (:expires-at root))
        now (millis now)]
    (and (or (nil? expires) (> expires now))
         (>= created (- now (* 86400000 (long recency-days)))))))

(defn- root-fact-ids [root]
  (set (or (:fact-ids root) [])))

(defn- root-status [root now recency-days recent-root-ids]
  (cond
    (:rejected? root) :rejected
    (and (contains? fact-root-live-kinds-v1 (:root-kind root))
         (or (nil? (:expires-at root))
             (> (millis (:expires-at root)) (millis now)))) :live
    (contains? recent-root-ids (:root-id root)) :recent
    :else :dead))

(defn- recent-root-ids [roots now recency-days recency-count]
  (let [warm (filter #(root-recent? % now recency-days) roots)
        newest (->> roots
                    (filter #(root-recent? % now recency-days))
                    (sort-by (comp millis :created-at) >)
                    (take (long recency-count)))]
    (set (map :root-id (concat warm newest)))))

(defn mark-and-partition-v1
  "Mark explicit/live/recent roots, close dependency edges, and partition facts.

   A fact is evictable only when its complete derivation manifest proves that
   the exact producer and source commit re-mint its exact fact-id."
  [{:keys [facts roots now recency-days recency-count rederive!]
    :or {now (System/currentTimeMillis) recency-days 7 recency-count 100}}]
  (let [roots (mapv fact-root-v1 roots)
        facts (mapv (fn [fact] (fact-id fact) fact) facts)
        by-id (into {} (map (juxt :fact-id identity) facts))
        recent-ids (recent-root-ids roots now recency-days recency-count)
        statuses (into {}
                       (map (fn [root]
                              [(:root-id root)
                               (root-status root now recency-days recent-ids)]))
                       roots)
        active-root-ids (set (for [[root-id status] statuses
                                   :when (not= :dead status)] root-id))
        active-candidates
        (set (map :fact-candidate-root
                  (filter #(contains? active-root-ids (:root-id %)) roots)))
        explicit (set (mapcat root-fact-ids
                              (filter #(contains? active-root-ids (:root-id %)) roots)))
        initial (set (concat explicit
                             (for [fact facts
                                   :when (contains? active-candidates
                                                    (:candidate-root fact))]
                               (:fact-id fact))))
        marked
        (loop [pending initial seen #{}]
          (if-let [id (first (remove seen pending))]
            (let [fact (get by-id id)
                  deps (set (or (get-in fact [:derivation :predecessor-fact-ids])
                                (:predecessor-fact-ids fact) []))]
              (recur (into pending deps) (conj seen id)))
            seen))
        partitions
        (group-by
         (fn [fact]
           (cond
             (contains? marked (:fact-id fact)) :marked
             (replayable? fact rederive!) :re-derivable
             (:derivation fact) :archive-only
             :else :unsafe))
         facts)]
    {:format fact-gc-format-v1
     :version fact-gc-version-v1
     :root-statuses statuses
     :recent-root-ids (vec (sort recent-ids))
     :marked-fact-ids (vec (sort marked))
     :partitions (into {}
                       (map (fn [class]
                              [class (vec (sort-by :fact-id
                                                   (get partitions class [])))])
                            fact-partition-classes-v1))
     :facts facts
     :roots roots
     :policy {:recency-days recency-days :recency-count recency-count}}))

(defn- sha256-text [value]
  (let [bytes (.getBytes (pr-str value) StandardCharsets/UTF_8)
        digest (.digest (MessageDigest/getInstance "SHA-256") bytes)]
    (str "sha256:" (apply str (map #(format "%02x" (bit-and (int %) 255)) digest)))))

(defn- log-value [path]
  (let [file (io/file path)]
    (when-not (.isFile file)
      (fail! :fact-gc/log-missing "fact log is missing" {:path (.getPath file)}))
    (try
      (let [value (read-string (slurp file))]
        (when-not (and (= fact-gc-format-v1 (:format value))
                       (= fact-gc-version-v1 (:version value))
                       (integer? (:revision value))
                       (vector? (:facts value))
                       (vector? (:roots value)))
          (fail! :fact-gc/invalid-log "fact log header is invalid" {:path path}))
        value)
      (catch clojure.lang.ExceptionInfo error (throw error))
      (catch Exception error
        (fail! :fact-gc/invalid-log "fact log cannot be decoded"
               {:path path :message (.getMessage error)})))))

(defn- write-log-file! [path value]
  (let [file (io/file path)
        bytes (.getBytes (pr-str value) StandardCharsets/UTF_8)]
    (spit file (String. bytes StandardCharsets/UTF_8))
    (with-open [channel (java.io.FileOutputStream. file true)]
      (.force (.getChannel channel) true))
    path))

(defn write-fact-log-v1!
  "Create a small deterministic EDN fact-log used by the maintenance seam/tests."
  [path {:keys [revision facts roots] :or {revision 0 facts [] roots []}}]
  (write-log-file! path {:format fact-gc-format-v1 :version fact-gc-version-v1
                         :revision revision :facts (vec facts) :roots (vec roots)}))

(defn inventory-v1
  "Report logical and filesystem inventory without mutating the fact log."
  [{:keys [log-path facts roots last-compaction-bytes last-successful-sweep-ms]
    :or {last-compaction-bytes 0}}]
  (let [value (when log-path (log-value log-path))
        facts (vec (or facts (:facts value) []))
        roots (vec (or roots (:roots value) []))
        file (when log-path (io/file log-path))
        bytes (long (if file (.length file) 0))
        now (System/currentTimeMillis)
        ages (map #(- now (millis (:created-at (fact-root-v1 %)))) roots)
        partition (mark-and-partition-v1 {:facts facts :roots roots :now now})]
    {:format inventory-format-v1
     :version fact-gc-version-v1
     :framlog-bytes bytes
     :filesystem-allocated-bytes bytes
     :operation-occurrences (count facts)
     :live-fact-entries (count (:marked-fact-ids partition))
     :candidate-root-count (count (set (map :fact-candidate-root facts)))
     :root-count (count roots)
     :root-age-ms (when (seq ages) {:oldest (apply max ages) :newest (apply min ages)})
     :dead-count (count (filter #(= :dead (val %)) (:root-statuses partition)))
     :recent-count (count (filter #(= :recent (val %)) (:root-statuses partition)))
     :re-derivable-count (count (get-in partition [:partitions :re-derivable]))
     :bytes-since-last-compaction (max 0 (- bytes (long last-compaction-bytes)))
     :last-successful-sweep-ms last-successful-sweep-ms
     :free-bytes (.getFreeSpace (or file (io/file ".")))
     :revision (:revision value)}))

(defn- cold-verify! [value partition]
  (let [ids (set (map :fact-id (:facts value)))]
    (when-not (set/subset? (set (:marked-fact-ids partition)) ids)
      (fail! :fact-gc/rehydration-failed
             "compacted log does not rehydrate every marked fact"
             {:missing (vec (sort (set/difference
                                   (set (:marked-fact-ids partition)) ids)))}))
    (doseq [root (:roots value)
            :when (not= :dead (get (:root-statuses partition) (:root-id root)))]
      (let [required (root-fact-ids root)]
        (when-not (set/subset? required ids)
          (fail! :fact-gc/rehydration-failed
                 "compacted log does not rehydrate a live root"
                 {:root-id (:root-id root)
                  :missing (vec (sort (set/difference required ids)))}))))
    value))

(defn compact-fact-log-v1!
  "Compact through a validated temporary log and publish only on revision CAS.

   The old log is never removed before the replacement has been cold-opened and
   every non-dead root has been checked. An exception before publish leaves it
   untouched and the temporary candidate available for diagnosis/resume."
  [{:keys [log-path roots facts expected-revision now recency-days recency-count
           rederive! authority! before-cas! interrupt-after-write?]
    :or {now (System/currentTimeMillis) recency-days 7 recency-count 100}}]
  (let [current (log-value log-path)
        expected (long (or expected-revision (:revision current)))
        _ (when-not (= expected (:revision current))
            (fail! :fact-gc/stale-cas
                   "fact log revision is stale before compaction"
                   {:expected expected :actual (:revision current)}))
        facts (vec (or facts (:facts current)))
        roots (vec (or roots (:roots current)))
        partition (mark-and-partition-v1
                   {:facts facts :roots roots :now now :recency-days recency-days
                    :recency-count recency-count :rederive! rederive!})
        evicted (get-in partition [:partitions :re-derivable])
        retained (vec (concat (get-in partition [:partitions :marked])
                             (get-in partition [:partitions :archive-only])
                             (get-in partition [:partitions :unsafe])))
        retained (vec (sort-by :fact-id retained))
        temporary (str log-path ".fact-gc-" (UUID/randomUUID) ".tmp")
        candidate {:format fact-gc-format-v1 :version fact-gc-version-v1
                   :revision (inc expected) :facts retained :roots roots
                   :previous-revision expected}]
    (write-log-file! temporary candidate)
    (cold-verify! (log-value temporary) partition)
    (when interrupt-after-write?
      (fail! :fact-gc/interrupted
             "compaction interrupted before compare-and-swap publish"
             {:temporary temporary :old-log log-path}))
    (when before-cas! (before-cas! {:temporary temporary :expected-revision expected}))
    (let [publish
          (fn []
            (let [observed (:revision (log-value log-path))]
              (when-not (= expected observed)
                (fail! :fact-gc/stale-cas
                       "fact log changed before compaction publish"
                       {:expected expected :actual observed
                        :temporary temporary}))
              (Files/move (.toPath (io/file temporary)) (.toPath (io/file log-path))
                          (into-array StandardCopyOption
                                      [StandardCopyOption/ATOMIC_MOVE
                                       StandardCopyOption/REPLACE_EXISTING]))
              true))]
      (if authority! (authority! publish) (publish)))
    (let [published (log-value log-path)
          receipt {:format retention-receipt-format-v1
                   :version fact-gc-version-v1
                   :receipt-id (sha256-text [expected (:revision published)
                                             (mapv :fact-id retained)
                                             (mapv :fact-id evicted)])
                   :root-ids (vec (sort (map :root-id roots)))
                   :candidate-roots (vec (sort (set (map :fact-candidate-root facts))))
                   :facts-scanned (count facts)
                   :bytes-scanned (.length (io/file log-path))
                   :facts-retained (count retained)
                   :facts-evicted (count evicted)
                   :evicted-fact-ids (vec (sort (map :fact-id evicted)))
                   :re-derivability (select-keys partition [:partitions :policy])
                   :compaction-bytes (.length (io/file log-path))
                   :cas {:expected-revision expected
                         :published-revision (:revision published)
                         :status :published}
                   :rehydration {:status :pass
                                 :live-fact-entries (count (:marked-fact-ids partition))}}]
      {:log published :partition partition :receipt receipt})))

(defn admission-budget-v1 [budget]
  (let [expected #{:max-log-bytes :max-fact-entries :min-free-bytes}]
    (exact-keys! budget expected "FactAdmissionBudgetV1")
    (doseq [field expected]
      (when-not (and (integer? (get budget field)) (not (neg? (get budget field))))
        (fail! :fact-gc/invalid-budget "admission budget values must be nonnegative integers"
               {:field field})))
    (assoc budget :format budget-format-v1 :version fact-gc-version-v1)))

(defn admit-append-v1!
  "Fail closed before append when any configured fact/byte/free-space bound is crossed."
  [{:keys [inventory budget append-bytes append-facts free-bytes]}]
  (let [budget (admission-budget-v1 budget)
        inventory (merge {:framlog-bytes 0 :live-fact-entries 0} inventory)
        next-bytes (+ (:framlog-bytes inventory) (long (or append-bytes 0)))
        next-facts (+ (:live-fact-entries inventory) (long (or append-facts 0)))
        free (long (or free-bytes (:free-bytes inventory) 0))
        breaches (vec (concat
                      (when (> next-bytes (:max-log-bytes budget)) [:max-log-bytes])
                      (when (> next-facts (:max-fact-entries budget)) [:max-fact-entries])
                      (when (< free (:min-free-bytes budget)) [:min-free-bytes])))]
    {:format budget-format-v1 :version fact-gc-version-v1
     :status (if (empty? breaches) :accepted :refused)
     :code (if (empty? breaches) :fact-gc/admitted :fact-gc/budget-breach)
     :breaches breaches
     :projected {:framlog-bytes next-bytes :live-fact-entries next-facts
                 :free-bytes free}}))
