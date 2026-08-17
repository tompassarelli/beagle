(require '[resolve-ident :as ri]
         '[resolve-mint :as rmi])

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

(let [[leaf v-cid] (symbol! "posix/getenv")
      external-target (node!)]
  (ri/assert! ctx leaf REFERS external-target)
  (ri/assert! ctx leaf QUALIFIER "must-not-prefix")
  (check! "unresolved external target preserves the quoted leaf spelling"
          (str "[" (ri/ordinal! ctx leaf) " \"v\" \"posix/getenv\"]")
          (emit-line! emit nil leaf v-cid)))

(let [[leaf v-cid] (symbol! "old-name")
      [binding _] (symbol! "renamed-name")]
  (ri/assert! ctx leaf REFERS binding)
  (check! "resolved binding identity still projects its renamed spelling"
          (str "[" (ri/ordinal! ctx leaf) " \"v\" \"renamed-name\"]")
          (emit-line! emit nil leaf v-cid)))

;; A projection integer is a view coordinate, never a node identity.
(let [[leaf _] (symbol! "shape-probe")]
  (check! "a minted identity is a Term, and the ordinal that projects it is not"
          [true false]
          [(ri/minted-node-id? leaf) (ri/minted-node-id? (ri/ordinal! ctx leaf))]))

(println (str "resolve-mint symbol fallback: " (if (zero? @failures) "PASS" "FAIL")))
(when (pos? @failures)
  (System/exit 1))
