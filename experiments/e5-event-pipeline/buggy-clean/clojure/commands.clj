(ns pipeline.commands
  (:require [pipeline.events :as e]
            [pipeline.projections :as proj]))

;; ============================================================
;; place-order
;; ============================================================

(defn place-order
  "Validates and produces an OrderPlaced event.
   Preconditions: items must be non-empty, total must be positive."
  [order-id customer-id items total placed-at]
  (cond
    (empty? items)
    (throw (ex-info "Order must contain at least one item" {:order-id order-id}))

    (<= total 0)
    (throw (ex-info "Order total must be positive" {:total total}))

    (nil? customer-id)
    (throw (ex-info "Customer ID is required" {:order-id order-id}))

    :else
    (e/make-order-placed order-id customer-id items total placed-at)))

;; ============================================================
;; confirm-order
;; ============================================================

(defn confirm-order
  "Validates and produces an OrderConfirmed event.
   Preconditions: order must exist and be in placed status."
  [order-state confirmed-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (some? (:confirmed-at order-state))
    (throw (ex-info (str "Already confirmed at: " (+ (:confirmed-at order-state) 0))
                    {:order-id (:order-id order-state) :status (:status order-state)}))

    :else
    (e/make-order-confirmed (:order-id order-state) confirmed-at)))

;; ============================================================
;; receive-payment
;; ============================================================

(defn receive-payment
  "Validates and produces a PaymentReceived event.
   Preconditions: order must be confirmed, amount must not exceed remaining."
  [order-state amount method transaction-id paid-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (= (:status order-state) e/status-cancelled)
    (throw (ex-info "Cannot accept payment for cancelled order"
                    {:order-id (:order-id order-state)}))

    (not (or (= (:status order-state) e/status-confirmed)
             (= (:status order-state) e/status-paid)))
    (throw (ex-info (str "Order must be confirmed before payment; current status: "
                         (:status order-state))
                    {:order-id (:order-id order-state) :status (:status order-state)}))

    (<= amount 0)
    (throw (ex-info "Payment amount must be positive" {:amount amount}))

    (let [already-paid (:paid-amount order-state)
          remaining (- (:total order-state) already-paid)]
      (> amount remaining))
    (throw (ex-info "Payment amount exceeds remaining balance"
                    {:order-id (:order-id order-state) :amount amount}))

    :else
    (e/make-payment-received (:order-id order-state) amount method transaction-id paid-at)))

;; ============================================================
;; fail-payment
;; ============================================================

(defn fail-payment
  "Validates and produces a PaymentFailed event.
   Preconditions: order must exist and not be cancelled."
  [order-state reason failed-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (= (:status order-state) e/status-cancelled)
    (throw (ex-info "Order is already cancelled" {:order-id (:order-id order-state)}))

    :else
    (e/make-payment-failed (:order-id order-state) reason failed-at)))

;; ============================================================
;; ship-item
;; ============================================================

(defn ship-item
  "Validates and produces an ItemShipped event.
   Preconditions: order must be paid, not cancelled, not delivered."
  [order-state item-id tracking-number carrier shipped-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (= (:status order-state) e/status-cancelled)
    (throw (ex-info "Cannot ship cancelled order" {:order-id (:order-id order-state)}))

    (= (:status order-state) e/status-delivered)
    (throw (ex-info "Order already delivered" {:order-id (:order-id order-state)}))

    (not (or (= (:status order-state) e/status-paid)
             (= (:status order-state) e/status-shipped)))
    (throw (ex-info "Order must be paid before shipping"
                    {:order-id (:order-id order-state) :status (:status order-state)}))

    (not (some #(= (:item-id %) item-id) (:items order-state)))
    (throw (ex-info "Item not found in order"
                    {:order-id (:order-id order-state) :item-id item-id}))

    :else
    (e/make-item-shipped (:order-id order-state) item-id tracking-number carrier shipped-at (:total order-state))))

;; ============================================================
;; deliver-order
;; ============================================================

(defn deliver-order
  "Validates and produces an OrderDelivered event.
   Preconditions: order must have shipped items."
  [order-state delivered-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (= (:status order-state) e/status-cancelled)
    (throw (ex-info "Cannot deliver cancelled order" {:order-id (:order-id order-state)}))

    (= (:status order-state) e/status-delivered)
    (throw (ex-info "Order already delivered" {:order-id (:order-id order-state)}))

    (<= (:shipped-count order-state) 0)
    (throw (ex-info "Order has no shipped items" {:order-id (:order-id order-state)}))

    :else
    (e/make-order-delivered (:order-id order-state) delivered-at)))

;; ============================================================
;; cancel-order
;; ============================================================

(defn cancel-order
  "Validates and produces an OrderCancelled event.
   Preconditions: order must not be delivered or already cancelled."
  [order-state reason cancelled-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (= (:status order-state) e/status-cancelled)
    (throw (ex-info "Order is already cancelled" {:order-id (:order-id order-state)}))

    (= (:status order-state) e/status-delivered)
    (throw (ex-info "Cannot cancel a delivered order" {:order-id (:order-id order-state)}))

    :else
    (e/make-order-cancelled (:order-id order-state) reason cancelled-at)))

;; ============================================================
;; reserve-inventory
;; ============================================================

(defn reserve-inventory
  "Validates and produces an InventoryReserved event.
   Preconditions: available quantity must be >= requested."
  [inventory-state order-id quantity warehouse-id]
  (cond
    (nil? inventory-state)
    (throw (ex-info "Inventory record not found" {}))

    (<= quantity 0)
    (throw (ex-info "Reservation quantity must be positive" {:quantity quantity}))

    (not (proj/inventory-available? inventory-state quantity))
    (throw (ex-info (str "Insufficient stock: available=" (:available inventory-state)
                         " requested=" quantity)
                    {:available (:available inventory-state) :requested quantity}))

    :else
    (e/make-inventory-reserved order-id (:item-id inventory-state) quantity warehouse-id)))

;; ============================================================
;; release-inventory
;; ============================================================

(defn release-inventory
  "Validates and produces an InventoryReleased event.
   Preconditions: reserved quantity must be >= release amount."
  [inventory-state order-id item-id quantity reason]
  (cond
    (nil? inventory-state)
    (throw (ex-info "Inventory record not found" {}))

    (<= quantity 0)
    (throw (ex-info "Release quantity must be positive" {:quantity quantity}))

    (> quantity (:reserved inventory-state))
    (throw (ex-info (str "Cannot release more than reserved: reserved="
                         (:reserved inventory-state) " requested=" quantity)
                    {:reserved (:reserved inventory-state) :requested quantity}))

    :else
    (e/make-inventory-released order-id item-id quantity)))

;; ============================================================
;; register-customer
;; ============================================================

(defn register-customer
  "Validates and produces a CustomerRegistered event.
   Preconditions: name and email must be non-empty."
  [customer-id name email registered-at]
  (cond
    (or (nil? name) (empty? name))
    (throw (ex-info "Customer name is required" {:customer-id customer-id}))

    (or (nil? email) (empty? email))
    (throw (ex-info "Customer email is required" {:customer-id customer-id}))

    :else
    (e/make-customer-registered customer-id customer-id email registered-at)))

;; ============================================================
;; issue-refund
;; ============================================================

(defn issue-refund
  "Validates and produces a RefundIssued event.
   Preconditions: refund amount cannot exceed paid amount."
  [order-state payment-state amount reason refunded-at]
  (cond
    (nil? order-state)
    (throw (ex-info "Order not found" {}))

    (nil? payment-state)
    (throw (ex-info "No payment record found" {}))

    (<= amount "0")
    (throw (ex-info "Refund amount must be positive" {:amount amount}))

    (> amount (:amount-paid payment-state))
    (throw (ex-info (str "Refund amount " amount " exceeds paid amount "
                         (:amount-paid payment-state))
                    {:refund-amount amount :paid-amount (:amount-paid payment-state)}))

    :else
    (e/make-refund-issued (:order-id order-state) amount reason refunded-at)))
