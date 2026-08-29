(ns store.revision-generation)

(defrecord RevisionSet [source program state])

(defn revisionset-source [r] (:source r))

(defn revisionset-program [r] (:program r))

(defn revisionset-state [r] (:state r))

(defrecord RevisionGeneration [revisions state-bytes])

(defn revisiongeneration-revisions [r] (:revisions r))

(defn revisiongeneration-state-bytes [r] (:state-bytes r))

(defn ^RevisionSet revision-set [^String source ^String program ^String state]
  (->RevisionSet source program state))

(defn ^Boolean revisions-match? [^RevisionSet expected ^RevisionSet actual]
  (and (= (revisionset-source expected) (revisionset-source actual)) (= (revisionset-program expected) (revisionset-program actual)) (= (revisionset-state expected) (revisionset-state actual))))

(defn hydrate-generation [^RevisionSet expected ^RevisionSet actual ^String state-bytes]
  (let [^RevisionGeneration candidate (->RevisionGeneration actual (str state-bytes ""))]
  (if (revisions-match? expected actual) candidate nil)))

(defn ^String generation-source-revision [^RevisionGeneration generation]
  (revisionset-source (revisiongeneration-revisions generation)))

(defn ^String generation-program-revision [^RevisionGeneration generation]
  (revisionset-program (revisiongeneration-revisions generation)))

(defn ^String generation-state-revision [^RevisionGeneration generation]
  (revisionset-state (revisiongeneration-revisions generation)))

(defn ^String generation-state-bytes [^RevisionGeneration generation]
  (revisiongeneration-state-bytes generation))

(defn generation-byte-count [^RevisionGeneration generation]
  (count (revisiongeneration-state-bytes generation)))
