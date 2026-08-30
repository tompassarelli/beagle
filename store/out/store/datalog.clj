(ns store.datalog
  (:require [store.rotation :as rot]
            [store.store :as store]
            [store.types :as t]
            [store.text-index :as text-index]
            [store.text-search :as text-search]))

(defrecord QueryTerm [variable value])

(defn queryterm-variable [r] (:variable r))

(defn queryterm-value [r] (:value r))

(defrecord Literal [kind relation arguments negated operator binding])

(defn literal-kind [r] (:kind r))

(defn literal-relation [r] (:relation r))

(defn literal-arguments [r] (:arguments r))

(defn literal-negated [r] (:negated r))

(defn literal-operator [r] (:operator r))

(defn literal-binding [r] (:binding r))

(defrecord Rule [head-relation head-arguments body])

(defn rule-head-relation [r] (:head-relation r))

(defn rule-head-arguments [r] (:head-arguments r))

(defn rule-body [r] (:body r))

(defrecord QueryEvaluationError [error-type code message reason steps max-steps timeout-ms bytes maximum])

(defn queryevaluationerror-error-type [r] (:error-type r))

(defn queryevaluationerror-code [r] (:code r))

(defn queryevaluationerror-message [r] (:message r))

(defn queryevaluationerror-reason [r] (:reason r))

(defn queryevaluationerror-steps [r] (:steps r))

(defn queryevaluationerror-max-steps [r] (:max-steps r))

(defn queryevaluationerror-timeout-ms [r] (:timeout-ms r))

(defn queryevaluationerror-bytes [r] (:bytes r))

(defn queryevaluationerror-maximum [r] (:maximum r))

(defrecord QueryControl [steps cancelled max-steps deadline-ns timeout-ms])

(defn querycontrol-steps [r] (:steps r))

(defn querycontrol-cancelled [r] (:cancelled r))

(defn querycontrol-max-steps [r] (:max-steps r))

(defn querycontrol-deadline-ns [r] (:deadline-ns r))

(defn querycontrol-timeout-ms [r] (:timeout-ms r))

(defrecord QueryEvaluationContext [control error])

(defn queryevaluationcontext-control [r] (:control r))

(defn queryevaluationcontext-error [r] (:error r))

(defrecord QueryEvaluationResult [db error])

(defn queryevaluationresult-db [r] (:db r))

(defn queryevaluationresult-error [r] (:error r))

(defrecord BuiltinValueResult [int-value double-value])

(defn builtinvalueresult-int-value [r] (:int-value r))

(defn builtinvalueresult-double-value [r] (:double-value r))

(defrecord OccurrenceCandidateSource [root lower-exclusive upper-inclusive postings])

(defn occurrencecandidatesource-root [r] (:root r))

(defn occurrencecandidatesource-lower-exclusive [r] (:lower-exclusive r))

(defn occurrencecandidatesource-upper-inclusive [r] (:upper-inclusive r))

(defn occurrencecandidatesource-postings [r] (:postings r))

(defrecord RotationCandidateSource [rotation lower-exclusive])

(defn rotationcandidatesource-rotation [r] (:rotation r))

(defn rotationcandidatesource-lower-exclusive [r] (:lower-exclusive r))

;; CandidateSourceValue = CandidateSource | StoreCandidateSource | VirtualCandidateSource
(defrecord CandidateSource [rows positions spo pos osp occurrence rotation])

(defn candidatesource-rows [r] (:rows r))

(defn candidatesource-positions [r] (:positions r))

(defn candidatesource-spo [r] (:spo r))

(defn candidatesource-pos [r] (:pos r))

(defn candidatesource-osp [r] (:osp r))

(defn candidatesource-occurrence [r] (:occurrence r))

(defn candidatesource-rotation [r] (:rotation r))
(defrecord StoreCandidateSource [root])

(defn storecandidatesource-root [r] (:root r))
(defrecord VirtualCandidateSource [relation source])

(defn virtualcandidatesource-relation [r] (:relation r))

(defn virtualcandidatesource-source [r] (:source r))

(defrecord CandidateSourcesResult [sources error])

(defn candidatesourcesresult-sources [r] (:sources r))

(defn candidatesourcesresult-error [r] (:error r))

(def ^String triple-relation "triple")

(def ^String occurrence-relation "occurrence")

(def ^String withdrawal-relation "withdrawal")

(def ^String text-match-relation "text-match")

(def ^String text-phrase-relation "text-phrase")

(def ^String text-substring-relation "text-substring")

(def ^String text-stem-relation "text-stem")

(def ^String text-search-relation "text-search")

(def text-relations #{text-match-relation text-phrase-relation text-substring-relation text-stem-relation text-search-relation})

(def base-relations (conj text-relations triple-relation occurrence-relation withdrawal-relation))

(def comparison-operators #{:eq :ne :lt :le :gt :ge})

(def subtract-operator (keyword "-"))

(def builtin-operators #{:+ subtract-operator :* :/ :mod})

(def ^:dynamic *query-control* nil)

(defn- next-query-step [steps]
  (inc steps))

(defn- query-cancellation-cell [reason]
  (atom reason))

(def no-query-evaluation-error nil)

(defn- query-evaluation-error-cell []
  (atom no-query-evaluation-error))

(defn preserve-first-query-evaluation-error [current ^QueryEvaluationError incoming]
  (if current current incoming))

(defn ^QueryControl query-control [max-steps timeout-ms]
  (if (and (> max-steps 0) (>= timeout-ms 0)) (let [steps (atom 0)
   cancelled (query-cancellation-cell nil)]
  (->QueryControl steps cancelled max-steps (+ (System/nanoTime) (* timeout-ms 1000000)) timeout-ms)) (throw (ex-info "store: query limits must be positive steps and non-negative milliseconds" {:type :invalid-query-control}))))

(defn cancel-query! [^QueryControl control reason]
  (reset! (querycontrol-cancelled control) reason)
  nil)

(defn query-steps [^QueryControl control]
  (deref (querycontrol-steps control)))

(defn ^QueryEvaluationContext new-query-evaluation-context [control]
  (->QueryEvaluationContext control (query-evaluation-error-cell)))

(defn ^QueryEvaluationError query-evaluation-error [error-type code ^String message]
  (->QueryEvaluationError error-type code message nil nil nil nil nil nil))

(defn ^QueryEvaluationError query-evaluation-limit-error [error-type code ^String message bytes maximum]
  (->QueryEvaluationError error-type code message nil nil nil nil bytes maximum))

(defn ^QueryEvaluationError query-evaluation-error-from-text-error [error-value]
  (if (text-index/texterror-limit-data error-value) (query-evaluation-limit-error (text-index/texterror-type error-value) (text-index/texterror-code error-value) (text-index/texterror-message error-value) (text-index/texterror-bytes error-value) (text-index/texterror-maximum error-value)) (query-evaluation-error (text-index/texterror-type error-value) (text-index/texterror-code error-value) (text-index/texterror-message error-value))))

(defn record-query-evaluation-error! [^QueryEvaluationContext context ^QueryEvaluationError error-value]
  (compare-and-set! (queryevaluationcontext-error context) no-query-evaluation-error error-value)
  nil)

(defn query-evaluation-context-error [^QueryEvaluationContext context]
  (deref (queryevaluationcontext-error context)))

(defn ^Boolean query-evaluation-context-open? [^QueryEvaluationContext context]
  (nil? (query-evaluation-context-error context)))

(defn ^Boolean query-evaluation-ok? [^QueryEvaluationResult result]
  (nil? (queryevaluationresult-error result)))

(defn query-evaluation-db [^QueryEvaluationResult result]
  (queryevaluationresult-db result))

(defn query-evaluation-result-error [^QueryEvaluationResult result]
  (queryevaluationresult-error result))

(defn query-evaluation-error-code [^QueryEvaluationError error-value]
  (queryevaluationerror-code error-value))

(defn query-evaluation-error-type [^QueryEvaluationError error-value]
  (queryevaluationerror-error-type error-value))

(defn ^String query-evaluation-error-message [^QueryEvaluationError error-value]
  (queryevaluationerror-message error-value))

(defn- query-evaluation-error-data [^QueryEvaluationError error-value]
  (let [error-type (queryevaluationerror-error-type error-value)
   code (queryevaluationerror-code error-value)
   steps (queryevaluationerror-steps error-value)
   bytes (queryevaluationerror-bytes error-value)]
  (cond
  (and (= error-type :store-query-abort) (some? steps)) {:type :store-query-abort :code code :reason (queryevaluationerror-reason error-value) :steps steps :max-steps (queryevaluationerror-max-steps error-value) :timeout-ms (queryevaluationerror-timeout-ms error-value)}
  (= error-type :store-query-abort) {:type :store-query-abort :code code}
  (and (= error-type :query-text-index-limit) (some? bytes)) {:type :query-text-index-limit :store/code code :bytes bytes :maximum (queryevaluationerror-maximum error-value)}
  :else {:type error-type :store/code code})))

(defn raise-query-evaluation-error [^QueryEvaluationError error-value]
  (throw (ex-info (queryevaluationerror-message error-value) (query-evaluation-error-data error-value))))

(defn raise-query-evaluation-error! [^QueryEvaluationError error-value]
  (raise-query-evaluation-error error-value))

(defn- query-evaluation-db-or-throw! [^QueryEvaluationResult result]
  (let [error-value (queryevaluationresult-error result)]
  (if (some? error-value) (raise-query-evaluation-error error-value) (queryevaluationresult-db result))))

(defn- ^Boolean query-check! [^QueryEvaluationContext context]
  (if (not (query-evaluation-context-open? context)) false (let [control (queryevaluationcontext-control context)]
  (if (nil? control) true (let [steps (swap! (querycontrol-steps control) next-query-step)
   now (System/nanoTime)
   cancelled (deref (querycontrol-cancelled control))
   code (cond
  (some? cancelled) :query-cancelled
  (> steps (querycontrol-max-steps control)) :query-work-limit
  (>= now (querycontrol-deadline-ns control)) :query-time-limit
  :else nil)]
  (if (nil? code) true (let [message (cond
  (= code :query-cancelled) "query evaluation stopped: query-cancelled"
  (= code :query-work-limit) "query evaluation stopped: query-work-limit"
  :else "query evaluation stopped: query-time-limit")]
  (record-query-evaluation-error! context (->QueryEvaluationError :store-query-abort code message cancelled steps (querycontrol-max-steps control) (querycontrol-timeout-ms control) nil nil))
  false)))))))

(defn ^QueryTerm variable [^String name]
  (if (pos? (count name)) (->QueryTerm name nil) (throw (ex-info "store: query variable name must be non-empty" {:type :invalid-query-variable}))))

(defn ^QueryTerm constant [value]
  (if (t/term? value) (->QueryTerm nil value) (throw (ex-info "store: query constant must be a Term" {:type :invalid-query-constant}))))

(defn ^Boolean query-term? [value]
  (and (instance? QueryTerm value) (if (some? (queryterm-variable value)) (and (pos? (count (queryterm-variable value))) (nil? (queryterm-value value))) (t/term? (queryterm-value value)))))

(defn ^Literal relation-literal [^String relation arguments]
  (->Literal :relation relation arguments false :none ""))

(defn ^Literal negated-literal [^String relation arguments]
  (->Literal :relation relation arguments true :none ""))

(defn ^Literal comparison-literal [operator arguments]
  (->Literal :comparison "" arguments false operator ""))

(defn ^Literal builtin-literal [operator arguments ^String binding]
  (->Literal :builtin "" arguments false operator binding))

(defn ^Rule rule [^String head-relation head-arguments body]
  (->Rule head-relation head-arguments body))

(defn- triple-row [value]
  [(t/triple-t1 value) (t/triple-t2 value) (t/triple-t3 value)])

(defn- rows [triples]
  (reduce (fn [acc value] (conj acc (triple-row value))) #{} triples))

(defn- occurrence-row [value]
  [(t/operationoccurrence-coordinate value) (t/operationoccurrence-action value) (t/operationoccurrence-proposition value)])

(defn- occurrence-rows [occurrences]
  (reduce (fn [acc value] (conj acc (occurrence-row value))) #{} occurrences))

(defn- withdrawal-row [value]
  [(t/operationoccurrence-coordinate (t/withdrawal-retraction value)) (t/operationoccurrence-coordinate (t/withdrawal-assertion value))])

(defn- withdrawal-rows [withdrawals]
  (reduce (fn [acc value] (conj acc (withdrawal-row value))) #{} withdrawals))

(defn edb [propositions]
  {triple-relation (rows propositions)})

(defn edb-with-history [propositions occurrences withdrawals]
  {triple-relation (rows propositions) occurrence-relation (occurrence-rows occurrences) withdrawal-relation (withdrawal-rows withdrawals)})

(defn- term-value [^QueryTerm term subst]
  (let [name (queryterm-variable term)]
  (if (some? name) (get subst name) (queryterm-value term))))

(defn- unify [^QueryTerm term value subst]
  (let [name (queryterm-variable term)]
  (if (some? name) (if (contains? subst name) (if (= (get subst name) value) subst nil) (assoc subst name value)) (if (= (queryterm-value term) value) subst nil))))

(defn- unify-arguments-controlled! [arguments tuple subst ^QueryEvaluationContext context]
  (if (not (query-check! context)) nil (if (not (= (count arguments) (count tuple))) nil (loop [position 0
   current subst]
  (if (or (nil? current) (>= position (count arguments))) current (recur (+ position 1) (unify (nth arguments position) (nth tuple position) current)))))))

(defn- unify-arguments! [arguments tuple subst ^QueryEvaluationContext context]
  (unify-arguments-controlled! arguments tuple subst context))

(defn- ground [arguments subst]
  (mapv (fn [^QueryTerm term] (let [value (term-value term subst)]
  (if (some? value) value (throw (ex-info "store: unbound query variable reached evaluation" {:type :unbound-query-variable}))))) arguments))

(defn- integer-value [value]
  (cond
  (integer? value) value
  (string? value) (parse-long value)
  :else nil))

(defn- numeric-value [value]
  (cond
  (integer? value) (double value)
  (number? value) (double value)
  (string? value) (let [integer-result (parse-long value)]
  (if (some? integer-result) (double integer-result) (parse-double value)))
  :else nil))

(defn- ^Boolean comparison-result [^Literal literal subst]
  (let [arguments (literal-arguments literal)
   left (term-value (nth arguments 0) subst)
   right (term-value (nth arguments 1) subst)
   operator (literal-operator literal)]
  (if (or (nil? left) (nil? right)) false (cond
  (= operator :eq) (= left right)
  (= operator :ne) (not (= left right))
  :else (let [left-number (numeric-value left)
   right-number (numeric-value right)]
  (if (or (nil? left-number) (nil? right-number)) false (cond
  (= operator :lt) (< left-number right-number)
  (= operator :le) (<= left-number right-number)
  (= operator :gt) (> left-number right-number)
  (= operator :ge) (>= left-number right-number)
  :else false)))))))

(defn- integer-builtin-value [operator left right]
  (cond
  (= operator :mod) (mod left right)
  (= operator :+) (+ left right)
  (= operator subtract-operator) (- left right)
  :else (* left right)))

(defn- double-builtin-value [operator left right]
  (cond
  (= operator :/) (/ left right)
  (= operator :+) (+ left right)
  (= operator subtract-operator) (- left right)
  :else (* left right)))

(defn- ^BuiltinValueResult builtin-value [operator left right]
  (let [left-int (integer-value left)
   right-int (integer-value right)
   left-number (numeric-value left)
   right-number (numeric-value right)
   ^BuiltinValueResult invalid (->BuiltinValueResult nil nil)]
  (cond
  (= operator :mod) (if (nil? left-int) invalid (if (nil? right-int) invalid (if (= right-int 0) invalid (->BuiltinValueResult (integer-builtin-value operator left-int right-int) nil))))
  (= operator :/) (if (nil? left-number) invalid (if (nil? right-number) invalid (if (= right-number 0.0) invalid (->BuiltinValueResult nil (double-builtin-value operator left-number right-number)))))
  (or (= operator :+) (or (= operator subtract-operator) (= operator :*))) (if (nil? left-int) (if (nil? left-number) invalid (if (nil? right-number) invalid (cond
  (= operator :+) (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))
  (= operator subtract-operator) (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))
  :else (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))))) (if (nil? right-int) (if (nil? left-number) invalid (if (nil? right-number) invalid (cond
  (= operator :+) (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))
  (= operator subtract-operator) (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))
  :else (->BuiltinValueResult nil (double-builtin-value operator left-number right-number))))) (cond
  (= operator :+) (->BuiltinValueResult (integer-builtin-value operator left-int right-int) nil)
  (= operator subtract-operator) (->BuiltinValueResult (integer-builtin-value operator left-int right-int) nil)
  :else (->BuiltinValueResult (integer-builtin-value operator left-int right-int) nil))))
  :else invalid)))

(defn- builtin-results [^Literal literal subst]
  (let [arguments (literal-arguments literal)
   left (term-value (nth arguments 0) subst)
   right (term-value (nth arguments 1) subst)]
  (if (or (nil? left) (nil? right)) [] (let [result (builtin-value (literal-operator literal) left right)]
  (let [int-value (builtinvalueresult-int-value result)
   double-value (builtinvalueresult-double-value result)]
  (cond
  (some? int-value) [(assoc subst (literal-binding literal) int-value)]
  (some? double-value) [(assoc subst (literal-binding literal) double-value)]
  :else []))))))

(defn- unify-tuples-controlled! [arguments tuples subst ^QueryEvaluationContext context]
  (loop [remaining tuples
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) results (let [matched (unify-arguments-controlled! arguments (first remaining) subst context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (if (some? matched) (conj results matched) results)) results)))))

(defn- unify-tuples! [arguments tuples subst ^QueryEvaluationContext context]
  (unify-tuples-controlled! arguments tuples subst context))

(defn- bound-term-value [^QueryTerm term subst]
  (let [name (queryterm-variable term)]
  (if (some? name) (if (contains? subst name) (get subst name) nil) (queryterm-value term))))

(defn- missing-candidate-source-result [^String relation]
  (text-search/query-text-rows-error :query-text-index-unavailable (str "candidate source is unavailable for relation '" relation "'")))

(defn- virtual-source-rows-result! [^VirtualCandidateSource candidate ^Boolean indexed arguments subst]
  (let [relation (virtualcandidatesource-relation candidate)
   source (virtualcandidatesource-source candidate)
   needle (bound-term-value (nth arguments 2) subst)]
  (cond
  (= relation text-match-relation) (if indexed (text-search/exact-indexed-rows-result! source needle) (text-search/exact-scan-rows-result! source needle))
  (= relation text-phrase-relation) (if indexed (text-search/phrase-indexed-rows-result! source needle) (text-search/phrase-scan-rows-result! source needle))
  (= relation text-substring-relation) (if indexed (text-search/substring-indexed-rows-result! source needle) (text-search/substring-scan-rows-result! source needle))
  (= relation text-stem-relation) (if indexed (text-search/stem-indexed-rows-result! source needle) (text-search/stem-scan-rows-result! source needle))
  (= relation text-search-relation) (if indexed (text-search/ranked-indexed-rows-result! source needle) (text-search/ranked-scan-rows-result! source needle))
  :else (missing-candidate-source-result relation))))

(defn- text-rows-or-record! [result ^QueryEvaluationContext context]
  (if (text-search/rows-result-ok? result) (text-search/rows-result-rows result) (do
  (record-query-evaluation-error! context (query-evaluation-error-from-text-error (text-search/rows-result-error result)))
  [])))

(defn- virtual-source-rows! [^VirtualCandidateSource candidate ^Boolean indexed arguments subst ^QueryEvaluationContext context]
  (text-rows-or-record! (virtual-source-rows-result! candidate indexed arguments subst) context))

(defn- relation-results! [db sources ^Literal literal subst ^QueryEvaluationContext context]
  (let [relation (literal-relation literal)
   arguments (literal-arguments literal)
   source (get sources relation)]
  (if (literal-negated literal) (if (contains? (get db relation #{}) (ground arguments subst)) [] [subst]) (cond
  (instance? VirtualCandidateSource source) (unify-tuples! arguments (virtual-source-rows! source false arguments subst context) subst context)
  (and (contains? text-relations relation) (nil? source)) (text-rows-or-record! (missing-candidate-source-result relation) context)
  :else (unify-tuples! arguments (vec (get db relation #{})) subst context)))))

(defn- literal-results! [db sources ^Literal literal subst ^QueryEvaluationContext context]
  (if (query-check! context) (cond
  (= :relation (literal-kind literal)) (relation-results! db sources literal subst context)
  (= :comparison (literal-kind literal)) (if (comparison-result literal subst) [subst] [])
  (= :builtin (literal-kind literal)) (builtin-results literal subst)
  :else []) []))

(defn- literal-substitutions! [db sources ^Literal literal substitutions ^QueryEvaluationContext context]
  (loop [remaining substitutions
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) (if (query-evaluation-context-open? context) results []) (let [matches (literal-results! db sources literal (first remaining) context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (into results matches)) [])))))

(defn- body-results! [db sources body seed ^QueryEvaluationContext context]
  (loop [remaining body
   substitutions [seed]]
  (cond
  (not (query-evaluation-context-open? context)) []
  (empty? remaining) substitutions
  (empty? substitutions) []
  :else (recur (rest remaining) (literal-substitutions! db sources (first remaining) substitutions context)))))

(defn- derive-rule! [db sources ^Rule value ^QueryEvaluationContext context]
  (let [substitutions (body-results! db sources (rule-body value) {} context)]
  (if (query-evaluation-context-open? context) (reduce (fn [acc subst] (conj acc (ground (rule-head-arguments value) subst))) #{} substitutions) #{})))

(defn- rule-head-relations [rules]
  (vec (reduce (fn [acc ^Rule value] (conj acc (rule-head-relation value))) #{} rules)))

(defn- append-handle [index key handle]
  (update index key (fn [current] (if (nil? current) [handle] (conj current handle)))))

(defn- add-position-handles [index tuple handle]
  (loop [position 0
   current index]
  (if (>= position (count tuple)) current (let [bucket (get current position {})]
  (recur (inc position) (assoc current position (append-handle bucket (nth tuple position) handle)))))))

(defn- trie-add [trie tuple order handle]
  (let [first-key (nth tuple (nth order 0))
   second-key (nth tuple (nth order 1))
   third-key (nth tuple (nth order 2))
   first-node (get trie first-key {})
   second-node (get first-node second-key {})
   leaf (get second-node third-key [])]
  (assoc trie first-key (assoc first-node second-key (assoc second-node third-key (conj leaf handle))))))

(defn- add-handle-values [handles values]
  (reduce (fn [current handle] (conj current handle)) handles values))

(defn- ordered-handles [handles]
  (sort (vec handles)))

(defn- trie-leaf-handles [node]
  (ordered-handles (reduce-kv (fn [handles key child] (add-handle-values handles child)) #{} node)))

(defn- trie-branch-handles [node]
  (ordered-handles (reduce-kv (fn [handles key child] (add-handle-values handles (trie-leaf-handles child))) #{} node)))

(defn- trie-node-handles [node]
  (ordered-handles (reduce-kv (fn [handles key child] (add-handle-values handles (trie-branch-handles child))) #{} node)))

(defn- trie-probe [trie prefix]
  (let [depth (count prefix)]
  (cond
  (= 0 depth) (trie-node-handles trie)
  (> depth 3) []
  :else (let [first-node (get trie (nth prefix 0))]
  (if (nil? first-node) [] (if (= 1 depth) (trie-branch-handles first-node) (let [second-node (get first-node (nth prefix 1))]
  (if (nil? second-node) [] (if (= 2 depth) (trie-leaf-handles second-node) (get second-node (nth prefix 2) []))))))))))

(defn- ^CandidateSource empty-candidate-source []
  (->CandidateSource [] {} {} {} {} nil nil))

(defn ^CandidateSource occurrence-candidate-source [root lower-exclusive upper-inclusive]
  (->CandidateSource [] {} {} {} {} (->OccurrenceCandidateSource root lower-exclusive upper-inclusive (store/operation-postings root)) nil))

(defn ^CandidateSource rotation-candidate-source [rotation lower-exclusive]
  (->CandidateSource [] {} {} {} {} nil (->RotationCandidateSource rotation lower-exclusive)))

(defn ^StoreCandidateSource triple-candidate-source [root]
  (->StoreCandidateSource root))

(defn- ^Boolean event-after-sequence? [event lower-exclusive]
  (if (< lower-exclusive 0) true (let [occurrence (t/operationoccurrence-coordinate event)]
  (if (t/occurrence-coordinate? occurrence) (let [transaction (t/triple-t1 occurrence)
   sequence (t/triple-t3 transaction)]
  (> sequence lower-exclusive)) false))))

(defn events-after-sequence [events lower-exclusive]
  (if (< lower-exclusive 0) events (filterv (fn [event] (event-after-sequence? event lower-exclusive)) events)))

(defn- ^String length-key [^String tag ^String value]
  (str tag (count value) ":" value))

(defn ^String term-key [value]
  (cond
  (string? value) (let [^String text value]
  (length-key "s" text))
  (integer? value) (let [integer-value value]
  (str "i" integer-value ";"))
  (number? value) (let [float-value (double value)]
  (str "f" float-value ";"))
  (boolean? value) (let [^Boolean bool-value value]
  (if bool-value "b1;" "b0;"))
  (keyword? value) (let [keyword-value value]
  (length-key "k" (str keyword-value)))
  (t/instant? value) (let [instant-value value]
  (str "m" (t/instant-epoch-seconds instant-value) ":" (t/instant-nanos instant-value) ";"))
  (t/triple? value) (let [triple-value value
   ^String t1 (term-key (t/triple-t1 triple-value))
   ^String t2 (term-key (t/triple-t2 triple-value))
   ^String t3 (term-key (t/triple-t3 triple-value))]
  (str "t" (count t1) ":" t1 (count t2) ":" t2 (count t3) ":" t3))
  :else "x0:"))

(defn ^String row-key [row]
  (reduce (fn [^String acc value] (let [key (term-key value)]
  (str acc (count key) ":" key))) "r" row))

(defn order-row-vector [rows]
  (let [by-key (reduce (fn [acc row] (assoc acc (row-key row) row)) {} rows)
   keys (reduce (fn [acc row] (conj acc (row-key row))) [] rows)]
  (mapv (fn [^String key] (let [row (get by-key key)]
  (if (some? row) (let [present row]
  present) []))) (vec (sort keys)))))

(defn- ordered-rows [rows]
  (order-row-vector (vec rows)))

(defn- ^CandidateSource candidate-source-add [^String relation ^CandidateSource source tuple]
  (let [handle (count (candidatesource-rows source))
   ^CandidateSource with-row (assoc source :rows (conj (candidatesource-rows source) tuple))]
  (if (and (= relation triple-relation) (= 3 (count tuple))) (assoc with-row :spo (trie-add (candidatesource-spo source) tuple [0 1 2] handle) :pos (trie-add (candidatesource-pos source) tuple [1 2 0] handle) :osp (trie-add (candidatesource-osp source) tuple [2 0 1] handle)) (assoc with-row :positions (add-position-handles (candidatesource-positions source) tuple handle)))))

(defn- ^CandidateSource candidate-source-add-rows [^String relation ^CandidateSource source tuples]
  (reduce (fn [^CandidateSource current tuple] (candidate-source-add relation current tuple)) source tuples))

(defn ^CandidateSource withdrawal-candidate-source [root lower-exclusive upper-inclusive]
  (candidate-source-add-rows withdrawal-relation (empty-candidate-source) (ordered-rows (set (store/withdrawal-tuples-between root lower-exclusive upper-inclusive)))))

(defn- build-candidate-sources [db relations seed]
  (reduce (fn [sources ^String relation] (if (contains? sources relation) sources (assoc sources relation (candidate-source-add-rows relation (empty-candidate-source) (ordered-rows (get db relation #{})))))) seed relations))

(defn- add-delta-sources [sources delta relations]
  (reduce (fn [current ^String relation] (let [tuples (get delta relation #{})
   existing (get current relation)
   ^CandidateSource base (if (instance? CandidateSource existing) existing (empty-candidate-source))]
  (if (empty? tuples) current (assoc current relation (candidate-source-add-rows relation base (ordered-rows tuples)))))) sources relations))

(defn ^Boolean text-relation-needle-valid?! [^String relation needle]
  (cond
  (= relation text-match-relation) (text-index/text-needle-valid?! needle)
  (or (= relation text-phrase-relation) (= relation text-stem-relation)) (text-search/word-needle-valid? needle)
  (or (= relation text-substring-relation) (= relation text-search-relation)) (text-search/substring-needle-valid? needle)
  :else false))

(defn text-candidate-sources [source]
  {text-match-relation (->VirtualCandidateSource text-match-relation source) text-phrase-relation (->VirtualCandidateSource text-phrase-relation source) text-substring-relation (->VirtualCandidateSource text-substring-relation source) text-stem-relation (->VirtualCandidateSource text-stem-relation source) text-search-relation (->VirtualCandidateSource text-search-relation source)})

(defn ^CandidateSourcesResult build-text-candidates-result! [propositions]
  (let [result (text-search/build-source-result! propositions text-index/text-index-max-bytes)
   source (text-search/source-result-source result)]
  (if (some? source) (->CandidateSourcesResult (text-candidate-sources source) nil) (->CandidateSourcesResult {} (query-evaluation-error-from-text-error (text-search/source-result-error result))))))

(defn ^CandidateSourcesResult build-text-candidates-for-attributes-result! [propositions attributes]
  (let [result (text-search/build-source-for-attributes-result! propositions attributes text-index/text-index-max-bytes)
   source (text-search/source-result-source result)]
  (if (some? source) (->CandidateSourcesResult (text-candidate-sources source) nil) (->CandidateSourcesResult {} (query-evaluation-error-from-text-error (text-search/source-result-error result))))))

(defn build-text-candidates! [propositions]
  (text-candidate-sources (text-search/build-source! propositions text-index/text-index-max-bytes)))

(defn- bound-prefix [arguments order subst]
  (loop [remaining order
   prefix []]
  (if (empty? remaining) prefix (let [value (bound-term-value (nth arguments (first remaining)) subst)]
  (if (nil? value) prefix (recur (rest remaining) (conj prefix value)))))))

(defn- triple-prefix-handles [^CandidateSource source arguments subst]
  (let [spo-key (bound-prefix arguments [0 1 2] subst)
   pos-key (bound-prefix arguments [1 2 0] subst)
   osp-key (bound-prefix arguments [2 0 1] subst)
   spo-count (count spo-key)
   pos-count (count pos-key)
   osp-count (count osp-key)]
  (cond
  (and (= 0 spo-count) (and (= 0 pos-count) (= 0 osp-count))) nil
  (and (>= spo-count pos-count) (>= spo-count osp-count)) (trie-probe (candidatesource-spo source) spo-key)
  (>= pos-count osp-count) (trie-probe (candidatesource-pos source) pos-key)
  :else (trie-probe (candidatesource-osp source) osp-key))))

(defn- positional-handles [^CandidateSource source arguments subst]
  (loop [position 0
   best []
   ^Boolean found false]
  (if (>= position (count arguments)) (if found best nil) (let [value (bound-term-value (nth arguments position) subst)]
  (if (nil? value) (recur (inc position) best found) (let [bucket (get (candidatesource-positions source) position {})
   candidate (get bucket value [])]
  (recur (inc position) (if (or (not found) (< (count candidate) (count best))) candidate best) true)))))))

(defn- source-handles [^CandidateSource source ^String relation arguments subst]
  (let [occurrence (candidatesource-occurrence source)]
  (if (some? occurrence) (store/operation-candidate-positions (occurrencecandidatesource-root occurrence) (occurrencecandidatesource-lower-exclusive occurrence) (occurrencecandidatesource-upper-inclusive occurrence) (bound-term-value (nth arguments 0) subst) (bound-term-value (nth arguments 2) subst) (occurrencecandidatesource-postings occurrence)) (if (and (= relation triple-relation) (= 3 (count arguments))) (triple-prefix-handles source arguments subst) (positional-handles source arguments subst)))))

(defn- source-row [^CandidateSource source handle]
  (let [occurrence (candidatesource-occurrence source)]
  (if (some? occurrence) (store/occurrence-tuple-at (occurrencecandidatesource-root occurrence) handle) (nth (candidatesource-rows source) handle))))

(defn- store-source-handles [^StoreCandidateSource source arguments subst]
  (store/matching-triple-handles (storecandidatesource-root source) (bound-term-value (nth arguments 0) subst) (bound-term-value (nth arguments 1) subst) (bound-term-value (nth arguments 2) subst)))

(defn- store-source-row [^StoreCandidateSource source handle]
  (store/triple-tuple-at (storecandidatesource-root source) handle))

(defn- ^Boolean store-source-contains? [^StoreCandidateSource source arguments subst]
  (let [wanted (ground arguments subst)]
  (some? (some (fn [handle] (if (= wanted (store-source-row source handle)) (do
  handle))) (store-source-handles source arguments subst)))))

(defn- ^Boolean source-contains? [^CandidateSource source ^String relation arguments subst]
  (let [rotation (candidatesource-rotation source)]
  (if (some? rotation) (let [wanted (ground arguments subst)]
  (not (empty? (events-after-sequence (rot/matching (rotationcandidatesource-rotation rotation) (nth wanted 0) (nth wanted 1) (nth wanted 2)) (rotationcandidatesource-lower-exclusive rotation))))) (let [wanted (ground arguments subst)
   handles (source-handles source relation arguments subst)]
  (some? (some (fn [handle] (if (= wanted (source-row source handle)) (do
  handle))) (or handles [])))))))

(defn- rotation-results-indexed! [^RotationCandidateSource rotation arguments subst ^QueryEvaluationContext context]
  (let [events (events-after-sequence (rot/matching (rotationcandidatesource-rotation rotation) (bound-term-value (nth arguments 0) subst) (bound-term-value (nth arguments 1) subst) (bound-term-value (nth arguments 2) subst)) (rotationcandidatesource-lower-exclusive rotation))]
  (loop [remaining events
   seen #{}
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) results (let [proposition (t/operationoccurrence-proposition (first remaining))]
  (if (contains? seen proposition) (recur (rest remaining) seen results) (let [matched (unify-arguments-controlled! arguments (triple-row proposition) subst context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (conj seen proposition) (if (some? matched) (conj results matched) results)) results))))))))

(defn- store-results-indexed! [^StoreCandidateSource source arguments subst ^QueryEvaluationContext context]
  (loop [remaining (store-source-handles source arguments subst)
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) results (let [tuple (store-source-row source (first remaining))
   matched (unify-arguments-controlled! arguments tuple subst context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (if (some? matched) (conj results matched) results)) results)))))

(defn- relation-results-indexed! [db sources ^Literal literal subst ^QueryEvaluationContext context]
  (let [^String relation (literal-relation literal)
   arguments (literal-arguments literal)
   source (get sources relation)]
  (if (literal-negated literal) (cond
  (instance? CandidateSource source) (if (source-contains? source relation arguments subst) [] [subst])
  (instance? StoreCandidateSource source) (if (store-source-contains? source arguments subst) [] [subst])
  :else (if (contains? (get db relation #{}) (ground arguments subst)) [] [subst])) (cond
  (instance? VirtualCandidateSource source) (unify-tuples-controlled! arguments (virtual-source-rows! source true arguments subst context) subst context)
  (instance? StoreCandidateSource source) (store-results-indexed! source arguments subst context)
  (instance? CandidateSource source) (let [rotation (candidatesource-rotation source)]
  (if (some? rotation) (rotation-results-indexed! rotation arguments subst context) (let [rows-value (candidatesource-rows source)
   handles (source-handles source relation arguments subst)]
  (if (nil? handles) (unify-tuples-controlled! arguments rows-value subst context) (loop [remaining handles
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) results (let [tuple (source-row source (first remaining))
   matched (unify-arguments-controlled! arguments tuple subst context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (if (some? matched) (conj results matched) results)) results))))))))
  :else (if (contains? text-relations relation) (do
  (text-rows-or-record! (missing-candidate-source-result relation) context)
  (let [missing []]
  missing)) (unify-tuples-controlled! arguments (vec (get db relation #{})) subst context))))))

(defn- literal-results-indexed! [db sources ^Literal literal subst ^QueryEvaluationContext context]
  (if (query-check! context) (cond
  (= :relation (literal-kind literal)) (relation-results-indexed! db sources literal subst context)
  (= :comparison (literal-kind literal)) (if (comparison-result literal subst) [subst] [])
  (= :builtin (literal-kind literal)) (builtin-results literal subst)
  :else []) []))

(defn- literal-substitutions-indexed! [db sources ^Literal literal substitutions ^QueryEvaluationContext context]
  (loop [remaining substitutions
   results []]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) (if (query-evaluation-context-open? context) results []) (let [matches (literal-results-indexed! db sources literal (first remaining) context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (into results matches)) [])))))

(defn- body-results-indexed! [db sources body seed ^QueryEvaluationContext context]
  (loop [remaining body
   substitutions [seed]]
  (cond
  (not (query-evaluation-context-open? context)) []
  (empty? remaining) substitutions
  (empty? substitutions) []
  :else (recur (rest remaining) (literal-substitutions-indexed! db sources (first remaining) substitutions context)))))

(defn- derive-rule-indexed! [db sources ^Rule value ^QueryEvaluationContext context]
  (let [substitutions (body-results-indexed! db sources (rule-body value) {} context)]
  (if (query-evaluation-context-open? context) (reduce (fn [acc subst] (conj acc (ground (rule-head-arguments value) subst))) #{} substitutions) #{})))

(defn- delta-relation-positions [body delta-relations]
  (loop [position 0
   remaining body
   positions []]
  (if (empty? remaining) positions (let [literal (first remaining)]
  (recur (inc position) (rest remaining) (if (and (= :relation (literal-kind literal)) (not (literal-negated literal)) (contains? delta-relations (literal-relation literal))) (conj positions position) positions))))))

(defn- positive-relation-names [rules]
  (vec (sort (vec (reduce (fn [relations ^Rule value] (reduce (fn [current ^Literal literal] (if (and (= :relation (literal-kind literal)) (not (literal-negated literal))) (conj current (literal-relation literal)) current)) relations (rule-body value))) #{} rules)))))

(defn- body-results-pinned! [db sources delta delta-sources body pin ^QueryEvaluationContext context]
  (loop [position 0
   remaining body
   substitutions [{}]]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) (if (query-evaluation-context-open? context) substitutions []) (let [literal (first remaining)
   pinned (and (= position pin) (= :relation (literal-kind literal)) (not (literal-negated literal)))
   read-db (if pinned delta db)
   read-sources (if pinned delta-sources sources)
   next-substitutions (literal-substitutions-indexed! read-db read-sources literal substitutions context)]
  (recur (inc position) (rest remaining) next-substitutions)))))

(defn- derive-rule-delta! [db sources delta delta-sources delta-relations ^Rule value ^QueryEvaluationContext context]
  (let [head (rule-head-arguments value)
   body (rule-body value)]
  (loop [remaining (delta-relation-positions body delta-relations)
   derived #{}]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) (if (query-evaluation-context-open? context) derived #{}) (let [substitutions (body-results-pinned! db sources delta delta-sources body (first remaining) context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (reduce (fn [current subst] (conj current (ground head subst))) derived substitutions)) #{}))))))

(defn- db-new-only [candidate db relations]
  (reduce (fn [delta ^String relation] (let [new-tuples (reduce (fn [rows-value tuple] (if (contains? (get db relation #{}) tuple) rows-value (conj rows-value tuple))) #{} (vec (get candidate relation #{})))]
  (if (empty? new-tuples) delta (assoc delta relation new-tuples)))) {} relations))

(defn- db-merge-delta [db delta relations]
  (reduce (fn [current ^String relation] (let [new-tuples (get delta relation #{})]
  (if (empty? new-tuples) current (update current relation (fn [known] (reduce (fn [rows-value tuple] (conj rows-value tuple)) (or known #{}) (vec new-tuples))))))) db relations))

(defn- ^Boolean delta-empty? [delta relations]
  (loop [remaining relations]
  (if (empty? remaining) true (if (empty? (get delta (first remaining) #{})) (recur (rest remaining)) false))))

(defn- derive-delta! [db sources delta rules relations delta-relations ^QueryEvaluationContext context]
  (let [delta-set (set delta-relations)
   delta-sources (build-candidate-sources delta delta-relations {})
   candidate (loop [remaining rules
   current {}]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) current (let [value (first remaining)
   relation (rule-head-relation value)
   derived (derive-rule-delta! db sources delta delta-sources delta-set value context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (update current relation (fn [known] (reduce (fn [rows-value tuple] (conj rows-value tuple)) (or known #{}) (vec derived))))) current))))]
  (if (query-evaluation-context-open? context) (db-new-only candidate db relations) {})))

(defn- fixpoint-with-candidates-context! [db0 rules candidates ^QueryEvaluationContext context]
  (let [relations (rule-head-relations rules)
   read-relations (positive-relation-names rules)
   head-set (set relations)
   delta-relations (vec (filter (fn [^String relation] (contains? head-set relation)) read-relations))
   initial-sources (build-candidate-sources db0 read-relations candidates)
   seeded (loop [remaining rules
   current db0]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) current (let [value (first remaining)
   relation (rule-head-relation value)
   derived (derive-rule-indexed! db0 initial-sources value context)]
  (if (query-evaluation-context-open? context) (recur (rest remaining) (update current relation (fn [known] (reduce (fn [rows-value tuple] (conj rows-value tuple)) (or known #{}) (vec derived))))) current))))]
  (if (not (query-evaluation-context-open? context)) seeded (let [delta0 (db-new-only seeded db0 relations)
   seeded-sources (add-delta-sources initial-sources delta0 read-relations)]
  (loop [db seeded
   sources seeded-sources
   delta delta0]
  (cond
  (not (query-evaluation-context-open? context)) db
  (delta-empty? delta delta-relations) db
  :else (let [next-delta (derive-delta! db sources delta rules relations delta-relations context)]
  (if (query-evaluation-context-open? context) (recur (db-merge-delta db next-delta relations) (add-delta-sources sources next-delta read-relations) next-delta) db))))))))

(defn ^QueryEvaluationResult fixpoint-with-candidates-result! [db0 rules candidates control]
  (let [context (new-query-evaluation-context control)
   db (fixpoint-with-candidates-context! db0 rules candidates context)]
  (->QueryEvaluationResult db (query-evaluation-context-error context))))

(defn fixpoint-with-candidates-controlled! [db0 rules candidates control]
  (query-evaluation-db-or-throw! (fixpoint-with-candidates-result! db0 rules candidates control)))

(defn fixpoint-with-candidates! [db0 rules candidates]
  (fixpoint-with-candidates-controlled! db0 rules candidates *query-control*))

(defn fixpoint! [db0 rules]
  (fixpoint-with-candidates! db0 rules {}))

(defn fixpoint-sourced! [db0 registered rules]
  (fixpoint-with-candidates! db0 rules registered))

(defn run-rules! [propositions rules]
  (fixpoint! (edb propositions) rules))

(defn ^QueryEvaluationResult run-strata-db-with-candidates-result! [db0 strata candidates control]
  (let [context (new-query-evaluation-context control)]
  (loop [remaining strata
   db db0]
  (if (or (empty? remaining) (not (query-evaluation-context-open? context))) (->QueryEvaluationResult db (query-evaluation-context-error context)) (recur (rest remaining) (fixpoint-with-candidates-context! db (first remaining) candidates context))))))

(defn run-strata-db-with-candidates-controlled! [db0 strata candidates control]
  (query-evaluation-db-or-throw! (run-strata-db-with-candidates-result! db0 strata candidates control)))

(defn run-strata-db-with-candidates! [db0 strata candidates]
  (run-strata-db-with-candidates-controlled! db0 strata candidates *query-control*))

(defn run-strata-db! [db0 strata]
  (run-strata-db-with-candidates! db0 strata {}))

(defn run-strata-db-sourced! [db0 sources strata]
  (run-strata-db-with-candidates! db0 strata sources))

(defn run-strata! [propositions strata]
  (run-strata-db! (edb propositions) strata))

(defn- negated-relations [stratum]
  (reduce (fn [acc ^Rule value] (reduce (fn [relations ^Literal literal] (if (and (= :relation (literal-kind literal)) (literal-negated literal)) (conj relations (literal-relation literal)) relations)) acc (rule-body value))) [] stratum))

(defn strata-violations [strata]
  (loop [index 0
   lower base-relations
   problems []]
  (if (>= index (count strata)) problems (let [stratum (nth strata index)
   heads (reduce (fn [acc ^Rule value] (conj acc (rule-head-relation value))) #{} stratum)
   problems2 (reduce (fn [acc ^String relation] (cond
  (contains? heads relation) (conj acc (str "stratum " index ": negated '" relation "' is also derived in the same stratum"))
  (not (contains? lower relation)) (conj acc (str "stratum " index ": negated '" relation "' is not a base or lower-stratum relation"))
  :else acc)) problems (negated-relations stratum))]
  (recur (+ index 1) (reduce (fn [acc ^String relation] (conj acc relation)) lower (vec heads)) problems2)))))

(defn facts [db ^String relation]
  (vec (get db relation #{})))
