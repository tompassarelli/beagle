(ns store.candidate-transformer
  (:require [clojure.set :as set]
            [clojure.string :as str]
            [resolve-core :as resolve-core]))

(def ^:private executable-heads #{"defn" "defn-"})
(def ^:private macro-heads #{"defmacro"})
(def ^:private value-heads #{"def" "def-" "defonce"})
(def ^:private max-edits 32)
(def ^:private source-meta-keys
  [:line :column :end-line :end-column :file])

(defn- reject! [type message data]
  (throw (ex-info message (assoc data :type type))))

(defn- node-name [module n]
  (str "@" module "#" n))

(defn- module-node-int [module value]
  (when (string? value)
    (let [prefix (str "@" module "#")]
      (when (str/starts-with? value prefix)
        (let [suffix (subs value (count prefix))]
          (when (re-matches #"(?:0|[1-9][0-9]*)" suffix)
            (parse-long suffix)))))))

(defn- next-node-int [facts module]
  (inc
   (reduce
    (fn [largest [subject _ object]]
      (max largest
           (or (module-node-int module subject) 0)
           (or (module-node-int module object) 0)))
    0 facts)))

(defn- object-index [facts]
  (reduce (fn [idx [subject predicate object]]
            (update idx [subject predicate] (fnil conj #{}) object))
          {} facts))

(defn- only-object [index node predicate]
  (let [values (get index [node predicate] #{})]
    (when (= 1 (count values)) (first values))))

(defn- position-key [predicate]
  (when (string? predicate)
    (if-let [[_ n] (re-matches #"f([0-9]+)" predicate)]
      [[(* (inc (parse-long n)) 65536)] [0 0]]
      (when-let [[_ path tie]
                 (re-matches #"f([0-9]+(?:\.[0-9]+)*)~([0-9]+|t[A-Za-z0-9_-]+)" predicate)]
        [(mapv parse-long (str/split path #"\."))
         (if (str/starts-with? tie "t") [1 tie] [0 (parse-long tie)])]))))

(defn- ordered-edges [facts node]
  (->> facts
       (keep (fn [[subject predicate object :as fact]]
               (when (= subject node)
                 (when-let [key (position-key predicate)]
                   {:key key :fact fact :node object}))))
       (sort-by (juxt :key (comp second :fact)))
       vec))

(defn- ordered-nodes [facts node]
  (mapv :node (ordered-edges facts node)))

(defn- kind-of [index node]
  (only-object index node "kind"))

(defn- symbol-value [index node]
  (when (= "symbol" (kind-of index node))
    (only-object index node "v")))

(defn- head-symbol [facts index node]
  (when (= "list" (kind-of index node))
    (symbol-value index (first (ordered-nodes facts node)))))

(defn- unwrap-meta [facts index node]
  (loop [current node depth 0]
    (if (= "#%meta" (head-symbol facts index current))
      (if (= depth 64)
        (reject! :metadata-depth "metadata wrapper depth exceeds 64"
                 {:node node})
        (recur (nth (ordered-nodes facts current) 2 nil) (inc depth)))
      current)))

(defn- unwrap-definition [facts index node]
  (if (= "js/export" (head-symbol facts index node))
    (nth (ordered-nodes facts node) 1 nil)
    node))

(defn- logical-name [facts index node]
  (let [outer (unwrap-meta facts index node)
        leaf (if (= "list" (kind-of index outer))
               (first (ordered-nodes facts outer))
               outer)]
    (symbol-value index (unwrap-meta facts index leaf))))

(defn- module-form-edges [facts module]
  (let [index (object-index facts)
        wrappers (->> facts
                      (map first)
                      (filter #(some? (module-node-int module %)))
                      distinct
                      (filter #(= "beagle-file"
                                  (head-symbol facts index %)))
                      vec)]
    (when-not (= 1 (count wrappers))
      (reject! :module-identity
               (str "module " (pr-str module)
                    " must have exactly one beagle-file wrapper")
               {:module module :wrappers wrappers}))
    {:wrapper (first wrappers)
     :forms (vec (rest (ordered-edges facts (first wrappers))))}))

(defn- definition-name [facts index head children]
  (when (resolve-core/named-def-head? head)
    (logical-name facts index
                  (nth children
                       (resolve-core/type-name-index head
                                                     (symbol-value index
                                                      (nth children 1 nil)))
                       nil))))

(defn- definition-matches [facts module name]
  (let [index (object-index facts)]
    (->> (:forms (module-form-edges facts module))
         (keep
          (fn [{:keys [fact node]}]
            (let [definition (unwrap-definition facts index node)
                  children (ordered-nodes facts definition)
                  head (head-symbol facts index definition)]
              (when (= name (definition-name facts index head children))
                {:form node :definition definition :head head
                 :children children :wrapper-edge fact}))))
         vec)))

(defn- definition-match [facts module name]
  (let [matches (definition-matches facts module name)]
    (when-not (= 1 (count matches))
      (reject! (if (empty? matches)
                 :definition-not-found :ambiguous-definition)
               (str "definition " (pr-str name) " in module "
                    (pr-str module) " matched " (count matches) " forms")
               {:module module :name name
                :definition-ids (mapv :definition matches)}))
    (first matches)))

(defn- brackets? [facts index node]
  (= "#%brackets" (head-symbol facts index node)))

(defn- body-edges [facts name {:keys [definition head children]}]
  (let [index (object-index facts)
        edges (ordered-edges facts definition)
        anchor
        (if (or (contains? executable-heads head)
                (contains? macro-heads head))
          (some (fn [[i node]] (when (brackets? facts index node) i))
                (map-indexed vector children))
          (some (fn [[i node]]
                  (when (= name (logical-name facts index node)) i))
                (map-indexed vector children)))]
    (when (nil? anchor)
      (reject! :definition-shape "definition has no body anchor"
               {:definition definition :name name}))
    (let [after-return (+ anchor 2)
          raises? (and (contains? executable-heads head)
                       (= ":raises"
                          (symbol-value index
                                        (nth children after-return nil))))
          body-start (cond
                       (contains? executable-heads head)
                       (+ anchor (if raises? 4 2))

                       (contains? macro-heads head)
                       (inc anchor)

                       (contains? value-heads head)
                       (dec (count edges))

                       :else
                       (reject! :definition-shape
                                "definition kind has no replaceable body"
                                {:definition definition :name name :head head}))
          _ (when (or (and (contains? executable-heads head)
                           (nil? (nth children (inc anchor) nil)))
                      (and raises?
                           (nil? (nth children (inc after-return) nil)))
                      (>= body-start (count edges)))
              (reject! :definition-shape
                       "definition has no complete signature and body"
                       {:definition definition :name name :head head}))
          body (if (contains? value-heads head)
                 (subvec edges body-start (inc body-start))
                 (subvec edges body-start))]
      (when (empty? body)
        (reject! :definition-shape "definition has no body edges"
                 {:definition definition :name name}))
      {:body-start body-start :body-edges body})))

(defn- reader-meta [datum]
  (when (instance? clojure.lang.IObj datum)
    (not-empty (apply dissoc (meta datum) source-meta-keys))))

(defn- beagle-meta [metadata]
  (cond
    (and (= 1 (count metadata))
         (contains? metadata :tag)
         (symbol? (:tag metadata)))
    (:tag metadata)

    (and (= 1 (count metadata)) (true? (val (first metadata))))
    (key (first metadata))

    :else metadata))

(declare mint-datum)

(defn- mint-leaf [module next-int kind value]
  (let [node (node-name module next-int)]
    {:root node :next-int (inc next-int)
     :facts #{[node "kind" kind] [node "v" value]}}))

(defn- mint-list [module next-int elements]
  (let [root (node-name module next-int)]
    (loop [remaining (vec elements)
           index 0
           cursor (inc next-int)
           facts #{[root "kind" "list"]}]
      (if (empty? remaining)
        {:root root :next-int cursor :facts facts}
        (let [child (mint-datum module cursor (first remaining))]
          (recur (subvec remaining 1)
                 (inc index)
                 (:next-int child)
                 (into (conj facts [root (str "f" index) (:root child)])
                       (:facts child))))))))

(defn- mint-datum [module next-int datum]
  (if-let [metadata (reader-meta datum)]
    (mint-datum module next-int
                (list (symbol "#%meta")
                      (beagle-meta metadata)
                      (with-meta datum nil)))
    (cond
      (nil? datum) (mint-leaf module next-int "symbol" "nil")
      (symbol? datum) (mint-leaf module next-int "symbol" (str datum))
      (keyword? datum) (mint-leaf module next-int "symbol" (str datum))
      (string? datum) (mint-leaf module next-int "string" datum)
      (boolean? datum) (mint-leaf module next-int "symbol"
                                  (if datum "true" "false"))
      (char? datum) (mint-leaf module next-int "char" (str datum))
      (number? datum) (mint-leaf module next-int "number" (str datum))
      (vector? datum) (mint-list module next-int
                                 (into [(symbol "#%brackets")] datum))
      (map? datum) (mint-list module next-int
                              (into [(symbol "#%map")]
                                    (apply concat (seq datum))))
      (instance? java.util.regex.Pattern datum)
      (mint-list module next-int [(symbol "#%regex") (.pattern datum)])
      (set? datum) (mint-list module next-int
                              (into [(symbol "#%set")] datum))
      (or (list? datum) (seq? datum))
      (mint-list module next-int datum)
      :else (mint-leaf module next-int "other" (pr-str datum)))))

(defn- validate-input! [snapshot edits]
  (when-not (map? snapshot)
    (reject! :invalid-snapshot "snapshot must be a map" {}))
  (when (str/blank? (str (:module snapshot)))
    (reject! :invalid-snapshot "snapshot :module is required" {}))
  (when-not (set? (:facts snapshot))
    (reject! :invalid-snapshot "snapshot :facts must be an immutable set"
             {:module (:module snapshot)}))
  (when-not (every? #(and (vector? %) (= 3 (count %))) (:facts snapshot))
    (reject! :invalid-snapshot "every snapshot fact must be a triple vector"
             {:module (:module snapshot)}))
  (when-not (vector? edits)
    (reject! :invalid-edits "edits must be a vector" {}))
  (when-not (<= 2 (count edits) max-edits)
    (reject! :invalid-edits
             (str "multi-set-body requires 2.." max-edits " edits")
             {:count (count edits)}))
  (doseq [[index edit] (map-indexed vector edits)]
    (when-not (and (map? edit)
                   (string? (:name edit))
                   (not (str/blank? (:name edit)))
                   (contains? edit :body))
      (reject! :invalid-edit "each edit requires nonblank :name and :body"
               {:index index})))
  (let [names (mapv :name edits)]
    (when-not (= (count names) (count (set names)))
      (reject! :duplicate-definition
               "every edit must target a distinct definition"
               {:names names}))))

(defn multi-set-body
  "Build a pure multi-definition body-edit candidate from one immutable module snapshot."
  [snapshot edits]
  (validate-input! snapshot edits)
  (let [module (:module snapshot)
        base (:facts snapshot)
        first-int (next-node-int base module)
        staged
        (reduce
         (fn [{:keys [facts next-int identities]} {:keys [name body]}]
           (let [match (definition-match facts module name)
                 {:keys [body-start body-edges]} (body-edges facts name match)
                 minted (mint-datum module next-int body)
                 retracts (set (map :fact body-edges))
                 asserts (conj (:facts minted)
                               [(:definition match) (str "f" body-start)
                                (:root minted)])]
             {:facts (-> facts (set/difference retracts) (set/union asserts))
              :next-int (:next-int minted)
              :identities (conj identities
                                {:name name
                                 :form (:form match)
                                 :definition (:definition match)})}))
         {:facts base :next-int first-int :identities []}
         edits)
        candidate (:facts staged)]
    {:base-version (:version snapshot)
     :module module
     :definition-identities (:identities staged)
     :ast candidate
     :asserts (set/difference candidate base)
     :retracts (set/difference base candidate)
     :next-node-int (:next-int staged)}))

(defn- top-level-form! [form]
  (when-not (and (seq? form)
                 (resolve-core/named-def-head? (str (first form))))
    (reject! :invalid-top-level-definition
             "form must be one named writable top-level definition"
             {:form form}))
  (let [name (resolve-core/named-form-name form)]
    (when (str/blank? name)
      (reject! :invalid-top-level-definition
               "form must carry one named top-level definition" {:form form}))
    {:name name :form form}))

(defn- append-position [facts wrapper]
  (resolve-core/ord-str
   (resolve-core/ord-append
    (some-> (last (ordered-edges facts wrapper)) :key first))
   0))

(defn top-level-def
  "Build an add-only or replace-only top-level definition candidate."
  [snapshot mode form]
  (when-not (map? snapshot)
    (reject! :invalid-snapshot "snapshot must be a map" {}))
  (when-not (contains? #{:add :replace} mode)
    (reject! :invalid-top-level-mode
             "top-level definition mode must be :add or :replace" {:mode mode}))
  (let [{:keys [name form]} (top-level-form! form)
        module (:module snapshot)
        base (:facts snapshot)]
    (when (str/blank? (str module))
      (reject! :invalid-snapshot "snapshot :module is required" {}))
    (when-not (and (set? base)
                   (every? #(and (vector? %) (= 3 (count %))) base))
      (reject! :invalid-snapshot
               "snapshot :facts must be an immutable set of triple vectors"
               {:module module}))
    (let [matches (definition-matches base module name)]
      (when (and (= :add mode) (seq matches))
        (reject! :definition-already-exists
                 (str "definition " (pr-str name) " already exists in module "
                      (pr-str module))
                 {:module module :name name}))
      (when (and (= :replace mode) (empty? matches))
        (reject! :definition-not-found
                 (str "definition " (pr-str name) " was not found in module "
                      (pr-str module))
                 {:module module :name name}))
      (when (> (count matches) 1)
        (reject! :ambiguous-definition
                 (str "definition " (pr-str name) " in module "
                      (pr-str module) " matched " (count matches) " forms")
                 {:module module :name name
                  :definition-ids (mapv :definition matches)}))
      (let [{:keys [wrapper]} (module-form-edges base module)
            victim (first matches)
            minted (mint-datum module (next-node-int base module) form)
            old-edge (:wrapper-edge victim)
            position (if old-edge (second old-edge)
                         (append-position base wrapper))
            new-edge [wrapper position (:root minted)]
            candidate (cond-> (set/union base (:facts minted) #{new-edge})
                        old-edge (disj old-edge))]
        {:base-version (:version snapshot)
         :module module
         :definition-identities [{:name name
                                  :form (:form victim)
                                  :definition (:definition victim)}]
         :ast candidate
         :asserts (set/difference candidate base)
         :retracts (set/difference base candidate)
         :next-node-int (:next-int minted)}))))
