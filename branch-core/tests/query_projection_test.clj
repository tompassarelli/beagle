;; Shared projections, deterministic row order, canonical cursors, typed page
;; errors, and bounded evaluation over recursive-Term data.
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
(defn plan [name strata] (q/query-plan (q/relation-find name) strata))
(defn result-codes [result]
  (set (map q/error-code (q/result-errors result))))
(defn page-codes [page]
  (set (map q/error-code (q/page-errors page))))

(def recipient (t/triple :person :key "me"))
(defn message [prefix index] (t/triple :message :key (str prefix index)))
(def propositions
  (vec
   (concat
    (mapcat (fn [index]
              (let [value (message "direct-" index)]
                [(t/triple value :to recipient)
                 (t/triple value :from (t/triple :person :key (str "sender-" (mod index 5))))
                 (t/triple value :body (str "hello " index))]))
            (range 30))
    (map (fn [index] (t/triple (message "direct-" index) :acked-by recipient))
         (range 5))
    (map (fn [index] (t/triple (message "direct-" index) :rejected-by recipient))
         (range 5 8))
    (mapcat (fn [index]
              (let [value (message "broadcast-" index)]
                [(t/triple value :to :everyone)
                 (t/triple value :broadcast-to recipient)]))
            (range 6))
    [(t/triple (message "broadcast-" 2) :rejected-by recipient)]
    (mapcat (fn [index]
              [(t/triple (message "noise-" index) :to (t/triple :person :key "other"))
               (t/triple (t/triple :thread :key index) :kind :thread)])
            (range 20)))))

(def pending-plan
  (plan
   "pending"
   [[(rule "candidate" [(v "message")]
           [(rel "triple" [(v "message") (c :to) (c recipient)])])
     (rule "candidate" [(v "message")]
           [(rel "triple" [(v "message") (c :broadcast-to) (c recipient)])
            (rel "triple" [(v "message") (c :to) (c :everyone)])])
     (rule "acknowledged" [(v "message")]
           [(rel "triple" [(v "message") (c :acked-by) (c recipient)])])
     (rule "rejected" [(v "message")]
           [(rel "triple" [(v "message") (c :rejected-by) (c recipient)])])]
    [(rule "pending" [(v "message")]
           [(rel "candidate" [(v "message")])
            (neg "acknowledged" [(v "message")])
            (neg "rejected" [(v "message")])])]]))

(def expected
  (set (concat (map (fn [index] [(message "direct-" index)]) (range 8 30))
               (map (fn [index] [(message "broadcast-" index)])
                    (remove #{2} (range 6))))))

(def projection (q/project! propositions))
(let [one-shot (q/run! propositions pending-plan)
      projected (q/run-projected! projection pending-plan)]
  (check! "shared projection equals one-shot evaluation"
          (= (q/result-rows one-shot) (q/result-rows projected)))
  (check! "projection returns the expected recursive Term rows"
          (= expected (set (q/result-rows projected))))
  (check! "result order is deterministic across input order"
          (= (q/result-rows one-shot)
             (q/result-rows (q/run! (vec (reverse propositions)) pending-plan)))))

(let [before (q/projection-edb projection)
      _ (q/run-projected! projection pending-plan)
      _ (q/run-page-projected! projection pending-plan 4 nil)]
  (check! "projection is immutable across reuse"
          (= before (q/projection-edb projection))))

(defn drain [projection-value limit]
  (loop [after nil accumulated []]
    (let [page (q/run-page-projected! projection-value pending-plan limit after)]
      (when-not (q/page-ok? page)
        (throw (ex-info "page drain failed" {:errors (q/page-errors page)})))
      (let [next-rows (into accumulated (q/page-rows page))]
        (if (q/page-more? page)
          (recur (q/page-next page) next-rows)
          next-rows)))))

(let [small-pages (drain projection 3)
      large-pages (drain projection 50)
      reversed-pages (drain (q/project! (vec (reverse propositions))) 7)]
  (check! "page drains lose and duplicate no rows"
          (and (= expected (set small-pages))
               (= (count small-pages) (count (set small-pages)))))
  (check! "page-size changes preserve the exact ordered result"
          (= small-pages large-pages))
  (check! "input order changes preserve the exact paged result"
          (= small-pages reversed-pages)))

(let [one-shot (q/run-page! propositions pending-plan 5 nil)
      projected (q/run-page-projected! projection pending-plan 5 nil)
      reversed (q/run-page! (vec (reverse propositions)) pending-plan 5 nil)]
  (check! "one-shot and projected page rows agree"
          (= (q/page-rows one-shot) (q/page-rows projected)))
  (check! "canonical first-page cursor is projection independent"
          (= (q/page-next one-shot)
             (q/page-next projected)
             (q/page-next reversed))))

(doseq [[label page expected-code]
        [["zero page limit is a typed error"
          (q/run-page! propositions pending-plan 0 nil) :query-page-limit]
         ["oversized page limit is a typed error"
          (q/run-page! propositions pending-plan (inc q/max-page-limit) nil) :query-page-limit]
         ["nonnumeric cursor is a typed error"
          (q/run-page! propositions pending-plan 5 7) :query-page-cursor]
         ["noncanonical cursor is a typed error"
          (q/run-page! propositions pending-plan 5 "not-a-fram-cursor") :query-page-cursor]]]
  (check! label (contains? (page-codes page) expected-code)))

(with-redefs [q/max-page-payload-bytes 8]
  (let [page (q/run-page! propositions pending-plan 1 nil)]
    (check! "row exceeding the bounded response is a typed error"
            (contains? (page-codes page) :query-page-row-too-large))))

(with-redefs [q/max-results 2]
  (let [limited (q/run! propositions pending-plan)]
    (check! "plain result limit reports a typed error"
            (and (contains? (result-codes limited) :query-result-limit)
                 (> (q/result-over-limit limited) (q/result-maximum limited))))))

(let [control (d/query-control 1 60000)
      stopped (binding [q/*query-control* control]
                (q/run-projected! projection pending-plan))]
  (check! "step budget aborts with query-work-limit"
          (contains? (result-codes stopped) :query-work-limit))
  (check! "step counter records consumed work" (> (d/query-steps control) 1)))

(let [control (d/query-control 1000000 0)
      stopped (binding [q/*query-control* control]
                (q/run-projected! projection pending-plan))]
  (check! "deadline aborts with query-time-limit"
          (contains? (result-codes stopped) :query-time-limit)))

(let [control (d/query-control 1000000 60000)
      _ (d/cancel-query! control :operator-request)
      stopped (binding [q/*query-control* control]
                (q/run-projected! projection pending-plan))]
  (check! "explicit cancellation aborts with query-cancelled"
          (contains? (result-codes stopped) :query-cancelled)))

(let [syntax-form
      {:find "direct"
       :rules [{:head {:rel "direct" :args [{:var "message"}]}
                :body [{:rel "triple" :args [{:var "message"} :to recipient]}]}]}
      compiled (q/compile-query! syntax-form)
      syntax-result (q/run-syntax! propositions syntax-form)]
  (check! "syntax adapter produces typed QueryPlan"
          (and (q/compile-ok? compiled)
               (q/query-plan? (q/compiled-plan compiled))))
  (check! "syntax adapter returns typed QueryResult"
          (and (q/result-ok? syntax-result)
               (= 30 (count (q/result-rows syntax-result))))))

(let [unknown-plan
      (plan "output"
            [[(rule "output" [(v "value")]
                    [(rel "unknown" [(v "value")])])]])
      result (q/run! propositions unknown-plan)]
  (check! "validation failures remain typed QueryErrors"
          (and (not (q/result-ok? result))
               (= :query-unknown-relation
                  (q/error-code (first (q/result-errors result)))))))

(let [inconsistent
      (plan "output"
            [[(rule "output" [(v "message")]
                    [(rel "triple" [(v "message") (c :to) (v "target")])])
              (rule "output" [(v "message") (v "target")]
                    [(rel "triple" [(v "message") (c :to) (v "target")])])]])
      forward
      (plan "output"
            [[(rule "output" [(v "message")]
                    [(rel "later" [(v "message")])])]
             [(rule "later" [(v "message")]
                    [(rel "triple" [(v "message") (c :to) (v "target")])])]])
      unstratified
      (plan "looping"
            [[(rule "looping" [(v "message")]
                    [(rel "triple" [(v "message") (c :to) (v "target")])
                     (neg "looping" [(v "message")])])]])
      shadow
      (plan "output"
            [[(rule "triple" [(v "left") (v "middle") (v "right")]
                    [(rel "triple" [(v "left") (v "middle") (v "right")])])
              (rule "output" [(v "left")]
                    [(rel "triple" [(v "left") (v "middle") (v "right")])])]])]
  (check! "derived relation arity must be consistent"
          (contains? (result-codes (q/run! propositions inconsistent)) :query-arity))
  (check! "later-stratum positive reference is rejected"
          (contains? (result-codes (q/run! propositions forward)) :query-forward-reference))
  (check! "negation of a same-stratum relation is rejected"
          (contains? (result-codes (q/run! propositions unstratified)) :query-stratification))
  (check! "rules cannot redefine a base relation"
          (contains? (result-codes (q/run! propositions shadow)) :query-base-shadow)))

(doseq [[label passed] @checks]
  (println (if passed "PASS" "FAIL") "-" label))
(when-not (every? second @checks)
  (throw (ex-info "projection query test failed" {:checks @checks})))
(println "projection query checks:" (count @checks) "passed")
