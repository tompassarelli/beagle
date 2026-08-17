;; Covering slot rotations over live assertion occurrences.
;;
;; FRI2 owns the persisted, source-bound Term/Triple tables and slot indexes.
;; This namespace is a disposable in-memory projection rebuilt from those
;; occurrence records. It never assigns another identity or owns log history.
(ns rotations
  (:require [store.types :as t]
            [fri :as fri]))

(defrecord RotationSet [image index])
(defrecord RotationSummary
  [space-id source-fingerprint source-position occurrences])

(def empty-index
  {:events []
   :event-set #{}
   :t1 {} :t2 {} :t3 {}
   :t12 {} :t23 {} :t13 {}
   :novelty []
   :watermark -1})

(defn- assertion! [event]
  (if (t/assertion-occurrence? event)
    event
    (throw (ex-info "rotations: expected an assertion occurrence"
                    {:type :invalid-rotation-occurrence}))))

(defn- proposition [event]
  (t/operationoccurrence-proposition (assertion! event)))

(defn- bucket-add [buckets key event]
  (assoc buckets key (conj (get buckets key []) event)))

(defn- remove-event [events target]
  (vec (remove #(= target %) events)))

(defn- bucket-del [buckets key event]
  (let [remaining (remove-event (get buckets key []) event)]
    (if (empty? remaining)
      (dissoc buckets key)
      (assoc buckets key remaining))))

(defn add
  "Add one exact assertion occurrence to all six covering slot buckets."
  [index event]
  (assertion! event)
  (if (contains? (:event-set index) event)
    index
    (let [triple (proposition event)
          t1 (t/triple-t1 triple)
          t2 (t/triple-t2 triple)
          t3 (t/triple-t3 triple)]
      (-> index
          (update :events conj event)
          (update :event-set conj event)
          (update :t1 bucket-add t1 event)
          (update :t2 bucket-add t2 event)
          (update :t3 bucket-add t3 event)
          (update :t12 bucket-add [t1 t2] event)
          (update :t23 bucket-add [t2 t3] event)
          (update :t13 bucket-add [t1 t3] event)))))

(defn del
  "Remove one exact occurrence. Equal propositions at other coordinates remain."
  [index event]
  (assertion! event)
  (if-not (contains? (:event-set index) event)
    index
    (let [triple (proposition event)
          t1 (t/triple-t1 triple)
          t2 (t/triple-t2 triple)
          t3 (t/triple-t3 triple)]
      (-> index
          (update :events remove-event event)
          (update :event-set disj event)
          (update :t1 bucket-del t1 event)
          (update :t2 bucket-del t2 event)
          (update :t3 bucket-del t3 event)
          (update :t12 bucket-del [t1 t2] event)
          (update :t23 bucket-del [t2 t3] event)
          (update :t13 bucket-del [t1 t3] event)))))

(defn build
  "Build a covering index from live assertion occurrences."
  [events]
  (reduce add empty-index events))

(defn build-from-fri [image] (build (fri/live-occurrences image)))
(defn build-from-fri-as-of [image sequence]
  (build (fri/live-occurrences-as-of image sequence)))

(defn occurrence-count [index] (count (:events index)))

;; Every bound subset of t1/t2/t3 has one exact bucket. Results are
;; occurrence events, so equal propositions at distinct coordinates survive.
(defn matching [index [t1 t2 t3]]
  (cond
    (and (some? t1) (and (some? t2) (some? t3)))
    (filterv #(= (t/triple t1 t2 t3) (proposition %)) (:events index))

    (and (some? t1) (some? t2)) (get (:t12 index) [t1 t2] [])
    (and (some? t2) (some? t3)) (get (:t23 index) [t2 t3] [])
    (and (some? t1) (some? t3)) (get (:t13 index) [t1 t3] [])
    (some? t1) (get (:t1 index) t1 [])
    (some? t2) (get (:t2 index) t2 [])
    (some? t3) (get (:t3 index) t3 [])
    :else (:events index)))

(defn matching-propositions [index pattern]
  (mapv proposition (matching index pattern)))

(defn note-add [index event version]
  (assertion! event)
  (-> index
      (update :novelty conj [:add event version])
      (assoc :watermark (max (long (:watermark index)) (long version)))))

(defn note-del [index event version]
  (assertion! event)
  (-> index
      (update :novelty conj [:del event version])
      (assoc :watermark (max (long (:watermark index)) (long version)))))

(defn novelty-count [index] (count (:novelty index)))
(defn drain-novelty [index] (assoc index :novelty []))

;; Rotation persistence is deliberately the same FRI2 artifact. This prevents a
;; second dictionary, watermark, or cache identity from becoming authoritative.
(defn index-path [canonical-log] (str canonical-log ".fri2"))

(defn write-set! [path dump source]
  (fri/write-fri! dump path source))

(defn open-set! [path source]
  (let [image (fri/open-fri! path source)]
    (->RotationSet image (build-from-fri image))))

(defn close-set! [opened]
  (fri/close-fri! (:image opened)))

(defn set-summary [opened]
  (->RotationSummary
   (fri/space-id (:image opened))
   (fri/source-fingerprint (:image opened))
   (fri/source-position (:image opened))
   (occurrence-count (:index opened))))
