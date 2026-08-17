(ns resolve-mint
  (:require [clojure.string :as str]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [resolve-read :as rr]
            [resolve-binds :as rb]
            [resolve-modules :as rm]
            [resolve-render :as rv]))

(def FN-RE (re-pattern "f\\d+"))

(defrecord Mint [ctx KIND Vp ents view BOUND REFERS FIXED])

(defn mint-ctx [r] (:ctx r))

(defn mint-KIND [r] (:KIND r))

(defn mint-Vp [r] (:Vp r))

(defn mint-ents [r] (:ents r))

(defn mint-view [r] (:view r))

(defn mint-BOUND [r] (:BOUND r))

(defn mint-REFERS [r] (:REFERS r))

(defn mint-FIXED [r] (:FIXED r))

(defrecord FnEdge [idx cid child])

(defn fnedge-idx [r] (:idx r))

(defn fnedge-cid [r] (:cid r))

(defn fnedge-child [r] (:child r))

(defn register! [^Mint m ^String src e]
  (let [ents (:ents m)]
  (do
  (swap! ents (fn [tbl] (assoc tbl src (conj (get tbl src []) e))))
  e)))

(defn- mint-leaf-on! [^Mint m builder ^String src kind v]
  (let [ctx (:ctx m)
   e (register! m src (ri/mint! ctx builder))]
  (do
  (ri/assert-on! builder e (:KIND m) (ri/literal! kind))
  (ri/assert-on! builder e (:Vp m) (ri/literal! v))
  e)))

(defn mint-leaf! [^Mint m ^String src kind v]
  (let [ctx (:ctx m)
   builder (ri/open ctx)
   e (mint-leaf-on! m builder src kind v)]
  (do
  (ri/commit! ctx builder)
  e)))

(defn- mint-symbol-on! [^Mint m builder ^String src d]
  (let [qualifier (namespace d)]
  (if (nil? qualifier) (mint-leaf-on! m builder src "symbol" (name d)) (let [ctx (:ctx m)
   e (register! m src (ri/mint! ctx builder))]
  (do
  (ri/assert-on! builder e (:KIND m) (ri/literal! "symbol"))
  (ri/assert-on! builder e "qualifier" (ri/literal! qualifier))
  (ri/assert-on! builder e "name" (ri/literal! (name d)))
  e)))))

(defn- clj-meta->beagle-meta [mt]
  (cond
  (and (= 1 (count mt)) (contains? mt :tag) (symbol? (:tag mt))) (:tag mt)
  (and (= 1 (count mt)) (true? (val (first mt)))) (key (first mt))
  :else mt))

(defn- reader-meta [d]
  (if (instance? clojure.lang.IObj d) (not-empty (apply dissoc (meta d) [:line :column :end-line :end-column :file])) nil))

(defn- mint-datum-on! [^Mint m builder ^String src d]
  (let [mt (reader-meta d)]
  (if (some? mt) (mint-datum-on! m builder src (list (symbol "#%meta") (clj-meta->beagle-meta mt) (with-meta d nil))) (let [reuse-node (rc/reuse-node-id d)]
  (if (some? reuse-node) reuse-node (cond
  (nil? d) (mint-leaf-on! m builder src "symbol" "nil")
  (symbol? d) (mint-symbol-on! m builder src d)
  (keyword? d) (mint-leaf-on! m builder src "symbol" (str d))
  (string? d) (mint-leaf-on! m builder src "string" d)
  (boolean? d) (mint-leaf-on! m builder src "symbol" (if d "true" "false"))
  (char? d) (mint-leaf-on! m builder src "char" (str d))
  (number? d) (mint-leaf-on! m builder src "number" (str d))
  (or (list? d) (seq? d) (vector? d) (map? d)) (let [ctx (:ctx m)
   head (cond
  (vector? d) [(symbol "#%brackets")]
  (map? d) [(symbol "#%map")]
  :else [])
   elems (vec (concat head (if (map? d) (apply concat (seq d)) (seq d))))
   e (register! m src (ri/mint! ctx builder))]
  (do
  (ri/assert-on! builder e (:KIND m) (ri/literal! "list"))
  (doseq [i (range (count elems))]
  (ri/assert-on! builder e (str "f" i) (mint-datum-on! m builder src (nth elems i))))
  e))
  (instance? java.util.regex.Pattern d) (mint-datum-on! m builder src (list (symbol "#%regex") (.pattern d)))
  (set? d) (mint-datum-on! m builder src (apply list (cons (symbol "#%set") (seq d))))
  :else (mint-leaf-on! m builder src "other" (pr-str d))))))))

(defn mint-datum! [^Mint m ^String src d]
  (let [ctx (:ctx m)
   builder (ri/open ctx)
   root (mint-datum-on! m builder src d)]
  (do
  (ri/commit! ctx builder)
  root)))

(defn fN-facts [^Mint m parent]
  (let [ctx (:ctx m)
   rows (reduce (fn [acc cid] (let [p (ri/predicate-at ctx cid)
   r (ri/value-at ctx cid)]
  (if (and (string? p) (some? (re-matches FN-RE (str p)))) (let [n (parse-long (subs (str p) 1))]
  (if (nil? n) acc (conj acc (->FnEdge n cid r)))) acc))) [] (ri/by-subject ctx parent))]
  (mapv (fn [^FnEdge e] [(:idx e) (:cid e) (:child e)]) (sort-by (fn [^FnEdge e] (:idx e)) rows))))

(defn retire-fact! [^Mint m oldc]
  (ri/retire! (:ctx m) oldc))

(defn- nn [e]
  e)

(defn- push [frame scope]
  (into [frame] scope))

(defn- ^Boolean renders-as-tracked-name? [^Mint m node]
  (and (empty? (ri/by-subject-predicate (:ctx m) (nn node) (:FIXED m))) (nil? (rr/pred-val (:ctx m) (:view m) node "qualifier"))))

(defn capture-refs [^Mint m node scope B newnm]
  (let [ctx (:ctx m)
   view (:view m)
   BOUND (:BOUND m)
   REFERS (:REFERS m)
   k (rr/kind-of ctx view node)]
  (cond
  (= "symbol" k) (let [target (rr/refers-target ctx view BOUND REFERS node)]
  (if (and (some? target) (= B (rv/ultimate ctx view BOUND REFERS target)) (renders-as-tracked-name? m node) (some? (some (fn [frame] (get frame newnm)) scope))) [node] []))
  (= "list" k) (let [kids (rr/ordered-children ctx node)
   head (str (rr/head-sym ctx view node))
   brk? (fn [candidate] (rb/brackets? ctx view candidate))
   capture-all (fn [nodes active-scope] (reduce (fn [acc child] (into acc (capture-refs m child active-scope B newnm))) [] nodes))
   cap-signature (fn [signature arity-scope] (let [params (:params signature)
   frame (rb/frame-of ctx view (if (nil? params) [] (rb/param-binds ctx view params)))
   constraints (if (nil? params) [] (rb/param-constraint-nodes ctx view params))
   or-vals (if (nil? params) [] (reduce (fn [acc binding] (into acc (rb/collect-or-vals ctx view binding))) [] (vec (rest (rr/ordered-children ctx params)))))
   body (vec (:body signature))]
  (into (into (capture-all constraints arity-scope) (capture-all or-vals arity-scope)) (capture-all body (push frame arity-scope)))))
   cap-arity (fn [forms ^Boolean macro? arity-scope] (cap-signature (rb/signature-parts ctx view forms macro? false) arity-scope))
   cap-field-constraints (fn [fields field-scope] (if (or (nil? fields) (not (brk? fields))) [] (capture-all (rb/param-constraint-nodes ctx view fields) field-scope)))
   cap-method-constraints (fn [raw-method method-scope] (let [method (rr/unwrap-meta ctx view raw-method)]
  (if (= "list" (rr/kind-of ctx view method)) (let [signature (rb/signature-parts ctx view (vec (rest (rr/ordered-children ctx method))) false false)
   params (:params signature)]
  (if (nil? params) [] (capture-all (rb/param-constraint-nodes ctx view params) method-scope))) [])))
   cap-protocol-method-constraints (fn [raw-method method-scope] (let [parts (rm/protocol-method-parts ctx view raw-method)
   params (:params parts)]
  (if (nil? params) [] (capture-all (rb/param-constraint-nodes ctx view params) method-scope))))
   cap-type-def (fn [forms type-scope] (let [type-head (str (rr/sym-val ctx view (nth forms 0 nil)))
   name-index (rc/type-name-index type-head (rr/sym-val ctx view (nth forms 1 nil)))
   members (vec (drop (inc name-index) forms))]
  (cond
  (= "defrecord" type-head) (cap-field-constraints (nth forms 2 nil) type-scope)
  (= "deftype" type-head) (reduce (fn [acc raw-member] (into acc (cap-method-constraints raw-member type-scope))) (cap-field-constraints (nth forms 2 nil) type-scope) (vec (drop 3 forms)))
  (contains? #{"defprotocol" "definterface"} type-head) (reduce (fn [acc method] (into acc (cap-protocol-method-constraints method type-scope))) [] members)
  (= "defunion" type-head) (reduce (fn [acc raw-member] (let [parts (rm/union-member-parts ctx view raw-member)
   fields (:fields parts)]
  (if (nil? fields) acc (into acc (cap-field-constraints fields type-scope))))) [] members)
  :else [])))]
  (cond
  (contains? rc/TYPE-DEFS head) (cap-type-def kids scope)
  (contains? rc/PARAM-FORMS head) (let [after-name (if (contains? #{"defn" "defn-" "defmacro"} head) (vec (drop 2 kids)) (vec (rest kids)))]
  (reduce (fn [acc signature] (into acc (cap-signature signature scope))) [] (rb/executable-signatures ctx view head after-name)))
  (contains? rc/LET-FORMS head) (let [bracket (nth kids 1 nil)
   pairs (if (and (some? bracket) (brk? bracket)) (rb/let-bind-pairs ctx view bracket) [])
   state (reduce (fn [state pair] (let [active-scope (nth state 0)
   captures (nth state 1)
   binds (nth pair 0)
   value-node (nth pair 1)
   or-vals (nth pair 2)
   constraint (nth pair 3 nil)
   after-defaults (into captures (capture-all or-vals active-scope))
   after-constraint (if (some? constraint) (into after-defaults (capture-refs m constraint active-scope B newnm)) after-defaults)
   after-value (if (some? value-node) (into after-constraint (capture-refs m value-node active-scope B newnm)) after-constraint)]
  [(push (rb/frame-of ctx view binds) active-scope) after-value])) [scope []] pairs)
   final-scope (nth state 0)
   binding-captures (nth state 1)]
  (into binding-captures (capture-all (vec (drop 2 kids)) final-scope)))
  (contains? rc/FOR-FORMS head) (let [bracket (nth kids 1 nil)
   entries (if (and (some? bracket) (brk? bracket)) (rb/for-bind-pairs ctx view bracket) [])
   state (reduce (fn [state entry] (let [active-scope (nth state 0)
   captures (nth state 1)]
  (if (= :expr (nth entry 0)) [active-scope (into captures (capture-refs m (nth entry 1) active-scope B newnm))] (let [binds (nth entry 1)
   value-node (nth entry 2)
   or-vals (nth entry 3)
   constraint (nth entry 4 nil)
   after-defaults (into captures (capture-all or-vals active-scope))
   after-constraint (if (some? constraint) (into after-defaults (capture-refs m constraint active-scope B newnm)) after-defaults)
   after-value (if (some? value-node) (into after-constraint (capture-refs m value-node active-scope B newnm)) after-constraint)]
  [(push (rb/frame-of ctx view binds) active-scope) after-value])))) [scope []] entries)
   final-scope (nth state 0)
   binding-captures (nth state 1)]
  (into binding-captures (capture-all (vec (drop 2 kids)) final-scope)))
  (contains? rc/MATCH-FORMS head) (reduce (fn [acc clause] (if (brk? clause) (let [clause-children (vec (rest (rr/ordered-children ctx clause)))
   pattern (nth clause-children 0 nil)
   body (vec (rest clause-children))
   frame (rb/frame-of ctx view (rb/match-pat-binds ctx view pattern))]
  (into (into acc (capture-refs m pattern scope B newnm)) (capture-all body (push frame scope)))) acc)) (capture-refs m (nth kids 1 nil) scope B newnm) (vec (drop 2 kids)))
  (= "letfn" head) (let [bracket (nth kids 1 nil)
   fnlists (if (and (some? bracket) (brk? bracket)) (vec (filter (fn [form] (= "list" (rr/kind-of ctx view form))) (vec (rest (rr/ordered-children ctx bracket))))) [])
   frame (rb/frame-of ctx view (vec (keep (fn [form] (nth (rr/ordered-children ctx form) 0 nil)) fnlists)))
   body-scope (push frame scope)
   function-captures (reduce (fn [acc form] (into acc (cap-arity (vec (rest (rr/ordered-children ctx form))) false body-scope))) [] fnlists)]
  (into function-captures (capture-all (vec (drop 2 kids)) body-scope)))
  (contains? #{"extend-type" "extend-protocol"} head) (reduce (fn [acc raw-item] (let [item (rr/unwrap-meta ctx view raw-item)]
  (cond
  (some? (rr/sym-val ctx view item)) acc
  (= "list" (rr/kind-of ctx view item)) (let [method (rr/ordered-children ctx item)]
  (into (into acc (capture-refs m (nth method 0 nil) scope B newnm)) (cap-arity (vec (rest method)) false scope)))
  :else acc))) [] (vec (rest kids)))
  (= "extend" head) (let [tail (vec (rest kids))
   target (nth tail 0 nil)
   body (vec (drop 2 tail))
   initial (if (some? target) (capture-refs m target scope B newnm) [])]
  (into initial (capture-all body scope)))
  (= "as->" head) (let [init (nth kids 1 nil)
   name-node (nth kids 2 nil)
   frame (rb/frame-of ctx view (if (some? (rr/sym-val ctx view name-node)) [(nn name-node)] []))
   initial (if (some? init) (capture-refs m init scope B newnm) [])]
  (into initial (capture-all (vec (drop 3 kids)) (push frame scope))))
  :else (capture-all kids scope)))
  :else [])))

(def INTERNAL-PREDS #{"refers_to" "keep_spelling" "qualifier" "ctor_prefix" "accessor_field"})

(defrecord Emit [ctx view BOUND REFERS FIXED ents wrapper-of descendants deleted-forms deleted-subtree])

(defn emit-ctx [r] (:ctx r))

(defn emit-view [r] (:view r))

(defn emit-BOUND [r] (:BOUND r))

(defn emit-REFERS [r] (:REFERS r))

(defn emit-FIXED [r] (:FIXED r))

(defn emit-ents [r] (:ents r))

(defn emit-wrapper-of [r] (:wrapper-of r))

(defn emit-descendants [r] (:descendants r))

(defn emit-deleted-forms [r] (:deleted-forms r))

(defn emit-deleted-subtree [r] (:deleted-subtree r))

(defn- emit-line! [^Emit m wrap e cid]
  (let [ctx (:ctx m)
   view (:view m)
   ps (ri/predicate-at ctx cid)
   r (ri/value-at ctx cid)]
  (cond
  (and (some? wrap) (= e wrap) (string? ps) (rc/ord-pos? ps) (not= ps "f0")) nil
  (contains? INTERNAL-PREDS (str ps)) nil
  (and (= ps "name") (= "symbol" (rr/kind-of ctx view e))) (str "[" (ri/ordinal! ctx e) " \"v\" " (pr-str (rv/render-sym ctx view (:BOUND m) (:REFERS m) (:FIXED m) e)) "]")
  (and (= ps "v") (some? (rr/refers-target ctx view (:BOUND m) (:REFERS m) e))) (str "[" (ri/ordinal! ctx e) " \"v\" " (pr-str (rv/render-sym ctx view (:BOUND m) (:REFERS m) (:FIXED m) e)) "]")
  (ri/literal? r) (str "[" (ri/ordinal! ctx e) " " (pr-str ps) " " (pr-str r) "]")
  :else (str "[" (ri/ordinal! ctx e) " " (pr-str ps) " " (ri/ordinal! ctx r) "]"))))

(defn extract-lines! [^Emit m ^String src]
  (let [ctx (:ctx m)
   wrapf (:wrapper-of m)
   desc (:descendants m)
   dforms (:deleted-forms m)
   dsub (:deleted-subtree m)
   wrap (wrapf src)
   root (if (empty? dforms) (wrapf src) nil)
   live (if (some? root) (desc root) nil)
   ents (vec (get (:ents m) src []))
   rows (reduce (fn [acc e] (if (or (contains? dsub e) (and (some? live) (not (contains? live e)))) acc (reduce (fn [a cid] (let [line (emit-line! m wrap e cid)]
  (if (nil? line) a (conj a line)))) acc (ri/by-subject ctx e)))) [] ents)
   children (if (some? wrap) (rr/ordered-children ctx wrap) [])
   head (first children)
   forms (vec (remove (fn [f] (contains? dforms f)) (vec (rest children))))
   projected-children (if (some? head) (into [head] forms) forms)
   structural-lines (mapv (fn [i] (let [child (nth projected-children i)
   child-ordinal (ri/ordinal! ctx child)
   predicate (rc/ord-str [(* (+ i 1) rc/ORD-STEP)] child-ordinal)]
  (str "[" (ri/ordinal! ctx wrap) " " (pr-str predicate) " " child-ordinal "]"))) (vec (range (count projected-children))))]
  (into (into [(str "@file " src)] rows) structural-lines)))

(defn author-emit-lines [op detail srcs outp]
  (let [f outp]
  (into [(str "================ authoring: " op " ================") detail] (mapv (fn [^String s] (str "projected -> " (f s) "   <- " s)) srcs))))

(defn re-resolve-frames [srcs mdefs mtypes maccs]
  (let [fd mdefs
   ft mtypes
   fa maccs]
  {:modframe (reduce (fn [acc ^String s] (assoc acc s (fd s))) {} srcs) :typeframe (reduce (fn [acc ^String s] (assoc acc s (ft s))) {} srcs) :accessors (reduce (fn [acc ^String s] (assoc acc s (fa s))) {} srcs)}))

(def STRUCTURAL-SEG-RE (re-pattern "seg\\d+"))

(def STRUCTURAL-COMMENT-RE (re-pattern "comment\\d+"))

(def PATH-SPLIT-RE (re-pattern "/"))

(defn wrapper-of [ctx view ents ^String src]
  (some (fn [e] (if (= "beagle-file" (rr/head-sym ctx view e)) (do
  e))) (vec (get ents src []))))

(defn structural-kids [ctx n]
  (vec (keep (fn [cid] (let [p (ri/predicate-at ctx cid)
   r (ri/target-at ctx cid)]
  (if (and (some? r) (string? p) (or (rc/ord-pos? p) (re-matches STRUCTURAL-SEG-RE p) (re-matches STRUCTURAL-COMMENT-RE p) (= p "tail"))) (do
  r)))) (ri/by-subject ctx n))))

(defn structural-descendants [ctx root]
  (loop [seen #{}
   stack [root]]
  (if (empty? stack) seen (let [n (peek stack)]
  (if (contains? seen n) (recur seen (pop stack)) (recur (conj seen n) (into (pop stack) (structural-kids ctx n))))))))

(defn form-for-victim [ctx view ents unwrap-def ^String src victim]
  (some (fn [f] (let [d (unwrap-def f)
   children (rr/ordered-children ctx d)
   name-index (rc/type-name-index (rr/head-sym ctx view d) (rr/sym-val ctx view (nth children 1 nil)))
   outer (rr/unwrap-meta ctx view (nth children name-index nil))
   leaf (if (= "list" (rr/kind-of ctx view outer)) (first (rr/ordered-children ctx outer)) outer)
   logical (rr/unwrap-meta ctx view leaf)]
  (if (= victim logical) (do
  f)))) (rest (rr/ordered-children ctx (wrapper-of ctx view ents src)))))

(defn ^Emit emit-env [ctx view BOUND REFERS FIXED ents unwrap-def]
  (->Emit ctx view BOUND REFERS FIXED ents (fn [^String src] (wrapper-of ctx view ents src)) (fn [root] (structural-descendants ctx root)) #{} #{}))

(def DEFAULT-RESOLVE-OUT nil)

(defn ^String out-path [^String src]
  (str (or DEFAULT-RESOLVE-OUT (System/getenv "RESOLVE_OUT") "/tmp") "/resolved-" (last (str/split src PATH-SPLIT-RE)) ".edn"))

(def DEFAULT-PROJECT-SRCS nil)

(defn emit-srcs [srcs]
  (if (nil? DEFAULT-PROJECT-SRCS) srcs (vec DEFAULT-PROJECT-SRCS)))

(defn ^Boolean scope-match? [module-name ^String src ^String scope]
  (let [seg? (fn [m] (boolean (and m (or (= m scope) (str/ends-with? m (str "." scope))))))]
  (or (seg? src) (seg? (module-name src)))))

(defn scope->srcs [module-name srcs ^String scope]
  (vec (filter (fn [^String src] (scope-match? module-name src scope)) srcs)))

(defn ^String out-path-for [resolve-out ^String src]
  (str (or resolve-out DEFAULT-RESOLVE-OUT (System/getenv "RESOLVE_OUT") "/tmp") "/resolved-" (last (str/split src PATH-SPLIT-RE)) ".edn"))

(defn emit-srcs-for [project-srcs srcs]
  (if (nil? project-srcs) (emit-srcs srcs) (vec project-srcs)))
