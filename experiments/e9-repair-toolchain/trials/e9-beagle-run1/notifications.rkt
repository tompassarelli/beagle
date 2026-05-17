#lang beagle

(ns notifications)
(define-mode strict)

(require customers :as cust)
(require orders :as ord)
(require shipping :as ship)
(require billing)

;; --- scalars ---------------------------------------------------------------

(defscalar NotificationId Long)
(defscalar TemplateId Long)

;; =============================================================================
;; Records
;; =============================================================================

(defrecord Template [(id : TemplateId) (name : String) (channel : String)
                     (subject : String) (body-pattern : String)])

(defrecord Notification [(id : NotificationId) (template-id : TemplateId)
                         (customer-id : cust/CustomerId) (reference-id : Long)
                         (reference-type : String) (status : String)
                         (created-at : ord/Timestamp) (sent-at : ord/Timestamp)])

(defrecord Preference [(customer-id : cust/CustomerId) (channel : String)
                       (enabled : Boolean)])

;; =============================================================================
;; Template operations
;; =============================================================================

(defn find-template-by-id [(templates : Any) (id : TemplateId)] : Any
  (first (filterv (fn [t] (= (templateid-value (template-id t)) (templateid-value id))) templates)))

(defn find-template-by-name [(templates : Any) (name : String)] : Any
  (first (filterv (fn [t] (= (template-name t) name)) templates)))

(defn templates-for-channel [(templates : Any) (channel : String)] : Any
  (filterv (fn [t] (= (template-channel t) channel)) templates))

;; =============================================================================
;; Notification creation and lifecycle
;; =============================================================================

(defn create-notification [(id : NotificationId) (template : Any) (customer : Any)
                           (reference-id : Long) (reference-type : String)
                           (created-at : ord/Timestamp)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  reference-id
                  reference-type
                  "pending"
                  created-at
                  (ord/->Timestamp 0)))

(defn send-notification [(n : Notification) (sent-at : ord/Timestamp)] : Notification
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

(defn find-notification-by-id [(notifications : Any) (id : NotificationId)] : Any
  (first (filterv (fn [n] (= (notificationid-value (notification-template-id n)) (notificationid-value id))) notifications)))

(defn notifications-for-customer [(notifications : Any)
                                  (customer-id : cust/CustomerId)] : Any
  (filterv (fn [n] (= (customerid-value (notification-customer-id n)) (customerid-value customer-id)))
           notifications))

(defn notifications-by-status [(notifications : Any)
                               (status : String)] : Any
  (filterv (fn [n] (= (notification-status n) status)) notifications))

(defn pending-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "pending"))

(defn sent-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "sent"))

(defn notifications-for-reference [(notifications : Any)
                                   (reference-id : Long)
                                   (reference-type : String)] : Any
  (filterv (fn [n] (and (= (notification-reference-id n) reference-id)
                        (= (notification-reference-type n) reference-type)))
           notifications))

;; =============================================================================
;; Preference operations
;; =============================================================================

(defn customer-preferences [(prefs : Any) (customer-id : cust/CustomerId)] : Any
  (filterv (fn [p] (= (customerid-value (preference-customer-id p)) (customerid-value customer-id))) prefs))

(defn channel-enabled? [(prefs : Any) (customer-id : cust/CustomerId)
                        (channel : String)] : Boolean
  (let [matching (filterv (fn [p] (and (= (customerid-value (preference-customer-id p)) (customerid-value customer-id))
                                       (= (preference-channel p) channel)))
                          prefs)]
    (if (empty? matching)
        true
        (preference-enabled (first matching)))))

(defn set-preference [(prefs : Any) (customer-id : cust/CustomerId) (channel : String)
                      (enabled : Boolean)] : Any
  (let [exists (some (fn [p] (and (= (customerid-value (preference-customer-id p)) (customerid-value customer-id))
                                  (= (preference-channel p) channel)))
                     prefs)]
    (if exists
        (mapv (fn [(p : Preference)]
                (if (and (= (customerid-value (preference-customer-id p)) (customerid-value customer-id))
                         (= (preference-channel p) channel))
                    (->Preference customer-id channel enabled)
                    p))
              prefs)
        (conj prefs (->Preference customer-id channel enabled)))))

;; =============================================================================
;; Analytics
;; =============================================================================

(defn delivery-rate-pct [(notifications : Any)] : Long
  (let [sent-count (count (notifications-by-status notifications "sent"))
        failed-count (count (notifications-by-status notifications "failed"))
        total (+ sent-count failed-count)]
    (if (= total 0) 100
        (quot (* sent-count 100) total))))

(defn notifications-sent-count [(notifications : Any)] : Long
  (count (notifications-by-status notifications "sent")))

(defn notifications-failed-count [(notifications : Any)] : Long
  (count (notifications-by-status notifications "failed")))

(defn channel-delivery-rate [(notifications : Any) (templates : Any)
                             (channel : String)] : Long
  (let [channel-template-ids (mapv (fn [t] (templateid-value (template-id t)))
                                   (templates-for-channel templates channel))
        channel-notifs (filterv (fn [n]
                                  (some (fn [tid]
                                          (= (templateid-value (notification-template-id n)) tid))
                                        channel-template-ids))
                                notifications)]
    (delivery-rate-pct channel-notifs)))

(defn avg-send-time [(notifications : Any)] : Long
  (let [sent (notifications-by-status notifications "sent")
        cnt (count sent)]
    (if (= cnt 0) 0
        (quot (reduce (fn [acc n]
                        (+ acc (- (timestamp-value (notification-sent-at n))
                                  (timestamp-value (notification-created-at n)))))
                      0 sent)
              cnt))))

;; =============================================================================
;; Cross-module notification generation
;; =============================================================================

(defn order-notification [(id : NotificationId) (template : Any) (order : Any)
                          (customer : Any) (created-at : ord/Timestamp)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (orderid-value (ord/order-id order))
                  "order"
                  "pending"
                  created-at
                  (->Timestamp 0)))

(defn shipment-notification [(id : NotificationId) (template : Any) (shipment : Any)
                             (customer : Any)
                             (created-at : ord/Timestamp)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (shipmentid-value (ship/shipment-id shipment))
                  "shipment"
                  "pending"
                  created-at
                  (->Timestamp 0)))

(defn invoice-notification [(id : NotificationId) (template : Any) (invoice : Any)
                            (customer : Any)
                            (created-at : ord/Timestamp)] : Notification
  (->Notification id
                  (template-id template)
                  (cust/customer-id customer)
                  (invoiceid-value (billing/invoice-id invoice))
                  "invoice"
                  "pending"
                  created-at
                  (->Timestamp 0)))

(defn should-notify? [(prefs : Any) (customer : Any)
                      (template : Any)] : Boolean
  (channel-enabled? prefs (cust/customer-id customer)
                    (template-channel template)))

;; =============================================================================
;; Notification validation
;; =============================================================================

(defn valid-template? [(t : Template)] : Boolean
  (and (> (templateid-value (template-id t)) 0)
       (not= (template-name t) "")
       (not= (template-channel t) "")
       (not= (template-subject t) "")
       (not= (template-body-pattern t) "")))

(defn valid-notification? [(n : Notification)] : Boolean
  (and (> (notificationid-value (notification-id n)) 0)
       (> (templateid-value (notification-template-id n)) 0)
       (> (customerid-value (notification-customer-id n)) 0)
       (> (notification-reference-id n) 0)
       (not= (notification-reference-type n) "")))

;; =============================================================================
;; Notification sorting
;; =============================================================================

(defn sort-notifications-by-date [(notifications : Any)] : Any
  (sort-by (fn [n] (timestamp-value (notification-created-at n))) notifications))

(defn sort-notifications-by-sent [(notifications : Any)] : Any
  (sort-by (fn [n] (timestamp-value (notification-sent-at n))) notifications))

;; =============================================================================
;; Notification counts and grouping
;; =============================================================================

(defn notification-status-counts [(notifications : Any)] : Any
  (let [pending-count (count (pending-notifications notifications))
        sent-count (count (sent-notifications notifications))
        failed-count (count (notifications-by-status notifications "failed"))]
    {:pending pending-count
     :sent sent-count
     :failed failed-count}))

(defn notifications-by-reference-type [(notifications : Any)
                                       (ref-type : String)] : Any
  (filterv (fn [n] (= (notification-reference-type n) ref-type))
           notifications))

(defn customer-notification-count [(notifications : Any)
                                   (customer-id : cust/CustomerId)] : Long
  (count (notifications-for-customer notifications customer-id)))

(defn customer-sent-count [(notifications : Any)
                           (customer-id : cust/CustomerId)] : Long
  (count (filterv (fn [n] (and (= (customerid-value (notification-customer-id n)) (customerid-value customer-id))
                               (= (notification-status n) "sent")))
                  notifications)))

;; =============================================================================
;; Template analytics
;; =============================================================================

(defn template-notification-count [(notifications : Any)
                                   (tid : TemplateId)] : Long
  (count (filterv (fn [n] (= (templateid-value (notification-template-id n)) (templateid-value tid)))
                  notifications)))

(defn template-sent-count [(notifications : Any)
                           (tid : TemplateId)] : Long
  (count (filterv (fn [n] (and (= (templateid-value (notification-template-id n)) (templateid-value tid))
                               (= (notification-status n) "sent")))
                  notifications)))

(defn template-delivery-rate [(notifications : Any)
                              (tid : TemplateId)] : Long
  (let [tmpl-notifs (filterv (fn [n] (= (templateid-value (notification-template-id n))
                                        (templateid-value tid)))
                             notifications)]
    (delivery-rate-pct tmpl-notifs)))

;; =============================================================================
;; Bulk operations
;; =============================================================================

(defn send-all-pending [(notifications : Any) (sent-at : ord/Timestamp)] : Any
  (mapv (fn [(n : Notification)]
          (if (= (notification-status n) "pending")
              (send-notification n sent-at)
              n))
        notifications))

(defn retry-all-failed [(notifications : Any)] : Any
  (mapv (fn [(n : Notification)]
          (if (= (notification-status n) "failed")
              (retry-notification n)
              n))
        notifications))

;; =============================================================================
;; Notification timing analytics
;; =============================================================================

(defn notifications-in-period [(notifications : Any) (start : ord/Timestamp)
                               (end : ord/Timestamp)] : Any
  (filterv (fn [n] (and (>= (timestamp-value (notification-created-at n)) (timestamp-value start))
                        (<= (timestamp-value (notification-created-at n)) (timestamp-value end))))
           notifications))

(defn notification-count-in-period [(notifications : Any) (start : ord/Timestamp)
                                    (end : ord/Timestamp)] : Long
  (count (notifications-in-period notifications start end)))

(defn sent-in-period [(notifications : Any) (start : ord/Timestamp)
                      (end : ord/Timestamp)] : Any
  (filterv (fn [n] (and (= (notification-status n) "sent")
                        (>= (timestamp-value (notification-sent-at n)) (timestamp-value start))
                        (<= (timestamp-value (notification-sent-at n)) (timestamp-value end))))
           notifications))

;; =============================================================================
;; Preference analytics
;; =============================================================================

(defn channel-opt-in-count [(prefs : Any) (channel : String)] : Long
  (count (filterv (fn [p] (and (= (preference-channel p) channel)
                               (preference-enabled p)))
                  prefs)))

(defn channel-opt-out-count [(prefs : Any) (channel : String)] : Long
  (count (filterv (fn [p] (and (= (preference-channel p) channel)
                               (not (preference-enabled p))))
                  prefs)))

(defn unique-channels [(prefs : Any)] : Any
  (distinct (mapv preference-channel prefs)))

(defn preference-summary [(prefs : Any)] : Any
  (let [channels (unique-channels prefs)]
    (reduce (fn [acc ch]
              (assoc acc ch (channel-opt-in-count prefs ch)))
            {} channels)))

;; =============================================================================
;; Formatting
;; =============================================================================

(defn notification-summary [(n : Notification)] : String
  (str "Notification #" (notificationid-value (notification-id n))
       " | Template: " (templateid-value (notification-template-id n))
       " | Customer: " (customerid-value (notification-customer-id n))
       " | " (notification-reference-type n)
       " #" (notification-reference-id n)
       " | " (notification-status n)))

(defn template-summary [(t : Template)] : String
  (str "Template #" (templateid-value (template-id t))
       " | " (template-name t)
       " | Channel: " (template-channel t)
       " | Subject: " (template-subject t)))

(defn notification-detail [(n : Notification)] : String
  (str "Notification #" (notificationid-value (notification-id n))
       " | Template: " (templateid-value (notification-template-id n))
       " | Customer: " (customerid-value (notification-customer-id n))
       " | Ref: " (notification-reference-type n) "#"
       (notification-reference-id n)
       " | Status: " (notification-status n)
       " | Created: " (timestamp-value (notification-created-at n))
       " | Sent: " (timestamp-value (notification-sent-at n))))

;; =============================================================================
;; Customer notification history
;; =============================================================================

(defn customer-recent-notifications [(notifications : Any)
                                     (customer-id : cust/CustomerId)
                                     (n : Long)] : Any
  (let [cust-notifs (notifications-for-customer notifications customer-id)
        sorted (reverse (sort-by (fn [x] (timestamp-value (notification-created-at x))) cust-notifs))]
    (vec (take n sorted))))

(defn customer-notification-summary [(notifications : Any)
                                     (customer-id : cust/CustomerId)] : Any
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

(defn order-notifications [(notifications : Any) (order-id : ord/OrderId)] : Any
  (notifications-for-reference notifications (orderid-value order-id) "order"))

(defn shipment-notifications [(notifications : Any)
                              (shipment-id : ship/ShipmentId)] : Any
  (notifications-for-reference notifications (shipmentid-value shipment-id) "shipment"))

(defn invoice-notifications [(notifications : Any)
                             (invoice-id : billing/InvoiceId)] : Any
  (notifications-for-reference notifications (invoiceid-value invoice-id) "invoice"))

;; =============================================================================
;; Failed notification diagnostics
;; =============================================================================

(defn failed-notifications [(notifications : Any)] : Any
  (notifications-by-status notifications "failed"))

(defn failed-for-customer [(notifications : Any)
                           (customer-id : cust/CustomerId)] : Any
  (filterv (fn [n] (and (= (customerid-value (notification-customer-id n)) (customerid-value customer-id))
                        (= (notification-status n) "failed")))
           notifications))

(defn failure-rate-pct [(notifications : Any)] : Long
  (let [total (count notifications)]
    (if (= total 0) 0
        (quot (* (notifications-failed-count notifications) 100) total))))

;; =============================================================================
;; Notification throughput analytics
;; =============================================================================

(defn fastest-notification [(notifications : Any)] : Any
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)]
    (if (empty? sent)
        nil
        (reduce (fn [best n]
                  (let [best-time (- (timestamp-value (notification-sent-at best))
                                     (timestamp-value (notification-created-at best)))
                        n-time (- (timestamp-value (notification-sent-at n))
                                  (timestamp-value (notification-created-at n)))]
                    (if (< n-time best-time) n best)))
                (first sent)
                (rest sent)))))

(defn slowest-notification [(notifications : Any)] : Any
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)]
    (if (empty? sent)
        nil
        (reduce (fn [worst n]
                  (let [worst-time (- (timestamp-value (notification-sent-at worst))
                                      (timestamp-value (notification-created-at worst)))
                        n-time (- (timestamp-value (notification-sent-at n))
                                  (timestamp-value (notification-created-at n)))]
                    (if (> n-time worst-time) n worst)))
                (first sent)
                (rest sent)))))

;; =============================================================================
;; Notification dashboard
;; =============================================================================

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

(defn notifications-by-channel [(notifications : Any)
                                (templates : Any)] : Any
  (let [channels (distinct (mapv template-channel templates))]
    (reduce (fn [acc ch]
              (let [ch-tmpl-ids (mapv (fn [t] (templateid-value (template-id t)))
                                     (templates-for-channel templates ch))
                    cnt (count (filterv
                                 (fn [n]
                                   (some (fn [tid]
                                           (= (templateid-value (notification-template-id n)) tid))
                                         ch-tmpl-ids))
                                 notifications))]
                (assoc acc ch cnt)))
            {} channels)))

(defn channel-sent-count [(notifications : Any) (templates : Any)
                          (channel : String)] : Long
  (let [ch-tmpl-ids (mapv (fn [t] (templateid-value (template-id t)))
                          (templates-for-channel templates channel))
        ch-sent (filterv (fn [n]
                           (and (= (notification-status n) "sent")
                                (some (fn [tid]
                                        (= (templateid-value (notification-template-id n)) tid))
                                      ch-tmpl-ids)))
                         notifications)]
    (count ch-sent)))

(defn channel-failed-count [(notifications : Any) (templates : Any)
                            (channel : String)] : Long
  (let [ch-tmpl-ids (mapv (fn [t] (templateid-value (template-id t)))
                          (templates-for-channel templates channel))
        ch-failed (filterv (fn [n]
                             (and (= (notification-status n) "failed")
                                  (some (fn [tid]
                                          (= (templateid-value (notification-template-id n)) tid))
                                        ch-tmpl-ids)))
                           notifications)]
    (count ch-failed)))

;; =============================================================================
;; Reference type analytics
;; =============================================================================

(defn reference-type-counts [(notifications : Any)] : Any
  (let [order-cnt (count (notifications-by-reference-type notifications "order"))
        shipment-cnt (count (notifications-by-reference-type notifications "shipment"))
        invoice-cnt (count (notifications-by-reference-type notifications "invoice"))]
    {:order order-cnt
     :shipment shipment-cnt
     :invoice invoice-cnt}))

(defn reference-type-delivery-rate [(notifications : Any)
                                    (ref-type : String)] : Long
  (delivery-rate-pct (notifications-by-reference-type notifications ref-type)))

;; =============================================================================
;; Notification age analytics
;; =============================================================================

(defn notification-age [(n : Notification) (now : ord/Timestamp)] : Long
  (- (timestamp-value now) (timestamp-value (notification-created-at n))))

(defn notification-age-days [(n : Notification) (now : ord/Timestamp)] : Long
  (quot (notification-age n now) 86400))

(defn stale-pending [(notifications : Any) (now : ord/Timestamp)
                     (threshold-days : Long)] : Any
  (let [max-seconds (* threshold-days 86400)]
    (filterv (fn [n] (and (= (notification-status n) "pending")
                          (< (- (timestamp-value now) (timestamp-value (notification-created-at n))) max-seconds)))
             notifications)))

;; =============================================================================
;; Comprehensive notification report
;; =============================================================================

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

(defn disable-channel [(prefs : Any) (customer-id : cust/CustomerId)
                       (channel : String)] : Any
  (set-preference prefs customer-id channel false))

(defn enable-channel [(prefs : Any) (customer-id : cust/CustomerId)
                      (channel : String)] : Any
  (set-preference prefs customer-id channel true))

(defn customer-enabled-channels [(prefs : Any)
                                 (customer-id : cust/CustomerId)] : Any
  (let [cust-prefs (customer-preferences prefs customer-id)]
    (mapv preference-channel
          (filterv (fn [p] (preference-enabled p)) cust-prefs))))

(defn customer-disabled-channels [(prefs : Any)
                                  (customer-id : cust/CustomerId)] : Any
  (let [cust-prefs (customer-preferences prefs customer-id)]
    (mapv preference-channel
          (filterv (fn [p] (not (preference-enabled p))) cust-prefs))))

(defn customer-has-preferences? [(prefs : Any)
                                 (customer-id : cust/CustomerId)] : Boolean
  (> (count (customer-preferences prefs customer-id)) 0))

;; =============================================================================
;; Notification batch creation (cross-module)
;; =============================================================================

(defn notify-all-for-order [(next-id : NotificationId) (template : Any)
                            (order : Any) (customers : Any)
                            (prefs : Any) (created-at : ord/Timestamp)] : Any
  (let [eligible (filterv (fn [c] (should-notify? prefs c template))
                          customers)]
    (mapv (fn [c]
            (let [idx (count (filterv (fn [c2]
                                        (< (customerid-value (cust/customer-id c2))
                                           (customerid-value (cust/customer-id c))))
                                      eligible))]
              (order-notification (->NotificationId (+ (notificationid-value next-id) idx))
                                 template order c created-at)))
          eligible)))

;; =============================================================================
;; Notification enrichment
;; =============================================================================

(defn notification-with-template-info [(n : Notification)
                                       (templates : Any)] : Any
  (let [tmpl (find-template-by-id templates (notification-template-id n))
        tmpl-name (if (nil? tmpl) "unknown" (template-name tmpl))
        tmpl-channel (if (nil? tmpl) "unknown" (template-channel tmpl))
        tmpl-subject (if (nil? tmpl) "" (template-subject tmpl))]
    {:notification-id (notificationid-value (notification-id n))
     :customer-id (customerid-value (notification-customer-id n))
     :reference-type (notification-reference-type n)
     :reference-id (notification-reference-id n)
     :status (notification-status n)
     :created-at (timestamp-value (notification-created-at n))
     :sent-at (timestamp-value (notification-sent-at n))
     :template-name tmpl-name
     :channel tmpl-channel
     :subject tmpl-subject}))

(defn enriched-notification-list [(notifications : Any)
                                  (templates : Any)] : Any
  (mapv (fn [n] (notification-with-template-info n templates))
        notifications))

;; =============================================================================
;; Notification deduplication
;; =============================================================================

(defn has-existing-notification? [(notifications : Any)
                                  (customer-id : cust/CustomerId)
                                  (reference-id : Long)
                                  (reference-type : String)] : Boolean
  (let [matches (filterv (fn [n]
                           (and (= (customerid-value (notification-customer-id n)) (customerid-value customer-id))
                                (= (notification-reference-id n) reference-id)
                                (= (notification-reference-type n) reference-type)))
                         notifications)]
    (> (count matches) 0)))

(defn duplicate-notifications [(notifications : Any)] : Any
  (filterv (fn [n]
             (let [matches (filterv (fn [other]
                                      (and (not= (notificationid-value (notification-id other))
                                                 (notificationid-value (notification-id n)))
                                           (= (customerid-value (notification-customer-id other))
                                              (customerid-value (notification-customer-id n)))
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

(defn customer-engagement-score [(notifications : Any)
                                 (customer-id : cust/CustomerId)] : Long
  (let [cust-notifs (notifications-for-customer notifications customer-id)
        sent-cnt (count (filterv (fn [n] (= (notification-status n) "sent"))
                                 cust-notifs))
        failed-cnt (count (filterv (fn [n] (= (notification-status n) "failed"))
                                   cust-notifs))
        pending-cnt (count (filterv (fn [n] (= (notification-status n) "pending"))
                                    cust-notifs))]
    (+ (* sent-cnt 10) (* pending-cnt 2) (- 0 (* failed-cnt 5)))))

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

(defn avg-daily-notification-volume [(notifications : Any) (start : ord/Timestamp)
                                     (end : ord/Timestamp)] : Long
  (let [period-notifs (notifications-in-period notifications start end)
        days (quot (- (timestamp-value end) (timestamp-value start)) 86400)]
    (if (<= days 0) (count period-notifs)
        (quot (count period-notifs) days))))

(defn notifications-created-before [(notifications : Any)
                                    (ts : ord/Timestamp)] : Any
  (filterv (fn [n] (< (timestamp-value (notification-created-at n)) (timestamp-value ts))) notifications))

(defn notifications-created-after [(notifications : Any)
                                   (ts : ord/Timestamp)] : Any
  (filterv (fn [n] (> (timestamp-value (notification-created-at n)) (timestamp-value ts))) notifications))

;; =============================================================================
;; Template management
;; =============================================================================

(defn template-channels [(templates : Any)] : Any
  (distinct (mapv template-channel templates)))

(defn templates-by-channel-summary [(templates : Any)] : Any
  (let [channels (template-channels templates)]
    (reduce (fn [acc ch]
              (assoc acc ch (count (templates-for-channel templates ch))))
            {} channels)))

(defn find-template-by-channel-and-name [(templates : Any) (channel : String)
                                         (name : String)] : Any
  (first (filterv (fn [t] (and (= (template-channel t) channel)
                               (= (template-name t) name)))
                  templates)))

;; =============================================================================
;; Cross-module notification summaries
;; =============================================================================

(defn order-notification-status [(notifications : Any)
                                 (order-id : ord/OrderId)] : String
  (let [order-notifs (order-notifications notifications order-id)]
    (if (empty? order-notifs)
        "none"
        (let [sorted (reverse (sort-by (fn [x] (timestamp-value (notification-created-at x))) order-notifs))]
          (notification-status (first sorted))))))

(defn shipment-notification-status [(notifications : Any)
                                    (shipment-id : ship/ShipmentId)] : String
  (let [ship-notifs (shipment-notifications notifications shipment-id)]
    (if (empty? ship-notifs)
        "none"
        (let [sorted (reverse (sort-by (fn [x] (timestamp-value (notification-created-at x))) ship-notifs))]
          (notification-status (first sorted))))))

(defn invoice-notification-status [(notifications : Any)
                                   (invoice-id : billing/InvoiceId)] : String
  (let [inv-notifs (invoice-notifications notifications invoice-id)]
    (if (empty? inv-notifs)
        "none"
        (let [sorted (reverse (sort-by (fn [x] (timestamp-value (notification-created-at x))) inv-notifs))]
          (notification-status (first sorted))))))

;; =============================================================================
;; Notification retry analytics
;; =============================================================================

(defn retryable-notifications [(notifications : Any)] : Any
  (failed-notifications notifications))

(defn retry-count-needed [(notifications : Any)] : Long
  (count (retryable-notifications notifications)))

(defn retry-count-for-customer [(notifications : Any)
                                (customer-id : cust/CustomerId)] : Long
  (count (failed-for-customer notifications customer-id)))

;; =============================================================================
;; Notification SLA tracking
;; =============================================================================

(defn within-sla? [(n : Notification) (max-seconds : Long)] : Boolean
  (if (= (notification-status n) "sent")
      (<= (- (timestamp-value (notification-sent-at n))
             (timestamp-value (notification-created-at n)))
          max-seconds)
      false))

(defn sla-compliance-rate [(notifications : Any)
                           (max-seconds : Long)] : Long
  (let [sent (filterv (fn [n] (= (notification-status n) "sent"))
                      notifications)
        cnt (count sent)]
    (if (= cnt 0) 100
        (let [compliant (count (filterv (fn [n] (within-sla? n max-seconds))
                                        sent))]
          (quot (* compliant 100) cnt)))))

(defn sla-breaches [(notifications : Any) (max-seconds : Long)] : Any
  (filterv (fn [n] (and (= (notification-status n) "sent")
                        (not (within-sla? n max-seconds))))
           notifications))

;; =============================================================================
;; Comprehensive customer notification report
;; =============================================================================

(defn customer-notification-report [(notifications : Any)
                                    (templates : Any)
                                    (prefs : Any)
                                    (customer-id : cust/CustomerId)] : Any
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
    {:customer-id (customerid-value customer-id)
     :total-notifications total
     :sent sent-cnt
     :failed failed-cnt
     :pending pending-cnt
     :delivery-rate del-rate
     :avg-send-time avg-time
     :engagement-score engagement
     :preference-count (count cust-prefs)
     :enabled-channels enabled-channels}))
