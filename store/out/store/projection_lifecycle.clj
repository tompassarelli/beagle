(ns store.projection-lifecycle
  "Confined, atomic publication of checked graph projections."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [store.code-reader :as code-reader]
            [store.program-inspection :as program])
  (:import [java.nio ByteBuffer]
           [java.nio.channels FileChannel]
           [java.nio.charset StandardCharsets]
           [java.nio.file CopyOption Files LinkOption OpenOption Path
            StandardCopyOption StandardOpenOption]
           [java.security MessageDigest]
           [java.util Arrays]))

(def ^:dynamic *before-atomic-move*
  "Test seam invoked after the complete temp file is forced and before rename."
  (fn [_] nil))

(def ^:dynamic *resolve-program-slice*
  "Test seam for the one-file resolved analysis projection."
  program/resolve-corpus-slice!)

(def ^:private byte-array-class (Class/forName "[B"))
(def ^:private no-links (make-array LinkOption 0))

(defn- lifecycle-fail! [type message data]
  (throw (ex-info message (assoc data :type type))))

(defn- byte-array! [value]
  (when-not (.isInstance byte-array-class value)
    (lifecycle-fail! :invalid-projection-bytes
                     "checked projection must be a byte array"
                     {:value-type (some-> value class str)}))
  value)

(defn- real-path! [value field]
  (try
    (.toRealPath (if (instance? Path value)
                   value
                   (.toPath (io/file value)))
                 no-links)
    (catch Throwable cause
      (lifecycle-fail! :invalid-projection-path
                       (str field " must name an existing path")
                       {:field field :path (str value) :cause cause}))))

(defn- inside-root? [^Path root ^Path path]
  (or (= root path) (.startsWith path root)))

(defn resolve-projection-path!
  "Resolve a registered projection path and reject traversal or symlink escape
   outside registered-root. The target's parent must already exist."
  [registered-root registered-path]
  (let [root (real-path! registered-root "registered root")]
    (when-not (Files/isDirectory root no-links)
      (lifecycle-fail! :invalid-projection-root
                       "registered root must be a directory"
                       {:registered-root (str root)}))
    (let [raw (.toPath (io/file registered-path))
          candidate (-> (if (.isAbsolute raw) raw (.resolve root raw))
                        .toAbsolutePath
                        .normalize)
          parent (.getParent candidate)]
      (when-not parent
        (lifecycle-fail! :invalid-projection-path
                         "registered projection path has no parent"
                         {:registered-path (str registered-path)}))
      (let [real-parent (real-path! parent "registered projection parent")
            target (.normalize (.resolve real-parent (.getFileName candidate)))]
        (when-not (inside-root? root real-parent)
          (lifecycle-fail! :projection-path-outside-root
                           "registered projection path escapes its registered root"
                           {:registered-root (str root)
                            :registered-path (str registered-path)
                            :resolved-parent (str real-parent)}))
        (when (Files/isSymbolicLink target)
          (lifecycle-fail! :projection-path-symlink
                           "registered projection path may not be a symbolic link"
                           {:registered-root (str root)
                            :registered-path (str registered-path)}))
        (when (and (Files/exists target no-links)
                   (Files/isDirectory target no-links))
          (lifecycle-fail! :invalid-projection-path
                           "registered projection path names a directory"
                           {:registered-path (str registered-path)}))
        (str target)))))

(defn- sha256 [^bytes value]
  (let [digest (.digest (MessageDigest/getInstance "SHA-256") value)]
    (str "sha256:"
         (apply str (map #(format "%02x" (bit-and 0xff %)) digest)))))

(defn- write-all! [^FileChannel channel ^ByteBuffer buffer]
  (loop []
    (when (.hasRemaining buffer)
      (when (neg? (.write channel buffer))
        (lifecycle-fail! :projection-write-failed
                         "projection temp file closed before all bytes were written"
                         {}))
      (recur))))

(defn- atomic-publish! [target value]
  (let [bytes (byte-array! value)
        target-path (.toPath (io/file target))
        parent (.getParent target-path)
        temp (Files/createTempFile
              parent ".store-projection-" ".tmp"
              (make-array java.nio.file.attribute.FileAttribute 0))]
    (try
      (with-open [channel
                  (FileChannel/open
                   temp
                   (into-array OpenOption
                               [StandardOpenOption/WRITE
                                StandardOpenOption/TRUNCATE_EXISTING]))]
        (write-all! channel (ByteBuffer/wrap bytes))
        (.force channel true))
      (*before-atomic-move* {:temp (str temp) :target (str target-path)})
      (Files/move
       temp target-path
       (into-array CopyOption
                   [StandardCopyOption/ATOMIC_MOVE
                    StandardCopyOption/REPLACE_EXISTING]))
      (let [actual (Files/readAllBytes target-path)]
        (when-not (Arrays/equals bytes actual)
          (lifecycle-fail! :projection-readback-mismatch
                           "published projection does not match checked bytes"
                           {:expected-sha256 (sha256 bytes)
                            :actual-sha256 (sha256 actual)})))
      {:path (str target-path) :sha256 (sha256 bytes) :bytes (alength bytes)}
      (finally
        (Files/deleteIfExists temp)))))

(defn- exception-summary [cause]
  {:type (or (:type (ex-data cause)) :projection-publication-failed)
   :message (.getMessage ^Throwable cause)})

(defn- commit-summary [commit-outcome]
  (select-keys commit-outcome
               [:type :module :base-version :committed-version
                :observed-version :conflicts]))

(defn- stale-outcome [commit-outcome cause]
  (let [repair (or (:repair (ex-data cause))
                   {:verb :repair-projection :module (:module commit-outcome)})
        result
        {:outcome :committed-projection-stale
         :graph-state :committed
         :graph-version (:committed-version commit-outcome)
         :projection-state :repair-needed
         :repair-needed? true
         :automatic-retry? false
         :retry (if (= :repair-program-view (:verb repair))
                  :repair-program-view-only :repair-projection-only)
         :repair repair
         :commit (commit-summary commit-outcome)
         :commit-receipt (:proof commit-outcome)
         :cause (exception-summary cause)}]
    (binding [*out* *err*]
      (println "PROJECTION STALE: graph commit succeeded; projection repair is required; do not retry the graph commit"
               (pr-str (select-keys result [:graph-version :repair :cause]))))
    result))

(defn publish-checked-projection!
  "Finish a stage-3 result without performing a graph commit.

   A :precommit-rejection returns before resolving paths or touching the
   filesystem. A :committed outcome atomically publishes the already-checked
   bytes. Any postcommit failure is a loud, repair-only state and is never an
   ordinary retry signal."
  [{:keys [commit-outcome registered-root registered-path checked-bytes
           program-corpus program-facts-command affected-definitions]}]
  (case (:type commit-outcome)
    :precommit-rejection
    {:outcome :precommit-rejected
     :graph-state :unchanged
     :projection-state :not-written
     :repair-needed? false
     :automatic-retry? false
     :retry :stage-3-policy
     :commit (commit-summary commit-outcome)
     :rejection (:rejection commit-outcome)}

    (:commit-conflict :commit-rejection)
    {:outcome :graph-commit-rejected
     :graph-state :unchanged
     :projection-state :not-written
     :repair-needed? false
     :automatic-retry? false
     :retry :stage-3-policy
     :commit (commit-summary commit-outcome)}

    :postcommit-divergence
    (stale-outcome
     commit-outcome
     (ex-info "stage-3 postcommit verification diverged"
              {:type :postcommit-divergence}))

    :committed
    (try
      (when (str/blank? (str (:module commit-outcome)))
        (lifecycle-fail! :invalid-module
                         "committed projection requires a module" {}))
      (let [target (resolve-projection-path! registered-root registered-path)
            published (atomic-publish! target checked-bytes)
            _ (when (and program-corpus
                         (or (str/blank? (str program-facts-command))
                             (empty? affected-definitions)))
                (lifecycle-fail! :invalid-program-materialization
                                 "program materialization requires its resolver and affected identities"
                                 {:module (:module commit-outcome)}))
            program-view
            (when program-corpus
              (try
                (program/materialize-committed-view!
                 {:path program-corpus
                  :registered-root registered-root
                  :registered-path registered-path
                  :resolved-slice
                  (*resolve-program-slice* program-facts-command
                                           registered-root target)
                  :affected-definitions affected-definitions
                  :committed-version (:committed-version commit-outcome)})
                (catch Throwable cause
                  (throw
                   (ex-info
                    "committed program view requires incremental repair"
                    {:type :program-view-publication-failed
                     :repair {:verb :repair-program-view
                              :module (:module commit-outcome)
                              :affectedDefinitions affected-definitions}}
                    cause)))))]
        (cond->
         {:outcome :committed-projection-published
          :graph-state :committed
          :graph-version (:committed-version commit-outcome)
          :projection-state :published
          :repair-needed? false
          :automatic-retry? false
          :retry :never
          :commit (commit-summary commit-outcome)
          :commit-receipt (:proof commit-outcome)
          :projection published}
          program-view (assoc :program-view program-view)))
      (catch Throwable cause
        (stale-outcome commit-outcome cause)))

    (lifecycle-fail! :invalid-commit-state
                     "projection lifecycle requires a closed stage-3 outcome"
                     {:commit-type (:type commit-outcome)})))

(defn- render-current! [port space registered-root module beagle]
  (let [snapshot (code-reader/read-module-snapshot!
                  port space registered-root module)
        rendered (code-reader/render-module! beagle snapshot)
        bytes (.getBytes ^String (:source rendered) StandardCharsets/UTF_8)
        target (resolve-projection-path!
                registered-root (get-in snapshot [:snapshot :root]))]
    {:module module
     :graph-version (get-in snapshot [:snapshot :version])
     :target target
     :bytes bytes
     :sha256 (sha256 bytes)}))

(defn projection-status!
  "Compare the registered file with a fresh projection of the current graph."
  [port space registered-root module beagle]
  (let [{:keys [target bytes graph-version] expected-sha256 :sha256}
        (render-current! port space registered-root module beagle)
        target-path (.toPath (io/file target))
        actual (when (Files/exists target-path no-links)
                 (Files/readAllBytes target-path))
        current? (and actual (Arrays/equals bytes actual))]
    (cond->
     {:module module
      :graph-version graph-version
      :path target
      :projection-state (if current? :current :stale)
      :repair-needed? (not current?)
      :expected-sha256 expected-sha256
      :repair {:verb :repair-projection :module module}}
      actual (assoc :actual-sha256 (sha256 actual)))))

(defn repair-projection!
  "Idempotently regenerate a registered projection from the current graph."
  [port space registered-root module beagle]
  (try
    (let [{:keys [target bytes sha256 graph-version]}
          (render-current! port space registered-root module beagle)
          published (atomic-publish! target bytes)]
      {:outcome :projection-repaired
       :graph-state :current
       :graph-version graph-version
       :projection-state :published
       :repair-needed? false
       :automatic-retry? false
       :retry :never
       :expected-sha256 sha256
       :projection published})
    (catch Throwable cause
      (let [result
            {:outcome :projection-repair-needed
             :graph-state :current
             :projection-state :repair-needed
             :repair-needed? true
             :automatic-retry? false
             :retry :repair-projection-only
             :repair {:verb :repair-projection :module module}
             :cause (exception-summary cause)}]
        (binding [*out* *err*]
          (println "PROJECTION REPAIR NEEDED: projection regeneration did not publish"
                   (pr-str (select-keys result [:repair :cause]))))
        result))))
