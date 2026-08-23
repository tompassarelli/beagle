;; End-to-end regressions for the graph-canonical warm MCP adapter.
;;
;; Proves that JSON form/body strings are parsed as EDN datums before :edit-min,
;; and that a dotted module id renders to its registered nested `file` path rather
;; than to BEAGLE_STORE_SRC/<dotted-module>.bclj. Also proves same-name add-def replaces
;; its live wrapper form and path confinement rejects before mutation.
;;
;; Run from the Beagle Store root:
;;   bb -cp out tests/mcp_warm_graph_edit_regression_test.clj
(require '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.rt :as rt])

(def root (.getCanonicalPath (io/file (System/getProperty "user.dir"))))
(def home (System/getProperty "user.home"))
(def beagle-home (or (System/getenv "BEAGLE_HOME") (str home "/code/beagle")))
(def beagle-bin (or (System/getenv "BEAGLE_STORE_BEAGLE") (str beagle-home "/bin/beagle")))
(def racket-bin
  (or (System/getenv "BEAGLE_STORE_RACKET")
      (let [r (try (p/sh {:out :string :err :string}
                         "direnv" "exec" beagle-home "which" "racket")
                   (catch Throwable _ nil))]
        (when (and r (zero? (:exit r))) (str/trim (:out r))))))

(when (or (str/blank? racket-bin)
          (not (.canExecute (io/file beagle-bin))))
  (println "SKIP — the flake-pinned Beagle/Racket toolchain is unavailable")
  (System/exit 0))

(def tmp (.getCanonicalPath
          (.toFile (java.nio.file.Files/createTempDirectory
                    "beagle-store-mcp-warm-regression"
                    (make-array java.nio.file.attribute.FileAttribute 0)))))
(def project (str tmp "/project"))
(def nested-dir (str project "/src/plangrep"))
(def source-file (str nested-dir "/model.bclj"))
(def root-level-artifact (str project "/src.plangrep.model.bclj"))
(def code-log (str project "/.store/code.log"))
(def graph-registry (str tmp "/graph-upstream-files"))
(run! #(.mkdirs (io/file %)) [nested-dir (str project "/.store")])

(spit source-file
      (str "#lang beagle/clj\n"
           "(ns src.plangrep.model)\n"
           "(defn base [] Int 1)\n"
           "(defn semantic-index-accepted? [(schema-version String)] Bool\n"
           "  (= schema-version \"firn-index/v1\"))\n"))
(spit graph-registry "/stale/pre-container/model.bclj\n")

(def checks (atom []))
(defn check! [label value]
  (let [ok (boolean value)]
    (swap! checks conj [label ok])
    (println (str "  [" (if ok "PASS" "FAIL") "] " label))
    ok))

(def base-tool-env
  {"BEAGLE_HOME" beagle-home
   "BEAGLE_STORE_RACKET" racket-bin
   "BEAGLE_STORE_OUT" (str root "/out")
   "BEAGLE_STORE_BIN" (str root "/bin")
   "BEAGLE_STORE_RESOLVE" (str root "/out/resolve.clj")
   "BEAGLE_STORE_BEAGLE" beagle-bin
   "BEAGLE_STORE_CHECK_EMIT" (str beagle-home "/beagle-lib/private/facts-check-emit.rkt")
   "BEAGLE_STORE_BUILD_ALL" (str beagle-home "/bin/beagle-build-all")})

(def ingest
  (p/shell {:dir root :out :string :err :string :continue true
            :extra-env base-tool-env}
           "bin/beagle-store-ingest-code" source-file "--root" project "--out" code-log
           "--space-id" "warm-regression"))
(when-not (zero? (:exit ingest))
  (println "ABORT — fixture ingest failed\n" (:out ingest) (:err ingest))
  (System/exit 1))

(defn free-port []
  (with-open [socket (java.net.ServerSocket. 0)] (.getLocalPort socket)))

(def port (free-port))
(.mkdirs (io/file project ".codex"))
(spit (str project "/.codex/config.toml")
      (str "[mcp_servers.beagle-store]\n"
           "command = " (pr-str (str root "/bin/beagle-store-mcp")) "\n"
           "args = []\n\n"
           "[mcp_servers.beagle-store.env]\n"
           "BEAGLE_STORE_SPACE_ID = \"warm-regression\"\n"
           "BEAGLE_STORE_SERVER_PORT = " (pr-str (str port)) "\n"
           "BEAGLE_STORE_LOG = " (pr-str code-log) "\n"))
;; The edit gate is launch-sealed: a server started without BEAGLE_STORE_EDIT_VERIFIER
;; rejects every graph edit as verification-unavailable.
(def daemon
  (p/process {:dir root
              :out (str tmp "/daemon.log") :err (str tmp "/daemon.log")
              :extra-env (merge base-tool-env
                                {"BEAGLE_STORE_REQUIRE_LOG_FENCE" "1"
                                 "BEAGLE_STORE_EDIT_VERIFIER" (str root "/bin/beagle-store-edit-verifier")
                                 "BEAGLE_STORE_EDIT_VERIFIER_RACKET" racket-bin
                                 ;; before/after version comparisons need a quiescent log:
                                 ;; post-boot snapshot metadata is a legitimate async writer.
                                 "BEAGLE_STORE_SNAPSHOT_BOOT" "0"})}
             "bin/beagle-store-server" "serve" (str port) code-log "warm-regression"))

(defn database [req] (rt/database-request-for-log port code-log req))
;; Sized for a JVM server boot, not for a quiet machine: readiness is the only
;; thing polled here, and a 10s budget flakes whenever the box is loaded.
(defn eventually [f]
  (loop [remaining 2400]
    (cond
      (try (f) (catch Throwable _ false)) true
      (zero? remaining) false
      :else (do (Thread/sleep 25) (recur (dec remaining))))))

(def mcp-env
  (merge base-tool-env
         {"BEAGLE_STORE_FLIP" "1"
          "BEAGLE_STORE_GRAPH_EDIT" "1"
          "BEAGLE_STORE_SERVER_PORT" (str port)
          "BEAGLE_STORE_CODE_PORT" (str port)
          "BEAGLE_STORE_SERVER_READ_TIMEOUT_MS" "180000"
          "BEAGLE_STORE_CODE_LOG" code-log
          "BEAGLE_STORE_LOG" code-log
          "BEAGLE_STORE_THREADS" project
          "BEAGLE_STORE_SRC" project}))

(defn mcp-run [env id tool arguments]
  (let [request (json/generate-string
                 {:jsonrpc "2.0" :id id :method "tools/call"
                  :params {:name tool :arguments arguments}})
        result (p/shell {:dir root :in (str request "\n")
                         :out :string :err :string :continue true :extra-env env}
                        "bin/beagle-store-mcp")]
    {:reply (->> (str/split-lines (:out result))
                 (keep #(try (json/parse-string % true) (catch Throwable _ nil)))
                 (some #(when (= id (:id %)) %)))
     :exit (:exit result)
     :err (str (:err result))}))

(defn mcp-call [env id tool arguments]
  (:reply (mcp-run env id tool arguments)))

(defn reply-error? [reply]
  (boolean (or (:error reply) (get-in reply [:result :isError]))))
(defn reply-text [reply] (or (get-in reply [:result :content 0 :text]) ""))
(defn version [] (:version (database {:op :version})))

(def watchdog
  (future
    (Thread/sleep 600000)          ; must outlast the readiness budget plus the edits
    (binding [*out* *err*] (println "mcp-warm-graph-edit-regression: hard timeout"))
    (try (p/destroy-tree daemon) (catch Throwable _ nil))
    (System/exit 124)))

(try
  (when-not (eventually #(integer? (version)))
    (throw (ex-info "code server did not become ready" {:daemon-log (slurp (str tmp "/daemon.log"))})))

  (let [path-response (database {:op :module-path :module "src.plangrep.model"})]
    (check! ":module-path resolves the exact registered nested source"
            (and (:ok path-response) (= source-file (:path path-response)))))

  (let [status (p/shell {:dir root :out :string :err :string :continue true
                         :extra-env {"GRAPH_UPSTREAM_REGISTRY" graph-registry}}
                        "bin/beagle-store-code-status" project)]
    (check! "status counts the in-band adopted path, not the stale registry row"
            (and (zero? (:exit status))
                 (str/includes? (:out status) "level=2 ")
                 (str/includes? (:out status) "mcp=present")
                 (str/includes? (:out status) "server=alive")
                 (str/includes? (:out status) "canonical=1"))))

  (let [event (json/generate-string
               {:tool_name "Edit" :tool_input {:file_path source-file}})
        guard (p/shell {:dir root :in (str event "\n")
                        :out :string :err :string :continue true
                        :extra-env {"GRAPH_UPSTREAM_REGISTRY" graph-registry
                                    "AGENT_NO_AUTHORING_HOOKS" "0"}}
                       "integrations/north/hooks/code-upstream-guard.sh")
        decision (try (json/parse-string (:out guard) true)
                      (catch Throwable _ nil))]
    (check! "the canonical adopted path is refused by direct text authoring"
            (and (zero? (:exit guard))
                 (= "deny" (get-in decision
                                    [:hookSpecificOutput :permissionDecision])))))

  (let [reply (mcp-call mcp-env 10 "add-def"
                        {:module source-file
                         :form "(defn increment [(x Int)] Int (+ x 1))"})
        rendered (slurp source-file)]
    (check! "the same canonical adopted path is accepted by graph authoring"
            (and reply (not (reply-error? reply))))
    (check! "add-def JSON string renders as a real top-level form"
            (and (str/includes? rendered "(defn increment")
                 (str/includes? rendered "(+ x 1)")
                 (not (str/includes? rendered "\"(defn increment"))))
    (check! "add-def updates the registered nested file"
            (str/includes? rendered "defn increment"))
    (check! "add-def creates no root-level dotted-module projection"
            (not (.exists (io/file root-level-artifact)))))

  (let [reply (mcp-call mcp-env 14 "add-def"
                        {:module "src.plangrep.model"
                         :form "(defn semantic-index-accepted? [(schema-version String)] Bool (= schema-version \"firn-index/v2\"))"})
        rendered (slurp source-file)]
    (check! "warm same-name add-def succeeds"
            (and reply (not (reply-error? reply))))
    (check! "same-name add-def replaces exactly one ingested wrapper form"
            (and (= 1 (count (re-seq #"\(defn semantic-index-accepted\?" rendered)))
                 (str/includes? rendered "firn-index/v2")
                 (not (str/includes? rendered "firn-index/v1")))))

  (let [reply (mcp-call mcp-env 11 "set-body"
                        {:module "src.plangrep.model" :name "base" :body "(+ 40 2)"})
        rendered (slurp source-file)]
    (check! "warm set-body succeeds" (and reply (not (reply-error? reply))))
    (check! "set-body JSON string renders as an expression, not a string literal"
            (and (str/includes? rendered "(+ 40 2)")
                 (not (str/includes? rendered "\"(+ 40 2)\""))))
    (check! "set-body still creates no root-level dotted-module projection"
            (not (.exists (io/file root-level-artifact)))))

  (let [narrow-root (str project "/test")
        _ (.mkdirs (io/file narrow-root))
        confined-env (assoc mcp-env "BEAGLE_STORE_SRC" narrow-root)
        before-version (version)
        before-source (slurp source-file)
        run (mcp-run confined-env 12 "set-body"
                     {:module "src.plangrep.model" :name "base" :body "99"})
        reply (:reply run)]
    ;; Confinement fences the adapter at startup as well as per call: either the
    ;; tool refuses to launch, or it answers with the per-edit rejection.
    (check! "outside-BEAGLE_STORE_SRC registered path is rejected"
            (or (and (reply-error? reply)
                     (str/includes? (reply-text reply) "outside BEAGLE_STORE_SRC"))
                (and (nil? reply)
                     (not (zero? (:exit run)))
                     (str/includes? (:err run) "OUTSIDE the BEAGLE_STORE_SRC"))))
    (check! "path-confinement rejection happens before graph mutation"
            (= before-version (version)))
    (check! "path-confinement rejection leaves the nested view byte-identical"
            (= before-source (slurp source-file))))

  (let [before-version (version)
        reply (mcp-call mcp-env 13 "set-body"
                        {:module "src.plangrep.model" :name "base" :body "(+ 1"})]
    (check! "unreadable set-body EDN is rejected"
            (and (reply-error? reply) (str/includes? (reply-text reply) "not readable EDN")))
    (check! "unreadable EDN rejection happens before graph mutation"
            (= before-version (version))))

  (finally
    (future-cancel watchdog)
    (try (p/destroy-tree daemon) (catch Throwable _ nil))))

(let [failures (remove second @checks)]
  (if (seq failures)
    (do (println "\nFAIL — corpus retained at" tmp) (System/exit 1))
    (do
      (println "\nPASS —" (count @checks) "warm MCP graph-edit regressions")
      (doseq [f (reverse (file-seq (io/file tmp)))]
        (try (io/delete-file f true) (catch Throwable _ nil))))))
