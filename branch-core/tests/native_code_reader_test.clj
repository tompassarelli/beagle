(require '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str]
         '[fram.code-reader :as code-reader]
         '[fram.rt :as rt]
         '[fram.types :as t])

(load-file "server.clj")

(def checks (atom []))
(defn check! [label value]
  (println (str (if value "[PASS] " "[FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond
        value value
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
    "fram-native-code-reader-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def checkout-root (.getCanonicalPath scratch))
(def fram-root (.getCanonicalPath (io/file ".")))
(def source-root (io/file scratch "src"))
(def known-path (str (io/file source-root "known.bclj")))
(def collision-path (str (io/file source-root "knownx.bclj")))
(def log-path (str (io/file scratch "code.framlog")))
(def space "native-code-reader-test")
(def beagle
  (or (System/getenv "FRAM_BEAGLE")
      (str (System/getProperty "user.home") "/code/beagle/main/bin/beagle")))

(.mkdirs source-root)
(def known-source
  (canonical-source!
   beagle
   "#lang beagle/clj\n(ns known)\n(defn answer [] 42)\n"
   known-path))
(canonical-source!
 beagle
 "#lang beagle/clj\n(ns knownx)\n(defn not-known [] 7)\n"
 collision-path)

(def ingest
  (shell/sh "env" (str "FRAM_BEAGLE=" beagle)
            (str (io/file fram-root "bin/fram-ingest-code"))
            "src/known.bclj" "src/knownx.bclj"
            "--root" "src"
            "--out" log-path
            "--space-id" space
            :dir checkout-root))
(def port (free-port))
(def server
  (when (zero? (:exit ingest))
    (future (server/serve! port log-path space :active))))

(try
  (check! "native ingest creates the scratch code corpus"
          (zero? (:exit ingest)))
  (check! "native server serves the ingested corpus"
          (some? (and server
                      (eventually
                       #(rt/native-call! port space :rpc/version
                                         framrpc/rpc-unit
                                         nil nil nil)))))
  (when server
    (let [module-snapshot
          (code-reader/read-module-snapshot!
           port space checkout-root "known" 20)
          citation (:snapshot module-snapshot)
          subjects (mapv t/triple-t1 (:triples module-snapshot))
          projected (code-reader/project-module-edn module-snapshot)
          rendered (code-reader/render-module! beagle module-snapshot)]
      (check! "page drain spans multiple FRAMRPC responses"
              (> (:pages module-snapshot) 1))
      (check! "snapshot cites the drained graph version"
              (= 2 (:version citation)))
      (check! "snapshot resolves the registered module root path"
              (= (.getCanonicalPath (io/file known-path)) (:root citation)))
      (check! "module filter admits only exact @known# subjects"
              (every? #(str/starts-with? % "@known#") subjects))
      (check! "module filter excludes the @knownx# collision"
              (not-any? #(str/starts-with? % "@knownx#") subjects))
      (check! "projected EDN cites the resolved root"
              (str/starts-with? projected (str "@file " (:root citation) "\n")))
      (check! "projected EDN uses numeric view coordinates for minted identities"
              (and (re-find #"(?m)^\[[0-9]+ \"kind\"" projected)
                   (not (str/includes? projected "@known#"))))
      (check! "rendered Beagle text preserves its snapshot citation"
              (= citation (:snapshot rendered)))
      (check! "graph projection is byte-identical to the known module source"
              (= known-source (:source rendered)))
      (check! "reader accepts the derived maximum page limit"
              (some? (code-reader/read-corpus-snapshot!
                      port space
                      (- framrpc/term-codec-v1-depth-limit 3))))
      (check! "reader rejects page limit above the derived maximum"
              (try
                (code-reader/read-corpus-snapshot!
                 port space
                 (inc (- framrpc/term-codec-v1-depth-limit 3)))
                false
                (catch clojure.lang.ExceptionInfo e
                  (and (= :invalid-code-snapshot (:type (ex-data e)))
                       (str/includes? (.getMessage e) "page limit must be between")))))))
  (finally
    ;; serve! blocks in accept, which ignores interrupts: only shutdown! stops
    ;; the non-daemon connection workers, so cancelling the future can't exit.
    (when server
      (server/shutdown!)
      (deref server 3000 nil))
    (delete-tree! scratch)))

(shutdown-agents)

(let [failures (remove second @checks)]
  (if (seq failures)
    (do
      (println (str "\nnative code reader: " (count failures) " FAILED"))
      (System/exit 1))
    (println (str "\nnative code reader: " (count @checks) "/"
                  (count @checks) " PASS"))))
