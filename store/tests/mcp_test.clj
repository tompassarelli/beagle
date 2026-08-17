;; Real stdio JSON-RPC MCP -> shared FRAMRPC client -> real JVM server.
(require '[babashka.fs :as fs]
         '[babashka.process :as proc]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[clojure.string :as str]
         '[store.rpc :as wire]
         '[store.rt :as rt]
         '[store.types :as terms])
(import '[java.net ServerSocket])

(def checks (atom []))
(defn check!
  ([label value] (check! label value nil))
  ([label value detail] (swap! checks conj [label (boolean value) detail])))
(defn free-port [] (with-open [socket (ServerSocket. 0)] (.getLocalPort socket)))
(defn eventually [f]
  (loop [remaining 800]
    (cond (try (boolean (f)) (catch Throwable _ false)) true
          (zero? remaining) false
          :else (do (Thread/sleep 25) (recur (dec remaining))))))
(defn stop-process! [process]
  (when process
    (try (proc/destroy-tree process) (catch Throwable _ nil))
    (let [java-process ^Process (:proc process)]
      (when-not (.waitFor java-process 5 java.util.concurrent.TimeUnit/SECONDS)
        (.destroyForcibly java-process)
        (.waitFor java-process 5 java.util.concurrent.TimeUnit/SECONDS)))))

(defn direct-version [port space]
  (let [response
        (rt/native-request-to!
         "127.0.0.1" port
         (wire/rpc-request! space :rpc/version nil nil nil wire/rpc-unit))]
    (when-not (terms/rpcresponse-error response)
      (terms/rpcresponse-served-version response))))

(defn parse-responses [output]
  (keep #(try (json/parse-string % true) (catch Throwable _ nil))
        (remove str/blank? (str/split-lines output))))
(defn response-map [output]
  (into {} (keep (fn [response]
                   (when (contains? response :id) [(:id response) response])))
        (parse-responses output)))
(defn call-text [response] (get-in response [:result :content 0 :text]))

(def root (.getCanonicalPath (io/file (System/getProperty "user.dir"))))
(def scratch (fs/create-temp-dir {:prefix "store-native-mcp-"}))
(def log-path (str (io/file (str scratch) "history.framlog")))
(def space "native-mcp-test")
(def port (free-port))
(def inherited
  (apply dissoc (into {} (System/getenv))
         ["BEAGLE_STORE_LOG" "BEAGLE_STORE_THREADS" "BEAGLE_STORE_TELEMETRY_LOG" "BEAGLE_STORE_GRAPH_EDIT"
          "BEAGLE_STORE_FLIP" "BEAGLE_STORE_MCP_PROFILE" "BEAGLE_STORE_SERVER_TLS"]))
(def server
  (proc/process {:dir root :env (assoc inherited
                                      "BEAGLE_STORE_SERVER_RUNTIME" "jvm-dev"
                                      "BEAGLE_STORE_SNAPSHOT_BOOT" "0")
                 :out :inherit :err :inherit}
                "bin/beagle-store-server" "serve" (str port) log-path space))

(try
  (check! "real JVM server starts on FRAMRPC"
          (eventually #(= 0 (direct-version port space))))

  (let [query
        {:find "reaches"
         :rules [{:head {:rel "reaches" :args [{:var "x"} {:var "y"}]}
                  :body [{:rel "triple"
                          :args [{:var "x"} "depends_on" {:var "y"}]}]}]}
        requests
        [{:jsonrpc "2.0" :id 1 :method "initialize" :params {}}
         {:jsonrpc "2.0" :id 2 :method "tools/list" :params {}}
         {:jsonrpc "2.0" :id 3 :method "tools/call"
          :params {:name "tell" :arguments {:subject "a" :predicate "title" :object "A"}}}
         {:jsonrpc "2.0" :id 4 :method "tools/call"
          :params {:name "tell" :arguments {:subject "a" :predicate "depends_on" :object "@b"}}}
         {:jsonrpc "2.0" :id 5 :method "tools/call"
          :params {:name "show" :arguments {:subject "a"}}}
         {:jsonrpc "2.0" :id 6 :method "tools/call"
          :params {:name "ask" :arguments {:query query}}}
         {:jsonrpc "2.0" :id 7 :method "tools/call"
          :params {:name "retract" :arguments {:subject "a" :predicate "title" :object "A"}}}
         {:jsonrpc "2.0" :id 8 :method "tools/call"
          :params {:name "show" :arguments {:subject "a"}}}
         {:jsonrpc "2.0" :id 9 :method "tools/call"
          :params {:name "validate" :arguments {}}}
         {:jsonrpc "2.0" :id 10 :method "tools/call"
          :params {:name "tell" :arguments {:subject "a" :predicate "note"}}}
         {:jsonrpc "2.0" :id 11 :method "tools/call"
          :params {:name "not-a-tool" :arguments {}}}
         {:jsonrpc "2.0" :id 12 :method "tools/call"
          :params {:name "ask" :arguments {:query {:rules []}}}}]
        input (str (str/join "\n" (map json/generate-string requests)) "\n")
        run @(proc/process
              {:dir root :in input :out :string :err :string
               :env (assoc inherited
                           "BEAGLE_STORE_SERVER_PORT" (str port)
                           "BEAGLE_STORE_SPACE_ID" space
                           "BEAGLE_STORE_GRAPH_OPS_LOG" "off")}
              "bin/beagle-store-mcp")
        by-id (response-map (:out run))]
    (when-not (zero? (:exit run))
      (println (:out run))
      (binding [*out* *err*] (println (:err run))))
    (check! "MCP process exits cleanly" (zero? (:exit run)))
    (check! "initialize advertises Beagle Store tools"
            (and (= "store" (get-in by-id [1 :result :serverInfo :name]))
                 (contains? (get-in by-id [1 :result :capabilities]) :tools)))
    (let [tools (get-in by-id [2 :result :tools])
          names (mapv :name tools)]
      (check! "tools/list is exactly the five public data verbs"
              (= ["tell" "retract" "show" "ask" "validate"] names))
      (check! "every tool carries a closed object input schema"
              (every? #(= "object" (get-in % [:inputSchema :type])) tools)))
    (check! "tell commits through FRAMRPC"
            (and (not (get-in by-id [3 :result :isError]))
                 (str/includes? (call-text (get by-id 3)) "servedVersion")))
    (check! "second tell advances the server logical version"
            (= "2" (get (json/parse-string (call-text (get by-id 4)))
                         "servedVersion")))
    (let [rows (json/parse-string (call-text (get by-id 5)))]
      (check! "show reads live recursive Triples through rpc/scan"
              (= #{["title" "A"] ["depends_on" "@b"]}
                 (set (map (fn [row] [(get row "t2") (get row "t3")]) rows)))))
    (let [rows (json/parse-string (call-text (get by-id 6)))]
      (check! "ask lowers structured JSON to the typed query plan"
              (contains? (set (map vec rows)) ["@a" "@b"])))
    (check! "retract commits through FRAMRPC"
            (and (not (get-in by-id [7 :result :isError]))
                 (= 3 (direct-version port space))))
    (let [rows (json/parse-string (call-text (get by-id 8)))]
      (check! "retracted proposition is absent from the next show"
              (= [{"t2" "depends_on" "t3" "@b"}] rows)))
    (check! "validate returns the typed validation result"
            (= true (get (json/parse-string (call-text (get by-id 9))) "valid")))
    (check! "missing required arguments fail before socket dispatch"
            (and (get-in by-id [10 :result :isError])
                 (str/includes? (call-text (get by-id 10)) "object")))
    (check! "unknown tool names fail closed"
            (and (get-in by-id [11 :result :isError])
                 (= "unknown tool: not-a-tool" (call-text (get by-id 11))))
            (get by-id 11))
    (check! "malformed query is a bounded MCP error"
            (and (get-in by-id [12 :result :isError])
                 (seq (call-text (get by-id 12))))))

  (let [input
        (str (str/join "\n"
                       [(json/generate-string
                         {:jsonrpc "2.0" :method "notifications/initialized"})
                        "[{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/list\"}]"
                        (json/generate-string
                         {:jsonrpc "2.0" :id 21 :method "frobnicate"})
                        (json/generate-string
                         {:jsonrpc "2.0" :id 22 :method "tools/list"})]) "\n")
        run @(proc/process
              {:dir root :in input :out :string :err :string
               :env (assoc inherited "BEAGLE_STORE_SERVER_PORT" (str port)
                           "BEAGLE_STORE_SPACE_ID" space "BEAGLE_STORE_GRAPH_OPS_LOG" "off")}
              "bin/beagle-store-mcp")
        responses (parse-responses (:out run))]
    (check! "notification emits no reply" (= 3 (count responses)))
    (check! "JSON-RPC batch is rejected and the loop survives"
            (and (some #(= -32600 (get-in % [:error :code])) responses)
                 (some #(= 22 (:id %)) responses)))
    (check! "unknown JSON-RPC method returns -32601"
            (some #(= -32601 (get-in % [:error :code])) responses)))

  (let [missing-space @(proc/process
                        {:dir root :out :string :err :string
                         :env (dissoc inherited "BEAGLE_STORE_SPACE_ID")}
                        "bin/beagle-store-mcp")]
    (check! "MCP launcher fails closed without BEAGLE_STORE_SPACE_ID"
            (and (not (zero? (:exit missing-space)))
                 (str/includes? (:err missing-space) "BEAGLE_STORE_SPACE_ID"))))

  (finally
    (stop-process! server)
    (fs/delete-tree scratch)))

(let [failures (remove second @checks)]
  (doseq [[label ok detail] @checks]
    (println (if ok "  [PASS]" "  [FAIL]") label)
    (when (and (not ok) detail) (println "    actual:" (pr-str detail))))
  (if (seq failures)
    (do (println "\nfram MCP FRAMRPC:" (count failures) "FAILED") (System/exit 1))
    (println "\nfram MCP FRAMRPC:" (count @checks) "/" (count @checks) "PASS")))
