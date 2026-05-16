(ns verify.behavioral
  (:require [clojure.string :as str]))

;; ============================================================
;; E5e Behavioral Test Suite
;;
;; Tests the BEHAVIOR that each of the 40 injected bugs breaks.
;; Designed to score "correct but different" fixes fairly: checks
;; observable outcomes, not implementation details.
;;
;; Usage:
;;   clj -Sdeps '{:paths ["<trial-dir-parent>"]}' -M verify/behavioral.verify.clj
;;
;; The classpath must contain a `pipeline/` directory with all 8 .clj files.
;; ============================================================

;; --- Bootstrap: make record classes available as vars ---
;; defrecord creates Java classes but not namespace vars. Other modules
;; reference them as e/OrderPlaced which requires vars to exist.
;; Beagle and Clojure tracks may define records in different namespaces,
;; so we try each class name and skip silently if not found.

(require '[pipeline.events])

(doseq [sym '[OrderItem OrderPlaced OrderConfirmed PaymentReceived PaymentFailed
              ItemShipped OrderDelivered OrderCancelled InventoryReserved
              InventoryReleased CustomerRegistered CustomerTierChanged
              RefundIssued NotificationSent OrderState CustomerState
              InventoryState ShipmentState PaymentState Projections
              EventStore]]
  (try
    (let [cls (Class/forName (str "pipeline.events." (name sym)))]
      (intern 'pipeline.events sym cls))
    (catch ClassNotFoundException _ nil)))

;; Now require modules one by one — track which loaded successfully.
;; Modules with compile errors fail to load; their tests auto-fail.
(def ^:dynamic *loaded-modules* (atom #{}))

(require '[pipeline.events :as e])
(swap! *loaded-modules* conj :events)

(doseq [[mod-key mod-sym]
        [[:projections 'pipeline.projections]
         [:commands    'pipeline.commands]
         [:handlers   'pipeline.handlers]
         [:pipeline   'pipeline.pipeline]
         [:notifications 'pipeline.notifications]
         [:analytics  'pipeline.analytics]
         [:queries    'pipeline.queries]]]
  (try
    (require mod-sym)
    (swap! *loaded-modules* conj mod-key)
    (catch Exception ex
      (println (str "LOAD FAILED: " (name mod-key) " — " (.getMessage ex))))))

;; Create aliases for loaded modules (nil for unloaded)
(when (@*loaded-modules* :projections)   (require '[pipeline.projections :as proj]))
(when (@*loaded-modules* :commands)      (require '[pipeline.commands :as cmd]))
(when (@*loaded-modules* :handlers)      (require '[pipeline.handlers :as hdl]))
(when (@*loaded-modules* :pipeline)      (require '[pipeline.pipeline :as pipe]))
(when (@*loaded-modules* :notifications) (require '[pipeline.notifications :as notif]))
(when (@*loaded-modules* :analytics)     (require '[pipeline.analytics :as analytics]))
(when (@*loaded-modules* :queries)       (require '[pipeline.queries :as qry]))

;; Intern records from pipeline.pipeline (EventStore may live here or in events)
(doseq [sym '[EventStore Command]]
  (try
    (let [cls (Class/forName (str "pipeline.pipeline." (name sym)))]
      (intern 'pipeline.pipeline sym cls))
    (catch ClassNotFoundException _ nil)))

;; --- Track adapter ---
;; Load adapter based on system property set by scoring script.
;; Adapters map track-specific function names to the canonical behavioral API.
(when-let [adapter-path (System/getProperty "e5.adapter")]
  (load-file adapter-path))

;; --- Test infrastructure -----------------------------------------------

(def ^:dynamic *results* (atom []))

(defmacro bug-test
  "Runs a test for a specific bug. Catches exceptions as failures."
  [bug-id description & body]
  `(try
     (let [passed# (do ~@body)]
       (swap! *results* conj {:bug ~bug-id :desc ~description
                              :pass (boolean passed#)
                              :error nil}))
     (catch Exception ex#
       (swap! *results* conj {:bug ~bug-id :desc ~description
                              :pass false
                              :error (.getMessage ex#)}))))

(defmacro bug-test-requires
  "Like bug-test but auto-fails if required modules aren't loaded."
  [bug-id description modules & body]
  `(if (every? @*loaded-modules* ~modules)
     (bug-test ~bug-id ~description ~@body)
     (swap! *results* conj {:bug ~bug-id :desc ~description
                            :pass false
                            :error (str "module not loaded: "
                                        (first (remove @*loaded-modules* ~modules)))})))

;; ============================================================
;; BUG-01: events — OrderItem constructor arg order
;; product-name and item-id swapped
;; ============================================================

(bug-test "BUG-01" "OrderItem fields are correctly typed (item-id Long, product-name String)"
  (let [item (e/->OrderItem 42 "Widget" 3 1500)]
    (and (= 42 (:item-id item))
         (= "Widget" (:product-name item))
         (integer? (:item-id item))
         (string? (:product-name item)))))

;; ============================================================
;; BUG-02: events — OrderState make — status/customer-id swapped
;; ============================================================

(bug-test "BUG-02" "make-order-state puts customer-id (Long) and status (String) correctly"
  (let [state (e/make-order-state 1 200 "placed" [] 5000 999000)]
    (and (= 200 (:customer-id state))
         (= "placed" (:status state))
         (integer? (:customer-id state))
         (string? (:status state)))))

;; ============================================================
;; BUG-03: projections — wrong field :name instead of :placed-at
;; ============================================================

(bug-test "BUG-03" "OrderState preserves placed-at timestamp from OrderPlaced event"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        state (proj/apply-order-event nil placed)]
    (= 1000000 (:placed-at state))))

;; ============================================================
;; BUG-04: projections — wrong field :transaction-id instead of :confirmed-at
;; ============================================================

(bug-test "BUG-04" "confirmed-at is correctly set from OrderConfirmed event"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        confirmed (e/->OrderConfirmed 100 1001000)
        s1 (proj/apply-order-event nil placed)
        s2 (proj/apply-order-event s1 confirmed)]
    (= 1001000 (:confirmed-at s2))))

;; ============================================================
;; BUG-05: projections — wrong field :order-id instead of :tracking-number
;; ============================================================

(bug-test "BUG-05" "ShipmentState tracking-number is set from ItemShipped event"
  (let [shipped (e/->ItemShipped 100 1 "TRK-ABC" "UPS" 1003000)
        state (proj/apply-shipment-event nil shipped)]
    (= "TRK-ABC" (:tracking-number state))))

;; ============================================================
;; BUG-06: projections — order-status uses cancelled-at in arithmetic (nil crash)
;; ============================================================

(bug-test "BUG-06" "order-status works on non-cancelled order (cancelled-at is nil)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        state (proj/apply-order-event nil placed)]
    (= "placed" (proj/order-status state))))

;; ============================================================
;; BUG-07: projections — transaction-id nil passed to subs
;; ============================================================

(bug-test "BUG-07" "PaymentFailed applied to payment state does not crash (nil transaction-id)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        paid-evt (e/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
        failed-evt (e/->PaymentFailed 100 "declined" 1003000)
        ps1 (proj/apply-payment-event nil paid-evt)
        ps2 (proj/apply-payment-event ps1 failed-evt)]
    (= "failed" (:status ps2))))

;; ============================================================
;; BUG-08: projections — missing OrderCancelled match case
;; ============================================================

(bug-test "BUG-08" "apply-order-event handles OrderCancelled (status becomes cancelled)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        cancelled (e/->OrderCancelled 100 "out of stock" 1005000)
        s1 (proj/apply-order-event nil placed)
        s2 (proj/apply-order-event s1 cancelled)]
    (and (= "cancelled" (:status s2))
         (= "out of stock" (:cancel-reason s2))
         (= 1005000 (:cancelled-at s2)))))

;; ============================================================
;; BUG-09: projections — missing CustomerTierChanged match case
;; ============================================================

(bug-test "BUG-09" "apply-customer-event handles CustomerTierChanged"
  (let [reg (e/->CustomerRegistered 200 "Alice" "alice@example.com" 999000)
        tier-change (e/->CustomerTierChanged 200 "bronze" "silver" 1100000)
        s1 (proj/apply-customer-event nil reg)
        s2 (proj/apply-customer-event s1 tier-change)]
    (= "silver" (:tier s2))))

;; ============================================================
;; BUG-10: projections — missing RefundIssued in payment projection
;; ============================================================

(bug-test "BUG-10" "apply-payment-event handles RefundIssued (reduces amount-paid)"
  (let [paid-evt (e/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
        refund-evt (e/->RefundIssued 100 5000 "full-refund" 1006000)
        ps1 (proj/apply-payment-event nil paid-evt)
        ps2 (proj/apply-payment-event ps1 refund-evt)]
    (and (= 0 (:amount-paid ps2))
         (= "refunded" (:status ps2)))))

;; ============================================================
;; BUG-11: commands — paid-amount nil used directly in arithmetic
;; ============================================================

(bug-test "BUG-11" "receive-payment works on confirmed order (paid-amount initially nil/0)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        confirmed (e/->OrderConfirmed 100 1001000)
        s1 (proj/apply-order-event nil placed)
        s2 (proj/apply-order-event s1 confirmed)
        e (cmd/receive-payment s2 5000 "credit-card" "txn-1" 1002000)]
    (and (instance? pipeline.events.PaymentReceived e)
         (= 5000 (:amount e)))))

;; ============================================================
;; BUG-12: commands — confirmed-at nil in arithmetic
;; ============================================================

(bug-test "BUG-12" "confirm-order works on placed order (confirmed-at initially nil)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        s1 (proj/apply-order-event nil placed)
        e (cmd/confirm-order s1 1001000)]
    (and (instance? pipeline.events.OrderConfirmed e)
         (= 100 (:order-id e))
         (= 1001000 (:confirmed-at e)))))

;; ============================================================
;; BUG-13: commands — make-inventory-released arity (3 args instead of 4)
;; ============================================================

(bug-test "BUG-13" "release-inventory produces InventoryReleased with all 4 fields"
  (let [inv-state (e/->InventoryState 1 10 95 5)
        e (cmd/release-inventory inv-state 100 1 3 "cancelled")]
    (and (instance? pipeline.events.InventoryReleased e)
         (= 100 (:order-id e))
         (= 1 (:item-id e))
         (= 3 (:quantity e))
         (= "cancelled" (:reason e)))))

;; ============================================================
;; BUG-14: commands — make-item-shipped arity (6 args instead of 5)
;; ============================================================

(bug-test "BUG-14" "ship-item produces ItemShipped with correct fields"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        confirmed (e/->OrderConfirmed 100 1001000)
        paid (e/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
        s1 (proj/apply-order-event nil placed)
        s2 (proj/apply-order-event s1 confirmed)
        s3 (proj/apply-order-event s2 paid)
        e (cmd/ship-item s3 1 "TRK-X" "FedEx" 1003000)]
    (and (instance? pipeline.events.ItemShipped e)
         (= 100 (:order-id e))
         (= 1 (:item-id e))
         (= "TRK-X" (:tracking-number e))
         (= "FedEx" (:carrier e))
         (= 1003000 (:shipped-at e)))))

;; ============================================================
;; BUG-15: commands — customer-id (Long) passed as name (String)
;; ============================================================

(bug-test "BUG-15" "register-customer produces event with correct name (String)"
  (let [e (cmd/register-customer 200 "Bob" "bob@example.com" 1000000)]
    (and (instance? pipeline.events.CustomerRegistered e)
         (= "Bob" (:name e))
         (string? (:name e))
         (= "bob@example.com" (:email e)))))

;; ============================================================
;; BUG-16: commands — comparing amount (Long) to String "0"
;; ============================================================

(bug-test "BUG-16" "issue-refund validates amount correctly (Long comparison)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        paid (e/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
        os (proj/apply-order-event nil placed)
        ps (proj/apply-payment-event nil paid)
        e (cmd/issue-refund os ps 3000 "partial" 1006000)]
    (and (instance? pipeline.events.RefundIssued e)
         (= 3000 (:amount e)))))

;; ============================================================
;; BUG-17: handlers — :placed-at instead of :customer-id in handle-order-placed
;; ============================================================

(bug-test "BUG-17" "handle-order-placed looks up customer by customer-id (not placed-at)"
  (let [item (e/->OrderItem 1 "Widget" 2 1500)
        placed (e/->OrderPlaced 100 200 [item] 3000 1000000)
        customer (proj/apply-customer-event nil
                   (e/->CustomerRegistered 200 "Alice" "alice@test.com" 900000))
        projections {:lookup-customer (fn [cid] (when (= cid 200) customer))
                     :lookup-order (fn [_] nil)
                     :lookup-inventory (fn [_ _] (e/->InventoryState 1 1 100 0))
                     :lookup-payment (fn [_] nil)}
        results (hdl/handle-order-placed placed projections)
        notif (last results)]
    (and (instance? pipeline.events.NotificationSent notif)
         (= "alice@test.com" (:recipient notif)))))

;; ============================================================
;; BUG-18: handlers — :cancelled-at instead of :reason in handle-order-cancelled
;; ============================================================

(bug-test "BUG-18" "handle-order-cancelled uses reason (String) for refund, not cancelled-at (Long)"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 2 1500)] 3000 1000000)
        paid-evt (e/->PaymentReceived 100 3000 "credit-card" "txn-1" 1002000)
        cancelled (e/->OrderCancelled 100 "changed mind" 1005000)
        os (-> nil
               (proj/apply-order-event placed)
               (proj/apply-order-event paid-evt))
        ps (proj/apply-payment-event nil paid-evt)
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 900000))
        projections {:lookup-order (fn [_] os)
                     :lookup-customer (fn [_] cs)
                     :lookup-payment (fn [_] ps)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-order-cancelled cancelled projections)
        refund (first (filter #(instance? pipeline.events.RefundIssued %) results))]
    (and (some? refund)
         (string? (:reason refund))
         (str/includes? (:reason refund) "changed mind"))))

;; ============================================================
;; BUG-19: handlers — :amount instead of :refunded-at in handle-refund-issued
;; ============================================================

(bug-test "BUG-19" "handle-refund-issued uses refunded-at as notification timestamp"
  (let [refund-evt (e/->RefundIssued 100 2000 "partial" 1006000)
        os (proj/apply-order-event nil
             (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000))
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 900000))
        projections {:lookup-order (fn [_] os)
                     :lookup-customer (fn [_] cs)
                     :lookup-payment (fn [_] nil)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-refund-issued refund-evt projections)
        notif (first (filter #(instance? pipeline.events.NotificationSent %) results))]
    (and (some? notif)
         (= 1006000 (:sent-at notif))
         (integer? (:sent-at notif)))))

;; ============================================================
;; BUG-20: handlers — determine-new-tier called with 2 args instead of 1
;; ============================================================

(bug-test "BUG-20" "handle-payment-received triggers tier upgrade when threshold met"
  (let [paid-evt (e/->PaymentReceived 100 500 "credit-card" "txn-1" 1002000)
        ;; Customer with 5100 spent (already above gold threshold but still silver)
        ;; eligible-for-upgrade? checks: silver + spent >= 5000 → true
        ;; determine-new-tier(5100 + 500 = 5600) → "gold"
        cs (e/->CustomerState 200 "Alice" "a@b.com" "silver" 5100 6 900000)
        os (e/make-order-state 100 200 "confirmed" [(e/->OrderItem 1 "A" 1 500)] 500 1000000)
        projections {:lookup-order (fn [_] os)
                     :lookup-customer (fn [_] cs)
                     :lookup-payment (fn [_] nil)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-payment-received paid-evt projections)
        tier-change (first (filter #(instance? pipeline.events.CustomerTierChanged %) results))]
    (and (some? tier-change)
         (= "gold" (:new-tier tier-change)))))

;; ============================================================
;; BUG-21: handlers — make-notification-sent called with 5 args instead of 4
;; ============================================================

(bug-test "BUG-21" "handler notification events have exactly 4 fields (no extra args)"
  (let [item (e/->OrderItem 1 "Widget" 2 1500)
        placed (e/->OrderPlaced 100 200 [item] 3000 1000000)
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 900000))
        projections {:lookup-customer (fn [_] cs)
                     :lookup-order (fn [_] nil)
                     :lookup-inventory (fn [_ _] (e/->InventoryState 1 1 100 0))
                     :lookup-payment (fn [_] nil)}
        results (hdl/handle-order-placed placed projections)
        notif (first (filter #(instance? pipeline.events.NotificationSent %) results))]
    (and (some? notif)
         (string? (:recipient notif))
         (string? (:channel notif))
         (string? (:template notif))
         (integer? (:sent-at notif)))))

;; ============================================================
;; BUG-22: handlers — Long (order-id) where String template expected
;; ============================================================

(bug-test "BUG-22" "handler notifications have String template names"
  (let [shipped (e/->ItemShipped 100 1 "TRK-1" "UPS" 1003000)
        os (-> nil
               (proj/apply-order-event (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000))
               (proj/apply-order-event (e/->PaymentReceived 100 5000 "cc" "t" 1002000)))
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 900000))
        projections {:lookup-order (fn [_] os)
                     :lookup-customer (fn [_] cs)
                     :lookup-payment (fn [_] nil)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-item-shipped shipped projections)
        notifs (filter #(instance? pipeline.events.NotificationSent %) results)]
    (every? #(string? (:template %)) notifs)))

;; ============================================================
;; BUG-23: handlers — CustomerRegistered missing from dispatcher
;; ============================================================

(bug-test "BUG-23" "handle-event dispatches CustomerRegistered (produces welcome notification)"
  (let [reg (e/->CustomerRegistered 200 "Alice" "alice@example.com" 999000)
        projections {:lookup-order (fn [_] nil)
                     :lookup-customer (fn [_] nil)
                     :lookup-payment (fn [_] nil)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-event reg projections [])]
    (and (pos? (count results))
         (some #(and (instance? pipeline.events.NotificationSent %)
                     (= "welcome" (:template %)))
               results))))

;; ============================================================
;; BUG-24: handlers — OrderDelivered missing from dispatcher
;; ============================================================

(bug-test "BUG-24" "handle-event dispatches OrderDelivered (produces delivery notification)"
  (let [delivered (e/->OrderDelivered 100 1004000)
        os (-> nil
               (proj/apply-order-event (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000))
               (proj/apply-order-event (e/->ItemShipped 100 1 "TRK" "UPS" 1003000)))
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 900000))
        projections {:lookup-order (fn [_] os)
                     :lookup-customer (fn [_] cs)
                     :lookup-payment (fn [_] nil)
                     :lookup-inventory (fn [_ _] nil)}
        results (hdl/handle-event delivered projections [])]
    (and (pos? (count results))
         (some #(and (instance? pipeline.events.NotificationSent %)
                     (= "push" (:channel %)))
               results))))

;; ============================================================
;; BUG-25: queries — :order-count instead of :total-spent in top-customers
;; ============================================================

(bug-test "BUG-25" "top-customers sorts by total-spent (not order-count)"
  (let [c1 (e/->CustomerState 1 "LowSpend" "a@b.com" "bronze" 100 10 900000)
        c2 (e/->CustomerState 2 "HighSpend" "b@b.com" "gold" 9000 2 900000)
        top (qry/top-customers 1 [c1 c2])]
    (= 2 (:customer-id (first top)))))

;; ============================================================
;; BUG-26: queries — :tracking-number instead of :carrier in shipment-by-carrier
;; ============================================================

(bug-test "BUG-26" "shipment-by-carrier groups by carrier field"
  (let [s1 (e/->ShipmentState 100 1 "TRK-1" "UPS" 1000000 nil)
        s2 (e/->ShipmentState 101 2 "TRK-2" "FedEx" 1001000 nil)
        s3 (e/->ShipmentState 102 3 "TRK-3" "UPS" 1002000 nil)
        result (qry/shipment-by-carrier [s1 s2 s3])]
    (and (= 2 (get result "UPS"))
         (= 1 (get result "FedEx")))))

;; ============================================================
;; BUG-27: queries — delivered-at nil in arithmetic (NPE in fulfillment-time)
;; ============================================================

(bug-test "BUG-27" "fulfillment-time returns nil (not crash) for undelivered order"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        os (proj/apply-order-event nil placed)]
    (nil? (qry/fulfillment-time os))))

;; ============================================================
;; BUG-28: queries — subtracting instead of adding in average-order-value
;; ============================================================

(bug-test "BUG-28" "average-order-value returns correct positive value"
  (let [os1 (e/make-order-state 1 200 "placed" [(e/->OrderItem 1 "A" 1 3000)] 3000 1000000)
        os2 (e/make-order-state 2 200 "placed" [(e/->OrderItem 2 "B" 1 7000)] 7000 1000000)]
    (= 5000 (qry/average-order-value [os1 os2]))))

;; ============================================================
;; BUG-29: queries — summing cancelled orders instead of non-cancelled
;; ============================================================

(bug-test "BUG-29" "total-revenue excludes cancelled orders"
  (let [os1 (e/make-order-state 1 200 "paid" [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        os2 (assoc (e/make-order-state 2 200 "cancelled" [(e/->OrderItem 2 "B" 1 3000)] 3000 1000000)
                   :cancelled-at 1001000 :cancel-reason "test")
        result (qry/total-revenue [os1 os2])]
    (= 5000 result)))

;; ============================================================
;; BUG-30: pipeline — append-event arity (3 args instead of 2)
;; ============================================================

(bug-test "BUG-30" "append-event takes store+event and works correctly"
  (let [store (pipe/empty-store)
        evt (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        store2 (pipe/append-event store evt)]
    (and (= 1 (:version store2))
         (= 1 (count (:events store2))))))

;; ============================================================
;; BUG-31: pipeline — event-count arity (2 args instead of 1)
;; ============================================================

(bug-test "BUG-31" "event-count takes 1 arg (store) and returns count"
  (let [store (pipe/empty-store)
        evt (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        store2 (pipe/append-event store evt)]
    (= 1 (pipe/event-count store2))))

;; ============================================================
;; BUG-32: pipeline — version and events swapped in EventStore
;; ============================================================

(bug-test "BUG-32" "empty-store has version 0 (Long) and events [] (vector)"
  (let [store (pipe/empty-store)]
    (and (= 0 (:version store))
         (integer? (:version store))
         (vector? (:events store))
         (empty? (:events store)))))

;; ============================================================
;; BUG-33: pipeline — String where events vector expected in rebuild
;; ============================================================

(bug-test "BUG-33" "append-events stores actual event objects (not strings)"
  (let [store (pipe/empty-store)
        evt (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        store2 (pipe/append-events store [evt])
        retrieved (first (:events store2))]
    (and (instance? pipeline.events.OrderPlaced retrieved)
         (= 100 (:order-id retrieved)))))

;; ============================================================
;; BUG-34: notifications — Long instead of String for order-id in template
;; ============================================================

(bug-test "BUG-34" "build-order-confirmation produces notification with String recipient"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        os (proj/apply-order-event nil placed)
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "alice@example.com" 999000))
        n (notif/build-order-confirmation os cs)]
    (and (instance? pipeline.events.NotificationSent n)
         (= "alice@example.com" (:recipient n))
         (string? (:recipient n)))))

;; ============================================================
;; BUG-35: notifications — Long instead of String for order-id (second builder)
;; ============================================================

(bug-test "BUG-35" "build-cancellation-notice produces valid notification"
  (let [placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        cancelled (e/->OrderCancelled 100 "out of stock" 1005000)
        os (-> nil
               (proj/apply-order-event placed)
               (proj/apply-order-event cancelled))
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "alice@test.com" 999000))
        n (notif/build-cancellation-notice os cs "out of stock")]
    (and (instance? pipeline.events.NotificationSent n)
         (= "alice@test.com" (:recipient n))
         (string? (:template n)))))

;; ============================================================
;; BUG-36: notifications — Long 0 where String recipient expected
;; ============================================================

(bug-test "BUG-36" "build-welcome-notice produces notification with email recipient"
  (let [cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Bob" "bob@example.com" 999000))
        n (notif/build-welcome-notice cs)]
    (and (instance? pipeline.events.NotificationSent n)
         (= "bob@example.com" (:recipient n))
         (string? (:recipient n)))))

;; ============================================================
;; BUG-37: notifications — wrong routing (email/sms/push swapped)
;; ============================================================

(bug-test "BUG-37" "shipping notice uses sms channel, delivery uses push"
  (let [shipped (e/->ItemShipped 100 1 "TRK-1" "FedEx" 1003000)
        ss (proj/apply-shipment-event nil shipped)
        placed (e/->OrderPlaced 100 200 [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        os (proj/apply-order-event nil placed)
        ship-notif (notif/build-shipping-notice ss os)
        cs (proj/apply-customer-event nil
             (e/->CustomerRegistered 200 "Alice" "a@b.com" 999000))
        deliver-notif (notif/build-delivery-confirmation os cs)]
    (and (= "sms" (:channel ship-notif))
         (= "push" (:channel deliver-notif)))))

;; ============================================================
;; BUG-38: analytics — >= 1 instead of > 1 (all customers counted as repeat)
;; ============================================================

(bug-test "BUG-38" "repeat-customer-rate only counts customers with >1 order"
  (let [os1 (e/make-order-state 1 200 "placed" [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
        os2 (e/make-order-state 2 200 "placed" [(e/->OrderItem 2 "B" 1 3000)] 3000 1100000)
        os3 (e/make-order-state 3 300 "placed" [(e/->OrderItem 3 "C" 1 7000)] 7000 1200000)
        ;; customer 200 has 2 orders, customer 300 has 1 → rate = 1/2 = 0.5
        rate (analytics/repeat-customer-rate [os1 os2 os3])]
    (= 0.5 rate)))

;; ============================================================
;; BUG-39: analytics — paid-at - placed-at subtracted in wrong order (negative)
;; ============================================================

(bug-test "BUG-39" "average-time-to-payment returns positive value"
  (let [os1 (assoc (e/make-order-state 1 200 "paid" [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
                   :paid-at 1100000)
        os2 (assoc (e/make-order-state 2 200 "paid" [(e/->OrderItem 2 "B" 1 3000)] 3000 2000000)
                   :paid-at 2200000)]
    (pos? (analytics/average-time-to-payment [os1 os2]))))

;; ============================================================
;; BUG-40: analytics — :status instead of :cancel-reason in cancellation-reasons
;; ============================================================

(bug-test "BUG-40" "cancellation-reasons groups by cancel-reason (not status)"
  (let [os1 (assoc (e/make-order-state 1 200 "cancelled" [(e/->OrderItem 1 "A" 1 5000)] 5000 1000000)
                   :cancelled-at 1001000 :cancel-reason "out of stock")
        os2 (assoc (e/make-order-state 2 300 "cancelled" [(e/->OrderItem 2 "B" 1 3000)] 3000 1100000)
                   :cancelled-at 1101000 :cancel-reason "customer request")
        os3 (assoc (e/make-order-state 3 400 "cancelled" [(e/->OrderItem 3 "C" 1 7000)] 7000 1200000)
                   :cancelled-at 1201000 :cancel-reason "out of stock")
        reasons (analytics/cancellation-reasons [os1 os2 os3])]
    (and (= 2 (get reasons "out of stock"))
         (= 1 (get reasons "customer request"))
         (nil? (get reasons "cancelled")))))

;; ============================================================
;; Results Summary
;; ============================================================

(println)
(println "=== E5e BEHAVIORAL TEST RESULTS ===")
(println)

(let [results @*results*
      passed (filter :pass results)
      failed (remove :pass results)]
  (doseq [r results]
    (println (str (if (:pass r) "  PASS" "  FAIL") "  " (:bug r) ": " (:desc r)
                  (when (:error r) (str " [" (:error r) "]")))))
  (println)
  (println (str "Total: " (count results) " | Passed: " (count passed)
               " | Failed: " (count failed)
               " | Score: " (if (pos? (count results))
                              (str (int (* 100.0 (/ (count passed) (count results)))) "%")
                              "N/A")))
  (println)

  ;; Machine-readable output for scoring script
  (println "--- MACHINE-READABLE ---")
  (doseq [r results]
    (println (str (:bug r) "|" (if (:pass r) "PASS" "FAIL") "|" (or (:error r) ""))))
  (println "---")

  (System/exit (if (empty? failed) 0 1)))
