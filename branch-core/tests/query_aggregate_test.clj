;; Aggregate finds operate after recursive-Term Datalog evaluation. Group keys
;; remain Terms, numeric results remain typed atoms, and failures are QueryError
;; values rather than alternate map envelopes.
(require '[fram.datalog :as d]
         '[fram.query :as q]
         '[fram.types :as t])

(def checks (atom []))
(defn check! [label value] (swap! checks conj [label (boolean value)]))
(defn v [name] (d/variable name))
(defn c [value] (d/constant value))
(defn rel [name arguments] (d/relation-literal name arguments))
(defn neg [name arguments] (d/negated-literal name arguments))
(defn rule [name head body] (d/rule name head body))
(defn aggregate [operator argument] (q/aggregate-spec operator argument))
(defn having [operator index value] (q/having-clause operator index value))
(defn aggregate-plan
  ([relation grouping aggregates rules]
   (aggregate-plan relation grouping aggregates [] [rules]))
  ([relation grouping aggregates clauses strata]
   (q/query-plan (q/aggregate-find relation grouping aggregates clauses) strata)))
(defn result! [propositions query-plan] (q/run! propositions query-plan))
(defn rows [query-result] (q/result-rows query-result))
(defn codes [query-result] (set (map q/error-code (q/result-errors query-result))))

(def alice (t/triple :person :key "alice"))
(def bob (t/triple :person :key "bob"))
(def carol (t/triple :person :key "carol"))
(def scores [(t/triple alice :score 3)
             (t/triple alice :score 5)
             (t/triple bob :score 10)
             (t/triple bob :score 20)])
(def score-rule
  (rule "score" [(v "person") (v "value")]
        [(rel "triple" [(v "person") (c :score) (v "value")])]))
(defn score-aggregate [operator]
  (result! scores
          (aggregate-plan "score" [0]
                          [(aggregate operator (when (not= operator :count) 1))]
                          [score-rule])))

(check! ":count preserves recursive Term group keys"
        (= #{[alice 2] [bob 2]} (set (rows (score-aggregate :count)))))
(check! ":sum returns Int atoms when every input is integral"
        (= #{[alice 8] [bob 30]} (set (rows (score-aggregate :sum)))))
(check! ":avg returns Double atoms"
        (= #{[alice 4.0] [bob 15.0]} (set (rows (score-aggregate :avg)))))
(check! ":min returns the numeric minimum"
        (= #{[alice 3] [bob 10]} (set (rows (score-aggregate :min)))))
(check! ":max returns the numeric maximum"
        (= #{[alice 5] [bob 20]} (set (rows (score-aggregate :max)))))

(let [propositions [(t/triple alice :first 7)
                    (t/triple alice :second 7)
                    (t/triple alice :third 9)]
      value-rule
      (rule "value" [(v "person") (v "source") (v "value")]
            [(rel "triple" [(v "person") (v "source") (v "value")])])
      query-plan
      (aggregate-plan "value" [0] [(aggregate :count-distinct 2)] [value-rule])]
  (check! ":count-distinct deduplicates recursive relation values"
          (= [[alice 2]] (rows (result! propositions query-plan)))))

(let [propositions [(t/triple carol :score 1.5)
                    (t/triple carol :other-score 2.5)]
      value-rule
      (rule "value" [(v "person") (v "value")]
            [(rel "triple" [(v "person") (v "slot") (v "value")])])
      sum-result
      (result! propositions
              (aggregate-plan "value" [0] [(aggregate :sum 1)] [value-rule]))]
  (check! ":sum widens to Double when an input is fractional"
          (= [[carol 4.0]] (rows sum-result))))

(let [propositions [(t/triple alice :edge bob)
                    (t/triple bob :edge carol)
                    (t/triple carol :edge (t/triple :person :key "dora"))]
      path-rules
      [(rule "path" [(v "from") (v "to")]
             [(rel "triple" [(v "from") (c :edge) (v "to")])])
       (rule "path" [(v "from") (v "to")]
             [(rel "triple" [(v "from") (c :edge) (v "via")])
              (rel "path" [(v "via") (v "to")])])]
      query-result
      (result! propositions
              (aggregate-plan "path" [0]
                              [(aggregate :count-distinct 1)] path-rules))]
  (check! "aggregate composes with recursive closure"
          (= #{[alice 3] [bob 2] [carol 1]} (set (rows query-result)))))

(let [empty-rule
      (rule "missing" [(v "person")]
            [(rel "triple" [(v "person") (c :absent) (v "value")])])
      query-result
      (result! scores
              (aggregate-plan "missing" [] [(aggregate :count nil)] [empty-rule]))]
  (check! "empty input produces no aggregate row"
          (and (q/result-ok? query-result) (empty? (rows query-result)))))

(let [query-result
      (result! scores
              (aggregate-plan "score" [] [(aggregate :count nil)] [score-rule]))]
  (check! "empty grouping creates one global group"
          (= [[4]] (rows query-result))))

(let [propositions [(t/triple alice :name "Alice")]
      name-rule
      (rule "name" [(v "person") (v "value")]
            [(rel "triple" [(v "person") (c :name) (v "value")])])
      query-result
      (result! propositions
              (aggregate-plan "name" [0] [(aggregate :sum 1)] [name-rule]))]
  (check! "nonnumeric aggregate input is a typed error"
          (contains? (codes query-result) :query-nonnumeric-aggregate)))

(check! "having filters after aggregation"
        (= [[bob 30]]
           (rows (result! scores
                         (aggregate-plan "score" [0] [(aggregate :sum 1)]
                                         [(having :ge 0 30)] [[score-rule]])))))
(check! "multiple having clauses are conjoined"
        (= [[bob 30]]
           (rows (result! scores
                         (aggregate-plan "score" [0] [(aggregate :sum 1)]
                                         [(having :gt 0 8) (having :le 0 30)]
                                         [[score-rule]])))))
(check! "having can remove every group"
        (empty? (rows (result! scores
                             (aggregate-plan "score" [0] [(aggregate :count nil)]
                                             [(having :gt 0 100)] [[score-rule]])))))

(let [done-rule
      (rule "done" [(v "person")]
            [(rel "triple" [(v "person") (c :state) (c :done)])])
      open-rule
      (rule "open" [(v "person")]
            [(rel "triple" [(v "person") (c :score) (v "score")])
             (neg "done" [(v "person")])])
      propositions (conj scores (t/triple bob :state :done))
      query-result
      (result! propositions
              (aggregate-plan "open" [] [(aggregate :count nil)]
                              [(having :eq 0 1)] [[done-rule] [open-rule]]))]
  (check! "aggregate and having compose with stratified negation"
          (= [[1]] (rows query-result))))

(let [unknown
      (aggregate-plan "unknown" [] [(aggregate :count nil)] [score-rule])
      base
      (aggregate-plan "triple" [] [(aggregate :count nil)] [score-rule])
      bad-group
      (aggregate-plan "score" [9] [(aggregate :count nil)] [score-rule])
      bad-op
      (aggregate-plan "score" [0] [(aggregate :median 1)] [score-rule])
      missing-arg
      (aggregate-plan "score" [0] [(aggregate :sum nil)] [score-rule])
      bad-arg
      (aggregate-plan "score" [0] [(aggregate :sum 9)] [score-rule])
      bad-having
      (aggregate-plan "score" [0] [(aggregate :count nil)]
                      [(having :gt 4 1)] [[score-rule]])]
  (check! "unknown aggregate relation is rejected"
          (contains? (codes (result! scores unknown)) :query-invalid-find))
  (check! "base relation cannot be an aggregate find target"
          (contains? (codes (result! scores base)) :query-invalid-find))
  (check! "group positions are range checked"
          (contains? (codes (result! scores bad-group)) :query-invalid-aggregate))
  (check! "aggregate operators are validated"
          (contains? (codes (result! scores bad-op)) :query-invalid-aggregate))
  (check! "numeric aggregate requires an argument"
          (contains? (codes (result! scores missing-arg)) :query-invalid-aggregate))
  (check! "aggregate argument is range checked"
          (contains? (codes (result! scores bad-arg)) :query-invalid-aggregate))
  (check! "having aggregate index is range checked"
          (contains? (codes (result! scores bad-having)) :query-invalid-having)))

(let [pair-rule
      (rule "pair" [(v "left") (v "right")]
            [(rel "triple" [(v "left") (v "slot-a") (v "value-a")])
             (rel "triple" [(v "right") (v "slot-b") (v "value-b")])])
      over-plan
      (aggregate-plan "pair" [0 1] [(aggregate :count nil)] [pair-rule])
      trimmed-plan
      (aggregate-plan "pair" [0 1] [(aggregate :count nil)]
                      [(having :gt 0 100)] [[pair-rule]])]
  (with-redefs [q/max-results 1]
    (let [over (result! scores over-plan)
          trimmed (result! scores trimmed-plan)]
      (check! "aggregate limit reports cardinality and maximum"
              (and (contains? (codes over) :query-result-limit)
                   (> (q/result-over-limit over) (q/result-maximum over))))
      (check! "limit is applied after having"
              (and (q/result-ok? trimmed) (empty? (rows trimmed)))))))

(let [aggregate-query
      (aggregate-plan "score" [0] [(aggregate :count nil)] [score-rule])
      page (q/run-page! scores aggregate-query 10 nil)]
  (check! "aggregate results are explicitly not pageable"
          (= :query-aggregate-not-pageable
             (q/error-code (first (q/page-errors page))))))

(doseq [[label passed] @checks]
  (println (if passed "PASS" "FAIL") "-" label))
(when-not (every? second @checks)
  (throw (ex-info "aggregate query test failed" {:checks @checks})))
(println "aggregate query checks:" (count @checks) "passed")
