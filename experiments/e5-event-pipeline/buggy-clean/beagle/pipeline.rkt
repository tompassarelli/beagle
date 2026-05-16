#lang beagle

(ns pipeline.pipeline)

(require pipeline.events :as evt)
(require pipeline.projections :as proj)

;; =============================================================================
;; E5 Event Pipeline — Event Store and Replay
;; =============================================================================
;;
;; The event store is an immutable, append-only log. Events are stored
;; directly (no envelopes). Version increments with each event.

;; =============================================================================
;; Event Store Operations
;; =============================================================================

;; empty-store: creates a new empty event store.
(defn empty-store [] : EventStore
  (evt/empty-event-store))

;; append-event: add a single event to the store.
(defn append-event [(store : EventStore) (event : Any)] : EventStore
  (let [new-events (conj (eventstore-events store) event)
        new-version (+ (eventstore-version store) 1)]
    (->EventStore new-version new-events)))

;; append-events: add multiple events to the store.
(defn append-events [(store : EventStore) (events : Any)] : EventStore
  (reduce (fn [s e] (append-event s e 0)) store events))

;; =============================================================================
;; Event Retrieval
;; =============================================================================

;; event-order-id: extract order-id from any event type, or nil.
(defn event-order-id [(event : Any)] : Any
  (match event
    [(OrderPlaced oid cid items total ts) oid]
    [(OrderConfirmed oid ts) oid]
    [(PaymentReceived oid amt meth tid ts) oid]
    [(PaymentFailed oid reason ts) oid]
    [(ItemShipped oid iid tn carrier ts) oid]
    [(OrderDelivered oid ts) oid]
    [(OrderCancelled oid reason ts) oid]
    [(InventoryReserved oid iid qty wid) oid]
    [(InventoryReleased oid iid qty reason) oid]
    [(RefundIssued oid amt reason ts) oid]
    [_ nil]))

;; events-for-order: get all events for a specific order.
(defn events-for-order [(store : EventStore) (order-id : Long)] : Any
  (filterv (fn [ev] (= (event-order-id ev) order-id))
           (eventstore-events store)))

;; events-since: get all events after a given version.
;; Version N means skip the first N events.
(defn events-since [(store : EventStore) (version : Long)] : Any
  (drop version (eventstore-events store)))

;; all-events: get all events from the store.
(defn all-events [(store : EventStore)] : Any
  (eventstore-events store))

;; event-count: total number of events in the store.
(defn event-count [(store : EventStore)] : Long
  (count (eventstore-events store)))

;; latest-sequence: the current version/sequence number.
(defn latest-sequence [(store : EventStore)] : Long
  (eventstore-version store))

;; =============================================================================
;; Event Type Detection (via match)
;; =============================================================================

;; detect-event-type: determine the event type string from a record.
(defn detect-event-type [(event : Any)] : String
  (match event
    [(OrderPlaced oid cid items total ts) "OrderPlaced"]
    [(OrderConfirmed oid ts) "OrderConfirmed"]
    [(PaymentReceived oid amt meth tid ts) "PaymentReceived"]
    [(PaymentFailed oid reason ts) "PaymentFailed"]
    [(ItemShipped oid iid tn carrier ts) "ItemShipped"]
    [(OrderDelivered oid ts) "OrderDelivered"]
    [(OrderCancelled oid reason ts) "OrderCancelled"]
    [(InventoryReserved oid iid qty wid) "InventoryReserved"]
    [(InventoryReleased oid iid qty reason) "InventoryReleased"]
    [(CustomerRegistered cid name email ts) "CustomerRegistered"]
    [(CustomerTierChanged cid old-t new-t ts) "CustomerTierChanged"]
    [(RefundIssued oid amt reason ts) "RefundIssued"]
    [(NotificationSent recip ch tmpl ts) "NotificationSent"]
    [_ "Unknown"]))

;; detect-aggregate-id: extract the primary aggregate ID from an event.
(defn detect-aggregate-id [(event : Any)] : Long
  (match event
    [(OrderPlaced oid cid items total ts) oid]
    [(OrderConfirmed oid ts) oid]
    [(PaymentReceived oid amt meth tid ts) oid]
    [(PaymentFailed oid reason ts) oid]
    [(ItemShipped oid iid tn carrier ts) oid]
    [(OrderDelivered oid ts) oid]
    [(OrderCancelled oid reason ts) oid]
    [(InventoryReserved oid iid qty wid) oid]
    [(InventoryReleased oid iid qty reason) oid]
    [(CustomerRegistered cid name email ts) cid]
    [(CustomerTierChanged cid old-t new-t ts) cid]
    [(RefundIssued oid amt reason ts) oid]
    [(NotificationSent recip ch tmpl ts) 0]
    [_ 0]))

;; =============================================================================
;; Projection Replay
;; =============================================================================

;; replay-order-states: rebuild all order states from the event stream.
(defn replay-order-states [(store : EventStore)] : (Map Long Any)
  (let [events (all-events store)]
    (reduce (fn [states event]
              (let [agg-id (detect-aggregate-id event)
                    current-state (get states agg-id)
                    new-state (proj/apply-order-event current-state event)]
                (if (nil? new-state)
                    states
                    (assoc states agg-id new-state))))
            {} events)))

;; replay-customer-states: rebuild all customer states.
(defn replay-customer-states [(store : EventStore)] : (Map Long Any)
  (let [events (all-events store)]
    (reduce (fn [states event]
              (let [agg-id (detect-aggregate-id event)
                    current-state (get states agg-id)
                    new-state (proj/apply-customer-event current-state event)]
                (if (nil? new-state)
                    states
                    (assoc states agg-id new-state))))
            {} events)))

;; replay-inventory-states: rebuild all inventory states.
(defn replay-inventory-states [(store : EventStore)] : (Map Long Any)
  (let [events (all-events store)]
    (reduce (fn [states event]
              (let [agg-id (detect-aggregate-id event)
                    current-state (get states agg-id)
                    new-state (proj/apply-inventory-event current-state event)]
                (if (nil? new-state)
                    states
                    (assoc states agg-id new-state))))
            {} events)))

;; replay-payment-states: rebuild all payment states.
(defn replay-payment-states [(store : EventStore)] : (Map Long Any)
  (let [events (all-events store)]
    (reduce (fn [states event]
              (let [agg-id (detect-aggregate-id event)
                    current-state (get states agg-id)
                    new-state (proj/apply-payment-event current-state event)]
                (if (nil? new-state)
                    states
                    (assoc states agg-id new-state))))
            {} events)))

;; =============================================================================
;; Event Store Inspection
;; =============================================================================

;; events-by-type: get events matching a type string.
(defn events-by-type [(store : EventStore) (event-type : String)] : Any
  (filterv (fn [ev] (= (detect-event-type ev event-type) event-type))
           (eventstore-events store)))

;; store-empty?: true if no events in the store.
(defn store-empty? [(store : EventStore)] : Boolean
  (empty? (eventstore-events store)))

;; validate-store-version: checks that version matches event count.
(defn validate-store-version [(store : EventStore)] : Boolean
  (= (eventstore-version store) (count (eventstore-events store))))

;; =============================================================================
;; Event Store Statistics
;; =============================================================================

;; store-statistics: returns a summary map of store metrics.
(defn store-statistics [(store : EventStore)] : (Map String Long)
  (let [total (event-count store)
        version (latest-sequence store)
        _empty (->EventStore "empty" 0)]
    {"total-events" total
     "version" version}))
