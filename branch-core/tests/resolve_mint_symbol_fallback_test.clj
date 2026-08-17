(require '[resolve-ident :as ri]
         '[resolve-mint :as rmi]
         '[resolve-read :as rr]
         '[resolve-render :as rv]
         '[resolve-corpus :as rco])

(def failures (atom 0))

(defn- check! [label expected actual]
  (let [ok? (= expected actual)]
    (println (if ok? "PASS" "FAIL") label)
    (when-not ok?
      (println "  expected:" (pr-str expected))
      (println "  actual:  " (pr-str actual))
      (swap! failures inc))))

;; A predicate is its spelling Term and a node is a minted coordinate, so the
;; projection's integers come from ri/ordinal! — view coordinates, not identity.
(def ctx (ri/new-graph! "resolve-mint-symbol-fallback-test"))
(def KIND "kind")
(def Vp "v")
(def BOUND "bound_to")
(def REFERS "refers_to")
(def FIXED "keep_spelling")
(def QUALIFIER "qualifier")
(def NAME "name")
(def ents (atom {}))
(def mint (rmi/->Mint ctx KIND Vp ents nil BOUND REFERS FIXED))

(defn- symbol! [spelling]
  (let [b (ri/open ctx)
        e (ri/mint! ctx b)]
    (ri/assert-on! b e KIND "symbol")
    (let [v-occ (ri/assert-on! b e Vp spelling)]
      (ri/commit! ctx b)
      [e v-occ])))

(defn- node! []
  (let [b (ri/open ctx) e (ri/mint! ctx b)]
    (ri/assert-on! b e KIND "symbol")
    (ri/commit! ctx b)
    e))

(def emit
  (rmi/->Emit ctx nil BOUND REFERS FIXED {} identity identity #{} #{}))
(def emit-line! (ns-resolve 'resolve-mint 'emit-line!))
(def structural-reader-rows
  (ns-resolve 'resolve-corpus 'structural-reader-rows))

(let [leaf (rmi/mint-datum! mint "runtime" 'posix/getenv)
      name-cid (first (ri/by-subject-predicate ctx leaf NAME))
      external-target (node!)]
  (ri/assert! ctx leaf REFERS external-target)
  (check! "qualified mint has no compound v fact"
          []
          (ri/by-subject-predicate ctx leaf Vp))
  (check! "qualified mint stores the authored qualifier"
          "posix"
          (rr/pred-val ctx nil leaf QUALIFIER))
  (check! "qualified mint stores the leaf name"
          "getenv"
          (rr/pred-val ctx nil leaf NAME))
  (check! "unresolved external target renders from structural facts"
          "posix/getenv"
          (rv/render-sym ctx nil BOUND REFERS FIXED leaf))
  (check! "projection joins structural facts only at its render boundary"
          (str "[" (ri/ordinal! ctx leaf) " \"v\" \"posix/getenv\"]")
          (emit-line! emit nil leaf name-cid)))

(let [leaf (rmi/mint-datum! mint "runtime" 'posix/getenv)
      name-cid (first (ri/by-subject-predicate ctx leaf NAME))
      [binding _] (symbol! "renamed-name")]
  (ri/assert! ctx leaf REFERS binding)
  (check! "resolved structural reference projects its renamed leaf"
          (str "[" (ri/ordinal! ctx leaf) " \"v\" \"posix/renamed-name\"]")
          (emit-line! emit nil leaf name-cid)))

(let [binding (node!)
      xresolve (rco/make-xresolve
                ctx nil {} {"posix" {"getenv" binding}} {} {} "runtime")]
  (check! "cross-module resolution consumes qualifier and leaf separately"
          binding
          (:target (xresolve "posix" "getenv"))))

(check! "reader-fact ingress lowers qualification once"
        [[1 "kind" "symbol"]
         [1 "qualifier" "posix"]
         [1 "name" "getenv"]
         [2 "kind" "symbol"]
         [2 "v" "plain"]]
        (structural-reader-rows
         [[1 "kind" "symbol"]
          [1 "v" "posix/getenv"]
          [2 "kind" "symbol"]
          [2 "v" "plain"]]))

;; A projection integer is a view coordinate, never a node identity.
(let [[leaf _] (symbol! "shape-probe")]
  (check! "a minted identity is a Term, and the ordinal that projects it is not"
          [true false]
          [(ri/minted-node-id? leaf) (ri/minted-node-id? (ri/ordinal! ctx leaf))]))

(println (str "resolve-mint symbol fallback: " (if (zero? @failures) "PASS" "FAIL")))
(when (pos? @failures)
  (System/exit 1))
