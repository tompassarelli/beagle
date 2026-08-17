(ns store.rotation
  (:require [store.types :as t]
            [store.store :as store]))

(defrecord KeyOne [a])

(defn keyone-a [r] (:a r))

(defrecord KeyTwo [a b])

(defn keytwo-a [r] (:a r))

(defn keytwo-b [r] (:b r))

(defrecord Bucket [width codes events heads chain])

(defn bucket-width [r] (:width r))

(defn bucket-codes [r] (:codes r))

(defn bucket-events [r] (:events r))

(defn bucket-heads [r] (:heads r))

(defn bucket-chain [r] (:chain r))

(defrecord OccurrenceIndex [width heads chain])

(defn occurrenceindex-width [r] (:width r))

(defn occurrenceindex-heads [r] (:heads r))

(defn occurrenceindex-chain [r] (:chain r))

(defrecord Rotation [space-id version events by-occurrence spo pos osp pending])

(defn rotation-space-id [r] (:space-id r))

(defn rotation-version [r] (:version r))

(defn rotation-events [r] (:events r))

(defn rotation-by-occurrence [r] (:by-occurrence r))

(defn rotation-spo [r] (:spo r))

(defn rotation-pos [r] (:pos r))

(defn rotation-osp [r] (:osp r))

(defn rotation-pending [r] (:pending r))

(def empty-events [])

(def empty-event-lists [])

(def empty-ints [])

(def no-pending [])

(def bucket-initial-slots 64)

(def bucket-slot-load 4)

(def pending-fold-cap 512)

(def shape-t1 0)

(def shape-t12 1)

(def shape-t2 2)

(def shape-t3 3)

(def shape-mask 3)

(def shape-bits 2)

(defn occurrence-of [event]
  (t/operationoccurrence-coordinate event))

(defn proposition-of [event]
  (t/operationoccurrence-proposition event))

(defn ^Boolean assertion-occurrence? [event]
  (t/assertion-occurrence? event))

(defn- hash-one [a]
  (hash (->KeyOne a)))

(defn- hash-two [a b]
  (hash (->KeyTwo a b)))

(defn- shape-hash [shape event]
  (let [proposition (proposition-of event)]
  (cond
  (= shape shape-t1) (hash-one (t/triple-t1 proposition))
  (= shape shape-t12) (hash-two (t/triple-t1 proposition) (t/triple-t2 proposition))
  (= shape shape-t2) (hash-one (t/triple-t2 proposition))
  :else (hash-one (t/triple-t3 proposition)))))

(defn- ^Boolean same-shape-key? [shape left right]
  (let [lp (proposition-of left)
   rp (proposition-of right)]
  (cond
  (= shape shape-t1) (= (t/triple-t1 lp) (t/triple-t1 rp))
  (= shape shape-t12) (and (= (t/triple-t1 lp) (t/triple-t1 rp)) (= (t/triple-t2 lp) (t/triple-t2 rp)))
  (= shape shape-t2) (= (t/triple-t2 lp) (t/triple-t2 rp))
  :else (= (t/triple-t3 lp) (t/triple-t3 rp)))))

(defn- key-code [position shape]
  (bit-or (bit-shift-left position shape-bits) shape))

(defn- code-position [code]
  (unsigned-bit-shift-right code shape-bits))

(defn- code-shape [code]
  (bit-and code shape-mask))

(defn- shape-term [shape event]
  (let [proposition (proposition-of event)]
  (cond
  (= shape shape-t1) (t/triple-t1 proposition)
  (= shape shape-t2) (t/triple-t2 proposition)
  :else (t/triple-t3 proposition))))

(defn- bucket-leaf-one [^Bucket bucket source shape a]
  (let [codes (bucket-codes bucket)
   chain (bucket-chain bucket)]
  (loop [key (nth (bucket-heads bucket) (mod (hash-one a) (bucket-width bucket)))]
  (if (< key 0) empty-events (let [code (nth codes key)]
  (if (and (= shape (code-shape code)) (= a (shape-term shape (nth source (code-position code))))) (nth (bucket-events bucket) key) (recur (nth chain key))))))))

(defn- bucket-leaf-two [^Bucket bucket source a b]
  (let [codes (bucket-codes bucket)
   chain (bucket-chain bucket)]
  (loop [key (nth (bucket-heads bucket) (mod (hash-two a b) (bucket-width bucket)))]
  (if (< key 0) empty-events (let [code (nth codes key)]
  (if (and (= shape-t12 (code-shape code)) (let [proposition (proposition-of (nth source (code-position code)))]
  (and (= a (t/triple-t1 proposition)) (= b (t/triple-t2 proposition))))) (nth (bucket-events bucket) key) (recur (nth chain key))))))))

(defn- occurrence-event [^OccurrenceIndex index source occurrence]
  (let [chain (occurrenceindex-chain index)]
  (loop [position (nth (occurrenceindex-heads index) (mod (hash-one occurrence) (occurrenceindex-width index)))]
  (if (< position 0) nil (let [event (nth source position)]
  (if (= occurrence (occurrence-of event)) event (recur (nth chain position))))))))

(defn- ^Boolean slot-matches? [pattern term]
  (or (nil? pattern) (= pattern term)))

(defn- ^Boolean pattern-match? [proposition t1 t2 t3]
  (and (slot-matches? t1 (t/triple-t1 proposition)) (and (slot-matches? t2 (t/triple-t2 proposition)) (slot-matches? t3 (t/triple-t3 proposition)))))

(defn- narrowed [base t1 t2 t3]
  (let [kept (loop [position 0
   total 0]
  (if (>= position (count base)) total (recur (inc position) (if (pattern-match? (proposition-of (nth base position)) t1 t2 t3) (inc total) total))))]
  (if (= kept (count base)) base (loop [built empty-events
   position 0]
  (if (>= position (count base)) built (recur (if (pattern-match? (proposition-of (nth base position)) t1 t2 t3) (conj built (nth base position)) built) (inc position)))))))

(defn- without-newest-of [events proposition]
  (let [at (loop [position (dec (count events))]
  (if (< position 0) -1 (if (= proposition (proposition-of (nth events position))) position (recur (dec position)))))]
  (if (< at 0) events (loop [built empty-events
   position 0]
  (if (>= position (count events)) built (recur (if (= position at) built (conj built (nth events position))) (inc position)))))))

(defn- merged-matching [base pending t1 t2 t3]
  (if (empty? pending) base (loop [events base
   position 0]
  (if (>= position (count pending)) events (let [op (nth pending position)
   proposition (proposition-of op)]
  (recur (if (= t/assert-action (t/operationoccurrence-action op)) (if (pattern-match? proposition t1 t2 t3) (conj events op) events) (without-newest-of events proposition)) (inc position)))))))

(defn ^String space-id [^Rotation rotation]
  (rotation-space-id rotation))

(defn version [^Rotation rotation]
  (rotation-version rotation))

(defn all-occurrences [^Rotation rotation]
  (merged-matching (rotation-events rotation) (rotation-pending rotation) nil nil nil))

(defn occurrence-count [^Rotation rotation]
  (count (all-occurrences rotation)))

(defn by-t1 [^Rotation rotation t1]
  (merged-matching (bucket-leaf-one (rotation-spo rotation) (rotation-events rotation) shape-t1 t1) (rotation-pending rotation) t1 nil nil))

(defn by-t12 [^Rotation rotation t1 t2]
  (merged-matching (bucket-leaf-two (rotation-spo rotation) (rotation-events rotation) t1 t2) (rotation-pending rotation) t1 t2 nil))

(defn by-t2 [^Rotation rotation t2]
  (merged-matching (bucket-leaf-one (rotation-pos rotation) (rotation-events rotation) shape-t2 t2) (rotation-pending rotation) nil t2 nil))

(defn by-t23 [^Rotation rotation t2 t3]
  (merged-matching (narrowed (bucket-leaf-one (rotation-osp rotation) (rotation-events rotation) shape-t3 t3) nil t2 nil) (rotation-pending rotation) nil t2 t3))

(defn by-t3 [^Rotation rotation t3]
  (merged-matching (bucket-leaf-one (rotation-osp rotation) (rotation-events rotation) shape-t3 t3) (rotation-pending rotation) nil nil t3))

(defn by-t13 [^Rotation rotation t1 t3]
  (merged-matching (narrowed (bucket-leaf-one (rotation-osp rotation) (rotation-events rotation) shape-t3 t3) t1 nil nil) (rotation-pending rotation) t1 nil t3))

(defn by-proposition [^Rotation rotation proposition]
  (merged-matching (narrowed (bucket-leaf-two (rotation-spo rotation) (rotation-events rotation) (t/triple-t1 proposition) (t/triple-t2 proposition)) nil nil (t/triple-t3 proposition)) (rotation-pending rotation) (t/triple-t1 proposition) (t/triple-t2 proposition) (t/triple-t3 proposition)))

(defn matching [^Rotation rotation t1 t2 t3]
  (cond
  (and (some? t1) (and (some? t2) (some? t3))) (by-proposition rotation (t/triple t1 t2 t3))
  (and (some? t1) (some? t2)) (by-t12 rotation t1 t2)
  (and (some? t2) (some? t3)) (by-t23 rotation t2 t3)
  (and (some? t1) (some? t3)) (by-t13 rotation t1 t3)
  (some? t1) (by-t1 rotation t1)
  (some? t2) (by-t2 rotation t2)
  (some? t3) (by-t3 rotation t3)
  :else (all-occurrences rotation)))

(defn event-at [^Rotation rotation occurrence]
  (let [base (occurrence-event (rotation-by-occurrence rotation) (rotation-events rotation) occurrence)
   candidate (let [pending (rotation-pending rotation)]
  (loop [position 0
   found base]
  (if (>= position (count pending)) found (let [op (nth pending position)]
  (recur (inc position) (if (and (= t/assert-action (t/operationoccurrence-action op)) (= occurrence (occurrence-of op))) op found))))))]
  (if (nil? candidate) nil (let [present candidate
   live (by-proposition rotation (proposition-of present))
   survives (loop [position 0]
  (if (>= position (count live)) false (if (= occurrence (occurrence-of (nth live position))) true (recur (inc position)))))]
  (if survives present nil)))))

(defn ^Boolean live-occurrence? [^Rotation rotation occurrence]
  (some? (event-at rotation occurrence)))

(defn newest-first [events]
  (vec (reverse events)))

(defn newest [events]
  (if (empty? events) nil (last events)))

(defn propositions [events]
  (mapv (fn [event] (proposition-of event)) events))

(defn subjects [events]
  (mapv (fn [event] (t/triple-t1 (proposition-of event))) events))

(defn values [events]
  (mapv (fn [event] (t/triple-t3 (proposition-of event))) events))

(defn occurrences [events]
  (mapv (fn [event] (occurrence-of event)) events))

(def empty-event-cells [])

(def empty-head-cells [])

(defn- fresh-head-cells [width]
  (loop [cells empty-head-cells
   position 0]
  (if (>= position width) cells (recur (conj cells (atom -1)) (inc position)))))

(defn- frozen-heads [cells]
  (loop [rows empty-ints
   position 0]
  (if (>= position (count cells)) rows (recur (conj rows (deref (nth cells position))) (inc position)))))

(defn- close-event-cells [cells]
  (loop [lists empty-event-lists
   position 0]
  (if (>= position (count cells)) lists (recur (conj lists (deref (nth cells position))) (inc position)))))

(defn- relinked-chain! [codes source heads width]
  (loop [chain empty-ints
   key 0]
  (if (>= key (count codes)) chain (let [code (nth codes key)
   slot (mod (shape-hash (code-shape code) (nth source (code-position code))) width)
   linked (conj chain (deref (nth heads slot)))]
  (do
  (reset! (nth heads slot) key)
  (recur linked (inc key)))))))

(defn- checked-assertion [event]
  (if (assertion-occurrence? event) event (throw (ex-info "store: rotations cover assertion occurrences only" {:type :invalid-rotation-occurrence}))))

(defn- initial-bucket-width [event-count]
  (loop [width bucket-initial-slots]
  (if (>= (* bucket-slot-load width) event-count) width (recur (* 2 width)))))

(defn- bucket-key-at [codes chain heads source slot shape event]
  (loop [key (deref (nth heads slot))]
  (if (< key 0) -1 (let [code (nth codes key)]
  (if (and (= shape (code-shape code)) (same-shape-key? shape event (nth source (code-position code)))) key (recur (nth chain key)))))))

(defn- ^Bucket projected-bucket! [events first-shape last-shape initial-width]
  (loop [width initial-width
   codes empty-ints
   cells empty-event-cells
   chain empty-ints
   heads (fresh-head-cells initial-width)
   position 0
   shape first-shape]
  (if (>= position (count events)) (->Bucket width codes (close-event-cells cells) (frozen-heads heads) chain) (if (> shape last-shape) (recur width codes cells chain heads (inc position) first-shape) (let [event (checked-assertion (nth events position))
   slot (mod (shape-hash shape event) width)
   at (bucket-key-at codes chain heads events slot shape event)]
  (if (>= at 0) (do
  (swap! (nth cells at) conj event)
  (recur width codes cells chain heads position (inc shape))) (let [appended (count codes)
   grown-codes (conj codes (key-code position shape))
   grown-cells (conj cells (atom [event]))
   grown-chain (conj chain (deref (nth heads slot)))]
  (do
  (reset! (nth heads slot) appended)
  (if (> (count grown-codes) (* bucket-slot-load width)) (let [widened (* 2 width)
   fresh (fresh-head-cells widened)
   relinked (relinked-chain! grown-codes events fresh widened)]
  (recur widened grown-codes grown-cells relinked fresh position (inc shape))) (recur width grown-codes grown-cells grown-chain heads position (inc shape)))))))))))

(defn- ^OccurrenceIndex projected-occurrences! [events width]
  (let [heads (fresh-head-cells width)]
  (loop [chain empty-ints
   position 0]
  (if (>= position (count events)) (->OccurrenceIndex width (frozen-heads heads) chain) (let [event (checked-assertion (nth events position))
   slot (mod (hash-one (occurrence-of event)) width)
   linked (conj chain (deref (nth heads slot)))]
  (do
  (reset! (nth heads slot) position)
  (recur linked (inc position))))))))

(defn- ^Rotation projected! [^String space-id version events]
  (let [total (count events)]
  (->Rotation space-id version events (projected-occurrences! events (initial-bucket-width total)) (projected-bucket! events shape-t1 shape-t12 (initial-bucket-width (* 2 total))) (projected-bucket! events shape-t2 shape-t2 (initial-bucket-width total)) (projected-bucket! events shape-t3 shape-t3 (initial-bucket-width total)) no-pending)))

(defn ^Rotation project! [ctx]
  (projected! (store/space-id ctx) (store/current-sequence ctx) (store/live-occurrences ctx)))

(defn- pending-with-frame [pending ^String space-id frame]
  (let [coordinate (t/transaction-coordinate space-id (t/transactionframe-sequence frame))
   operations (t/transactionframe-operations frame)]
  (loop [built pending
   ordinal 0]
  (if (>= ordinal (count operations)) built (let [operation (nth operations ordinal)
   proposition (t/commitoperation-proposition operation)]
  (recur (conj built (t/operation-occurrence (t/occurrence-coordinate coordinate ordinal) (t/commitoperation-action operation) proposition)) (inc ordinal)))))))

(defn ^Rotation staged [^Rotation rotation ^String space-id sequence operations]
  (assoc rotation :pending (pending-with-frame (rotation-pending rotation) space-id (t/->TransactionFrame sequence operations))))

(defn ^Rotation refresh! [^Rotation rotation ctx]
  (let [space (store/space-id ctx)
   target (store/current-sequence ctx)
   pinned (rotation-version rotation)]
  (if (not (= space (rotation-space-id rotation))) (throw (ex-info "store: rotation belongs to a different space" {:type :rotation-space-mismatch})) (if (> pinned target) (throw (ex-info "store: rotation is ahead of the store it projects" {:type :rotation-ahead-of-store})) (if (= pinned target) rotation (let [frames (store/transaction-frames-between (deref ctx) pinned target)
   pending (loop [built (rotation-pending rotation)
   position 0]
  (if (>= position (count frames)) built (recur (pending-with-frame built space (nth frames position)) (inc position))))
   advanced (->Rotation (rotation-space-id rotation) target (rotation-events rotation) (rotation-by-occurrence rotation) (rotation-spo rotation) (rotation-pos rotation) (rotation-osp rotation) pending)]
  (if (> (count pending) pending-fold-cap) (projected! space target (all-occurrences advanced)) advanced)))))))

(defn ^Boolean pinned? [^Rotation rotation ctx]
  (and (= (store/space-id ctx) (rotation-space-id rotation)) (= (store/current-sequence ctx) (rotation-version rotation))))
