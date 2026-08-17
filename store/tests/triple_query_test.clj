;; Recursive Term query core: typed plans, slot-neutral matching, explicit
;; occurrence history, stratified negation, recursion, and stable paging.
(require '[store.datalog :as d]
         '[store.query :as q]
         '[store.store :as store]
         '[store.types :as t])

(def checks (atom []))
(defn check! [label value] (swap! checks conj [label (boolean value)]))
(defn v [name] (d/variable name))
(defn c [value] (d/constant value))
(defn rel [name arguments] (d/relation-literal name arguments))
(defn neg [name arguments] (d/negated-literal name arguments))
(defn rule [name head body] (d/rule name head body))
(defn plan [name strata] (q/query-plan (q/relation-find name) strata))
(defn rows [result] (set (q/result-rows result)))

(def node-a (t/triple :node :key "a"))
(def node-b (t/triple :node :key "b"))
(def node-c (t/triple :node :key "c"))
(def nested-t2 (t/triple :relation :key "label"))
(def edge-ab (t/triple node-a :edge node-b))
(def edge-bc (t/triple node-b :edge node-c))
(def nested-middle (t/triple "left" nested-t2 "right"))
(def nested-right (t/triple "container" :contains node-a))

(def term-store (store/new-term-store "msa-space"))
(store/commit-transaction!
 term-store
 [(store/assert-operation edge-ab)
  (store/assert-operation edge-bc)
  (store/assert-operation nested-middle)
  (store/assert-operation nested-right)])
(store/commit-transaction! term-store [(store/retract-operation nested-middle)])

(def live (store/live-propositions term-store))
(def occurrences (store/occurrences term-store))
(def withdrawals (store/withdrawals term-store))

(def slot-rules
  [(rule "slot-matches" [(c node-a) (v "s1") (v "s2")]
         [(rel "triple" [(c node-a) (v "s1") (v "s2")])])
   (rule "slot-matches" [(v "s0") (c nested-t2) (v "s2")]
         [(rel "triple" [(v "s0") (c nested-t2) (v "s2")])])
   (rule "slot-matches" [(v "s0") (v "s1") (c node-a)]
         [(rel "triple" [(v "s0") (v "s1") (c node-a)])])])
(def slot-plan (plan "slot-matches" [slot-rules]))

(let [compiled (q/compile-query! slot-plan)
      result (q/run! (conj live nested-middle) slot-plan)
      found (rows result)]
  (check! "typed plan compiles" (and (q/compile-ok? compiled)
                                      (q/query-plan? (q/compiled-plan compiled))))
  (check! "recursive constant matches t1" (contains? found [node-a :edge node-b]))
  (check! "recursive constant matches t2" (contains? found ["left" nested-t2 "right"]))
  (check! "recursive constant matches t3" (contains? found ["container" :contains node-a])))

(def closure-rules
  [(rule "reaches" [(v "from") (v "to")]
         [(rel "triple" [(v "from") (c :edge) (v "to")])])
   (rule "reaches" [(v "from") (v "to")]
         [(rel "triple" [(v "from") (c :edge) (v "via")])
          (rel "reaches" [(v "via") (v "to")])])])
(def closure-plan (plan "reaches" [closure-rules]))

(check! "recursive rule keeps recursive terms as values"
        (contains? (rows (q/run! live closure-plan)) [node-a node-c]))

(def negation-plan
  (plan "terminal"
        [[(rule "outgoing" [(v "node")]
                [(rel "triple" [(v "node") (c :edge) (v "next")])])]
         [(rule "terminal" [(v "node")]
                [(rel "triple" [(v "prior") (c :edge) (v "node")])
                 (neg "outgoing" [(v "node")])])]]))

(check! "stratified negation keeps recursive Term equality"
        (= #{[node-c]} (rows (q/run! live negation-plan))))

(def occurrence-plan
  (plan "events"
        [[(rule "events" [(v "where") (v "action") (v "value")]
                [(rel "occurrence" [(v "where") (v "action") (v "value")])])]]))

(def withdrawal-plan
  (plan "withdrawals"
        [[(rule "withdrawals" [(v "retraction") (v "assertion")]
                [(rel "withdrawal" [(v "retraction") (v "assertion")])])]]))

(let [without-history (q/run! live occurrence-plan)
      without-withdrawals (q/run! live withdrawal-plan)
      with-history (q/run-plan-projected!
                    (q/project-with-history! live occurrences withdrawals)
                    occurrence-plan)
      withdrawal-result
      (q/run-plan-projected!
       (q/project-with-history! live occurrences withdrawals)
       withdrawal-plan)
      found (rows with-history)
      tx1 (t/transaction-coordinate "msa-space" 1)
      tx2 (t/transaction-coordinate "msa-space" 2)]
  (check! "ordinary projection does not expose occurrence history"
          (and (q/result-ok? without-history)
               (empty? (q/result-rows without-history))
               (q/result-ok? without-withdrawals)
               (empty? (q/result-rows without-withdrawals))))
  (check! "assert occurrence has exact coordinate"
          (contains? found [(t/occurrence-coordinate tx1 0) :assert edge-ab]))
  (check! "retract occurrence has exact coordinate"
          (contains? found
                     [(t/occurrence-coordinate tx2 0) :retract nested-middle]))
  (check! "history relation contains every operation occurrence"
          (= (count occurrences) (count found)))
  (check! "withdrawal is a separate system relation over exact occurrences"
          (= #{[(t/occurrence-coordinate tx2 0)
                (t/occurrence-coordinate tx1 2)]}
             (rows withdrawal-result))))

(def all-live-plan
  (plan "all-live"
        [[(rule "all-live" [(v "a") (v "b") (v "c")]
                [(rel "triple" [(v "a") (v "b") (v "c")])])]]))

(let [ranked [(t/triple "c" :score 3)
              (t/triple "a" :score 10)
              (t/triple "b" :score 10)
              (t/triple "d" :score 2)]
      ranked-rules
      [[(rule "ranked" [(v "entity") (v "score")]
              [(rel "triple" [(v "entity") (c :score) (v "score")])])]]
      ranked-plan
      (q/ordered-query-plan
       (q/relation-find "ranked") ranked-rules
       [(q/order-clause 1 :desc) (q/order-clause 0 :asc)] 2)
      result (q/run! ranked ranked-plan)]
  (check! "ordered query applies natural numeric order, stable ties, and top-K"
          (= [["a" 10] ["b" 10]] (q/result-rows result))))

(let [lower Long/MIN_VALUE
      higher (inc lower)
      ranked [(t/triple "lower" :score lower)
              (t/triple "higher" :score higher)]
      ranked-rules
      [[(rule "ranked-i64" [(v "entity") (v "score")]
              [(rel "triple" [(v "entity") (c :score) (v "score")])])]]
      ranked-plan
      (q/ordered-query-plan
       (q/relation-find "ranked-i64") ranked-rules
       [(q/order-clause 1 :asc)] nil)
      result (q/run! ranked ranked-plan)]
  (check! "ordered query preserves exact adjacent i64 order"
          (= [["lower" lower] ["higher" higher]]
             (q/result-rows result))))

(let [lower Long/MIN_VALUE
      higher (inc lower)
      branch-cases
      [[false true -1]
       [true false 1]
       [lower higher -1]
       [higher lower 1]
       [1.5 2.5 -1]
       [-0.0 0.0 0]
       [##NaN 1.0 0]
       [1.0 ##NaN 0]
       ["a" "b" -1]
       [:a :b -1]
       [(t/instant 4 999999999) (t/instant 5 0) -1]
       [(t/instant 5 1) (t/instant 5 2) -1]
       [(t/triple "a" :edge 1) (t/triple "a" :edge 2) -1]
       [false 0 -1]
       [0 "a" -1]
       ["a" :a -1]]]
  (check! "natural Term comparison covers every scalar, recursive, and rank branch"
          (every? (fn [[left right expected]]
                    (= expected (Long/signum (long (q/term-compare left right)))))
                  branch-cases)))

(let [size 1024
      rows (mapv vector (range (dec size) -1 -1))
      ordered-plan
      (q/ordered-query-plan
       (q/relation-find "complexity") [] [(q/order-clause 0 :asc)] nil)
      comparisons (atom 0)
      original-compare q/term-compare
      ordered
      (with-redefs [q/term-compare
                    (fn [left right]
                      (swap! comparisons inc)
                      (original-compare left right))]
        (q/ordered-plan-rows ordered-plan rows))]
  (check! "ordered query uses an n-log-n comparison budget"
          (and (= (mapv vector (range size)) ordered)
               (<= @comparisons 10240))))

(loop [after nil collected []]
  (let [page (q/run-page! live all-live-plan 1 after)
        collected2 (vec (concat collected (q/page-rows page)))]
    (if (q/page-more? page)
      (recur (q/page-next page) collected2)
      (check! "paging drains recursive Term rows without loss or duplication"
              (and (q/page-ok? page)
                   (= (set collected2)
                      (set (map (fn [value]
                                  [(t/triple-t1 value)
                                   (t/triple-t2 value)
                                   (t/triple-t3 value)])
                                live))))))))

(doseq [[label passed] @checks]
  (println (if passed "PASS" "FAIL") "-" label))

(when-not (every? second @checks)
  (throw (ex-info "triple query test failed" {:checks @checks})))

(println "triple query checks:" (count @checks) "passed")
