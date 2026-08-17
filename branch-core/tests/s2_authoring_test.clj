;; s2_authoring_test.clj — authoring with minted Term identities.
;;   bb -cp out tests/s2_authoring_test.clj
(require '[clojure.edn :as edn]
         '[clojure.string :as str]
         '[fram.store :as c]
         '[fram.types :as t]
         '[fram.txn :as txn]
         '[fram.rotation :as rot]
         '[fram.candidate-transformer :as candidate]
         '[resolve-read :as rr]
         '[resolve-corpus :as corpus]
         '[resolve-query :as query]
         '[resolve-verbs :as rvb]
         '[resolve :as resolve])

(def checks (atom []))
(defn check! [label ok] (swap! checks conj [label (boolean ok)]))

;; ----------------------------------------------------- direct authoring seam
(def store (c/new-term-store "s2-authoring"))
(def context (rr/context! store))
(def node-a (rr/mint! context))
(def node-b (rr/mint! context))
(def node-c (rr/mint! context))
(def predicate (t/triple "predicate-space" :predicate "edge"))

(rr/assert! context node-a predicate node-b)
(rr/assert! context node-c predicate node-a)
(rr/assert! context node-a "line" 42)

(check! "minted node identity is a Term transaction coordinate"
        (and (txn/mint-coordinate? node-a) (t/term? node-a) (not (int? node-a))))
(check! "two nodes minted by one builder have distinct Term identities"
        (and (not= node-a node-b)
             (= (t/triple-t1 node-a) (t/triple-t1 node-b))))
(check! "predicate identity accepts a non-Int Term"
        (= [node-b]
           (mapv rr/event-value
                 (rr/events-by-subject-predicate context node-a predicate))))
(check! "minted Term subjects remain readable"
        (= [node-a]
           (mapv rr/event-value
                 (rr/events-by-subject-predicate context node-c predicate))))
(check! "integer scalar values stay literal Terms"
        (= 42 (rr/pred-val context nil node-a "line")))
(check! "staged authoring is visible before commit"
        (= node-b (rr/pred-val context nil node-a predicate)))
(check! "staging does not mutate the real store"
        (and (zero? (c/transaction-count store))
             (zero? (c/operation-count store))))
(check! "one context owns the authoritative S1 builder"
        (= 3 (txn/operation-count (rr/builder context))))

(def coordinate (rr/commit! context))
(def committed-view (rot/project! store))
(check! "all staged operations commit atomically as one transaction"
        (and (t/transaction-coordinate? coordinate)
             (= 1 (c/transaction-count store))
             (= 3 (c/operation-count store))))
(check! "committed minted Term identities remain queryable"
        (= #{[node-a predicate node-b] [node-c predicate node-a] [node-a "line" 42]}
           (set (map (fn [event]
                       (let [p (rot/proposition-of event)]
                         [(t/triple-t1 p) (t/triple-t2 p) (t/triple-t3 p)]))
                     (rot/all-occurrences committed-view)))))

(rr/update-single! context node-a predicate 99)
(check! "single-cardinality update is visible in the staged rotation"
        (= [99]
           (mapv rr/event-value
                 (rr/events-by-subject-predicate context node-a predicate))))
(def transactions-before-update (c/transaction-count store))
(rr/commit! context)
(check! "the update compiler retires and asserts in one transaction"
        (and (= 1 (- (c/transaction-count store) transactions-before-update))
             (= [99]
                (rot/values (rot/by-t12 (rot/project! store) node-a predicate)))))

;; ---------------------------------------------- EDN boundary + verb + emit
(def input (java.io.File/createTempFile "fram-s2-authoring-" ".edn"))
(def output (java.io.File/createTempFile "fram-s2-projection-" ".edn"))
(def automatic-output-dir
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-s2-automatic-projection-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def automatic-output (java.io.File. automatic-output-dir "resolved-demo.edn"))
(.deleteOnExit input)
(.deleteOnExit output)
(.deleteOnExit automatic-output)
(.deleteOnExit automatic-output-dir)
(spit input
      (str "@file demo\n"
           "[1 \"kind\" \"list\"]\n"
           "[1 \"f0\" 2]\n"
           "[1 \"f1\" 3]\n"
           "[2 \"kind\" \"symbol\"]\n"
           "[2 \"v\" \"beagle-file\"]\n"
           "[3 \"kind\" \"list\"]\n"
           "[3 \"f0\" 4]\n"
           "[3 \"f1\" 5]\n"
           "[3 \"f2\" 6]\n"
           "[4 \"kind\" \"symbol\"]\n"
           "[4 \"v\" \"def\"]\n"
           "[5 \"kind\" \"symbol\"]\n"
           "[5 \"v\" \"base\"]\n"
           "[6 \"kind\" \"number\"]\n"
           "[6 \"v\" 42]\n"
           "[6 \"line\" 42]\n"))

(defn projection-rows [file]
  (mapv edn/read-string
        (filter #(str/starts-with? % "[")
                (str/split-lines (slurp file)))))

;; Exercise the actual non-capture verb emission before the later direct
;; extraction can satisfy any assertion accidentally. The explicit verb-env
;; output directory also proves that author emission closes over its caller's
;; scope instead of falling back to the module's global /tmp path.
(resolve/resolve-edn!
 [(.getAbsolutePath input)]
 (fn []
   (rvb/verb-upsert-form!
    (resolve/verb-env (.getAbsolutePath automatic-output-dir) nil)
    "demo"
    '(def automatic-emission 7))))
(check! "non-capture upsert automatically emits resolved EDN"
        (.isFile automatic-output))
(def automatic-projected-lines (projection-rows automatic-output))
(check! "automatic author emission preserves scalar v and line integers"
        (and (some #(= [(nth % 0) "v" 42] %) automatic-projected-lines)
             (some #(= [(nth % 0) "line" 42] %) automatic-projected-lines)))

(def captured-store (atom nil))
(def captured-entities (atom nil))
(def captured-name-node (atom nil))
(binding [resolve/*capture-only?* true]
  (resolve/resolve-edn!
   [(.getAbsolutePath input)]
   (fn []
     (let [entities (get @resolve/file->ents "demo")
           binding-node (resolve/def-binding "demo" "base")]
       (reset! captured-store resolve/ctx)
       (reset! captured-entities entities)
       (reset! captured-name-node binding-node)
       (check! "EDN local labels widen to minted Term nodes"
               (and (seq entities)
                    (every? txn/mint-coordinate? entities)
                    (every? (complement int?) entities)))
       (check! "EDN scalar integer is not re-keyed as a node"
               (= 42 (some #(resolve/pred-val % "line") entities)))
       (resolve/verb-rename! "base" "renamed" "demo")
       (check! "the rename verb updates the binding by Term identity"
               (= "renamed" (resolve/sym-val binding-node)))
       (resolve/verb-upsert-form! "demo" '(def extra-a 7))
       (resolve/verb-upsert-form! "demo" '(def extra-b 8))
       (let [wrapper (resolve/wrapper-of "demo")
             predicates (mapv rr/event-predicate
                              (rr/events-by-subject resolve/rctx wrapper))
             widened-keys (filterv #(and (string? %)
                                         (re-matches #"f[0-9.]+~t[A-Za-z0-9_-]+" %))
                                   predicates)]
         (check! "new order predicates encode the child Term identity"
                 (= 2 (count widened-keys)))
         (check! "distinct minted children cannot collide on one order predicate"
                 (= 2 (count (distinct widened-keys))))
         (check! "Term-tied wrapper edges are immediately readable in order"
                 (= 4 (count (resolve/wrap-forms wrapper)))))
       (resolve/extract-file! "demo" (.getAbsolutePath output))))))

(check! "the complete resolve+verb flow commits once"
        (= 1 (c/transaction-count @captured-store)))
(def projected-lines (projection-rows output))
(check! "later explicit extraction does not replace automatic-emission evidence"
        (= automatic-projected-lines (projection-rows automatic-output)))
(check! "projection remaps structural Term targets to local integer labels"
        (every? integer?
                (map #(nth % 2)
                     (filter #(re-matches #"f[0-9]+" (str (nth % 1)))
                             projected-lines))))
(check! "projection preserves scalar integers without node ambiguity"
        (and (some #(= [(nth % 0) "v" 42] %) projected-lines)
             (some #(= [(nth % 0) "line" 42] %) projected-lines)))
(check! "projection carries the authored spelling"
        (some #(= "renamed" (nth % 2)) projected-lines))

;; --------------------------------------------------------- widened queries
(check! "call-graph closure accepts arbitrary Term edge keys"
        (= {:b #{:a} :c #{:a :b}}
           (:blast (query/blast-closure! [[:a :b] [:b :c]]))))
(check! "dead-private query keeps identity-keyed reachability"
        (= #{:c}
           (query/dead-private-bindings!
            {:defn-meta {:a {} :b {} :c {}} :edges [[:a :b]]}
            {:a :public :b :private :c :private})))
(check! "structural predicate classification is role-based"
        (and (corpus/node-reference-predicate? "f12")
             (corpus/node-reference-predicate? "seg2")
             (not (corpus/node-reference-predicate? "line"))
             (not (corpus/node-reference-predicate? "v"))))
(def candidate-position-key
  (deref (ns-resolve 'fram.candidate-transformer 'position-key)))
(check! "candidate transformation orders Term-tied predicates"
        (= [[65536] [1 "tab_CD"]]
           (candidate-position-key "f65536~tab_CD")))

;; ------------------------------------------------------------------- report
(let [rows @checks
      fails (remove second rows)]
  (doseq [[label ok] rows] (println (if ok "  [PASS] " "  [FAIL] ") label))
  (if (empty? fails)
    (println "\nTerm authoring:" (count rows) "/" (count rows) "PASS")
    (do (println "\nTerm authoring:" (count fails) "FAILED") (System/exit 1))))
