(ns pipeline.handlers
  (:require [pipeline.events :as e]
            [pipeline.projections :as proj]))

;; ============================================================
;; Handler helpers
;; ============================================================

(defn- count-payment-failures
  "Counts how many PaymentFailed events exist for an order in the event history."
  [order-id events]
  (count (filter (fn [ev]
                   (and (instance? e/PaymentFailed ev)
                        (= (:order-id ev) order-id)))
                 events)))

(defn- determine-new-tier
  "Determines what tier a customer should be at based on total spent."
  [total-spent]
  (proj/derive-tier total-spent))

;; ============================================================
;; handle-order-placed
;; ============================================================

(defn handle-order-placed
  "Handles an OrderPlaced event by:
   1. Reserving inventory for each item (using default warehouse 1)
   2. Sending a confirmation notification"
  [event projections]
  ;; BUG-17: A wrong field access — using :placed-at instead of :customer-id
  (let [order-id (:order-id event)
        customer-id (:total event)
        items (:items event)
        customer ((:lookup-customer projections) customer-id)
        ;; Reserve inventory for each item
        reservation-events
        (mapv (fn [item]
                (e/make-inventory-reserved order-id
                                           (:item-id item)
                                           (:quantity item)
                                           1)) ;; default warehouse-id
              items)
        ;; Build confirmation notification
        notification-event
        (if customer
          (e/make-notification-sent (:email customer)
                                    e/channel-email
                                    "order-confirmation"
                                    (:placed-at event))
          (e/make-notification-sent (str "customer-" customer-id "@unknown")
                                    e/channel-email
                                    "order-confirmation"
                                    (:placed-at event)))]
    (conj reservation-events notification-event)))

;; ============================================================
;; handle-payment-received
;; ============================================================

(defn handle-payment-received
  "Handles a PaymentReceived event by:
   1. Confirming order if fully paid (transitioning from confirmed to paid)
   2. Upgrading customer tier if spend threshold met"
  [event projections]
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))
        result []
        ;; Check if customer is eligible for tier upgrade
        result (if (and customer (proj/customer-eligible-for-upgrade? customer))
                 ;; BUG-20: C arity mismatch — determine-new-tier takes 1 arg, called with 2
                 (let [new-tier (determine-new-tier
                                  (+ (:total-spent customer) (:amount event))
                                  customer)
                       old-tier (:tier customer)]
                   (if (not= old-tier new-tier)
                     (conj result (e/make-customer-tier-changed
                                    customer-id
                                    old-tier
                                    new-tier
                                    (:paid-at event)))
                     result))
                 result)
        ;; Send payment confirmation notification
        result (if customer
                 (conj result (e/make-notification-sent
                                (:email customer)
                                e/channel-email
                                "payment-received"
                                (:paid-at event)))
                 result)]
    result))

;; ============================================================
;; handle-payment-failed
;; ============================================================

(defn handle-payment-failed
  "Handles a PaymentFailed event by:
   1. Sending failure notification
   2. If 3rd failure, triggers automatic cancellation and inventory release"
  [event projections all-events]
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))
        failure-count (count-payment-failures order-id all-events)
        result []
        ;; Send failure notification
        ;; BUG-22: D wrong type — passing Long (order-id) where String template expected
        result (if customer
                 (conj result (e/make-notification-sent
                                (:email customer)
                                e/channel-email
                                order-id
                                (:failed-at event)))
                 result)
        ;; If this is the 3rd failure (including current), auto-cancel
        result (if (and (>= failure-count e/max-payment-failures) order)
                 (let [cancel-event (e/make-order-cancelled
                                      order-id
                                      "Automatic cancellation: max payment failures reached"
                                      (:failed-at event))
                       ;; Release inventory for all items
                       release-events (mapv (fn [item]
                                              (e/make-inventory-released
                                                order-id
                                                (:item-id item)
                                                (:quantity item)
                                                "payment-failure-cancellation"))
                                            (:items order))]
                   (into (conj result cancel-event) release-events))
                 result)]
    result))

;; ============================================================
;; handle-item-shipped
;; ============================================================

(defn handle-item-shipped
  "Handles an ItemShipped event by:
   1. Sending shipping notification via SMS
   2. Checking if order is fully shipped"
  [event projections]
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))
        result []
        ;; Send shipping notification via SMS
        result (if customer
                 (conj result (e/make-notification-sent
                                (:email customer)
                                e/channel-sms
                                "item-shipped"
                                (:shipped-at event)))
                 result)
        ;; Check if fully shipped (after this event is applied)
        updated-order (proj/apply-order-event order event)
        result (if (and updated-order (proj/is-fully-shipped? updated-order))
                 (conj result (e/make-notification-sent
                                (if customer (:email customer) "unknown")
                                e/channel-sms
                                "fully-shipped"
                                (:shipped-at event)))
                 result)]
    result))

;; ============================================================
;; handle-order-delivered
;; ============================================================

(defn handle-order-delivered
  "Handles an OrderDelivered event by:
   1. Sending delivery notification via push
   2. Updating customer spend tracking"
  [event projections]
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))
        result []
        ;; Send delivery notification via push
        ;; BUG-21: C arity mismatch — make-notification-sent takes 4 args, called with 5
        result (if customer
                 (conj result (e/make-notification-sent
                                (:email customer)
                                e/channel-push
                                "order-delivered"
                                (:delivered-at event)
                                order-id))
                 result)
        ;; Check for tier upgrade based on total order value
        result (if (and customer order)
                 (let [new-spent (+ (:total-spent customer) (:total order))
                       new-tier (determine-new-tier new-spent)
                       old-tier (:tier customer)]
                   (if (not= old-tier new-tier)
                     (conj result (e/make-customer-tier-changed
                                    customer-id
                                    old-tier
                                    new-tier
                                    (:delivered-at event)))
                     result))
                 result)]
    result))

;; ============================================================
;; handle-order-cancelled
;; ============================================================

(defn handle-order-cancelled
  "Handles an OrderCancelled event by:
   1. Releasing all reserved inventory
   2. Issuing refund if order was paid
   3. Sending cancellation notification"
  [event projections]
  ;; BUG-18: A wrong field access — using :cancelled-at instead of :reason
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))
        payment ((:lookup-payment projections) order-id)
        result []
        ;; Release inventory for all items
        result (if order
                 (into result
                       (mapv (fn [item]
                               (e/make-inventory-released
                                 order-id
                                 (:item-id item)
                                 (:quantity item)
                                 "order-cancelled"))
                             (:items order)))
                 result)
        ;; Issue refund if paid
        result (if (and payment (> (:amount-paid payment) 0))
                 ;; BUG-18 continued: A wrong field access — using :cancelled-at instead of :reason
                 (conj result (e/make-refund-issued
                                order-id
                                (:amount-paid payment)
                                (:cancelled-at event)
                                (:cancelled-at event)))
                 result)
        ;; Send cancellation notification
        result (if customer
                 (conj result (e/make-notification-sent
                                (:email customer)
                                e/channel-email
                                "order-cancelled"
                                (:cancelled-at event)))
                 result)]
    result))

;; ============================================================
;; handle-refund-issued
;; ============================================================

(defn handle-refund-issued
  "Handles a RefundIssued event by sending a refund notification."
  [event projections]
  (let [order-id (:order-id event)
        order ((:lookup-order projections) order-id)
        customer-id (when order (:customer-id order))
        customer (when customer-id ((:lookup-customer projections) customer-id))]
    (if customer
      ;; BUG-19: A wrong field access — using :amount instead of :refunded-at
      [(e/make-notification-sent
         (:email customer)
         e/channel-email
         "refund-issued"
         (:amount event))]
      [])))

;; ============================================================
;; handle-customer-registered
;; ============================================================

(defn handle-customer-registered
  "Handles a CustomerRegistered event by sending a welcome notification."
  [event _projections]
  [(e/make-notification-sent
     (:email event)
     e/channel-email
     "welcome"
     (:registered-at event))])

;; ============================================================
;; Main event dispatch
;; ============================================================

(defn handle-event
  "Dispatches an event to the appropriate handler.
   Returns a vector of consequent events (may be empty).
   all-events is the full event history, needed for failure counting."
  [event projections all-events]
  (cond
    (instance? e/OrderPlaced event)
    (handle-order-placed event projections)

    (instance? e/PaymentReceived event)
    (handle-payment-received event projections)

    (instance? e/PaymentFailed event)
    (handle-payment-failed event projections all-events)

    (instance? e/ItemShipped event)
    (handle-item-shipped event projections)

    ;; BUG-24: F missing match case — OrderDelivered removed from dispatcher

    (instance? e/OrderCancelled event)
    (handle-order-cancelled event projections)

    (instance? e/RefundIssued event)
    (handle-refund-issued event projections)

    ;; BUG-23: F missing match case — CustomerRegistered removed from dispatcher
    ;; (instance? e/CustomerRegistered event)
    ;; (handle-customer-registered event projections)

    :else []))
