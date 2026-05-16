#lang beagle

(ns pipeline.handlers)

(require pipeline.events :as evt)
(require pipeline.projections :as proj)
(require pipeline.commands :as cmd)

;; =============================================================================
;; E5 Event Pipeline — Handlers
;; =============================================================================
;;
;; Event handlers that orchestrate business logic. Each handler receives an
;; event and a projections map (with keyword keys :lookup-order,
;; :lookup-customer, :lookup-inventory, :lookup-payment), and returns a vector
;; of secondary events to be appended to the event store.

;; =============================================================================
;; Helper: Notification event construction
;; =============================================================================

(defn make-notification [(recipient : String) (channel : String)
                         (template : String) (timestamp : Long)] : Any
  (->NotificationSent recipient channel template timestamp))

;; =============================================================================
;; Payment Failure Tracking
;; =============================================================================

(defn count-payment-failures [(events : Any) (order-id : Long)] : Long
  (count (filterv (fn [e]
                    (match e
                      [(PaymentFailed oid reason ts) (= oid order-id)]
                      [_ false]))
                  events)))

;; =============================================================================
;; Handle: OrderPlaced
;; =============================================================================

;; When an order is placed:
;; 1. Reserve inventory for each item (one event per item)
;; 2. Send order confirmation notification
;;
;; projections is a map with keys :lookup-inventory, :lookup-customer,
;; :lookup-order, :lookup-payment.
(defn handle-order-placed [(event : Any) (projections : Any)] : Any
  (let [oid (orderplaced-order-id event)
        cid (orderplaced-customer-id event)
        items (orderplaced-items event)
        timestamp (orderplaced-placed-at event)
        ;; Build inventory reservation events for each item
        reservations (mapv (fn [item]
                             (->InventoryReserved oid
                                                  (orderitem-item-id item)
                                                  (orderitem-quantity item)
                                                  1))
                           items)
        ;; Look up customer for notification
        get-cust (:lookup-customer projections)
        customer (get-cust cid)
        customer-email (if (nil? customer)
                           (str "customer-" cid "@example.com")
                           (customerstate-email customer))
        ;; Build confirmation notification
        notification (make-notification customer-email "email"
                                        "order-confirmation" timestamp)]
    (conj reservations notification)))

;; =============================================================================
;; Handle: PaymentReceived
;; =============================================================================

(defn handle-payment-received [(event : Any) (projections : Any)] : Any
  (let [oid (paymentreceived-order-id event)
        amount (paymentreceived-amount event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)
        result []]
    (if (nil? order)
        result
        (let [current-paid (if (nil? (orderstate-paid-amount order))
                               0
                               (orderstate-paid-amount order))
              new-paid (+ current-paid amount)
              fully-paid (>= new-paid (orderstate-total order))
              cid (orderstate-customer-id order)
              customer (get-cust cid)
              confirm-events (if (and fully-paid
                                      (nil? (orderstate-confirmed-at order)))
                                 [(->OrderConfirmed oid (paymentreceived-paid-at event))]
                                 [])
              tier-events (if (nil? customer)
                              []
                              (let [new-spent (+ (customerstate-total-spent customer) amount)
                                    new-tier (evt/compute-tier new-spent)
                                    old-tier (customerstate-tier customer)]
                                (if (not= old-tier new-tier)
                                    [(->CustomerTierChanged cid old-tier new-tier
                                                            (paymentreceived-paid-at event))]
                                    [])))]
          (concat confirm-events tier-events)))))

;; =============================================================================
;; Handle: PaymentFailed
;; =============================================================================

(defn handle-payment-failed [(event : Any) (projections : Any)
                             (all-events : Any)] : Any
  (let [oid (paymentfailed-order-id event)
        reason (paymentfailed-reason event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)]
    (if (nil? order)
        []
        (let [cid (orderstate-customer-id order)
              customer (get-cust cid)
              customer-email (if (nil? customer)
                                 (str "customer-" cid "@example.com")
                                 (customerstate-email customer))
              notify (make-notification customer-email "email"
                                        "payment-failed"
                                        (paymentfailed-failed-at event))
              failure-count (+ (count-payment-failures all-events oid) 1)
              cancel-events (if (cmd/should-auto-cancel? failure-count)
                                (let [cancel-event (->OrderCancelled oid
                                                     "Auto-cancelled: max payment failures"
                                                     (paymentfailed-failed-at event))
                                      releases (mapv (fn [item]
                                                       (->InventoryReleased
                                                         oid
                                                         (orderitem-item-id item)
                                                         (orderitem-quantity item)
                                                         "payment-failure-cancellation"))
                                                     (orderstate-items order))]
                                  (into [cancel-event] releases))
                                [])]
          (into [notify] cancel-events)))))

;; =============================================================================
;; Handle: ItemShipped
;; =============================================================================

(defn handle-item-shipped [(event : Any) (projections : Any)] : Any
  (let [oid (itemshipped-order-id event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)]
    (if (nil? order)
        []
        (let [cid (orderstate-customer-id order)
              customer (get-cust cid)
              customer-email (if (nil? customer)
                                 (str "customer-" cid "@example.com")
                                 (customerstate-email customer))
              notify (make-notification customer-email "sms"
                                        "item-shipped"
                                        (itemshipped-shipped-at event))
              new-shipped (+ (orderstate-shipped-count order) 1)
              item-count (count (orderstate-items order))
              fully-shipped (>= new-shipped item-count)
              full-ship-notif (if fully-shipped
                                  [(make-notification customer-email "email"
                                                      "all-items-shipped"
                                                      (itemshipped-shipped-at event))]
                                  [])]
          (into [notify] full-ship-notif)))))

;; =============================================================================
;; Handle: OrderDelivered
;; =============================================================================

(defn handle-order-delivered [(event : Any) (projections : Any)] : Any
  (let [oid (orderdelivered-order-id event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)]
    (if (nil? order)
        []
        (let [cid (orderstate-customer-id order)
              customer (get-cust cid)
              customer-email (if (nil? customer)
                                 (str "customer-" cid "@example.com")
                                 (customerstate-email customer))
              notify (make-notification customer-email "push"
                                        "order-delivered"
                                        (orderdelivered-delivered-at event))]
          [notify]))))

;; =============================================================================
;; Handle: OrderCancelled
;; =============================================================================

;; When an order is cancelled:
;; 1. Release all reserved inventory
;; 2. Issue refund if payment was received
;; 3. Send cancellation notification
(defn handle-order-cancelled [(event : Any) (projections : Any)] : Any
  (let [oid (ordercancelled-order-id event)
        reason (ordercancelled-reason event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)
        get-payment (:lookup-payment projections)]
    (if (nil? order)
        []
        (let [cid (orderstate-customer-id order)
              customer (get-cust cid)
              customer-email (if (nil? customer)
                                 (str "customer-" cid "@example.com")
                                 (customerstate-email customer))
              ;; Release inventory for all items
              releases (mapv (fn [item]
                               (->InventoryReleased
                                 oid
                                 (orderitem-item-id item)
                                 (orderitem-quantity item)
                                 (str "order-cancelled: " reason)))
                             (orderstate-items order))
              ;; Issue refund if paid
              payment (get-payment oid)
              refund-events (if (nil? payment)
                                []
                                (if (> (paymentstate-amount-paid payment) 0)
                                    [(->RefundIssued oid
                                       (paymentstate-amount-paid payment)
                                       (str "Refund for cancelled order: " reason)
                                       (ordercancelled-cancelled-at event))]
                                    []))
              ;; Send cancellation notification
              notify (make-notification customer-email "email"
                                        "order-cancelled"
                                        (ordercancelled-cancelled-at event))]
          (into (into releases refund-events) [notify])))))

;; =============================================================================
;; Handle: CustomerRegistered
;; =============================================================================

(defn handle-customer-registered [(event : Any) (projections : Any)] : Any
  (let [email (customerregistered-email event)]
    [(make-notification email "email" "welcome"
                        (customerregistered-registered-at event))]))

;; =============================================================================
;; Handle: RefundIssued
;; =============================================================================

(defn handle-refund-issued [(event : Any) (projections : Any)] : Any
  (let [oid (refundissued-order-id event)
        get-order (:lookup-order projections)
        order (get-order oid)
        get-cust (:lookup-customer projections)]
    (if (nil? order)
        []
        (let [cid (orderstate-customer-id order)
              customer (get-cust cid)
              customer-email (if (nil? customer)
                                 (str "customer-" cid "@example.com")
                                 (customerstate-email customer))
              notify (make-notification customer-email "email"
                                        "refund-issued"
                                        (refundissued-refunded-at event))]
          [notify]))))

;; =============================================================================
;; Handle: InventoryReserved
;; =============================================================================

(defn handle-inventory-reserved [(event : Any) (projections : Any)] : Any
  (let [iid (inventoryreserved-item-id event)
        wid (inventoryreserved-warehouse-id event)
        qty (inventoryreserved-quantity event)
        get-inv (:lookup-inventory projections)
        inv-state (get-inv iid wid)]
    (if (nil? inv-state)
        []
        (let [remaining (- (inventorystate-available inv-state) qty)]
          (if (< remaining 10)
              [(make-notification "ops@example.com" "email"
                                  "low-stock-alert" 0)]
              [])))))

;; =============================================================================
;; Master Event Dispatcher
;; =============================================================================

(defn dispatch-event [(event : Any) (projections : Any)
                      (all-events : Any)] : Any
  (match event
    [(OrderPlaced oid cid items total ts)
     (handle-order-placed event projections)]
    [(PaymentReceived oid amt meth tid ts)
     (handle-payment-received event projections)]
    [(PaymentFailed oid reason ts)
     (handle-payment-failed event projections all-events)]
    [(ItemShipped oid iid tn carrier ts)
     (handle-item-shipped event projections)]
    [(OrderDelivered oid ts)
     (handle-order-delivered event projections)]
    [(OrderCancelled oid reason ts)
     (handle-order-cancelled event projections)]
    [(CustomerRegistered cid name email ts)
     (handle-customer-registered event projections)]
    [(RefundIssued oid amt reason ts)
     (handle-refund-issued event projections)]
    [(InventoryReserved oid iid qty wid)
     (handle-inventory-reserved event projections)]
    [_ []]))

;; =============================================================================
;; Batch Handler Helpers
;; =============================================================================

(defn process-secondary-events [(events : Any) (projections : Any)
                                (all-events : Any)
                                (depth : Long)] : Any
  (if (or (empty? events) (>= depth 5))
      []
      (let [secondaries (mapv (fn [e]
                                (dispatch-event e projections all-events))
                              events)
            flat (reduce (fn [acc evts] (into acc evts)) [] secondaries)]
        (if (empty? flat)
            []
            (into flat (process-secondary-events flat projections
                                                 (into all-events flat)
                                                 (+ depth 1)))))))

(defn handle-all [(event : Any) (projections : Any)
                  (all-events : Any)] : Any
  (let [primary (dispatch-event event projections all-events)]
    (if (empty? primary)
        []
        (let [secondaries (process-secondary-events primary projections
                                                    (into all-events primary)
                                                    0)]
          (into primary secondaries)))))

;; =============================================================================
;; Handler Analytics
;; =============================================================================

(defn count-notifications [(events : Any)] : Long
  (count (filterv (fn [e]
                    (match e
                      [(NotificationSent r ch tmpl ts) true]
                      [_ false]))
                  events)))

(defn count-inventory-events [(events : Any)] : Long
  (count (filterv (fn [e]
                    (match e
                      [(InventoryReserved oid iid qty wid) true]
                      [(InventoryReleased oid iid qty reason) true]
                      [_ false]))
                  events)))

(defn extract-order-ids [(events : Any)] : Any
  (distinct (filterv (fn [id] (not (nil? id)))
                     (mapv (fn [e]
                             (match e
                               [(OrderPlaced oid cid items total ts) oid]
                               [(OrderConfirmed oid ts) oid]
                               [(PaymentReceived oid amt meth tid ts) oid]
                               [(ItemShipped oid iid tn carrier ts) oid]
                               [(OrderDelivered oid ts) oid]
                               [(OrderCancelled oid reason ts) oid]
                               [_ nil]))
                           events))))
