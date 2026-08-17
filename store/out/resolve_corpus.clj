(ns resolve-corpus
  (:require [clojure.string :as str]
            [resolve-ident :as ri]
            [resolve-core :as rc]
            [resolve-read :as rr]
            [resolve-modules :as rm]
            [resolve-walk :as rw]))

(def MODULE-NAME-RE (re-pattern "@([^#]+)#\\d+"))

(def NODE-REFERENCE-PREDICATE-RE (re-pattern "(?:seg|comment)\\d+"))

(defrecord CorpusState [ctx view KIND BOUND REFERS file-ents corpus-cache corpus-scope resolve-walk? srcs install-srcs install-tables install-warm run-all run-over profile])

(defn corpusstate-ctx [r] (:ctx r))

(defn corpusstate-view [r] (:view r))

(defn corpusstate-KIND [r] (:KIND r))

(defn corpusstate-BOUND [r] (:BOUND r))

(defn corpusstate-REFERS [r] (:REFERS r))

(defn corpusstate-file-ents [r] (:file-ents r))

(defn corpusstate-corpus-cache [r] (:corpus-cache r))

(defn corpusstate-corpus-scope [r] (:corpus-scope r))

(defn corpusstate-resolve-walk? [r] (:resolve-walk? r))

(defn corpusstate-srcs [r] (:srcs r))

(defn corpusstate-install-srcs [r] (:install-srcs r))

(defn corpusstate-install-tables [r] (:install-tables r))

(defn corpusstate-install-warm [r] (:install-warm r))

(defn corpusstate-run-all [r] (:run-all r))

(defn corpusstate-run-over [r] (:run-over r))

(defn corpusstate-profile [r] (:profile r))

(defrecord CorpusHost [with-state load-edn state])

(defn corpushost-with-state [r] (:with-state r))

(defn corpushost-load-edn [r] (:load-edn r))

(defn corpushost-state [r] (:state r))

(defn walk-corpus [srcs modframe typeframe accessors ents]
  (rw/->Corpus srcs modframe typeframe accessors ents))

(defn name->module [nm]
  (if (string? nm) (let [hit (re-matches MODULE-NAME-RE nm)]
  (if (some? hit) (second hit) nil)) nil))

(defn make-xresolve [ctx view ents-of exports type-exports accessor-exports src]
  (let [{:keys [refer as rename]} (rm/parse-require ctx view (vec (get ents-of src [])))
   xport (fn [m n] (or (get-in exports [m n]) (get-in type-exports [m n])))
   xacc (fn [m n] (get-in accessor-exports [m n]))]
  (fn [qualifier nm] (cond
  (nil? nm) nil
  (some? qualifier) (let [alias qualifier
   public-name nm
   module (or (get as alias) (if (some (fn [table] (contains? table alias)) [exports type-exports accessor-exports]) (do
  alias)))]
  (if module (do
  (let [target (xport module public-name)]
  (if target {:target target :mode :qual :alias alias} (let [accessor (xacc module public-name)]
  (if accessor (do
  {:target (first accessor) :mode :qual :alias alias :accessor (second accessor)}))))))))
  (get refer nm) (let [m (get refer nm)]
  (let [target (xport m nm)]
  (if target {:target target :mode :tracking} (let [accessor (xacc m nm)]
  (if accessor (do
  {:target (first accessor) :mode :tracking :accessor (second accessor)}))))))
  (get rename nm) (let [[m source-name] (get rename nm)]
  {:target (xport m source-name) :mode :fixed})
  :else nil))))

(defn module-export-set [ctx view ents-of src]
  (let [ents (vec (get ents-of src []))
   exports (rm/module-exports ctx view ents)
   value-exports (if (empty? exports) (rm/module-defs ctx view ents) exports)]
  (into #{} (concat (set (keys value-exports)) (set (keys (rm/module-types ctx view ents))) (set (keys (rm/module-accessors ctx view ents)))))))

(defn module-imports [ctx view ents-of src]
  (let [imports (rm/parse-require ctx view (vec (get ents-of src [])))
   refer (:refer imports {})
   as (:as imports {})
   rename (:rename imports {})]
  (into #{} (concat (set (vals refer)) (set (vals as)) (map first (set (vals rename)))))))

(defn import-graph [ctx view ents-of srcs]
  (into {} (map (fn [src] (let [ents (vec (get ents-of src []))]
  [(rm/module-name ctx view ents) (module-imports ctx view ents-of src)])) (filter (fn [src] (some? (rm/module-name ctx view (vec (get ents-of src []))))) srcs))))

(defn ^Boolean module-has-macro? [ctx view ents-of src]
  (let [ents (vec (get ents-of src []))]
  (boolean (some (fn [form] (let [def-form (rm/unwrap-def ctx view form)
   head (first (rr/ordered-children ctx def-form))]
  (= "defmacro" (rr/sym-val ctx view head)))) (rm/forms-of ctx view ents)))))

(defn lift-bound-to-refers! [ctx KIND BOUND REFERS]
  (if (some? BOUND) (do
  (doseq [occ (ri/by-predicate ctx BOUND)]
  (let [leaf (ri/subject-at ctx occ)
   target (ri/target-at ctx occ)]
  (if (and (some? target) (rr/live-node? ctx KIND target) (empty? (ri/by-subject-predicate ctx leaf REFERS))) (do
  (ri/assert! ctx leaf REFERS target))))))))

(defn corpus-from-store! [^CorpusState state]
  (let [t0 (System/nanoTime)
   groups (rw/warm-groups (:ctx state) (:corpus-cache state) name->module)
   t-groups (System/nanoTime)
   tables (rw/scoped-corpus-tables (:ctx state) (:view state) groups (:corpus-scope state))
   install (:install-warm state)]
  (do
  (install groups tables)
  (if (= "1" (System/getenv "BEAGLE_STORE_PROF")) (do
  (let [profile (:profile state)
   t-done (System/nanoTime)]
  (profile (format "  corpus-from-store!: groups=%.1fms frames+exports=%.1fms cached=%s nsrcs=%d scoped=%s" (/ (- t-groups t0) 1000000.0) (/ (- t-done t-groups) 1000000.0) (some? (:corpus-cache state)) (count (:srcs tables)) (boolean (:corpus-scope state)))))))
  tables)))

(def ^String RESOLVE-SPACE "resolve")

(defn resolve-edn! [^CorpusHost host edn-paths body]
  (let [ctx (ri/new-graph! RESOLVE-SPACE)
   with-state (:with-state host)]
  (with-state ctx (fn [] (let [state-fn (:state host)
   load (:load-edn host)
   loaded (mapv load edn-paths)
   state (state-fn)
   install-srcs (:install-srcs state)
   install-tables (:install-tables state)]
  (do
  (install-srcs loaded)
  (install-tables (rw/corpus-tables (:ctx state) (:view state) loaded (deref (:file-ents state))))
  (let [run-all (:run-all state)]
  (run-all))
  (body)))))))

(defn resolve-warm-store! [^CorpusHost host ctx body]
  (let [with-state (:with-state host)]
  (with-state ctx (fn [] (let [state-fn (:state host)
   state (state-fn)]
  (do
  (corpus-from-store! state)
  (if (:resolve-walk? state) (do
  (let [run-all (:run-all state)]
  (run-all))
  (lift-bound-to-refers! (:ctx state) (:KIND state) (:BOUND state) (:REFERS state))))
  (body)))))))

(defn resolve-modules! [^CorpusHost host ctx module-set body]
  (let [with-state (:with-state host)]
  (with-state ctx (fn [] (let [state-fn (:state host)
   state (state-fn)]
  (do
  (corpus-from-store! state)
  (let [fresh (state-fn)
   run-over (:run-over fresh)]
  (run-over (filter module-set (:srcs fresh)))
  (lift-bound-to-refers! (:ctx fresh) (:KIND fresh) (:BOUND fresh) (:REFERS fresh)))
  (body)))))))

(defn file-entities [file-ents src]
  (get (deref file-ents) src []))

(defn file-entity-map [file-ents]
  (deref file-ents))

(defn def-binding [modframe typeframe src nm]
  (or (get (get modframe src) nm) (get (get typeframe src) nm)))

(defn corpus-table-values [tables]
  [(:modframe tables) (:typeframe tables) (:accessors tables) (:exports tables) (:type-exports tables) (:accessor-exports tables)])

(defn table-srcs [tables]
  (:srcs tables))

(def corpus-predicates {:Vp "v" :KIND "kind" :REFERS "refers_to" :BOUND "bound_to" :FIXED "keep_spelling" :QUAL "qualifier" :CTOR "ctor_prefix" :ACC "accessor_field"})

(defn corpus-predicate-ids [ctx]
  corpus-predicates)

(defn- ^Boolean node-reference-predicate? [predicate]
  (and (string? predicate) (or (= "child" predicate) (= "tail" predicate) (rc/ord-pos? predicate) (boolean (re-matches NODE-REFERENCE-PREDICATE-RE predicate)))))

(defn- structural-reader-rows [rows]
  (let [symbol-nodes (reduce (fn [nodes row] (if (and (= "kind" (nth row 1 nil)) (= "symbol" (nth row 2 nil))) (conj nodes (nth row 0)) nodes)) #{} rows)]
  (reduce (fn [result row] (let [subject (nth row 0 nil)
   predicate (nth row 1 nil)
   object (nth row 2 nil)]
  (if (and (= "v" predicate) (contains? symbol-nodes subject) (string? object)) (let [reference (symbol object)
   qualifier (namespace reference)]
  (if (nil? qualifier) (conj result row) (into result [[subject "qualifier" qualifier] [subject "name" (name reference)]]))) (conj result row)))) [] rows)))

(defn load-edn! [ctx file-ents path]
  (let [lines (str/split-lines (slurp path))
   src (-> (first (filter (fn [line] (str/starts-with? line "@file")) lines)) (subs 6))
   local (atom {})
   read-edn (requiring-resolve 'clojure.edn/read-string)
   rows (structural-reader-rows (mapv read-edn (filter (fn [line] (str/starts-with? line "[")) lines)))
   builder (ri/open ctx)
   ent (fn [lid] (or (get (deref local) lid) (let [e (ri/mint! ctx builder)]
  (do
  (swap! local assoc lid e)
  (swap! file-ents update src (fnil conj []) e)
  e))))]
  (do
  (doseq [row rows]
  (let [[s p o] row]
  (ri/assert-on! builder (ent s) p (if (node-reference-predicate? p) (if (integer? o) (ent o) (throw (ex-info "resolve: structural edge target must be a local integer id" {:predicate p :target o}))) (ri/literal! o)))))
  (ri/commit! ctx builder)
  src)))
