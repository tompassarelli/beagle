(ns fram.query
  (:require [fram.datalog :as d]
            [fram.types :as t]
            [clojure.string :as str]))

(defrecord AggregateSpec [operator argument])

(defn aggregatespec-operator [r] (:operator r))

(defn aggregatespec-argument [r] (:argument r))

(defrecord HavingClause [operator aggregate-index value])

(defn havingclause-operator [r] (:operator r))

(defn havingclause-aggregate-index [r] (:aggregate-index r))

(defn havingclause-value [r] (:value r))

(defrecord FindSpec [relation grouping aggregates having])

(defn findspec-relation [r] (:relation r))

(defn findspec-grouping [r] (:grouping r))

(defn findspec-aggregates [r] (:aggregates r))

(defn findspec-having [r] (:having r))

(defrecord OrderClause [column direction])

(defn orderclause-column [r] (:column r))

(defn orderclause-direction [r] (:direction r))

(defrecord QueryPlan [find strata order limit])

(defn queryplan-find [r] (:find r))

(defn queryplan-strata [r] (:strata r))

(defn queryplan-order [r] (:order r))

(defn queryplan-limit [r] (:limit r))

(defrecord Projection [edb candidates])

(defn projection-edb [r] (:edb r))

(defn projection-candidates [r] (:candidates r))

(defrecord ProjectionResult [projection error])

(defn projectionresult-projection [r] (:projection r))

(defn projectionresult-error [r] (:error r))

(defrecord QueryError [code message])

(defn queryerror-code [r] (:code r))

(defn queryerror-message [r] (:message r))

(defrecord CompileResult [plan errors])

(defn compileresult-plan [r] (:plan r))

(defn compileresult-errors [r] (:errors r))

(defrecord QueryResult [rows errors over-limit maximum])

(defn queryresult-rows [r] (:rows r))

(defn queryresult-errors [r] (:errors r))

(defn queryresult-over-limit [r] (:over-limit r))

(defn queryresult-maximum [r] (:maximum r))

(defrecord QueryExecutionResult [query-result error])

(defn queryexecutionresult-query-result [r] (:query-result r))

(defn queryexecutionresult-error [r] (:error r))

(defrecord QueryPage [rows next more errors max-bytes])

(defn querypage-rows [r] (:rows r))

(defn querypage-next [r] (:next r))

(defn querypage-more [r] (:more r))

(defn querypage-errors [r] (:errors r))

(defn querypage-max-bytes [r] (:max-bytes r))

(defrecord CursorResult [key error])

(defn cursorresult-key [r] (:key r))

(defn cursorresult-error [r] (:error r))

(defrecord AggregateGroup [key members])

(defn aggregategroup-key [r] (:key r))

(defn aggregategroup-members [r] (:members r))

(defrecord AggregateGroups [by-key order])

(defn aggregategroups-by-key [r] (:by-key r))

(defn aggregategroups-order [r] (:order r))

(def ^:dynamic *query-control* nil)

(def base-rel-arities {d/triple-relation 3 d/occurrence-relation 3 d/withdrawal-relation 2 d/text-match-relation 3 d/text-phrase-relation 3 d/text-substring-relation 3 d/text-stem-relation 3 d/text-search-relation 4})

(def base-relations d/base-relations)

(def aggregate-operators #{:count :count-distinct :sum :avg :min :max})

(def aggregate-argument-operators #{:count-distinct :sum :avg :min :max})

(defn ^QueryError query-error [code ^String message]
  (->QueryError code message))

(defn ^FindSpec relation-find [^String relation]
  (->FindSpec relation [] [] []))

(defn ^AggregateSpec aggregate-spec [operator argument]
  (->AggregateSpec operator argument))

(defn ^HavingClause having-clause [operator aggregate-index value]
  (->HavingClause operator aggregate-index value))

(defn ^FindSpec aggregate-find [^String relation grouping aggregates having]
  (->FindSpec relation grouping aggregates having))

(defn ^OrderClause order-clause [column direction]
  (->OrderClause column direction))

(defn ^QueryPlan ordered-query-plan [^FindSpec find strata order limit]
  (->QueryPlan find strata order limit))

(defn ^QueryPlan query-plan [^FindSpec find strata]
  (ordered-query-plan find strata [] nil))

(defn- literal-text-attribute-scope [literal scope]
  (if (nil? scope) nil (if (and (= :relation (d/literal-kind literal)) (contains? d/text-relations (d/literal-relation literal))) (let [attribute (nth (d/literal-arguments literal) 1)]
  (if (some? (d/queryterm-variable attribute)) nil (conj scope (d/queryterm-value attribute)))) scope)))

(defn- rule-text-attribute-scope [rule scope]
  (reduce (fn [current literal] (literal-text-attribute-scope literal current)) scope (d/rule-body rule)))

(defn- empty-any-set []
  #{})

(defn plan-text-attribute-scope [^QueryPlan plan]
  (reduce (fn [scope stratum] (reduce (fn [current rule] (rule-text-attribute-scope rule current)) scope stratum)) (empty-any-set) (queryplan-strata plan)))

(defn ^Boolean query-plan? [value]
  (instance? QueryPlan value))

(defn ^Boolean projection? [value]
  (instance? Projection value))

(defn ^Boolean aggregate-find? [^FindSpec find]
  (not (empty? (findspec-aggregates find))))

(def max-results (let [raw (System/getenv "FRAM_MAX_RESULTS")
   parsed (if (and (string? raw) (not (= raw ""))) (let [text raw]
  (parse-long text)) nil)]
  (if (and (some? parsed) (> parsed 0)) parsed 100000)))

(defn ^Boolean compile-ok? [^CompileResult result]
  (empty? (compileresult-errors result)))

(defn compiled-plan [^CompileResult result]
  (compileresult-plan result))

(defn compile-errors [^CompileResult result]
  (compileresult-errors result))

(defn ^Boolean result-ok? [^QueryResult result]
  (empty? (queryresult-errors result)))

(defn result-rows [^QueryResult result]
  (queryresult-rows result))

(defn result-errors [^QueryResult result]
  (queryresult-errors result))

(defn result-over-limit [^QueryResult result]
  (queryresult-over-limit result))

(defn result-maximum [^QueryResult result]
  (queryresult-maximum result))

(defn execution-query-result [^QueryExecutionResult result]
  (queryexecutionresult-query-result result))

(defn execution-error [^QueryExecutionResult result]
  (queryexecutionresult-error result))

(defn projection-result-projection [^ProjectionResult result]
  (projectionresult-projection result))

(defn projection-result-error [^ProjectionResult result]
  (projectionresult-error result))

(defn ^Boolean page-ok? [^QueryPage page]
  (empty? (querypage-errors page)))

(defn page-rows [^QueryPage page]
  (querypage-rows page))

(defn page-next [^QueryPage page]
  (querypage-next page))

(defn ^Boolean page-more? [^QueryPage page]
  (querypage-more page))

(defn page-errors [^QueryPage page]
  (querypage-errors page))

(defn error-code [^QueryError error-value]
  (queryerror-code error-value))

(defn ^String error-message [^QueryError error-value]
  (queryerror-message error-value))

(defn- ^QueryResult success-result [rows]
  (->QueryResult rows [] nil nil))

(defn- ^QueryResult failure-result [errors]
  (->QueryResult [] errors nil nil))

(defn- ^QueryResult limited-result [^QueryError error-value count-value maximum]
  (->QueryResult [] [error-value] count-value maximum))

(defn- ^QueryPage success-page [rows next ^Boolean more]
  (->QueryPage rows next more [] nil))

(defn- ^QueryPage failure-page [errors]
  (->QueryPage [] nil false errors nil))

(defn- ^QueryPage wire-failure-page [^QueryError error-value maximum]
  (->QueryPage [] nil false [error-value] maximum))

(defn ^Projection project-with-candidates [propositions candidates]
  (->Projection (d/edb propositions) candidates))

(defn ^Projection project-with-source [propositions ^String relation source]
  (project-with-candidates propositions {relation source}))

(defn- ^ProjectionResult projection-from-candidates-result [database result]
  (let [error-value (d/candidatesourcesresult-error result)]
  (if (some? error-value) (->ProjectionResult nil error-value) (->ProjectionResult (->Projection database (d/candidatesourcesresult-sources result)) nil))))

(defn ^ProjectionResult project-result! [propositions]
  (projection-from-candidates-result (d/edb propositions) (d/build-text-candidates-result! propositions)))

(defn ^ProjectionResult project-with-history-result! [propositions occurrences withdrawals]
  (let [database (d/edb-with-history propositions occurrences withdrawals)]
  (projection-from-candidates-result database (d/build-text-candidates-result! propositions))))

(defn- ^Projection projection-or-raise [^ProjectionResult result]
  (let [projection-value (projectionresult-projection result)
   error-value (projectionresult-error result)]
  (if (some? projection-value) projection-value (if (some? error-value) (d/raise-query-evaluation-error error-value) (throw (ex-info "query projection produced no result" {:type :query-projection-missing-result}))))))

(defn ^Projection project! [propositions]
  (projection-or-raise (project-result! propositions)))

(defn ^Projection project-with-history! [propositions occurrences withdrawals]
  (projection-or-raise (project-with-history-result! propositions occurrences withdrawals)))

(defn- set-union [left right]
  (reduce (fn [acc ^String value] (conj acc value)) left right))

(defn- empty-string-set []
  #{})

(defn- empty-query-errors []
  [])

(defn- empty-rules []
  [])

(defn- term-vars [terms]
  (reduce (fn [acc term] (let [name (d/queryterm-variable term)]
  (if (some? name) (conj acc name) acc))) (empty-string-set) terms))

(defn- term-errors [terms ^String context]
  (reduce (fn [acc term] (if (d/query-term? term) acc (conj acc (query-error :query-invalid-term (str context " contains an invalid QueryTerm"))))) [] terms))

(defn- unbound-errors [terms bound ^String context]
  (reduce (fn [acc ^String name] (if (contains? bound name) acc (conj acc (query-error :query-unbound-variable (str context " variable '" name "' is not bound"))))) [] (term-vars terms)))

(defn- head-arities [rules]
  (reduce (fn [acc rule] (let [relation (d/rule-head-relation rule)]
  (if (contains? acc relation) acc (assoc acc relation (count (d/rule-head-arguments rule)))))) {} rules))

(defn- derived-relations [rules]
  (reduce (fn [acc rule] (conj acc (d/rule-head-relation rule))) #{} rules))

(defn- relation-arity [^String relation arities]
  (if (contains? base-rel-arities relation) (get base-rel-arities relation) (get arities relation)))

(defn- literal-errors [literal known arities bound]
  (let [kind (d/literal-kind literal)
   arguments (d/literal-arguments literal)
   base-errors (term-errors arguments "literal")]
  (cond
  (= kind :relation) (let [relation (d/literal-relation literal)
   arity (relation-arity relation arities)
   relation-errors (cond
  (not (contains? known relation)) [(query-error :query-unknown-relation (str "unknown relation '" relation "'"))]
  (and (some? arity) (not (= arity (count arguments)))) [(query-error :query-arity (str "relation '" relation "' takes " arity " arguments"))]
  :else (empty-query-errors))
   range-errors (if (d/literal-negated literal) (unbound-errors arguments bound "negated literal") (empty-query-errors))]
  (vec (concat base-errors (concat relation-errors range-errors))))
  (= kind :comparison) (let [operator-errors (if (contains? d/comparison-operators (d/literal-operator literal)) (empty-query-errors) [(query-error :query-invalid-comparison "comparison operator is not supported")])
   arity-errors (if (= 2 (count arguments)) (empty-query-errors) [(query-error :query-arity "comparison literal takes two arguments")])]
  (vec (concat base-errors (concat operator-errors (concat arity-errors (unbound-errors arguments bound "comparison"))))))
  (= kind :builtin) (let [operator-errors (if (contains? d/builtin-operators (d/literal-operator literal)) (empty-query-errors) [(query-error :query-invalid-builtin "builtin operator is not supported")])
   arity-errors (if (= 2 (count arguments)) (empty-query-errors) [(query-error :query-arity "builtin literal takes two arguments")])
   binding (d/literal-binding literal)
   binding-errors (cond
  (not (pos? (count binding))) [(query-error :query-invalid-builtin "builtin binding must be non-empty")]
  (contains? bound binding) [(query-error :query-unbound-variable (str "builtin binding '" binding "' is already bound"))]
  :else (empty-query-errors))]
  (vec (concat base-errors (concat operator-errors (concat arity-errors (concat binding-errors (unbound-errors arguments bound "builtin")))))))
  :else [(query-error :query-invalid-literal "literal kind is not supported")])))

(defn- literal-bindings [literal]
  (cond
  (and (= :relation (d/literal-kind literal)) (not (d/literal-negated literal))) (term-vars (d/literal-arguments literal))
  (= :builtin (d/literal-kind literal)) #{(d/literal-binding literal)}
  :else #{}))

(defn- text-literal-errors! [literal bound]
  (if (and (= :relation (d/literal-kind literal)) (contains? d/text-relations (d/literal-relation literal))) (let [relation (d/literal-relation literal)
   arguments (d/literal-arguments literal)]
  (cond
  (d/literal-negated literal) [(query-error :query-text-negative (str relation " is available only as a positive relation"))]
  (not (= (get base-rel-arities relation) (count arguments))) (empty-query-errors)
  :else (let [needle (nth arguments 2)
   variable (d/queryterm-variable needle)]
  (cond
  (some? variable) (if (contains? bound variable) (empty-query-errors) [(query-error :query-text-unbound-needle (str relation " query must be constant or already bound"))])
  (d/text-relation-needle-valid?! relation (d/queryterm-value needle)) (empty-query-errors)
  :else [(query-error :query-text-invalid-needle (str relation " query is empty or invalid"))])))) (empty-query-errors)))

(defn- rule-errors! [rule known arities]
  (let [head-relation (d/rule-head-relation rule)
   head-arguments (d/rule-head-arguments rule)
   head-errors (vec (concat (if (pos? (count head-relation)) (empty-query-errors) [(query-error :query-invalid-rule "rule head relation is empty")]) (concat (if (contains? base-relations head-relation) [(query-error :query-base-shadow (str "rule head cannot redefine base relation '" head-relation "'"))] (empty-query-errors)) (term-errors head-arguments "rule head"))))]
  (let [body (d/rule-body rule)]
  (loop [position 0
   bound (empty-string-set)
   errors head-errors]
  (if (>= position (count body)) (vec (concat errors (unbound-errors head-arguments bound "rule head"))) (let [literal (nth body position)]
  (recur (inc position) (set-union bound (literal-bindings literal)) (vec (concat errors (concat (literal-errors literal known arities bound) (text-literal-errors! literal bound)))))))))))

(defn- arity-errors [rules]
  (let [arities (head-arities rules)]
  (reduce (fn [acc rule] (let [relation (d/rule-head-relation rule)
   expected (get arities relation)
   actual (count (d/rule-head-arguments rule))]
  (if (= expected actual) acc (conj acc (query-error :query-arity (str "relation '" relation "' has inconsistent arity")))))) (empty-query-errors) rules)))

(defn- positive-relations [rule]
  (reduce (fn [acc literal] (if (and (= :relation (d/literal-kind literal)) (not (d/literal-negated literal))) (conj acc (d/literal-relation literal)) acc)) (empty-string-set) (d/rule-body rule)))

(defn- dependency-edges [rules]
  (reduce (fn [acc rule] (let [head (d/rule-head-relation rule)]
  (update acc head (fn [current] (set-union (or current (empty-string-set)) (positive-relations rule)))))) {} rules))

(defn- ^Boolean reaches? [^String start ^String target edges]
  (loop [frontier (vec (get edges start (empty-string-set)))
   position 0
   seen (empty-string-set)]
  (if (>= position (count frontier)) false (let [current (nth frontier position)]
  (cond
  (= current target) true
  (contains? seen current) (recur frontier (inc position) seen)
  :else (recur (vec (concat frontier (vec (get edges current (empty-string-set))))) (inc position) (conj seen current)))))))

(defn- recursive-relations [rules]
  (let [edges (dependency-edges rules)]
  (reduce (fn [acc rule] (let [relation (d/rule-head-relation rule)]
  (if (reaches? relation relation edges) (conj acc relation) acc))) (empty-string-set) rules)))

(defn- ^Boolean recursive-builtin? [rule]
  (let [body (d/rule-body rule)]
  (loop [position 0]
  (if (>= position (count body)) false (if (= :builtin (d/literal-kind (nth body position))) true (recur (inc position)))))))

(defn- recursive-builtin-errors [rules]
  (let [recursive (recursive-relations rules)]
  (reduce (fn [acc rule] (if (and (contains? recursive (d/rule-head-relation rule)) (recursive-builtin? rule)) (conj acc (query-error :query-recursive-builtin (str "recursive relation '" (d/rule-head-relation rule) "' cannot contain a builtin binding"))) acc)) (empty-query-errors) rules)))

(defn- forward-errors [strata all-derived]
  (loop [position 0
   lower base-relations
   errors (empty-query-errors)]
  (if (>= position (count strata)) errors (let [stratum (nth strata position)
   current (derived-relations stratum)
   available (set-union lower current)
   errors2 (reduce (fn [acc rule] (reduce (fn [inner ^String relation] (if (and (contains? all-derived relation) (not (contains? available relation))) (conj inner (query-error :query-forward-reference (str "relation '" relation "' is defined only in a later stratum"))) inner)) acc (positive-relations rule))) errors stratum)]
  (recur (inc position) (set-union lower current) errors2)))))

(defn- find-errors [^FindSpec find derived arities]
  (let [relation (findspec-relation find)
   arity (get arities relation)
   relation-errors (cond
  (contains? base-relations relation) [(query-error :query-invalid-find "find cannot name a base relation")]
  (not (contains? derived relation)) [(query-error :query-invalid-find (str "find relation '" relation "' is not derived"))]
  :else (empty-query-errors))
   aggregate-errors (if (aggregate-find? find) (let [group-errors (reduce (fn [acc position] (if (and (>= position 0) (and (some? arity) (< position arity))) acc (conj acc (query-error :query-invalid-aggregate "aggregate group position is out of range")))) (empty-query-errors) (findspec-grouping find))
   spec-errors (reduce (fn [acc ^AggregateSpec spec] (let [operator (aggregatespec-operator spec)
   argument (aggregatespec-argument spec)]
  (cond
  (not (contains? aggregate-operators operator)) (conj acc (query-error :query-invalid-aggregate "aggregate operator is not supported"))
  (and (contains? aggregate-argument-operators operator) (nil? argument)) (conj acc (query-error :query-invalid-aggregate "aggregate operator requires an argument position"))
  (and (some? argument) (not (and (>= argument 0) (and (some? arity) (< argument arity))))) (conj acc (query-error :query-invalid-aggregate "aggregate argument position is out of range"))
  :else acc))) (empty-query-errors) (findspec-aggregates find))
   having-errors (reduce (fn [acc ^HavingClause clause] (cond
  (not (contains? d/comparison-operators (havingclause-operator clause))) (conj acc (query-error :query-invalid-having "having operator is not supported"))
  (not (and (>= (havingclause-aggregate-index clause) 0) (< (havingclause-aggregate-index clause) (count (findspec-aggregates find))))) (conj acc (query-error :query-invalid-having "having aggregate index is out of range"))
  (not (number? (havingclause-value clause))) (conj acc (query-error :query-invalid-having "having comparison value must be numeric"))
  :else acc)) (empty-query-errors) (findspec-having find))]
  (vec (concat group-errors (concat spec-errors having-errors)))) (if (or (not (empty? (findspec-grouping find))) (not (empty? (findspec-having find)))) [(query-error :query-invalid-find "plain find cannot contain grouping or having clauses")] (empty-query-errors)))]
  (vec (concat relation-errors aggregate-errors))))

(defn- result-arity [^FindSpec find arities]
  (if (aggregate-find? find) (+ (count (findspec-grouping find)) (count (findspec-aggregates find))) (get arities (findspec-relation find))))

(defn- order-errors [^QueryPlan plan arities]
  (let [arity (result-arity (queryplan-find plan) arities)
   clause-errors (loop [remaining (queryplan-order plan)
   seen #{}
   errors []]
  (if (empty? remaining) errors (let [clause (first remaining)
   column (orderclause-column clause)
   direction (orderclause-direction clause)
   errors2 (cond
  (not (contains? #{:asc :desc} direction)) (conj errors (query-error :query-invalid-order "query order direction must be :asc or :desc"))
  (or (< column 0) (and (some? arity) (>= column arity))) (conj errors (query-error :query-invalid-order "query order column is out of range"))
  (contains? seen column) (conj errors (query-error :query-invalid-order "query order columns must be unique"))
  :else errors)]
  (recur (rest remaining) (conj seen column) errors2))))
   limit (queryplan-limit plan)
   limit-errors (if (and (some? limit) (or (< limit 1) (> limit max-results))) [(query-error :query-invalid-limit (str "query limit must be from 1 through " max-results))] [])]
  (vec (concat clause-errors limit-errors))))

(defn validate-plan! [^QueryPlan plan]
  (let [strata (queryplan-strata plan)
   rules (reduce (fn [acc stratum] (vec (concat acc stratum))) (empty-rules) strata)
   derived (derived-relations rules)
   known (set-union base-relations derived)
   arities (head-arities rules)
   empty-errors (if (empty? rules) [(query-error :query-invalid-plan "query plan must contain at least one rule")] (empty-query-errors))
   rules-errors (reduce (fn [acc rule] (vec (concat acc (rule-errors! rule known arities)))) (empty-query-errors) rules)
   strata-errors (reduce (fn [acc ^String message] (conj acc (query-error :query-stratification message))) (empty-query-errors) (d/strata-violations strata))]
  (vec (concat empty-errors (concat rules-errors (concat (arity-errors rules) (concat (recursive-builtin-errors rules) (concat (forward-errors strata derived) (concat strata-errors (concat (find-errors (queryplan-find plan) derived arities) (order-errors plan arities)))))))))))

(defn- ^Boolean variable-form? [value]
  (and (map? value) (and (= 1 (count value)) (and (contains? value :var) (and (string? (:var value)) (pos? (count (:var value))))))))

(defn- ^Boolean query-term-form? [value]
  (or (variable-form? value) (t/term? value)))

(defn- ^Boolean all-vectors? [values]
  (loop [remaining values]
  (if (empty? remaining) true (if (vector? (first remaining)) (recur (rest remaining)) false))))

(defn- raw-strata [form]
  (cond
  (not (map? form)) nil
  (and (contains? form :rules) (not (contains? form :strata))) (if (vector? (:rules form)) [(:rules form)] nil)
  (and (contains? form :strata) (not (contains? form :rules))) (if (and (vector? (:strata form)) (all-vectors? (:strata form))) (:strata form) nil)
  :else nil))

(defn- syntax-term-errors [values ^String context]
  (if (not (vector? values)) [(query-error :query-invalid-syntax (str context " arguments must be a vector"))] (reduce (fn [acc value] (if (query-term-form? value) acc (conj acc (query-error :query-invalid-syntax (str context " contains an invalid term"))))) [] values)))

(defn- syntax-literal-errors [literal]
  (if (not (map? literal)) [(query-error :query-invalid-syntax "literal must be a map")] (cond
  (contains? literal :pred) (vec (concat (if (keyword? (:pred literal)) [] [(query-error :query-invalid-syntax "comparison operator must be a keyword")]) (syntax-term-errors (:args literal) "comparison")))
  (contains? literal :fn) (vec (concat (if (and (keyword? (:fn literal)) (string? (:bind literal))) [] [(query-error :query-invalid-syntax "builtin requires keyword :fn and string :bind")]) (syntax-term-errors (:args literal) "builtin")))
  :else (vec (concat (if (string? (:rel literal)) [] [(query-error :query-invalid-syntax "relation literal requires string :rel")]) (concat (if (or (nil? (:neg literal)) (or (= true (:neg literal)) (= false (:neg literal)))) [] [(query-error :query-invalid-syntax "literal :neg must be boolean")]) (syntax-term-errors (:args literal) "literal")))))))

(defn- syntax-rule-errors [rule]
  (if (not (map? rule)) [(query-error :query-invalid-syntax "rule must be a map")] (let [head (:head rule)
   body (:body rule)
   head-errors (if (and (map? head) (and (string? (:rel head)) (vector? (:args head)))) (syntax-term-errors (:args head) "rule head") [(query-error :query-invalid-syntax "rule head must contain string :rel and vector :args")])
   body-errors (if (vector? body) (reduce (fn [acc literal] (vec (concat acc (syntax-literal-errors literal)))) [] body) [(query-error :query-invalid-syntax "rule body must be a vector")])]
  (vec (concat head-errors body-errors)))))

(defn- syntax-find-errors [find]
  (cond
  (string? find) []
  (not (map? find)) [(query-error :query-invalid-syntax "find must be a relation string or aggregate map")]
  :else (let [base-errors (vec (concat (if (string? (:rel find)) [] [(query-error :query-invalid-syntax "aggregate find requires string :rel")]) (concat (if (and (vector? (:group find)) (every? integer? (:group find))) [] [(query-error :query-invalid-syntax "aggregate :group must contain integer positions")]) (if (and (vector? (:agg find)) (not (empty? (:agg find)))) [] [(query-error :query-invalid-syntax "aggregate :agg must be a non-empty vector")]))))
   spec-errors (if (vector? (:agg find)) (reduce (fn [acc spec] (if (and (map? spec) (and (keyword? (:op spec)) (or (nil? (:arg spec)) (integer? (:arg spec))))) acc (conj acc (query-error :query-invalid-syntax "aggregate spec requires keyword :op and optional integer :arg")))) [] (:agg find)) [])
   having-errors (if (or (nil? (:having find)) (vector? (:having find))) (reduce (fn [acc clause] (if (and (map? clause) (and (keyword? (:op clause)) (and (integer? (:agg clause)) (number? (:val clause))))) acc (conj acc (query-error :query-invalid-syntax "having clause requires :op, integer :agg, and numeric :val")))) [] (or (:having find) [])) [(query-error :query-invalid-syntax "aggregate :having must be a vector")])]
  (vec (concat base-errors (concat spec-errors having-errors))))))

(defn- syntax-order-errors [value]
  (if (or (nil? value) (vector? value)) (reduce (fn [errors clause] (if (and (map? clause) (and (integer? (:column clause)) (contains? #{:asc :desc} (:direction clause)))) errors (conj errors (query-error :query-invalid-syntax "query :order-by requires :column and :direction")))) [] (or value [])) [(query-error :query-invalid-syntax "query :order-by must be a vector")]))

(defn- syntax-errors [form]
  (cond
  (not (map? form)) [(query-error :query-invalid-syntax "query must be a map")]
  (= (contains? form :rules) (contains? form :strata)) [(query-error :query-invalid-syntax "query must provide exactly one of :rules or :strata")]
  (nil? (raw-strata form)) [(query-error :query-invalid-syntax "rules or strata have an invalid shape")]
  :else (let [strata (raw-strata form)
   rules (reduce (fn [acc stratum] (vec (concat acc stratum))) [] strata)
   rule-errors (reduce (fn [acc rule] (vec (concat acc (syntax-rule-errors rule)))) [] rules)]
  (vec (concat (syntax-find-errors (:find form)) (concat (syntax-order-errors (:order-by form)) (concat (if (or (nil? (:limit form)) (integer? (:limit form))) [] [(query-error :query-invalid-syntax "query :limit must be an integer")]) rule-errors)))))))

(defn- compile-term-form [value]
  (if (variable-form? value) (d/variable (:var value)) (d/constant value)))

(defn- compile-term-forms [values]
  (mapv (fn [value] (compile-term-form value)) values))

(defn- compile-literal-form [literal]
  (cond
  (contains? literal :pred) (d/comparison-literal (:pred literal) (compile-term-forms (:args literal)))
  (contains? literal :fn) (d/builtin-literal (:fn literal) (compile-term-forms (:args literal)) (:bind literal))
  (= true (:neg literal)) (d/negated-literal (:rel literal) (compile-term-forms (:args literal)))
  :else (d/relation-literal (:rel literal) (compile-term-forms (:args literal)))))

(defn- compile-rule-form [rule]
  (d/rule (:rel (:head rule)) (compile-term-forms (:args (:head rule))) (mapv (fn [literal] (compile-literal-form literal)) (:body rule))))

(defn- ^FindSpec compile-find-form [find]
  (if (string? find) (relation-find find) (aggregate-find (:rel find) (:group find) (mapv (fn [spec] (aggregate-spec (:op spec) (:arg spec))) (:agg find)) (mapv (fn [clause] (having-clause (:op clause) (:agg clause) (:val clause))) (or (:having find) [])))))

(defn ^CompileResult compile-query! [form]
  (if (query-plan? form) (let [errors (validate-plan! form)]
  (if (empty? errors) (->CompileResult form []) (->CompileResult nil errors))) (let [errors (syntax-errors form)]
  (if (not (empty? errors)) (->CompileResult nil errors) (let [strata (mapv (fn [stratum] (mapv (fn [rule] (compile-rule-form rule)) stratum)) (raw-strata form))
   plan (ordered-query-plan (compile-find-form (:find form)) strata (mapv (fn [clause] (order-clause (:column clause) (:direction clause))) (or (:order-by form) [])) (:limit form))
   validation-errors (validate-plan! plan)]
  (if (empty? validation-errors) (->CompileResult plan []) (->CompileResult nil validation-errors)))))))

(defn- ^String length-key [^String tag ^String value]
  (str tag (count value) ":" value))

(defn ^String term-key [value]
  (cond
  (string? value) (let [text value]
  (length-key "s" text))
  (integer? value) (let [integer-value value]
  (str "i" integer-value ";"))
  (number? value) (let [float-value value]
  (str "f" float-value ";"))
  (boolean? value) (let [bool-value value]
  (if bool-value "b1;" "b0;"))
  (keyword? value) (let [keyword-value value]
  (length-key "k" (str keyword-value)))
  (t/instant? value) (let [instant-value value]
  (str "m" (t/instant-epoch-seconds instant-value) ":" (t/instant-nanos instant-value) ";"))
  (t/triple? value) (let [triple-value value
   t1 (term-key (t/triple-t1 triple-value))
   t2 (term-key (t/triple-t2 triple-value))
   t3 (term-key (t/triple-t3 triple-value))]
  (str "t" (count t1) ":" t1 (count t2) ":" t2 (count t3) ":" t3))
  :else "x0:"))

(defn ^String row-key [row]
  (reduce (fn [^String acc value] (let [key (term-key value)]
  (str acc (count key) ":" key))) "r" row))

(defn- order-row-vector [rows]
  (let [by-key (reduce (fn [acc row] (assoc acc (row-key row) row)) {} rows)
   keys (reduce (fn [acc row] (conj acc (row-key row))) [] rows)]
  (mapv (fn [^String key] (let [row (get by-key key)]
  (if (some? row) (let [present row]
  present) []))) (vec (sort keys)))))

(defn- ordered-rows [rows]
  (order-row-vector (vec rows)))

(defn- term-rank [value]
  (cond
  (boolean? value) 0
  (number? value) 1
  (string? value) 2
  (keyword? value) 3
  (t/instant? value) 4
  (t/triple? value) 5
  :else 6))

(defn- int-compare [left right]
  (cond
  (< left right) -1
  (> left right) 1
  :else 0))

(defn- bool-compare [^Boolean left ^Boolean right]
  (cond
  (= left right) 0
  left 1
  :else -1))

(defn- float-compare [left right]
  (cond
  (< left right) -1
  (> left right) 1
  :else 0))

(defn term-compare [left right]
  (let [left-rank (term-rank left)
   right-rank (term-rank right)
   rank-order (int-compare left-rank right-rank)]
  (if (not (zero? rank-order)) rank-order (cond
  (and (boolean? left) (boolean? right)) (let [left-bool left
   right-bool right]
  (bool-compare left-bool right-bool))
  (and (number? left) (number? right)) (if (and (integer? left) (integer? right)) (let [left-int left
   right-int right]
  (int-compare left-int right-int)) (let [left-float (double left)
   right-float (double right)]
  (float-compare left-float right-float)))
  (and (string? left) (string? right)) (let [left-string left
   right-string right]
  (compare left-string right-string))
  (and (keyword? left) (keyword? right)) (let [left-keyword left
   right-keyword right]
  (compare (str left-keyword) (str right-keyword)))
  (and (t/instant? left) (t/instant? right)) (let [left-instant left
   right-instant right
   seconds-order (int-compare (t/instant-epoch-seconds left-instant) (t/instant-epoch-seconds right-instant))]
  (if (zero? seconds-order) (int-compare (t/instant-nanos left-instant) (t/instant-nanos right-instant)) seconds-order))
  (and (t/triple? left) (t/triple? right)) (let [left-triple left
   right-triple right
   first-order (term-compare (t/triple-t1 left-triple) (t/triple-t1 right-triple))
   second-order (if (zero? first-order) (term-compare (t/triple-t2 left-triple) (t/triple-t2 right-triple)) first-order)]
  (if (zero? second-order) (term-compare (t/triple-t3 left-triple) (t/triple-t3 right-triple)) second-order))
  :else (compare (term-key left) (term-key right))))))

(defn- ordered-row-compare [order left right]
  (loop [remaining order]
  (if (empty? remaining) (compare (row-key left) (row-key right)) (let [clause (first remaining)
   column-order (term-compare (nth left (orderclause-column clause)) (nth right (orderclause-column clause)))
   directed-order (if (= :desc (orderclause-direction clause)) (- 0 column-order) column-order)]
  (if (zero? directed-order) (recur (rest remaining)) directed-order)))))

(defn- merge-ordered-row-vectors [order left right]
  (loop [left-index 0
   right-index 0
   merged []]
  (cond
  (>= left-index (count left)) (into merged (subvec right right-index))
  (>= right-index (count right)) (into merged (subvec left left-index))
  (<= (ordered-row-compare order (nth left left-index) (nth right right-index)) 0) (recur (inc left-index) right-index (conj merged (nth left left-index)))
  :else (recur left-index (inc right-index) (conj merged (nth right right-index))))))

(defn- merge-sort-ordered-rows [order rows]
  (if (<= (count rows) 1) rows (let [middle (quot (count rows) 2)
   left (merge-sort-ordered-rows order (subvec rows 0 middle))
   right (merge-sort-ordered-rows order (subvec rows middle))]
  (merge-ordered-row-vectors order left right))))

(defn ordered-plan-rows [^QueryPlan plan rows]
  (let [order (queryplan-order plan)
   ordered (if (empty? order) (order-row-vector rows) (merge-sort-ordered-rows order rows))
   limit (queryplan-limit plan)]
  (if (some? limit) (vec (take limit ordered)) ordered)))

(defn- evaluate-plan-result! [^Projection projection ^QueryPlan plan control]
  (d/run-strata-db-with-candidates-result! (projection-edb projection) (queryplan-strata plan) (projection-candidates projection) control))

(defn- ^QueryResult abort-result [problem]
  (let [data (ex-data problem)]
  (if (= :fram-query-abort (:type data)) (failure-result [(query-error (:code data) (ex-message problem))]) (throw problem))))

(def numeric-aggregate-operators #{:sum :avg :min :max})

(defn- number-atom [value]
  (cond
  (number? value) (if (integer? value) (let [integer-value value]
  integer-value) (let [float-value value]
  float-value))
  (string? value) (let [text value
   integer-result (parse-long text)]
  (if (some? integer-result) (let [integer-value integer-result
   numeric-value integer-value]
  numeric-value) (let [float-result (parse-double text)]
  (if (some? float-result) (let [float-value float-result
   numeric-value float-value]
  numeric-value) nil))))
  :else nil))

(defn- required-number [value]
  (let [number (number-atom value)]
  (if (some? number) (let [present number]
  present) 0)))

(defn- numeric-int [value]
  (if (integer? value) (let [integer-value value]
  integer-value) 0))

(defn- numeric-float [value]
  (if (integer? value) (let [integer-value value]
  (double integer-value)) (let [float-value value]
  float-value)))

(defn- ^Boolean nonnumeric-row? [rows position]
  (loop [index 0]
  (if (>= index (count rows)) false (if (nil? (number-atom (nth (nth rows index) position))) true (recur (inc index))))))

(defn- numeric-column-error [rows ^FindSpec find]
  (let [specs (findspec-aggregates find)]
  (loop [index 0]
  (if (>= index (count specs)) nil (let [spec (nth specs index)]
  (if (contains? numeric-aggregate-operators (aggregatespec-operator spec)) (let [position (or (aggregatespec-argument spec) 0)
   bad (nonnumeric-row? rows position)]
  (if bad (query-error :query-nonnumeric-aggregate (str "aggregate position " position " contains a non-numeric Term")) (recur (inc index)))) (recur (inc index))))))))

(defn- ^AggregateGroups group-rows [rows grouping]
  (reduce (fn [^AggregateGroups acc row] (let [key (mapv (fn [position] (nth row position)) grouping)
   key-text (row-key key)
   groups (aggregategroups-by-key acc)
   current (get groups key-text)]
  (if (some? current) (let [group current
   updated (->AggregateGroup (aggregategroup-key group) (conj (aggregategroup-members group) row))]
  (->AggregateGroups (assoc groups key-text updated) (aggregategroups-order acc))) (->AggregateGroups (assoc groups key-text (->AggregateGroup key [row])) (conj (aggregategroups-order acc) key-text))))) (->AggregateGroups {} []) rows))

(defn- ^Boolean all-integers? [rows position]
  (every? (fn [row] (integer? (required-number (nth row position)))) rows))

(defn- sum-values [rows position]
  (if (all-integers? rows position) (reduce (fn [acc row] (+ acc (numeric-int (required-number (nth row position))))) 0 rows) (reduce (fn [acc row] (+ acc (numeric-float (required-number (nth row position))))) 0.0 rows)))

(defn- extreme-value [rows position ^Boolean maximum?]
  (reduce (fn [best row] (let [candidate (required-number (nth row position))]
  (if (nil? best) candidate (let [present-best best]
  (if (if maximum? (> (numeric-float candidate) (numeric-float present-best)) (< (numeric-float candidate) (numeric-float present-best))) candidate present-best))))) nil rows))

(defn- distinct-column-count [rows position]
  (count (reduce (fn [keys row] (conj keys (term-key (nth row position)))) (empty-string-set) rows)))

(defn- aggregate-value [rows ^AggregateSpec spec]
  (let [operator (aggregatespec-operator spec)
   position (or (aggregatespec-argument spec) 0)]
  (cond
  (= operator :count) (count rows)
  (= operator :count-distinct) (distinct-column-count rows position)
  (= operator :sum) (sum-values rows position)
  (= operator :avg) (/ (numeric-float (sum-values rows position)) (double (count rows)))
  (= operator :min) (or (extreme-value rows position false) 0)
  (= operator :max) (or (extreme-value rows position true) 0)
  :else 0)))

(defn- ^Boolean comparison-number [operator left right]
  (let [left-number (numeric-float left)
   right-number (numeric-float right)]
  (cond
  (= operator :eq) (= left-number right-number)
  (= operator :ne) (not (= left-number right-number))
  (= operator :lt) (< left-number right-number)
  (= operator :le) (<= left-number right-number)
  (= operator :gt) (> left-number right-number)
  (= operator :ge) (>= left-number right-number)
  :else false)))

(defn- aggregate-values [rows specs]
  (mapv (fn [^AggregateSpec spec] (aggregate-value rows spec)) specs))

(defn- append-aggregate-values [row values]
  (reduce (fn [current value] (if (integer? value) (let [integer-value value
   element integer-value]
  (conj current element)) (let [float-value value
   element float-value]
  (conj current element)))) row values))

(defn- ^Boolean having-passes? [row grouping-count clauses]
  (every? (fn [^HavingClause clause] (comparison-number (havingclause-operator clause) (required-number (nth row (+ grouping-count (havingclause-aggregate-index clause)))) (required-number (havingclause-value clause)))) clauses))

(defn- ^QueryResult aggregate-result [db ^QueryPlan plan]
  (let [find (queryplan-find plan)
   rows (vec (get db (findspec-relation find) #{}))]
  (if (empty? rows) (success-result []) (let [numeric-error (numeric-column-error rows find)]
  (if (some? numeric-error) (failure-result [numeric-error]) (let [groups (group-rows rows (findspec-grouping find))
   aggregated (reduce (fn [acc ^String group-key] (let [group-value (get (aggregategroups-by-key groups) group-key)
   group (if (some? group-value) (let [present group-value]
  present) (->AggregateGroup [] []))
   key (aggregategroup-key group)
   members (aggregategroup-members group)
   values (aggregate-values members (findspec-aggregates find))]
  (conj acc (append-aggregate-values key values)))) [] (aggregategroups-order groups))
   survivors (filterv (fn [row] (having-passes? row (count (findspec-grouping find)) (findspec-having find))) aggregated)
   count-value (count survivors)]
  (if (and (nil? (queryplan-limit plan)) (> count-value max-results)) (limited-result (query-error :query-result-limit (str "aggregate result has " count-value " groups, over limit " max-results)) count-value max-results) (success-result (ordered-plan-rows plan survivors)))))))))

(defn ^QueryExecutionResult run-plan-projected-result! [^Projection projection ^QueryPlan plan control]
  (let [errors (validate-plan! plan)]
  (if (not (empty? errors)) (->QueryExecutionResult (failure-result errors) nil) (let [evaluation (evaluate-plan-result! projection plan control)
   error-value (d/query-evaluation-result-error evaluation)]
  (if (some? error-value) (->QueryExecutionResult nil error-value) (let [db (d/query-evaluation-db evaluation)
   find (queryplan-find plan)
   result (if (aggregate-find? find) (aggregate-result db plan) (let [rows (get db (findspec-relation find) #{})
   count-value (count rows)]
  (if (and (nil? (queryplan-limit plan)) (> count-value max-results)) (limited-result (query-error :query-result-limit (str "result has " count-value " rows, over limit " max-results)) count-value max-results) (success-result (ordered-plan-rows plan (vec rows))))))]
  (->QueryExecutionResult result nil)))))))

(defn ^QueryExecutionResult run-plan-with-history-result! [propositions occurrences withdrawals ^QueryPlan plan control]
  (let [projection-result (project-with-history-result! propositions occurrences withdrawals)
   projection-value (projection-result-projection projection-result)
   error-value (projection-result-error projection-result)]
  (cond
  (some? projection-value) (run-plan-projected-result! projection-value plan control)
  (some? error-value) (->QueryExecutionResult nil error-value)
  :else (->QueryExecutionResult nil (d/query-evaluation-error :query-projection-missing-result :rpc/native-query-failed "query projection produced no result")))))

(defn- ^QueryResult execution-result-or-raise! [^QueryExecutionResult execution]
  (let [result (queryexecutionresult-query-result execution)
   error-value (queryexecutionresult-error execution)]
  (cond
  (some? result) result
  (some? error-value) (if (= :fram-query-abort (d/query-evaluation-error-type error-value)) (failure-result [(query-error (d/query-evaluation-error-code error-value) (d/query-evaluation-error-message error-value))]) (d/raise-query-evaluation-error! error-value))
  :else (failure-result [(query-error :query-evaluation-missing-result "query evaluation produced no result")]))))

(defn ^QueryResult run-plan-projected-controlled! [^Projection projection ^QueryPlan plan control]
  (try
  (execution-result-or-raise! (run-plan-projected-result! projection plan control))
  (catch Exception problem
    (abort-result problem))))

(defn ^QueryResult run-plan-projected! [^Projection projection ^QueryPlan plan]
  (run-plan-projected-controlled! projection plan *query-control*))

(defn ^QueryResult run-projected! [^Projection projection ^QueryPlan plan]
  (run-plan-projected! projection plan))

(defn ^QueryResult run! [propositions ^QueryPlan plan]
  (run-plan-projected! (project! propositions) plan))

(defn ^QueryResult run-syntax! [propositions form]
  (let [compiled (compile-query! form)
   plan (compileresult-plan compiled)]
  (if (some? plan) (run! propositions plan) (failure-result (compileresult-errors compiled)))))

(def max-page-limit 4096)

(def max-page-wire-bytes 1048576)

(def max-page-payload-bytes (- max-page-wire-bytes 512))

(def max-page-cursor-bytes 524288)

(def ^String page-cursor-prefix "fram-query-term-page-v1.")

(defn- utf8-size [^String value]
  (count (.getBytes value "UTF-8")))

(defn ^String page-cursor [row]
  (str page-cursor-prefix (row-key row)))

(defn ^CursorResult decode-page-cursor [cursor]
  (if (not (string? cursor)) (->CursorResult nil (query-error :query-page-cursor "page cursor must be a string")) (if (or (> (utf8-size cursor) max-page-cursor-bytes) (or (not (str/starts-with? cursor page-cursor-prefix)) (= cursor page-cursor-prefix))) (->CursorResult nil (query-error :query-page-cursor "page cursor is not canonical")) (->CursorResult (subs cursor (count page-cursor-prefix)) nil))))

(defn- ^QueryPage page-envelope [window count-value]
  (let [rows (subvec window 0 count-value)
   more (> (count window) count-value)
   next (if (and more (> count-value 0)) (page-cursor (nth rows (- count-value 1))) nil)]
  (success-page rows next more)))

(defn- envelope-size [rows-size next ^Boolean more]
  (+ (utf8-size "rows:") rows-size (utf8-size "|next:") (utf8-size (pr-str next)) (utf8-size "|more:") (utf8-size (pr-str more))))

(defn- fitting-prefix [window wanted]
  (loop [index 0
   rows-size 2
   best 0]
  (if (>= index wanted) best (let [row (nth window index)
   count-value (+ index 1)
   rows-size2 (+ rows-size (if (= index 0) 0 1) (utf8-size (pr-str row)))
   more (> (count window) count-value)
   next (if more (page-cursor row) nil)
   fits (and (or (nil? next) (<= (utf8-size next) max-page-cursor-bytes)) (<= (envelope-size rows-size2 next more) max-page-payload-bytes))]
  (recur count-value rows-size2 (if fits count-value best))))))

(defn- ^QueryPage abort-page [problem]
  (let [data (ex-data problem)]
  (if (= :fram-query-abort (:type data)) (failure-page [(query-error (:code data) (ex-message problem))]) (throw problem))))

(defn- ^QueryPage evaluation-error-page-or-raise! [error-value]
  (if (= :fram-query-abort (d/query-evaluation-error-type error-value)) (failure-page [(query-error (d/query-evaluation-error-code error-value) (d/query-evaluation-error-message error-value))]) (d/raise-query-evaluation-error! error-value)))

(defn- rows-after-key [rows ^String after-key]
  (loop [position 0]
  (cond
  (>= position (count rows)) []
  (= after-key (row-key (nth rows position))) (vec (drop (inc position) rows))
  :else (recur (inc position)))))

(defn ^QueryPage run-page-plan-projected! [^Projection projection ^QueryPlan plan limit after]
  (let [validation-errors (validate-plan! plan)]
  (cond
  (not (empty? validation-errors)) (failure-page validation-errors)
  (aggregate-find? (queryplan-find plan)) (failure-page [(query-error :query-aggregate-not-pageable "aggregate results are not pageable")])
  (or (not (integer? limit)) (or (< limit 1) (> limit max-page-limit))) (failure-page [(query-error :query-page-limit (str "page limit must be from 1 through " max-page-limit))])
  (and (some? after) (not (string? after))) (failure-page [(query-error :query-page-cursor "page cursor must be a string or nil")])
  :else (let [decoded (if (some? after) (decode-page-cursor after) (->CursorResult nil nil))
   cursor-error (cursorresult-error decoded)]
  (if (some? cursor-error) (failure-page [cursor-error]) (try
  (let [evaluation (evaluate-plan-result! projection plan *query-control*)
   error-value (d/query-evaluation-result-error evaluation)]
  (if (some? error-value) (evaluation-error-page-or-raise! error-value) (let [db (d/query-evaluation-db evaluation)
   relation (get db (findspec-relation (queryplan-find plan)) #{})
   ordered (ordered-plan-rows plan (vec relation))
   after-key (cursorresult-key decoded)
   eligible (if (some? after-key) (rows-after-key ordered after-key) ordered)
   window (vec (take (+ limit 1) eligible))
   wanted (min limit (count window))]
  (if (= wanted 0) (page-envelope window 0) (let [count-value (fitting-prefix window wanted)]
  (if (= count-value 0) (wire-failure-page (query-error :query-page-row-too-large "page contains a row too large for the bounded response") max-page-wire-bytes) (page-envelope window count-value)))))))
  (catch Exception problem
    (abort-page problem))))))))

(defn ^QueryPage run-page-projected! [^Projection projection ^QueryPlan plan limit after]
  (run-page-plan-projected! projection plan limit after))

(defn ^QueryPage run-page! [propositions ^QueryPlan plan limit after]
  (run-page-plan-projected! (project! propositions) plan limit after))
