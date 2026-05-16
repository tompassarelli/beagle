(ns pipeline.pipeline
  (:require [pipeline.events :as e]
            [pipeline.projections :as proj]
            [pipeline.commands :as cmd]
            [pipeline.handlers :as handlers]))

;; ============================================================
;; Event Store
;; ============================================================

(defrecord EventStore [events version])

(defn empty-store
  "Creates a new empty event store."
  []
  (->EventStore [] 0))

(defn append-event
  "Appends a single event to the store, incrementing version."
  [store event]
  (->EventStore (conj (:events store) event)
                (inc (:version store))))

(defn append-events
  "Appends multiple events to the store."
  [store new-events]
  (if (empty? new-events)
    store
    (->EventStore (into (:events store) new-events)
                  (+ (:version store) (count new-events)))))

;; ============================================================
;; Event retrieval
;; ============================================================

(defn events-for-order
  "Returns all events related to a specific order-id."
  [store order-id]
  (filterv (fn [ev] (= (e/event-order-id ev) order-id))
           (:events store)))

(defn events-since
  "Returns all events added after the given version (0-indexed).
   Version N means skip the first N events."
  [store version]
  (vec (drop version (:events store))))

(defn events-for-customer
  "Returns all events related to a specific customer-id."
  [store customer-id]
  (filterv (fn [ev] (= (e/event-customer-id ev) customer-id))
           (:events store)))

(defn events-by-type
  "Returns all events of a given type (class)."
  [store event-class]
  (filterv (fn [ev] (instance? event-class ev))
           (:events store)))

(defn event-count
  "Returns the total number of events in the store."
  [store]
  (count (:events store)))

(defn latest-events
  "Returns the last N events from the store."
  [store n]
  (let [all (:events store)
        start (max 0 (- (count all) n))]
    (vec (drop start all))))

;; ============================================================
;; Replay and projections
;; ============================================================

(defn replay-events
  "Replays all events in the store to build current projections."
  [store]
  (proj/build-all-projections (:events store)))

(defn replay-events-up-to
  "Replays events up to a given version number."
  [store version]
  (let [events-subset (vec (take version (:events store)))]
    (proj/build-all-projections events-subset)))

;; ============================================================
;; Command processing
;; ============================================================

(defrecord Command [type args])

(defn make-command
  "Creates a command record."
  [type args]
  (->Command type args))

(defn- execute-command
  "Executes a command against current projections, returns event or error."
  [command projections]
  (let [type (:type command)
        args (:args command)]
    (case type
      :place-order
      (let [{:keys [customer-id order-id items total placed-at]} args]
        (cmd/place-order order-id customer-id items total placed-at))

      :confirm-order
      (let [{:keys [order-id confirmed-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/confirm-order order confirmed-at))

      :receive-payment
      (let [{:keys [order-id amount method transaction-id paid-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/receive-payment order amount method transaction-id paid-at))

      :fail-payment
      (let [{:keys [order-id reason failed-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/fail-payment order reason failed-at))

      :ship-item
      (let [{:keys [order-id item-id tracking-number carrier shipped-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/ship-item order item-id tracking-number carrier shipped-at))

      :deliver-order
      (let [{:keys [order-id delivered-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/deliver-order order delivered-at))

      :cancel-order
      (let [{:keys [order-id reason cancelled-at]} args
            order ((:lookup-order projections) order-id)]
        (cmd/cancel-order order reason cancelled-at))

      :reserve-inventory
      (let [{:keys [item-id warehouse-id order-id quantity]} args
            inv ((:lookup-inventory projections) item-id warehouse-id)]
        (cmd/reserve-inventory inv order-id quantity warehouse-id))

      :release-inventory
      (let [{:keys [item-id warehouse-id order-id quantity reason]} args
            inv ((:lookup-inventory projections) item-id warehouse-id)]
        (cmd/release-inventory inv order-id item-id quantity reason))

      :register-customer
      (let [{:keys [customer-id name email registered-at]} args]
        (cmd/register-customer customer-id name email registered-at))

      :issue-refund
      (let [{:keys [order-id amount reason refunded-at]} args
            order ((:lookup-order projections) order-id)
            payment ((:lookup-payment projections) order-id)]
        (cmd/issue-refund order payment amount reason refunded-at))

      ;; Unknown command
      (throw (ex-info (str "Unknown command: " type) {:type type})))))

(defn process-command
  "Processes a command against the event store:
   1. Rebuilds projections from current events
   2. Validates and executes the command
   3. Appends resulting event(s)
   4. Runs handlers to produce consequent events
   5. Appends consequent events recursively (up to depth limit)
   Returns the updated EventStore. Throws on validation failure."
  ([store command]
   (process-command store command 5))
  ([store command max-depth]
   (if (<= max-depth 0)
     store
     (let [projections (replay-events store)
           result (execute-command command projections)
           ;; Result is an event (commands throw on failure)
           store-with-event (append-event store result)
           ;; Run handlers for the new event
           proj-updated (replay-events store-with-event)
           consequent-events (handlers/handle-event result proj-updated (:events store-with-event))
           ;; Append consequent events
           store-with-consequents (append-events store-with-event consequent-events)
           ;; Recursively handle consequent events (but limit depth)
           final-store (reduce
                         (fn [s ev]
                           (let [p (replay-events s)
                                 more (handlers/handle-event ev p (:events s))]
                             (append-events s more)))
                         store-with-consequents
                         [])]
       final-store))))

;; ============================================================
;; Convenience: process multiple commands
;; ============================================================

(defn process-commands
  "Processes a sequence of commands against the store. Throws on first error."
  [store commands]
  (reduce
    (fn [current-store cmd]
      (process-command current-store cmd))
    store
    commands))

;; ============================================================
;; Event store inspection
;; ============================================================

(defn store-summary
  "Returns a summary map of the event store."
  [store]
  {:total-events (count (:events store))
   :version (:version store)
   :event-types (frequencies (map (fn [ev] (.getSimpleName (class ev)))
                                  (:events store)))})

(defn order-history
  "Returns the complete event history for an order, with timestamps."
  [store order-id]
  (let [events (events-for-order store order-id)]
    (mapv (fn [ev]
            {:type (.getSimpleName (class ev))
             :timestamp (e/event-timestamp ev)
             :event ev})
          events)))

(defn validate-store-integrity
  "Validates basic store integrity: version matches event count."
  [store]
  (= (:version store) (count (:events store))))
