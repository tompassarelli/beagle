(ns rename
  (:require [fram.store :as c]
            [fram.types :as t]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(def ^String space-id "codegraph")

(def ^String value-pred "v")

(def ^String kind-pred "kind")

(def ^String symbol-kind "symbol")

(def binding-heads #{"defn" "definline" "def-" "defonce" "defn-" "def"})

(defn seen-node [state node]
  (if (contains? (:seen state) node) state (assoc state :seen (conj (:seen state) node) :nodes (conj (vec (:nodes state)) node))))

(defn load-lines [offset lines]
  (reduce (fn [state ^String line] (if (str/starts-with? line "[") (let [trip (edn/read-string line)
   l (+ offset (int (nth trip 0)))
   p (nth trip 1)
   o (nth trip 2)
   node-ref? (integer? o)
   r (if node-ref? (+ offset (int o)) o)
   with-l (seen-node state l)
   with-r (if node-ref? (seen-node with-l r) with-l)]
  (assoc with-r :operations (conj (vec (:operations with-r)) (c/assert-operation (t/triple l p r))) :top (max (int (:top with-r)) l (if node-ref? (int r) 0)))) state)) {:seen #{} :nodes [] :operations [] :top 0} lines))

(defn ^String load-edn! [ctx file->nodes next-offset ^String path]
  (let [lines (str/split-lines (slurp path))
   heads (filterv (fn [^String l] (str/starts-with? l "@file")) lines)
   src (subs (nth heads 0) 6)
   loaded (load-lines (deref next-offset) lines)]
  (swap! file->nodes assoc src (vec (:nodes loaded)))
  (reset! next-offset (inc (int (:top loaded))))
  (if (pos? (count (vec (:operations loaded)))) (do
  (c/commit-transaction! ctx (vec (:operations loaded)))))
  src))

(defn live-index [ctx]
  (group-by (fn [p] (t/triple-t1 p)) (c/live-propositions ctx)))

(defn propositions-of [index node]
  (vec (get index node [])))

(defn ^Boolean symbol-leaf? [index node]
  (pos? (count (filterv (fn [p] (and (= kind-pred (t/triple-t2 p)) (= symbol-kind (t/triple-t3 p)))) (propositions-of index node)))))

(defn field-child [index node ^String fname]
  (let [hits (filterv (fn [p] (= fname (t/triple-t2 p))) (propositions-of index node))]
  (if (empty? hits) 0 (let [child (t/triple-t3 (nth hits 0))]
  (if (integer? child) (int child) 0)))))

(defn sym-val [index node]
  (if (and (> (int node) 0) (symbol-leaf? index node)) (let [hits (filterv (fn [p] (= value-pred (t/triple-t2 p))) (propositions-of index node))]
  (if (empty? hits) nil (t/triple-t3 (nth hits 0)))) nil))

(defn binding-name [index node]
  (let [h (sym-val index (field-child index node "f0"))]
  (if (and (not (nil? h)) (contains? binding-heads h)) (sym-val index (field-child index node "f1")) nil)))

(defn module-bindings [index file->nodes ^String src]
  (set (filterv (fn [nm] (not (nil? nm))) (mapv (fn [node] (binding-name index node)) (vec (get (deref file->nodes) src []))))))

(defn rename-operations [index ^String new-name target-nodes propositions]
  (vec (mapcat (fn [p] (let [node (t/triple-t1 p)]
  (if (and (contains? target-nodes node) (symbol-leaf? index node)) [(c/retract-operation p) (c/assert-operation (t/triple node (t/triple-t2 p) new-name))] []))) propositions)))

(defn ^String project-line [proposition]
  (let [node (t/triple-t1 proposition)
   p (t/triple-t2 proposition)
   r (t/triple-t3 proposition)]
  (if (integer? r) (str "[" node " " (pr-str p) " " r "]\n") (str "[" node " " (pr-str p) " " (pr-str r) "]\n"))))

(defn project-file! [index file->nodes ^String src ^String out-path]
  (spit out-path (str (str "@file " src "\n") (str/join "" (mapv (fn [node] (str/join "" (mapv (fn [p] (project-line p)) (propositions-of index node)))) (vec (get (deref file->nodes) src []))))))
  nil)

(defn ^String out-path [^String src]
  (let [parts (str/split src (re-pattern "/"))]
  (str "/tmp/mutated-" (nth parts (dec (count parts))) ".edn")))

(defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  (let [argv (vec args)
   old-name (str (nth argv 0))
   new-name (str (nth argv 1))
   target-substr (str (nth argv 2))
   edn-files (vec (drop 3 argv))
   ctx (c/new-term-store space-id)
   file->nodes (atom {})
   next-offset (atom 0)
   srcs (mapv (fn [p] (load-edn! ctx file->nodes next-offset (str p))) edn-files)
   index (live-index ctx)
   target-modules (filterv (fn [^String s] (str/includes? s target-substr)) srcs)
   target-nodes (set (vec (mapcat (fn [^String s] (vec (get (deref file->nodes) s []))) target-modules)))
   collisions (filterv (fn [^String m] (contains? (module-bindings index file->nodes m) new-name)) target-modules)]
  (if (pos? (count collisions)) (do
  (let [m (nth collisions 0)]
  (binding [*out* *err*]
  (println (str "REJECTED — `" new-name "` is already a binding in " m ".\n" "  A rename onto an existing binding would shadow/collide; the store refuses the write.\n" "  (Turtle #5 invariant: rename-doesn't-collide. No propositions were mutated.)")))
  (System/exit 3))))
  (let [targets (filterv (fn [p] (and (= value-pred (t/triple-t2 p)) (= old-name (t/triple-t3 p)))) (c/live-propositions ctx))
   operations (rename-operations index new-name target-nodes targets)
   renamed (quot (count operations) 2)
   preserved (count (filterv (fn [p] (let [node (t/triple-t1 p)]
  (and (not (contains? target-nodes node)) (symbol-leaf? index node)))) targets))
   _edit (if (pos? (count operations)) (do
  (c/commit-transaction! ctx operations)))
   projected (live-index ctx)
   outs (mapv (fn [^String s] (out-path s)) srcs)]
  (doseq [i (range (count srcs))]
  (project-file! projected file->nodes (nth srcs i) (nth outs i)))
  (binding [*out* *err*]
  (println "================ TURTLE #4 — graph-native rename ================")
  (println (str "edit: rename symbol `" old-name "` -> `" new-name "` in files matching \"" target-substr "\""))
  (println (str "renamed (target file): " renamed " symbol occurrences"))
  (println (str "preserved (other files, same name, untouched): " preserved " occurrences"))
  (println (str "withdrawn assertions (recoverable, nothing deleted): " renamed))
  (println (str "live propositions in store: " (count (c/live-propositions ctx))))
  (doseq [i (range (count srcs))]
  (println (str "projected -> " (nth outs i) "   <- " (nth srcs i)))))))))
