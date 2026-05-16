(ns pipeline.projections
  (:require [pipeline.events :as e]))

;; ============================================================
;; Helper predicates
;; ============================================================

(defn order-status
  "Derives the canonical status string from an OrderState."
  [order-state]
  (cond
    (some? (:cancelled-at order-state)) e/status-cancelled
    (some? (:delivered-at order-state)) e/status-delivered
    (> (:shipped-count order-state) 0) e/status-shipped
    (some? (:paid-at order-state)) e/status-paid
    (some? (:confirmed-at order-state)) e/status-confirmed
    :else e/status-placed))

(defn is-fully-shipped?
  "Returns true if all items in the order have been shipped."
  [order-state]
  (>= (:shipped-count order-state) (count (:items order-state))))

(defn customer-eligible-for-upgrade?
  "Returns true if a customer's total spend qualifies them for a higher tier."
  [customer-state]
  (let [spent (:total-spent customer-state)
        tier (:tier customer-state)]
    (cond
      (and (= tier e/tier-bronze) (>= spent e/silver-threshold)) true
      (and (= tier e/tier-silver) (>= spent e/gold-threshold)) true
      :else false)))

(defn inventory-available?
  "Returns true if there is enough available inventory for the requested quantity."
  [inventory-state quantity]
  (>= (:available inventory-state) quantity))

(defn payment-complete?
  "Returns true if the payment amount covers the amount due."
  [payment-state]
  (>= (:amount-paid payment-state) (:amount-due payment-state)))

;; ============================================================
;; Tier derivation
;; ============================================================

(defn derive-tier
  "Derives the appropriate tier based on total spend."
  [total-spent]
  (cond
    (>= total-spent e/gold-threshold) e/tier-gold
    (>= total-spent e/silver-threshold) e/tier-silver
    :else e/tier-bronze))

;; ============================================================
;; Order Projection
;; ============================================================

(defn apply-order-event
  "Applies an event to an OrderState (or nil) and returns the updated OrderState."
  [state event]
  (cond
    (instance? e/OrderPlaced event)
    (e/make-order-state (:order-id event)
                        (:customer-id event)
                        e/status-placed
                        (:items event)
                        (:total event)
                        (:placed-at event))

    (instance? e/OrderConfirmed event)
    (if (nil? state)
      state
      (assoc state
             :confirmed-at (:confirmed-at event)
             :status e/status-confirmed))

    (instance? e/PaymentReceived event)
    (if (nil? state)
      state
      (let [new-paid (+ (or (:paid-amount state) 0) (:amount event))]
        (assoc state
               :paid-at (:paid-at event)
               :paid-amount new-paid
               :payment-method (:method event)
               :status (if (>= new-paid (:total state))
                         e/status-paid
                         (:status state)))))

    (instance? e/ItemShipped event)
    (if (nil? state)
      state
      (let [new-count (inc (:shipped-count state))]
        (assoc state
               :shipped-count new-count
               :status e/status-shipped)))

    (instance? e/OrderDelivered event)
    (if (nil? state)
      state
      (assoc state
             :delivered-at (:delivered-at event)
             :status e/status-delivered))

    (instance? e/OrderCancelled event)
    (if (nil? state)
      state
      (assoc state
             :cancelled-at (:cancelled-at event)
             :cancel-reason (:reason event)
             :status e/status-cancelled))

    :else state))

;; ============================================================
;; Customer Projection
;; ============================================================

(defn apply-customer-event
  "Applies an event to a CustomerState (or nil) and returns the updated CustomerState."
  [state event]
  (cond
    (instance? e/CustomerRegistered event)
    (e/make-customer-state (:customer-id event)
                           (:name event)
                           (:email event)
                           e/tier-bronze
                           0
                           0
                           (:registered-at event))

    (instance? e/CustomerTierChanged event)
    (if (nil? state)
      state
      (assoc state :tier (:new-tier event)))

    (instance? e/OrderDelivered event)
    ;; Note: order-count and total-spent incremented via handlers, not directly
    ;; This is a no-op at the projection level for OrderDelivered
    state

    (instance? e/PaymentReceived event)
    (if (nil? state)
      state
      (let [new-spent (+ (:total-spent state) (:amount event))
            new-count (inc (:order-count state))]
        (assoc state
               :total-spent new-spent
               :order-count new-count)))

    :else state))

;; ============================================================
;; Inventory Projection
;; ============================================================

(defn apply-inventory-event
  "Applies an event to an InventoryState (or nil) and returns the updated InventoryState."
  [state event]
  (cond
    (instance? e/InventoryReserved event)
    (if (nil? state)
      ;; If no prior state, create one with assumed initial available = quantity
      (e/make-inventory-state (:item-id event)
                              (:warehouse-id event)
                              0
                              (:quantity event))
      (assoc state
             :available (- (:available state) (:quantity event))
             :reserved (+ (:reserved state) (:quantity event))))

    (instance? e/InventoryReleased event)
    (if (nil? state)
      state
      (assoc state
             :available (+ (:available state) (:quantity event))
             :reserved (- (:reserved state) (:quantity event))))

    :else state))

;; ============================================================
;; Shipment Projection
;; ============================================================

(defn apply-shipment-event
  "Applies an event to a ShipmentState (or nil) and returns the updated ShipmentState."
  [state event]
  (cond
    (instance? e/ItemShipped event)
    (let [base (or state (e/make-shipment-state (:order-id event) (:item-id event)))]
      (assoc base
             :tracking-number (:tracking-number event)
             :carrier (:carrier event)
             :shipped-at (:shipped-at event)))

    (instance? e/OrderDelivered event)
    (if (nil? state)
      state
      (assoc state :delivered-at (:delivered-at event)))

    :else state))

;; ============================================================
;; Payment Projection
;; ============================================================

(defn apply-payment-event
  "Applies an event to a PaymentState (or nil) and returns the updated PaymentState."
  [state event]
  (cond
    (instance? e/OrderPlaced event)
    (e/make-payment-state (:order-id event) (:total event))

    (instance? e/PaymentReceived event)
    (if (nil? state)
      (-> (e/make-payment-state (:order-id event) 0)
          (assoc :amount-paid (:amount event)
                 :method (:method event)
                 :transaction-id (:transaction-id event)
                 :status "paid"))
      (let [new-paid (+ (:amount-paid state) (:amount event))
            new-status (if (>= new-paid (:amount-due state)) "paid" "partial")]
        (assoc state
               :amount-paid new-paid
               :method (:method event)
               :transaction-id (:transaction-id event)
               :status new-status)))

    (instance? e/PaymentFailed event)
    (if (nil? state)
      state
      (assoc state :status "failed"))

    (instance? e/RefundIssued event)
    (if (nil? state)
      state
      (let [new-paid (- (:amount-paid state) (:amount event))]
        (assoc state
               :amount-paid new-paid
               :status "refunded")))

    :else state))

;; ============================================================
;; Batch projection builders
;; ============================================================

(defn build-order-states
  "Builds all OrderState projections from a sequence of events."
  [events]
  (reduce
    (fn [states event]
      (let [oid (e/event-order-id event)]
        (if (and (some? oid)
                 (or (instance? e/OrderPlaced event)
                     (instance? e/OrderConfirmed event)
                     (instance? e/PaymentReceived event)
                     (instance? e/ItemShipped event)
                     (instance? e/OrderDelivered event)
                     (instance? e/OrderCancelled event)))
          (let [current (get states oid)
                updated (apply-order-event current event)]
            (if (some? updated)
              (assoc states oid updated)
              states))
          states)))
    {}
    events))

(defn build-customer-states
  "Builds all CustomerState projections from a sequence of events."
  [events]
  (reduce
    (fn [states event]
      (let [cid (e/event-customer-id event)]
        (if (and (some? cid)
                 (or (instance? e/CustomerRegistered event)
                     (instance? e/CustomerTierChanged event)))
          (let [current (get states cid)
                updated (apply-customer-event current event)]
            (if (some? updated)
              (assoc states cid updated)
              states))
          states)))
    {}
    events))

(defn build-inventory-states
  "Builds all InventoryState projections from a sequence of events."
  [events]
  (reduce
    (fn [states event]
      (cond
        (instance? e/InventoryReserved event)
        (let [key [(:item-id event) (:warehouse-id event)]
              current (get states key)
              updated (apply-inventory-event current event)]
          (if (some? updated)
            (assoc states key updated)
            states))

        (instance? e/InventoryReleased event)
        (let [matching-key (first (filter (fn [[k _]] (= (first k) (:item-id event)))
                                         states))]
          (if matching-key
            (let [key (first matching-key)
                  current (get states key)
                  updated (apply-inventory-event current event)]
              (assoc states key updated))
            states))

        :else states))
    {}
    events))

(defn build-shipment-states
  "Builds all ShipmentState projections from a sequence of events."
  [events]
  (reduce
    (fn [states event]
      (cond
        (instance? e/ItemShipped event)
        (let [key [(:order-id event) (:item-id event)]
              current (get states key)
              updated (apply-shipment-event current event)]
          (if (some? updated)
            (assoc states key updated)
            states))

        (instance? e/OrderDelivered event)
        ;; Apply to all shipments for this order
        (reduce-kv
          (fn [s k v]
            (if (= (first k) (:order-id event))
              (assoc s k (apply-shipment-event v event))
              s))
          states
          states)

        :else states))
    {}
    events))

(defn build-payment-states
  "Builds all PaymentState projections from a sequence of events."
  [events]
  (reduce
    (fn [states event]
      (let [oid (e/event-order-id event)]
        (if (and (some? oid)
                 (or (instance? e/OrderPlaced event)
                     (instance? e/PaymentReceived event)
                     (instance? e/PaymentFailed event)
                     (instance? e/RefundIssued event)))
          (let [current (get states oid)
                updated (apply-payment-event current event)]
            (if (some? updated)
              (assoc states oid updated)
              states))
          states)))
    {}
    events))

;; ============================================================
;; Build all projections at once
;; ============================================================

(defn build-all-projections
  "Builds all projections from a sequence of events, returns a Projections record."
  [events]
  (let [orders (build-order-states events)
        customers (build-customer-states events)
        inventory (build-inventory-states events)
        shipments (build-shipment-states events)
        payments (build-payment-states events)]
    (e/make-projections
      (fn [oid] (get orders oid))
      (fn [cid] (get customers cid))
      (fn [item-id wh-id] (get inventory [item-id wh-id]))
      (fn [oid item-id] (get shipments [oid item-id]))
      (fn [oid] (get payments oid))
      (fn [] (vals orders))
      (fn [] (vals customers))
      (fn [] (vals inventory))
      (fn [] (vals shipments))
      (fn [] (vals payments)))))
