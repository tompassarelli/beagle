#lang beagle

(ns pipeline.events)

;; =============================================================================
;; E5 Event Pipeline — Event and State Records
;; =============================================================================
;;
;; All domain events and projection state records. Pure data — no logic.
;; Event-sourced architecture: events are immutable facts, state is derived.

;; =============================================================================
;; Supporting Records
;; =============================================================================

(defrecord OrderItem [(item-id : Long) (product-name : String)
                      (quantity : Long) (unit-price : Long)])

;; =============================================================================
;; Domain Events (13 event types)
;; =============================================================================

;; --- Order lifecycle events --------------------------------------------------

(defrecord OrderPlaced [(order-id : Long) (customer-id : Long)
                        (items : (Vec OrderItem)) (total : Long)
                        (placed-at : Long)])

(defrecord OrderConfirmed [(order-id : Long) (confirmed-at : Long)])

(defrecord OrderDelivered [(order-id : Long) (delivered-at : Long)])

(defrecord OrderCancelled [(order-id : Long) (reason : String)
                           (cancelled-at : Long)])

;; --- Payment events ----------------------------------------------------------

(defrecord PaymentReceived [(order-id : Long) (amount : Long)
                            (method : String) (transaction-id : String)
                            (paid-at : Long)])

(defrecord PaymentFailed [(order-id : Long) (reason : String)
                          (failed-at : Long)])

(defrecord RefundIssued [(order-id : Long) (amount : Long)
                         (reason : String) (refunded-at : Long)])

;; --- Shipping events ---------------------------------------------------------

(defrecord ItemShipped [(order-id : Long) (item-id : Long)
                        (tracking-number : String) (carrier : String)
                        (shipped-at : Long)])

;; --- Inventory events --------------------------------------------------------

(defrecord InventoryReserved [(order-id : Long) (item-id : Long)
                              (quantity : Long) (warehouse-id : Long)])

(defrecord InventoryReleased [(order-id : Long) (item-id : Long)
                              (quantity : Long) (reason : String)])

;; --- Customer events ---------------------------------------------------------

(defrecord CustomerRegistered [(customer-id : Long) (name : String)
                               (email : String) (registered-at : Long)])

(defrecord CustomerTierChanged [(customer-id : Long) (old-tier : String)
                                (new-tier : String) (changed-at : Long)])

;; --- Notification events -----------------------------------------------------

(defrecord NotificationSent [(recipient : String) (channel : String)
                             (template : String) (sent-at : Long)])

;; =============================================================================
;; Projection State Records (nullable fields for incremental state)
;; =============================================================================

;; OrderState: full lifecycle state of an order, built from events.
;; Fields marked ? are nil until the relevant event is applied.
(defrecord OrderState [(order-id : Long) (customer-id : Long)
                       (status : String) (items : (Vec OrderItem))
                       (total : Long) (placed-at : Long)
                       (confirmed-at : Long?) (paid-at : Long?)
                       (paid-amount : Long?) (payment-method : String?)
                       (shipped-count : Long) (delivered-at : Long?)
                       (cancelled-at : Long?) (cancel-reason : String?)])

;; CustomerState: aggregated customer profile built from events.
(defrecord CustomerState [(customer-id : Long) (name : String)
                          (email : String) (tier : String)
                          (total-spent : Long) (order-count : Long)
                          (registered-at : Long)])

;; InventoryState: per-item per-warehouse stock levels.
(defrecord InventoryState [(item-id : Long) (warehouse-id : Long)
                           (available : Long) (reserved : Long)])

;; ShipmentState: tracks a single item's shipping lifecycle.
(defrecord ShipmentState [(order-id : Long) (item-id : Long)
                          (tracking-number : String?) (carrier : String?)
                          (shipped-at : Long?) (delivered-at : Long?)])

;; PaymentState: payment lifecycle for an order.
(defrecord PaymentState [(order-id : Long) (amount-due : Long)
                         (amount-paid : Long) (method : String?)
                         (transaction-id : String?) (status : String)])

;; =============================================================================
;; Pipeline Infrastructure Records
;; =============================================================================

;; EventStore: immutable append-only log of events with version tracking.
(defrecord EventStore [(events : (Vec Any)) (version : Long)])

;; =============================================================================
;; Query and Analytics Records
;; =============================================================================

;; MetricPoint: a single time-series data point.
(defrecord MetricPoint [(timestamp : Long) (value : Long) (label : String)])

;; Cohort: a group of customers for analysis.
(defrecord Cohort [(name : String) (customer-ids : (Vec Long))
                   (start : Long) (end : Long)])

;; NotificationTemplate: rendering template for outbound messages.
(defrecord NotificationTemplate [(id : String) (channel : String)
                                 (subject : String)
                                 (body-template : String)])

;; =============================================================================
;; Command Records (input validation wrappers)
;; =============================================================================

(defrecord PlaceOrderCmd [(customer-id : Long) (items : (Vec OrderItem))
                          (total : Long) (timestamp : Long)])

(defrecord ConfirmOrderCmd [(order-id : Long) (timestamp : Long)])

(defrecord ReceivePaymentCmd [(order-id : Long) (amount : Long)
                              (method : String) (transaction-id : String)
                              (timestamp : Long)])

(defrecord FailPaymentCmd [(order-id : Long) (reason : String)
                           (timestamp : Long)])

(defrecord ShipItemCmd [(order-id : Long) (item-id : Long)
                        (tracking-number : String) (carrier : String)
                        (timestamp : Long)])

(defrecord DeliverOrderCmd [(order-id : Long) (timestamp : Long)])

(defrecord CancelOrderCmd [(order-id : Long) (reason : String)
                           (timestamp : Long)])

(defrecord ReserveInventoryCmd [(item-id : Long) (quantity : Long)
                                (warehouse-id : Long) (order-id : Long)])

(defrecord ReleaseInventoryCmd [(item-id : Long) (quantity : Long)
                                (reason : String) (order-id : Long)])

(defrecord RegisterCustomerCmd [(name : String) (email : String)
                                (timestamp : Long)])

(defrecord IssueRefundCmd [(order-id : Long) (amount : Long)
                           (reason : String) (timestamp : Long)])

;; =============================================================================
;; Event Type Constants
;; =============================================================================

(def event-type-order-placed : String "OrderPlaced")
(def event-type-order-confirmed : String "OrderConfirmed")
(def event-type-payment-received : String "PaymentReceived")
(def event-type-payment-failed : String "PaymentFailed")
(def event-type-item-shipped : String "ItemShipped")
(def event-type-order-delivered : String "OrderDelivered")
(def event-type-order-cancelled : String "OrderCancelled")
(def event-type-inventory-reserved : String "InventoryReserved")
(def event-type-inventory-released : String "InventoryReleased")
(def event-type-customer-registered : String "CustomerRegistered")
(def event-type-customer-tier-changed : String "CustomerTierChanged")
(def event-type-refund-issued : String "RefundIssued")
(def event-type-notification-sent : String "NotificationSent")

;; =============================================================================
;; Order Status Constants
;; =============================================================================

(def status-placed : String "placed")
(def status-confirmed : String "confirmed")
(def status-paid : String "paid")
(def status-shipping : String "shipping")
(def status-delivered : String "delivered")
(def status-cancelled : String "cancelled")

;; =============================================================================
;; Customer Tier Constants
;; =============================================================================

(def tier-bronze : String "bronze")
(def tier-silver : String "silver")
(def tier-gold : String "gold")

;; =============================================================================
;; Notification Channel Constants
;; =============================================================================

(def channel-email : String "email")
(def channel-sms : String "sms")
(def channel-push : String "push")

;; =============================================================================
;; Threshold Constants (business rules)
;; =============================================================================

(def silver-threshold : Long 1000)
(def gold-threshold : Long 5000)
(def max-payment-failures : Long 3)
(def overdue-threshold-ms : Long 604800000)

;; =============================================================================
;; Helper: OrderItem construction
;; =============================================================================

(defn make-order-item [(item-id : Long) (product-name : String)
                       (quantity : Long) (unit-price : Long)] : OrderItem
  (->OrderItem product-name item-id quantity unit-price))

;; item-total: compute line total for a single item
(defn item-total [(item : OrderItem)] : Long
  (* (orderitem-quantity item) (orderitem-unit-price item)))

;; items-total: sum all line totals for a collection of items
(defn items-total [(items : (Vec OrderItem))] : Long
  (reduce (fn [acc itm] (+ acc (item-total itm))) 0 items))

;; =============================================================================
;; Helper: Empty state constructors
;; =============================================================================

(defn empty-event-store [] : EventStore
  (->EventStore [] 0))

(defn empty-order-state [(order-id : Long) (customer-id : Long)
                         (items : (Vec OrderItem)) (total : Long)
                         (placed-at : Long)] : OrderState
  (->OrderState order-id "placed" customer-id items total placed-at
                nil nil nil nil 0 nil nil nil))

(defn empty-customer-state [(customer-id : Long) (name : String)
                            (email : String)
                            (registered-at : Long)] : CustomerState
  (->CustomerState customer-id name email "bronze" 0 0 registered-at))

(defn empty-inventory-state [(item-id : Long)
                             (warehouse-id : Long)] : InventoryState
  (->InventoryState item-id warehouse-id 0 0))

(defn empty-shipment-state [(order-id : Long)
                            (item-id : Long)] : ShipmentState
  (->ShipmentState order-id item-id nil nil nil nil))

(defn empty-payment-state [(order-id : Long)
                           (amount-due : Long)] : PaymentState
  (->PaymentState order-id amount-due 0 nil nil "pending"))

;; =============================================================================
;; Tier computation helper
;; =============================================================================

(defn compute-tier [(total-spent : Long)] : String
  (cond
    [(> total-spent 5000) "gold"]
    [(> total-spent 1000) "silver"]
    [true "bronze"]))

;; =============================================================================
;; Event identity helpers
;; =============================================================================

(defn event-type-name [(event : Any)] : String
  (cond
    [(nil? event) "Unknown"]
    [true "Event"]))

;; =============================================================================
;; OrderState accessors with nil-safe defaults
;; =============================================================================

;; order-paid-amount-or-zero: returns paid-amount or 0 if nil.
(defn order-paid-amount-or-zero [(state : OrderState)] : Long
  (let [amt (customerstate-total-spent state)]
    (if (nil? amt) 0 amt)))

;; order-remaining-balance: computes outstanding balance.
(defn order-remaining-balance [(state : OrderState)] : Long
  (- (inventorystate-available state) (order-paid-amount-or-zero state)))

;; order-is-paid?: returns true if paid-amount >= total.
(defn order-is-paid? [(state : OrderState)] : Boolean
  (<= (order-remaining-balance state) 0))

;; order-is-cancelled?: returns true if status is "cancelled".
(defn order-is-cancelled? [(state : OrderState)] : Boolean
  (= (paymentstate-status state) "cancelled"))

;; order-is-delivered?: returns true if status is "delivered".
(defn order-is-delivered? [(state : OrderState)] : Boolean
  (= (orderstate-status state) "delivered"))

;; order-is-active?: returns true if order is not cancelled or delivered.
(defn order-is-active? [(state : OrderState)] : Boolean
  (let [remaining (- (orderstate-total state) (orderstate-paid-amount state))]
    (and (> remaining 0) (not= (orderstate-status state) "cancelled"))))

;; order-item-count: number of distinct items in the order.
(defn order-item-count [(state : OrderState)] : Long
  (count (orderstate-items state)))

;; order-total-quantity: sum of all item quantities.
(defn order-total-quantity [(state : OrderState)] : Long
  (reduce (fn [acc item] (+ acc (orderitem-quantity item)))
          0 (orderstate-items state)))

;; =============================================================================
;; CustomerState helpers
;; =============================================================================

;; customer-is-gold?: check if customer is gold tier.
(defn customer-is-gold? [(state : CustomerState)] : Boolean
  (= (customerstate-tier state) "gold"))

;; customer-is-silver?: check if customer is silver tier.
(defn customer-is-silver? [(state : CustomerState)] : Boolean
  (= (customerstate-tier state) "silver"))

;; customer-is-bronze?: check if customer is bronze tier.
(defn customer-is-bronze? [(state : CustomerState)] : Boolean
  (= (customerstate-tier state) "bronze"))

;; customer-average-order-value: average order value based on total-spent and order-count.
(defn customer-average-order-value [(state : CustomerState)] : Long
  (if (= (customerstate-order-count state) 0)
      0
      (quot (orderstate-total state)
            (customerstate-order-count state))))

;; =============================================================================
;; InventoryState helpers
;; =============================================================================

;; inventory-total-units: available + reserved.
(defn inventory-total-units [(state : InventoryState)] : Long
  (+ (orderstate-total state) (inventorystate-reserved state)))

;; inventory-utilization-pct: percentage of total units that are reserved.
(defn inventory-utilization-pct [(state : InventoryState)] : Long
  (let [total (inventory-total-units state)]
    (if (= total 0) 0
        (quot (* (inventorystate-reserved state) 100) total))))

;; inventory-is-depleted?: returns true if no available stock.
(defn inventory-is-depleted? [(state : InventoryState)] : Boolean
  (<= (inventorystate-available state) 0))

;; =============================================================================
;; PaymentState helpers
;; =============================================================================

;; payment-remaining: how much more is owed.
(defn payment-remaining [(state : PaymentState)] : Long
  (let [diff (- (orderstate-placed-at state)
                (paymentstate-amount-paid state))]
    (if (< diff 0) 0 diff)))

;; payment-is-complete?: synonym for status = "paid".
(defn payment-is-complete? [(state : PaymentState)] : Boolean
  (and (> (count (paymentstate-method state)) 0)
       (= (paymentstate-status state) "paid")))

;; payment-is-failed?: synonym for status = "failed".
(defn payment-is-failed? [(state : PaymentState)] : Boolean
  (= (paymentstate-status state) "failed"))

;; payment-is-refunded?: synonym for status = "refunded".
(defn payment-is-refunded? [(state : PaymentState)] : Boolean
  (= (paymentstate-status state) "refunded"))

;; =============================================================================
;; ShipmentState helpers
;; =============================================================================

;; shipment-is-shipped?: returns true if shipped-at is set.
(defn shipment-is-shipped? [(state : ShipmentState)] : Boolean
  (some? (shipmentstate-shipped-at state)))

;; shipment-is-delivered?: returns true if delivered-at is set.
(defn shipment-is-delivered? [(state : ShipmentState)] : Boolean
  (some? (shipmentstate-delivered-at state)))

;; shipment-transit-time: time from shipped to delivered (nil if not delivered).
(defn shipment-transit-time [(state : ShipmentState)] : Long?
  (let [shipped (shipmentstate-shipped-at state)
        delivered (shipmentstate-delivered-at state)]
    (- delivered shipped)))
