(require '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[fram.candidate-transformer :as transformer]
         '[fram.code-commit-gate :as gate]
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
      (spit path (:out rendered)))
    (io/delete-file raw true)
    (io/delete-file facts true)))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-native-code-gate-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def checkout-root (.getCanonicalPath scratch))
(def fram-root (.getCanonicalPath (io/file ".")))
(def source-root (io/file scratch "src"))
(def source-path (str (io/file source-root "gate_fixture.bclj")))
(def log-path (str (io/file scratch "code.framlog")))
(def space "native-code-gate-test")
(def port (free-port))
(def beagle-home
  (or (System/getenv "BEAGLE_HOME")
      (str (System/getProperty "user.home") "/code/beagle/main")))
(def beagle
  (or (System/getenv "FRAM_BEAGLE")
      (str beagle-home "/bin/beagle")))
(def racket
  (or (System/getenv "FRAM_EDIT_VERIFIER_RACKET")
      (System/getenv "FRAM_RACKET")
      "/run/current-system/sw/bin/racket"))

(.mkdirs source-root)
(canonical-source!
 beagle
 (str "#lang beagle/clj\n"
      "(ns gate.fixture)\n"
      "(defn alpha [] Int 0)\n"
      "(defn beta [] Int 1)\n")
 source-path)

(def ingest
  (shell/sh "env" (str "FRAM_BEAGLE=" beagle)
            (str (io/file fram-root "bin/fram-ingest-code"))
            "src/gate_fixture.bclj"
            "--root" "src"
            "--out" log-path
            "--space-id" space
            :dir checkout-root))
(def server
  (when (zero? (:exit ingest))
    (future (server/serve! port log-path space :active))))
(def gate-options
  {:verifier (str (io/file fram-root "bin/fram-edit-verifier"))
   :verifier-env
   {"BEAGLE_HOME" beagle-home
    "FRAM_EDIT_VERIFIER_RACKET" racket
    "FRAM_EDIT_VERIFIER_OVERLAY_CHECK"
    (str beagle-home "/beagle-lib/private/facts-check-overlay.rkt")}})

(defn version! []
  (-> (rt/native-call! port space :rpc/version
                       framrpc/rpc-unit nil nil nil)
      rt/require-native-success!
      t/rpcresponse-served-version))

(try
  (check! "native ingest creates the scratch code corpus"
          (zero? (:exit ingest)))
  (check! "scratch native server starts"
          (some? (and server (eventually version!))))
  (when server
    (let [before
          (code-reader/read-module-snapshot!
           port space checkout-root "gate_fixture")
          outcome
          (gate/gate-and-commit!
           port space checkout-root "gate_fixture"
           [{:name "alpha" :body 42}
            {:name "beta" :body '(+ 40 2)}]
           gate-options)]
      (check! "reader snapshot feeds a successful sealed batch commit"
              (= :committed (:type outcome)))
      (check! "commit uses the reader's pinned base version"
              (= (get-in before [:snapshot :version])
                 (:base-version outcome)))
      (check! "one batch advances the native graph exactly once"
              (= (inc (:base-version outcome))
                 (:committed-version outcome)))
      (check! "committed triples equal the candidate net delta exactly"
              (= {:asserts (get-in outcome [:candidate :asserts])
                  :retracts (get-in outcome [:candidate :retracts])}
                 (:committed-delta outcome))))

    (let [bumped? (atom false)
          bump-response (atom nil)
          options
          (assoc gate-options
                 :before-commit
                 (fn [{:keys [attempt base]}]
                   (when (and (zero? attempt)
                              (compare-and-set! bumped? false true))
                     (let [bump
                           (transformer/multi-set-body
                            base
                            [{:name "alpha" :body 100}
                             {:name "beta" :body 101}])]
                       (reset! bump-response
                               (gate/commit-candidate!
                                port space bump))))))
          outcome
          (gate/gate-and-commit!
           port space checkout-root "gate_fixture"
           [{:name "alpha" :body 7}
            {:name "beta" :body 8}]
           options)]
      (check! "concurrent bump wins before the stale batch"
              (and @bump-response
                   (nil? (rt/native-error-code @bump-response))))
      (check! "version conflict recomputes and then commits"
              (and (= :committed (:type outcome))
                   (= 1 (:conflicts outcome))
                   (= 2 (count (:attempts outcome)))))
      (check! "recomputed candidate mints above the concurrent allocation"
              (< (:next-node-int (first (:attempts outcome)))
                 (:next-node-int (second (:attempts outcome)))))
      (check! "conflict winner still commits its exact recomputed delta"
              (= {:asserts (get-in outcome [:candidate :asserts])
                  :retracts (get-in outcome [:candidate :retracts])}
                 (:committed-delta outcome))))

    (let [version-before (version!)
          facts-before (:facts
                        (gate/transformer-snapshot
                         (code-reader/read-module-snapshot!
                          port space checkout-root "gate_fixture")))
          rejected
          (gate/gate-and-commit!
           port space checkout-root "gate_fixture"
           [{:name "alpha" :body "not-an-int"}
            {:name "beta" :body "also-not-an-int"}]
           gate-options)
          version-after (version!)
          facts-after (:facts
                       (gate/transformer-snapshot
                        (code-reader/read-module-snapshot!
                         port space checkout-root "gate_fixture")))]
      (check! "failing sealed Beagle check is a typed precommit rejection"
              (and (= :precommit-rejection (:type rejected))
                   (= "beagle-overlay-rejected"
                      (get-in rejected [:rejection :code]))))
      (check! "failing Beagle check commits nothing"
              (and (= version-before version-after)
                   (= facts-before facts-after)))))
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
      (println (str "\nnative code commit gate: "
                    (count failures) " FAILED of " (count @checks)))
      (System/exit 1))
    (println (str "\nnative code commit gate: "
                  (count @checks) "/" (count @checks) " PASS"))))
