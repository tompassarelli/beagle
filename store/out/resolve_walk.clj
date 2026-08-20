(ns resolve-walk
  (:require [clojure.string :as str]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [resolve-read :as rr]
            [resolve-binds :as rb]
            [resolve-modules :as rm]))

(defrecord Walk [ctx view REFERS BOUND FIXED QUAL CTOR ACC nres nunres nxmod ntype ncomment xres tres ares])

(defn walk-ctx [r] (:ctx r))

(defn walk-view [r] (:view r))

(defn walk-REFERS [r] (:REFERS r))

(defn walk-BOUND [r] (:BOUND r))

(defn walk-FIXED [r] (:FIXED r))

(defn walk-QUAL [r] (:QUAL r))

(defn walk-CTOR [r] (:CTOR r))

(defn walk-ACC [r] (:ACC r))

(defn walk-nres [r] (:nres r))

(defn walk-nunres [r] (:nunres r))

(defn walk-nxmod [r] (:nxmod r))

(defn walk-ntype [r] (:ntype r))

(defn walk-ncomment [r] (:ncomment r))

(defn walk-xres [r] (:xres r))

(defn walk-tres [r] (:tres r))

(defn walk-ares [r] (:ares r))

(defrecord Corpus [srcs module-context type-context accessors ents])

(defn corpus-srcs [r] (:srcs r))

(defn corpus-module-context [r] (:module-context r))

(defn corpus-type-context [r] (:type-context r))

(defn corpus-accessors [r] (:accessors r))

(defn corpus-ents [r] (:ents r))

(defn- nn [e]
  e)

(def UNQUOTE-TOKENS #{"~" "," "~@" ",@"})

(defn- sv [^Walk w e]
  (rr/sym-val (:ctx w) (:view w) e))

(defn- sq [^Walk w e]
  (rr/sym-qualifier (:ctx w) (:view w) e))

(defn- kd [^Walk w e]
  (rr/kind-of (:ctx w) (:view w) e))

(defn- hd [^Walk w e]
  (rr/head-sym (:ctx w) (:view w) e))

(defn- kids [^Walk w e]
  (rr/ordered-children (:ctx w) e))

(defn- ^Boolean brk? [^Walk w e]
  (rb/brackets? (:ctx w) (:view w) e))

(defn- ^Boolean list? [^Walk w e]
  (= "list" (kd w e)))

(defn- xr [^Walk w node nm]
  (let [f (:xres w)]
  (f (sq w node) nm)))

(defn- tr [^Walk w nm]
  (let [f (:tres w)]
  (f nm)))

(defn- ar [^Walk w nm]
  (let [f (:ares w)]
  (f nm)))

(defn- scope-lookup [scope nm]
  (loop [i 0]
  (if (>= i (count scope)) nil (let [hit (get (nth scope i) nm)]
  (if (nil? hit) (recur (inc i)) hit)))))

(defn- push [context scope]
  (into [context] scope))

(defn bind! [^Walk w L target]
  (do
  (ri/assert! (:ctx w) (nn L) (:REFERS w) (nn target))
  (swap! (:nres w) (fn [n] (inc n)))))

(defn bind-xmod! [^Walk w node x]
  (if (or (nil? x) (nil? (:target x))) nil (let [mode (:mode x)
   acc (:accessor x)]
  (do
  (bind! w node (:target x))
  (if (= :fixed mode) (do
  (ri/assert! (:ctx w) (nn node) (:FIXED w) (ri/literal! "1"))))
  (if (some? acc) (do
  (ri/assert! (:ctx w) (nn node) (:ACC w) (ri/literal! acc))))
  (swap! (:nxmod w) (fn [n] (inc n)))
  true))))

(defn bound-render! [^Walk w node nm bt]
  (do
  (bind! w node bt)
  (let [x (xr w node nm)
   pfx (rc/ctor-prefix (if (string? nm) nm nil))
   acc (ar w nm)
   stripped (if (nil? pfx) nil (str/replace (str nm) pfx ""))]
  (cond
  (and (some? x) (some? (:target x))) (let [mode (:mode x)
   xacc (:accessor x)]
  (do
  (if (= :fixed mode) (do
  (ri/assert! (:ctx w) (nn node) (:FIXED w) (ri/literal! "1"))))
  (if (some? xacc) (do
  (ri/assert! (:ctx w) (nn node) (:ACC w) (ri/literal! xacc))))))
  (and (some? pfx) (or (some? (tr w stripped)) (some? (:target (xr w node stripped))))) (ri/assert! (:ctx w) (nn node) (:CTOR w) (ri/literal! pfx))
  (some? acc) (ri/assert! (:ctx w) (nn node) (:ACC w) (ri/literal! (nth acc 1)))
  :else nil))))

(defn walk-type! [^Walk w node]
  (cond
  (some? (sv w node)) (let [nm (sv w node)
   qualifier (sq w node)
   b (if (nil? qualifier) (tr w nm) nil)]
  (if (some? b) (do
  (bind! w node b)
  (swap! (:ntype w) (fn [n] (inc n)))
  true) (bind-xmod! w node (xr w node nm))))
  (= "list" (kd w node)) (doseq [ch (kids w node)]
  (walk-type! w ch))
  (brk? w node) (doseq [ch (vec (rest (kids w node)))]
  (walk-type! w ch))
  :else nil))

(defn- walk-binding-types! [^Walk w types]
  (doseq [type-node types]
  (walk-type! w type-node)))

(defn walk-all! [^Walk w nodes scope wf]
  (doseq [n nodes]
  (wf w n scope)))

(defn walk-pat-heads! [^Walk w pat scope wf]
  (if (= "list" (kd w pat)) (do
  (let [cs (kids w pat)]
  (do
  (wf w (nth cs 0 nil) scope)
  (doseq [ch (vec (rest cs))]
  (walk-pat-heads! w ch scope wf)))))))

(defn- walk-fn-signature! [^Walk w signature scope wf ^Boolean macro?]
  (if (some? signature) (do
  (let [params (:params signature)
   binds (rb/param-binds (:ctx w) (:view w) params)
   constraints (rb/param-constraint-nodes (:ctx w) (:view w) params)
   or-vals (reduce (fn [acc binding] (into acc (rb/collect-or-vals (:ctx w) (:view w) binding))) [] (vec (rest (kids w params))))
   context (rb/context-of (:ctx w) (:view w) binds)
   return-type (:return-type signature)
   raises-type (:raises-type signature)]
  (do
  (if (not macro?) (do
  (walk-binding-types! w (rb/param-type-nodes (:ctx w) (:view w) params))))
  (if (some? return-type) (do
  (walk-type! w return-type)))
  (if (some? raises-type) (do
  (walk-type! w raises-type)))
  (walk-all! w constraints scope wf)
  (walk-all! w or-vals scope wf)
  (walk-all! w (:body signature) (push context scope) wf))))))

(defn walk-fn-arity! [^Walk w forms scope wf ^Boolean macro?]
  (walk-fn-signature! w (rb/signature-parts (:ctx w) (:view w) forms macro? false) scope wf macro?))

(defn walk-quasi! [^Walk w node scope ^Boolean quoted? wf qsf]
  (cond
  (some? (sv w node)) (if (not quoted?) (do
  (let [nm (sv w node)
   qualifier (sq w node)
   outer (if (empty? scope) [] (vec (butlast scope)))
   module-context (if (empty? scope) nil (last scope))
   inner (if (nil? qualifier) (scope-lookup outer nm) nil)
   mod-hit (if (nil? qualifier) (get module-context nm) nil)]
  (cond
  (some? inner) nil
  (some? mod-hit) (bind! w node mod-hit)
  (some? (bind-xmod! w node (xr w node nm))) nil
  :else nil))))
  (= "list" (kd w node)) (let [h (hd w node)]
  (cond
  (contains? #{"unquote" "unquote-splicing"} (str h)) (walk-all! w (vec (rest (kids w node))) scope wf)
  (= "quote" (str h)) (qsf w (kids w node) scope true wf)
  :else (qsf w (kids w node) scope quoted? wf)))
  :else nil))

(defn walk-quasi-seq! [^Walk w children scope ^Boolean quoted? wf]
  (loop [cs children]
  (if (empty? cs) nil (let [v (sv w (nth cs 0 nil))]
  (if (and (some? v) (contains? UNQUOTE-TOKENS (str v))) (do
  (if (some? (nth cs 1 nil)) (do
  (wf w (nth cs 1 nil) scope)))
  (recur (vec (drop 2 cs)))) (do
  (walk-quasi! w (nth cs 0 nil) scope quoted? wf walk-quasi-seq!)
  (recur (vec (rest cs)))))))))

(defn- ^Boolean try-type! [^Walk w node nm]
  (let [b (tr w nm)]
  (if (nil? b) false (do
  (bind! w node b)
  (swap! (:ntype w) (fn [n] (inc n)))
  true))))

(defn- ^Boolean try-ctor! [^Walk w node nm]
  (let [pfx (rc/ctor-prefix (if (string? nm) nm nil))
   qualifier (sq w node)]
  (if (nil? pfx) false (let [stripped (str/replace (str nm) pfx "")
   b (if (nil? qualifier) (tr w stripped) nil)]
  (if (some? b) (do
  (bind! w node b)
  (ri/assert! (:ctx w) (nn node) (:CTOR w) (ri/literal! pfx))
  (swap! (:ntype w) (fn [n] (inc n)))
  true) (if (some? (bind-xmod! w node (xr w node stripped))) (do
  (ri/assert! (:ctx w) (nn node) (:CTOR w) (ri/literal! pfx))
  true) false))))))

(defn- ^Boolean try-accessor! [^Walk w node nm]
  (let [a (ar w nm)]
  (if (nil? a) false (do
  (bind! w node (nth a 0))
  (ri/assert! (:ctx w) (nn node) (:ACC w) (ri/literal! (nth a 1)))
  (swap! (:ntype w) (fn [n] (inc n)))
  true))))

(defn- walk-signature-types! [^Walk w signature scope wf]
  (if (some? signature) (do
  (do
  (walk-binding-types! w (rb/param-type-nodes (:ctx w) (:view w) (:params signature)))
  (if (some? (:return-type signature)) (do
  (walk-type! w (:return-type signature))))
  (if (some? (:raises-type signature)) (do
  (walk-type! w (:raises-type signature))))
  (walk-all! w (rb/param-constraint-nodes (:ctx w) (:view w) (:params signature)) scope wf)))))

(defn- walk-method-types! [^Walk w raw-method scope wf]
  (let [method (rr/unwrap-meta (:ctx w) (:view w) raw-method)]
  (if (= "list" (kd w method)) (do
  (walk-signature-types! w (rb/signature-parts (:ctx w) (:view w) (vec (rest (kids w method))) false false) scope wf)))))

(defn- walk-protocol-method-types! [^Walk w raw-method scope wf]
  (let [parts (rm/protocol-method-parts (:ctx w) (:view w) raw-method)]
  (if (some? parts) (do
  (walk-signature-types! w {:params (:params parts) :return-type (:return-type parts) :raises-type nil} scope wf)))))

(defn- walk-type-def! [^Walk w ks scope wf]
  (let [head (str (sv w (nth ks 0 nil)))
   name-index (rc/type-name-index head (sv w (nth ks 1 nil)))
   members (vec (drop (inc name-index) ks))]
  (cond
  (= "defrecord" head) (let [fields (nth ks 2 nil)]
  (if (and (some? fields) (brk? w fields)) (do
  (do
  (walk-binding-types! w (rb/param-type-nodes (:ctx w) (:view w) fields))
  (walk-all! w (rb/param-constraint-nodes (:ctx w) (:view w) fields) scope wf)))))
  (= "deftype" head) (let [fields (nth ks 2 nil)]
  (do
  (if (and (some? fields) (brk? w fields)) (do
  (do
  (walk-binding-types! w (rb/param-type-nodes (:ctx w) (:view w) fields))
  (walk-all! w (rb/param-constraint-nodes (:ctx w) (:view w) fields) scope wf))))
  (doseq [raw-member (vec (drop 3 ks))]
  (let [member (rr/unwrap-meta (:ctx w) (:view w) raw-member)]
  (cond
  (= "list" (kd w member)) (walk-method-types! w member scope wf)
  (some? (sv w member)) (walk-type! w member)
  :else nil)))))
  (contains? #{"defprotocol" "definterface"} head) (doseq [method members]
  (walk-protocol-method-types! w method scope wf))
  (= "defunion" head) (doseq [raw-member members]
  (let [member (rr/unwrap-meta (:ctx w) (:view w) raw-member)
   parts (rm/union-member-parts (:ctx w) (:view w) raw-member)]
  (cond
  (some? (:fields parts)) (let [fields (:fields parts)]
  (do
  (walk-binding-types! w (rb/param-type-nodes (:ctx w) (:view w) fields))
  (walk-all! w (rb/param-constraint-nodes (:ctx w) (:view w) fields) scope wf)))
  (some? (:name parts)) (let [binding (tr w (sv w (:name parts)))]
  (if (and (some? binding) (not= binding member)) (do
  (do
  (bind! w member binding)
  (swap! (:ntype w) (fn [n] (inc n)))))))
  :else nil)))
  :else nil)))

(defn- walk-executable! [^Walk w ^String head forms scope wf]
  (doseq [signature (rb/executable-signatures (:ctx w) (:view w) head forms)]
  (walk-fn-signature! w signature scope wf (= "defmacro" head))))

(defn- walk-value-def! [^Walk w ks scope wf]
  (let [tail (vec (drop 2 ks))
   first-node (nth tail 0 nil)
   typed? (and (>= (count tail) 2) (not= "string" (kd w first-node)))
   value-node (last tail)]
  (do
  (if typed? (do
  (walk-type! w first-node)))
  (if (some? value-node) (do
  (wf w value-node scope))))))

(defn- walk-extension! [^Walk w ks scope wf]
  (let [head (str (sv w (nth ks 0 nil)))
   tail (vec (rest ks))]
  (if (= "extend" head) (do
  (if (some? (nth tail 0 nil)) (do
  (wf w (nth tail 0) scope)))
  (if (some? (nth tail 1 nil)) (do
  (walk-type! w (nth tail 1))))
  (walk-all! w (vec (drop 2 tail)) scope wf)) (doseq [raw-item tail]
  (let [item (rr/unwrap-meta (:ctx w) (:view w) raw-item)]
  (cond
  (some? (sv w item)) (walk-type! w item)
  (= "list" (kd w item)) (let [method (kids w item)]
  (do
  (if (some? (nth method 0 nil)) (do
  (wf w (nth method 0) scope)))
  (walk-fn-arity! w (vec (rest method)) scope wf false)))
  :else nil))))))

(defn walk! [^Walk w node scope]
  (let [k (kd w node)]
  (cond
  (= "symbol" k) (let [nm (sv w node)
   qualifier (sq w node)
   local (if (nil? qualifier) (scope-lookup scope nm) nil)
   bt (rr/bound-target (:ctx w) (:view w) (:BOUND w) node)]
  (cond
  (some? bt) (bound-render! w node nm bt)
  (some? local) (bind! w node local)
  (some? (bind-xmod! w node (xr w node nm))) nil
  (and (some? qualifier) (try-ctor! w node nm)) nil
  (some? qualifier) (swap! (:nunres w) (fn [n] (inc n)))
  (try-type! w node nm) nil
  (try-ctor! w node nm) nil
  (try-accessor! w node nm) nil
  :else (swap! (:nunres w) (fn [n] (inc n)))))
  (= "list" k) (let [ks (kids w node)
   h (hd w node)
   hs (str h)]
  (cond
  (= "quote" hs) nil
  (= "quasiquote" hs) (walk-quasi! w node scope false walk! walk-quasi-seq!)
  (contains? rc/TYPE-DEFS hs) (walk-type-def! w ks scope walk!)
  (contains? rc/DEF-FORMS hs) (walk-value-def! w ks scope walk!)
  (contains? rc/PARAM-FORMS hs) (walk-executable! w hs (if (contains? #{"defn" "defn-" "defmacro"} hs) (vec (drop 2 ks)) (vec (rest ks))) scope walk!)
  (contains? rc/LET-FORMS hs) (let [bracket (nth ks 1 nil)
   ok (and (some? bracket) (brk? w bracket))
   _ (if ok (do
  (walk-binding-types! w (rb/let-type-nodes (:ctx w) (:view w) bracket))))
   pairs (if ok (rb/let-bind-pairs (:ctx w) (:view w) bracket) [])
   final (reduce (fn [sc p] (let [bsyms (nth p 0)
   vnode (nth p 1)
   orvals (nth p 2)
   constraint (nth p 3 nil)]
  (do
  (walk-all! w orvals sc walk!)
  (if (some? constraint) (do
  (walk! w constraint sc)))
  (if (some? vnode) (do
  (walk! w vnode sc)))
  (push (rb/context-of (:ctx w) (:view w) bsyms) sc)))) scope pairs)]
  (walk-all! w (vec (drop 2 ks)) final walk!))
  (contains? rc/FOR-FORMS hs) (let [bracket (nth ks 1 nil)
   ok (and (some? bracket) (brk? w bracket))
   _ (if ok (do
  (walk-binding-types! w (rb/for-type-nodes (:ctx w) (:view w) bracket))))
   entries (if ok (rb/for-bind-pairs (:ctx w) (:view w) bracket) [])
   final (reduce (fn [sc e] (if (= :expr (nth e 0)) (do
  (walk! w (nth e 1) sc)
  sc) (let [bsyms (nth e 1)
   vnode (nth e 2)
   orvals (nth e 3)
   constraint (nth e 4 nil)]
  (do
  (walk-all! w orvals sc walk!)
  (if (some? constraint) (do
  (walk! w constraint sc)))
  (if (some? vnode) (do
  (walk! w vnode sc)))
  (push (rb/context-of (:ctx w) (:view w) bsyms) sc))))) scope entries)]
  (walk-all! w (vec (drop 2 ks)) final walk!))
  (contains? rc/MATCH-FORMS hs) (do
  (walk! w (nth ks 1 nil) scope)
  (doseq [clause (vec (filter (fn [cl] (brk? w cl)) (vec (drop 2 ks))))]
  (let [cc (vec (rest (kids w clause)))
   pat (nth cc 0 nil)
   body (vec (rest cc))]
  (do
  (walk-pat-heads! w pat scope walk!)
  (walk-all! w body (push (rb/context-of (:ctx w) (:view w) (rb/match-pat-binds (:ctx w) (:view w) pat)) scope) walk!)))))
  (= "letfn" hs) (let [bracket (nth ks 1 nil)
   fnlists (if (and (some? bracket) (brk? w bracket)) (vec (filter (fn [f] (= "list" (kd w f))) (vec (rest (kids w bracket))))) [])
   context (rb/context-of (:ctx w) (:view w) (vec (keep (fn [f] (nth (kids w f) 0 nil)) fnlists)))
   bodyscope (push context scope)]
  (do
  (doseq [fl fnlists]
  (walk-fn-arity! w (vec (rest (kids w fl))) bodyscope walk! false))
  (walk-all! w (vec (drop 2 ks)) bodyscope walk!)))
  (contains? rc/EXTEND-FORMS hs) (walk-extension! w ks scope walk!)
  (= "as->" hs) (let [init (nth ks 1 nil)
   name (nth ks 2 nil)
   context (rb/context-of (:ctx w) (:view w) (if (some? (sv w name)) [name] []))]
  (do
  (if (some? init) (do
  (walk! w init scope)))
  (walk-all! w (vec (drop 3 ks)) (push context scope) walk!)))
  :else (walk-all! w ks scope walk!)))
  :else nil)))

(defn cbind! [^Walk w L target]
  (do
  (ri/assert! (:ctx w) (nn L) (:REFERS w) (nn target))
  (swap! (:ncomment w) (fn [n] (inc n)))))

(defn- def-binding [^Corpus cp src nm]
  (let [v (get (get (:module-context cp) src) nm)]
  (if (some? v) v (get (get (:type-context cp) src) nm))))

(defn resolve-comment! [^Walk w ^Corpus cp e src]
  (doseq [seg (vec (filter (fn [s] (= "symbol" (kd w s))) (rr/ordered-segs (:ctx w) e)))]
  (let [nm (sv w seg)
   qualifier (sq w seg)
   local (if (nil? qualifier) (def-binding cp src nm) nil)
   b (if (some? local) local (:target (xr w seg nm)))]
  (if (some? b) (do
  (cbind! w seg b))))))

(defn walk-comments! [^Walk w ^Corpus cp src]
  (doseq [e (vec (filter (fn [x] (= "comment" (kd w x))) (vec (get (:ents cp) src []))))]
  (resolve-comment! w cp e src)))

(defn- ^Walk for-src [^Walk w ^Corpus cp src xres-for]
  (->Walk (:ctx w) (:view w) (:REFERS w) (:BOUND w) (:FIXED w) (:QUAL w) (:CTOR w) (:ACC w) (:nres w) (:nunres w) (:nxmod w) (:ntype w) (:ncomment w) (xres-for src) (fn [nm] (get (get (:type-context cp) src) nm)) (fn [nm] (get (get (:accessors cp) src) nm))))

(defn run-resolution-over! [^Walk w ^Corpus cp walk-srcs xres-for n-forms walked]
  (doseq [src walk-srcs]
  (let [w2 (for-src w cp src xres-for)
   ents (vec (get (:ents cp) src []))
   forms (rm/forms-of (:ctx w) (:view w) ents)]
  (do
  (swap! walked conj src)
  (swap! n-forms + (count forms))
  (walk-all! w2 forms [(get (:module-context cp) src)] walk!)
  (walk-comments! w2 cp src)))))

(defn run-resolution! [^Walk w ^Corpus cp xres-for n-forms walked]
  (run-resolution-over! w cp (:srcs cp) xres-for n-forms walked))

(defn corpus-tables [ctx view srcs ents-of]
  (let [per (fn [f] (reduce (fn [m s] (assoc m s (f (vec (get ents-of s []))))) {} srcs))
   named (vec (filter (fn [s] (some? (rm/module-name ctx view (vec (get ents-of s []))))) srcs))
   by-mod (fn [f] (reduce (fn [m s] (let [ents (vec (get ents-of s []))]
  (assoc m (rm/module-name ctx view ents) (f ents)))) {} named))]
  {:module-context (per (fn [ents] (rm/module-defs ctx view ents))) :type-context (per (fn [ents] (rm/module-types ctx view ents))) :accessors (per (fn [ents] (rm/module-accessors ctx view ents))) :exports (by-mod (fn [ents] (let [e (rm/module-exports ctx view ents)]
  (if (empty? e) (rm/module-defs ctx view ents) e)))) :type-exports (by-mod (fn [ents] (rm/module-types ctx view ents))) :accessor-exports (by-mod (fn [ents] (rm/module-accessors ctx view ents)))}))

(defn warm-groups [ctx cache name->module]
  (if (some? cache) cache (reduce (fn [groups occ] (let [node-name (ri/value-at ctx occ)
   module (name->module node-name)]
  (if (some? module) (update groups module (fnil conj []) (ri/subject-at ctx occ)) groups))) {} (ri/by-predicate ctx "name"))))

(defn scoped-corpus-tables [ctx view groups scope]
  (let [srcs (vec (keys groups))
   context-srcs (if (some? scope) (vec (filter scope srcs)) srcs)
   per-context (fn [f] (reduce (fn [table src] (assoc table src (f (vec (get groups src []))))) {} context-srcs))
   named (vec (filter (fn [src] (some? (rm/module-name ctx view (vec (get groups src []))))) srcs))
   by-module (fn [f] (if (some? scope) {} (reduce (fn [table src] (let [ents (vec (get groups src []))]
  (assoc table (rm/module-name ctx view ents) (f ents)))) {} named)))]
  {:srcs srcs :module-context (per-context (fn [ents] (rm/module-defs ctx view ents))) :type-context (per-context (fn [ents] (rm/module-types ctx view ents))) :accessors (per-context (fn [ents] (rm/module-accessors ctx view ents))) :exports (by-module (fn [ents] (let [exports (rm/module-exports ctx view ents)]
  (if (empty? exports) (rm/module-defs ctx view ents) exports)))) :type-exports (by-module (fn [ents] (rm/module-types ctx view ents))) :accessor-exports (by-module (fn [ents] (rm/module-accessors ctx view ents)))}))
