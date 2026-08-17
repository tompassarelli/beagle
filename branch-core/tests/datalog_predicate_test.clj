;; Comparison literals filter substitutions over recursive Terms. Equality is
;; structural; ordering is numeric; no comparison literal creates a binding.
(require '[fram.datalog :as d]
         '[fram.query :as q]
         '[fram.types :as t])

(def checks (atom []))
(defn check! [label value] (swap! checks conj [label (boolean value)]))
(defn v [name] (d/variable name))
(defn c [value] (d/constant value))
(defn rel [name arguments] (d/relation-literal name arguments))
(defn cmp [operator arguments] (d/comparison-literal operator arguments))
(defn rule [name head body] (d/rule name head body))
(defn plan [name rules] (q/query-plan (q/relation-find name) [rules]))
(defn result-set [propositions query-plan]
  (set (q/result-rows (q/run! propositions query-plan))))
(defn error-codes [query-plan]
  (set (map q/error-code (q/compile-errors (q/compile-query! query-plan)))))

(let [propositions [(t/triple "a" :count 150)
                    (t/triple "b" :count 50)
                    (t/triple "c" :count 200)]
      big (rule "big" [(v "x")]
                [(rel "triple" [(v "x") (c :count) (v "n")])
                 (cmp :gt [(v "n") (c 100)])])
      small (rule "small" [(v "x")]
                  [(rel "triple" [(v "x") (c :count) (v "n")])
                   (cmp :lt [(v "n") (c 100)])])]
  (check! ":gt keeps numeric Terms above the boundary"
          (= #{["a"] ["c"]} (result-set propositions (plan "big" [big]))))
  (check! ":lt keeps numeric Terms below the boundary"
          (= #{["b"]} (result-set propositions (plan "small" [small])))))

(let [alice (t/triple :person :key "alice")
      bob (t/triple :person :key "bob")
      propositions [(t/triple alice :related bob)
                    (t/triple alice :related alice)
                    (t/triple bob :related alice)]
      distinct-rule
      (rule "distinct" [(v "x") (v "y")]
            [(rel "triple" [(v "x") (c :related) (v "y")])
             (cmp :ne [(v "x") (v "y")])])
      same-rule
      (rule "same" [(v "x")]
            [(rel "triple" [(v "x") (c :related) (v "y")])
             (cmp :eq [(v "x") (v "y")])])]
  (check! ":ne compares recursive Terms structurally"
          (= #{[alice bob] [bob alice]}
             (result-set propositions (plan "distinct" [distinct-rule]))))
  (check! ":eq compares recursive Terms structurally"
          (= #{[alice]} (result-set propositions (plan "same" [same-rule])))))

(let [propositions [(t/triple "n1" :edge "n2")
                    (t/triple "n2" :edge "n3")
                    (t/triple "n3" :edge "n1")]
      rules
      [(rule "reach" [(v "x") (v "y")]
             [(rel "triple" [(v "x") (c :edge) (v "y")])])
       (rule "reach" [(v "x") (v "z")]
             [(rel "triple" [(v "x") (c :edge) (v "y")])
              (rel "reach" [(v "y") (v "z")])
              (cmp :ne [(v "x") (v "z")])])]
      found (result-set propositions (plan "reach" rules))]
  (check! "comparison inside recursion terminates"
          (= 6 (count found)))
  (check! "comparison inside recursion removes self-reach"
          (every? (fn [[left right]] (not= left right)) found)))

(let [propositions [(t/triple "bad" :count "not-a-number")
                    (t/triple "good" :count 150)]
      big (rule "big" [(v "x")]
                [(rel "triple" [(v "x") (c :count) (v "n")])
                 (cmp :ge [(v "n") (c 100)])])
      result (q/run! propositions (plan "big" [big]))]
  (check! "nonnumeric ordering operand drops only that row"
          (and (q/result-ok? result)
               (= [["good"]] (q/result-rows result)))))

(let [base-body [(rel "triple" [(v "x") (c :edge) (v "y")])]
      unbound
      (plan "r" [(rule "r" [(v "x")]
                            (conj base-body (cmp :gt [(v "z") (c 5)])))])
      bad-op
      (plan "r" [(rule "r" [(v "x")]
                            (conj base-body (cmp :unsupported [(v "x") (v "y")])))])
      wrong-arity
      (plan "r" [(rule "r" [(v "x")]
                            (conj base-body (cmp :gt [(v "x")])))])
      head-only
      (plan "r" [(rule "r" [(v "z")]
                            (conj base-body (cmp :eq [(v "x") (v "y")])))])]
  (check! "unbound comparison input is rejected"
          (contains? (error-codes unbound) :query-unbound-variable))
  (check! "unsupported comparison operator is rejected"
          (contains? (error-codes bad-op) :query-invalid-comparison))
  (check! "comparison arity is validated"
          (contains? (error-codes wrong-arity) :query-arity))
  (check! "comparison cannot supply a head binding"
          (contains? (error-codes head-only) :query-unbound-variable)))

(doseq [[label passed] @checks]
  (println (if passed "PASS" "FAIL") "-" label))
(when-not (every? second @checks)
  (throw (ex-info "comparison query test failed" {:checks @checks})))
(println "comparison query checks:" (count @checks) "passed")
