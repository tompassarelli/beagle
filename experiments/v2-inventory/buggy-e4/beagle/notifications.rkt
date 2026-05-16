#lang beagle

(ns notifications)

(require customers :as cust)
(require orders :as ord)
(require shipping :as ship)
(require billing)

;; =============================================================================
;; Records
;; =============================================================================

(defrecord Template [(id : Long) (name : String) (channel : String)
                     (subject : String) (body-pattern : String)])

(defrecord Notification [(id : Long) (template-id : Long)
                         (customer-id : Long) (reference-id : Long)
                         (reference-type : String) (status : String)
                         (created-at : Long) (sent-at : Long)])

(defrecord Preference [(customer-id : Long) (channel : String)
                       (enabled : Boolean)])

;; =============================================================================
;; Template operations
;; =============================================================================

;; find-template-by-id: locate a template by its id
(defn find-template-by-id [(templates : Any) (id : Long)] : Any
  (first (filterv (fn [t] (= (template-id t) id)) templates)))

;; find-template-by-name: locate a template by its name
(defn find-template-by-name [(templates : Any) (name : String)] : Any
  (first (filterv (fn [t] (= (template-name t) name)) templates)))

;; templates-for-channel: all templates using a given channel
(defn templates-for-channel [(templates : Any) (channel : String)] : Any
  (filterv (fn [t] (= (template-channel t) channel)) templates))

;; =============================================================================
;; Notification creation and lifecycle
;; =============================================================================

;; create-notification: build a new notification from a template and customer.
;; Starts with status "pending", sent-at 0.
(defn create-notification [(id : Long) (template : Any) (customer : Any)
                           (reference-id : Long) (reference-type : String)
                           (created-at : Long)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  reference-id
                  reference-type
                  "pending"
                  created-at
                  0))

;; send-notification: mark as "sent" with a sent-at timestamp, only if pending.
(defn send-notification [(n : Notification) (sent-at : Long)] : Notification
  (if (= (notification-status n) "pending")
      (->Notification (notification-id n)
                      (notification-template-id n)
                      (notification-customer-id n)
                      (notification-reference-id n)
                      (notification-reference-type n)
                      "sent"
                      (notification-created-at n)
                      sent-at)
      n))

;; fail-notification: mark as "failed", only if pending.
(defn fail-notification [(n : Notification)] : Notification
  (if (= (notification-status n) "pending")
      (->Notification (notification-id n)
                      (notification-template-id n)
                      (notification-customer-id n)
                      (notification-reference-id n)
                      (notification-reference-type n)
                      "failed"
                      (notification-created-at n)
                      (notification-sent-at n))
      n))

;; retry-notification: reset a failed notification to "pending".
(defn retry-notification [(n : Notification)] : Notification
  (if (= (notification-status n) "failed")
      (->Notification (notification-id n)
                      (notification-template-id n)
                      (notification-customer-id n)
                      (notification-reference-id n)
                      (notification-reference-type n)
                      "pending"
                      (notification-created-at n)
                      (notification-sent-at n))
      n))

;; =============================================================================
;; Notification lookup and filtering
;; =============================================================================

;; find-notification-by-id: locate a notification by id
(defn find-notification-by-id [(notifications : Any) (id : Long)] : Any
  (first (filterv (fn [n] (= (notification-id n) id)) notifications)))

;; notifications-for-customer: all notifications for a given customer-id
(defn notifications-for-customer [(notifications : Any)
                                  (customer-id : Long)] : Any
  (filterv (fn [n] (= (notification-customer-id n) customer-id))
           notifications))

;; notifications-by-status: filter by status string
(defn notifications-by-status [(notifications : Any)
                               (status : String)] : Any
  (filterv (fn [n] (= (notification-status n) status)) notifications))

;; pending-notifications: shortcut for status "pending"
(defn pending-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "pending"))

;; sent-notifications: shortcut for status "sent"
(defn sent-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "sent"))

;; notifications-for-reference: match both reference-id and reference-type
(defn notifications-for-reference [(notifications : Any)
                                   (reference-id : Long)
                                   (reference-type : String)] : Any
  (filterv (fn [n] (and (= (notification-reference-id n) reference-id)
                        (= (notification-reference-type n) reference-type)))
           notifications))

;; =============================================================================
;; Preference operations
;; =============================================================================

;; customer-preferences: all preferences for a customer
(defn customer-preferences [(prefs : Any) (customer-id : Long)] : Any
  (filterv (fn [p] (= (preference-customer-id p) customer-id)) prefs))

;; channel-enabled?: check if a customer has a specific channel enabled.
;; Default true if no matching preference exists.
(defn channel-enabled? [(prefs : Any) (customer-id : Long)
                        (channel : String)] : Boolean
  (let [matching (filterv (fn [p] (and (= (preference-customer-id p) customer-id)
                                       (= (preference-channel p) channel)))
                          prefs)]
    (if (empty? matching)
        true
        (preference-enabled (first matching)))))

;; set-preference: update or add a preference for a customer/channel pair.
;; Returns the updated prefs vector.
(defn set-preference [(prefs : Any) (customer-id : Long) (channel : String)
                      (enabled : Boolean)] : Any
  (let [exists (some (fn [p] (and (= (preference-customer-id p) customer-id)
                                  (= (preference-channel p) channel)))
                     prefs)]
    (if exists
        (mapv (fn [(p : Preference)]
                (if (and (= (preference-customer-id p) customer-id)
                         (= (preference-channel p) channel))
                    (->Preference customer-id channel enabled)
                    p))
              prefs)
        (conj prefs (->Preference customer-id channel enabled)))))

;; =============================================================================
;; Analytics
;; =============================================================================

;; delivery-rate-pct: (sent count * 100) / (sent + failed count).
;; Returns 100 if there are no sent+failed notifications.
(defn delivery-rate-pct [(notifications : Any)] : Long
  (let [sent-count (count (notifications-by-status notifications "sent"))
        failed-count (count (notifications-by-status notifications "failed"))
        total (count notifications)]
    (if (= total 0) 100
        (quot (* sent-count 100) total))))

;; notifications-sent-count: count of notifications with status "sent"
(defn notifications-sent-count [(notifications : Any)] : Long
  (count (notifications-by-status notifications "sent")))

;; notifications-failed-count: count of notifications with status "failed"
(defn notifications-failed-count [(notifications : Any)] : Long
  (count (notifications-by-status notifications "failed")))

;; channel-delivery-rate: delivery rate for notifications whose template
;; uses the specified channel.
(defn channel-delivery-rate [(notifications : Any) (templates : Any)
                             (channel : String)] : Long
  (let [channel-template-ids (mapv template-id
                                   (templates-for-channel templates channel))
        channel-notifs (filterv (fn [n]
                                  (some (fn [tid]
                                          (= (notification-template-id n) tid))
                                        channel-template-ids))
                                notifications)]
    (delivery-rate-pct channel-notifs)))

;; avg-send-time: average (sent-at - created-at) for sent notifications
(defn avg-send-time [(notifications : Any)] : Long
  (let [sent (notifications-by-status notifications "sent")
        cnt (count sent)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc n]
                        (+ acc (- (notification-status n)
                                  (notification-created-at n))))
                      0 sent)
              cnt))))

;; =============================================================================
;; Cross-module notification generation
;; =============================================================================

;; order-notification: create a notification for an order event.
;; reference-type "order", reference-id from ord/order-id.
(defn order-notification [(id : Long) (template : Any) (order : Any)
                          (customer : Any) (created-at : Long)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (ord/order-id order)
                  "order"
                  "pending"
                  0))

;; shipment-notification: create a notification for a shipment event.
;; reference-type "shipment", reference-id from ship/shipment-id.
(defn shipment-notification [(id : Long) (template : Any) (shipment : Any)
                             (customer : Any)
                             (created-at : Long)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (ship/shipment-status shipment)
                  "shipment"
                  "pending"
                  created-at
                  0))

;; invoice-notification: create a notification for an invoice event.
;; reference-type "invoice", reference-id from billing/invoice-id.
(defn invoice-notification [(id : Long) (template : Any) (invoice : Any)
                            (customer : Any)
                            (created-at : Long)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (billing/invoice-id invoice)
                  "invoice"
                  "pending"
                  created-at
                  0))

;; should-notify?: check whether a customer should receive a notification
;; via the template's channel, according to their preferences.
(defn should-notify? [(prefs : Any) (customer : Any)
                      (template : Any)] : Boolean
  (channel-enabled? prefs (cust/customer-id customer)
                    (template-channel template)))

;; =============================================================================
;; Notification validation
;; =============================================================================

;; valid-template?: basic validation for a template record
(defn valid-template? [(t : Template)] : Boolean
  (and (> (template-id t) 0)
       (not= (template-name t) "")
       (not= (template-channel t) "")
       (not= (template-subject t) "")
       (not= (template-body-pattern t) "")))

;; valid-notification?: basic validation for a notification record
(defn valid-notification? [(n : Notification)] : Boolean
  (and (> (notification-id n) 0)
       (> (notification-template-id n) 0)
       (> (notification-customer-id n) 0)
       (> (notification-reference-id n) 0)
       (not= (notification-reference-type n) "")))

;; =============================================================================
;; Notification sorting
;; =============================================================================

;; sort-notifications-by-date: sort by created-at ascending
(defn sort-notifications-by-date [(notifications : Any)] : Any
  (sort-by notification-created-at notifications))

;; sort-notifications-by-sent: sort by sent-at ascending
(defn sort-notifications-by-sent [(notifications : Any)] : Any
  (sort-by notification-sent-at notifications))

;; =============================================================================
;; Notification counts and grouping
;; =============================================================================

;; notification-status-counts: count of notifications per status
(defn notification-status-counts [(notifications : Any)] : Any
  (let [pending-count (count (pending-notifications notifications))
        sent-count (count (sent-notifications notifications))
        failed-count (count (notifications-by-status notifications "failed"))]
    {:pending pending-count
     :sent sent-count
     :failed failed-count}))

;; notifications-by-reference-type: filter by reference-type
(defn notifications-by-reference-type [(notifications : Any)
                                       (ref-type : String)] : Any
  (filterv (fn [n] (= (notification-reference-type n) ref-type))
           notifications))

;; customer-notification-count: total notifications for a customer
(defn customer-notification-count [(notifications : Any)
                                   (customer-id : Long)] : Long
  (count (notifications-for-customer notifications customer-id)))

;; customer-sent-count: count of sent notifications for a customer
(defn customer-sent-count [(notifications : Any)
                           (customer-id : Long)] : Long
  (count (filterv (fn [n] (and (= (notification-customer-id n) customer-id)
                               (= (notification-status n) "sent")))
                  notifications)))

;; =============================================================================
;; Template analytics
;; =============================================================================

;; template-notification-count: how many notifications use a given template
(defn template-notification-count [(notifications : Any)
                                   (template-id : Long)] : Long
  (count (filterv (fn [n] (= (notification-template-id n) template-id))
                  notifications)))

;; template-sent-count: how many sent notifications use a given template
(defn template-sent-count [(notifications : Any)
                           (template-id : Long)] : Long
  (count (filterv (fn [n] (and (= (notification-template-id n) template-id)
                               (= (notification-status n) "sent")))
                  notifications)))

;; template-delivery-rate: delivery rate for a specific template
(defn template-delivery-rate [(notifications : Any)
                              (template-id : Long)] : Long
  (let [tmpl-notifs (filterv (fn [n] (= (notification-template-id n)
                                        template-id))
                             notifications)]
    (delivery-rate-pct tmpl-notifs)))

;; =============================================================================
;; Bulk operations
;; =============================================================================

;; send-all-pending: mark all pending notifications as sent at a given time
(defn send-all-pending [(notifications : Any) (sent-at : Long)] : Any
  (mapv (fn [(n : Notification)]
          (if (= (notification-status n) "pending")
              (send-notification n sent-at)
              n))
        notifications))

;; retry-all-failed: reset all failed notifications back to pending
(defn retry-all-failed [(notifications : Any)] : Any
  (mapv (fn [(n : Notification)]
          (if (= (notification-status n) "failed")
              (retry-notification n)
              n))
        notifications))

;; =============================================================================
;; Notification timing analytics
;; =============================================================================

;; notifications-in-period: notifications created within [start, end]
(defn notifications-in-period [(notifications : Any) (start : Long)
                               (end : Long)] : Any
  (filterv (fn [n] (and (>= (notification-created-at n) start)
                        (<= (notification-created-at n) end)))
           notifications))

;; notification-count-in-period: count of notifications in a time window
(defn notification-count-in-period [(notifications : Any) (start : Long)
                                    (end : Long)] : Long
  (count (notifications-in-period notifications start end)))

;; sent-in-period: notifications sent within [start, end]
(defn sent-in-period [(notifications : Any) (start : Long)
                      (end : Long)] : Any
  (filterv (fn [n] (and (= (notification-status n) "sent")
                        (>= (notification-sent-at n) start)
                        (<= (notification-sent-at n) end)))
           notifications))

;; =============================================================================
;; Preference analytics
;; =============================================================================

;; channel-opt-in-count: how many customers have the channel enabled
(defn channel-opt-in-count [(prefs : Any) (channel : String)] : Long
  (count (filterv (fn [p] (and (= (preference-channel p) channel)
                               (preference-enabled p)))
                  prefs)))

;; channel-opt-out-count: how many customers have the channel disabled
(defn channel-opt-out-count [(prefs : Any) (channel : String)] : Long
  (count (filterv (fn [p] (and (= (preference-channel p) channel)
                               (not (preference-enabled p))))
                  prefs)))

;; unique-channels: distinct channels found in preferences
(defn unique-channels [(prefs : Any)] : Any
  (distinct (mapv preference-channel prefs)))

;; preference-summary: map of channel -> enabled-count
(defn preference-summary [(prefs : Any)] : Any
  (let [channels (unique-channels prefs)]
    (reduce (fn [acc ch]
              (assoc acc ch (channel-opt-in-count prefs ch)))
            {} channels)))

;; =============================================================================
;; Formatting
;; =============================================================================

;; notification-summary: human-readable summary of a notification
(defn notification-summary [(n : Notification)] : String
  (str "Notification #" (notification-id n)
       " | Template: " (notification-template-id n)
       " | Customer: " (notification-customer-id n)
       " | " (notification-reference-type n)
       " #" (notification-reference-id n)
       " | " (notification-status n)))

;; template-summary: human-readable summary of a template
(defn template-summary [(t : Template)] : String
  (str "Template #" (template-id t)
       " | " (template-name t)
       " | Channel: " (template-channel t)
       " | Subject: " (template-subject t)))

;; notification-detail: verbose notification string
(defn notification-detail [(n : Notification)] : String
  (str "Notification #" (notification-id n)
       " | Template: " (notification-template-id n)
       " | Customer: " (notification-customer-id n)
       " | Ref: " (notification-reference-type n) "#"
       (notification-reference-id n)
       " | Status: " (notification-status n)
       " | Created: " (notification-created-at n)
       " | Sent: " (notification-sent-at n)))

;; =============================================================================
;; Customer notification history
;; =============================================================================

;; customer-recent-notifications: last n notifications for a customer by date
(defn customer-recent-notifications [(notifications : Any)
                                     (customer-id : Long)
                                     (n : Long)] : Any
  (let [cust-notifs (notifications-for-customer notifications customer-id)
        sorted (reverse (sort-by notification-created-at cust-notifs))]
    (vec (take n sorted))))

;; customer-notification-summary: status counts for a specific customer
(defn customer-notification-summary [(notifications : Any)
                                     (customer-id : Long)] : Any
  (let [cust-notifs (notifications-for-customer notifications customer-id)]
    {:total (count cust-notifs)
     :sent (count (filterv (fn [n] (= (notification-status n) "sent"))
                           cust-notifs))
     :pending (count (filterv (fn [n] (= (notification-status n) "pending"))
                              cust-notifs))
     :failed (count (filterv (fn [n] (= (notification-status n) "failed"))
                             cust-notifs))}))

;; =============================================================================
;; Cross-module notification queries
;; =============================================================================

;; order-notifications: all notifications referencing a specific order
(defn order-notifications [(notifications : Any) (order-id : Long)] : Any
  (notifications-for-reference notifications order-id "order"))

;; shipment-notifications: all notifications referencing a specific shipment
(defn shipment-notifications [(notifications : Any)
                              (shipment-id : Long)] : Any
  (notifications-for-reference notifications shipment-id "shipment"))

;; invoice-notifications: all notifications referencing a specific invoice
(defn invoice-notifications [(notifications : Any)
                             (invoice-id : Long)] : Any
  (notifications-for-reference notifications invoice-id "invoice"))

;; =============================================================================
;; Failed notification diagnostics
;; =============================================================================

;; failed-notifications: all notifications with status "failed"
(defn failed-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "failed"))

;; failed-for-customer: failed notifications for a specific customer
(defn failed-for-customer [(notifications : Any)
                           (customer-id : Long)] : Any
  (filterv (fn [n] (and (= (notification-customer-id n) customer-id)
                        (= (notification-status n) "failed")))
           notifications))

;; failure-rate-pct: percentage of all notifications that failed
(defn failure-rate-pct [(notifications : Any)] : Long
  (let [total (count notifications)]
    (if (= total 0) 0
        (quot (* (notifications-failed-count notifications) 100) total))))

;; =============================================================================
;; Notification throughput analytics
;; =============================================================================

;; fastest-notification: sent notification with shortest send time
(defn fastest-notification [(notifications : Any)] : Any
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)]
    (if (empty? sent)
        nil
        (reduce (fn [best n]
                  (let [best-time (- (notification-sent-at best)
                                     (notification-created-at best))
                        n-time (- (notification-sent-at n)
                                  (notification-created-at n))]
                    (if (< n-time best-time) n best)))
                (first sent)
                (rest sent)))))

;; slowest-notification: sent notification with longest send time
(defn slowest-notification [(notifications : Any)] : Any
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)]
    (if (empty? sent)
        nil
        (reduce (fn [worst n]
                  (let [worst-time (- (notification-sent-at worst)
                                      (notification-created-at worst))
                        n-time (- (notification-sent-at n)
                                  (notification-created-at n))]
                    (if (> n-time worst-time) n worst)))
                (first sent)
                (rest sent)))))

;; =============================================================================
;; Notification dashboard
;; =============================================================================

;; notification-dashboard: high-level metrics as a map
(defn notification-dashboard [(notifications : Any)
                              (templates : Any)
                              (prefs : Any)] : Any
  (let [total (count notifications)
        sent-cnt (notifications-sent-count notifications)
        failed-cnt (notifications-failed-count notifications)
        pending-cnt (count (pending-notifications notifications))
        del-rate (delivery-rate-pct notifications)
        avg-time (avg-send-time notifications)
        tmpl-count (count templates)
        pref-count (count prefs)]
    {:total-notifications total
     :sent sent-cnt
     :failed failed-cnt
     :pending pending-cnt
     :delivery-rate del-rate
     :avg-send-time avg-time
     :template-count tmpl-count
     :preference-count pref-count}))

;; =============================================================================
;; Channel distribution analytics
;; =============================================================================

;; notifications-by-channel: count of notifications per channel, using templates
(defn notifications-by-channel [(notifications : Any)
                                (templates : Any)] : Any
  (let [channels (distinct (mapv template-channel templates))]
    (reduce (fn [acc ch]
              (let [ch-tmpl-ids (mapv template-id
                                     (templates-for-channel templates ch))
                    cnt (count (filterv
                                 (fn [n]
                                   (some (fn [tid]
                                           (= (notification-template-id n) tid))
                                         ch-tmpl-ids))
                                 notifications))]
                (assoc acc ch cnt)))
            {} channels)))

;; channel-sent-count: count of sent notifications for a channel
(defn channel-sent-count [(notifications : Any) (templates : Any)
                          (channel : String)] : Long
  (let [ch-tmpl-ids (mapv template-id
                          (templates-for-channel templates channel))
        ch-sent (filterv (fn [n]
                           (and (= (notification-status n) "sent")
                                (some (fn [tid]
                                        (= (notification-template-id n) tid))
                                      ch-tmpl-ids)))
                         notifications)]
    (count ch-sent)))

;; channel-failed-count: count of failed notifications for a channel
(defn channel-failed-count [(notifications : Any) (templates : Any)
                            (channel : String)] : Long
  (let [ch-tmpl-ids (mapv template-id
                          (templates-for-channel templates channel))
        ch-failed (filterv (fn [n]
                             (and (= (notification-status n) "failed")
                                  (some (fn [tid]
                                          (= (notification-template-id n) tid))
                                        ch-tmpl-ids)))
                           notifications)]
    (count ch-failed)))

;; =============================================================================
;; Reference type analytics
;; =============================================================================

;; reference-type-counts: count notifications by reference type
(defn reference-type-counts [(notifications : Any)] : Any
  (let [order-cnt (count (notifications-by-reference-type notifications "order"))
        shipment-cnt (count (notifications-by-reference-type notifications
                                                             "shipment"))
        invoice-cnt (count (notifications-by-reference-type notifications
                                                            "invoice"))]
    {:order order-cnt
     :shipment shipment-cnt
     :invoice invoice-cnt}))

;; reference-type-delivery-rate: delivery rate for a given reference type
(defn reference-type-delivery-rate [(notifications : Any)
                                    (ref-type : String)] : Long
  (delivery-rate-pct (notifications-by-reference-type notifications ref-type)))

;; =============================================================================
;; Notification age analytics
;; =============================================================================

;; notification-age [(n : Notification) (now : Long)] : Long
;; How many seconds since the notification was created
(defn notification-age [(n : Notification) (now : Long)] : Long
  (- now (notification-created-at n)))

;; notification-age-days: age in whole days
(defn notification-age-days [(n : Notification) (now : Long)] : Long
  (quot (notification-age n now) 86400))

;; stale-pending: pending notifications older than threshold days
(defn stale-pending [(notifications : Any) (now : Long)
                     (threshold-days : Long)] : Any
  (let [max-seconds (* threshold-days 86400)]
    (filterv (fn [n] (and (= (notification-status n) "pending")
                          (> (- now (notification-created-at n)) max-seconds)))
             notifications)))

;; =============================================================================
;; Comprehensive notification report
;; =============================================================================

;; notification-report: full report combining all major metrics
(defn notification-report [(notifications : Any) (templates : Any)
                           (prefs : Any)] : Any
  (let [total (count notifications)
        sent-cnt (notifications-sent-count notifications)
        failed-cnt (notifications-failed-count notifications)
        pending-cnt (count (pending-notifications notifications))
        del-rate (delivery-rate-pct notifications)
        avg-time (avg-send-time notifications)
        ref-counts (reference-type-counts notifications)
        status-counts (notification-status-counts notifications)
        tmpl-count (count templates)
        pref-count (count prefs)]
    {:total-notifications total
     :sent sent-cnt
     :failed failed-cnt
     :pending pending-cnt
     :delivery-rate del-rate
     :avg-send-time avg-time
     :reference-types ref-counts
     :status-counts status-counts
     :template-count tmpl-count
     :preference-count pref-count}))

;; =============================================================================
;; Customer preference management
;; =============================================================================

;; disable-channel: convenience for disabling a channel for a customer
(defn disable-channel [(prefs : Any) (customer-id : Long)
                       (channel : String)] : Any
  (set-preference prefs customer-id channel false))

;; enable-channel: convenience for enabling a channel for a customer
(defn enable-channel [(prefs : Any) (customer-id : Long)
                      (channel : String)] : Any
  (set-preference prefs customer-id channel true))

;; customer-enabled-channels: list of channels enabled for a customer
(defn customer-enabled-channels [(prefs : Any)
                                 (customer-id : Long)] : Any
  (let [cust-prefs (customer-preferences prefs customer-id)]
    (mapv preference-channel
          (filterv (fn [p] (preference-enabled p)) cust-prefs))))

;; customer-disabled-channels: list of channels disabled for a customer
(defn customer-disabled-channels [(prefs : Any)
                                  (customer-id : Long)] : Any
  (let [cust-prefs (customer-preferences prefs customer-id)]
    (mapv preference-channel
          (filterv (fn [p] (not (preference-enabled p))) cust-prefs))))

;; customer-has-preferences?: whether a customer has any preferences set
(defn customer-has-preferences? [(prefs : Any)
                                 (customer-id : Long)] : Boolean
  (> (count (customer-preferences prefs customer-id)) 0))

;; =============================================================================
;; Notification batch creation (cross-module)
;; =============================================================================

;; notify-all-for-order: create notifications for all customers in a list
;; for a given order, respecting channel preferences.
;; Returns a vector of notifications that should be sent.
(defn notify-all-for-order [(next-id : Long) (template : Any)
                            (order : Any) (customers : Any)
                            (prefs : Any) (created-at : Long)] : Any
  (let [eligible (filterv (fn [c] (should-notify? prefs c template))
                          customers)]
    (mapv (fn [c]
            (let [idx (count (filterv (fn [c2]
                                        (< (cust/customer-id c2)
                                           (cust/customer-id c)))
                                      eligible))]
              (order-notification (+ next-id idx) template order c created-at)))
          eligible)))

;; =============================================================================
;; Notification enrichment
;; =============================================================================

;; notification-with-template-info: return a map with notification and template
;; details combined for display purposes
(defn notification-with-template-info [(n : Notification)
                                       (templates : Any)] : Any
  (let [tmpl (find-template-by-id templates (notification-template-id n))
        tmpl-name (if (nil? tmpl) "unknown" (template-name tmpl))
        tmpl-channel (if (nil? tmpl) "unknown" (template-channel tmpl))
        tmpl-subject (if (nil? tmpl) "" (template-subject tmpl))]
    {:notification-id (notification-id n)
     :customer-id (notification-customer-id n)
     :reference-type (notification-reference-type n)
     :reference-id (notification-reference-id n)
     :status (notification-status n)
     :created-at (notification-created-at n)
     :sent-at (notification-sent-at n)
     :template-name tmpl-name
     :channel tmpl-channel
     :subject tmpl-subject}))

;; enriched-notification-list: enrich all notifications with template info
(defn enriched-notification-list [(notifications : Any)
                                  (templates : Any)] : Any
  (mapv (fn [n] (notification-with-template-info n templates))
        notifications))

;; =============================================================================
;; Notification deduplication
;; =============================================================================

;; has-existing-notification?: check if a notification already exists for
;; a given customer/reference combination
(defn has-existing-notification? [(notifications : Any)
                                  (customer-id : Long)
                                  (reference-id : Long)
                                  (reference-type : String)] : Boolean
  (let [matches (filterv (fn [n]
                           (and (= (notification-customer-id n) customer-id)
                                (= (notification-reference-id n) reference-id)
                                (= (notification-reference-type n) reference-type)))
                         notifications)]
    (> (count matches) 0)))

;; duplicate-notifications: find notifications that share customer+reference
;; with at least one other notification (potential duplicates)
(defn duplicate-notifications [(notifications : Any)] : Any
  (filterv (fn [n]
             (let [matches (filterv (fn [other]
                                      (and (not= (notification-id other)
                                                 (notification-id n))
                                           (= (notification-customer-id other)
                                              (notification-customer-id n))
                                           (= (notification-reference-id other)
                                              (notification-reference-id n))
                                           (= (notification-reference-type other)
                                              (notification-reference-type n))))
                                   notifications)]
               (> (count matches) 0)))
           notifications))

;; =============================================================================
;; Customer communication scoring
;; =============================================================================

;; customer-engagement-score: score based on notification interactions
;; Sent = +10 points each, Failed = -5 points each, Pending = +2 each
(defn customer-engagement-score [(notifications : Any)
                                 (customer-id : Long)] : Long
  (let [cust-notifs (notifications-for-customer notifications customer-id)
        sent-cnt (count (filterv (fn [n] (= (notification-status n) "sent"))
                                 cust-notifs))
        failed-cnt (count (filterv (fn [n] (= (notification-status n) "failed"))
                                   cust-notifs))
        pending-cnt (count (filterv (fn [n] (= (notification-status n) "pending"))
                                    cust-notifs))]
    (+ (* sent-cnt 10) (* pending-cnt 2) (- 0 (* failed-cnt 5)))))

;; top-engaged-customers: customer-ids sorted by engagement score descending
(defn top-engaged-customers [(notifications : Any)
                             (customer-ids : Any)
                             (n : Long)] : Any
  (let [scored (reverse (sort-by (fn [cid]
                                   (customer-engagement-score notifications cid))
                                 customer-ids))]
    (vec (take n scored))))

;; =============================================================================
;; Notification volume analytics
;; =============================================================================

;; avg-daily-notification-volume: average notifications per day in a range
(defn avg-daily-notification-volume [(notifications : Any) (start : Long)
                                     (end : Long)] : Long
  (let [period-notifs (notifications-in-period notifications start end)
        days (quot (- end start) 86400)]
    (if (<= days 0) (count period-notifs)
        (quot (count period-notifs) days))))

;; notifications-created-before: filter by created-at < timestamp
(defn notifications-created-before [(notifications : Any)
                                    (timestamp : Long)] : Any
  (filterv (fn [n] (< (notification-created-at n) timestamp)) notifications))

;; notifications-created-after: filter by created-at > timestamp
(defn notifications-created-after [(notifications : Any)
                                   (timestamp : Long)] : Any
  (filterv (fn [n] (> (notification-created-at n) timestamp)) notifications))

;; =============================================================================
;; Template management
;; =============================================================================

;; template-channels: distinct channels across all templates
(defn template-channels [(templates : Any)] : Any
  (distinct (mapv template-channel templates)))

;; templates-by-channel-summary: map of channel -> count of templates
(defn templates-by-channel-summary [(templates : Any)] : Any
  (let [channels (template-channels templates)]
    (reduce (fn [acc ch]
              (assoc acc ch (count (templates-for-channel templates ch))))
            {} channels)))

;; find-template-by-channel-and-name: locate a template by channel and name
(defn find-template-by-channel-and-name [(templates : Any) (channel : String)
                                         (name : String)] : Any
  (first (filterv (fn [t] (and (= (template-channel t) channel)
                               (= (template-name t) name)))
                  templates)))

;; =============================================================================
;; Cross-module notification summaries
;; =============================================================================

;; order-notification-status: get the notification status for an order.
;; Returns "none" if no notification exists, or the status of the latest one.
(defn order-notification-status [(notifications : Any)
                                 (order-id : Long)] : String
  (let [order-notifs (order-notifications notifications order-id)]
    (if (empty? order-notifs)
        "none"
        (let [sorted (reverse (sort-by notification-created-at order-notifs))]
          (notification-status (first sorted))))))

;; shipment-notification-status: get the notification status for a shipment
(defn shipment-notification-status [(notifications : Any)
                                    (shipment-id : Long)] : String
  (let [ship-notifs (shipment-notifications notifications shipment-id)]
    (if (empty? ship-notifs)
        "none"
        (let [sorted (reverse (sort-by notification-created-at ship-notifs))]
          (notification-status (first sorted))))))

;; invoice-notification-status: get the notification status for an invoice
(defn invoice-notification-status [(notifications : Any)
                                   (invoice-id : Long)] : String
  (let [inv-notifs (invoice-notifications notifications invoice-id)]
    (if (empty? inv-notifs)
        "none"
        (let [sorted (reverse (sort-by notification-created-at inv-notifs))]
          (notification-status (first sorted))))))

;; =============================================================================
;; Notification retry analytics
;; =============================================================================

;; retryable-notifications: failed notifications that could be retried
(defn retryable-notifications [(notifications : Any)] : Any
  (failed-notifications notifications))

;; retry-count-needed: how many retries are needed
(defn retry-count-needed [(notifications : Any)] : Long
  (count (retryable-notifications notifications)))

;; retry-count-for-customer: count of retryable notifications per customer
(defn retry-count-for-customer [(notifications : Any)
                                (customer-id : Long)] : Long
  (count (failed-for-customer notifications customer-id)))

;; =============================================================================
;; Notification SLA tracking
;; =============================================================================

;; within-sla?: check if a sent notification was delivered within the SLA
;; (max-seconds from creation to send)
(defn within-sla? [(n : Notification) (max-seconds : Long)] : Boolean
  (if (= (notification-status n) "sent")
      (<= (- (notification-sent-at n) (notification-created-at n)) max-seconds)
      false))

;; sla-compliance-rate: percentage of sent notifications within SLA
(defn sla-compliance-rate [(notifications : Any)
                           (max-seconds : Long)] : Long
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)
        cnt (count sent)]
    (if (= cnt 0) 100
        (let [compliant (count (filterv (fn [n] (within-sla? n max-seconds))
                                        sent))]
          (quot (* compliant 100) cnt)))))

;; sla-breaches: sent notifications that exceeded the SLA
(defn sla-breaches [(notifications : Any) (max-seconds : Long)] : Any
  (filterv (fn [n] (and (= (notification-status n) "sent")
                        (not (within-sla? n max-seconds))))
           notifications))

;; =============================================================================
;; Comprehensive customer notification report
;; =============================================================================

;; customer-notification-report: full report for a single customer
(defn customer-notification-report [(notifications : Any)
                                    (templates : Any)
                                    (prefs : Any)
                                    (customer-id : Long)] : Any
  (let [cust-notifs (notifications-for-customer notifications customer-id)
        total (count cust-notifs)
        sent-cnt (count (filterv (fn [n] (= (notification-status n) "sent"))
                                 cust-notifs))
        failed-cnt (count (filterv (fn [n] (= (notification-status n) "failed"))
                                   cust-notifs))
        pending-cnt (count (filterv (fn [n] (= (notification-status n) "pending"))
                                    cust-notifs))
        del-rate (delivery-rate-pct cust-notifs)
        avg-time (avg-send-time cust-notifs)
        engagement (customer-engagement-score notifications customer-id)
        cust-prefs (customer-preferences prefs customer-id)
        enabled-channels (customer-enabled-channels prefs customer-id)]
    {:customer-id customer-id
     :total-notifications total
     :sent sent-cnt
     :failed failed-cnt
     :pending pending-cnt
     :delivery-rate del-rate
     :avg-send-time avg-time
     :engagement-score engagement
     :preference-count (count cust-prefs)
     :enabled-channels enabled-channels}))
