;; fram_mcp.clj — the public AI-facing data edge of a Fram instance.
;; Speaks MCP (JSON-RPC 2.0, newline-delimited, over stdio). This process has
;; exactly five data tools. Graph authoring belongs to a separate sealed control
;; service and is neither catalogued nor linked into this runtime closure.
(require '[cheshire.core :as json]
         '[clojure.string :as str]
         '[framrpc :as rpc-wire]
         '[fram.types :as terms]
         '[fram.rt])

(defn- log! [& xs] (binding [*out* *err*] (apply println xs)))

(def instructions
  (str
   "Fram is a recursive Triple engine: every proposition has t1/t2/t3. "
   "The public data interface is exactly tell, retract, show, ask, and validate. "
   "tell and retract write one Triple; show scans live Triples by t1; ask runs "
   "a validated typed recursive query; validate reports structural integrity. "
   "Graph authoring is available only through a separate sealed control service."))

(defn- param
  ([name type] (param name type true))
  ([name type required] {:name name :type type :required required}))

(def ^:private closed-catalog
  [{:name "tell" :desc "Assert one recursive Triple." :params [(param "subject" "string") (param "predicate" "string") (param "object" "string")]}
   {:name "retract" :desc "Retract one exact recursive Triple." :params [(param "subject" "string") (param "predicate" "string") (param "object" "string")]}
   {:name "show" :desc "Read every live Triple whose t1 matches subject." :params [(param "subject" "string")]}
   {:name "ask" :desc "Run a typed recursive query." :params [(param "query" "object")]}
   {:name "validate" :desc "Report structural integrity violations." :params []}])

(defn- input-schema [params]
  {:type "object"
   :properties (reduce (fn [m p] (assoc m (:name p) {:type (:type p) :description (str (:name p))})) {} params)
   :required (vec (keep (fn [p] (when (:required p) (:name p))) params))})

(def ^:private query-term-schema
  {:oneOf
   [{:type "object"
     :properties {"var" {:type "string"}}
     :required ["var"]}
    {:type "string"}
    {:type "number"}]})

(def ^:private query-rule-schema
  {:type "object"
   :properties
   {"head"
    {:type "object"
     :properties
     {"rel" {:type "string"}
      "args" {:type "array" :items query-term-schema}}
     :required ["rel" "args"]}
    "body"
    {:type "array"
     :description "Relational, predicate, or function literals; exact safety rules are validated before execution."
     :items {:type "object"}}}
   :required ["head" "body"]})

(def ^:private aggregate-find-schema
  {:type "object"
   :properties
   {"rel" {:type "string" :description "Derived relation to aggregate."}
    "group" {:type "array"
             :items {:type "integer" :minimum 0}
             :description "Tuple positions that form the group key."}
    "agg" {:type "array"
           :minItems 1
           :items
           {:type "object"
            :properties
            {"op" {:type "string"
                   :enum ["count" "count-distinct" "sum" "avg" "min" "max"]}
             "arg" {:type "integer" :minimum 0}}
            :required ["op"]}}
    "having" {:type "array"
              :items
              {:type "object"
               :properties
               {"op" {:type "string" :enum ["eq" "ne" "lt" "le" "gt" "ge"]}
                "agg" {:type "integer" :minimum 0}
                "val" {:type "number"}}
               :required ["op" "agg" "val"]}}}
   :required ["rel" "group" "agg"]})

(def ^:private ordinary-query-example
  {"find" "result"
   "rules"
   [{"head" {"rel" "result" "args" [{"var" "r"}]}
     "body" [{"rel" "triple" "args" ["@subject" "title" {"var" "r"}]}]}]})

(def ^:private ask-query-schema
  {:type "object"
   :description "Ordinary find is a relation-name string, not a rule-head map. Supply exactly one of rules or strata."
   :properties
   {"find" {:oneOf
            [{:type "string"
              :description "Ordinary query result relation, matching a rule head rel."}
             aggregate-find-schema]}
    "rules" {:type "array" :items query-rule-schema}
    "strata" {:type "array"
              :items {:type "array" :items query-rule-schema}}}
   :required ["find"]
   :oneOf
   [{:required ["rules"] :not {:required ["strata"]}}
    {:required ["strata"] :not {:required ["rules"]}}]
   :examples [ordinary-query-example]})

(defn- tool-input-schema [spec]
  (cond-> (input-schema (:params spec))
    (= "ask" (:name spec))
    (assoc-in [:properties "query"] ask-query-schema)))

(defn- ->tool [spec]
  {:name (:name spec)
   :description (:desc spec)
   :inputSchema (tool-input-schema spec)})

(def ^:private closed-tools (mapv ->tool closed-catalog))

(defn- term-json [value]
  (cond
    (terms/triple? value)
    {:triple [(term-json (terms/triple-t1 value))
              (term-json (terms/triple-t2 value))
              (term-json (terms/triple-t3 value))]}
    (terms/instant? value)
    {:instant {:epochSeconds (str (terms/instant-epoch-seconds value))
               :nanos (terms/instant-nanos value)}}
    (keyword? value) (str value)
    :else value))

(defn- native-error-result [response]
  (when-let [error (fram.rt/native-error response)]
    {:isError true
     :text (str (name (terms/rpcerror-code error)) ": "
                (terms/rpcerror-message error))}))

(defn- mcp-subject! [value]
  (if (and (string? value) (not (str/starts-with? value "@")))
    (str "@" value)
    (fram.rt/lower-term! value)))

(defn- native-version! []
  (let [response (fram.rt/native-call!
                  (fram.rt/server-port) :rpc/version rpc-wire/rpc-unit)]
    (fram.rt/require-native-success! response)
    (terms/rpcresponse-served-version response)))

(defn- native-mcp-write [name arguments]
  (try
    (let [operation (if (= name "tell") :rpc/assert :rpc/retract)
          subject (mcp-subject! (:subject arguments))
          proposition
          (terms/triple subject
                        (fram.rt/lower-term! (:predicate arguments))
                        (fram.rt/lower-term! (:object arguments)))]
      (loop [remaining 5]
        (let [base (native-version!)
              response
              (fram.rt/native-call!
               (fram.rt/server-port) (fram.rt/rpc-space-id) operation
               (rpc-wire/rpc-write! proposition rpc-wire/rpc-subject-any nil)
               base nil nil)]
          (cond
            (and (= :rpc/conflict (fram.rt/native-error-code response))
                 (pos? remaining))
            (recur (dec remaining))

            (fram.rt/native-error response)
            (native-error-result response)

            :else
            {:text
             (json/generate-string
              {:changed
               (let [[results]
                     (fram.rt/rpc-record-fields!
                      (fram.rt/native-payload response)
                      :rpc/mutation-result 1)
                     [result] (fram.rt/rpc-list-values! results)
                     [_ changed _]
                     (fram.rt/rpc-record-fields! result :rpc/action-result 3)]
                 changed)
               :servedVersion
               (str (terms/rpcresponse-served-version response))})}))))
    (catch Throwable error
      {:isError true :text (or (.getMessage error) (str (class error)))})))

(defn- native-mcp-show [arguments]
  (try
    (let [response
          (fram.rt/native-call!
           (fram.rt/server-port) :rpc/scan
           (rpc-wire/rpc-triple-pattern!
            (mcp-subject! (:subject arguments)) nil nil))]
      (or (native-error-result response)
          (let [[values]
                (fram.rt/rpc-record-fields!
                 (fram.rt/native-payload response) :rpc/triples 1)]
            {:text
             (json/generate-string
              (mapv
               (fn [triple]
                 {:t2 (term-json (terms/triple-t2 triple))
                  :t3 (term-json (terms/triple-t3 triple))})
               (fram.rt/rpc-list-values! values)))})))
    (catch Throwable error
      {:isError true :text (or (.getMessage error) (str (class error)))})))

(defn- native-mcp-query [arguments]
  (try
    (let [response
          (fram.rt/native-call!
           (fram.rt/server-port) :rpc/query
           (fram.rt/native-query-payload! (:query arguments)))]
      (or (native-error-result response)
          (let [[rows]
                (fram.rt/rpc-record-fields!
                 (fram.rt/native-payload response) :query/rows 1)]
            {:text
             (json/generate-string
              (mapv
               (fn [row]
                 (let [[values]
                       (fram.rt/rpc-record-fields! row :query/row 1)]
                   (mapv term-json (fram.rt/rpc-list-values! values))))
               (fram.rt/rpc-list-values! rows)))})))
    (catch Throwable error
      {:isError true :text (or (.getMessage error) (str (class error)))})))

(defn- native-mcp-validate []
  (try
    (let [response
          (fram.rt/native-call!
           (fram.rt/server-port) :rpc/validate rpc-wire/rpc-unit)]
      (or (native-error-result response)
          (let [[valid violations]
                (fram.rt/rpc-record-fields!
                 (fram.rt/native-payload response) :rpc/validation 2)]
            {:text
             (json/generate-string
              {:valid valid
               :violations
               (mapv term-json (fram.rt/rpc-list-values! violations))})})))
    (catch Throwable error
      {:isError true :text (or (.getMessage error) (str (class error)))})))


(defn- dispatch-call [name arguments]
  (cond
    (= name "tell") (native-mcp-write "tell" arguments)
    (= name "retract") (native-mcp-write "retract" arguments)
    (= name "show") (native-mcp-show arguments)
    (= name "ask") (native-mcp-query arguments)
    (= name "validate") (native-mcp-validate)
    :else
    {:isError true :text (str "unknown tool: " name)}))

(defn handle-call [name args]
  (let [arguments (or args {})
        required (cond
                   (contains? #{"tell" "retract"} name)
                   [:subject :predicate :object]
                   (= "show" name) [:subject]
                   (= "ask" name) [:query]
                   :else [])
        missing (filterv #(nil? (get arguments %)) required)]
    (if (seq missing)
      {:isError true
       :text (str "missing required param(s): "
                  (str/join ", " (map #(str "'" (clojure.core/name %) "'") missing)))}
      (dispatch-call name arguments))))

(def ^:private max-live-queries
  (max 1 (quot (.. Runtime getRuntime availableProcessors) 2)))
(def ^:private live-queries (atom 0))

(defn- with-timeout [ms thunk]
  ;; reserve a worker slot; refuse fast if too many (possibly orphaned) are alive.
  (if (> (swap! live-queries inc) max-live-queries)
    (do (swap! live-queries dec)
        {:isError true :text (str "query budget: too many concurrent/abandoned queries in flight (>" max-live-queries ") — a prior expensive query is still running; retry later or narrow it")})
    (let [result (promise)
          worker (doto (Thread.
                        (fn []
                          (try (deliver result (thunk))
                               (catch InterruptedException _ (deliver result ::timeout))
                               (catch Throwable t (deliver result {:isError true :text (str "query failed: " (.getMessage t))}))
                               (finally (swap! live-queries dec)))))
                   (.setDaemon true)         ; never blocks JVM shutdown
                   (.setName "fram-mcp-query")
                   (.start))
          r (deref result ms ::timeout)]
      (if (= r ::timeout)
        (do (.interrupt worker)              ; best-effort; abandoned if it ignores us
            {:isError true :text (str "query exceeded the " (quot ms 1000) "s time budget — narrow it (fewer rules / more constants)")})
        r))))

;; --- JSON-RPC plumbing -------------------------------------------------------
(defn- reply [id result] (println (json/generate-string {:jsonrpc "2.0" :id id :result result})) (flush))
(defn- reply-err [id code msg] (println (json/generate-string {:jsonrpc "2.0" :id id :error {:code code :message msg}})) (flush))


(defn handle [req]
  (let [has-id (contains? req :id)
        id (:id req)
        method (:method req)
        params (:params req)]
    (cond
      (not has-id) nil

      (= method "initialize")
      (reply id {:protocolVersion "2024-11-05"
                 :capabilities {:tools {}}
                 :serverInfo {:name "fram" :version "0.1"}
                 :instructions instructions})

      (= method "tools/list")
      (reply id {:tools closed-tools})

      (= method "tools/call")
      (let [result
            (with-timeout
              10000
              (fn [] (handle-call (:name params) (:arguments params))))]
        (reply id {:content [{:type "text" :text (:text result)}]
                   :isError (boolean (:isError result))}))

      :else
      (reply-err id -32601 (str "method not found: " method)))))

(log! "fram-mcp: ready on stdio (public data catalog: tell/retract/show/ask/validate)")
(loop []
  (when-let [line (read-line)]
    (when (seq (str/trim line))
      (let [req (try
                  (json/parse-string line true)
                  (catch Exception error
                    (log! "parse error:" (.getMessage error))
                    nil))]
        (cond
          (nil? req) nil
          (not (map? req))
          (do
            (println
             (json/generate-string
              {:jsonrpc "2.0"
               :id nil
               :error {:code -32600
                       :message "Invalid Request: expected a single JSON object (batches not supported)"}}))
            (flush))
          :else
          (try
            (handle req)
            (catch Exception error
              (log! "handler error:" (.getMessage error))
              (when (contains? req :id)
                (reply-err (:id req) -32603 (.getMessage error))))))))
    (recur)))
