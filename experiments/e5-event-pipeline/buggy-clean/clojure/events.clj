(ns pipeline.events)

;; ============================================================
;; Supporting Records
;; ============================================================

(defrecord OrderItem [item-id product-name quantity unit-price])

(defn make-order-item
  "Constructs an OrderItem."
  [item-id product-name quantity unit-price]
  (->OrderItem product-name item-id quantity unit-price))

;; ============================================================
;; Event Records (13 events)
;; ============================================================

(defrecord OrderPlaced [order-id customer-id items total placed-at])

(defn make-order-placed
  "Constructs an OrderPlaced event."
  [order-id customer-id items total placed-at]
  (->OrderPlaced order-id customer-id items total placed-at))

(defrecord OrderConfirmed [order-id confirmed-at])

(defn make-order-confirmed
  "Constructs an OrderConfirmed event."
  [order-id confirmed-at]
  (->OrderConfirmed order-id confirmed-at))

(defrecord PaymentReceived [order-id amount method transaction-id paid-at])

(defn make-payment-received
  "Constructs a PaymentReceived event."
  [order-id amount method transaction-id paid-at]
  (->PaymentReceived order-id amount method transaction-id paid-at))

(defrecord PaymentFailed [order-id reason failed-at])

(defn make-payment-failed
  "Constructs a PaymentFailed event."
  [order-id reason failed-at]
  (->PaymentFailed order-id reason failed-at))

(defrecord ItemShipped [order-id item-id tracking-number carrier shipped-at])

(defn make-item-shipped
  "Constructs an ItemShipped event."
  [order-id item-id tracking-number carrier shipped-at]
  (->ItemShipped order-id item-id tracking-number carrier shipped-at))

(defrecord OrderDelivered [order-id delivered-at])

(defn make-order-delivered
  "Constructs an OrderDelivered event."
  [order-id delivered-at]
  (->OrderDelivered order-id delivered-at))

(defrecord OrderCancelled [order-id reason cancelled-at])

(defn make-order-cancelled
  "Constructs an OrderCancelled event."
  [order-id reason cancelled-at]
  (->OrderCancelled order-id reason cancelled-at))

(defrecord InventoryReserved [order-id item-id quantity warehouse-id])

(defn make-inventory-reserved
  "Constructs an InventoryReserved event."
  [order-id item-id quantity warehouse-id]
  (->InventoryReserved order-id item-id quantity warehouse-id))

(defrecord InventoryReleased [order-id item-id quantity reason])

(defn make-inventory-released
  "Constructs an InventoryReleased event."
  [order-id item-id quantity reason]
  (->InventoryReleased order-id item-id quantity reason))

(defrecord CustomerRegistered [customer-id name email registered-at])

(defn make-customer-registered
  "Constructs a CustomerRegistered event."
  [customer-id name email registered-at]
  (->CustomerRegistered customer-id name email registered-at))

(defrecord CustomerTierChanged [customer-id old-tier new-tier changed-at])

(defn make-customer-tier-changed
  "Constructs a CustomerTierChanged event."
  [customer-id old-tier new-tier changed-at]
  (->CustomerTierChanged customer-id old-tier new-tier changed-at))

(defrecord RefundIssued [order-id amount reason refunded-at])

(defn make-refund-issued
  "Constructs a RefundIssued event."
  [order-id amount reason refunded-at]
  (->RefundIssued order-id amount reason refunded-at))

(defrecord NotificationSent [recipient channel template sent-at])

(defn make-notification-sent
  "Constructs a NotificationSent event."
  [recipient channel template sent-at]
  (->NotificationSent recipient channel template sent-at))

;; ============================================================
;; Projection State Records
;; ============================================================

(defrecord OrderState
  [order-id customer-id status items total placed-at
   confirmed-at paid-at paid-amount payment-method
   shipped-count delivered-at cancelled-at cancel-reason])

(defn make-order-state
  "Constructs an initial OrderState with sensible defaults for nullable fields."
  [order-id customer-id status items total placed-at]
  (->OrderState order-id status customer-id items total placed-at
               nil nil nil nil 0 nil nil nil))

(defrecord CustomerState
  [customer-id name email tier total-spent order-count registered-at])

(defn make-customer-state
  "Constructs a CustomerState."
  [customer-id name email tier total-spent order-count registered-at]
  (->CustomerState customer-id name email tier total-spent order-count registered-at))

(defrecord InventoryState [item-id warehouse-id available reserved])

(defn make-inventory-state
  "Constructs an InventoryState."
  [item-id warehouse-id available reserved]
  (->InventoryState item-id warehouse-id available reserved))

(defrecord ShipmentState
  [order-id item-id tracking-number carrier shipped-at delivered-at])

(defn make-shipment-state
  "Constructs an initial ShipmentState."
  [order-id item-id]
  (->ShipmentState order-id item-id nil nil nil nil))

(defrecord PaymentState
  [order-id amount-due amount-paid method transaction-id status])

(defn make-payment-state
  "Constructs an initial PaymentState."
  [order-id amount-due]
  (->PaymentState order-id amount-due 0 nil nil "pending"))

;; ============================================================
;; Projections lookup container
;; ============================================================

(defrecord Projections
  [lookup-order lookup-customer lookup-inventory lookup-shipment lookup-payment
   all-orders all-customers all-inventory all-shipments all-payments])

(defn make-projections
  "Constructs a Projections record with lookup functions and collection accessors."
  [lookup-order lookup-customer lookup-inventory lookup-shipment lookup-payment
   all-orders all-customers all-inventory all-shipments all-payments]
  (->Projections lookup-order lookup-customer lookup-inventory lookup-shipment lookup-payment
                 all-orders all-customers all-inventory all-shipments all-payments))

;; ============================================================
;; Event type predicates
;; ============================================================

(defn order-placed? [e] (instance? OrderPlaced e))
(defn order-confirmed? [e] (instance? OrderConfirmed e))
(defn payment-received? [e] (instance? PaymentReceived e))
(defn payment-failed? [e] (instance? PaymentFailed e))
(defn item-shipped? [e] (instance? ItemShipped e))
(defn order-delivered? [e] (instance? OrderDelivered e))
(defn order-cancelled? [e] (instance? OrderCancelled e))
(defn inventory-reserved? [e] (instance? InventoryReserved e))
(defn inventory-released? [e] (instance? InventoryReleased e))
(defn customer-registered? [e] (instance? CustomerRegistered e))
(defn customer-tier-changed? [e] (instance? CustomerTierChanged e))
(defn refund-issued? [e] (instance? RefundIssued e))
(defn notification-sent? [e] (instance? NotificationSent e))

;; ============================================================
;; Event field access helpers (uniform interface)
;; ============================================================

(defn event-order-id
  "Returns the order-id from an event, or nil if not applicable."
  [e]
  (cond
    (instance? OrderPlaced e) (:order-id e)
    (instance? OrderConfirmed e) (:order-id e)
    (instance? PaymentReceived e) (:order-id e)
    (instance? PaymentFailed e) (:order-id e)
    (instance? ItemShipped e) (:order-id e)
    (instance? OrderDelivered e) (:order-id e)
    (instance? OrderCancelled e) (:order-id e)
    (instance? InventoryReserved e) (:order-id e)
    (instance? InventoryReleased e) (:order-id e)
    (instance? RefundIssued e) (:order-id e)
    :else nil))

(defn event-customer-id
  "Returns the customer-id from an event, or nil if not applicable."
  [e]
  (cond
    (instance? OrderPlaced e) (:customer-id e)
    (instance? CustomerRegistered e) (:customer-id e)
    (instance? CustomerTierChanged e) (:customer-id e)
    :else nil))

(defn event-timestamp
  "Returns the primary timestamp from an event."
  [e]
  (cond
    (instance? OrderPlaced e) (:placed-at e)
    (instance? OrderConfirmed e) (:confirmed-at e)
    (instance? PaymentReceived e) (:paid-at e)
    (instance? PaymentFailed e) (:failed-at e)
    (instance? ItemShipped e) (:shipped-at e)
    (instance? OrderDelivered e) (:delivered-at e)
    (instance? OrderCancelled e) (:cancelled-at e)
    (instance? CustomerRegistered e) (:registered-at e)
    (instance? CustomerTierChanged e) (:changed-at e)
    (instance? RefundIssued e) (:refunded-at e)
    (instance? NotificationSent e) (:sent-at e)
    :else nil))

;; ============================================================
;; Constants
;; ============================================================

(def status-placed "placed")
(def status-confirmed "confirmed")
(def status-paid "paid")
(def status-shipped "shipped")
(def status-delivered "delivered")
(def status-cancelled "cancelled")

(def tier-bronze "bronze")
(def tier-silver "silver")
(def tier-gold "gold")

(def channel-email "email")
(def channel-sms "sms")
(def channel-push "push")

;; Overdue threshold: 7 days in milliseconds
(def overdue-threshold-ms 604800000)

;; Tier thresholds
(def silver-threshold 1000)
(def gold-threshold 5000)

;; Max payment failures before auto-cancel
(def max-payment-failures 3)
