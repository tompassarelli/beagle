(require '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str]
         '[fram.projection-lifecycle :as lifecycle]
         '[fram.rt :as rt])

(load-file "server.clj")

(def checks (atom []))
(defn check! [label value]
  (println (str (if value "[PASS] " "[FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 200) nil
            :else (do (Thread/sleep 25) (recur (inc attempt)))))))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)]
    (.getLocalPort socket)))

(defn delete-tree! [root]
  (doseq [file (reverse (file-seq root))]
    (io/delete-file file true)))

(defn canonical-source! [beagle source path]
  (let [raw (str path ".raw")
        facts (str path ".edn")]
    (spit raw source)
    (let [emitted (shell/sh beagle "facts-roundtrip" "--emit-edn" raw)]
      (when-not (zero? (:exit emitted))
        (throw (ex-info "fixture emit failed" {:stderr (:err emitted)})))
      (spit facts (:out emitted)))
    (let [rendered (shell/sh beagle "facts-roundtrip" "--render" facts)]
      (when-not (zero? (:exit rendered))
        (throw (ex-info "fixture render failed" {:stderr (:err rendered)})))
      (spit path (:out rendered))
      (:out rendered))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-projection-lifecycle-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def checkout (io/file scratch "checkout"))
(def source-dir (io/file checkout "src"))
(def target (io/file source-dir "known.bclj"))
(def outside (io/file scratch "outside.bclj"))
(def log-path (str (io/file scratch "code.framlog")))
(def checkout-root (.getCanonicalPath checkout))
(def fram-root (.getCanonicalPath (io/file ".")))
(def space "projection-lifecycle-test")
(def beagle
  (or (System/getenv "FRAM_BEAGLE")
      (str (System/getProperty "user.home") "/code/beagle/main/bin/beagle")))

(.mkdirs source-dir)
(spit target "OLD-COMPLETE")
(spit outside "OUTSIDE-UNCHANGED")

(try
  (let [before-files (set (map #(.getCanonicalPath %) (file-seq scratch)))
        rejected
        (lifecycle/publish-checked-projection!
         {:commit-outcome {:type :precommit-rejection
                           :module "known"
                           :rejection {:code "beagle-overlay-rejected"}}
          :registered-root checkout-root
          :registered-path "../outside.bclj"
          :checked-bytes (.getBytes "MUST-NOT-WRITE" "UTF-8")})]
    (check! "precommit rejection is typed as graph-unchanged and projection-not-written"
            (and (= :precommit-rejected (:outcome rejected))
                 (= :unchanged (:graph-state rejected))
                 (= :not-written (:projection-state rejected))))
    (check! "precommit rejection touches no file or temp path anywhere"
            (and (= "OLD-COMPLETE" (slurp target))
                 (= "OUTSIDE-UNCHANGED" (slurp outside))
                 (= before-files
                    (set (map #(.getCanonicalPath %) (file-seq scratch)))))))

  (let [cause
        (try
          (lifecycle/resolve-projection-path!
           checkout-root "../outside.bclj")
          nil
          (catch Throwable error (ex-data error)))]
    (check! "path traversal outside the registered root is rejected"
            (= :projection-path-outside-root (:type cause)))
    (check! "out-of-root confinement rejection leaves the outside file unchanged"
            (= "OUTSIDE-UNCHANGED" (slurp outside))))

  (let [move-calls (atom 0)
        err (java.io.StringWriter.)
        result
        (binding [lifecycle/*before-atomic-move*
                  (fn [_]
                    (swap! move-calls inc)
                    (throw (ex-info "simulated process stop before rename"
                                    {:type :simulated-crash})))
                  *err* err]
          (lifecycle/publish-checked-projection!
           {:commit-outcome {:type :committed
                             :module "known"
                             :committed-version 5
                             :proof {:ok true :id "receipt-1"}}
            :registered-root checkout-root
            :registered-path "src/known.bclj"
            :checked-bytes (.getBytes "NEW-COMPLETE" "UTF-8")}))]
    (check! "crash after commit and before rename is typed projection-stale"
            (and (= :committed-projection-stale (:outcome result))
                 (= :committed (:graph-state result))
                 (= :repair-needed (:projection-state result))))
    (check! "postcommit stale outcome forbids graph retry and names repair only"
            (and (false? (:automatic-retry? result))
                 (= :repair-projection-only (:retry result))
                 (= {:verb :repair-projection :module "known"}
                    (:repair result))))
    (check! "postcommit stale outcome is reported loudly exactly once"
            (and (= 1 @move-calls)
                 (str/includes? (str err) "PROJECTION STALE")
                 (str/includes? (str err) "do not retry the graph commit")))
    (check! "crash before atomic rename leaves the old complete bytes, never a torn target"
            (= "OLD-COMPLETE" (slurp target)))
    (check! "failed atomic publication leaves no temp residue"
            (empty? (filter #(str/starts-with? (.getName %) ".fram-projection-")
                            (file-seq checkout)))))

  (let [result
        (lifecycle/publish-checked-projection!
         {:commit-outcome {:type :committed
                           :module "known"
                           :committed-version 6
                           :proof {:ok true :id "receipt-2"}}
          :registered-root checkout-root
          :registered-path "src/known.bclj"
          :checked-bytes (.getBytes "NEW-COMPLETE" "UTF-8")})]
    (check! "successful postcommit publication is typed as committed and published"
            (and (= :committed-projection-published (:outcome result))
                 (= :committed (:graph-state result))
                 (= :published (:projection-state result))))
    (check! "atomic rename installs the complete checked bytes"
            (= "NEW-COMPLETE" (slurp target))))

  (let [canonical
        (canonical-source!
         beagle
         "#lang beagle/clj\n(ns known)\n(defn answer [] 42)\n"
         (str target))
        ingest
        (shell/sh "env" (str "FRAM_BEAGLE=" beagle)
                  (str (io/file fram-root "bin/fram-ingest-code"))
                  "src/known.bclj"
                  "--root" "src"
                  "--out" log-path
                  "--space-id" space
                  :dir checkout-root)
        port (free-port)
        server (when (zero? (:exit ingest))
                 (future (server/serve! port log-path space :active)))]
    (try
      (check! "repair fixture graph is served"
              (some? (and server
                          (eventually
                           #(rt/native-call! port space :rpc/version
                                             framrpc/rpc-unit
                                             nil nil nil)))))
      (spit target "STALE-COMPLETE")
      (let [stale (lifecycle/projection-status!
                   port space checkout-root "known" beagle)
            repaired (lifecycle/repair-projection!
                      port space checkout-root "known" beagle)
            first-bytes (java.nio.file.Files/readAllBytes (.toPath target))
            repaired-again (lifecycle/repair-projection!
                            port space checkout-root "known" beagle)
            second-bytes (java.nio.file.Files/readAllBytes (.toPath target))
            current (lifecycle/projection-status!
                     port space checkout-root "known" beagle)]
        (check! "current-graph comparison detects a stale registered projection"
                (and (= :stale (:projection-state stale))
                     (:repair-needed? stale)))
        (check! "repair verb publishes from the current cited graph version"
                (and (= :projection-repaired (:outcome repaired))
                     (= :published (:projection-state repaired))
                     (integer? (:graph-version repaired))))
        (check! "stale repair round-trips byte-identically to the stage-1 projector"
                (and (= canonical (String. ^bytes first-bytes "UTF-8"))
                     (java.util.Arrays/equals first-bytes second-bytes)
                     (= :projection-repaired (:outcome repaired-again))))
        (check! "repaired projection is current and no longer repair-needed"
                (and (= :current (:projection-state current))
                     (false? (:repair-needed? current)))))
      (finally
        ;; serve! blocks in accept, which ignores interrupts: only shutdown!
        ;; stops the non-daemon connection workers, so cancelling can't exit.
        (when server
          (server/shutdown!)
          (deref server 3000 nil)))))
  (finally
    (delete-tree! scratch)))

(shutdown-agents)

(let [failures (remove second @checks)]
  (if (seq failures)
    (do
      (println (str "\nprojection lifecycle: " (count failures) " FAILED"))
      (System/exit 1))
    (println (str "\nprojection lifecycle: " (count @checks) "/"
                  (count @checks) " PASS"))))
