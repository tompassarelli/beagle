(require '[babashka.process :as process]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.set :as set]
         '[clojure.string :as str]
         '[store.code-commit-gate :as gate]
         '[store.code-reader :as code-reader]
         '[store.rt :as rt]
         '[store.types :as t])

(def e2e-args *command-line-args*)
(binding [*command-line-args* []]
  (load-file "server.clj"))

(def checks (atom []))
(def program-version-before (atom nil))
(def program-view-after (atom nil))
(defn check! [label value]
  (println (str (if value "[PASS] " "[FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(defn eventually [f]
  (loop [attempt 0]
    (let [value (try (f) (catch Throwable _ nil))]
      (cond value value
            (>= attempt 240) nil
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

(defn parse-replies [output]
  (into {}
        (keep (fn [line]
                (when-not (str/blank? line)
                  (let [reply (json/parse-string line true)]
                    (when (contains? reply :id) [(:id reply) reply])))))
        (str/split-lines output)))

(defn call-value [reply]
  (json/parse-string (get-in reply [:result :content 0 :text]) true))

(defn run-control [runtime launch-env requests]
  (let [input (str (str/join "\n" (map json/generate-string requests)) "\n")]
    (process/shell {:in input :out :string :err :string :continue true
                    :extra-env launch-env}
                   runtime "mcp")))

(defn version! [port space]
  (-> (rt/native-call! port space :rpc/version
                       rpc/rpc-unit nil nil nil)
      rt/require-native-success!
      t/rpcresponse-served-version))

(def runtime
  (or (first e2e-args)
      (System/getenv "BEAGLE_STORE_GRAPH_CONTROL_RUNTIME")))
(when (str/blank? runtime)
  (binding [*out* *err*]
    (println "usage: bb -cp out tests/graph_control_mcp_e2e_test.clj /nix/store/.../bin/beagle-store-graph-edit-runtime"))
  (System/exit 2))

(def root (.getCanonicalPath (io/file ".")))
(def store-root
  (or (System/getenv "BEAGLE_STORE_GRAPH_E2E_BEAGLE_STORE_ROOT") root))
(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-graph-control-e2e-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def checkout-root (.getCanonicalPath scratch))
(def source-root (io/file scratch "src"))
(def source-path (io/file source-root "fixture.bclj"))
(def code-log (str (io/file scratch ".store/code.log")))
(def space "graph-control-e2e")
(def port (free-port))
(def beagle
  (or (System/getenv "BEAGLE_STORE_GRAPH_E2E_BEAGLE")
      (System/getenv "BEAGLE_STORE_BEAGLE")
      (str (System/getProperty "user.home") "/code/beagle/main/bin/beagle")))
(def bb
  (or (System/getenv "BEAGLE_STORE_GRAPH_E2E_BB") "bb"))
(def beagle-facts
  (str (io/file (.getParentFile (io/file beagle)) "beagle-facts")))
(def corpus (io/file scratch ".store/corpus.facts"))

(.mkdirs source-root)
(canonical-source!
 beagle
 (str "#lang beagle/clj\n"
      "(ns fixture)\n"
      "(defn alpha [] Int 0)\n"
      ;; beta calls alpha so the program reads have one real resolved edge;
      ;; a third definition would push beagle-store-code-status past its preflight cap.
      "(defn beta [] Int (alpha))\n")
 (str source-path))

(def ingest
  (shell/sh bb (str (io/file store-root "bin/beagle-store-ingest-code"))
            "src/fixture.bclj" "--root" "src"
            "--out" code-log "--space-id" space
            :env (assoc (into {} (System/getenv)) "BEAGLE_STORE_BEAGLE" beagle)
            :dir checkout-root))
(def corpus-emit
  (when (zero? (:exit ingest))
    (let [result (shell/sh beagle-facts "src" :dir checkout-root)]
      (when (zero? (:exit result))
        (.mkdirs (.getParentFile corpus))
        (spit corpus (:out result)))
      result)))
(def server
  (when (zero? (:exit ingest))
    (future (server/serve! port code-log space :active))))

(def launch-env
  {"NORTH_STORE_AUTHORITY_INSTANCE_ID" "123e4567-e89b-42d3-a456-426614174000"
   "NORTH_STORE_AUTHORITY_LEASE_ID" "123e4567-e89b-42d3-b456-426614174001"
   "NORTH_STORE_AUTHORITY_LEASE_EPOCH" "7"
   "NORTH_STORE_RUNTIME_CLOSURE_DIGEST"
   "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
   "NORTH_STORE_CHECKOUT_ROOT" checkout-root
   "NORTH_STORE_SOURCE_ROOT" (.getCanonicalPath source-root)
   "NORTH_STORE_CODE_LOG" (.getCanonicalPath (io/file code-log))
   "NORTH_STORE_CODE_PORT" (str port)})

(try
  (when-not (zero? (:exit ingest))
    (binding [*out* *err*] (println (:err ingest))))
  (check! "N2.6a ingests the scratch fixture into native FRAMLOG"
          (zero? (:exit ingest)))
  (check! "scratch native server serves the ingested corpus"
          (some? (and server (eventually #(version! port space)))))
  (when server
    (spit (io/file scratch ".mcp.json")
          (json/generate-string
            {:mcpServers
            {:beagle-store {:command (str (io/file store-root "bin/beagle-store-mcp"))
                    :args []
                    :env {:BEAGLE_STORE_SPACE_ID space :BEAGLE_STORE_SERVER_PORT (str port)
                          :BEAGLE_STORE_LOG code-log}}
             :beagle-store-graph-control {:command runtime :args ["mcp"]
                                  :env launch-env}}}))
    (let [status (shell/sh (str (io/file store-root "bin/beagle-store-code-status"))
                           checkout-root)]
      (check! "real sealed preflight earns beagle-store-code-status Level 3"
              (and (zero? (:exit status))
                   (str/starts-with? (:out status) "level=3 "))))

    (check! "the resolved reference corpus is emitted for the scratch checkout"
            (and corpus-emit (zero? (:exit corpus-emit)) (.isFile corpus)))

    ;; Every launch pays one full sealed preflight, so the reads that must
    ;; observe the pre-edit corpus ride in the same process as the edit,
    ;; ahead of it in request order.
    (let [seed (run-control
                runtime launch-env
                [{:jsonrpc "2.0" :id 20 :method "tools/call"
                  :params {:name "read_definition"
                           :arguments {:name "alpha"}}}])
          seed-reply (get (parse-replies (:out seed)) 20)
          alpha (call-value seed-reply)
          alpha-identity (:semanticIdentity alpha)
          before (gate/transformer-snapshot
                  (code-reader/read-module-snapshot!
                   port space checkout-root "fixture"))
          run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 21 :method "tools/call"
                 :params {:name "find_references"
                          :arguments {:semanticIdentity alpha-identity
                                      :direction "inbound"}}}
                {:jsonrpc "2.0" :id 22 :method "tools/call"
                 :params {:name "inspect_program"
                          :arguments
                          {:requests
                           [{:tag "history" :request "occurrence_history"
                             :arguments {:semanticIdentity alpha-identity}}
                            {:tag "context" :request "program_context"
                             :arguments {:semanticIdentity alpha-identity}}]}}}
                {:jsonrpc "2.0" :id 1 :method "tools/list"}
                {:jsonrpc "2.0" :id 2 :method "tools/call"
                 :params {:name "multi-set-body"
                          :arguments
                          {:module "fixture"
                           :edits [{:name "alpha" :body "42"}
                                   {:name "beta" :body "(+ 40 2)"}]}}}])
          replies (parse-replies (:out run))
          references (call-value (get replies 21))
          caller (first (:references references))
          batch (call-value (get replies 22))
          result (call-value (get replies 2))
          after-snapshot (code-reader/read-module-snapshot!
                          port space checkout-root "fixture")
          after (gate/transformer-snapshot after-snapshot)
          actual-asserts (set/difference (:facts after) (:facts before))
          actual-retracts (set/difference (:facts before) (:facts after))
          candidate-asserts (set (get-in result [:candidateDelta :asserts]))
          candidate-retracts (set (get-in result [:candidateDelta :retracts]))
          rendered (code-reader/render-module! beagle after-snapshot)]
      (when-not (zero? (:exit run))
        (binding [*out* *err*] (println (:err run))))
      (reset! program-version-before (:logicalVersion alpha))
      (check! "an advertised program read dispatches to its real handler"
              (and (not (get-in seed-reply [:result :isError]))
                   (= "ok" (:outcome alpha))
                   (= "alpha" (get-in alpha [:definition :name]))
                   (= "fixture" (get-in alpha [:definition :module]))
                   (seq (get-in alpha [:definition :root-facts]))
                   (str/starts-with? (str alpha-identity) "src/fixture.bclj#")
                   (some? (re-matches #"sha256:[0-9a-f]{64}"
                                      (str (:logicalVersion alpha))))))
      (check! "find_references answers with the resolved inbound caller"
              (and (not (get-in replies [21 :result :isError]))
                   (= "ok" (:outcome references))
                   (= 1 (count (:references references)))
                   (= "calls" (:relation caller))
                   (not= alpha-identity (:semanticIdentity caller))
                   (str/starts-with? (str (:semanticIdentity caller))
                                     "src/fixture.bclj#")
                   (= (:logicalVersion alpha) (:logicalVersion references))))
      (check! "inspect_program runs every child against one pinned snapshot"
              (and (= "ok" (:outcome batch))
                   (= ["history" "context"] (mapv :tag (:children batch)))
                   (= ["ok" "ok"] (mapv :outcome (:children batch)))
                   (= [(:logicalVersion alpha) (:logicalVersion alpha)]
                      (mapv :logicalVersion (:children batch)))
                   (seq (:occurrences (first (:children batch))))))
      (check! "sealed MCP preserves inspection tools beside the widened graph-control catalog"
              (= ["read_definition" "find_references" "trace_impact"
                  "occurrence_history" "program_context" "inspect_program"
                  "multi-set-body" "add-def" "replace-def"]
                 (mapv :name (get-in replies [1 :result :tools]))))
      (check! "multi-set-body completes commit and checked publication"
              (and (not (get-in replies [2 :result :isError]))
                   (= "committed-projection-published" (:outcome result))))
      (check! "committed triples match the MCP candidate delta"
              (and (= candidate-asserts actual-asserts)
                   (= candidate-retracts actual-retracts)
                   (= (:candidateDelta result) (:committedDelta result))))
      (check! "projection file is republished byte-correct from committed triples"
              (= (:source rendered) (slurp source-path)))
      (reset! program-view-after (get-in result [:programView :logical-version]))
      (check! "the checked publication materializes an advanced program view"
              (and (some? (re-matches #"sha256:[0-9a-f]{64}"
                                      (str @program-view-after)))
                   (= @program-version-before
                      (get-in result [:programView :previous-version]))
                   (not= @program-version-before @program-view-after)
                   (= (:committedVersion result)
                      (str (get-in result [:programView
                                           :source-graph-version])))
                   (let [invalidated (get-in result [:programView
                                                     :invalidated-identities])]
                     (and (<= 2 (count invalidated))
                          (every? #(str/starts-with? (str %)
                                                     "src/fixture.bclj#")
                                  invalidated))))))

    (let [run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 23 :method "tools/call"
                 :params {:name "read_definition"
                          :arguments {:name "alpha"}}}
                {:jsonrpc "2.0" :id 10 :method "tools/call"
                 :params {:name "add-def"
                          :arguments
                          {:module "fixture"
                           :form "(defrecord Point [(x Int) (y Int)])"}}}])
          replies (parse-replies (:out run))
          alpha (call-value (get replies 23))
          reply (get replies 10)
          result (call-value reply)
          after-snapshot (code-reader/read-module-snapshot!
                          port space checkout-root "fixture")
          rendered (code-reader/render-module! beagle after-snapshot)]
      (check! "add-def adds a top-level defrecord through checked publication"
              (and (not (get-in reply [:result :isError]))
                   (= "committed-projection-published" (:outcome result))))
      (check! "add-def republishes the committed defrecord projection"
              (and (str/includes? (:source rendered) "(defrecord Point")
                   (= (:source rendered) (slurp source-path))))
      (check! "program reads observe the materialized post-commit version"
              (and (= "ok" (:outcome alpha))
                   (= @program-view-after (:logicalVersion alpha))
                   (not= @program-version-before (:logicalVersion alpha)))))

    (let [run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 11 :method "tools/call"
                 :params {:name "replace-def"
                          :arguments
                          {:module "fixture"
                           :form "(defrecord Point [(x Int) (y Int) (label String)])"}}}])
          reply (get (parse-replies (:out run)) 11)
          result (call-value reply)
          after-snapshot (code-reader/read-module-snapshot!
                          port space checkout-root "fixture")
          rendered (code-reader/render-module! beagle after-snapshot)]
      (check! "replace-def replaces an existing top-level definition through checked publication"
              (and (not (get-in reply [:result :isError]))
                   (= "committed-projection-published" (:outcome result))))
      (check! "replace-def republishes one updated definition at the original position"
              (and (= 1 (count (re-seq #"\(defrecord Point" (:source rendered))))
                   (str/includes? (:source rendered) "(label String)")
                   (= (:source rendered) (slurp source-path)))))

    (let [run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 24 :method "tools/call"
                 :params {:name "add-def"
                          :arguments
                          {:module "fixture"
                           :form "(defn typed-value [(value Int)] Int value)"}}}])
          reply (get (parse-replies (:out run)) 24)
          result (call-value reply)
          rendered (code-reader/render-module!
                    beagle
                    (code-reader/read-module-snapshot!
                     port space checkout-root "fixture"))]
      (check! "add-def accepts current structural annotations through the sealed parser"
              (and (not (get-in reply [:result :isError]))
                   (= "committed-projection-published" (:outcome result))
                   (str/includes? (:source rendered)
                                  "[(value Int)] Int"))))

    (let [version-before (version! port space)
          facts-before (:facts
                        (gate/transformer-snapshot
                         (code-reader/read-module-snapshot!
                          port space checkout-root "fixture")))
          bytes-before (java.nio.file.Files/readAllBytes (.toPath source-path))
          run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 12 :method "tools/call"
                 :params {:name "add-def"
                          :arguments
                          {:module "fixture"
                           :form "(defrecord Point [(x Int)])"}}}])
          reply (get (parse-replies (:out run)) 12)
          result (call-value reply)
          version-after (version! port space)
          facts-after (:facts
                       (gate/transformer-snapshot
                        (code-reader/read-module-snapshot!
                         port space checkout-root "fixture")))
          bytes-after (java.nio.file.Files/readAllBytes (.toPath source-path))]
      (check! "add-def rejects an existing top-level definition"
              (and (get-in reply [:result :isError])
                   (= "definition-already-exists" (:type result))))
      (check! "failing add-def commits no triples and publishes no bytes"
              (and (= version-before version-after)
                   (= facts-before facts-after)
                   (java.util.Arrays/equals bytes-before bytes-after))))

    (let [version-before (version! port space)
          facts-before (:facts
                        (gate/transformer-snapshot
                         (code-reader/read-module-snapshot!
                          port space checkout-root "fixture")))
          bytes-before (java.nio.file.Files/readAllBytes (.toPath source-path))
          run (run-control
               runtime launch-env
               [{:jsonrpc "2.0" :id 3 :method "tools/call"
                 :params {:name "multi-set-body"
                          :arguments
                          {:module "fixture"
                           :edits [{:name "alpha" :body "\"bad\""}
                                   {:name "beta" :body "\"worse\""}]}}}])
          reply (get (parse-replies (:out run)) 3)
          result (call-value reply)
          version-after (version! port space)
          facts-after (:facts
                       (gate/transformer-snapshot
                        (code-reader/read-module-snapshot!
                         port space checkout-root "fixture")))
          bytes-after (java.nio.file.Files/readAllBytes (.toPath source-path))]
      (check! "failing sealed edit returns a typed precommit rejection"
              (and (get-in reply [:result :isError])
                   (= "precommit-rejected" (:outcome result))))
      (check! "failing edit commits no triples and publishes no bytes"
              (and (= version-before version-after)
                   (= facts-before facts-after)
                   (java.util.Arrays/equals bytes-before bytes-after)))))
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
    (do (println "\ngraph-control MCP E2E:" (count failures)
                 "FAILED of" (count @checks))
        (System/exit 1))
    (do (println "\ngraph-control MCP E2E:" (count @checks) "/"
                 (count @checks) "PASS")
        (System/exit 0))))
