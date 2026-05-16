#lang beagle

(ns pipeline.projections)

(require pipeline.events :as evt)

;; =============================================================================
;; E5 Event Pipeline — Projections
;; =============================================================================
;;
;; Event application functions: apply events to projection state.
;; Each projection function takes current state (possibly nil for first event)
;; and an event, returns updated state.
;;
;; Pattern matching dispatches on event type. Guard patterns narrow nullable
;; fields before access.

;; =============================================================================
;; Order Projection
;; =============================================================================

;; apply-order-placed: creates initial order state from OrderPlaced event.
(defn apply-order-placed [(event : Any)] : OrderState
  (evt/empty-order-state
    (orderplaced-order-id event)
    (orderplaced-customer-id event)
    (orderplaced-items event)
    (orderplaced-total event)
    (orderplaced-placed-at event)))

;; apply-order-confirmed: marks order as confirmed with timestamp.
(defn apply-order-confirmed [(state : OrderState) (event : Any)] : OrderState
  (->OrderState (orderstate-order-id state)
                (orderstate-customer-id state)
                "confirmed"
                (orderstate-items state)
                (orderstate-total state)
                (orderstate-placed-at state)
                (orderconfirmed-confirmed-at event)
                (orderstate-paid-at state)
                (orderstate-paid-amount state)
                (orderstate-payment-method state)
                (orderstate-shipped-count state)
                (orderstate-delivered-at state)
                (orderstate-cancelled-at state)
                (orderstate-cancel-reason state)))

;; apply-payment-to-order: records payment on order state.
(defn apply-payment-to-order [(state : OrderState) (event : Any)] : OrderState
  (let [new-paid (+ (if (nil? (orderstate-paid-amount state))
                        0
                        (orderstate-paid-amount state))
                    (paymentreceived-amount event))
        new-status (if (>= new-paid (orderstate-total state))
                       "paid"
                       (orderstate-status state))]
    (->OrderState (orderstate-order-id state)
                  (orderstate-customer-id state)
                  new-status
                  (orderstate-items state)
                  (orderstate-total state)
                  (orderstate-placed-at state)
                  (orderstate-confirmed-at state)
                  (paymentreceived-paid-at event)
                  new-paid
                  (paymentreceived-method event)
                  (orderstate-shipped-count state)
                  (orderstate-delivered-at state)
                  (orderstate-cancelled-at state)
                  (orderstate-cancel-reason state))))

;; apply-item-shipped-to-order: increments shipped count, updates status.
(defn apply-item-shipped-to-order [(state : OrderState)
                                   (event : Any)] : OrderState
  (let [new-count (+ (orderstate-shipped-count state) 1)
        item-count (count (orderstate-items state))
        new-status (if (>= new-count item-count) "shipping" (orderstate-status state))]
    (->OrderState (orderstate-order-id state)
                  (orderstate-customer-id state)
                  new-status
                  (orderstate-items state)
                  (orderstate-total state)
                  (orderstate-placed-at state)
                  (orderstate-confirmed-at state)
                  (orderstate-paid-at state)
                  (orderstate-paid-amount state)
                  (orderstate-payment-method state)
                  new-count
                  (orderstate-delivered-at state)
                  (orderstate-cancelled-at state)
                  (orderstate-cancel-reason state))))

;; apply-order-delivered-to-order: marks order as delivered.
(defn apply-order-delivered-to-order [(state : OrderState)
                                     (event : Any)] : OrderState
  (->OrderState (orderstate-order-id state)
                (orderstate-customer-id state)
                "delivered"
                (orderstate-items state)
                (orderstate-total state)
                (orderstate-placed-at state)
                (orderstate-confirmed-at state)
                (orderstate-paid-at state)
                (orderstate-paid-amount state)
                (orderstate-payment-method state)
                (orderstate-shipped-count state)
                (orderdelivered-delivered-at event)
                (orderstate-cancelled-at state)
                (orderstate-cancel-reason state)))

;; apply-order-cancelled-to-order: marks order as cancelled with reason.
(defn apply-order-cancelled-to-order [(state : OrderState)
                                      (event : Any)] : OrderState
  (->OrderState (orderstate-order-id state)
                (orderstate-customer-id state)
                "cancelled"
                (orderstate-items state)
                (orderstate-total state)
                (orderstate-placed-at state)
                (orderstate-confirmed-at state)
                (orderstate-paid-at state)
                (orderstate-paid-amount state)
                (orderstate-payment-method state)
                (orderstate-shipped-count state)
                (orderstate-delivered-at state)
                (ordercancelled-cancelled-at event)
                (ordercancelled-reason event)))

;; apply-order-event: main dispatcher for order state projection.
;; Handles nil initial state (first event must be OrderPlaced).
(defn apply-order-event [(state : Any) (event : Any)] : Any
  (match event
    [(OrderPlaced oid cid items total ts)
     (apply-order-placed event)]
    [(OrderConfirmed oid ts)
     (if (nil? state) state (apply-order-confirmed state event))]
    [(PaymentReceived oid amt meth tid ts)
     (if (nil? state) state (apply-payment-to-order state event))]
    [(ItemShipped oid iid tn carr ts)
     (if (nil? state) state (apply-item-shipped-to-order state event))]
    [(OrderDelivered oid ts)
     (if (nil? state) state (apply-order-delivered-to-order state event))]
    [(OrderCancelled oid reason ts)
     (if (nil? state) state (apply-order-cancelled-to-order state event))]
    [_ state]))

;; =============================================================================
;; Customer Projection
;; =============================================================================

;; apply-customer-registered: creates initial customer state.
(defn apply-customer-registered [(event : Any)] : CustomerState
  (evt/empty-customer-state
    (customerregistered-customer-id event)
    (customerregistered-name event)
    (customerregistered-email event)
    (customerregistered-registered-at event)))

;; apply-tier-change: updates customer tier.
(defn apply-tier-change [(state : CustomerState) (event : Any)] : CustomerState
  (->CustomerState (customerstate-customer-id state)
                   (customerstate-name state)
                   (customerstate-email state)
                   (customertierchanged-new-tier event)
                   (customerstate-total-spent state)
                   (customerstate-order-count state)
                   (customerstate-registered-at state)))

;; apply-order-to-customer: increments order count.
(defn apply-order-to-customer [(state : CustomerState)
                               (event : Any)] : CustomerState
  (->CustomerState (customerstate-customer-id state)
                   (customerstate-name state)
                   (customerstate-email state)
                   (customerstate-tier state)
                   (customerstate-total-spent state)
                   (+ (customerstate-order-count state) 1)
                   (customerstate-registered-at state)))

;; apply-payment-to-customer: adds payment amount to total-spent.
(defn apply-payment-to-customer [(state : CustomerState)
                                 (amount : Long)] : CustomerState
  (->CustomerState (customerstate-customer-id state)
                   (customerstate-name state)
                   (customerstate-email state)
                   (customerstate-tier state)
                   (+ (customerstate-total-spent state) amount)
                   (customerstate-order-count state)
                   (customerstate-registered-at state)))

;; apply-customer-event: main dispatcher for customer state projection.
(defn apply-customer-event [(state : Any) (event : Any)] : Any
  (match event
    [(CustomerRegistered cid name email ts)
     (apply-customer-registered event)]
    [(CustomerTierChanged cid old-t new-t ts)
     (if (nil? state) state (apply-tier-change state event))]
    [(OrderPlaced oid cid items total ts)
     (if (nil? state) state (apply-order-to-customer state event))]
    [(PaymentReceived oid amt meth tid ts)
     (if (nil? state) state (apply-payment-to-customer state amt))]
    [_ state]))

;; =============================================================================
;; Inventory Projection
;; =============================================================================

;; apply-inventory-reserved: decreases available, increases reserved.
(defn apply-inventory-reserved [(state : InventoryState)
                                (event : Any)] : InventoryState
  (let [qty (inventoryreserved-quantity event)]
    (->InventoryState (inventorystate-item-id state)
                      (inventorystate-warehouse-id state)
                      (- (inventorystate-available state) qty)
                      (+ (inventorystate-reserved state) qty))))

;; apply-inventory-released: increases available, decreases reserved.
(defn apply-inventory-released [(state : InventoryState)
                                (event : Any)] : InventoryState
  (let [qty (inventoryreleased-quantity event)]
    (->InventoryState (inventorystate-item-id state)
                      (inventorystate-warehouse-id state)
                      (+ (inventorystate-available state) qty)
                      (- (inventorystate-reserved state) qty))))

;; apply-inventory-event: main dispatcher for inventory state projection.
;; Creates empty state if nil and event is InventoryReserved.
(defn apply-inventory-event [(state : Any) (event : Any)] : Any
  (match event
    [(InventoryReserved oid iid qty wid)
     (if (nil? state)
         (->InventoryState iid wid (- 0 qty) qty)
         (apply-inventory-reserved state event))]
    [(InventoryReleased oid iid qty reason)
     (if (nil? state)
         state
         (apply-inventory-released state event))]
    [_ state]))

;; =============================================================================
;; Shipment Projection
;; =============================================================================

;; apply-item-shipped-to-shipment: records shipping details.
(defn apply-item-shipped-to-shipment [(state : ShipmentState)
                                      (event : Any)] : ShipmentState
  (->ShipmentState (shipmentstate-order-id state)
                   (shipmentstate-item-id state)
                   (itemshipped-tracking-number event)
                   (itemshipped-carrier event)
                   (itemshipped-shipped-at event)
                   (shipmentstate-delivered-at state)))

;; apply-delivered-to-shipment: marks shipment as delivered.
(defn apply-delivered-to-shipment [(state : ShipmentState)
                                   (event : Any)] : ShipmentState
  (->ShipmentState (shipmentstate-order-id state)
                   (shipmentstate-item-id state)
                   (shipmentstate-tracking-number state)
                   (shipmentstate-carrier state)
                   (shipmentstate-shipped-at state)
                   (orderdelivered-delivered-at event)))

;; apply-shipment-event: main dispatcher for shipment state projection.
(defn apply-shipment-event [(state : Any) (event : Any)] : Any
  (match event
    [(ItemShipped oid iid tn carrier ts)
     (if (nil? state)
         (->ShipmentState oid iid tn carrier ts nil)
         (apply-item-shipped-to-shipment state event))]
    [(OrderDelivered oid ts)
     (if (nil? state)
         state
         (apply-delivered-to-shipment state event))]
    [_ state]))

;; =============================================================================
;; Payment Projection
;; =============================================================================

;; apply-payment-received-to-payment: records successful payment.
(defn apply-payment-received-to-payment [(state : PaymentState)
                                         (event : Any)] : PaymentState
  (let [new-paid (+ (paymentstate-amount-paid state)
                    (paymentreceived-amount event))
        new-status (if (>= new-paid (paymentstate-amount-due state))
                       "paid"
                       "partial")]
    (->PaymentState (paymentstate-order-id state)
                    (paymentstate-amount-due state)
                    new-paid
                    (paymentreceived-method event)
                    (paymentreceived-transaction-id event)
                    new-status)))

;; apply-payment-failed-to-payment: records failed payment attempt.
(defn apply-payment-failed-to-payment [(state : PaymentState)
                                       (event : Any)] : PaymentState
  (->PaymentState (paymentstate-order-id state)
                  (paymentstate-amount-due state)
                  (paymentstate-amount-paid state)
                  (paymentstate-method state)
                  (paymentstate-transaction-id state)
                  "failed"))

;; apply-refund-to-payment: deducts refund from paid amount.
(defn apply-refund-to-payment [(state : PaymentState)
                               (event : Any)] : PaymentState
  (let [new-paid (- (paymentstate-amount-paid state)
                    (refundissued-amount event))
        new-status (if (<= new-paid 0) "refunded" "partial-refund")]
    (->PaymentState (paymentstate-order-id state)
                    (paymentstate-amount-due state)
                    new-paid
                    (paymentstate-method state)
                    (paymentstate-transaction-id state)
                    new-status)))

;; apply-payment-event: main dispatcher for payment state projection.
(defn apply-payment-event [(state : Any) (event : Any)] : Any
  (match event
    [(PaymentReceived oid amt meth tid ts)
     (if (nil? state)
         (->PaymentState oid amt amt meth tid "paid")
         (apply-payment-received-to-payment state event))]
    [(PaymentFailed oid reason ts)
     (if (nil? state)
         state
         (apply-payment-failed-to-payment state event))]
    [(RefundIssued oid amt reason ts)
     (if (nil? state)
         state
         (apply-refund-to-payment state event))]
    [_ state]))

;; =============================================================================
;; Derived State Helpers
;; =============================================================================

;; order-status: derives the current status string from state fields.
(defn order-status [(state : OrderState)] : String
  (orderstate-status state))

;; is-fully-shipped?: true if shipped-count >= item count.
(defn is-fully-shipped? [(state : OrderState)] : Boolean
  (>= (orderstate-shipped-count state)
      (count (orderstate-items state))))

;; customer-eligible-for-upgrade?: true if total-spent crosses tier boundary.
(defn customer-eligible-for-upgrade? [(state : CustomerState)] : Boolean
  (let [spent (customerstate-total-spent state)
        tier (customerstate-tier state)]
    (cond
      [(= tier "bronze") (> spent 1000)]
      [(= tier "silver") (> spent 5000)]
      [true false])))

;; inventory-available?: true if available stock meets requested quantity.
(defn inventory-available? [(state : InventoryState)
                            (qty : Long)] : Boolean
  (>= (inventorystate-available state) qty))

;; payment-complete?: true if payment status is "paid".
(defn payment-complete? [(state : PaymentState)] : Boolean
  (= (paymentstate-status state) "paid"))

;; =============================================================================
;; Batch Projection Helpers
;; =============================================================================

;; fold-order-events: apply a sequence of events to build order state.
(defn fold-order-events [(events : Any)] : Any
  (reduce (fn [state event] (apply-order-event state event))
          nil events))

;; fold-customer-events: apply a sequence of events to build customer state.
(defn fold-customer-events [(events : Any)] : Any
  (reduce (fn [state event] (apply-customer-event state event))
          nil events))

;; fold-inventory-events: apply a sequence of events to build inventory state.
(defn fold-inventory-events [(events : Any)] : Any
  (reduce (fn [state event] (apply-inventory-event state event))
          nil events))

;; fold-shipment-events: apply a sequence of events to build shipment state.
(defn fold-shipment-events [(events : Any)] : Any
  (reduce (fn [state event] (apply-shipment-event state event))
          nil events))

;; fold-payment-events: apply a sequence of events to build payment state.
(defn fold-payment-events [(events : Any)] : Any
  (reduce (fn [state event] (apply-payment-event state event))
          nil events))

;; =============================================================================
;; State Validation
;; =============================================================================

;; order-state-valid?: basic invariant check on order state.
(defn order-state-valid? [(state : OrderState)] : Boolean
  (and (> (orderstate-order-id state) 0)
       (> (orderstate-customer-id state) 0)
       (> (orderstate-total state) 0)
       (> (count (orderstate-items state)) 0)))

;; customer-state-valid?: basic invariant check on customer state.
(defn customer-state-valid? [(state : CustomerState)] : Boolean
  (and (> (customerstate-customer-id state) 0)
       (>= (customerstate-total-spent state) 0)
       (>= (customerstate-order-count state) 0)))

;; inventory-state-valid?: reserved cannot exceed original stock.
(defn inventory-state-valid? [(state : InventoryState)] : Boolean
  (and (>= (inventorystate-available state) 0)
       (>= (inventorystate-reserved state) 0)))

;; payment-state-valid?: paid cannot exceed due (except refunds).
(defn payment-state-valid? [(state : PaymentState)] : Boolean
  (and (> (paymentstate-amount-due state) 0)
       (>= (paymentstate-amount-paid state) 0)))
