;; Real server + authenticated JSON shim + FRAMRPC restart proof.
(require '[babashka.fs :as fs]
         '[babashka.process :as proc]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[store.rpc :as wire]
         '[store.rt :as rt]
         '[store.types :as terms])
(import '[java.net URI ServerSocket]
        '[java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers
          HttpResponse$BodyHandlers])

(def root (.getCanonicalPath (io/file (System/getProperty "user.dir"))))
(def checks (atom []))
(defn check! [label value] (swap! checks conj [label (boolean value)]))
(defn free-port [] (with-open [socket (ServerSocket. 0)] (.getLocalPort socket)))
(defn eventually [f]
  (loop [remaining 800]
    (cond (try (boolean (f)) (catch Throwable _ false)) true
          (zero? remaining) false
          :else (do (Thread/sleep 25) (recur (dec remaining))))))

(def watchdog
  (future (Thread/sleep 90000)
          (binding [*out* *err*] (println "cloudflare FRAMRPC: hard timeout"))
          (System/exit 124)))

(defn stop-process! [process]
  (when process
    (try (proc/destroy-tree process) (catch Throwable _ nil))
    (let [java-process ^Process (:proc process)]
      (when-not (.waitFor java-process 5 java.util.concurrent.TimeUnit/SECONDS)
        (.destroyForcibly java-process)
        (.waitFor java-process 5 java.util.concurrent.TimeUnit/SECONDS)))))

(defn term-json [value]
  (cond
    (string? value) ["string" value]
    (integer? value) ["integer" (str value)]
    (and (number? value) (not (integer? value)))
    ["float64" (format "%016x" (Double/doubleToLongBits (double value)))]
    (boolean? value) ["boolean" value]
    (keyword? value) ["keyword" (subs (str value) 1)]
    (terms/instant? value)
    ["instant" (str (terms/instant-epoch-seconds value))
     (str (terms/instant-nanos value))]
    (terms/triple? value)
    ["triple" (term-json (terms/triple-t1 value))
     (term-json (terms/triple-t2 value))
     (term-json (terms/triple-t3 value))]
    :else (throw (ex-info "not a Term" {:value value}))))

(defn list-json-values [value]
  (loop [cursor value result []]
    (cond
      (= ["keyword" "rpc/list-end"] cursor) result
      (and (= "triple" (first cursor))
           (= ["keyword" "rpc/list"] (second cursor)))
      (recur (nth cursor 3) (conj result (nth cursor 2)))
      :else (throw (ex-info "malformed JSON RPC list" {:value value})))))

(defn record-json-fields [value tag field-count]
  (when-not (and (= "triple" (first value))
                 (= ["keyword" tag] (second value))
                 (= ["keyword" "rpc/record"] (nth value 3)))
    (throw (ex-info "malformed JSON RPC record" {:tag tag :value value})))
  (let [fields (list-json-values (nth value 2))]
    (when-not (= field-count (count fields))
      (throw (ex-info "wrong JSON RPC field count" {:tag tag :value value})))
    fields))

(def http-client (HttpClient/newHttpClient))
(defn http-post [port path token content-type body]
  (let [builder (doto (HttpRequest/newBuilder
                       (URI/create (str "http://127.0.0.1:" port path)))
                  (.POST (HttpRequest$BodyPublishers/ofString body)))
        _ (when token (.header builder "authorization" (str "Bearer " token)))
        _ (when content-type (.header builder "content-type" content-type))
        response (.send http-client (.build builder) (HttpResponse$BodyHandlers/ofString))]
    {:status (.statusCode response)
     :content-type (.orElse (.firstValue (.headers response) "content-type") "")
     :body (.body response)
     :json (try (json/parse-string-strict (.body response)) (catch Throwable _ nil))}))

(defn request-json
  ([space op payload] (request-json space op payload nil))
  ([space op payload options]
   (json/generate-string
    (cond-> {"space" space "op" (subs (str op) 1) "payload" (term-json payload)}
      (:expected-version options) (assoc "expectedVersion" (str (:expected-version options)))
      (:timeout-ms options) (assoc "timeoutMs" (str (:timeout-ms options)))
      (:page options) (assoc "page" (:page options))))))

(defn direct-version [port space]
  (let [response
        (rt/native-request-to!
         "127.0.0.1" port
         (wire/rpc-request! space :rpc/version nil nil nil wire/rpc-unit))]
    (when-not (terms/rpcresponse-error response)
      (terms/rpcresponse-served-version response))))

(defn all-triples-plan []
  (let [t1 (wire/rpc-query-variable! "t1")
        t2 (wire/rpc-query-variable! "t2")
        t3 (wire/rpc-query-variable! "t3")]
    (wire/rpc-query-plan!
     (wire/rpc-query-find-relation! "all")
     [(wire/rpc-query-stratum!
       [(wire/rpc-query-rule!
         (wire/rpc-query-head! "all" [t1 t2 t3])
         [(wire/rpc-query-relation! "triple" [t1 t2 t3] false)])])])))

(let [server-port (free-port)
      shim-port (free-port)
      scratch (fs/create-temp-dir {:prefix "store-cloudflare-rpc-"})
      log-path (str (io/file (str scratch) "history.framlog"))
      space "cloudflare-rpc-test"
      token "cloudflare-rpc-secret"
      inherited (apply dissoc (into {} (System/getenv))
                       ["BEAGLE_STORE_LOG" "BEAGLE_STORE_TELEMETRY_LOG" "SHIM_LIBRARY"
                        "BEAGLE_STORE_SERVER_TLS" "BEAGLE_STORE_TLS_KEYSTORE" "BEAGLE_STORE_TLS_TRUSTSTORE"])
      server (atom nil)
      shim (atom nil)
      start-server!
      (fn []
        (reset! server
                (proc/process
                 {:dir root :env (assoc inherited "BEAGLE_STORE_SERVER_RUNTIME" "jvm-dev")
                  :out :inherit :err :inherit}
                 "bin/beagle-store-server" "serve" (str server-port) log-path space)))]
  (try
    (let [node @(proc/process {:dir root :out :string :err :string}
                              "node" "tests/cloudflare_worker_client_test.mjs")]
      (when-not (zero? (:exit node))
        (println (:out node))
        (binding [*out* *err*] (println (:err node))))
      (check! "Worker client typed JSON contract" (zero? (:exit node))))

    (start-server!)
    (check! "server starts on FRAMRPC"
            (eventually #(= 0 (direct-version server-port space))))
    (reset! shim
            (proc/process
             {:dir root
              :env (assoc inherited "BEAGLE_STORE_SERVER_CONNECT" "127.0.0.1"
                          "BEAGLE_STORE_SERVER_PORT" (str server-port)
                          "SHIM_PORT" (str shim-port)
                          "SHIM_TOKEN" token)
              :out :inherit :err :inherit}
             "bb" "-cp" "out" "deploy/cloudflare/shim.clj"))
    (check! "shim becomes ready on authenticated JSON"
            (eventually
             #(= 200 (:status
                      (http-post shim-port "/q" token "application/json"
                                 (request-json space :rpc/version wire/rpc-unit))))))

    (let [version (http-post shim-port "/q" token "application/json"
                             (request-json space :rpc/version wire/rpc-unit))]
      (check! "success response is one closed JSON FRAMRPC envelope"
              (and (= 200 (:status version))
                   (= "application/json" (:content-type version))
                   (= #{"space" "op" "servedVersion" "payload"}
                      (set (keys (:json version))))
                   (= "0" (get (:json version) "servedVersion"))
                   (= ["keyword" "rpc/unit"] (get (:json version) "payload")))))

    (let [subject (terms/triple "source-file" :page 1)
          values ["Door Schedule" -42 1.5 true :door
                  (terms/instant 1785580282 123000000)
                  (terms/triple "nested" :kernel/type "triple")]
          actions (mapv (fn [index value]
                          (wire/rpc-action!
                           :rpc/assert
                           (terms/triple subject (keyword (str "value-" index)) value)
                           wire/rpc-subject-any))
                        (range) values)
          asserted
          (http-post shim-port "/assert" token "application/json"
                     (request-json space :rpc/batch (wire/rpc-batch! actions nil)
                                   {:expected-version 0}))
          scanned
          (http-post shim-port "/q" token "application/json"
                     (request-json space :rpc/scan
                                   (wire/rpc-triple-pattern! subject nil nil)))
          [encoded-triples]
          (record-json-fields (get (:json scanned) "payload") "rpc/triples" 1)
          triples (list-json-values encoded-triples)]
      (check! "batch accepts every Atom kind plus recursive Triple nesting"
              (and (= 200 (:status asserted))
                   (= "1" (get (:json asserted) "servedVersion"))
                   (= 7 (count triples))
                   (= #{"string" "integer" "float64" "boolean" "keyword" "instant" "triple"}
                      (set (map #(first (nth % 3)) triples)))))

      (let [first-page
            (http-post shim-port "/q" token "application/json"
                       (request-json space :rpc/query
                                     (wire/rpc-query-request!
                                      (all-triples-plan) wire/query-current)
                                     {:page {"limit" "2"}}))
            cursor (get-in first-page [:json "page" "nextCursor"])
            second-page
            (http-post shim-port "/q" token "application/json"
                       (request-json space :rpc/query
                                     (wire/rpc-query-request!
                                      (all-triples-plan) wire/query-current)
                                     {:page {"limit" "100" "cursor" cursor}}))]
        (check! "pagination cursor stays a tagged Term and resumes the snapshot"
                (and (= false (get-in first-page [:json "page" "done"]))
                     (= "triple" (first cursor))
                     (= true (get-in second-page [:json "page" "done"]))
                     (= "1" (get-in second-page [:json "servedVersion"])))))

      (stop-process! @server)
      (reset! server nil)
      (start-server!)
      (check! "server restart replays the recursive FRAMLOG"
              (eventually #(= 1 (direct-version server-port space))))
      (let [after-restart
            (http-post shim-port "/q" token "application/json"
                       (request-json space :rpc/scan
                                     (wire/rpc-triple-pattern! subject nil nil)))
            [encoded] (record-json-fields (get (:json after-restart) "payload")
                                          "rpc/triples" 1)]
        (check! "shim reads the same seven live Triples after restart"
                (= 7 (count (list-json-values encoded))))))

    (let [unauthorized
          (http-post shim-port "/q" "wrong" "application/json" "not json")
          malformed-json
          (let [body (request-json space :rpc/version wire/rpc-unit)]
            (http-post shim-port "/q" token "application/json"
                       (subs body 0 (dec (count body)))))
          duplicate
          (http-post shim-port "/q" token "application/json"
                     (str "{\"space\":\"" space "\",\"space\":\"other\","
                          "\"op\":\"rpc/version\",\"payload\":[\"keyword\",\"rpc/unit\"]}"))
          extra
          (http-post shim-port "/q" token "application/json"
                     (json/generate-string
                      {"space" space "op" "rpc/version"
                       "payload" ["keyword" "rpc/unit"] "extra" true}))
          noncanonical
          (http-post shim-port "/assert" token "application/json"
                     (json/generate-string
                      {"space" space "op" "rpc/assert"
                       "payload" ["integer" "01"]}))
          wrong-path
          (http-post shim-port "/q" token "application/json"
                     (request-json space :rpc/assert wire/rpc-unit))]
      (check! "authentication runs before malformed-body parsing"
              (and (= 401 (:status unauthorized))
                   (= "shim/unauthorized" (get-in unauthorized [:json "error" "code"]))))
      (check! "malformed JSON stays a structured JSON error"
              (and (= 400 (:status malformed-json))
                   (= "shim/invalid-json" (get-in malformed-json [:json "error" "code"]))))
      (check! "duplicate envelope keys are rejected"
              (and (= 400 (:status duplicate))
                   (= "shim/invalid-json" (get-in duplicate [:json "error" "code"]))))
      (check! "unknown envelope keys are rejected"
              (and (= 400 (:status extra))
                   (= "shim/unknown-key" (get-in extra [:json "error" "code"]))))
      (check! "noncanonical tagged scalar is rejected before FRAMRPC"
              (and (= 400 (:status noncanonical))
                   (= "shim/noncanonical-integer"
                      (get-in noncanonical [:json "error" "code"]))))
      (check! "mutation on the read path is denied"
              (and (= 403 (:status wrong-path))
                   (= "shim/operation-not-allowed"
                      (get-in wrong-path [:json "error" "code"])))))

    (let [wrong-space
          (http-post shim-port "/q" token "application/json"
                     (request-json "another-space" :rpc/version wire/rpc-unit))]
      (check! "server errors remain typed JSON response envelopes"
              (and (= 200 (:status wrong-space))
                   (string? (get-in wrong-space [:json "error" "code"]))
                   (= "another-space" (get-in wrong-space [:json "space"])))))

    (stop-process! @server)
    (reset! server nil)
    (let [upstream
          (http-post shim-port "/q" token "application/json"
                     (request-json space :rpc/version wire/rpc-unit))]
      (check! "upstream failure is bounded structured JSON"
              (and (= 502 (:status upstream))
                   (= "shim/upstream-failure" (get-in upstream [:json "error" "code"])))))

    (finally
      (stop-process! @shim)
      (stop-process! @server)
      (future-cancel watchdog)
      (fs/delete-tree scratch))))

(let [failures (remove second @checks)]
  (doseq [[label ok] @checks] (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (seq failures)
    (do (println "\ncloudflare FRAMRPC:" (count failures) "FAILED") (System/exit 1))
    (println "\ncloudflare FRAMRPC:" (count @checks) "/" (count @checks) "PASS")))
