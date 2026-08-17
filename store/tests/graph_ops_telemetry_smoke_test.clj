(require '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(defn delete-tree! [file]
  (when (.isDirectory file)
    (doseq [child (.listFiles file)] (delete-tree! child)))
  (.delete file))

(defn run-call [env request]
  (let [result (p/shell {:in (str (json/generate-string request) "\n")
                         :out :string :err :string :continue true :env env}
                        "bin/beagle-store-mcp")
        reply (->> (str/split-lines (:out result))
                   (keep #(try (json/parse-string % true) (catch Throwable _ nil)))
                   (some #(when (= (:id request) (:id %)) %)))]
    {:process result :reply reply}))

(let [root (System/getProperty "user.dir")
      home (System/getProperty "user.home")
      tmp (.toFile (java.nio.file.Files/createTempDirectory
                    "store-graph-ops-smoke"
                    (make-array java.nio.file.attribute.FileAttribute 0)))
      src (io/file tmp "src")
      module (io/file src "fixture.bclj")
      facts (io/file tmp "facts.log")
      telemetry (io/file tmp "graph-ops.jsonl")
      beagle-home (or (System/getenv "BEAGLE_HOME") (str home "/code/beagle/main"))
      request {:jsonrpc "2.0" :id 7 :method "tools/call"
               :params {:name "set-body"
                        :arguments {:module "fixture" :name "no-such-def"
                                    :body "(+ 1 1)"}}}
      base-env (cond-> {"PATH" (System/getenv "PATH")
                        "HOME" home
                        "BEAGLE_STORE_LOG" (.getCanonicalPath facts)
                        "BEAGLE_STORE_THREADS" (.getCanonicalPath tmp)
                        "BEAGLE_STORE_SERVER_PORT" "59998"
                        "BEAGLE_STORE_SRC" (.getCanonicalPath src)
                        "BEAGLE_STORE_OUT" (str root "/out")
                        "BEAGLE_STORE_RESOLVE" (str root "/out/resolve.clj")
                        "BEAGLE_HOME" beagle-home
                        "BEAGLE_STORE_BEAGLE" (str beagle-home "/bin/beagle")
                        "BEAGLE_STORE_BUILD_ALL" (str beagle-home "/bin/beagle-build-all")}
                 (System/getenv "JAVA_HOME")
                 (assoc "JAVA_HOME" (System/getenv "JAVA_HOME")))]
  (try
    (.mkdirs src)
    (io/copy (io/file root "codegraph/test/fc-truecap.bclj") module)
    (spit facts "{:tx 1 :op \"assert\" :l \"@a\" :p \"title\" :r \"A\" :frame \"test\"}\n")
    (let [off (run-call (assoc base-env "BEAGLE_STORE_GRAPH_OPS_LOG" "off") request)
          absent-off? (not (.exists telemetry))
          on (run-call (assoc base-env "BEAGLE_STORE_GRAPH_OPS_LOG" (.getCanonicalPath telemetry)) request)
          records (when (.isFile telemetry)
                    (mapv #(json/parse-string % true)
                          (remove str/blank? (str/split-lines (slurp telemetry)))))
          record (first records)
          same-result? (= (get-in off [:reply :result]) (get-in on [:reply :result]))
          pass? (and (zero? (get-in off [:process :exit]))
                     (zero? (get-in on [:process :exit]))
                     absent-off?
                     same-result?
                     (= 1 (count records))
                     (= "set-body" (:op record))
                     (= "fixture" (:module record))
                     (= "no-such-def" (:def record))
                     (number? (:wall_ms record))
                     (pos? (:payload_bytes record))
                     (= (.length module) (:module_bytes record))
                     (false? (:accepted record))
                     (string? (:reject_reason record))
                     (nil? (:recompile_ms record))
                     (zero? (:retry_seq record)))]
      (if pass?
        (println "graph-ops-telemetry-smoke: PASS — scratch op result unchanged; record"
                 (json/generate-string record))
        (do
          (binding [*out* *err*]
            (println "graph-ops-telemetry-smoke: FAIL"
                     (pr-str {:off off :on on :absent-off absent-off?
                              :same-result same-result? :records records})))
          (System/exit 1))))
    (finally (delete-tree! tmp))))
