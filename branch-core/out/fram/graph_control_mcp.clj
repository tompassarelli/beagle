(ns fram.graph-control-mcp
  "Sealed stdio MCP composition for native multi-definition graph edits."
  (:require [cheshire.core :as json]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.walk :as walk]
            [framrpc :as framrpc]
            [fram.code-commit-gate :as gate]
            [fram.code-reader :as code-reader]
            [fram.program-inspection :as program]
            [fram.projection-lifecycle :as lifecycle]
            [fram.rt :as rt]
            [fram.types :as t])
  (:import [java.io PushbackReader StringReader]
           [java.nio ByteBuffer ByteOrder]
           [java.nio.charset CodingErrorAction StandardCharsets]
           [java.nio.file Files]
           [java.util Arrays]))

(def ^:private preflight-contract "fram.graph-control-preflight/v1")
(def ^:private server-name "fram-graph-control")
(def ^:private multi-tool-name "multi-set-body")
(def ^:private add-tool-name "add-def")
(def ^:private replace-tool-name "replace-def")
(def ^:private framlog-magic
  (.getBytes "FRAMLOG\u0000" StandardCharsets/UTF_8))

(defn- fail! [type message data]
  (throw (ex-info message (assoc data :type type))))

(defn- required-env! [name]
  (let [value (System/getenv name)]
    (when (str/blank? value)
      (fail! :missing-sealed-binding
             (str name " is required") {:binding name}))
    value))

(defn- port! []
  (let [raw (required-env! "FRAM_CODE_PORT")]
    (try
      (let [value (Long/parseLong raw)]
        (when-not (<= 1 value 65535)
          (fail! :invalid-sealed-binding
                 "FRAM_CODE_PORT is outside the TCP port range" {:port raw}))
        value)
      (catch NumberFormatException _
        (fail! :invalid-sealed-binding
               "FRAM_CODE_PORT must be a decimal TCP port" {:port raw})))))

(defn- canonical-path! [value field]
  (try
    (.getCanonicalPath (io/file value))
    (catch Throwable cause
      (fail! :invalid-sealed-path (str field " is not canonicalizable")
             {:field field :path value :cause cause}))))

(defn- beagle-facts-command! [beagle]
  (let [command (io/file (.getParentFile (io/file beagle)) "beagle-facts")]
    (when-not (and (.isFile command) (.canExecute command))
      (fail! :missing-sealed-binding
             "FRAM_BEAGLE must have an executable beagle-facts sibling"
             {:beagle beagle}))
    (.getCanonicalPath command)))

(defn- space-id! [code-log]
  (let [bytes (Files/readAllBytes (.toPath (io/file code-log)))]
    (when (< (alength bytes) 16)
      (fail! :invalid-code-log "FRAMLOG header is truncated" {}))
    (when-not (Arrays/equals framlog-magic (Arrays/copyOfRange bytes 0 8))
      (fail! :invalid-code-log "code log is not native FRAMLOG" {}))
    (let [buffer (doto (ByteBuffer/wrap bytes) (.order ByteOrder/LITTLE_ENDIAN))
          _ (.position buffer 8)
          version (bit-and 65535 (int (.getShort buffer)))
          flags (bit-and 65535 (int (.getShort buffer)))
          length (Integer/toUnsignedLong (.getInt buffer))]
      (when-not (and (= 1 version) (zero? flags)
                     (pos? length) (<= length (.remaining buffer)))
        (fail! :invalid-code-log "FRAMLOG header is invalid"
               {:version version :flags flags :space-length length}))
      (try
        (str (.decode (doto (.newDecoder StandardCharsets/UTF_8)
                        (.onMalformedInput CodingErrorAction/REPORT)
                        (.onUnmappableCharacter CodingErrorAction/REPORT))
                      (ByteBuffer/wrap bytes 16 (int length))))
        (catch Throwable cause
          (fail! :invalid-code-log "FRAMLOG SpaceId is not strict UTF-8"
                 {:cause cause}))))))

(defn- inside? [root path]
  (let [root-path (.toPath (io/file root))
        path-value (.toPath (io/file path))]
    (or (= root-path path-value) (.startsWith path-value root-path))))

(defn- module-root-rows! [checkout-root source-root triples]
  (let [ast-modules
        (->> triples
             (keep (fn [triple]
                     (when-let [[_ module]
                                (and (string? (t/triple-t1 triple))
                                     (re-matches #"^@(.+)#[0-9]+$"
                                                 (t/triple-t1 triple)))]
                       module)))
             set)
        roots
        (->> triples
             (keep
              (fn [triple]
                (when-let [[_ module]
                           (and (= "file" (t/triple-t2 triple))
                                (string? (t/triple-t1 triple))
                                (re-matches #"^@(.+)#root$"
                                            (t/triple-t1 triple)))]
                  [module (t/triple-t3 triple)])))
             (group-by first))]
    (when (empty? ast-modules)
      (fail! :module-roots-missing
             "native corpus contains no module AST roots" {}))
    (when-not (= ast-modules (set (keys roots)))
      (fail! :module-roots-missing
             "native corpus module ASTs and registered roots differ"
             {:ast-modules (sort ast-modules)
              :root-modules (sort (keys roots))}))
    (mapv
     (fn [module]
       (let [rows (get roots module)
             values (mapv second rows)]
         (when-not (and (= 1 (count values)) (string? (first values)))
           (fail! :module-roots-invalid
                  "each native module must have one String root"
                  {:module module :roots values}))
         (let [raw (io/file (first values))
               path (canonical-path!
                     (if (.isAbsolute raw)
                       raw (io/file checkout-root (first values)))
                     "module root")]
           (when-not (and (inside? source-root path)
                          (.isFile (io/file path)))
             (fail! :module-root-outside-source
                    "registered module root must be an existing source file"
                    {:module module :root path :source-root source-root}))
           {:module module :root path})))
     (sort ast-modules))))

(defn- unchanged-candidate [module-snapshot]
  (let [base (gate/transformer-snapshot module-snapshot)]
    {:base-version (:version base)
     :module (:module base)
     :ast (:facts base)
     :asserts #{}
     :retracts #{}}))

(defn preflight!
  "Prove server reachability, complete module roots, and one sealed green check."
  []
  (let [checkout-root (canonical-path! (required-env! "FRAM_CHECKOUT_ROOT")
                                       "checkout root")
        source-root (canonical-path! (required-env! "FRAM_SOURCE_ROOT")
                                     "source root")
        code-log (canonical-path! (required-env! "FRAM_CODE_LOG") "code log")
        port (port!)
        space (space-id! code-log)
        corpus (code-reader/read-corpus-snapshot! port space)
        roots (module-root-rows! checkout-root source-root (:triples corpus))
        selected (:module (first roots))
        snapshot (code-reader/module-snapshot-from-corpus!
                  checkout-root selected corpus)
        candidate (unchanged-candidate snapshot)
        request (gate/verifier-request snapshot candidate)
        check (gate/sealed-check! request {})
        rendered (when (:accepted check)
                   (code-reader/render-module!
                    (required-env! "FRAM_BEAGLE") snapshot))
        version-after
        (-> (rt/native-call! port space :rpc/version
                             framrpc/rpc-unit nil nil nil)
            rt/require-native-success!
            t/rpcresponse-served-version)]
    (when-not (:accepted check)
      (fail! :sealed-preflight-rejected
             "sealed module-overlay preflight rejected the current corpus"
             {:module selected :receipt (:receipt check)}))
    (when-not (= (:version corpus) version-after)
      (fail! :preflight-version-drift
             "native corpus changed during graph-control preflight"
             {:before (:version corpus) :after version-after}))
    {:contractVersion preflight-contract
     :ok true
     :service {:name server-name :server "reachable"}
     :corpus {:version (str version-after)
              :moduleCount (count roots)
              :modules (mapv :module roots)
              :rootsPresent true}
     :check {:green true
             :module selected
             :inputDigest (:input-digest request)
             :projectionBytes (count (.getBytes ^String (:source rendered)
                                                StandardCharsets/UTF_8))}}))

(defn- parse-body! [index value]
  (when-not (string? value)
    (fail! :invalid-edit-body
           "each edit body must be one EDN datum encoded as a string"
           {:index index}))
  (try
    (with-open [reader (PushbackReader. (StringReader. value))]
      (let [eof (Object.)
            datum (edn/read {:eof eof} reader)
            tail (edn/read {:eof eof} reader)]
        (when (or (identical? eof datum) (not (identical? eof tail)))
          (fail! :invalid-edit-body
                 "each edit body must contain exactly one EDN datum"
                 {:index index}))
        datum))
    (catch clojure.lang.ExceptionInfo error (throw error))
    (catch Throwable cause
      (fail! :invalid-edit-body "edit body is not valid EDN"
             {:index index :cause cause}))))

(defn- edits! [value]
  (when-not (vector? value)
    (fail! :invalid-edits "edits must be an array" {}))
  (mapv
   (fn [index edit]
     (when-not (and (map? edit)
                    (= #{:name :body} (set (keys edit)))
                    (string? (:name edit))
                    (not (str/blank? (:name edit))))
       (fail! :invalid-edit
              "each edit requires exactly nonblank name and body strings"
              {:index index}))
     {:name (:name edit) :body (parse-body! index (:body edit))})
   (range) value))

(defn- form! [value]
  (when-not (string? value)
    (fail! :invalid-edit-form
           "form must be one EDN datum encoded as a string" {}))
  (let [annotation-token (symbol (str "__fram_annotation_" (gensym)))
        delimiter? #(or (Character/isWhitespace ^Character %)
                        (contains? #{\( \) \[ \] \{ \} \" \; \,} %))
        annotation-name? #(boolean (re-matches
                                     #"[A-Za-z_*+!$%&=<>?][A-Za-z0-9_.*+!$%&=<>?/\\-]*:"
                                     %))
        edn-form
        (loop [chars (seq value) mode :code out (StringBuilder.)]
          (if-let [ch (first chars)]
            (case mode
              :string
              (do (.append out ch)
                  (cond
                    (= ch \\) (if-let [escaped (second chars)]
                               (do (.append out escaped)
                                   (recur (nnext chars) :string out))
                               (recur nil :string out))
                    (= ch \" ) (recur (next chars) :code out)
                    :else (recur (next chars) :string out)))

              :comment
              (do (.append out ch)
                  (recur (next chars) (if (= ch \newline) :code :comment) out))

              (cond
                (= ch \") (do (.append out ch) (recur (next chars) :string out))
                (= ch \;) (do (.append out ch) (recur (next chars) :comment out))
                (delimiter? ch) (do (.append out ch) (recur (next chars) :code out))
                :else (let [[token remaining] (split-with (complement delimiter?) chars)]
                        (.append out (if (annotation-name? (apply str token))
                                       (str (apply str (butlast token)) " " annotation-token)
                                       (apply str token)))
                        (recur remaining :code out))))
            (.toString out)))]
    (try
      (with-open [reader (PushbackReader. (StringReader. edn-form))]
        (let [eof (Object.)
              datum (edn/read {:eof eof} reader)
              tail (edn/read {:eof eof} reader)]
          (when (or (identical? eof datum) (not (identical? eof tail)))
            (fail! :invalid-edit-form
                   "form must contain exactly one EDN datum" {}))
          (walk/postwalk #(if (= annotation-token %) (symbol "#%:") %) datum)))
      (catch clojure.lang.ExceptionInfo error (throw error))
      (catch Throwable cause
        (fail! :invalid-edit-form "form is not valid EDN" {:cause cause})))))

(defn- candidate-snapshot [snapshot candidate]
  {:module (:module snapshot)
   :snapshot (:snapshot snapshot)
   :triples (mapv (fn [[t1 t2 t3]]
                    (t/triple t1 t2 t3))
                  (:ast candidate))})

(defn- sorted-delta [rows]
  (mapv vec (sort-by pr-str rows)))

(defn- committed-affected-definitions [outcome]
  (let [delta (concat (get-in outcome [:committed-delta :asserts])
                      (get-in outcome [:committed-delta :retracts]))
        nodes (into #{} (mapcat (fn [[subject _ object]] [subject object])) delta)]
    (filterv (fn [{:keys [form definition]}]
               (or (contains? nodes form)
                   (contains? nodes definition)
                   (and (nil? form) (nil? definition) (seq delta))))
             (get-in outcome [:candidate :definition-identities]))))

(defn- edit-response [outcome publication]
  (cond->
   {:outcome (name (:outcome publication))
    :module (:module outcome)
    :graphState (name (:graph-state publication))
    :projectionState (name (:projection-state publication))
    :baseVersion (some-> (:base-version outcome) str)
    :committedVersion (some-> (:committed-version outcome) str)}
    (:candidate outcome)
    (assoc :candidateDelta
           {:asserts (sorted-delta (get-in outcome [:candidate :asserts]))
            :retracts (sorted-delta (get-in outcome [:candidate :retracts]))})
    (:committed-delta outcome)
    (assoc :committedDelta
           {:asserts (sorted-delta (get-in outcome [:committed-delta :asserts]))
            :retracts (sorted-delta (get-in outcome [:committed-delta :retracts]))})
    (:projection publication)
    (assoc :projection (:projection publication))
    (:program-view publication)
    (assoc :programView (:program-view publication))
    (:rejection outcome)
    (assoc :rejection (:rejection outcome))))

(defn- edit-module!
  [{:keys [checkout-root port space beagle program-corpus
           program-facts-command]} arguments]
  (when-not (and (map? arguments)
                 (= #{:module :edits} (set (keys arguments)))
                 (string? (:module arguments))
                 (not (str/blank? (:module arguments))))
    (fail! :invalid-tool-arguments
           "multi-set-body requires exactly module and edits" {}))
  (let [checked (atom nil)
        outcome
        (gate/gate-and-commit!
         port space checkout-root (:module arguments) (edits! (:edits arguments))
         {:before-commit
          (fn [{:keys [snapshot candidate]}]
            (let [rendered (code-reader/render-module!
                            beagle (candidate-snapshot snapshot candidate))]
              (reset! checked
                      {:candidate candidate
                       :root (get-in snapshot [:snapshot :root])
                       :bytes (.getBytes ^String (:source rendered)
                                        StandardCharsets/UTF_8)})))})
        checked-value @checked]
    (when (and (= :committed (:type outcome))
               (not= (:candidate outcome) (:candidate checked-value)))
      (fail! :checked-projection-mismatch
             "committed candidate differs from the checked projection"
             {:module (:module outcome)}))
    (let [affected (committed-affected-definitions outcome)
          publication
          (lifecycle/publish-checked-projection!
           {:commit-outcome outcome
            :registered-root checkout-root
            :registered-path (:root checked-value)
            :checked-bytes (:bytes checked-value)
            ;; Materialization needs named identities; without them the corpus
            ;; must stay untouched instead of turning a clean publish into a
            ;; repair-needed state.
            :program-corpus (when (seq affected) program-corpus)
            :program-facts-command program-facts-command
            :affected-definitions affected})]
      {:isError (not= :committed-projection-published
                      (:outcome publication))
       :value (edit-response outcome publication)})))

(defn- edit-top-level!
  [{:keys [checkout-root port space beagle]} tool mode arguments]
  (when-not (and (map? arguments)
                 (= #{:module :form} (set (keys arguments)))
                 (string? (:module arguments))
                 (not (str/blank? (:module arguments))))
    (fail! :invalid-tool-arguments
           (str tool " requires exactly module and form") {}))
  (let [checked (atom nil)
        outcome
        (gate/gate-top-level-and-commit!
         port space checkout-root (:module arguments) mode (form! (:form arguments))
         {:before-commit
          (fn [{:keys [snapshot candidate]}]
            (let [rendered (code-reader/render-module!
                            beagle (candidate-snapshot snapshot candidate))]
              (reset! checked
                      {:candidate candidate
                       :root (get-in snapshot [:snapshot :root])
                       :bytes (.getBytes ^String (:source rendered)
                                        StandardCharsets/UTF_8)})))})
        checked-value @checked]
    (when (and (= :committed (:type outcome))
               (not= (:candidate outcome) (:candidate checked-value)))
      (fail! :checked-projection-mismatch
             "committed candidate differs from the checked projection"
             {:module (:module outcome)}))
    (let [publication
          (lifecycle/publish-checked-projection!
           {:commit-outcome outcome
            :registered-root checkout-root
            :registered-path (:root checked-value)
            :checked-bytes (:bytes checked-value)})]
      {:isError (not= :committed-projection-published
                      (:outcome publication))
       :value (edit-response outcome publication)})))

(def ^:private tools
  ;; Reasoning verbs stay mounted beside the widened edit catalog.
  (into (vec program/tool-descriptors)
  [{:name multi-tool-name
    :description "Atomically replace the bodies of 2..32 definitions in one native module, sealed-check the candidate, and publish its checked projection."
    :inputSchema
    {:type "object"
     :additionalProperties false
     :properties
     {:module {:type "string"}
      :edits {:type "array" :minItems 2 :maxItems 32
              :items {:type "object" :additionalProperties false
                      :properties {:name {:type "string"}
                                   :body {:type "string"
                                          :description "Exactly one EDN datum."}}
                      :required ["name" "body"]}}}
     :required ["module" "edits"]}}
   {:name add-tool-name
    :description "Add one new named top-level Beagle definition, sealed-check the candidate, and publish its checked projection. Existing names reject without committing."
    :inputSchema
    {:type "object"
     :additionalProperties false
     :properties {:module {:type "string"}
                  :form {:type "string"
                         :description "Exactly one named writable top-level EDN form."}}
     :required ["module" "form"]}}
   {:name replace-tool-name
    :description "Replace one existing named top-level Beagle definition, sealed-check the candidate, and publish its checked projection. Missing names reject without committing."
    :inputSchema
    {:type "object"
     :additionalProperties false
     :properties {:module {:type "string"}
                  :form {:type "string"
                         :description "Exactly one named writable top-level EDN form."}}
     :required ["module" "form"]}}]))

(defn- read-program!
  "Serve one advertised program-inspection read against the resolved corpus."
  [{:keys [program-corpus]} tool arguments]
  (when-not program-corpus
    (fail! :program-corpus-unavailable
           "this checkout has no resolved program corpus at .fram/corpus.facts"
           {:tool tool}))
  {:isError false :value (program/invoke-path! program-corpus tool arguments)})

(defn- reply! [id result]
  (println (json/generate-string {:jsonrpc "2.0" :id id :result result}))
  (flush))

(defn- reply-error! [id code message]
  (println (json/generate-string
            {:jsonrpc "2.0" :id id
             :error {:code code :message message}}))
  (flush))

(defn- tool-result [context tool arguments]
  (try
    (case tool
      "multi-set-body" (edit-module! context arguments)
      "add-def" (edit-top-level! context tool :add arguments)
      "replace-def" (edit-top-level! context tool :replace arguments)
      (if (program/program-tool? tool)
        (read-program! context tool arguments)
        {:isError true :value {:type "unknown-tool"
                               :message (str "unknown tool: " tool)}}))
    (catch Throwable error
      {:isError true
       :value {:type (name (or (:type (ex-data error)) :graph-control-error))
               :message (or (.getMessage error) (str (class error)))}})))

(defn- handle! [context request]
  (when (contains? request :id)
    (let [id (:id request)
          method (:method request)]
      (case method
        "initialize"
        (reply! id {:protocolVersion "2024-11-05"
                    :capabilities {:tools {}}
                    :serverInfo {:name server-name :version "1"}
                    :instructions "Sealed native graph control. Use multi-set-body, add-def, or replace-def for atomic checked edits, and read_definition, find_references, trace_impact, occurrence_history, program_context, or inspect_program for snapshot-pinned program reads."})

        "tools/list" (reply! id {:tools tools})

        "tools/call"
        (let [{:keys [isError value]}
              (tool-result context (get-in request [:params :name])
                           (or (get-in request [:params :arguments]) {}))]
          (reply! id {:content [{:type "text"
                                :text (json/generate-string value)}]
                      :isError (boolean isError)}))

        (reply-error! id -32601 (str "method not found: " method))))))

(defn- program-corpus-path
  "Locate fram-code-on's resolved reference corpus for this checkout.

   Absent until it has been emitted; nil then leaves program reads and view
   materialization off rather than failing every checked edit."
  [checkout-root]
  (let [file (io/file checkout-root ".fram" "corpus.facts")]
    (when (.isFile file) (.getCanonicalPath file))))

(defn- service-context! []
  (let [preflight (preflight!)
        code-log (required-env! "FRAM_CODE_LOG")
        checkout-root (canonical-path! (required-env! "FRAM_CHECKOUT_ROOT")
                                       "checkout root")]
    {:preflight preflight
     :checkout-root checkout-root
     :port (port!)
     :space (space-id! code-log)
     :beagle (required-env! "FRAM_BEAGLE")
     :program-corpus (program-corpus-path checkout-root)
     :program-facts-command
     (beagle-facts-command! (required-env! "FRAM_BEAGLE"))}))

(defn- serve! []
  (let [context (service-context!)]
    (binding [*out* *err*]
      (println "fram-graph-control: sealed preflight PASS; ready on stdio"))
    (loop []
      (when-let [line (read-line)]
        (when-not (str/blank? line)
          (let [request
                (try (json/parse-string line true)
                     (catch Throwable _ ::invalid))]
            (cond
              (= ::invalid request)
              (reply-error! nil -32700 "parse error")

              (not (map? request))
              (reply-error! nil -32600 "Invalid Request: batches are unsupported")

              :else
              (try (handle! context request)
                   (catch Throwable error
                     (when (contains? request :id)
                       (reply-error! (:id request) -32603
                                     (or (.getMessage error)
                                         "graph-control failure"))))))))
        (recur)))))

(defn -main [& [command]]
  (case command
    "preflight" (println (json/generate-string (preflight!)))
    "mcp" (serve!)
    (fail! :invalid-command "expected preflight or mcp" {:command command})))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))
