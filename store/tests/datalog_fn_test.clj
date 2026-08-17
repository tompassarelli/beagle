;; Arithmetic builtins consume grounded Terms and bind a typed numeric Term.
;; Failed arithmetic drops a substitution; recursive heads cannot contain a
;; value-producing builtin because that can create an unbounded relation.
(require '[store.datalog :as d]
         '[store.query :as q]
         '[store.types :as t])

(def checks (atom []))
(defn check! [label value] (swap! checks conj [label (boolean value)]))
(defn v [name] (d/variable name))
(defn c [value] (d/constant value))
(defn rel [name arguments] (d/relation-literal name arguments))
(defn builtin [operator arguments binding]
  (d/builtin-literal operator arguments binding))
(defn rule [name head body] (d/rule name head body))
(defn plan [name rules] (q/query-plan (q/relation-find name) [rules]))
(defn result-set [propositions query-plan]
  (set (q/result-rows (q/run! propositions query-plan))))
(defn error-codes [query-plan]
  (set (map q/error-code (q/compile-errors (q/compile-query! query-plan)))))

(def entity (t/triple :entity :key "a"))
(defn arithmetic-rule [operator]
  (rule "calculated" [(v "entity") (v "answer")]
        [(rel "triple" [(v "entity") (c :left) (v "left")])
         (rel "triple" [(v "entity") (c :right) (v "right")])
         (builtin operator [(v "left") (v "right")] "answer")]))
(defn calculate [propositions operator]
  (result-set propositions (plan "calculated" [(arithmetic-rule operator)])))

(def five-three [(t/triple entity :left 5) (t/triple entity :right 3)])
(check! ":+ binds an Int Term" (= #{[entity 8]} (calculate five-three :+)))
(check! "subtraction binds an Int Term"
        (= #{[entity 2]} (calculate five-three d/subtract-operator)))
(check! ":* binds an Int Term" (= #{[entity 15]} (calculate five-three :*)))
(check! ":mod binds an Int Term" (= #{[entity 2]} (calculate five-three :mod)))
(check! ":/ binds a Double Term"
        (= #{[entity (/ 5.0 3.0)]} (calculate five-three :/)))

(let [other (t/triple :entity :key "b")
      propositions [(t/triple entity :left 6)
                    (t/triple entity :right 2)
                    (t/triple other :left 7)
                    (t/triple other :right 2)]]
  (check! "division remains Double for exact and fractional quotients"
          (= #{[entity 3.0] [other 3.5]} (calculate propositions :/))))

(let [propositions [(t/triple entity :left 1.5)
                    (t/triple entity :right 2)]]
  (check! "mixed numeric inputs produce a Double"
          (= #{[entity 3.5]} (calculate propositions :+))))

(doseq [[label propositions operator]
        [["division by zero drops the row"
          [(t/triple entity :left 5) (t/triple entity :right 0)] :/]
         ["modulus by zero drops the row"
          [(t/triple entity :left 5) (t/triple entity :right 0)] :mod]
         ["fractional modulus drops the row"
          [(t/triple entity :left 5.5) (t/triple entity :right 2)] :mod]
         ["nonnumeric input drops the row"
          [(t/triple entity :left "no") (t/triple entity :right 2)] :+]]]
  (check! label (empty? (calculate propositions operator))))

(let [rule-value
      (rule "calculated" [(v "entity") (v "answer")]
            [(rel "triple" [(v "entity") (c :left) (v "left")])
             (rel "triple" [(v "entity") (c :right) (v "right")])
             (builtin :+ [(v "left") (v "right")] "subtotal")
             (builtin :* [(v "subtotal") (c 2)] "answer")])]
  (check! "builtin bindings feed later builtins"
          (= #{[entity 16]} (result-set five-three (plan "calculated" [rule-value])))))

(let [base [(rel "triple" [(v "entity") (c :left) (v "left")])]
      unbound
      (plan "r" [(rule "r" [(v "entity") (v "answer")]
                            (conj base (builtin :+ [(v "missing") (c 1)] "answer")))])
      bad-op
      (plan "r" [(rule "r" [(v "entity") (v "answer")]
                            (conj base (builtin :power [(v "left") (c 2)] "answer")))])
      empty-binding
      (plan "r" [(rule "r" [(v "entity")]
                            (conj base (builtin :+ [(v "left") (c 1)] "")))])
      rebound
      (plan "r" [(rule "r" [(v "entity")]
                            (conj base (builtin :+ [(v "left") (c 1)] "entity")))])]
  (check! "unbound builtin input is rejected"
          (contains? (error-codes unbound) :query-unbound-variable))
  (check! "unsupported builtin operator is rejected"
          (contains? (error-codes bad-op) :query-invalid-builtin))
  (check! "empty builtin binding is rejected"
          (contains? (error-codes empty-binding) :query-invalid-builtin))
  (check! "builtin cannot overwrite an existing binding"
          (contains? (error-codes rebound) :query-unbound-variable)))

(let [recursive-rules
      [(rule "grow" [(v "entity") (v "n")]
             [(rel "triple" [(v "entity") (c :left) (v "n")])])
       (rule "grow" [(v "entity") (v "next")]
             [(rel "grow" [(v "entity") (v "n")])
              (builtin :+ [(v "n") (c 1)] "next")])]
      recursive-plan (plan "grow" recursive-rules)]
  (check! "builtin in a recursive relation is rejected"
          (contains? (error-codes recursive-plan) :query-recursive-builtin)))

(let [path-rules
      [(rule "path" [(v "from") (v "to")]
             [(rel "triple" [(v "from") (c :edge) (v "to")])])
       (rule "path" [(v "from") (v "to")]
             [(rel "triple" [(v "from") (c :edge) (v "via")])
              (rel "path" [(v "via") (v "to")])])
       (rule "scored" [(v "from") (v "to") (v "score")]
             [(rel "path" [(v "from") (v "to")])
              (builtin :+ [(c 1) (c 2)] "score")])]
      propositions [(t/triple entity :edge (t/triple :entity :key "b"))]
      result (q/run! propositions (plan "scored" path-rules))]
  (check! "nonrecursive projection may calculate over recursive output"
          (and (q/result-ok? result)
               (= 3 (last (first (q/result-rows result)))))))

(doseq [[label passed] @checks]
  (println (if passed "PASS" "FAIL") "-" label))
(when-not (every? second @checks)
  (throw (ex-info "builtin query test failed" {:checks @checks})))
(println "builtin query checks:" (count @checks) "passed")
