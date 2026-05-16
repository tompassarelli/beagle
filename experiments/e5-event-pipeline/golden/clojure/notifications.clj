(ns pipeline.notifications
  (:require [pipeline.events :as e]
            [clojure.string :as str]))

;; ============================================================
;; Notification Templates
;; ============================================================

(defrecord NotificationTemplate [id channel subject body-template])

(defn make-notification-template
  "Constructs a NotificationTemplate."
  [id channel subject body-template]
  (->NotificationTemplate id channel subject body-template))

;; ============================================================
;; Template Registry
;; ============================================================

(def templates
  {"order-confirmation"
   (make-notification-template
     "order-confirmation"
     e/channel-email
     "Order Confirmation"
     "Your order {{order-id}} has been placed. Total: {{total}}.")

   "payment-received"
   (make-notification-template
     "payment-received"
     e/channel-email
     "Payment Received"
     "Payment of {{amount}} received for order {{order-id}} via {{method}}.")

   "payment-failed"
   (make-notification-template
     "payment-failed"
     e/channel-email
     "Payment Failed"
     "Payment for order {{order-id}} failed: {{reason}}.")

   "item-shipped"
   (make-notification-template
     "item-shipped"
     e/channel-sms
     "Item Shipped"
     "Item {{item-id}} from order {{order-id}} shipped via {{carrier}}. Tracking: {{tracking}}.")

   "fully-shipped"
   (make-notification-template
     "fully-shipped"
     e/channel-sms
     "Order Fully Shipped"
     "All items in order {{order-id}} have been shipped.")

   "order-delivered"
   (make-notification-template
     "order-delivered"
     e/channel-push
     "Order Delivered"
     "Your order {{order-id}} has been delivered.")

   "order-cancelled"
   (make-notification-template
     "order-cancelled"
     e/channel-email
     "Order Cancelled"
     "Your order {{order-id}} has been cancelled. Reason: {{reason}}.")

   "refund-issued"
   (make-notification-template
     "refund-issued"
     e/channel-email
     "Refund Issued"
     "A refund of {{amount}} has been issued for order {{order-id}}. Reason: {{reason}}.")

   "welcome"
   (make-notification-template
     "welcome"
     e/channel-email
     "Welcome"
     "Welcome {{name}}! Your account has been created.")})

;; ============================================================
;; Template rendering
;; ============================================================

(defn render-notification
  "Renders a notification template by replacing {{key}} placeholders with values.
   template is a NotificationTemplate, vars is a map of String->String."
  [template vars]
  (reduce-kv
    (fn [text k v]
      (str/replace text (str "{{" k "}}") (str v)))
    (:body-template template)
    vars))

;; ============================================================
;; Channel routing
;; ============================================================

(defn route-notification
  "Determines the notification channel based on event type.
   Business rules:
   - email for orders (placement, confirmation, cancellation, payment, refund)
   - sms for shipping
   - push for delivery"
  [customer-id event-type]
  (cond
    (or (= event-type "order-confirmation")
        (= event-type "payment-received")
        (= event-type "payment-failed")
        (= event-type "order-cancelled")
        (= event-type "refund-issued")
        (= event-type "welcome"))
    e/channel-email

    (or (= event-type "item-shipped")
        (= event-type "fully-shipped"))
    e/channel-sms

    (= event-type "order-delivered")
    e/channel-push

    :else e/channel-email))

;; ============================================================
;; Notification builders
;; ============================================================

(defn build-order-confirmation
  "Builds an order confirmation notification."
  [order-state customer-state]
  (let [template (get templates "order-confirmation")
        body (render-notification template
               {"order-id" (str (:order-id order-state))
                "total" (str (:total order-state))})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-email
      body
      (:placed-at order-state))))

(defn build-shipping-notice
  "Builds a shipping notification."
  [shipment-state order-state]
  (let [template (get templates "item-shipped")
        body (render-notification template
               {"item-id" (str (:item-id shipment-state))
                "order-id" (str (:order-id shipment-state))
                "carrier" (or (:carrier shipment-state) "unknown")
                "tracking" (or (:tracking-number shipment-state) "pending")})]
    (e/make-notification-sent
      (str "order-" (:order-id order-state))
      e/channel-sms
      body
      (or (:shipped-at shipment-state) 0))))

(defn build-payment-failed-notice
  "Builds a payment failure notification."
  [payment-state customer-state]
  (let [template (get templates "payment-failed")
        body (render-notification template
               {"order-id" (str (:order-id payment-state))
                "reason" (or (:status payment-state) "unknown")})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-email
      body
      0)))

(defn build-delivery-confirmation
  "Builds a delivery confirmation notification."
  [order-state customer-state]
  (let [template (get templates "order-delivered")
        body (render-notification template
               {"order-id" (str (:order-id order-state))})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-push
      body
      (or (:delivered-at order-state) 0))))

(defn build-cancellation-notice
  "Builds an order cancellation notification."
  [order-state customer-state reason]
  (let [template (get templates "order-cancelled")
        body (render-notification template
               {"order-id" (str (:order-id order-state))
                "reason" reason})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-email
      body
      (or (:cancelled-at order-state) 0))))

(defn build-refund-notice
  "Builds a refund notification."
  [refund-event customer-state]
  (let [template (get templates "refund-issued")
        body (render-notification template
               {"amount" (str (:amount refund-event))
                "order-id" (str (:order-id refund-event))
                "reason" (or (:reason refund-event) "unspecified")})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-email
      body
      (:refunded-at refund-event))))

(defn build-welcome-notice
  "Builds a welcome notification for a newly registered customer."
  [customer-state]
  (let [template (get templates "welcome")
        body (render-notification template
               {"name" (:name customer-state)})]
    (e/make-notification-sent
      (:email customer-state)
      e/channel-email
      body
      (:registered-at customer-state))))

;; ============================================================
;; Notification history helpers
;; ============================================================

(defn notifications-for-recipient
  "Filters notification events for a specific recipient."
  [recipient events]
  (filterv
    (fn [ev]
      (and (instance? e/NotificationSent ev)
           (= (:recipient ev) recipient)))
    events))

(defn notifications-by-channel
  "Groups notification events by channel."
  [events]
  (let [notifs (filter (fn [ev] (instance? e/NotificationSent ev)) events)]
    (reduce
      (fn [groups n]
        (update groups (:channel n) (fnil conj []) n))
      {}
      notifs)))

(defn notification-count-by-channel
  "Returns a map of channel -> count for notifications."
  [events]
  (let [grouped (notifications-by-channel events)]
    (reduce-kv
      (fn [m k v] (assoc m k (count v)))
      {}
      grouped)))
