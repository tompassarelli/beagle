(ns fram.program-inspection
  "Snapshot-pinned semantic reads over fram-code-on's resolved corpus."
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.set :as set]
            [clojure.string :as str])
  (:import [java.nio.charset StandardCharsets]
           [java.nio.channels FileChannel]
           [java.nio.file CopyOption Files OpenOption StandardCopyOption
            StandardOpenOption]
           [java.security MessageDigest]
           [java.util Arrays]))

(def named-tool-names
  ["read_definition" "find_references" "trace_impact" "occurrence_history"
   "program_context"])

(def batch-tool-name "inspect_program")

(def program-tool-names (conj named-tool-names batch-tool-name))

(def ^:private operation-tags
  {"read_definition" "read-definition"
   "find_references" "find-references"
   "trace_impact" "trace-impact"
   "occurrence_history" "trace-impact"})

(defn program-tool? [tool]
  (contains? (set program-tool-names) tool))

(defn- fail! [type message data]
  (throw (ex-info message (assoc data :type type))))

(defn- bytes->hex [bytes]
  (apply str (map #(format "%02x" (bit-and 0xff %)) bytes)))

(defn- sha256 [bytes]
  (str "sha256:"
       (bytes->hex (.digest (MessageDigest/getInstance "SHA-256") bytes))))

(def ^:private view-schema "fram.program-view/v1")
(def ^:private version-pattern #"sha256:[0-9a-f]{64}")

(defn- finish-block [{:keys [current blocks] :as state}]
  (if current
    (assoc state :current nil :blocks (conj blocks current))
    state))

(defn- parse-corpus [text]
  (let [{:keys [blocks skipped]}
        (->> (str/split-lines text)
             (reduce
              (fn [{:keys [current] :as state} line]
                (cond
                  (str/starts-with? line "@file ")
                  (assoc (finish-block state)
                         :current {:file (subs line 6) :triples [] :lines []})

                  (str/starts-with? line "[")
                  (if-not current
                    (fail! :invalid-program-corpus
                           "corpus fact appears before its @file anchor" {})
                    (try
                      (let [triple (edn/read-string line)]
                        (if (and (vector? triple) (= 3 (count triple)))
                          (-> state
                              (update-in [:current :triples] conj triple)
                              (update-in [:current :lines] conj line))
                          (fail! :invalid-program-corpus
                                 "corpus fact is not a three-slot vector"
                                 {:line line})))
                      (catch clojure.lang.ExceptionInfo error (throw error))
                      (catch Throwable _
                        (-> state
                            (update :skipped inc)
                            (update-in [:current :lines] conj line)))))

                  current (update-in state [:current :lines] conj line)
                  :else state))
              {:current nil :blocks [] :skipped 0})
             finish-block)]
    (when (empty? blocks)
      (fail! :invalid-program-corpus
             "resolved corpus contains no @file blocks" {}))
    {:blocks blocks :skippedFacts skipped}))

(defn- module-of [file]
  (-> file io/file .getName (str/replace #"\.[^.]+$" "")))

(defn- node-sort-key [node]
  (if (integer? node) [0 node] [1 (pr-str node)]))

(defn- anchor [file node kind]
  {:file file :nodeId node :kind kind})

(defn- identity-of [[file node]]
  (str file "#" node))

(defn- index-by [predicate triples]
  (reduce (fn [result [t1 t2 t3]]
            (if (= predicate t2) (assoc result t1 t3) result))
          {} triples))

(defn- derive-block [{:keys [file triples]}]
  (let [kinds (index-by "form-kind" triples)
        names (index-by "name" triples)
        calls (index-by "calls" triples)
        children (reduce (fn [result [t1 t2 t3]]
                           (if (= "child" t2)
                             (update result t1 (fnil conj []) t3)
                             result))
                         {} triples)
        child-set (set (mapcat identity (vals children)))
        nodes (sort-by node-sort-key (keys kinds))
        roots (remove child-set nodes)
        definitions
        (mapv (fn [node]
                {:key [file node]
                 :identity (identity-of [file node])
                 :name (get names node)
                 :module (module-of file)
                 :file file
                 :node node
                 :anchor (anchor file node "definition")
                 :root-facts (mapv vec (filter #(= node (nth % 0)) triples))})
              (filter #(= "defn" (get kinds %)) nodes))
        mentions
        (loop [stack (vec (reverse (map #(vector % nil) roots)))
               result []]
          (if (empty? stack)
            result
            (let [[node owner] (peek stack)
                  stack* (pop stack)
                  owner* (if (= "defn" (get kinds node)) node owner)
                  result* (if (and owner* (= "call" (get kinds node))
                                   (contains? calls node))
                            (conj result {:caller-key [file owner*]
                                          :call-name (get calls node)
                                          :anchor (anchor file node "reference")})
                            result)
                  next-nodes (reverse (get children node []))]
              (recur (into stack* (map #(vector % owner*) next-nodes))
                     result*))))]
    {:definitions definitions :mentions mentions}))

(defn- resolve-call [by-name caller-key call-name]
  (let [candidates (vec (get by-name call-name []))
        caller-file (first caller-key)
        local (filterv #(= caller-file (first (:key %))) candidates)]
    (cond
      (= 1 (count local)) (:key (first local))
      (= 1 (count candidates)) (:key (first candidates))
      :else nil)))

(defn- reference-indexes [references]
  {:references-by-caller (group-by :caller-key references)
   :references-by-callee (group-by :callee-key references)})

(defn- build-program [blocks]
  (let [derived (mapv derive-block blocks)
        definitions (vec (mapcat :definitions derived))
        by-name (group-by :name definitions)
        references
        (->> derived
             (mapcat :mentions)
             (keep (fn [{:keys [caller-key call-name anchor]}]
                     (when-let [callee-key (resolve-call by-name caller-key call-name)]
                       {:caller-key caller-key
                        :callee-key callee-key
                        :anchor anchor})))
             vec)]
    (merge
     {:definitions (into {} (map (juxt :identity identity) definitions))
      :definitions-by-key (into {} (map (juxt :key identity) definitions))
      :references references}
     (reference-indexes references))))

(defn- version-directory [path]
  (io/file (str (.getCanonicalPath (io/file path)) ".versions")))

(defn- version-token! [version]
  (when-not (and (string? version) (re-matches version-pattern version))
    (fail! :invalid-program-version
           "logicalVersion must be a corpus sha256 digest"
           {:logicalVersion version}))
  (subs version (count "sha256:")))

(defn- version-corpus-file [path version]
  (io/file (version-directory path) (str (version-token! version) ".facts")))

(defn- version-view-file [path version]
  (io/file (version-directory path) (str (version-token! version) ".view.edn")))

(defn- program-from-view [path version]
  (let [file (version-view-file path version)]
    (when (.isFile file)
      (let [lines (str/split-lines (slurp file))
            header (some-> (first lines) edn/read-string)
            row-lines (vec (rest lines))
            rows (mapv edn/read-string row-lines)]
        (when-not (and (= view-schema (:schema header))
                       (= version (:logicalVersion header))
                       (every? #(= #{:semanticIdentity :definition
                                     :inboundEdges :outboundEdges :occurrences}
                                   (set (keys %)))
                               rows))
          (fail! :invalid-program-view
                 "materialized program view is not bound to the requested version"
                 {:path (.getCanonicalPath file)
                  :logicalVersion version}))
        (let [definitions (into {} (map (juxt :semanticIdentity :definition)) rows)
              references (vec (mapcat :outboundEdges rows))]
          (merge
           {:definitions definitions
            :definitions-by-key
            (into {} (map (fn [[_ definition]]
                            [(:key definition) definition])) definitions)
            :references references
            :source-graph-version (:sourceGraphVersion header)
            :view-path (.getCanonicalPath file)
            :raw-view-rows
            (into {} (map (fn [row line] [(:semanticIdentity row) line])
                          rows row-lines))}
           (reference-indexes references)))))))

(defn read-snapshot!
  "Read one current or explicitly pinned immutable corpus image."
  ([path] (read-snapshot! path nil))
  ([path requested-version]
   (let [current-file (io/file path)]
    (when-not (.isFile current-file)
      (fail! :program-corpus-unavailable
             "resolved program corpus is unavailable"
             {:path (.getCanonicalPath current-file)}))
    (let [current-bytes (Files/readAllBytes (.toPath current-file))
          current-version (sha256 current-bytes)
          _ (when requested-version (version-token! requested-version))
          selected-file (if (or (nil? requested-version)
                                (= current-version requested-version))
                          current-file
                          (version-corpus-file path requested-version))
          _ (when-not (.isFile selected-file)
              (fail! :program-version-unavailable
                     "requested program version is unavailable"
                     {:logicalVersion requested-version}))
          bytes (if (= selected-file current-file)
                  current-bytes
                  (Files/readAllBytes (.toPath selected-file)))
          logical-version (sha256 bytes)
          _ (when (and requested-version (not= requested-version logical-version))
              (fail! :invalid-program-view
                     "stored corpus bytes do not match their version key"
                     {:logicalVersion requested-version
                      :actualVersion logical-version}))
          parsed (parse-corpus (String. bytes StandardCharsets/UTF_8))
          program (or (program-from-view path logical-version)
                      (build-program (:blocks parsed)))]
      (merge {:logical-version (sha256 bytes)
              :version-kind "corpus-sha256"
              :path (.getCanonicalPath selected-file)}
             parsed
             program)))))

(defn- exact-map! [arguments allowed required label]
  (when-not (map? arguments)
    (fail! :invalid-tool-arguments (str label " arguments must be an object") {}))
  (let [actual (set (keys arguments))]
    (when-not (and (every? actual required) (every? allowed actual))
      (fail! :invalid-tool-arguments
             (str label " arguments have unknown or missing fields")
             {:allowed (sort allowed) :required (sort required)
              :actual (sort actual)})))
  arguments)

(defn- identity! [arguments]
  (let [identity (:semanticIdentity arguments)]
    (when-not (and (string? identity) (not (str/blank? identity)))
      (fail! :invalid-semantic-identity
             "semanticIdentity must be a nonblank exact corpus identity" {}))
    identity))

(defn- common [snapshot tool identity direction depth anchors]
  {:tool tool
   :operation (get operation-tags tool)
   :outcome "ok"
   :logicalVersion (:logical-version snapshot)
   :versionKind (:version-kind snapshot)
   :semanticIdentity identity
   :sourceAnchors (vec anchors)
   :direction direction
   :depth depth})

(defn- not-found [snapshot tool identity direction depth]
  (assoc (common snapshot tool identity direction depth [])
         :outcome "not-found"
         :message "semanticIdentity is absent from this corpus snapshot"))

(defn- definition! [snapshot identity]
  (get-in snapshot [:definitions identity]))

(defn- read-definition [snapshot arguments]
  (exact-map! arguments #{:semanticIdentity :name :file} #{}
              "read_definition")
  (let [identity-selector (:semanticIdentity arguments)
        name-selector (:name arguments)
        file-selector (:file arguments)
        _ (when-not (or (and (string? identity-selector)
                             (not (str/blank? identity-selector))
                             (nil? name-selector) (nil? file-selector))
                        (and (nil? identity-selector)
                             (string? name-selector)
                             (not (str/blank? name-selector))
                             (or (nil? file-selector)
                                 (and (string? file-selector)
                                      (not (str/blank? file-selector))))))
            (fail! :invalid-definition-selector
                   "read_definition requires semanticIdentity, or name with optional file"
                   {}))
        candidates (if identity-selector
                     (keep identity [(definition! snapshot identity-selector)])
                     (filterv #(and (= name-selector (:name %))
                                    (or (nil? file-selector)
                                        (= file-selector (:file %))))
                              (vals (:definitions snapshot))))
        _ (when (> (count candidates) 1)
            (fail! :ambiguous-definition
                   "definition name is ambiguous; add file or use semanticIdentity"
                   {:candidates (sort (map :identity candidates))}))
        definition (first candidates)
        identity (or (:identity definition) identity-selector)]
    (if-let [definition (definition! snapshot identity)]
      (assoc (common snapshot "read_definition" identity "self" 0
                     [(:anchor definition)])
             :definition (select-keys definition
                                      [:identity :name :module :root-facts]))
      (not-found snapshot "read_definition" identity "self" 0))))

(defn- direction! [arguments allowed]
  (let [direction (:direction arguments)]
    (when-not (contains? allowed direction)
      (fail! :invalid-direction
             (str "direction must be one of " (str/join ", " (sort allowed)))
             {:direction direction}))
    direction))

(defn- reference-view [snapshot seed direction reference]
  (let [related-key (if (= direction "inbound")
                      (:caller-key reference) (:callee-key reference))
        related (get-in snapshot [:definitions-by-key related-key])]
    {:semanticIdentity (:identity related)
     :referenceOf seed
     :ownerIdentity (identity-of (:caller-key reference))
     :relation "calls"
     :sourceAnchors [(:anchor reference)]
     :direction direction
     :depth 1}))

(defn- reference-sort-key [reference]
  (let [{:keys [file nodeId]} (first (:sourceAnchors reference))]
    [file (node-sort-key nodeId) (:direction reference)
     (:semanticIdentity reference)]))

(defn- references-for [snapshot identity direction]
  (let [definition (definition! snapshot identity)
        key (:key definition)
        inbound (when (contains? #{"inbound" "both"} direction)
                  (for [reference (get-in snapshot
                                           [:references-by-callee key] [])]
                    (reference-view snapshot identity "inbound" reference)))
        outbound (when (contains? #{"outbound" "both"} direction)
                   (for [reference (get-in snapshot
                                            [:references-by-caller key] [])]
                     (reference-view snapshot identity "outbound" reference)))]
    (vec (sort-by reference-sort-key (concat inbound outbound)))))

(defn- find-references [snapshot arguments]
  (exact-map! arguments #{:semanticIdentity :direction}
              #{:semanticIdentity :direction} "find_references")
  (let [identity (identity! arguments)
        direction (direction! arguments #{"inbound" "outbound" "both"})]
    (if-let [definition (definition! snapshot identity)]
      (let [references (references-for snapshot identity direction)]
        (assoc (common snapshot "find_references" identity direction 1
                       (mapcat :sourceAnchors references))
               :definitionAnchor (:anchor definition)
               :references references))
      (not-found snapshot "find_references" identity direction 1))))

(defn- trace-nodes [snapshot seed-key direction max-depth]
  (loop [frontier [[seed-key 0]] visited #{seed-key} result []]
    (if (empty? frontier)
      result
      (let [[node depth] (first frontier)
            remaining (subvec (vec frontier) 1)
            next-depth (inc depth)
            references (get-in snapshot
                               [(if (= direction "inbound")
                                  :references-by-callee :references-by-caller)
                                node]
                               [])
            next-nodes (if (< depth max-depth)
                         (->> references
                              (map (if (= direction "inbound")
                                     :caller-key :callee-key))
                              set
                              (remove visited)
                              (sort-by identity-of))
                         [])
            visited* (into visited next-nodes)
            frontier* (into remaining (map #(vector % next-depth) next-nodes))
            result* (into result (map #(vector % next-depth) next-nodes))]
        (recur frontier* visited* result*)))))

(defn- trace-impact [snapshot arguments]
  (exact-map! arguments #{:semanticIdentity :direction :maxDepth}
              #{:semanticIdentity :direction} "trace_impact")
  (let [identity (identity! arguments)
        direction (direction! arguments #{"inbound" "outbound"})
        max-depth (get arguments :maxDepth 32)]
    (when-not (and (integer? max-depth) (<= 1 max-depth 64))
      (fail! :invalid-depth "maxDepth must be an integer from 1 through 64"
             {:maxDepth max-depth}))
    (if-let [definition (definition! snapshot identity)]
      (let [traced (trace-nodes snapshot (:key definition) direction max-depth)
            impacts (mapv (fn [[key depth]]
                            (let [target (get-in snapshot [:definitions-by-key key])]
                              {:semanticIdentity (:identity target)
                               :sourceAnchors [(:anchor target)]
                               :direction direction
                               :depth depth}))
                          traced)
            observed-depth (reduce max 0 (map :depth impacts))]
        (assoc (common snapshot "trace_impact" identity direction observed-depth
                       [(:anchor definition)])
               :maxDepth max-depth
               :impacts impacts))
      (not-found snapshot "trace_impact" identity direction 0))))

(defn- occurrences-for [snapshot identity]
  (let [definition (definition! snapshot identity)
        references (references-for snapshot identity "inbound")]
    (vec
     (sort-by
      (fn [occurrence]
        (let [{:keys [file nodeId]} (:sourceAnchor occurrence)]
          [file (node-sort-key nodeId) (:kind occurrence)]))
      (cons {:kind "definition"
             :semanticIdentity identity
             :ownerIdentity identity
             :sourceAnchor (:anchor definition)
             :direction "self"
             :depth 0}
            (map (fn [reference]
                   {:kind "reference"
                    :semanticIdentity identity
                    :ownerIdentity (:ownerIdentity reference)
                    :sourceAnchor (first (:sourceAnchors reference))
                    :direction "inbound"
                    :depth 1})
                 references))))))

(defn- occurrence-history [snapshot arguments]
  (exact-map! arguments #{:semanticIdentity} #{:semanticIdentity}
              "occurrence_history")
  (let [identity (identity! arguments)]
    (if-let [definition (definition! snapshot identity)]
      (let [occurrences (occurrences-for snapshot identity)]
        (assoc (common snapshot "occurrence_history" identity "inbound" 1
                       (map :sourceAnchor occurrences))
               :occurrenceScope "snapshot-source-order"
               :occurrences occurrences))
      (not-found snapshot "occurrence_history" identity "inbound" 1))))

(defn resolve-corpus-slice!
  "Extract the analysis projection for exactly one published source file."
  [facts-command registered-root target]
  (let [result (shell/sh facts-command target :dir registered-root)]
    (when-not (zero? (:exit result))
      (fail! :program-slice-resolution-failed
             "resolved program slice extraction failed"
             {:target target :exit (:exit result) :stderr (:err result)}))
    (:out result)))

(defn- triple-line [line]
  (when (str/starts-with? line "[")
    (try
      (let [value (edn/read-string line)]
        (when (and (vector? value) (= 3 (count value))) value))
      (catch Throwable _ nil))))

(defn- canonical-block-file [registered-root file]
  (.getCanonicalPath
   (let [value (io/file file)]
     (if (.isAbsolute value) value (io/file registered-root file)))))

(defn- descendants [block root]
  (let [children (reduce (fn [result [subject predicate object]]
                           (if (= "child" predicate)
                             (update result subject (fnil conj []) object)
                             result))
                         {} (:triples block))]
    (loop [pending [root] seen #{}]
      (if-let [node (peek pending)]
        (if (contains? seen node)
          (recur (pop pending) seen)
          (recur (into (pop pending) (get children node []))
                 (conj seen node)))
        seen))))

(defn- definitions-by-name! [block names label]
  (let [matches (group-by :name (:definitions (derive-block block)))]
    (into {}
          (map
           (fn [name]
             (let [definitions (vec (get matches name []))]
               (when-not (= 1 (count definitions))
                 (fail! :program-slice-identity-mismatch
                        (str label " resolved slice must contain one touched definition")
                        {:name name :matches (mapv :identity definitions)}))
               [name (first definitions)])))
          names)))

(defn- max-node [block]
  (reduce (fn [largest [subject _ object]]
            (max largest
                 (if (integer? subject) subject 0)
                 (if (integer? object) object 0)))
          0 (:triples block)))

(defn- remap-triple [mapping [subject predicate object]]
  [(get mapping subject subject) predicate (get mapping object object)])

(defn- replace-definition-slices [current fresh names]
  (let [old-matches (group-by :name (:definitions (derive-block current)))
        _ (doseq [name names]
            (when (> (count (get old-matches name [])) 1)
              (fail! :program-slice-identity-mismatch
                     "current corpus contains an ambiguous touched definition"
                     {:name name
                      :matches (mapv :identity (get old-matches name))})))
        old-definitions (into {} (map (fn [name]
                                        [name (first (get old-matches name []))]))
                              names)
        fresh-definitions (definitions-by-name! fresh names "fresh")
        cursor (atom (inc (max-node current)))
        slices
        (into {}
              (map
               (fn [name]
                 (let [old-root (some-> (get old-definitions name) :node)
                       fresh-root (:node (get fresh-definitions name))
                       old-nodes (if old-root (descendants current old-root) #{})
                       fresh-nodes (descendants fresh fresh-root)
                       mapping
                       (reduce
                        (fn [result node]
                          (if (= node fresh-root)
                            (if old-root
                              (assoc result node old-root)
                              (let [next-node @cursor]
                                (swap! cursor inc)
                                (assoc result node next-node)))
                            (let [next-node @cursor]
                              (swap! cursor inc)
                              (assoc result node next-node))))
                        {} (sort-by node-sort-key fresh-nodes))
                       lines
                       (->> (:lines fresh)
                            (keep (fn [line]
                                    (when-let [triple (triple-line line)]
                                      (when (contains? fresh-nodes (first triple))
                                        (pr-str (remap-triple mapping triple))))))
                            vec)]
                   [name {:old-nodes old-nodes :lines lines}])))
              names)
        owner-of
        (into {}
              (mapcat (fn [[name {:keys [old-nodes]}]]
                        (map #(vector % name) old-nodes)))
              slices)
        replaced
        (reduce
         (fn [{:keys [inserted lines] :as state} line]
           (if-let [name (some-> line triple-line first owner-of)]
             (if (contains? inserted name)
               state
               {:inserted (conj inserted name)
                :lines (into lines (get-in slices [name :lines]))})
             (update state :lines conj line)))
         {:inserted #{} :lines []} (:lines current))
        added (remove (:inserted replaced) names)
        lines (reduce (fn [result name]
                        (into result (get-in slices [name :lines])))
                      (:lines replaced) added)]
    (let [text (str "@file " (:file current) "\n"
                    (str/join "\n" lines) "\n")]
      (first (:blocks (parse-corpus text))))))

(defn- corpus-bytes [blocks]
  (.getBytes
   (apply str
          (map (fn [{:keys [file lines]}]
                 (str "@file " file "\n" (str/join "\n" lines) "\n"))
               blocks))
   StandardCharsets/UTF_8))

(defn- reference-order [{:keys [caller-key callee-key anchor]}]
  [(:file anchor) (node-sort-key (:nodeId anchor))
   (identity-of caller-key) (identity-of callee-key)])

(defn- incremental-program [snapshot merged-block names]
  (let [new-by-name (definitions-by-name! merged-block names "merged")
        old-definitions (:definitions snapshot)
        prior-touched
        (into {}
              (map (fn [name]
                     [name (first (filter #(and (= name (:name %))
                                               (= (:file merged-block) (:file %)))
                                          (vals old-definitions)))]))
              names)
        _ (doseq [name names]
            (when (and (get prior-touched name)
                       (not= (:identity (get prior-touched name))
                             (:identity (get new-by-name name))))
              (fail! :program-slice-identity-mismatch
                     "touched definition identity changed during slice refresh"
                     {:name name
                      :before (:identity (get prior-touched name))
                      :after (:identity (get new-by-name name))})))
        definitions (reduce (fn [result name]
                              (assoc result (:identity (get new-by-name name))
                                     (get new-by-name name)))
                            old-definitions names)
        definitions-by-key
        (into {} (map (fn [[_ definition]] [(:key definition) definition]))
              definitions)
        prior-keys (into #{} (keep (comp :key val)) prior-touched)
        affected-keys (set (map (comp :key new-by-name) names))
        removed (filterv #(contains? prior-keys (:caller-key %))
                         (:references snapshot))
        retained (remove #(contains? prior-keys (:caller-key %))
                         (:references snapshot))
        by-name (group-by :name (vals definitions))
        added
        (->> (:mentions (derive-block merged-block))
             (filter #(contains? affected-keys (:caller-key %)))
             (keep (fn [{:keys [caller-key call-name anchor]}]
                     (when-let [callee-key (resolve-call by-name caller-key call-name)]
                       {:caller-key caller-key :callee-key callee-key :anchor anchor})))
             vec)
        references (vec (sort-by reference-order (concat retained added)))
        affected-callee-keys
        (set/union (set (map :callee-key removed)) (set (map :callee-key added)))
        invalidated-identities
        (set/union
         (set (map (comp :identity new-by-name) names))
         (into #{} (keep #(some-> definitions-by-key (get %) :identity))
               affected-callee-keys))]
    (merge
     {:definitions definitions
      :definitions-by-key definitions-by-key
      :references references
      :invalidated-identities invalidated-identities}
     (reference-indexes references))))

(defn- identity-view-row [snapshot identity]
  (let [definition (get-in snapshot [:definitions identity])
        key (:key definition)]
    (array-map
     :semanticIdentity identity
     :definition definition
     :inboundEdges (vec (sort-by reference-order
                                 (get-in snapshot [:references-by-callee key] [])))
     :outboundEdges (vec (sort-by reference-order
                                  (get-in snapshot [:references-by-caller key] [])))
     :occurrences (occurrences-for snapshot identity))))

(defn- render-view [snapshot logical-version source-version reusable invalidated]
  (let [header (pr-str (array-map :schema view-schema
                                  :logicalVersion logical-version
                                  :sourceGraphVersion source-version))
        rows
        (into {}
              (map
               (fn [identity]
                 [identity
                  (if (and (not (contains? invalidated identity))
                           (contains? reusable identity))
                    (get reusable identity)
                    (pr-str (identity-view-row snapshot identity)))]))
              (sort (keys (:definitions snapshot))))
        text (str header "\n" (str/join "\n" (map rows (sort (keys rows)))) "\n")]
    {:bytes (.getBytes text StandardCharsets/UTF_8) :rows rows}))

(defn- atomic-write! [file bytes]
  (.mkdirs (.getParentFile (io/file file)))
  (let [path (.toPath (io/file file))
        temp (Files/createTempFile (.getParent path) ".fram-program-view-" ".tmp"
                                   (make-array java.nio.file.attribute.FileAttribute 0))]
    (try
      (Files/write temp bytes (make-array java.nio.file.OpenOption 0))
      (with-open [channel (FileChannel/open temp
                                           (into-array OpenOption
                                                       [StandardOpenOption/WRITE]))]
        (.force channel true))
      (Files/move temp path
                  (into-array CopyOption
                              [StandardCopyOption/ATOMIC_MOVE
                               StandardCopyOption/REPLACE_EXISTING]))
      (finally (Files/deleteIfExists temp)))))

(defn- write-immutable! [file bytes]
  (if (.isFile (io/file file))
    (when-not (Arrays/equals bytes (Files/readAllBytes (.toPath (io/file file))))
      (fail! :program-version-collision
             "immutable program version path contains different bytes"
             {:path (.getCanonicalPath (io/file file))}))
    (atomic-write! file bytes)))

(defn materialize-committed-view!
  "Incrementally replace touched definition slices and publish an immutable view."
  [{:keys [path registered-root registered-path resolved-slice
           affected-definitions committed-version]}]
  (let [names (mapv :name affected-definitions)]
    (when-not (and (seq names) (= (count names) (count (set names))))
      (fail! :invalid-program-delta
             "committed delta must name distinct affected definitions"
             {:affectedDefinitions affected-definitions}))
    (let [old-snapshot (read-snapshot! path)
          target (canonical-block-file registered-root registered-path)
          current-index
          (first (keep-indexed
                  (fn [index block]
                    (when (= target (canonical-block-file registered-root (:file block)))
                      index))
                  (:blocks old-snapshot)))
          _ (when (nil? current-index)
              (fail! :program-slice-unregistered
                     "published source file is absent from the resolved corpus"
                     {:registeredPath registered-path}))
          current-block (nth (:blocks old-snapshot) current-index)
          fresh-parsed (parse-corpus resolved-slice)
          _ (when-not (= 1 (count (:blocks fresh-parsed)))
              (fail! :invalid-program-slice
                     "resolved commit slice must contain exactly one file block"
                     {:blocks (count (:blocks fresh-parsed))}))
          fresh-block (assoc (first (:blocks fresh-parsed)) :file (:file current-block))
          merged-block (replace-definition-slices current-block fresh-block names)
          blocks (assoc (vec (:blocks old-snapshot)) current-index merged-block)
          new-corpus-bytes (corpus-bytes blocks)
          old-corpus-bytes (Files/readAllBytes (.toPath (io/file path)))
          old-version (:logical-version old-snapshot)
          new-version (sha256 new-corpus-bytes)
          program (incremental-program old-snapshot merged-block names)
          old-view (render-view old-snapshot old-version
                                (:source-graph-version old-snapshot) {} #{})
          reusable (merge (:rows old-view) (:raw-view-rows old-snapshot))
          new-snapshot (merge {:logical-version new-version
                               :version-kind "corpus-sha256"
                               :source-graph-version committed-version}
                              program)
          new-view (render-view new-snapshot new-version committed-version
                                reusable (:invalidated-identities program))
          old-corpus-file (version-corpus-file path old-version)
          old-view-file (version-view-file path old-version)
          new-corpus-file (version-corpus-file path new-version)
          new-view-file (version-view-file path new-version)]
      (write-immutable! old-corpus-file old-corpus-bytes)
      (write-immutable! old-view-file (:bytes old-view))
      (write-immutable! new-corpus-file new-corpus-bytes)
      (write-immutable! new-view-file (:bytes new-view))
      (atomic-write! (io/file path) new-corpus-bytes)
      {:logical-version new-version
       :previous-version old-version
       :source-graph-version committed-version
       :path (.getCanonicalPath new-corpus-file)
       :view-path (.getCanonicalPath new-view-file)
       :invalidated-identities (vec (sort (:invalidated-identities program)))
       :reused-identities
       (vec (sort (set/difference (set (keys (:definitions program)))
                                  (:invalidated-identities program))))})))

(def ^:private context-default-token-budget 1200)
(def ^:private context-min-token-budget 512)
(def ^:private context-max-token-budget 8192)
(def ^:private context-hub-degree 16)
(def ^:private context-hub-neighbor-limit 8)
(def ^:private context-impact-limit 8)

(defn- response-tokens [value]
  (long (Math/ceil (/ (double (count (pr-str value))) 4.0))))

(defn- context-neighbor [reference]
  (select-keys reference [:semanticIdentity :relation :sourceAnchors :depth]))

(defn- context-neighbors [references requested-limit]
  (let [degree (count references)
        limit (min degree requested-limit
                   (if (> degree context-hub-degree) context-hub-neighbor-limit degree))]
    {:degree degree
     :neighbors (mapv context-neighbor (take limit references))
     :suppressed (> degree limit)}))

(defn- context-impact [snapshot definition direction requested-limit]
  (let [traced (trace-nodes snapshot (:key definition) direction 64)
        total (count traced)
        limit (min context-impact-limit requested-limit)
        impacts (take limit traced)]
    {:count total
     :affectedIdentities
     (mapv (fn [[key depth]]
             (let [target (get-in snapshot [:definitions-by-key key])]
               {:semanticIdentity (:identity target)
                :sourceAnchors [(:anchor target)]
                :depth depth}))
           impacts)
     :suppressed (> total limit)}))

(defn- context-packet [snapshot definition token-budget neighbor-limit impact-limit body-slice]
  (let [identity (:identity definition)
        inbound (references-for snapshot identity "inbound")
        outbound (references-for snapshot identity "outbound")
        base
        (array-map
         :tool "program_context"
         :outcome "ok"
         :logicalVersion (:logical-version snapshot)
         :versionKind (:version-kind snapshot)
         :semanticIdentity identity
         :querySeed {:semanticIdentity identity :sourceAnchors [(:anchor definition)]}
         :definition {:signature {:name (:name definition) :module (:module definition)}
                      :bodySlice body-slice
                      :sourceAnchors [(:anchor definition)]}
         :relationships {:callers (context-neighbors inbound neighbor-limit)
                         :callees (context-neighbors outbound neighbor-limit)}
         :impactSummary {:inbound (context-impact snapshot definition "inbound" impact-limit)
                         :outbound (context-impact snapshot definition "outbound" impact-limit)}
         :tokenBudget token-budget)]
    base))

(defn- program-context [snapshot arguments]
  (exact-map! arguments #{:semanticIdentity :tokenBudget} #{:semanticIdentity}
              "program_context")
  (let [identity (identity! arguments)
        token-budget (get arguments :tokenBudget context-default-token-budget)]
    (when-not (and (integer? token-budget)
                   (<= context-min-token-budget token-budget context-max-token-budget))
      (fail! :invalid-token-budget
             "tokenBudget must be an integer from 512 through 8192"
             {:tokenBudget token-budget}))
    (if-let [definition (definition! snapshot identity)]
      (let [full (context-packet snapshot definition token-budget
                                 context-hub-neighbor-limit context-impact-limit
                                 (:root-facts definition))]
        (if (<= (response-tokens full) token-budget)
          full
          (assoc (context-packet snapshot definition token-budget 1 1
                                 (filterv #(= "body" (nth % 1))
                                          (:root-facts definition)))
                 :truncated true
                 :narrowingAdvice
                 "Use read_definition, find_references, or trace_impact with one direction to narrow this context.")))
      (not-found snapshot "program_context" identity "both" 0))))

(defn execute-named
  "Execute one named request against an already-pinned snapshot."
  [snapshot tool arguments]
  (let [requested-version (:logicalVersion arguments)
        _ (when (and requested-version
                     (not= requested-version (:logical-version snapshot)))
            (fail! :program-version-mismatch
                   "request version does not match the pinned snapshot"
                   {:requestedVersion requested-version
                    :logicalVersion (:logical-version snapshot)}))
        arguments (dissoc arguments :logicalVersion)]
    (case tool
      "read_definition" (read-definition snapshot arguments)
      "find_references" (find-references snapshot arguments)
      "trace_impact" (trace-impact snapshot arguments)
      "occurrence_history" (occurrence-history snapshot arguments)
      "program_context" (program-context snapshot arguments)
      (fail! :unknown-program-tool (str "unknown program inspection tool: " tool)
             {:tool tool}))))

(defn- child-error [snapshot tag request error]
  {:tag tag
   :request request
   :outcome "error"
   :logicalVersion (:logical-version snapshot)
   :versionKind (:version-kind snapshot)
   :error {:type (name (or (:type (ex-data error)) :program-inspection-error))
           :message (or (.getMessage error) (str (class error)))}})

(defn inspect-program
  "Execute ordered children against one immutable snapshot, preserving every tag."
  [snapshot arguments]
  (exact-map! arguments #{:requests :logicalVersion} #{:requests} "inspect_program")
  (let [requested-version (:logicalVersion arguments)
        _ (when (and requested-version
                     (not= requested-version (:logical-version snapshot)))
            (fail! :program-version-mismatch
                   "batch version does not match the pinned snapshot"
                   {:requestedVersion requested-version
                    :logicalVersion (:logical-version snapshot)}))
        requests (:requests arguments)]
    (when-not (and (vector? requests) (<= 1 (count requests) 32))
      (fail! :invalid-inspection-batch
             "requests must be an array containing 1..32 named requests" {}))
    {:tool batch-tool-name
     :outcome "ok"
     :logicalVersion (:logical-version snapshot)
     :versionKind (:version-kind snapshot)
     :children
     (mapv
      (fn [child]
        (let [tag (when (map? child) (:tag child))
              request (when (map? child) (:request child))]
          (try
            (exact-map! child #{:tag :request :arguments}
                        #{:tag :request :arguments} "inspect_program child")
            (when-not (and (string? tag) (not (str/blank? tag)))
              (fail! :invalid-inspection-tag "each child tag must be nonblank" {}))
            (when-not (contains? (set named-tool-names) request)
              (fail! :invalid-inspection-request
                     "each child request must name a program inspection tool"
                     {:request request}))
            (merge {:tag tag :request request}
                   (execute-named snapshot request (:arguments child)))
            (catch Throwable error
              (child-error snapshot tag request error)))))
      requests)}))

(defn invoke-path!
  "Load one snapshot and execute either a named read or the typed batch."
  [path tool arguments]
  (let [snapshot (read-snapshot! path (:logicalVersion arguments))]
    (if (= batch-tool-name tool)
      (inspect-program snapshot arguments)
      (execute-named snapshot tool arguments))))

(def ^:private identity-schema
  {:type "object" :additionalProperties false
   :properties {:semanticIdentity {:type "string" :minLength 1}
                :logicalVersion {:type "string"
                                 :pattern "^sha256:[0-9a-f]{64}$"}}
   :required ["semanticIdentity"]})

(def ^:private definition-schema
  {:type "object"
   :oneOf
   [identity-schema
    {:type "object" :additionalProperties false
     :properties {:name {:type "string" :minLength 1}
                  :file {:type "string" :minLength 1}
                  :logicalVersion {:type "string"
                                   :pattern "^sha256:[0-9a-f]{64}$"}}
     :required ["name"]}]})

(def ^:private reference-schema
  {:type "object" :additionalProperties false
   :properties {:semanticIdentity {:type "string" :minLength 1}
                :direction {:type "string"
                            :enum ["inbound" "outbound" "both"]}
                :logicalVersion {:type "string"
                                 :pattern "^sha256:[0-9a-f]{64}$"}}
   :required ["semanticIdentity" "direction"]})

(def ^:private impact-schema
  {:type "object" :additionalProperties false
   :properties {:semanticIdentity {:type "string" :minLength 1}
                :direction {:type "string" :enum ["inbound" "outbound"]}
                :maxDepth {:type "integer" :minimum 1 :maximum 64}
                :logicalVersion {:type "string"
                                 :pattern "^sha256:[0-9a-f]{64}$"}}
   :required ["semanticIdentity" "direction"]})

(def ^:private context-schema
  {:type "object" :additionalProperties false
   :properties {:semanticIdentity {:type "string" :minLength 1}
                :tokenBudget {:type "integer" :minimum 512 :maximum 8192}
                :logicalVersion {:type "string"
                                 :pattern "^sha256:[0-9a-f]{64}$"}}
   :required ["semanticIdentity"]})

(defn- batch-child-schema [request argument-schema]
  {:type "object" :additionalProperties false
   :properties {:tag {:type "string" :minLength 1}
                :request {:const request}
                :arguments argument-schema}
   :required ["tag" "request" "arguments"]})

(def tool-descriptors
  [{:name "read_definition"
    :description "Resolve a definition by exact semantic identity or by name plus optional file in the pinned corpus. Returns structural anchors and root facts; use text to read the rendered body."
    :inputSchema definition-schema}
   {:name "find_references"
    :description "Find direct scope-resolved inbound or outbound references for one exact semantic identity."
    :inputSchema reference-schema}
   {:name "trace_impact"
    :description "Trace transitive callers or callees from one exact semantic identity with bounded depth."
    :inputSchema impact-schema}
   {:name "occurrence_history"
    :description "List the definition and its resolved reference occurrences in deterministic source order for one corpus snapshot."
    :inputSchema identity-schema}
   {:name "program_context"
    :description "Return one snapshot-pinned, token-bounded context packet: definition slice, direct callers/callees, and transitive impact summaries. High-degree relationships are curtailed deterministically."
    :inputSchema context-schema}
   {:name batch-tool-name
    :description "Execute 1..32 ordered named program reads against one immutable corpus version, preserving each child tag and outcome."
    :inputSchema
    {:type "object" :additionalProperties false
     :properties
     {:logicalVersion {:type "string"
                       :pattern "^sha256:[0-9a-f]{64}$"}
      :requests
      {:type "array" :minItems 1 :maxItems 32
       :items
       {:oneOf [(batch-child-schema "read_definition" definition-schema)
                (batch-child-schema "find_references" reference-schema)
                (batch-child-schema "trace_impact" impact-schema)
                (batch-child-schema "occurrence_history" identity-schema)
                (batch-child-schema "program_context" context-schema)]}}}
     :required ["requests"]}}])
