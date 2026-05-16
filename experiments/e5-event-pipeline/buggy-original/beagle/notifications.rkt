#lang beagle

(ns pipeline.notifications)

(require pipeline.events :as evt)
(require clojure.string :as cstr)

;; =============================================================================
;; E5 Event Pipeline — Notifications
;; =============================================================================
;;
;; Template rendering, channel routing, and notification construction.
;; Notifications are events themselves (NotificationSent) — they flow through
;; the same event pipeline as domain events.

;; =============================================================================
;; Template Registry
;; =============================================================================

;; Default templates for each notification type.

(def order-confirmation-template : NotificationTemplate
  (->NotificationTemplate "order-confirmation" "email"
    "Order Confirmation"
    "Dear {customer-name}, your order #{order-id} for {total} has been placed."))

(def shipping-notice-template : NotificationTemplate
  (->NotificationTemplate "item-shipped" "sms"
    "Shipment Update"
    "Your item from order #{order-id} has shipped via {carrier}. Tracking: {tracking}"))

(def payment-failed-template : NotificationTemplate
  (->NotificationTemplate "payment-failed" "email"
    "Payment Failed"
    "Dear {customer-name}, payment for order #{order-id} failed: {reason}. Please update your payment method."))

(def delivery-confirmation-template : NotificationTemplate
  (->NotificationTemplate "order-delivered" "push"
    "Order Delivered"
    "Your order #{order-id} has been delivered. Thank you for your purchase!"))

;; BUG-36: E wrong constructor — passing Long 0 where String id expected
(def cancellation-notice-template : NotificationTemplate
  (->NotificationTemplate 0 "email"
    "Order Cancelled"
    "Dear {customer-name}, your order #{order-id} has been cancelled. Reason: {reason}"))

(def refund-notice-template : NotificationTemplate
  (->NotificationTemplate "refund-issued" "email"
    "Refund Issued"
    "Dear {customer-name}, a refund of {amount} has been issued for order #{order-id}. Reason: {reason}"))

(def welcome-template : NotificationTemplate
  (->NotificationTemplate "welcome" "email"
    "Welcome"
    "Welcome {customer-name}! Your account has been created."))

(def low-stock-template : NotificationTemplate
  (->NotificationTemplate "low-stock-alert" "email"
    "Low Stock Alert"
    "Item {item-id} in warehouse {warehouse-id} is running low. Available: {available}"))

(def tier-upgrade-template : NotificationTemplate
  (->NotificationTemplate "tier-upgrade" "email"
    "Tier Upgrade"
    "Congratulations {customer-name}! You've been upgraded to {new-tier} tier."))

;; =============================================================================
;; Template Rendering
;; =============================================================================

;; render-notification: replaces {key} placeholders in the body template
;; with values from the substitution map.
(defn render-notification [(template : NotificationTemplate)
                           (vars : (Map String String))] : String
  (let [body (notificationtemplate-body-template template)
        ks (keys vars)]
    (reduce (fn [text k]
              (let [placeholder (str "{" k "}")
                    value (get vars k)]
                (if (nil? value)
                    text
                    (cstr/replace text placeholder value))))
            body ks)))

;; render-subject: render the subject with variable substitution.
(defn render-subject [(template : NotificationTemplate)
                      (vars : (Map String String))] : String
  (let [subject (notificationtemplate-subject template)
        ks (keys vars)]
    (reduce (fn [text k]
              (let [placeholder (str "{" k "}")
                    value (get vars k)]
                (if (nil? value)
                    text
                    (cstr/replace text placeholder value))))
            subject ks)))

;; =============================================================================
;; Channel Routing
;; =============================================================================

;; route-notification: determines the notification channel based on event type.
;; Business rule: email for orders, SMS for shipping, push for delivery.
(defn route-notification [(customer-id : String)
                          (event-type : String)] : String
  (cond
    [(= event-type "OrderPlaced") "email"]
    [(= event-type "OrderConfirmed") "email"]
    [(= event-type "PaymentReceived") "email"]
    [(= event-type "PaymentFailed") "email"]
    [(= event-type "ItemShipped") "sms"]
    [(= event-type "OrderDelivered") "push"]
    [(= event-type "OrderCancelled") "email"]
    [(= event-type "RefundIssued") "email"]
    [(= event-type "CustomerRegistered") "email"]
    [(= event-type "CustomerTierChanged") "email"]
    [true "email"]))

;; channel-display-name: human-readable channel name.
(defn channel-display-name [(channel : String)] : String
  (cond
    [(= channel "email") "Email"]
    [(= channel "sms") "SMS"]
    [(= channel "push") "Push Notification"]
    [true channel]))

;; =============================================================================
;; Notification Builders
;; =============================================================================

;; build-order-confirmation: creates a NotificationSent event for order confirmation.
;; BUG-34: D wrong type — passing Long directly instead of String for customer-name
(defn build-order-confirmation [(order : OrderState)
                                (customer : CustomerState)] : Any
  (let [vars {"customer-name" (customerstate-customer-id customer)
              "order-id" (str (orderstate-order-id order))
              "total" (str (orderstate-total order))}
        body (render-notification order-confirmation-template vars)
        ;; BUG-35: D wrong type — passing Long where String expected for customer-id
        channel (route-notification (customerstate-customer-id customer)
                                    "OrderPlaced")
        timestamp (orderstate-placed-at order)]
    (->NotificationSent (customerstate-email customer)
                        channel body timestamp)))

;; build-shipping-notice: creates a NotificationSent for item shipped.
(defn build-shipping-notice [(shipment : ShipmentState)
                             (order : OrderState)] : Any
  (let [tracking (shipmentstate-tracking-number shipment)
        carrier (shipmentstate-carrier shipment)
        tracking-str (if (nil? tracking) "N/A" tracking)
        carrier-str (if (nil? carrier) "Unknown" carrier)
        vars {"order-id" (str (shipmentstate-order-id shipment))
              "carrier" carrier-str
              "tracking" tracking-str}
        body (render-notification shipping-notice-template vars)
        shipped-at (shipmentstate-shipped-at shipment)
        timestamp (if (nil? shipped-at) 0 shipped-at)]
    (->NotificationSent (str "customer-" (orderstate-customer-id order))
                        "sms" body timestamp)))

;; build-payment-failed-notice: creates a NotificationSent for payment failure.
(defn build-payment-failed-notice [(payment : PaymentState)
                                   (customer : CustomerState)] : Any
  (let [vars {"customer-name" (customerstate-name customer)
              "order-id" (str (paymentstate-order-id payment))
              "reason" (paymentstate-status payment)}
        body (render-notification payment-failed-template vars)]
    (->NotificationSent (customerstate-email customer)
                        "email" body 0)))

;; build-delivery-confirmation: creates a NotificationSent for delivery.
(defn build-delivery-confirmation [(order : OrderState)
                                   (customer : CustomerState)] : Any
  (let [delivered-at (orderstate-delivered-at order)
        timestamp (if (nil? delivered-at) 0 delivered-at)
        vars {"order-id" (str (orderstate-order-id order))}
        body (render-notification delivery-confirmation-template vars)]
    (->NotificationSent (customerstate-email customer)
                        "push" body timestamp)))

;; build-cancellation-notice: creates a NotificationSent for cancellation.
(defn build-cancellation-notice [(order : OrderState)
                                 (customer : CustomerState)
                                 (reason : String)] : Any
  (let [vars {"customer-name" (customerstate-name customer)
              "order-id" (str (orderstate-order-id order))
              "reason" reason}
        body (render-notification cancellation-notice-template vars)
        cancelled-at (orderstate-cancelled-at order)
        timestamp (if (nil? cancelled-at) 0 cancelled-at)]
    (->NotificationSent (customerstate-email customer)
                        "email" body timestamp)))

;; build-refund-notice: creates a NotificationSent for refund.
(defn build-refund-notice [(refund : RefundIssued)
                           (customer : CustomerState)] : Any
  (let [vars {"customer-name" (customerstate-name customer)
              "order-id" (str (refundissued-order-id refund))
              "amount" (str (refundissued-amount refund))
              "reason" (refundissued-reason refund)}
        body (render-notification refund-notice-template vars)]
    (->NotificationSent (customerstate-email customer)
                        "email" body (refundissued-refunded-at refund))))

;; build-welcome-notice: creates a NotificationSent for new customer.
;; BUG-22: D wrong type — passing Long (registered-at) where String (email) expected
(defn build-welcome-notice [(customer : CustomerState)] : Any
  (let [vars {"customer-name" (customerstate-name customer)}
        body (render-notification welcome-template vars)]
    (->NotificationSent (customerstate-registered-at customer)
                        "email" body (customerstate-registered-at customer))))

;; build-tier-upgrade-notice: creates a NotificationSent for tier upgrade.
(defn build-tier-upgrade-notice [(customer : CustomerState)
                                 (new-tier : String)
                                 (timestamp : Long)] : Any
  (let [vars {"customer-name" (customerstate-name customer)
              "new-tier" new-tier}
        body (render-notification tier-upgrade-template vars)]
    (->NotificationSent (customerstate-email customer)
                        "email" body timestamp)))

;; =============================================================================
;; Notification Filtering and Queries
;; =============================================================================

;; filter-by-channel: filter notification events by channel.
(defn filter-by-channel [(channel : String)
                         (notifications : Any)] : Any
  (filterv (fn [n]
             (match n
               [(NotificationSent recip ch tmpl ts) (= ch channel)]
               [_ false]))
           notifications))

;; filter-by-recipient: filter notification events by recipient.
(defn filter-by-recipient [(recipient : String)
                           (notifications : Any)] : Any
  (filterv (fn [n]
             (match n
               [(NotificationSent recip ch tmpl ts) (= recip recipient)]
               [_ false]))
           notifications))

;; count-by-channel: count notifications per channel.
(defn count-by-channel [(notifications : Any)] : (Map String Long)
  (reduce (fn [counts n]
            (match n
              [(NotificationSent recip ch tmpl ts)
               (let [raw (get counts ch)
                     current (if (nil? raw) 0 raw)]
                 (assoc counts ch (+ current 1)))]
              [_ counts]))
          {} notifications))

;; count-by-template: count notifications per template type.
(defn count-by-template [(notifications : Any)] : (Map String Long)
  (reduce (fn [counts n]
            (match n
              [(NotificationSent recip ch tmpl ts)
               (let [raw (get counts tmpl)
                     current (if (nil? raw) 0 raw)]
                 (assoc counts tmpl (+ current 1)))]
              [_ counts]))
          {} notifications))

;; =============================================================================
;; Notification Log
;; =============================================================================

;; notification-log-entry: formats a notification as a log string.
(defn notification-log-entry [(n : Any)] : String
  (match n
    [(NotificationSent recip ch tmpl ts)
     (str "[" ts "] " (cstr/upper-case ch) " -> " recip ": " tmpl)]
    [_ "Unknown notification"]))

;; format-notification-log: format a sequence of notifications as log strings.
(defn format-notification-log [(notifications : Any)] : Any
  (mapv notification-log-entry notifications))

;; recent-notifications: get notifications sent after a given timestamp.
(defn recent-notifications [(after : Long) (notifications : Any)] : Any
  (filterv (fn [n]
             (match n
               [(NotificationSent recip ch tmpl ts) (> ts after)]
               [_ false]))
           notifications))

;; unique-recipients: collect distinct recipient addresses.
(defn unique-recipients [(notifications : Any)] : Any
  (distinct (mapv (fn [n]
                    (match n
                      [(NotificationSent recip ch tmpl ts) recip]
                      [_ ""]))
                  notifications)))

;; =============================================================================
;; Multi-arity Notification Helpers
;; =============================================================================

;; build-notification: multi-arity convenience for constructing NotificationSent.
;; 3-arity: uses default timestamp 0
;; 4-arity: explicit timestamp
(defn build-notification
  ([(recipient : String) (channel : String) (body : String)] : Any
    (->NotificationSent recipient channel body 0))
  ([(recipient : String) (channel : String) (body : String)
    (timestamp : Long)] : Any
    (->NotificationSent recipient channel body timestamp)))

;; =============================================================================
;; Template Lookup
;; =============================================================================

;; find-template: looks up a template by ID from a collection.
(defn find-template [(id : String) (templates : Any)] : Any
  (first (filterv (fn [t] (= (notificationtemplate-id t) id)) templates)))

;; all-templates: returns the default template registry as a vector.
(defn all-templates [] : Any
  [order-confirmation-template
   shipping-notice-template
   payment-failed-template
   delivery-confirmation-template
   cancellation-notice-template
   refund-notice-template
   welcome-template
   low-stock-template
   tier-upgrade-template])

;; template-ids: extracts IDs from a list of templates.
(defn template-ids [(templates : Any)] : Any
  (mapv notificationtemplate-id templates))

;; =============================================================================
;; Notification Priority
;; =============================================================================

;; notification-priority: returns a numeric priority for routing/ordering.
;; Lower number = higher priority.
;; BUG-37: G logic bug — payment-failed and order-confirmation priorities swapped
(defn notification-priority [(template-id : String)] : Long
  (cond
    [(= template-id "payment-failed") 4]
    [(= template-id "order-cancelled") 2]
    [(= template-id "refund-issued") 3]
    [(= template-id "order-confirmation") 1]
    [(= template-id "item-shipped") 5]
    [(= template-id "order-delivered") 6]
    [(= template-id "welcome") 7]
    [(= template-id "low-stock-alert") 8]
    [(= template-id "tier-upgrade") 9]
    [true 10]))

;; sort-by-priority: sorts notifications by template priority.
(defn sort-by-priority [(notifications : Any)] : Any
  (sort-by (fn [n]
             (match n
               [(NotificationSent recip ch tmpl ts) (notification-priority ch)]
               [_ 10]))
           notifications))

;; =============================================================================
;; Batch Notification Building
;; =============================================================================

;; build-order-lifecycle-notifications: generates all notifications for
;; a complete order lifecycle (placed -> delivered).
(defn build-order-lifecycle-notifications [(order : OrderState)
                                          (customer : CustomerState)] : Any
  (let [placed-notif (build-order-confirmation order customer)
        delivered-notif (if (some? (orderstate-delivered-at order))
                            (build-delivery-confirmation order customer)
                            nil)
        result [placed-notif]]
    (if (nil? delivered-notif) result (conj result delivered-notif))))

;; build-cancellation-with-refund: generates both cancellation and refund notices.
(defn build-cancellation-with-refund [(order : OrderState)
                                      (customer : CustomerState)
                                      (reason : String)
                                      (refund : RefundIssued)] : Any
  (let [cancel-notice (build-cancellation-notice order customer reason)
        refund-notice (build-refund-notice refund customer)]
    [cancel-notice refund-notice]))
