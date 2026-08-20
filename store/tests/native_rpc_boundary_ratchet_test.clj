;; Static ratchet for the public data boundary. EDN remains a local human,
;; migration, and compiler syntax only; it never reaches a live data socket.
(require '[clojure.string :as str])

(def checks (atom []))
(defn check! [label value detail]
  (swap! checks conj [label (boolean value) detail]))
(defn file-source [path] (slurp path))
(defn absent? [text needles] (not-any? #(str/includes? text %) needles))
(defn between [text start end]
  (let [from (str/index-of text start)
        to (when from (str/index-of text end (+ from (count start))))]
    (when (and from to) (subs text from to))))

(let [shim (file-source "deploy/cloudflare/shim.clj")
      worker (file-source "deploy/cloudflare/worker-client.js")]
  (check! "Cloudflare shim uses the shared STORERPC client"
          (and (str/includes? shim "rt/native-request-to!")
               (str/includes? shim "rpc/rpc-request!")
               (str/includes? shim "strict-duplicate-detection true"))
          nil)
  (check! "Worker has the exact closed Term vocabulary"
          (every? #(str/includes? worker (str "'" % "'"))
                  ["string" "integer" "float64" "boolean" "keyword" "instant" "triple"])
          nil)
  (check! "Worker surface has the exact thirteen named operations"
          (= ["version" "status" "validate" "occurrences" "scan" "query"
              "assert" "retract" "batch" "leaseAcquire" "leaseRenew"
              "leaseRelease" "leaseCheck"]
             (mapv second
                   (re-seq #"(?m)^    ([A-Za-z]+): .*send\(" worker)))
          nil))

(let [server (file-source "server.clj")]
  (check! "server serves only the closed thirteen-op STORERPC set"
          (= 13 (count (re-seq #":rpc/[a-z-]+" (between server
                                                       "(def native-rpc-operations"
                                                       "(def paged-rpc-operations"))))
          nil))

(let [runtime (file-source "src/store/rt.clj")]
  (check! "human Term parsing is explicitly local"
          (and (str/includes? runtime "defn parse-human-term!")
               (str/includes? runtime "This parser is a CLI boundary only"))
          nil))

(let [mcp (file-source "tests/store_mcp.clj")
      catalog (between mcp "(def ^:private closed-catalog"
                       "(defn- input-schema")
      public (between mcp "(defn- term-json" "(def ^:private max-live-queries")
      tool-names (mapv second (re-seq #":name \"([^\"]+)\"" catalog))]
  (check! "MCP tools/list catalog is exactly the five public data verbs"
          (= ["tell" "retract" "show" "ask" "validate"] tool-names)
          tool-names)
  (check! "MCP public data dispatch is STORERPC-only"
          (and public
               (str/includes? public "store.rt/native-call!"))
          nil))

(let [fast (file-source "bin/beagle-store-cli.clj")
      up (file-source "bin/beagle-store-up")
      selfcheck-runner (file-source "bin/beagle-store-doctor")
      selfcheck (file-source "bin/beagle-store-doctor-probe.clj")]
  (check! "CLI EDN use is confined to the local human query parser"
          (= 2 (count (re-seq #"(?:clojure\.edn|edn/read-string)" fast)))
          nil)
  (check! "CLI occurrences drains bounded pages instead of truncating history"
          (and (str/includes? fast "(wire/rpc-page-request! 200 cursor)")
               (str/includes? fast "(t/rpcpageresponse-done page)")
               (str/includes? fast "(t/rpc-page-response-cursor-value page)"))
          nil)
  (check! "readiness and deep probes speak native version records"
          (and (str/includes? up "native-call!")
               (str/includes? selfcheck "native-request-to!"))
          nil)
  (check! "deep probes bind the exact runtime engine identity"
          (and (str/includes? selfcheck-runner "native) EXPECTED_ENGINE=:rpc/native")
               (str/includes? selfcheck-runner "graal) EXPECTED_ENGINE=:rpc/graal")
               (str/includes? selfcheck-runner
                              "jvm-oracle|jvm-dev) EXPECTED_ENGINE=:rpc/jvm")
               (str/includes? selfcheck-runner
                              "BEAGLE_STORE_SC_EXPECTED_ENGINE=\"$EXPECTED_ENGINE\"")
               (str/includes? selfcheck
                              "BEAGLE_STORE_SC_EXPECTED_ENGINE must be :rpc/native, :rpc/graal, or :rpc/jvm")
               (str/includes? selfcheck "(= expected-engine engine)"))
          nil))

(let [launcher (file-source "bin/beagle-store-server")
      code-on (file-source "bin/beagle-store-code-on")
      ingest (file-source "bin/beagle-store-ingest-code")
      status (file-source "bin/beagle-store-code-status")]
  (check! "STORELOG serving and code ingest retain distinct boundaries"
          (and (str/includes? launcher "BEAGLE_STORE_SERVER_RUNTIME:-native")
               (str/includes? launcher "artifact_dir/READY")
               (str/includes? launcher "BEAGLE_STORE_GRAAL_ARTIFACT")
               (str/includes? launcher "exec \"$graal_artifact\"")
               (str/includes? launcher "jvm-oracle|jvm-dev")
               (str/includes? launcher "exec \"$native_server\"")
               (str/includes? code-on "bin/beagle-store-server serve")
               (str/includes? code-on "--space-id \"$SPACE_ID\"")
               (every? #(str/includes? ingest %)
                       ["database/create-triple-log!" "database/open-database!"
                        "database/commit!" "replace-atomically!"])
               (str/includes? status "BEAGLE_CLI=\"${BEAGLE_STORE_BEAGLE:-$HERE/../bin/beagle}\"")
               (str/includes? status "\"$BEAGLE_CLI\" store status")
               (absent? status ["wc -l"]))
          nil))

(let [failures (remove second @checks)]
  (doseq [[label ok detail] @checks]
    (println (if ok "  [PASS]" "  [FAIL]") label)
    (when (and (not ok) detail) (println "         " detail)))
  (if (seq failures)
    (do (println "\nnative RPC boundary ratchet:" (count failures) "FAILED")
        (System/exit 1))
    (println "\nnative RPC boundary ratchet:" (count @checks) "/" (count @checks) "PASS")))
