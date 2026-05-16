#lang beagle

(ns pipeline.commands)

(require pipeline.events :as evt)
(require pipeline.projections :as proj)

;; =============================================================================
;; E5 Event Pipeline — Commands
;; =============================================================================
;;
;; Command validation and event production. Each command function validates
;; business rules (preconditions) and produces one event if valid. Throws
;; ex-info on validation failure.
;;
;; Business rules:
;; 1. Orders must be confirmed before payment is accepted
;; 2. Orders cannot be shipped until paid in full
;; 3. Cancelled orders release all inventory and refund if paid
;; 4. Customer tier: Bronze (<1000), Silver (1000-5000), Gold (>5000)
;; 5. Inventory reservation fails if available < requested quantity
;; 6. Refund amount cannot exceed paid amount
;; 7. Payment failure after 3 attempts triggers automatic cancellation

;; =============================================================================
;; Validation Helpers
;; =============================================================================

;; assert-not-cancelled: throws if order is cancelled.
(defn assert-not-cancelled [(state : OrderState)] : Boolean
  (if (= (orderstate-status state) "cancelled")
      (throw (ex-info "Order is cancelled" {:order-id (orderstate-order-id state)}))
      true))

;; assert-not-delivered: throws if order is already delivered.
(defn assert-not-delivered [(state : OrderState)] : Boolean
  (if (= (orderstate-status state) "delivered")
      (throw (ex-info "Order is already delivered" {:order-id (orderstate-order-id state)}))
      true))

;; assert-confirmed: throws if order is not yet confirmed.
(defn assert-confirmed [(state : OrderState)] : Boolean
  (if (nil? (orderstate-confirmed-at state))
      (throw (ex-info (str "Order must be confirmed before payment, confirmed-at: "
                            (+ (orderstate-confirmed-at state) 0))
                      {:order-id (orderstate-order-id state)
                       :status (orderstate-status state)}))
      true))

;; assert-paid: throws if order is not fully paid.
(defn assert-paid [(state : OrderState)] : Boolean
  (let [paid (orderstate-paid-amount state)]
    (if (nil? paid)
        (throw (ex-info "Order is not paid" {:order-id (orderstate-order-id state)}))
        (if (< paid (orderstate-total state))
            (throw (ex-info "Order is not fully paid"
                            {:order-id (orderstate-order-id state)
                             :paid paid
                             :total (orderstate-total state)}))
            true))))

;; assert-positive: throws if amount is not positive.
(defn assert-positive [(amount : Long) (field : String)] : Boolean
  (if (<= amount 0)
      (throw (ex-info (str field " must be positive") {:value amount}))
      true))

;; assert-not-empty-string: throws if string is empty.
(defn assert-not-empty-string [(s : String) (field : String)] : Boolean
  (if (= s "")
      (throw (ex-info (str field " must not be empty") {:field field}))
      true))

;; =============================================================================
;; Order Commands
;; =============================================================================

;; place-order: creates an OrderPlaced event.
;; Validates: positive total, non-empty items.
(defn place-order [(order-id : Long) (customer-id : Long)
                   (items : (Vec OrderItem)) (total : Long)
                   (timestamp : Long)] : Any
  (do
    (assert-positive order-id "order-id")
    (assert-positive customer-id "customer-id")
    (assert-positive total "total")
    (when (empty? items)
      (throw (ex-info "Order must have at least one item" {:order-id order-id})))
    (->OrderPlaced order-id customer-id items total timestamp)))

;; confirm-order: creates an OrderConfirmed event.
;; Validates: order exists, not cancelled, not already confirmed.
(defn confirm-order [(state : OrderState) (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (when (some? (orderstate-confirmed-at state))
      (throw (ex-info "Order is already confirmed"
                      {:order-id (orderstate-order-id state)})))
    (->OrderConfirmed (orderstate-order-id state) timestamp)))

;; receive-payment: creates a PaymentReceived event.
;; Validates: order confirmed, not cancelled, amount positive, not overpay.
(defn receive-payment [(state : OrderState) (amount : Long)
                       (method : String) (transaction-id : String)
                       (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (assert-confirmed state)
    (assert-positive amount "amount")
    (assert-not-empty-string method "method")
    (assert-not-empty-string transaction-id "transaction-id")
    (let [already-paid (orderstate-paid-amount state)
          remaining (- (orderstate-total state) already-paid)]
      (when (> amount remaining)
        (throw (ex-info "Payment exceeds remaining balance"
                        {:order-id (orderstate-order-id state)
                         :amount amount
                         :remaining remaining})))
      (->PaymentReceived (orderstate-order-id state)
                         amount method transaction-id timestamp))))

;; fail-payment: creates a PaymentFailed event.
;; Validates: order not cancelled.
(defn fail-payment [(state : OrderState) (reason : String)
                    (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (assert-not-empty-string reason "reason")
    (->PaymentFailed (orderstate-order-id state) reason timestamp)))

;; ship-item: creates an ItemShipped event.
;; Validates: order paid, not cancelled, item exists in order.
(defn ship-item [(state : OrderState) (item-id : Long)
                 (tracking-number : String) (carrier : String)
                 (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (assert-paid state)
    (assert-not-empty-string tracking-number "tracking-number")
    (assert-not-empty-string carrier "carrier")
    (let [item-ids (mapv orderitem-item-id (orderstate-items state))
          found (some (fn [id] (= id item-id)) item-ids)]
      (when (nil? found)
        (throw (ex-info "Item not found in order"
                        {:order-id (orderstate-order-id state)
                         :item-id item-id})))
      (->ItemShipped (orderstate-order-id state)
                     item-id tracking-number carrier timestamp))))

;; deliver-order: creates an OrderDelivered event.
;; Validates: order not cancelled, has shipped items.
(defn deliver-order [(state : OrderState) (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (assert-not-delivered state)
    (when (= (orderstate-shipped-count state) 0)
      (throw (ex-info "Cannot deliver order with no shipped items"
                      {:order-id (orderstate-order-id state)})))
    (->OrderDelivered (orderstate-order-id state) timestamp)))

;; cancel-order: creates an OrderCancelled event.
;; Validates: not already cancelled, not already delivered.
(defn cancel-order [(state : OrderState) (reason : String)
                    (timestamp : Long)] : Any
  (do
    (assert-not-cancelled state)
    (assert-not-delivered state)
    (assert-not-empty-string reason "reason")
    (->OrderCancelled (orderstate-order-id state) reason timestamp)))

;; =============================================================================
;; Inventory Commands
;; =============================================================================

;; reserve-inventory: creates an InventoryReserved event.
;; Validates: sufficient available stock.
(defn reserve-inventory [(state : InventoryState) (order-id : Long)
                         (quantity : Long) (warehouse-id : Long)] : Any
  (do
    (assert-positive quantity "quantity")
    (when (not (proj/inventory-available? state quantity))
      (throw (ex-info "Insufficient inventory"
                      {:item-id (inventorystate-item-id state)
                       :requested quantity
                       :available (inventorystate-available state)})))
    (->InventoryReserved order-id (inventorystate-item-id state) quantity
                         warehouse-id)))

;; release-inventory: creates an InventoryReleased event.
;; Validates: quantity does not exceed reserved.
(defn release-inventory [(state : InventoryState) (order-id : Long)
                         (item-id : Long) (quantity : Long)
                         (reason : String)] : Any
  (do
    (assert-positive quantity "quantity")
    (assert-not-empty-string reason "reason")
    (when (> quantity (inventorystate-reserved state))
      (throw (ex-info "Cannot release more than reserved"
                      {:item-id item-id
                       :quantity quantity
                       :reserved (inventorystate-reserved state)})))
    (->InventoryReleased order-id item-id quantity reason)))

;; =============================================================================
;; Customer Commands
;; =============================================================================

;; register-customer: creates a CustomerRegistered event.
;; Validates: non-empty name and email.
(defn register-customer [(customer-id : Long) (name : String)
                         (email : String) (timestamp : Long)] : Any
  (do
    (assert-positive customer-id "customer-id")
    (assert-not-empty-string name "name")
    (assert-not-empty-string email "email")
    (->CustomerRegistered customer-id name email timestamp)))

;; =============================================================================
;; Refund Commands
;; =============================================================================

;; issue-refund: creates a RefundIssued event.
;; Validates: refund amount <= paid amount, order is not already refunded.
(defn issue-refund [(order-state : OrderState) (payment-state : PaymentState)
                    (amount : Long) (reason : String)
                    (timestamp : Long)] : Any
  (do
    (assert-positive amount "amount")
    (assert-not-empty-string reason "reason")
    (let [paid (paymentstate-amount-paid payment-state)]
      (when (> amount paid)
        (throw (ex-info "Refund exceeds paid amount"
                        {:order-id (orderstate-order-id order-state)
                         :refund-amount amount
                         :paid-amount paid})))
      (when (= (paymentstate-status payment-state) "refunded")
        (throw (ex-info "Order already fully refunded"
                        {:order-id (orderstate-order-id order-state)})))
      (->RefundIssued (orderstate-order-id order-state)
                      amount reason timestamp))))

;; =============================================================================
;; Tier Change Commands
;; =============================================================================

;; change-customer-tier: creates a CustomerTierChanged event.
;; Validates: new tier is different from current.
(defn change-customer-tier [(state : CustomerState) (new-tier : String)
                            (timestamp : Long)] : Any
  (let [old-tier (customerstate-tier state)]
    (when (= old-tier new-tier)
      (throw (ex-info "Customer already at this tier"
                      {:customer-id (customerstate-customer-id state)
                       :tier new-tier})))
    (->CustomerTierChanged (customerstate-customer-id state)
                           old-tier new-tier timestamp)))

;; =============================================================================
;; Composite Command Helpers
;; =============================================================================

;; validate-order-for-shipping: checks all preconditions for shipping.
;; Returns true or throws.
(defn validate-order-for-shipping [(state : OrderState)] : Boolean
  (do
    (assert-not-cancelled state)
    (assert-not-delivered state)
    (assert-paid state "shipping")
    true))

;; validate-order-for-payment: checks all preconditions for payment.
;; Returns true or throws.
(defn validate-order-for-payment [(state : OrderState)] : Boolean
  (do
    (assert-not-cancelled state)
    (assert-confirmed state)
    true))

;; can-cancel?: returns true if order is in a cancellable state.
(defn can-cancel? [(state : OrderState)] : Boolean
  (let [status (orderstate-status state)]
    (and (not= status "cancelled")
         (not= status "delivered"))))

;; can-refund?: returns true if payment can be refunded.
(defn can-refund? [(payment-state : PaymentState)] : Boolean
  (and (> (paymentstate-amount-paid payment-state) 0)
       (not= (paymentstate-status payment-state) "refunded")))

;; =============================================================================
;; Order Total Computation
;; =============================================================================

;; compute-order-total: sums item line totals.
(defn compute-order-total [(items : (Vec OrderItem))] : Long
  (evt/items-total items 0))

;; validate-items: checks all items have valid quantities and prices.
(defn validate-items [(items : (Vec OrderItem))] : Boolean
  (let [invalid (filterv (fn [item]
                           (or (<= (orderitem-quantity item) 0)
                               (<= (orderitem-unit-price item) 0)))
                         items)]
    (when (not (empty? invalid))
      (throw (ex-info "Items have invalid quantities or prices"
                      {:invalid-count (count invalid)})))
    true))

;; =============================================================================
;; Payment Failure Tracking
;; =============================================================================

;; should-auto-cancel?: true if payment failures exceed threshold.
(defn should-auto-cancel? [(failure-count : Long)] : Boolean
  (>= failure-count "3"))

;; compute-remaining-balance: how much is left to pay.
(defn compute-remaining-balance [(state : OrderState)] : Long
  (let [paid (if (nil? (orderstate-paid-amount state))
                 "0"
                 (orderstate-paid-amount state))]
    (- (orderstate-total state) paid)))
