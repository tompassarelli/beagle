(ns store.store
  (:require [store.types :as t]
            [store.slots :as slots]))

(def empty-ids [])

(def empty-atoms [])

(def empty-triple-rows [])

(def empty-transaction-rows [])

(def empty-operation-rows [])

(def empty-commit-operations [])

(def empty-transaction-frames [])

(def empty-active-buckets [])

(def empty-active-cells [])

(def term-store-dump-version 2)

(def max-transaction-sequence 9223372036854775806)

(defrecord TermStoreLoadResult [ok code message])

(defn termstoreloadresult-ok [r] (:ok r))

(defn termstoreloadresult-code [r] (:code r))

(defn termstoreloadresult-message [r] (:message r))

(defrecord TransactionReplayResult [ok code message])

(defn transactionreplayresult-ok [r] (:ok r))

(defn transactionreplayresult-code [r] (:code r))

(defn transactionreplayresult-message [r] (:message r))

(defrecord TransactionFramesResult [ok frames code message])

(defn transactionframesresult-ok [r] (:ok r))

(defn transactionframesresult-frames [r] (:frames r))

(defn transactionframesresult-code [r] (:code r))

(defn transactionframesresult-message [r] (:message r))

(def initial-slots 64)

(def slot-load 4)

(defn- ^Boolean valid-space-id? [space-id]
  (and (string? space-id) (pos? (count space-id))))

(defn- term-slots-width-for [n]
  (loop [width initial-slots]
  (if (>= (* slot-load width) n) width (recur (* 2 width)))))

(defn- build-atom-term-slots! [atoms width]
  (loop [slots (slots/fresh-slots width)
   position 0]
  (if (>= position (count atoms)) slots (recur (slots/slot-add! slots (slots/slot-of (nth atoms position) width) position) (inc position)))))

(defn- build-triple-term-slots! [rows width]
  (loop [slots (slots/fresh-slots width)
   position 0]
  (if (>= position (count rows)) slots (recur (slots/slot-add! slots (slots/slot-of (nth rows position) width) position) (inc position)))))

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

(defn- store-active-slots [store]
  (deref (t/termstore-active-slots store)))

(defn new-term-store-sized [^String space-id expected-atoms expected-triples expected-buckets]
  (if (valid-space-id? space-id) (atom (t/->TermStore space-id (atom 1) (atom empty-atoms) (atom empty-triple-rows) (atom empty-transaction-rows) (atom empty-operation-rows) (atom empty-ids) (atom empty-active-buckets) (atom empty-active-cells) (atom false) (atom (slots/fresh-slots (term-slots-width-for expected-atoms))) (atom (slots/fresh-slots (term-slots-width-for expected-triples))) (atom (slots/fresh-slots (term-slots-width-for expected-buckets))))) (throw (ex-info "store: TermStore requires a non-empty SpaceId" {:type :invalid-space-id}))))

(defn new-term-store [^String space-id]
  (new-term-store-sized space-id 0 0 0))

(defn new-term-store-for-log [^String space-id log-bytes]
  (new-term-store-sized space-id (quot log-bytes 64) (quot log-bytes 32) (quot log-bytes 128)))

(defn- fork-position-cells [cells]
  (mapv (fn [cell] (atom (deref cell))) cells))

(defn fork-state [store]
  (t/->TermStore (t/termstore-space-id store) (atom (store-next-sequence store)) (atom (store-atoms store)) (atom (store-triples store)) (atom (store-transactions store)) (atom (store-operations store)) (atom (store-withdrawal-targets store)) (atom (store-active-buckets store)) (atom (fork-position-cells (store-active-cells store))) (atom (store-fold-open store)) (atom (store-atom-slots store)) (atom (store-triple-slots store)) (atom (store-active-slots store))))

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

(defn- find-atom-position [atoms slots value]
  (let [positions (deref (nth slots (slots/slot-of value (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (< position (count atoms)) (= (nth atoms position) value)) position (recur (inc offset))))))))

(defn- find-triple-position [rows slots value]
  (let [positions (deref (nth slots (slots/slot-of value (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (< position (count rows)) (= (nth rows position) value)) position (recur (inc offset))))))))

(defn- index-atom-term! [store value position]
  (let [slots (store-atom-slots store)
   width (count slots)
   indexed (slots/slot-add! slots (slots/slot-of value width) position)]
  (if (> (count (store-atoms store)) (* slot-load (count indexed))) (do
  (reset! (t/termstore-atom-slots store) (build-atom-term-slots! (store-atoms store) (* 2 width)))
  store) store)))

(defn- index-triple-term! [store value position]
  (let [slots (store-triple-slots store)
   width (count slots)
   indexed (slots/slot-add! slots (slots/slot-of value width) position)]
  (if (> (count (store-triples store)) (* slot-load (count indexed))) (do
  (reset! (t/termstore-triple-slots store) (build-triple-term-slots! (store-triples store) (* 2 width)))
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
   known (find-triple-position rows (store-triple-slots store) value)]
  (if (>= known 0) (triple-handle known) (let [position (count rows)]
  (swap! (t/termstore-triples store) conj value)
  (index-triple-term! store value position)
  (triple-handle position)))) (let [value (atom-row term)
   store (deref ctx)
   atoms (store-atoms store)
   known (find-atom-position atoms (store-atom-slots store) value)]
  (if (>= known 0) (atom-handle known) (let [position (count atoms)]
  (swap! (t/termstore-atoms store) conj value)
  (index-atom-term! store value position)
  (atom-handle position)))))))

(defn- ^Boolean valid-handle? [store handle]
  (and (>= handle 0) (if (atom-handle? handle) (< (handle-position handle) (count (store-atoms store))) (< (handle-position handle) (count (store-triples store))))))

(defn- resolve-handle [store handle]
  (if (not (valid-handle? store handle)) (throw (ex-info "store: term handle does not resolve" {:type :invalid-term-handle})) (let [position (handle-position handle)]
  (if (atom-handle? handle) (atom-row-value (nth (store-atoms store) position)) (let [row (nth (store-triples store) position)]
  (t/triple (resolve-handle store (t/triplerow-t1 row)) (resolve-handle store (t/triplerow-t2 row)) (resolve-handle store (t/triplerow-t3 row))))))))

(defn- resolve-triple-handle [store handle]
  (let [term (resolve-handle store handle)]
  (if (t/triple? term) term (throw (ex-info "store: operation handle does not resolve to Triple" {:type :invalid-operation-handle})))))

(defn intern-atom-handle! [ctx value]
  (if (or (t/triple? value) (not (t/term? value))) (throw (ex-info "store: value outside Atom" {:type :invalid-atom})) (let [row (atom-row value)
   store (deref ctx)
   atoms (store-atoms store)
   known (find-atom-position atoms (store-atom-slots store) row)]
  (if (>= known 0) (atom-handle known) (let [position (count atoms)]
  (do
  (swap! (t/termstore-atoms store) conj row)
  (index-atom-term! store row position)
  (atom-handle position)))))))

(defn intern-triple-handle! [ctx t1 t2 t3]
  (let [store (deref ctx)
   rows (store-triples store)
   value (t/->TripleRow t1 t2 t3)
   known (find-triple-position rows (store-triple-slots store) value)]
  (if (not (and (valid-handle? store t1) (and (valid-handle? store t2) (valid-handle? store t3)))) (throw (ex-info "store: term handle does not resolve" {:type :invalid-term-handle})) (if (>= known 0) (triple-handle known) (let [position (count rows)]
  (do
  (swap! (t/termstore-triples store) conj value)
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
  (if all-known (let [position (find-triple-position (store-triples store) (store-triple-slots store) (t/->TripleRow (if (some? t1) t1 0) (if (some? t2) t2 0) (if (some? t3) t3 0)))]
  (if (>= position 0) (do
  (triple-handle position)))) nil)) (let [position (find-atom-position (store-atoms store) (store-atom-slots store) (atom-row term))]
  (if (>= position 0) (do
  (atom-handle position)))))))

(defn intern-term! [ctx term]
  (let [handle (intern-handle! ctx term)]
  (resolve-handle (deref ctx) handle)))

(defn replay-terms! [ctx terms]
  (do
  (doseq [term terms]
  (intern-term! ctx term))
  ctx))

(defn atom-term-count [ctx]
  (count (store-atoms (deref ctx))))

(defn triple-term-count [ctx]
  (count (store-triples (deref ctx))))

(defn term-count [ctx]
  (+ (atom-term-count ctx) (triple-term-count ctx)))

(defn transaction-count [ctx]
  (count (store-transactions (deref ctx))))

(defn operation-count [ctx]
  (count (store-operations (deref ctx))))

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

(defn transaction-frame [sequence operations]
  (if (and (>= sequence 0) (valid-operations? operations)) (t/->TransactionFrame sequence operations) (throw (ex-info "store: transaction frame requires a non-negative sequence and operations" {:type :invalid-transaction-frame}))))

(defn- find-active-bucket-position [store handle]
  (let [slots (store-active-slots store)
   buckets (store-active-buckets store)
   positions (deref (nth slots (slots/slot-of handle (count slots))))]
  (loop [offset 0]
  (if (>= offset (count positions)) -1 (let [position (nth positions offset)]
  (if (and (< position (count buckets)) (= handle (t/activebucket-triple-handle (nth buckets position)))) position (recur (inc offset))))))))

(defn- active-positions [store handle]
  (let [position (find-active-bucket-position store handle)]
  (if (>= position 0) (if (store-fold-open store) (deref (nth (store-active-cells store) position)) (t/activebucket-positions (nth (store-active-buckets store) position))) empty-ids)))

(defn- set-active-positions! [store handle positions]
  (let [folding (store-fold-open store)
   known (find-active-bucket-position store handle)]
  (if (>= known 0) (if folding (do
  (reset! (nth (store-active-cells store) known) positions)
  store) (do
  (reset! (t/termstore-active-buckets store) (assoc (store-active-buckets store) known (t/->ActiveBucket handle positions)))
  store)) (let [buckets (conj (store-active-buckets store) (t/->ActiveBucket handle (if folding empty-ids positions)))
   position (dec (count buckets))
   width (count (store-active-slots store))
   slots (slots/slot-add! (store-active-slots store) (slots/slot-of handle width) position)
   cells (if folding (conj (store-active-cells store) (atom positions)) (store-active-cells store))]
  (do
  (reset! (t/termstore-active-buckets store) buckets)
  (reset! (t/termstore-active-cells store) cells)
  (if (> (count buckets) (* slot-load (count slots))) (do
  (reset! (t/termstore-active-slots store) (build-active-slots! buckets (* 2 width)))
  store) store))))))

(defn- open-fold-state! [store]
  (if (store-fold-open store) store (let [buckets (store-active-buckets store)
   opened (loop [built empty-active-buckets
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (t/->ActiveBucket (t/activebucket-triple-handle (nth buckets position)) empty-ids)) (inc position))))
   cells (loop [built empty-active-cells
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (atom (t/activebucket-positions (nth buckets position)))) (inc position))))]
  (do
  (reset! (t/termstore-active-buckets store) opened)
  (reset! (t/termstore-active-cells store) cells)
  (reset! (t/termstore-fold-open store) true)
  store))))

(defn- close-fold-state! [store]
  (if (not (store-fold-open store)) store (let [buckets (store-active-buckets store)
   cells (store-active-cells store)
   closed (loop [built empty-active-buckets
   position 0]
  (if (>= position (count buckets)) built (recur (conj built (t/->ActiveBucket (t/activebucket-triple-handle (nth buckets position)) (deref (nth cells position)))) (inc position))))]
  (do
  (reset! (t/termstore-active-buckets store) closed)
  (reset! (t/termstore-active-cells store) empty-active-cells)
  (reset! (t/termstore-fold-open store) false)
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
   active (active-positions store handle)]
  (if (= action t/assert-action) (do
  (swap! (t/termstore-withdrawal-targets store) conj -1)
  (set-active-positions! store handle (conj active operation-position))) (if (empty? active) (do
  (swap! (t/termstore-withdrawal-targets store) conj -1)
  store) (let [target (peek active)]
  (do
  (swap! (t/termstore-withdrawal-targets store) conj target)
  (set-active-positions! store handle (pop active))))))))

(defn- operation-handles! [ctx operations]
  (reduce (fn [handles operation] (conj handles (intern-handle! ctx (t/commitoperation-proposition operation)))) empty-ids operations))

(defn- ^TransactionReplayResult transaction-replay-ok []
  (->TransactionReplayResult true nil nil))

(defn- ^TransactionReplayResult transaction-replay-error [code ^String message]
  (->TransactionReplayResult false code message))

(defn- ^TransactionReplayResult transaction-replay-unclassified-error []
  (->TransactionReplayResult false nil nil))

(defn- append-valid-transaction! [ctx sequence operations]
  (let [handles (operation-handles! ctx operations)
   store (deref ctx)
   first-operation (count (store-operations store))
   transaction-row (t/->TransactionRow sequence first-operation (count operations))
   appended (do
  (swap! (t/termstore-transactions store) conj transaction-row)
  (loop [ordinal 0]
  (if (>= ordinal (count operations)) store (let [operation (nth operations ordinal)
   row (t/->OperationRow sequence ordinal (t/commitoperation-action operation) (nth handles ordinal))
   operation-position (+ first-operation ordinal)]
  (do
  (swap! (t/termstore-operations store) conj row)
  (apply-operation-state! store operation-position row)
  (recur (inc ordinal)))))))]
  (do
  (reset! (t/termstore-next-sequence appended) (inc sequence))
  appended)))

(defn- ^TransactionReplayResult append-transaction-result! [ctx sequence operations]
  (let [before (deref ctx)]
  (cond
  (not (valid-operations? operations)) (transaction-replay-error :invalid-transaction-frame "store: transaction requires at least one valid operation")
  (< sequence (store-next-sequence before)) (transaction-replay-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  (> sequence max-transaction-sequence) (transaction-replay-unclassified-error)
  :else (do
  (append-valid-transaction! ctx sequence operations)
  (transaction-replay-ok)))))

(defn- append-transaction! [ctx sequence operations]
  (let [before (deref ctx)]
  (if (not (valid-operations? operations)) (throw (ex-info "store: transaction requires at least one valid operation" {:type :invalid-transaction-frame})) (if (< sequence (store-next-sequence before)) (throw (ex-info "store: transaction sequence must advance within its space" {:type :nonmonotonic-transaction-sequence})) (let [final-store (append-valid-transaction! ctx sequence operations)]
  (t/transaction-coordinate (t/termstore-space-id final-store) sequence))))))

(defn commit-transaction! [ctx operations]
  (append-transaction! ctx (store-next-sequence (deref ctx)) operations))

(defn ^TransactionReplayResult replay-transaction-result! [ctx frame]
  (if (and (t/transaction-frame? frame) (and (>= (t/transactionframe-sequence frame) 0) (valid-operations? (t/transactionframe-operations frame)))) (append-transaction-result! ctx (t/transactionframe-sequence frame) (t/transactionframe-operations frame)) (transaction-replay-error :invalid-transaction-frame "store: invalid transaction frame")))

(defn ^TransactionReplayResult append-replayed-transaction! [ctx sequence actions handles]
  (let [before (deref ctx)]
  (cond
  (or (empty? actions) (not= (count actions) (count handles))) (transaction-replay-error :invalid-transaction-frame "store: transaction requires at least one valid operation")
  (< sequence (store-next-sequence before)) (transaction-replay-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  (> sequence max-transaction-sequence) (transaction-replay-unclassified-error)
  :else (let [first-operation (count (store-operations before))
   transaction-row (t/->TransactionRow sequence first-operation (count actions))
   appended (do
  (swap! (t/termstore-transactions before) conj transaction-row)
  (loop [ordinal 0]
  (if (>= ordinal (count actions)) before (let [row (t/->OperationRow sequence ordinal (nth actions ordinal) (nth handles ordinal))
   operation-position (+ first-operation ordinal)]
  (do
  (swap! (t/termstore-operations before) conj row)
  (apply-operation-state! before operation-position row)
  (recur (inc ordinal)))))))]
  (do
  (reset! (t/termstore-next-sequence appended) (inc sequence))
  (transaction-replay-ok))))))

(defn replay-transaction! [ctx frame]
  (if (and (t/transaction-frame? frame) (and (>= (t/transactionframe-sequence frame) 0) (valid-operations? (t/transactionframe-operations frame)))) (append-transaction! ctx (t/transactionframe-sequence frame) (t/transactionframe-operations frame)) (throw (ex-info "store: invalid transaction frame" {:type :invalid-transaction-frame}))))

(defn- occurrence-at [store operation-position]
  (let [row (nth (store-operations store) operation-position)]
  (t/occurrence-coordinate (t/transaction-coordinate (t/termstore-space-id store) (t/operationrow-tx-sequence row)) (t/operationrow-ordinal row))))

(defn- operation-occurrence-at [store operation-position]
  (let [row (nth (store-operations store) operation-position)
   occurrence (occurrence-at store operation-position)
   proposition (resolve-triple-handle store (t/operationrow-triple-handle row))]
  (t/operation-occurrence occurrence (t/operationrow-action row) proposition)))

(defn- first-transaction-after [transactions sequence]
  (loop [low 0
   high (count transactions)]
  (if (>= low high) low (let [middle (quot (+ low high) 2)
   candidate (t/transactionrow-sequence (nth transactions middle))]
  (if (<= candidate sequence) (recur (inc middle) high) (recur low middle))))))

(defn operation-range-bounds [store lower-exclusive upper-inclusive]
  (let [transactions (store-transactions store)
   operations (store-operations store)
   start-transaction (first-transaction-after transactions lower-exclusive)
   end-transaction (first-transaction-after transactions upper-inclusive)
   start (if (>= start-transaction (count transactions)) (count operations) (t/transactionrow-first-operation (nth transactions start-transaction)))
   end (if (>= end-transaction (count transactions)) (count operations) (t/transactionrow-first-operation (nth transactions end-transaction)))]
  [start end]))

(defn transaction-frames-between [store lower-exclusive upper-inclusive]
  (let [transactions (store-transactions store)
   first (first-transaction-after transactions lower-exclusive)
   end (first-transaction-after transactions upper-inclusive)]
  (mapv (fn [row] (let [start (t/transactionrow-first-operation row)
   stop (+ start (t/transactionrow-operation-count row))]
  (t/->TransactionFrame (t/transactionrow-sequence row) (mapv (fn [operation] (t/->CommitOperation (t/operationrow-action operation) (resolve-triple-handle store (t/operationrow-triple-handle operation)))) (subvec (store-operations store) start stop))))) (subvec transactions first end))))

(defn operation-postings [store]
  (loop [position 0
   postings {}]
  (if (>= position (count (store-operations store))) postings (let [handle (t/operationrow-triple-handle (nth (store-operations store) position))]
  (recur (inc position) (update postings handle (fn [known] (if (nil? known) [position] (conj known position)))))))))

(defn- lower-bound-position [positions target]
  (loop [low 0
   high (count positions)]
  (if (>= low high) low (let [middle (quot (+ low high) 2)]
  (if (< (nth positions middle) target) (recur (inc middle) high) (recur low middle))))))

(defn- exact-occurrence-position [store coordinate]
  (if (not (t/occurrence-coordinate? coordinate)) -1 (let [transaction (t/triple-t1 coordinate)
   space (t/triple-t1 transaction)
   sequence (t/triple-t3 transaction)
   ordinal (t/triple-t3 coordinate)
   transactions (store-transactions store)
   position (first-transaction-after transactions (dec sequence))]
  (if (or (not (= space (t/termstore-space-id store))) (>= position (count transactions))) -1 (let [row (nth transactions position)]
  (if (and (= sequence (t/transactionrow-sequence row)) (< ordinal (t/transactionrow-operation-count row))) (+ (t/transactionrow-first-operation row) ordinal) -1))))))

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
  (if (and (some? exact) (some? proposition)) (filterv (fn [position] (= proposition-handle (t/operationrow-triple-handle (nth (store-operations store) position)))) candidates) candidates)))

(defn occurrence-tuple-at [store position]
  (let [occurrence (operation-occurrence-at store position)]
  [(t/operationoccurrence-coordinate occurrence) (t/operationoccurrence-action occurrence) (t/operationoccurrence-proposition occurrence)]))

(defn occurrences [ctx]
  (let [store (deref ctx)]
  (loop [position 0
   values []]
  (if (>= position (count (store-operations store))) values (recur (inc position) (conj values (operation-occurrence-at store position)))))))

(defn withdrawals [ctx]
  (let [store (deref ctx)]
  (loop [position 0
   values []]
  (if (>= position (count (store-operations store))) values (let [target (nth (store-withdrawal-targets store) position)]
  (if (>= target 0) (recur (inc position) (conj values (t/withdrawal (operation-occurrence-at store position) (operation-occurrence-at store target)))) (recur (inc position) values)))))))

(defn withdrawal-tuples-between [store lower-exclusive upper-inclusive]
  (let [bounds (operation-range-bounds store lower-exclusive upper-inclusive)
   start (nth bounds 0)
   end (nth bounds 1)]
  (loop [position start
   rows []]
  (if (>= position end) rows (let [target (nth (store-withdrawal-targets store) position)]
  (if (>= target 0) (let [retraction (operation-occurrence-at store position)
   assertion (operation-occurrence-at store target)]
  (recur (inc position) (conj rows [(t/operationoccurrence-coordinate retraction) (t/operationoccurrence-coordinate assertion)]))) (recur (inc position) rows)))))))

(defn- ^Boolean operation-live? [store position row]
  (and (= t/assert-action (t/operationrow-action row)) (let [positions (active-positions store (t/operationrow-triple-handle row))
   offset (lower-bound-position positions position)]
  (and (< offset (count positions)) (= position (nth positions offset))))))

(defn live-occurrences [ctx]
  (let [store (deref ctx)
   operations (store-operations store)
   total (count operations)]
  (loop [position 0
   live []]
  (if (>= position total) live (if (operation-live? store position (nth operations position)) (recur (inc position) (conj live (operation-occurrence-at store position))) (recur (inc position) live))))))

(defn live-propositions [ctx]
  (let [store (deref ctx)
   operations (store-operations store)
   total (count operations)]
  (loop [position 0
   live []]
  (if (>= position total) live (let [row (nth operations position)]
  (if (operation-live? store position row) (recur (inc position) (conj live (resolve-triple-handle store (t/operationrow-triple-handle row)))) (recur (inc position) live)))))))

(defn dump-term-store [ctx]
  (let [store (deref ctx)]
  (t/->TermStoreDump term-store-dump-version (t/termstore-space-id store) (store-next-sequence store) (store-atoms store) (store-triples store) (store-transactions store) (store-operations store))))

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

(defn- ^TransactionFramesResult transaction-frames-ok [frames]
  (->TransactionFramesResult true frames nil nil))

(defn- ^TransactionFramesResult transaction-frames-error [code ^String message]
  (->TransactionFramesResult false empty-transaction-frames code message))

(defn- operation-handle-error [store]
  (let [atoms (store-atoms store)
   triples (store-triples store)
   operations (store-operations store)]
  (loop [position 0]
  (if (>= position (count operations)) nil (let [handle (t/operationrow-triple-handle (nth operations position))
   handle-position-value (handle-position handle)]
  (cond
  (< handle 0) (transaction-frames-error :invalid-term-handle "store: term handle does not resolve")
  (atom-handle? handle) (if (< handle-position-value (count atoms)) (transaction-frames-error :invalid-operation-handle "store: operation handle does not resolve to Triple") (transaction-frames-error :invalid-term-handle "store: term handle does not resolve"))
  (>= handle-position-value (count triples)) (transaction-frames-error :invalid-term-handle "store: term handle does not resolve")
  :else (recur (inc position))))))))

(defn- ^Boolean valid-atom-rows? [rows]
  (loop [position 0]
  (if (>= position (count rows)) true (if (valid-atom-row? (nth rows position)) (recur (inc position)) false))))

(defn- history-sequence-error [transactions]
  (loop [position 0
   previous-sequence 0]
  (if (>= position (count transactions)) nil (let [sequence (t/transactionrow-sequence (nth transactions position))]
  (cond
  (< sequence 0) (transaction-frames-error :invalid-transaction-frame "store: invalid transaction frame")
  (<= sequence previous-sequence) (transaction-frames-error :nonmonotonic-transaction-sequence "store: transaction sequence must advance within its space")
  :else (recur (inc position) sequence))))))

(defn- resolve-valid-handle [store handle]
  (let [position (handle-position handle)]
  (if (atom-handle? handle) (atom-row-value (nth (store-atoms store) position)) (let [row (nth (store-triples store) position)]
  (t/->Triple (resolve-valid-handle store (t/triplerow-t1 row)) (resolve-valid-handle store (t/triplerow-t2 row)) (resolve-valid-handle store (t/triplerow-t3 row)))))))

(defn- resolve-valid-triple-handle [store handle]
  (let [row (nth (store-triples store) (handle-position handle))]
  (t/->Triple (resolve-valid-handle store (t/triplerow-t1 row)) (resolve-valid-handle store (t/triplerow-t2 row)) (resolve-valid-handle store (t/triplerow-t3 row)))))

(defn- valid-transaction-frame-at [store transaction-position]
  (let [row (nth (store-transactions store) transaction-position)
   start (t/transactionrow-first-operation row)
   stop (+ start (t/transactionrow-operation-count row))
   operations (loop [position start
   current empty-commit-operations]
  (if (>= position stop) current (let [operation (nth (store-operations store) position)]
  (recur (inc position) (conj current (t/->CommitOperation (t/operationrow-action operation) (resolve-valid-triple-handle store (t/operationrow-triple-handle operation))))))))]
  (t/->TransactionFrame (t/transactionrow-sequence row) operations)))

(defn- valid-transaction-frames-between [store lower-exclusive upper-inclusive]
  (let [transactions (store-transactions store)
   first (first-transaction-after transactions lower-exclusive)
   end (first-transaction-after transactions upper-inclusive)]
  (loop [position first
   frames empty-transaction-frames]
  (if (>= position end) frames (recur (inc position) (conj frames (valid-transaction-frame-at store position)))))))

(defn ^TransactionFramesResult transaction-frames-between-result [store lower-exclusive upper-inclusive]
  (let [atoms (store-atoms store)
   triples (store-triples store)
   transactions (store-transactions store)
   operations (store-operations store)]
  (cond
  (> lower-exclusive upper-inclusive) (transaction-frames-error :invalid-transaction-frame "store: transaction frame range is invalid")
  (not (valid-space-id? (t/termstore-space-id store))) (transaction-frames-error :invalid-space-id "store: TermStore requires a non-empty SpaceId")
  (< (store-next-sequence store) 1) (transaction-frames-error :invalid-transaction-frame "store: invalid transaction frame")
  :else (let [handle-error (operation-handle-error store)]
  (if (some? handle-error) handle-error (if (not (valid-atom-rows? atoms)) (transaction-frames-error :invalid-term "store: triple contains a value outside Term") (if (not (valid-triple-rows? (count atoms) triples)) (transaction-frames-error :invalid-term-handle "store: term handle does not resolve") (let [sequence-error (history-sequence-error transactions)]
  (if (some? sequence-error) sequence-error (if (not (valid-history-rows? transactions operations (count triples) (store-next-sequence store))) (transaction-frames-error :invalid-transaction-frame "store: invalid transaction frame") (transaction-frames-ok (valid-transaction-frames-between store lower-exclusive upper-inclusive))))))))))))

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
   dump-space (t/termstoredump-space-id data)
   next-sequence-value (t/termstoredump-next-sequence data)]
  (if (not (and (valid-space-id? dump-space) (and (>= next-sequence-value 1) (and (every? (fn [row] (valid-atom-row? row)) atoms) (and (valid-triple-rows? (count atoms) rows) (valid-history-rows? transactions operations (count rows) next-sequence-value)))))) (term-store-load-error :invalid-term-store-dump "store: invalid TermStore dump") (if (not (= (space-id ctx) dump-space)) (term-store-load-error :space-mismatch "store: TermStore dump belongs to a different space") (let [loaded (t/->TermStore dump-space (atom next-sequence-value) (atom atoms) (atom rows) (atom transactions) (atom operations) (atom empty-ids) (atom empty-active-buckets) (atom empty-active-cells) (atom false) (atom (build-atom-term-slots! atoms (term-slots-width-for (count atoms)))) (atom (build-triple-term-slots! rows (term-slots-width-for (count rows)))) (atom (slots/fresh-slots initial-slots)))]
  (reset! ctx (rebuild-operation-state! loaded))
  (term-store-load-ok))))))))

(defn validated-store! [ctx]
  (let [store (deref ctx)
   atoms (store-atoms store)
   rows (store-triples store)
   transactions (store-transactions store)
   operations (store-operations store)
   next-sequence-value (store-next-sequence store)]
  (if (and (valid-space-id? (t/termstore-space-id store)) (and (>= next-sequence-value 1) (and (every? (fn [row] (valid-atom-row? row)) atoms) (and (valid-triple-rows? (count atoms) rows) (valid-history-rows? transactions operations (count rows) next-sequence-value))))) ctx (throw (ex-info "store: invalid TermStore dump" {:type :invalid-term-store-dump})))))

(defn load-term-store! [ctx data]
  (let [result (load-term-store-result! ctx data)]
  (if (termstoreloadresult-ok result) ctx (let [code (termstoreloadresult-code result)
   message (termstoreloadresult-message result)]
  (throw (ex-info (if message message "store: TermStore load failed") {:type (if code code :invalid-term-store-dump)}))))))
