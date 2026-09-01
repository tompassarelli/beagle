(ns store.store
  (:require [store.types :as t]
            [store.slots :as slots]
            [store.packed :as packed]))

(def empty-ids [])

(def empty-atoms [])

(def empty-triple-rows [])

(def empty-transaction-rows [])

(def empty-operation-rows [])

(def empty-commit-operations [])

(def empty-transaction-records [])

(def empty-active-buckets [])

(def empty-active-cells [])

(def term-store-dump-version 2)

(def max-transaction-sequence 9223372036854775806)

(def default-tail-row-limit 65536)

(def default-tail-byte-limit 67108864)

(def tail-base-rows 448)

(def tail-base-bytes 28672)

(def atom-tail-overhead-bytes 64)

(def slot-entry-tail-bytes 24)

(def triple-tail-bytes 168)

(def transaction-tail-bytes 48)

(def operation-tail-bytes 64)

(def withdrawal-tail-bytes 16)

(def active-bucket-tail-bytes 88)

(def active-position-tail-bytes 16)

(def active-cell-tail-bytes 32)

(def ^:dynamic *deferred-packed-rollover* nil)

(defrecord TermStoreLoadResult [ok code message])

(defn termstoreloadresult-ok [r] (:ok r))

(defn termstoreloadresult-code [r] (:code r))

(defn termstoreloadresult-message [r] (:message r))

(defrecord TransactionReplayResult [ok code message])

(defn transactionreplayresult-ok [r] (:ok r))

(defn transactionreplayresult-code [r] (:code r))

(defn transactionreplayresult-message [r] (:message r))

(defrecord TransactionRecordsResult [ok records code message])

(defn transactionrecordsresult-ok [r] (:ok r))

(defn transactionrecordsresult-records [r] (:records r))

(defn transactionrecordsresult-code [r] (:code r))

(defn transactionrecordsresult-message [r] (:message r))

(defrecord TailDemand [seen rows bytes])

(defn taildemand-seen [r] (:seen r))

(defn taildemand-rows [r] (:rows r))

(defn taildemand-bytes [r] (:bytes r))

(defrecord TriplePair [first second])

(defn triplepair-first [r] (:first r))

(defn triplepair-second [r] (:second r))

(def initial-slots 64)

(def slot-load 4)

(defn- ^Boolean valid-space-id? [space-id]
  (and (string? space-id) (pos? (count space-id))))

(defn- term-slots-width-for [n]
  (loop [width initial-slots]
  (if (>= (* slot-load width) n) width (recur (* 2 width)))))

(defn- build-atom-term-slots! [atoms width base]
  (loop [slots (slots/fresh-slots width)
   position 0]
  (if (>= position (count atoms)) slots (recur (slots/slot-add! slots (slots/slot-of (nth atoms position) width) (+ base position)) (inc position)))))

(defn- build-triple-term-slots! [rows width base]
  (loop [slots (slots/fresh-slots width)
   position 0]
  (if (>= position (count rows)) slots (recur (slots/slot-add! slots (slots/slot-of (nth rows position) width) (+ base position)) (inc position)))))

(def triple-index-t1 0)

(def triple-index-t12 1)

(def triple-index-t2 2)

(def triple-index-t3 3)

(defn- triple-index-key [row index-id]
  (cond
  (= index-id triple-index-t1) (t/triplerow-t1 row)
  (= index-id triple-index-t12) (->TriplePair (t/triplerow-t1 row) (t/triplerow-t2 row))
  (= index-id triple-index-t2) (t/triplerow-t2 row)
  :else (t/triplerow-t3 row)))

(defn- build-triple-query-slots! [rows width base index-id]
  (loop [index (slots/fresh-slots width)
   position 0]
  (if (>= position (count rows)) index (let [row (nth rows position)]
  (recur (slots/slot-add! index (slots/slot-of (triple-index-key row index-id) width) (+ base position)) (inc position))))))

(defn- build-active-slots! [buckets width]
  (loop [slots (slots/fresh-slots width)
   position 0]
  (if (>= position (count buckets)) slots (recur (slots/slot-add! slots (slots/slot-of (t/activebucket-triple-handle (nth buckets position)) width) position) (inc position)))))

(defn- store-atoms [store]
  (deref (t/termstore-atoms store)))

(defn- store-triples [store]
  (deref (t/termstore-triples store)))

(defn- store-transactions [store]
  (deref (t/termstore-transactions store)))

(defn- store-operations [store]
  (deref (t/termstore-operations store)))

(defn- store-withdrawal-targets [store]
  (deref (t/termstore-withdrawal-targets store)))

(defn- store-active-buckets [store]
  (deref (t/termstore-active-buckets store)))

(defn- store-active-cells [store]
  (deref (t/termstore-active-cells store)))

(defn- ^Boolean store-fold-open [store]
  (deref (t/termstore-fold-open store)))

(defn- store-next-sequence [store]
  (deref (t/termstore-next-sequence store)))

(defn- store-atom-slots [store]
  (deref (t/termstore-atom-slots store)))

(defn- store-triple-slots [store]
  (deref (t/termstore-triple-slots store)))

(defn- store-triple-t1-slots [store]
  (deref (t/termstore-triple-t1-slots store)))

(defn- store-triple-t12-slots [store]
  (deref (t/termstore-triple-t12-slots store)))

(defn- store-triple-t2-slots [store]
  (deref (t/termstore-triple-t2-slots store)))

(defn- store-triple-t3-slots [store]
  (deref (t/termstore-triple-t3-slots store)))

(defn- store-active-slots [store]
  (deref (t/termstore-active-slots store)))

(defn- store-prefix [store]
  (t/termstore-packed-prefix store))

(defn- prefix-atom-count [store]
  (if (nil? (store-prefix store)) 0 (packed/atom-count (store-prefix store))))

(defn- prefix-triple-count [store]
  (if (nil? (store-prefix store)) 0 (packed/triple-count (store-prefix store))))

(defn- prefix-transaction-count [store]
  (if (nil? (store-prefix store)) 0 (packed/transaction-count (store-prefix store))))

(defn- prefix-operation-count [store]
  (if (nil? (store-prefix store)) 0 (packed/operation-count (store-prefix store))))

(defn- total-atom-count [store]
  (+ (prefix-atom-count store) (count (store-atoms store))))

(defn- total-triple-count [store]
  (+ (prefix-triple-count store) (count (store-triples store))))

(defn- total-transaction-count [store]
  (+ (prefix-transaction-count store) (count (store-transactions store))))

(defn- total-operation-count [store]
  (+ (prefix-operation-count store) (count (store-operations store))))

(defn atom-row-at [store position]
  (let [base (prefix-atom-count store)]
  (if (< position base) (packed/atom-row-at! (store-prefix store) position) (nth (store-atoms store) (- position base)))))

(defn triple-row-at [store position]
  (let [base (prefix-triple-count store)]
  (if (< position base) (packed/triple-row-at! (store-prefix store) position) (nth (store-triples store) (- position base)))))

(defn transaction-row-at [store position]
  (let [base (prefix-transaction-count store)]
  (if (< position base) (packed/transaction-row-at! (store-prefix store) position) (nth (store-transactions store) (- position base)))))

(defn operation-row-at [store position]
  (let [base (prefix-operation-count store)]
  (if (< position base) (packed/operation-row-at! (store-prefix store) position) (nth (store-operations store) (- position base)))))

(defn- withdrawal-target-at [store position]
  (let [base (prefix-operation-count store)]
  (if (< position base) (packed/withdrawal-target-at! (store-prefix store) position) (nth (store-withdrawal-targets store) (- position base)))))

(defn- tail-row-count [store]
  (let [atoms (count (store-atoms store))
   triples (count (store-triples store))
   transactions (count (store-transactions store))
   operations (count (store-operations store))
   buckets (store-active-buckets store)
   bucket-count (count buckets)
   active-positions (if (store-fold-open store) (reduce + (map (fn [cell] (count (deref cell))) (store-active-cells store))) (reduce + (map (fn [bucket] (count (t/activebucket-positions bucket))) buckets)))
   cell-count (if (store-fold-open store) bucket-count 0)]
  (+ tail-base-rows (+ (* 2 atoms) (+ (* 6 triples) (+ transactions (+ (* 2 operations) (+ (* 2 bucket-count) (+ active-positions cell-count)))))))))

(defn- ensure-tail-room! [store rows bytes]
  (let [row-limit (t/termstore-tail-row-limit store)
   byte-limit (t/termstore-tail-byte-limit store)
   tail-rows (tail-row-count store)
   tail-bytes (deref (t/termstore-tail-bytes store))
   demand-data {:tail-rows tail-rows :tail-bytes tail-bytes :requested-rows rows :requested-bytes bytes :row-limit row-limit :byte-limit byte-limit}
   fits-current? (and (<= (+ tail-rows rows) row-limit) (<= (+ tail-bytes bytes) byte-limit))
   fits-empty? (and (<= (+ tail-base-rows rows) row-limit) (<= (+ tail-base-bytes bytes) byte-limit))]
  (cond
  (and *deferred-packed-rollover* (not fits-empty?)) (throw (ex-info "store: one transaction exceeds the empty boxed-tail bound" (assoc demand-data :type :packed-tail-capacity-exceeded :store/code :packed-tail-capacity-exceeded)))
  (or (nil? (store-prefix store)) fits-current?) nil
  *deferred-packed-rollover* (do
  (reset! *deferred-packed-rollover* true)
  nil)
  :else (throw (ex-info "store: boxed mutation tail requires a packed checkpoint rollover" (assoc demand-data :type :packed-tail-rollover-required :store/code :packed-tail-rollover-required))))))

(defn- account-tail-bytes! [store amount]
  (swap! (t/termstore-tail-bytes store) + amount)
  nil)

(defn- new-term-store-sized-with-tail-limits [^String space-id expected-atoms expected-triples expected-buckets tail-row-limit tail-byte-limit]
  (cond
  (not (valid-space-id? space-id)) (throw (ex-info "store: TermStore requires a non-empty SpaceId" {:type :invalid-space-id}))
  (not (and (pos? tail-row-limit) (pos? tail-byte-limit))) (throw (ex-info "store: TermStore requires positive tail bounds" {:type :invalid-packed-tail-bound :store/code :invalid-packed-tail-bound}))
  :else (atom (t/->TermStore space-id (atom 1) (atom empty-atoms) (atom empty-triple-rows) (atom empty-transaction-rows) (atom empty-operation-rows) (atom empty-ids) (atom empty-active-buckets) (atom empty-active-cells) (atom false) (atom (slots/fresh-slots (term-slots-width-for expected-atoms))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-buckets))) nil tail-row-limit tail-byte-limit (atom 0) (atom 0)))))

(defn new-term-store-sized [^String space-id expected-atoms expected-triples expected-buckets]
  (new-term-store-sized-with-tail-limits space-id expected-atoms expected-triples expected-buckets default-tail-row-limit default-tail-byte-limit))

(defn new-term-store [^String space-id]
  (new-term-store-sized space-id 0 0 0))

(defn new-term-store-with-tail-limits [^String space-id tail-row-limit tail-byte-limit]
  (new-term-store-sized-with-tail-limits space-id 0 0 0 tail-row-limit tail-byte-limit))

(defn new-packed-term-store [prefix tail-row-limit tail-byte-limit rollovers]
  (if (and (some? prefix) (and (pos? tail-row-limit) (and (pos? tail-byte-limit) (>= rollovers 0)))) (atom (t/->TermStore (packed/space-id prefix) (atom (packed/next-sequence prefix)) (atom empty-atoms) (atom empty-triple-rows) (atom empty-transaction-rows) (atom empty-operation-rows) (atom empty-ids) (atom empty-active-buckets) (atom empty-active-cells) (atom false) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) (atom (slots/fresh-slots initial-slots)) prefix tail-row-limit tail-byte-limit (atom tail-base-bytes) (atom rollovers))) (throw (ex-info "store: packed TermStore requires positive tail bounds" {:type :invalid-packed-tail-bound :store/code :invalid-packed-tail-bound}))))

(defn install-packed-prefix! [ctx prefix]
  (let [before (deref ctx)]
  (if (not (and (= (t/termstore-space-id before) (packed/space-id prefix)) (= (store-next-sequence before) (packed/next-sequence prefix)))) (throw (ex-info "store: packed checkpoint does not match the live Store boundary" {:type :packed-source-mismatch :store/code :packed-source-mismatch})) (let [replacement (new-packed-term-store prefix (t/termstore-tail-row-limit before) (t/termstore-tail-byte-limit before) (inc (deref (t/termstore-tail-rollovers before))))]
  (reset! ctx (deref replacement))
  ctx))))

(defn new-term-store-for-log [^String space-id log-bytes]
  (new-term-store-sized space-id (quot log-bytes 64) (quot log-bytes 32) (quot log-bytes 128)))

(defn- fork-position-cells [cells]
  (mapv (fn [cell] (atom (deref cell))) cells))

(defn fork-state [store]
  (t/->TermStore (t/termstore-space-id store) (atom (store-next-sequence store)) (atom (store-atoms store)) (atom (store-triples store)) (atom (store-transactions store)) (atom (store-operations store)) (atom (store-withdrawal-targets store)) (atom (store-active-buckets store)) (atom (fork-position-cells (store-active-cells store))) (atom (store-fold-open store)) (atom (fork-position-cells (store-atom-slots store))) (atom (fork-position-cells (store-triple-slots store))) (atom (fork-position-cells (store-triple-t1-slots store))) (atom (fork-position-cells (store-triple-t12-slots store))) (atom (fork-position-cells (store-triple-t2-slots store))) (atom (fork-position-cells (store-triple-t3-slots store))) (atom (fork-position-cells (store-active-slots store))) (store-prefix store) (t/termstore-tail-row-limit store) (t/termstore-tail-byte-limit store) (atom (deref (t/termstore-tail-bytes store))) (atom (deref (t/termstore-tail-rollovers store)))))

(defn fork-store [ctx]
  (atom (fork-state (deref ctx))))

(defn ^String space-id [ctx]
  (t/termstore-space-id (deref ctx)))

(defn next-sequence [ctx]
  (store-next-sequence (deref ctx)))

(defn current-sequence [ctx]
  (dec (next-sequence ctx)))

(defn- atom-row [value]
  (cond
  (string? value) (t/->AtomRow :string value nil nil nil nil nil)
  (integer? value) (t/->AtomRow :int nil value nil nil nil nil)
  (number? value) (t/->AtomRow :float nil nil (double value) nil nil nil)
  (boolean? value) (t/->AtomRow :bool nil nil nil value nil nil)
  (keyword? value) (t/->AtomRow :keyword nil nil nil nil value nil)
  (t/instant? value) (t/->AtomRow :instant nil nil nil nil nil value)
  :else (throw (ex-info "store: value outside Atom" {:type :invalid-atom}))))

(defn- atom-row-value [row]
  (cond
  (= :string (t/atomrow-kind row)) (t/atomrow-string-value row)
  (= :int (t/atomrow-kind row)) (t/atomrow-int-value row)
  (= :float (t/atomrow-kind row)) (t/atomrow-float-value row)
  (= :bool (t/atomrow-kind row)) (t/atomrow-bool-value row)
  (= :keyword (t/atomrow-kind row)) (t/atomrow-keyword-value row)
  (= :instant (t/atomrow-kind row)) (t/atomrow-instant-value row)
  :else nil))

(defn- ^Boolean valid-atom-row? [row]
  (let [value (atom-row-value row)]
  (and (some? value) (= row (atom-row value)))))

(defn- find-atom-position [atoms slots base value]
  (let [positions (deref (nth slots (slots/slot-of value (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (>= position base) (and (< position (+ base (count atoms))) (= (nth atoms (- position base)) value))) position (recur (inc offset))))))))

(defn- find-triple-position [rows slots base value]
  (let [positions (deref (nth slots (slots/slot-of value (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (>= position base) (and (< position (+ base (count rows))) (= (nth rows (- position base)) value))) position (recur (inc offset))))))))

(defn- index-atom-term! [store value position]
  (let [slots (store-atom-slots store)
   width (count slots)
   indexed (slots/slot-add! slots (slots/slot-of value width) position)]
  (if (> (count (store-atoms store)) (* slot-load (count indexed))) (do
  (reset! (t/termstore-atom-slots store) (build-atom-term-slots! (store-atoms store) (* 2 width) (prefix-atom-count store)))
  store) store)))

(defn- index-triple-term! [store value position]
  (let [slots (store-triple-slots store)
   width (count slots)]
  (slots/slot-add! slots (slots/slot-of value width) position)
  (slots/slot-add! (store-triple-t1-slots store) (slots/slot-of (triple-index-key value triple-index-t1) width) position)
  (slots/slot-add! (store-triple-t12-slots store) (slots/slot-of (triple-index-key value triple-index-t12) width) position)
  (slots/slot-add! (store-triple-t2-slots store) (slots/slot-of (triple-index-key value triple-index-t2) width) position)
  (slots/slot-add! (store-triple-t3-slots store) (slots/slot-of (triple-index-key value triple-index-t3) width) position)
  (if (> (count (store-triples store)) (* slot-load width)) (let [rows (store-triples store)
   widened (* 2 width)
   base (prefix-triple-count store)]
  (reset! (t/termstore-triple-slots store) (build-triple-term-slots! rows widened base))
  (reset! (t/termstore-triple-t1-slots store) (build-triple-query-slots! rows widened base triple-index-t1))
  (reset! (t/termstore-triple-t12-slots store) (build-triple-query-slots! rows widened base triple-index-t12))
  (reset! (t/termstore-triple-t2-slots store) (build-triple-query-slots! rows widened base triple-index-t2))
  (reset! (t/termstore-triple-t3-slots store) (build-triple-query-slots! rows widened base triple-index-t3))
  store) store)))

(defn- atom-handle [position]
  (* 2 position))

(defn- triple-handle [position]
  (inc (* 2 position)))

(defn- ^Boolean atom-handle? [handle]
  (= 0 (mod handle 2)))

(defn- handle-position [handle]
  (quot handle 2))

(defn- intern-handle! [ctx term]
  (if (not (t/term? term)) (throw (ex-info "store: cannot intern a value outside Term" {:type :invalid-term})) (if (t/triple? term) (let [t1 (intern-handle! ctx (t/triple-t1 term))
   t2 (intern-handle! ctx (t/triple-t2 term))
   t3 (intern-handle! ctx (t/triple-t3 term))
   store (deref ctx)
   rows (store-triples store)
   value (t/->TripleRow t1 t2 t3)
   prefix-known (if (nil? (store-prefix store)) -1 (packed/find-triple-position (store-prefix store) t1 t2 t3))
   tail-known (find-triple-position rows (store-triple-slots store) (prefix-triple-count store) value)
   known (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= known 0) (triple-handle known) (let [position (total-triple-count store)]
  (ensure-tail-room! store 6 triple-tail-bytes)
  (swap! (t/termstore-triples store) conj value)
  (account-tail-bytes! store triple-tail-bytes)
  (index-triple-term! store value position)
  (triple-handle position)))) (let [value (atom-row term)
   store (deref ctx)
   atoms (store-atoms store)
   prefix-known (if (nil? (store-prefix store)) -1 (packed/find-atom-position! (store-prefix store) term))
   tail-known (find-atom-position atoms (store-atom-slots store) (prefix-atom-count store) value)
   known (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= known 0) (atom-handle known) (let [position (total-atom-count store)
   bytes (+ slot-entry-tail-bytes (+ atom-tail-overhead-bytes (packed/term-byte-count! term)))]
  (ensure-tail-room! store 2 bytes)
  (swap! (t/termstore-atoms store) conj value)
  (account-tail-bytes! store bytes)
  (index-atom-term! store value position)
  (atom-handle position)))))))

(defn- ^Boolean valid-handle? [store handle]
  (and (>= handle 0) (if (atom-handle? handle) (< (handle-position handle) (total-atom-count store)) (< (handle-position handle) (total-triple-count store)))))

(defn- resolve-handle [store handle]
  (if (not (valid-handle? store handle)) (throw (ex-info "store: term handle does not resolve" {:type :invalid-term-handle})) (let [position (handle-position handle)]
  (if (atom-handle? handle) (atom-row-value (atom-row-at store position)) (let [row (triple-row-at store position)]
  (t/triple (resolve-handle store (t/triplerow-t1 row)) (resolve-handle store (t/triplerow-t2 row)) (resolve-handle store (t/triplerow-t3 row))))))))

(defn- resolve-triple-handle [store handle]
  (let [term (resolve-handle store handle)]
  (if (t/triple? term) term (throw (ex-info "store: operation handle does not resolve to Triple" {:type :invalid-operation-handle})))))

(defn intern-atom-handle! [ctx value]
  (if (or (t/triple? value) (not (t/term? value))) (throw (ex-info "store: value outside Atom" {:type :invalid-atom})) (let [row (atom-row value)
   store (deref ctx)
   atoms (store-atoms store)
   prefix-known (if (nil? (store-prefix store)) -1 (packed/find-atom-position! (store-prefix store) value))
   tail-known (find-atom-position atoms (store-atom-slots store) (prefix-atom-count store) row)
   known (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= known 0) (atom-handle known) (let [position (total-atom-count store)
   bytes (+ slot-entry-tail-bytes (+ atom-tail-overhead-bytes (packed/term-byte-count! value)))]
  (do
  (ensure-tail-room! store 2 bytes)
  (swap! (t/termstore-atoms store) conj row)
  (account-tail-bytes! store bytes)
  (index-atom-term! store row position)
  (atom-handle position)))))))

(defn intern-triple-handle! [ctx t1 t2 t3]
  (let [store (deref ctx)
   rows (store-triples store)
   value (t/->TripleRow t1 t2 t3)
   prefix-known (if (nil? (store-prefix store)) -1 (packed/find-triple-position (store-prefix store) t1 t2 t3))
   tail-known (find-triple-position rows (store-triple-slots store) (prefix-triple-count store) value)
   known (if (>= prefix-known 0) prefix-known tail-known)]
  (if (not (and (valid-handle? store t1) (and (valid-handle? store t2) (valid-handle? store t3)))) (throw (ex-info "store: term handle does not resolve" {:type :invalid-term-handle})) (if (>= known 0) (triple-handle known) (let [position (total-triple-count store)]
  (do
  (ensure-tail-room! store 6 triple-tail-bytes)
  (swap! (t/termstore-triples store) conj value)
  (account-tail-bytes! store triple-tail-bytes)
  (index-triple-term! store value position)
  (triple-handle position)))))))

(defn ^Boolean triple-handle-shape? [handle]
  (and (>= handle 0) (= 1 (mod handle 2))))

(defn known-term-handle [store term]
  (if (not (t/term? term)) nil (if (t/triple? term) (let [t1 (known-term-handle store (t/triple-t1 term))
   t2 (known-term-handle store (t/triple-t2 term))
   t3 (known-term-handle store (t/triple-t3 term))
   handles [t1 t2 t3]
   all-known (loop [position 0]
  (if (>= position (count handles)) true (if (some? (nth handles position)) (recur (inc position)) false)))]
  (if all-known (let [h1 (if (some? t1) t1 0)
   h2 (if (some? t2) t2 0)
   h3 (if (some? t3) t3 0)
   prefix-known (if (nil? (store-prefix store)) -1 (packed/find-triple-position (store-prefix store) h1 h2 h3))
   tail-known (find-triple-position (store-triples store) (store-triple-slots store) (prefix-triple-count store) (t/->TripleRow h1 h2 h3))
   position (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= position 0) (do
  (triple-handle position)))) nil)) (let [prefix-known (if (nil? (store-prefix store)) -1 (packed/find-atom-position! (store-prefix store) term))
   tail-known (find-atom-position (store-atoms store) (store-atom-slots store) (prefix-atom-count store) (atom-row term))
   position (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= position 0) (do
  (atom-handle position)))))))

(defn known-triple-row-handle [store t1 t2 t3]
  (let [prefix-known (if (nil? (store-prefix store)) -1 (packed/find-triple-position (store-prefix store) t1 t2 t3))
   tail-known (find-triple-position (store-triples store) (store-triple-slots store) (prefix-triple-count store) (t/->TripleRow t1 t2 t3))
   position (if (>= prefix-known 0) prefix-known tail-known)]
  (if (>= position 0) (do
  (triple-handle position)))))

(defn resolve-term-handle [store handle]
  (resolve-handle store handle))

(defn triple-row-handles-at [store handle]
  (if (or (not (valid-handle? store handle)) (atom-handle? handle)) (throw (ex-info "store: handle does not identify a Triple row" {:type :invalid-triple-handle})) (triple-row-at store (handle-position handle))))

(defn triple-tuple-at [store handle]
  (let [proposition (resolve-triple-handle store handle)]
  [(t/triple-t1 proposition) (t/triple-t2 proposition) (t/triple-t3 proposition)]))

(declare find-active-bucket-position)

(defn- collect-new-term-demand! [store term seen]
  (if (or (contains? seen term) (some? (known-term-handle store term))) (->TailDemand seen 0 0) (if (t/triple? term) (let [^TailDemand first-demand (collect-new-term-demand! store (t/triple-t1 term) seen)
   ^TailDemand second-demand (collect-new-term-demand! store (t/triple-t2 term) (taildemand-seen first-demand))
   ^TailDemand third-demand (collect-new-term-demand! store (t/triple-t3 term) (taildemand-seen second-demand))]
  (->TailDemand (conj (taildemand-seen third-demand) term) (+ 6 (+ (taildemand-rows first-demand) (+ (taildemand-rows second-demand) (taildemand-rows third-demand)))) (+ triple-tail-bytes (+ (taildemand-bytes first-demand) (+ (taildemand-bytes second-demand) (taildemand-bytes third-demand)))))) (->TailDemand (conj seen term) 2 (+ slot-entry-tail-bytes (+ atom-tail-overhead-bytes (packed/term-byte-count! term)))))))

(defn- transaction-tail-demand! [store operations]
  (let [^TailDemand terms (loop [position 0
   ^TailDemand demand (->TailDemand #{} 0 0)]
  (if (>= position (count operations)) demand (let [^TailDemand next (collect-new-term-demand! store (t/commitoperation-proposition (nth operations position)) (taildemand-seen demand))]
  (recur (inc position) (->TailDemand (taildemand-seen next) (+ (taildemand-rows demand) (taildemand-rows next)) (+ (taildemand-bytes demand) (taildemand-bytes next)))))))
   overlay (loop [position 0
   seen #{}
   bucket-count 0
   asserted-count 0]
  (if (>= position (count operations)) {:buckets bucket-count :assertions asserted-count} (let [operation (nth operations position)
   proposition (t/commitoperation-proposition operation)
   handle (known-term-handle store proposition)
   needs-bucket (and (not (contains? seen proposition)) (or (nil? handle) (< (find-active-bucket-position store (if (some? handle) handle 0)) 0)))]
  (recur (+ position 1) (conj seen proposition) (+ bucket-count (if needs-bucket 1 0)) (+ asserted-count (if (= t/assert-action (t/commitoperation-action operation)) 1 0))))))
   bucket-count (:buckets overlay)
   asserted-count (:assertions overlay)
   cell-count (if (store-fold-open store) bucket-count 0)]
  [(+ (taildemand-rows terms) (+ 1 (+ (* 2 (count operations)) (+ (* 2 bucket-count) (+ asserted-count cell-count))))) (+ (taildemand-bytes terms) (+ transaction-tail-bytes (+ (* (+ operation-tail-bytes withdrawal-tail-bytes) (count operations)) (+ (* active-bucket-tail-bytes bucket-count) (+ (* active-position-tail-bytes asserted-count) (* active-cell-tail-bytes cell-count))))))]))

(defn ensure-transaction-capacity! [ctx operations]
  (let [store (deref ctx)
   demand (transaction-tail-demand! store operations)]
  (ensure-tail-room! store (nth demand 0) (nth demand 1))
  ctx))

(defn intern-term! [ctx term]
  (let [store (deref ctx)
   ^TailDemand demand (collect-new-term-demand! store term #{})
   _ (ensure-tail-room! store (taildemand-rows demand) (taildemand-bytes demand))
   handle (intern-handle! ctx term)]
  (resolve-handle (deref ctx) handle)))

(defn replay-terms! [ctx terms]
  (do
  (doseq [term terms]
  (intern-term! ctx term))
  ctx))

(defn atom-term-count [ctx]
  (total-atom-count (deref ctx)))

(defn triple-term-count [ctx]
  (total-triple-count (deref ctx)))

(defn term-count [ctx]
  (+ (atom-term-count ctx) (triple-term-count ctx)))

(defn transaction-count [ctx]
  (total-transaction-count (deref ctx)))

(defn operation-count [ctx]
  (total-operation-count (deref ctx)))

(defn assert-operation [proposition]
  (let [triple (t/term-as-triple proposition)]
  (if (some? triple) (t/->CommitOperation t/assert-action triple) (throw (ex-info "store: assertion operation requires a Triple" {:type :invalid-commit-operation})))))

(defn retract-operation [proposition]
  (let [triple (t/term-as-triple proposition)]
  (if (some? triple) (t/->CommitOperation t/retract-action triple) (throw (ex-info "store: retraction operation requires a Triple" {:type :invalid-commit-operation})))))

(defn- ^Boolean valid-commit-operation? [operation]
  (and (or (= t/assert-action (t/commitoperation-action operation)) (= t/retract-action (t/commitoperation-action operation))) (and (t/triple? (t/commitoperation-proposition operation)) (t/term? (t/commitoperation-proposition operation)))))

(defn- ^Boolean valid-operations? [operations]
  (and (pos? (count operations)) (every? (fn [operation] (valid-commit-operation? operation)) operations)))

(defn transaction-record [sequence operations]
  (if (and (>= sequence 0) (valid-operations? operations)) (t/->TransactionRecord sequence operations) (throw (ex-info "store: transaction record requires a non-negative sequence and operations" {:type :invalid-transaction-record}))))

(def ^String canonical-validator "store/canonical-validator-v1")

(def ^String canonical-shape-schema-id "store/CommitOperationV1")

(defn commit-metadata [^String producer ^String shape-schema-id profile]
  (t/->CommitMetadata producer shape-schema-id profile (t/->CommitValidationAttestation canonical-validator :pending canonical-validator)))

(defn- find-active-bucket-position [store handle]
  (let [slots (store-active-slots store)
   buckets (store-active-buckets store)
   positions (deref (nth slots (slots/slot-of handle (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (< position (count buckets)) (= handle (t/activebucket-triple-handle (nth buckets position)))) position (recur (inc offset))))))))

(defn- active-tail-positions [store bucket-position]
  (if (< bucket-position 0) empty-ids (if (store-fold-open store) (deref (nth (store-active-cells store) bucket-position)) (t/activebucket-positions (nth (store-active-buckets store) bucket-position)))))

(defn- active-prefix-count [store handle bucket-position]
  (if (>= bucket-position 0) (t/activebucket-prefix-count (nth (store-active-buckets store) bucket-position)) (if (nil? (store-prefix store)) 0 (packed/active-position-count (store-prefix store) handle))))

(defn ^Boolean active-handle? [store handle]
  (let [bucket-position (find-active-bucket-position store handle)]
  (pos? (+ (active-prefix-count store handle bucket-position) (count (active-tail-positions store bucket-position))))))

(defn active-operation-positions [store handle]
  (let [bucket-position (find-active-bucket-position store handle)
   prefix-count (active-prefix-count store handle bucket-position)
   tail (active-tail-positions store bucket-position)
   prefix (store-prefix store)]
  (loop [position 0
   values []]
  (if (>= position prefix-count) (into values tail) (recur (+ position 1) (conj values (packed/active-position-at! prefix handle position)))))))

(defn active-triple-handles [store]
  (let [prefix (store-prefix store)
   prefix-total (if (nil? prefix) 0 (packed/active-handle-count prefix))
   prefix-result (loop [position 0
   handles []
   seen #{}]
  (if (>= position prefix-total) {:handles handles :seen seen} (let [handle (packed/active-handle-at! prefix position)]
  (recur (+ position 1) (if (active-handle? store handle) (conj handles handle) handles) (conj seen handle)))))
   prefix-handles (:handles prefix-result)
   prefix-seen (:seen prefix-result)]
  (reduce (fn [handles bucket] (let [handle (t/activebucket-triple-handle bucket)]
  (if (or (contains? prefix-seen handle) (not (active-handle? store handle))) handles (conj handles handle)))) prefix-handles (store-active-buckets store))))

(defn live-occurrence-count [ctx]
  (let [store (deref ctx)
   prefix (store-prefix store)
   prefix-total (if (nil? prefix) 0 (packed/active-run-count prefix))
   buckets (store-active-buckets store)]
  (loop [position 0
   total prefix-total]
  (if (>= position (count buckets)) total (let [bucket (nth buckets position)
   handle (t/activebucket-triple-handle bucket)
   packed-count (if (nil? prefix) 0 (packed/active-position-count prefix handle))
   current-count (+ (t/activebucket-prefix-count bucket) (count (active-tail-positions store position)))]
  (recur (+ position 1) (+ total (- current-count packed-count))))))))

(defn- ^Boolean triple-row-matches? [row t1 t2 t3]
  (and (or (nil? t1) (= t1 (t/triplerow-t1 row))) (and (or (nil? t2) (= t2 (t/triplerow-t2 row))) (or (nil? t3) (= t3 (t/triplerow-t3 row))))))

(defn- matching-tail-index-positions [store rows index key t1 t2 t3]
  (let [base (prefix-triple-count store)
   limit (+ base (count rows))
   positions (slots/slot-positions index (slots/slot-of key (count index)))]
  (loop [remaining positions
   matches []]
  (if (empty? remaining) matches (let [position (first remaining)]
  (if (and (>= position base) (< position limit)) (let [row (nth rows (- position base))]
  (recur (rest remaining) (if (triple-row-matches? row t1 t2 t3) (conj matches position) matches))) (recur (rest remaining) matches)))))))

(defn- matching-tail-triple-positions [store t1 t2 t3]
  (let [rows (store-triples store)]
  (cond
  (and (some? t1) (and (some? t2) (some? t3))) (let [position (find-triple-position rows (store-triple-slots store) (prefix-triple-count store) (t/->TripleRow t1 t2 t3))]
  (if (>= position 0) [position] []))
  (and (some? t1) (some? t2)) (matching-tail-index-positions store rows (store-triple-t12-slots store) (->TriplePair t1 t2) t1 t2 t3)
  (and (some? t2) (some? t3)) (matching-tail-index-positions store rows (store-triple-t3-slots store) t3 t1 t2 t3)
  (and (some? t1) (some? t3)) (matching-tail-index-positions store rows (store-triple-t3-slots store) t3 t1 t2 t3)
  (some? t1) (matching-tail-index-positions store rows (store-triple-t1-slots store) t1 t1 t2 t3)
  (some? t2) (matching-tail-index-positions store rows (store-triple-t2-slots store) t2 t1 t2 t3)
  (some? t3) (matching-tail-index-positions store rows (store-triple-t3-slots store) t3 t1 t2 t3)
  :else [])))

(defn matching-triple-handles-by-handles [store h1 h2 h3]
  (let [all-valid (and (or (nil? h1) (valid-handle? store h1)) (and (or (nil? h2) (valid-handle? store h2)) (or (nil? h3) (valid-handle? store h3))))]
  (if (not all-valid) [] (if (and (nil? h1) (and (nil? h2) (nil? h3))) (active-triple-handles store) (let [prefix (store-prefix store)
   prefix-positions (if (nil? prefix) [] (packed/matching-triple-positions prefix h1 h2 h3))
   prefix-handles (reduce (fn [handles position] (let [handle (triple-handle position)]
  (if (active-handle? store handle) (conj handles handle) handles))) [] prefix-positions)
   tail-positions (matching-tail-triple-positions store h1 h2 h3)]
  (loop [remaining tail-positions
   handles prefix-handles]
  (if (empty? remaining) handles (let [handle (triple-handle (first remaining))]
  (recur (rest remaining) (if (active-handle? store handle) (conj handles handle) handles))))))))))

(defn matching-triple-handles [store t1 t2 t3]
  (let [h1 (if (some? t1) (do
  (known-term-handle store t1)))
   h2 (if (some? t2) (do
  (known-term-handle store t2)))
   h3 (if (some? t3) (do
  (known-term-handle store t3)))
   all-known (and (or (nil? t1) (some? h1)) (and (or (nil? t2) (some? h2)) (or (nil? t3) (some? h3))))]
  (if all-known (matching-triple-handles-by-handles store h1 h2 h3) [])))

(defn- set-active-state! [store handle prefix-count positions]
  (let [folding (store-fold-open store)
   known (find-active-bucket-position store handle)]
  (if (>= known 0) (do
  (if folding (reset! (nth (store-active-cells store) known) positions) nil)
  (reset! (t/termstore-active-buckets store) (assoc (store-active-buckets store) known (t/->ActiveBucket handle prefix-count (if folding empty-ids positions))))
  store) (let [buckets (conj (store-active-buckets store) (t/->ActiveBucket handle prefix-count (if folding empty-ids positions)))
   position (dec (count buckets))
   width (count (store-active-slots store))
   slots (slots/slot-add! (store-active-slots store) (slots/slot-of handle width) position)
   cells (if folding (conj (store-active-cells store) (atom positions)) (store-active-cells store))]
  (do
  (account-tail-bytes! store (+ active-bucket-tail-bytes (if folding active-cell-tail-bytes 0)))
  (reset! (t/termstore-active-buckets store) buckets)
  (reset! (t/termstore-active-cells store) cells)
  (if (> (count buckets) (* slot-load (count slots))) (do
  (reset! (t/termstore-active-slots store) (build-active-slots! buckets (* 2 width)))
  store) store))))))

(defn- open-fold-state! [store]
  (if (store-fold-open store) store (let [buckets (store-active-buckets store)
   _ (ensure-tail-room! store (count buckets) (* active-cell-tail-bytes (count buckets)))
   opened (loop [built empty-active-buckets
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (t/->ActiveBucket (t/activebucket-triple-handle (nth buckets position)) (t/activebucket-prefix-count (nth buckets position)) empty-ids)) (inc position))))
   cells (loop [built empty-active-cells
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (atom (t/activebucket-positions (nth buckets position)))) (inc position))))]
  (do
  (reset! (t/termstore-active-buckets store) opened)
  (reset! (t/termstore-active-cells store) cells)
  (reset! (t/termstore-fold-open store) true)
  (account-tail-bytes! store (* active-cell-tail-bytes (count buckets)))
  store))))

(defn- close-fold-state! [store]
  (if (not (store-fold-open store)) store (let [buckets (store-active-buckets store)
   cells (store-active-cells store)
   closed (loop [built empty-active-buckets
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (t/->ActiveBucket (t/activebucket-triple-handle (nth buckets position)) (t/activebucket-prefix-count (nth buckets position)) (deref (nth cells position)))) (inc position))))]
  (do
  (reset! (t/termstore-active-buckets store) closed)
  (reset! (t/termstore-active-cells store) empty-active-cells)
  (reset! (t/termstore-fold-open store) false)
  (account-tail-bytes! store (- (* active-cell-tail-bytes (count buckets))))
  store))))

(defn open-fold! [ctx]
  (do
  (open-fold-state! (deref ctx))
  ctx))

(defn close-fold! [ctx]
  (do
  (close-fold-state! (deref ctx))
  ctx))

(defn- apply-operation-state! [store operation-position row]
  (let [handle (t/operationrow-triple-handle row)
   action (t/operationrow-action row)
   bucket-position (find-active-bucket-position store handle)
   prefix-count (active-prefix-count store handle bucket-position)
   tail (active-tail-positions store bucket-position)]
  (account-tail-bytes! store withdrawal-tail-bytes)
  (if (= action t/assert-action) (do
  (swap! (t/termstore-withdrawal-targets store) conj -1)
  (account-tail-bytes! store active-position-tail-bytes)
  (set-active-state! store handle prefix-count (conj tail operation-position))) (if (and (zero? prefix-count) (empty? tail)) (do
  (swap! (t/termstore-withdrawal-targets store) conj -1)
  store) (let [target (if (empty? tail) (packed/active-position-at! (store-prefix store) handle (- prefix-count 1)) (peek tail))]
  (do
  (swap! (t/termstore-withdrawal-targets store) conj target)
  (if (empty? tail) (set-active-state! store handle (- prefix-count 1) tail) (do
  (account-tail-bytes! store (- active-position-tail-bytes))
  (set-active-state! store handle prefix-count (pop tail))))))))))

(defn- operation-handles! [ctx operations]
  (reduce (fn [handles operation] (conj handles (intern-handle! ctx (t/commitoperation-proposition operation)))) empty-ids operations))

(defn- ^TransactionReplayResult transaction-replay-ok []
  (->TransactionReplayResult true nil nil))

(defn- ^TransactionReplayResult transaction-replay-error [code ^String message]
  (->TransactionReplayResult false code message))

(defn- ^TransactionReplayResult transaction-replay-unclassified-error []
  (->TransactionReplayResult false nil nil))

(defn- append-valid-transaction! [ctx sequence operations]
  (let [store-before (deref ctx)
   demand (transaction-tail-demand! store-before operations)
   _ (ensure-tail-room! store-before (nth demand 0) (nth demand 1))
   handles (operation-handles! ctx operations)
   store (deref ctx)
   first-operation (total-operation-count store)
   transaction-row (t/->TransactionRow sequence first-operation (count operations))
   appended (do
  (swap! (t/termstore-transactions store) conj transaction-row)
  (account-tail-bytes! store transaction-tail-bytes)
  (loop [ordinal 0]
  (if (>= ordinal (count operations)) store (let [operation (nth operations ordinal)
   row (t/->OperationRow sequence ordinal (t/commitoperation-action operation) (nth handles ordinal))
   operation-position (+ first-operation ordinal)]
  (do
  (swap! (t/termstore-operations store) conj row)
  (account-tail-bytes! store operation-tail-bytes)
  (apply-operation-state! store operation-position row)
  (recur (inc ordinal)))))))]
  (do
  (reset! (t/termstore-next-sequence appended) (inc sequence))
  appended)))

(defn- ^TransactionReplayResult append-transaction-result! [ctx sequence operations]
  (let [before (deref ctx)]
  (cond
  (not (valid-operations? operations)) (transaction-replay-error :invalid-transaction-record "store: transaction requires at least one valid operation")
  (< sequence (store-next-sequence before)) (transaction-replay-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  (> sequence max-transaction-sequence) (transaction-replay-unclassified-error)
  :else (do
  (append-valid-transaction! ctx sequence operations)
  (transaction-replay-ok)))))

(defn- append-transaction! [ctx sequence operations metadata]
  (let [before (deref ctx)]
  (if (not (and (valid-operations? operations) (t/commit-metadata? metadata))) (throw (ex-info "store: transaction requires at least one valid operation" {:type :invalid-transaction-record})) (if (< sequence (store-next-sequence before)) (throw (ex-info "store: transaction sequence must advance within its space" {:type :nonmonotonic-transaction-sequence})) (let [final-store (append-valid-transaction! ctx sequence operations)]
  (t/transaction-coordinate (t/termstore-space-id final-store) sequence))))))

(defn- canonical-validate-commit! [operations metadata]
  (let [attestation (t/commitmetadata-validation-attestation metadata)]
  (if (and (valid-operations? operations) (t/commit-metadata? metadata) (string? (t/commitmetadata-producer metadata)) (pos? (count (t/commitmetadata-producer metadata))) (string? (t/commitmetadata-shape-schema-id metadata)) (pos? (count (t/commitmetadata-shape-schema-id metadata))) (or (nil? (t/commitmetadata-profile metadata)) (and (string? (t/commitmetadata-profile metadata)) (pos? (count (t/commitmetadata-profile metadata))))) (t/commit-validation-attestation? attestation)) (t/->CommitMetadata (t/commitmetadata-producer metadata) (t/commitmetadata-shape-schema-id metadata) (t/commitmetadata-profile metadata) (t/->CommitValidationAttestation canonical-validator :accepted canonical-validator)) (throw (ex-info "store: canonical commit validation rejected the write" {:type :canonical-commit-rejected})))))

(defn commit-boundary! [ctx operations metadata]
  (let [validated (canonical-validate-commit! operations metadata)]
  (append-transaction! ctx (store-next-sequence (deref ctx)) operations validated)))

(defn commit-transaction! [ctx operations]
  (commit-boundary! ctx operations (commit-metadata "store.txn/v1" canonical-shape-schema-id "store-schema-v1")))

(defn ^TransactionReplayResult replay-transaction-result! [ctx record]
  (if (and (t/transaction-record? record) (and (>= (t/transactionrecord-sequence record) 0) (valid-operations? (t/transactionrecord-operations record)))) (append-transaction-result! ctx (t/transactionrecord-sequence record) (t/transactionrecord-operations record)) (transaction-replay-error :invalid-transaction-record "store: invalid transaction record")))

(defn- replayed-transaction-demand [store actions handles]
  (let [overlay (loop [position 0
   seen #{}
   bucket-count 0
   asserted-count 0]
  (if (>= position (count actions)) {:buckets bucket-count :assertions asserted-count} (let [handle (nth handles position)
   needs-bucket (and (not (contains? seen handle)) (< (find-active-bucket-position store handle) 0))]
  (recur (+ position 1) (conj seen handle) (+ bucket-count (if needs-bucket 1 0)) (+ asserted-count (if (= t/assert-action (nth actions position)) 1 0))))))
   bucket-count (:buckets overlay)
   asserted-count (:assertions overlay)
   cell-count (if (store-fold-open store) bucket-count 0)]
  [(+ 1 (+ (* 2 (count actions)) (+ (* 2 bucket-count) (+ asserted-count cell-count)))) (+ transaction-tail-bytes (+ (* (+ operation-tail-bytes withdrawal-tail-bytes) (count actions)) (+ (* active-bucket-tail-bytes bucket-count) (+ (* active-position-tail-bytes asserted-count) (* active-cell-tail-bytes cell-count)))))]))

(defn ^TransactionReplayResult append-replayed-transaction! [ctx sequence actions handles]
  (let [before (deref ctx)]
  (cond
  (or (empty? actions) (not= (count actions) (count handles))) (transaction-replay-error :invalid-transaction-record "store: transaction requires at least one valid operation")
  (< sequence (store-next-sequence before)) (transaction-replay-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  (> sequence max-transaction-sequence) (transaction-replay-unclassified-error)
  :else (let [demand (replayed-transaction-demand before actions handles)
   _ (ensure-tail-room! before (nth demand 0) (nth demand 1))
   first-operation (total-operation-count before)
   transaction-row (t/->TransactionRow sequence first-operation (count actions))
   appended (do
  (swap! (t/termstore-transactions before) conj transaction-row)
  (account-tail-bytes! before transaction-tail-bytes)
  (loop [ordinal 0]
  (if (>= ordinal (count actions)) before (let [row (t/->OperationRow sequence ordinal (nth actions ordinal) (nth handles ordinal))
   operation-position (+ first-operation ordinal)]
  (do
  (swap! (t/termstore-operations before) conj row)
  (account-tail-bytes! before operation-tail-bytes)
  (apply-operation-state! before operation-position row)
  (recur (inc ordinal)))))))]
  (do
  (reset! (t/termstore-next-sequence appended) (inc sequence))
  (transaction-replay-ok))))))

(defn replay-transaction! [ctx record]
  (if (and (t/transaction-record? record) (and (>= (t/transactionrecord-sequence record) 0) (valid-operations? (t/transactionrecord-operations record)))) (append-transaction! ctx (t/transactionrecord-sequence record) (t/transactionrecord-operations record) (commit-metadata "store.replay/v1" canonical-shape-schema-id nil)) (throw (ex-info "store: invalid transaction record" {:type :invalid-transaction-record}))))

(defn- occurrence-at [store operation-position]
  (let [row (operation-row-at store operation-position)]
  (t/occurrence-coordinate (t/transaction-coordinate (t/termstore-space-id store) (t/operationrow-tx-sequence row)) (t/operationrow-ordinal row))))

(defn- operation-occurrence-at [store operation-position]
  (let [row (operation-row-at store operation-position)
   occurrence (occurrence-at store operation-position)
   proposition (resolve-triple-handle store (t/operationrow-triple-handle row))]
  (t/operation-occurrence occurrence (t/operationrow-action row) proposition)))

(defn- matching-live-operation-positions [store t1 t2 t3]
  (let [handles (matching-triple-handles store t1 t2 t3)
   positions (reduce (fn [known handle] (into known (active-operation-positions store handle))) [] handles)]
  (vec (sort positions))))

(defn matching-live-occurrences [store t1 t2 t3 maximum]
  (loop [positions (matching-live-operation-positions store t1 t2 t3)
   values []]
  (if (or (empty? positions) (and (some? maximum) (>= (count values) maximum))) values (recur (rest positions) (conj values (operation-occurrence-at store (first positions)))))))

(defn matching-live-propositions [store t1 t2 t3 maximum]
  (mapv t/operationoccurrence-proposition (matching-live-occurrences store t1 t2 t3 maximum)))

(defn- first-transaction-after [store sequence]
  (loop [low 0
   high (total-transaction-count store)]
  (if (>= low high) low (let [middle (quot (+ low high) 2)
   candidate (t/transactionrow-sequence (transaction-row-at store middle))]
  (if (<= candidate sequence) (recur (inc middle) high) (recur low middle))))))

(defn operation-range-bounds [store lower-exclusive upper-inclusive]
  (let [transaction-total (total-transaction-count store)
   operation-total (total-operation-count store)
   start-transaction (first-transaction-after store lower-exclusive)
   end-transaction (first-transaction-after store upper-inclusive)
   start (if (>= start-transaction transaction-total) operation-total (t/transactionrow-first-operation (transaction-row-at store start-transaction)))
   end (if (>= end-transaction transaction-total) operation-total (t/transactionrow-first-operation (transaction-row-at store end-transaction)))]
  [start end]))

(defn transaction-records-between [store lower-exclusive upper-inclusive]
  (let [first (first-transaction-after store lower-exclusive)
   end (first-transaction-after store upper-inclusive)]
  (loop [transaction-position first
   records []]
  (if (>= transaction-position end) records (let [row (transaction-row-at store transaction-position)
   start (t/transactionrow-first-operation row)
   stop (+ start (t/transactionrow-operation-count row))
   operations (loop [operation-position start
   collected []]
  (if (>= operation-position stop) collected (let [operation (operation-row-at store operation-position)]
  (recur (inc operation-position) (conj collected (t/->CommitOperation (t/operationrow-action operation) (resolve-triple-handle store (t/operationrow-triple-handle operation))))))))]
  (recur (inc transaction-position) (conj records (t/->TransactionRecord (t/transactionrow-sequence row) operations))))))))

(defn operation-postings [store]
  (loop [position 0
   postings {}]
  (if (>= position (total-operation-count store)) postings (let [handle (t/operationrow-triple-handle (operation-row-at store position))]
  (recur (inc position) (update postings handle (fn [known] (if (nil? known) [position] (conj known position)))))))))

(defn- lower-bound-position [positions target]
  (loop [low 0
   high (count positions)]
  (if (>= low high) low (let [middle (quot (+ low high) 2)]
  (if (< (nth positions middle) target) (recur (inc middle) high) (recur low middle))))))

(defn- exact-occurrence-position [store coordinate]
  (if (not (t/occurrence-coordinate? coordinate)) -1 (let [transaction (t/triple-t1 coordinate)
   ^String space (t/triple-t1 transaction)
   sequence (t/triple-t3 transaction)
   ordinal (t/triple-t3 coordinate)
   position (first-transaction-after store (dec sequence))]
  (if (or (not (= space (t/termstore-space-id store))) (>= position (total-transaction-count store))) -1 (let [row (transaction-row-at store position)]
  (if (and (= sequence (t/transactionrow-sequence row)) (< ordinal (t/transactionrow-operation-count row))) (+ (t/transactionrow-first-operation row) ordinal) -1))))))

(defn occurrence-at-coordinate [ctx coordinate]
  (let [store (deref ctx)
   position (exact-occurrence-position store coordinate)]
  (if (>= position 0) (do
  (operation-occurrence-at store position)))))

(defn operation-candidate-positions [store lower-exclusive upper-inclusive coordinate proposition postings]
  (let [bounds (operation-range-bounds store lower-exclusive upper-inclusive)
   start (nth bounds 0)
   end (nth bounds 1)
   exact (if (some? coordinate) (do
  (exact-occurrence-position store coordinate)))
   proposition-handle (if (some? proposition) (do
  (known-term-handle store proposition)))
   posted (if (some? proposition-handle) (get postings proposition-handle []) [])
   from (lower-bound-position posted start)
   until (lower-bound-position posted end)
   candidates (cond
  (some? exact) (if (and (>= exact start) (< exact end)) [exact] [])
  (some? proposition) (if (some? proposition-handle) (subvec posted from until) [])
  :else (vec (range start end)))]
  (if (and (some? exact) (some? proposition)) (filterv (fn [position] (= proposition-handle (t/operationrow-triple-handle (operation-row-at store position)))) candidates) candidates)))

(defn occurrence-tuple-at [store position]
  (let [occurrence (operation-occurrence-at store position)]
  [(t/operationoccurrence-coordinate occurrence) (t/operationoccurrence-action occurrence) (t/operationoccurrence-proposition occurrence)]))

(defn occurrences [ctx]
  (let [store (deref ctx)]
  (loop [position 0
   values []]
  (if (>= position (total-operation-count store)) values (recur (inc position) (conj values (operation-occurrence-at store position)))))))

(defn withdrawals [ctx]
  (let [store (deref ctx)]
  (loop [position 0
   values []]
  (if (>= position (total-operation-count store)) values (let [target (withdrawal-target-at store position)]
  (if (>= target 0) (recur (inc position) (conj values (t/withdrawal (operation-occurrence-at store position) (operation-occurrence-at store target)))) (recur (inc position) values)))))))

(defn withdrawal-tuples-between [store lower-exclusive upper-inclusive]
  (let [bounds (operation-range-bounds store lower-exclusive upper-inclusive)
   start (nth bounds 0)
   end (nth bounds 1)]
  (loop [position start
   rows []]
  (if (>= position end) rows (let [target (withdrawal-target-at store position)]
  (if (>= target 0) (let [retraction (operation-occurrence-at store position)
   assertion (operation-occurrence-at store target)]
  (recur (inc position) (conj rows [(t/operationoccurrence-coordinate retraction) (t/operationoccurrence-coordinate assertion)]))) (recur (inc position) rows)))))))

(defn- ^Boolean operation-live? [store position row]
  (and (= t/assert-action (t/operationrow-action row)) (let [handle (t/operationrow-triple-handle row)
   bucket-position (find-active-bucket-position store handle)
   prefix-count (active-prefix-count store handle bucket-position)
   tail (active-tail-positions store bucket-position)]
  (if (< position (prefix-operation-count store)) (and (some? (store-prefix store)) (packed/active-prefix-operation? (store-prefix store) handle prefix-count position)) (let [offset (lower-bound-position tail position)]
  (and (< offset (count tail)) (= position (nth tail offset))))))))

(defn live-occurrences [ctx]
  (let [store (deref ctx)
   total (total-operation-count store)]
  (loop [position 0
   live []]
  (if (>= position total) live (if (operation-live? store position (operation-row-at store position)) (recur (inc position) (conj live (operation-occurrence-at store position))) (recur (inc position) live))))))

(defn live-propositions [ctx]
  (let [store (deref ctx)
   total (total-operation-count store)]
  (loop [position 0
   live []]
  (if (>= position total) live (let [row (operation-row-at store position)]
  (if (operation-live? store position row) (recur (inc position) (conj live (resolve-triple-handle store (t/operationrow-triple-handle row)))) (recur (inc position) live)))))))

(defn- ^Boolean relation-proposition? [predicate value]
  (and (t/triple? value) (and (t/occurrence-coordinate? (t/triple-t1 value)) (and (= predicate (t/triple-t2 value)) (t/occurrence-coordinate? (t/triple-t3 value))))))

(defn supersession-triples [ctx]
  (filterv (fn [value] (relation-proposition? :kernel/supersedes value)) (matching-live-propositions (deref ctx) nil :kernel/supersedes nil nil)))

(defn- suppressed-occurrence-coordinates [store]
  (reduce (fn [coordinates proposition] (conj coordinates (t/triple-t3 proposition))) #{} (filterv (fn [value] (relation-proposition? :kernel/supersedes value)) (matching-live-propositions store nil :kernel/supersedes nil nil))))

(defn effective-live-occurrences [ctx]
  (let [store (deref ctx)
   suppressed (suppressed-occurrence-coordinates store)]
  (filterv (fn [occurrence] (not (contains? suppressed (t/operationoccurrence-coordinate occurrence)))) (live-occurrences ctx))))

(defn effective-live-propositions [ctx]
  (mapv t/operationoccurrence-proposition (effective-live-occurrences ctx)))

(defn ^Boolean effective-live-occurrence? [ctx coordinate]
  (let [store (deref ctx)
   position (exact-occurrence-position store coordinate)]
  (and (>= position 0) (and (operation-live? store position (operation-row-at store position)) (not (contains? (suppressed-occurrence-coordinates store) coordinate))))))

(defn effective-live-proposition-count [ctx]
  (let [store (deref ctx)
   suppressed (suppressed-occurrence-coordinates store)
   suppressed-live (reduce (fn [total coordinate] (let [position (exact-occurrence-position store coordinate)]
  (if (and (>= position 0) (operation-live? store position (operation-row-at store position))) (+ total 1) total))) 0 suppressed)]
  (- (live-occurrence-count ctx) suppressed-live)))

(defn matching-effective-occurrences [store t1 t2 t3 maximum]
  (let [suppressed (suppressed-occurrence-coordinates store)]
  (loop [remaining (matching-live-occurrences store t1 t2 t3 nil)
   occurrences []]
  (if (or (empty? remaining) (and (some? maximum) (>= (count occurrences) maximum))) occurrences (let [occurrence (first remaining)]
  (recur (rest remaining) (if (contains? suppressed (t/operationoccurrence-coordinate occurrence)) occurrences (conj occurrences occurrence))))))))

(defn matching-effective-propositions [store t1 t2 t3 maximum]
  (mapv t/operationoccurrence-proposition (matching-effective-occurrences store t1 t2 t3 maximum)))

(defn dump-term-store [ctx]
  (let [store (deref ctx)
   atoms (loop [position 0
   collected []]
  (if (>= position (total-atom-count store)) collected (recur (inc position) (conj collected (atom-row-at store position)))))
   triples (loop [position 0
   collected []]
  (if (>= position (total-triple-count store)) collected (recur (inc position) (conj collected (triple-row-at store position)))))
   transactions (loop [position 0
   collected []]
  (if (>= position (total-transaction-count store)) collected (recur (inc position) (conj collected (transaction-row-at store position)))))
   operations (loop [position 0
   collected []]
  (if (>= position (total-operation-count store)) collected (recur (inc position) (conj collected (operation-row-at store position)))))]
  (t/->TermStoreDump term-store-dump-version (t/termstore-space-id store) (store-next-sequence store) atoms triples transactions operations)))

(defn dump-term-store-tail [ctx]
  (let [store (deref ctx)]
  (t/->TermStoreDump term-store-dump-version (t/termstore-space-id store) (store-next-sequence store) (store-atoms store) (store-triples store) (store-transactions store) (store-operations store))))

(defn packed-prefix [ctx]
  (store-prefix (deref ctx)))

(defn storage-diagnostics [ctx]
  (let [store (deref ctx)
   prefix (store-prefix store)
   overlay-buckets (store-active-buckets store)
   overlay-positions (if (store-fold-open store) (reduce + (map (fn [cell] (count (deref cell))) (store-active-cells store))) (reduce + (map (fn [bucket] (count (t/activebucket-positions bucket))) overlay-buckets)))]
  {:source (if (nil? prefix) :storelog-full-replay :packed-checkpoint) :active-manifest (if (nil? prefix) nil (packed/manifest-path prefix)) :prefix-atoms (prefix-atom-count store) :prefix-triples (prefix-triple-count store) :prefix-transactions (prefix-transaction-count store) :prefix-operations (prefix-operation-count store) :suffix-atoms (count (store-atoms store)) :suffix-triples (count (store-triples store)) :suffix-transactions (count (store-transactions store)) :suffix-operations (count (store-operations store)) :active-overlay-buckets (count overlay-buckets) :active-overlay-positions overlay-positions :tail-rows (tail-row-count store) :tail-bytes (deref (t/termstore-tail-bytes store)) :tail-row-limit (t/termstore-tail-row-limit store) :tail-byte-limit (t/termstore-tail-byte-limit store) :tail-rollovers (deref (t/termstore-tail-rollovers store)) :mapped-bytes (if (nil? prefix) 0 (packed/mapped-bytes prefix))}))

(defn- ^Boolean valid-prior-handle? [atom-count triple-position handle]
  (and (>= handle 0) (if (atom-handle? handle) (< (handle-position handle) atom-count) (< (handle-position handle) triple-position))))

(defn- ^Boolean valid-triple-rows? [atom-count rows]
  (loop [position 0]
  (if (>= position (count rows)) true (let [row (nth rows position)]
  (if (and (valid-prior-handle? atom-count position (t/triplerow-t1 row)) (and (valid-prior-handle? atom-count position (t/triplerow-t2 row)) (valid-prior-handle? atom-count position (t/triplerow-t3 row)))) (recur (inc position)) false)))))

(defn- ^Boolean valid-dump-operation? [triple-count sequence ordinal row]
  (let [handle (t/operationrow-triple-handle row)]
  (and (= sequence (t/operationrow-tx-sequence row)) (and (= ordinal (t/operationrow-ordinal row)) (and (or (= t/assert-action (t/operationrow-action row)) (= t/retract-action (t/operationrow-action row))) (and (>= handle 0) (and (not (atom-handle? handle)) (< (handle-position handle) triple-count))))))))

(defn- ^Boolean valid-operation-slice? [operations triple-count sequence first-operation operation-count]
  (loop [ordinal 0]
  (if (>= ordinal operation-count) true (if (valid-dump-operation? triple-count sequence ordinal (nth operations (+ first-operation ordinal))) (recur (inc ordinal)) false))))

(defn- ^Boolean valid-history-rows? [transactions operations triple-count next-sequence-value]
  (loop [transaction-position 0
   operation-position 0
   previous-sequence -1]
  (if (>= transaction-position (count transactions)) (and (= operation-position (count operations)) (if (< previous-sequence 0) (= next-sequence-value 1) (and (> next-sequence-value 0) (= (dec next-sequence-value) previous-sequence)))) (let [row (nth transactions transaction-position)
   sequence (t/transactionrow-sequence row)
   first-operation (t/transactionrow-first-operation row)
   operation-count-value (t/transactionrow-operation-count row)]
  (if (and (> sequence previous-sequence) (and (= first-operation operation-position) (and (pos? operation-count-value) (and (<= operation-count-value (- (count operations) first-operation)) (valid-operation-slice? operations triple-count sequence first-operation operation-count-value))))) (recur (inc transaction-position) (+ operation-position operation-count-value) sequence) false)))))

(defn- ^TransactionRecordsResult transaction-records-ok [records]
  (->TransactionRecordsResult true records nil nil))

(defn- ^TransactionRecordsResult transaction-records-error [code ^String message]
  (->TransactionRecordsResult false empty-transaction-records code message))

(defn- operation-handle-error [store]
  (let [atoms (store-atoms store)
   triples (store-triples store)
   operations (store-operations store)]
  (loop [position 0]
  (if (>= position (count operations)) nil (let [handle (t/operationrow-triple-handle (nth operations position))
   handle-position-value (handle-position handle)]
  (cond
  (< handle 0) (transaction-records-error :invalid-term-handle "store: term handle does not resolve")
  (atom-handle? handle) (if (< handle-position-value (count atoms)) (transaction-records-error :invalid-operation-handle "store: operation handle does not resolve to Triple") (transaction-records-error :invalid-term-handle "store: term handle does not resolve"))
  (>= handle-position-value (count triples)) (transaction-records-error :invalid-term-handle "store: term handle does not resolve")
  :else (recur (inc position))))))))

(defn- ^Boolean valid-atom-rows? [rows]
  (loop [position 0]
  (if (>= position (count rows)) true (if (valid-atom-row? (nth rows position)) (recur (inc position)) false))))

(defn- ^Boolean unique-atom-rows? [rows]
  (loop [position 0
   seen #{}]
  (if (>= position (count rows)) true (let [row (nth rows position)]
  (if (contains? seen row) false (recur (inc position) (conj seen row)))))))

(defn- ^Boolean unique-triple-rows? [rows]
  (loop [position 0
   seen #{}]
  (if (>= position (count rows)) true (let [row (nth rows position)]
  (if (contains? seen row) false (recur (inc position) (conj seen row)))))))

(defn- ^Boolean canonical-term-rows? [atoms rows]
  (and (valid-atom-rows? atoms) (and (unique-atom-rows? atoms) (and (valid-triple-rows? (count atoms) rows) (unique-triple-rows? rows)))))

(defn- history-sequence-error [transactions]
  (loop [position 0
   previous-sequence 0]
  (if (>= position (count transactions)) nil (let [sequence (t/transactionrow-sequence (nth transactions position))]
  (cond
  (< sequence 0) (transaction-records-error :invalid-transaction-record "store: invalid transaction record")
  (<= sequence previous-sequence) (transaction-records-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  :else (recur (inc position) sequence))))))

(defn- resolve-valid-handle [store handle]
  (let [position (handle-position handle)]
  (if (atom-handle? handle) (atom-row-value (atom-row-at store position)) (let [row (triple-row-at store position)]
  (t/->Triple (resolve-valid-handle store (t/triplerow-t1 row)) (resolve-valid-handle store (t/triplerow-t2 row)) (resolve-valid-handle store (t/triplerow-t3 row)))))))

(defn- resolve-valid-triple-handle [store handle]
  (let [row (triple-row-at store (handle-position handle))]
  (t/->Triple (resolve-valid-handle store (t/triplerow-t1 row)) (resolve-valid-handle store (t/triplerow-t2 row)) (resolve-valid-handle store (t/triplerow-t3 row)))))

(defn- valid-transaction-record-at [store transaction-position]
  (let [row (transaction-row-at store transaction-position)
   start (t/transactionrow-first-operation row)
   stop (+ start (t/transactionrow-operation-count row))
   operations (loop [position start
   current empty-commit-operations]
  (if (>= position stop) current (let [operation (operation-row-at store position)]
  (recur (inc position) (conj current (t/->CommitOperation (t/operationrow-action operation) (resolve-valid-triple-handle store (t/operationrow-triple-handle operation))))))))]
  (t/->TransactionRecord (t/transactionrow-sequence row) operations)))

(defn- valid-transaction-records-between [store lower-exclusive upper-inclusive]
  (let [first (first-transaction-after store lower-exclusive)
   end (first-transaction-after store upper-inclusive)]
  (loop [position first
   records empty-transaction-records]
  (if (>= position end) records (recur (inc position) (conj records (valid-transaction-record-at store position)))))))

(defn ^TransactionRecordsResult transaction-records-between-result [store lower-exclusive upper-inclusive]
  (if (some? (store-prefix store)) (if (> lower-exclusive upper-inclusive) (transaction-records-error :invalid-transaction-record "store: transaction record range is invalid") (transaction-records-ok (transaction-records-between store lower-exclusive upper-inclusive))) (let [atoms (store-atoms store)
   triples (store-triples store)
   transactions (store-transactions store)
   operations (store-operations store)]
  (cond
  (> lower-exclusive upper-inclusive) (transaction-records-error :invalid-transaction-record "store: transaction record range is invalid")
  (not (valid-space-id? (t/termstore-space-id store))) (transaction-records-error :invalid-space-id "store: TermStore requires a non-empty SpaceId")
  (< (store-next-sequence store) 1) (transaction-records-error :invalid-transaction-record "store: invalid transaction record")
  :else (let [handle-error (operation-handle-error store)]
  (if (some? handle-error) handle-error (if (not (valid-atom-rows? atoms)) (transaction-records-error :invalid-term "store: triple contains a value outside Term") (if (not (valid-triple-rows? (count atoms) triples)) (transaction-records-error :invalid-term-handle "store: term handle does not resolve") (let [sequence-error (history-sequence-error transactions)]
  (if (some? sequence-error) sequence-error (if (not (valid-history-rows? transactions operations (count triples) (store-next-sequence store))) (transaction-records-error :invalid-transaction-record "store: invalid transaction record") (transaction-records-ok (valid-transaction-records-between store lower-exclusive upper-inclusive)))))))))))))

(defn- rebuild-operation-state! [store]
  (let [operations (store-operations store)
   total (count operations)
   base (do
  (reset! (t/termstore-withdrawal-targets store) empty-ids)
  (reset! (t/termstore-active-buckets store) empty-active-buckets)
  (reset! (t/termstore-active-cells store) empty-active-cells)
  (reset! (t/termstore-fold-open store) false)
  (reset! (t/termstore-active-slots store) (slots/fresh-slots (term-slots-width-for total)))
  (open-fold-state! store))]
  (close-fold-state! (loop [position 0]
  (if (>= position total) base (do
  (apply-operation-state! base position (nth operations position))
  (recur (inc position))))))))

(defn- ^TermStoreLoadResult term-store-load-ok []
  (->TermStoreLoadResult true nil nil))

(defn- ^TermStoreLoadResult term-store-load-error [code ^String message]
  (->TermStoreLoadResult false code message))

(defn ^TermStoreLoadResult load-term-store-result! [ctx data]
  (if (not (t/term-store-dump? data)) (term-store-load-error :invalid-term-store-dump "store: invalid TermStore dump") (if (not (= term-store-dump-version (t/termstoredump-version data))) (term-store-load-error :invalid-term-store-dump "store: invalid TermStore dump") (let [atoms (t/termstoredump-atoms data)
   rows (t/termstoredump-triples data)
   transactions (t/termstoredump-transactions data)
   operations (t/termstoredump-operations data)
   ^String dump-space (t/termstoredump-space-id data)
   next-sequence-value (t/termstoredump-next-sequence data)]
  (if (not (and (valid-space-id? dump-space) (and (>= next-sequence-value 1) (and (canonical-term-rows? atoms rows) (valid-history-rows? transactions operations (count rows) next-sequence-value))))) (term-store-load-error :invalid-term-store-dump "store: invalid TermStore dump") (if (not (= (space-id ctx) dump-space)) (term-store-load-error :space-mismatch "store: TermStore dump belongs to a different space") (let [loaded (t/->TermStore dump-space (atom next-sequence-value) (atom atoms) (atom rows) (atom transactions) (atom operations) (atom empty-ids) (atom empty-active-buckets) (atom empty-active-cells) (atom false) (atom (build-atom-term-slots! atoms (term-slots-width-for (count atoms)) 0)) (atom (build-triple-term-slots! rows (term-slots-width-for (count rows)) 0)) (atom (build-triple-query-slots! rows (term-slots-width-for (count rows)) 0 triple-index-t1)) (atom (build-triple-query-slots! rows (term-slots-width-for (count rows)) 0 triple-index-t12)) (atom (build-triple-query-slots! rows (term-slots-width-for (count rows)) 0 triple-index-t2)) (atom (build-triple-query-slots! rows (term-slots-width-for (count rows)) 0 triple-index-t3)) (atom (slots/fresh-slots initial-slots)) nil default-tail-row-limit default-tail-byte-limit (atom 0) (atom 0))]
  (reset! ctx (rebuild-operation-state! loaded))
  (term-store-load-ok))))))))

(defn validated-store! [ctx]
  (let [store (deref ctx)
   atoms (store-atoms store)
   rows (store-triples store)
   transactions (store-transactions store)
   operations (store-operations store)
   next-sequence-value (store-next-sequence store)]
  (if (or (some? (store-prefix store)) (and (valid-space-id? (t/termstore-space-id store)) (and (>= next-sequence-value 1) (and (canonical-term-rows? atoms rows) (valid-history-rows? transactions operations (count rows) next-sequence-value))))) ctx (throw (ex-info "store: invalid TermStore dump" {:type :invalid-term-store-dump})))))

(defn load-term-store! [ctx data]
  (let [^TermStoreLoadResult result (load-term-store-result! ctx data)]
  (if (termstoreloadresult-ok result) ctx (let [code (termstoreloadresult-code result)
   message (termstoreloadresult-message result)]
  (throw (ex-info (if message message "store: TermStore load failed") {:type (if code code :invalid-term-store-dump)}))))))
