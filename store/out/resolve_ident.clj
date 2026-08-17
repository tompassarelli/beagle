(ns resolve-ident
  (:require [store.types :as t]
            [store.store :as c]
            [store.rotation :as rot]
            [store.txn :as txn]))

(def no-occurrences [])

(def no-ordinals {})

(defn ^Boolean minted-node-id? [x]
  (txn/mint-coordinate? x))

(defn ^Boolean literal? [x]
  (not (minted-node-id? x)))

(defn literal! [x]
  (if (minted-node-id? x) (throw (ex-info "resolve: a code-graph literal may not be shaped like a node identity" {:type :ambiguous-code-literal :value x})) x))

(defrecord Graph [store view writers ordinals])

(defn graph-store [r] (:store r))

(defn graph-view [r] (:view r))

(defn graph-writers [r] (:writers r))

(defn graph-ordinals [r] (:ordinals r))

(defn ^Graph graph! [store writers]
  (->Graph store (atom (rot/project! store)) writers (atom no-ordinals)))

(defn ^Graph new-graph! [^String space-id]
  (graph! (c/new-term-store space-id) {}))

(defn store-of [^Graph g]
  (graph-store g))

(defn writers-of [^Graph g]
  (graph-writers g))

(defn view [^Graph g]
  (deref (graph-view g)))

(defn ^Graph refresh! [^Graph g]
  (do
  (reset! (graph-view g) (rot/refresh! (view g) (graph-store g)))
  g))

(defn ^Graph with-view! [^Graph g rotation]
  (do
  (reset! (graph-view g) rotation)
  g))

(defn ordinal! [^Graph g node]
  (let [book (deref (graph-ordinals g))
   hit (get book node)]
  (if (some? hit) hit (let [n (+ 1 (count book))]
  (do
  (swap! (graph-ordinals g) assoc node n)
  n)))))

(defn by-subject [^Graph g subject]
  (rot/occurrences (rot/by-t1 (view g) subject)))

(defn by-subject-predicate [^Graph g subject predicate]
  (rot/occurrences (rot/by-t12 (view g) subject predicate)))

(defn by-predicate [^Graph g predicate]
  (rot/occurrences (rot/by-t2 (view g) predicate)))

(defn by-predicate-value [^Graph g predicate value]
  (rot/occurrences (rot/by-t23 (view g) predicate value)))

(defn proposition-at [^Graph g occurrence]
  (let [event (rot/event-at (view g) occurrence)]
  (if (nil? event) nil (t/operationoccurrence-proposition event))))

(defn subject-at [^Graph g occurrence]
  (let [p (proposition-at g occurrence)]
  (if (nil? p) nil (t/triple-t1 p))))

(defn predicate-at [^Graph g occurrence]
  (let [p (proposition-at g occurrence)]
  (if (nil? p) nil (t/triple-t2 p))))

(defn value-at [^Graph g occurrence]
  (let [p (proposition-at g occurrence)]
  (if (nil? p) nil (t/triple-t3 p))))

(defn target-at [^Graph g occurrence]
  (let [r (if (nil? occurrence) nil (value-at g occurrence))]
  (if (minted-node-id? r) r nil)))

(defn live-propositions [^Graph g]
  (rot/propositions (rot/all-occurrences (view g))))

(defn ^Boolean live? [^Graph g occurrence]
  (rot/live-occurrence? (view g) occurrence))

(defn occurrence-order [occurrence]
  (if (t/occurrence-coordinate? occurrence) [(t/triple-t3 (t/triple-t1 occurrence)) (t/triple-t3 occurrence)] (throw (ex-info "resolve: occurrence coordinate required" {:type :invalid-occurrence-coordinate :value occurrence}))))

(defn ^String writer-of [^Graph g occurrence]
  (if (t/occurrence-coordinate? occurrence) (let [hit (get (graph-writers g) (t/triple-t1 occurrence))]
  (if (nil? hit) "" (str hit))) (throw (ex-info "resolve: occurrence coordinate required" {:type :invalid-occurrence-coordinate :value occurrence}))))

(defn minted-count [^Graph g]
  (count (deref (graph-ordinals g))))

(defn withdrawal-count [^Graph g]
  (count (c/withdrawals (graph-store g))))

(defn open [^Graph g]
  (txn/open (graph-store g)))

(defn mint! [^Graph g b]
  (let [node (txn/mint! b)]
  (do
  (ordinal! g node)
  node)))

(defn assert-on! [b subject predicate value]
  (txn/assert! b (t/triple subject predicate value)))

(defn retract-on! [^Graph g b occurrence]
  (let [p (proposition-at g occurrence)]
  (if (nil? p) nil (txn/retract! b p))))

(defn ^Graph commit! [^Graph g b]
  (do
  (if (pos? (txn/operation-count b)) (do
  (txn/commit! (graph-store g) b)))
  (refresh! g)))

(defn assert! [^Graph g subject predicate value]
  (let [b (open g)
   occurrence (assert-on! b subject predicate value)]
  (do
  (commit! g b)
  occurrence)))

(defn retire! [^Graph g occurrence]
  (let [b (open g)
   target (retract-on! g b occurrence)]
  (do
  (commit! g b)
  target)))
