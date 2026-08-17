;; Compiler-selected lexical identity ingress.
;; Run from store/: bb -cp out tests/compiler_lexical_edges_test.clj
(require '[resolve :as resolve]
         '[resolve-corpus :as corpus]
         '[resolve-ident :as ri]
         '[resolve-read :as rr]
         '[store.txn :as txn])

(def failures (atom []))

(defn- check! [label ok?]
  (println (if ok? "PASS" "FAIL") label)
  (when-not ok?
    (swap! failures conj label)))

(def fixture "tests/fixtures/compiler_lexical_edges.edn")

(defn- only [label xs]
  (let [values (vec xs)]
    (when-not (= 1 (count values))
      (throw (ex-info (str label " is not unique") {:values values})))
    (first values)))

(defn- entity-with [ctx ents predicate value]
  (only (str predicate "=" value)
        (filter #(= value (rr/pred-val ctx nil % predicate)) ents)))

(defn- targets [ctx entity predicate]
  (mapv #(ri/target-at ctx %)
        (ri/by-subject-predicate ctx entity predicate)))

(defn- target [ctx entity predicate]
  (only (str predicate " target") (targets ctx entity predicate)))

(def expected-targets
  {"outer-occurrence-owner" "fixture:outer-tmp"
   "inner-occurrence-owner" "fixture:inner-tmp"
   "x-occurrence-owner" "fixture:destructure-x"
   "y-occurrence-owner" "fixture:destructure-y"})

(defn- observed-targets [ctx ents]
  (into {}
        (map (fn [[owner-label expected-binding-id]]
               (let [owner (entity-with ctx ents "test-label" owner-label)
                     occurrence (target ctx owner "occurrenceIdent")
                     raw-target (target ctx occurrence "refersTo")
                     bound-target (target ctx occurrence "bound_to")
                     refers-target (target ctx occurrence "refers_to")]
                 [owner-label
                  {:expected expected-binding-id
                   :raw (rr/pred-val ctx nil raw-target "bindingId")
                   :bound (rr/pred-val ctx nil bound-target "bindingId")
                   :durable-refers (rr/pred-val ctx nil refers-target "bindingId")
                   :same-entity (= raw-target bound-target refers-target)}])))
        expected-targets))

(check! "compiler lexical predicates are local node references"
        (and (corpus/node-reference-predicate? "bindingIdent")
             (corpus/node-reference-predicate? "occurrenceIdent")
             (corpus/node-reference-predicate? "refersTo")
             (not (corpus/node-reference-predicate? "bindingId"))
             (not (corpus/node-reference-predicate? "name"))))

(def ctx (ri/new-graph! "compiler-lexical-edges-test"))
(def file-ents (atom {}))
(def src (corpus/load-edn! ctx file-ents fixture))
(def ents (get @file-ents src))
(def direct-observed (observed-targets ctx ents))

(check! "load maps each stable bindingId to the exact compiler binder entity"
        (every? (fn [[_ {:keys [expected raw bound durable-refers same-entity]}]]
                  (and same-entity
                       (= expected raw bound durable-refers)))
                direct-observed))

(let [outer (entity-with ctx ents "bindingId" "fixture:outer-tmp")
      inner (entity-with ctx ents "bindingId" "fixture:inner-tmp")]
  (check! "same-name shadowed binders remain distinct"
          (and (not= outer inner)
               (= "tmp" (rr/pred-val ctx nil outer "name"))
               (= "tmp" (rr/pred-val ctx nil inner "name")))))

(let [owner (entity-with ctx ents "test-label" "destructure-binding-owner")
      binders (targets ctx owner "bindingIdent")]
  (check! "one destructuring owner retains two distinct compiler binders"
          (and (= 2 (count binders))
               (= 2 (count (distinct binders)))
               (= #{"fixture:destructure-x" "fixture:destructure-y"}
                  (set (map #(rr/pred-val ctx nil % "bindingId") binders))))))

(check! "compiler owner links load as minted nodes rather than integer literals"
        (every? txn/mint-coordinate?
                (concat
                 (mapcat #(targets ctx % "bindingIdent") ents)
                 (mapcat #(targets ctx % "occurrenceIdent") ents)
                 (mapcat #(targets ctx % "refersTo") ents))))

(check! "stable bindingId values remain literal strings"
        (every? string?
                (keep #(rr/pred-val ctx nil % "bindingId") ents)))

(def post-run-observed (atom nil))
(resolve/resolve-edn!
 [fixture]
 (fn []
   (let [loaded (get @resolve/file->ents "compiler-lexical-edges")]
     (reset! post-run-observed (observed-targets resolve/rctx loaded)))))

(check! "legacy resolution preserves compiler-selected bound_to and refers_to"
        (= direct-observed @post-run-observed))

(if (empty? @failures)
  (println "compiler lexical edges: 7/7 PASS")
  (do
    (println "compiler lexical edges:" (count @failures) "FAILED")
    (System/exit 1)))
