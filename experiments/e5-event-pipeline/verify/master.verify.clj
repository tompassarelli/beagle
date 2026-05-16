(ns verify.master
  (:require [pipeline.events :as evt]
            [pipeline.projections :as proj]
            [pipeline.commands :as cmd]
            [pipeline.handlers :as hdl]
            [pipeline.queries :as qry]
            [pipeline.pipeline :as pipe]
            [pipeline.notifications :as notif]
            [pipeline.analytics :as analytics]))

;; --- test infrastructure ---------------------------------------------------

(def ^:dynamic *pass-count* (atom 0))
(def ^:dynamic *fail-count* (atom 0))
(def ^:dynamic *failures* (atom []))

(defmacro assert-eq [label expected actual]
  `(let [e# ~expected a# ~actual]
     (if (= e# a#)
       (swap! *pass-count* inc)
       (do (swap! *fail-count* inc)
           (swap! *failures* conj
                  {:label ~label :expected e# :actual a#})))))

(defmacro assert-true [label expr]
  `(if ~expr
     (swap! *pass-count* inc)
     (do (swap! *fail-count* inc)
         (swap! *failures* conj {:label ~label :expected true :actual false}))))

(defmacro assert-false [label expr]
  `(if (not ~expr)
     (swap! *pass-count* inc)
     (do (swap! *fail-count* inc)
         (swap! *failures* conj {:label ~label :expected false :actual true}))))

(defmacro assert-nil [label expr]
  `(let [v# ~expr]
     (if (nil? v#)
       (swap! *pass-count* inc)
       (do (swap! *fail-count* inc)
           (swap! *failures* conj {:label ~label :expected nil :actual v#})))))

(defmacro assert-not-nil [label expr]
  `(let [v# ~expr]
     (if (some? v#)
       (swap! *pass-count* inc)
       (do (swap! *fail-count* inc)
           (swap! *failures* conj {:label ~label :expected 'non-nil :actual nil})))))

(defmacro assert-throws [label & body]
  `(try ~@body
        (do (swap! *fail-count* inc)
            (swap! *failures* conj {:label ~label :expected 'exception :actual 'no-exception}))
        (catch Exception _# (swap! *pass-count* inc))))

;; --- 1. Event construction -------------------------------------------------

(println "=== Event Construction ===")

(let [item (evt/->OrderItem 1 "Widget" 3 1500)]
  (assert-eq "OrderItem item-id" 1 (:item-id item))
  (assert-eq "OrderItem product-name" "Widget" (:product-name item))
  (assert-eq "OrderItem quantity" 3 (:quantity item))
  (assert-eq "OrderItem unit-price" 1500 (:unit-price item)))

(let [e (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 2 1000)] 2000 1000000)]
  (assert-eq "OrderPlaced order-id" 100 (:order-id e))
  (assert-eq "OrderPlaced customer-id" 200 (:customer-id e))
  (assert-eq "OrderPlaced total" 2000 (:total e))
  (assert-eq "OrderPlaced placed-at" 1000000 (:placed-at e))
  (assert-eq "OrderPlaced items count" 1 (count (:items e))))

(let [e (evt/->PaymentReceived 100 2000 "credit-card" "txn-001" 1001000)]
  (assert-eq "PaymentReceived order-id" 100 (:order-id e))
  (assert-eq "PaymentReceived amount" 2000 (:amount e))
  (assert-eq "PaymentReceived method" "credit-card" (:method e))
  (assert-eq "PaymentReceived transaction-id" "txn-001" (:transaction-id e)))

(let [e (evt/->ItemShipped 100 1 "TRK-123" "FedEx" 1002000)]
  (assert-eq "ItemShipped tracking-number" "TRK-123" (:tracking-number e))
  (assert-eq "ItemShipped carrier" "FedEx" (:carrier e)))

(let [e (evt/->OrderCancelled 100 "customer request" 1003000)]
  (assert-eq "OrderCancelled reason" "customer request" (:reason e)))

(let [e (evt/->CustomerRegistered 200 "Alice" "alice@example.com" 999000)]
  (assert-eq "CustomerRegistered name" "Alice" (:name e))
  (assert-eq "CustomerRegistered email" "alice@example.com" (:email e)))

(let [e (evt/->InventoryReserved 100 1 5 10)]
  (assert-eq "InventoryReserved quantity" 5 (:quantity e))
  (assert-eq "InventoryReserved warehouse-id" 10 (:warehouse-id e)))

(let [e (evt/->RefundIssued 100 2000 "cancelled" 1004000)]
  (assert-eq "RefundIssued amount" 2000 (:amount e)))

(let [e (evt/->NotificationSent "alice@example.com" "email" "order-confirm" 1005000)]
  (assert-eq "NotificationSent channel" "email" (:channel e)))

;; --- 2. Projections --------------------------------------------------------

(println "=== Projections ===")

;; Order projection from nil state
(let [placed (evt/->OrderPlaced 100 200
               [(evt/->OrderItem 1 "Widget" 2 1500)
                (evt/->OrderItem 2 "Gadget" 1 3000)]
               6000 1000000)
      state (proj/apply-order-event nil placed)]
  (assert-eq "OrderState order-id" 100 (:order-id state))
  (assert-eq "OrderState customer-id" 200 (:customer-id state))
  (assert-eq "OrderState status" "placed" (:status state))
  (assert-eq "OrderState total" 6000 (:total state))
  (assert-eq "OrderState items count" 2 (count (:items state)))
  (assert-nil "OrderState confirmed-at initially nil" (:confirmed-at state))
  (assert-nil "OrderState paid-at initially nil" (:paid-at state))
  (assert-nil "OrderState delivered-at initially nil" (:delivered-at state))
  (assert-nil "OrderState cancelled-at initially nil" (:cancelled-at state))
  (assert-eq "OrderState shipped-count" 0 (:shipped-count state)))

;; Confirm then pay
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      confirmed (evt/->OrderConfirmed 100 1001000)
      paid (evt/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 confirmed)
      s3 (proj/apply-order-event s2 paid)]
  (assert-eq "After confirm status" "confirmed" (:status s2))
  (assert-eq "After confirm confirmed-at" 1001000 (:confirmed-at s2))
  (assert-eq "After pay status" "paid" (:status s3))
  (assert-eq "After pay paid-at" 1002000 (:paid-at s3))
  (assert-eq "After pay amount" 5000 (:paid-amount s3))
  (assert-eq "After pay method" "credit-card" (:payment-method s3)))

;; Ship and deliver
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      shipped (evt/->ItemShipped 100 1 "TRK-1" "UPS" 1003000)
      delivered (evt/->OrderDelivered 100 1004000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 shipped)
      s3 (proj/apply-order-event s2 delivered)]
  (assert-eq "After ship shipped-count" 1 (:shipped-count s2))
  (assert-eq "After deliver status" "delivered" (:status s3))
  (assert-eq "After deliver delivered-at" 1004000 (:delivered-at s3)))

;; Cancel
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      cancelled (evt/->OrderCancelled 100 "out of stock" 1005000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 cancelled)]
  (assert-eq "After cancel status" "cancelled" (:status s2))
  (assert-eq "After cancel reason" "out of stock" (:cancel-reason s2))
  (assert-eq "After cancel cancelled-at" 1005000 (:cancelled-at s2)))

;; Customer projection
(let [reg (evt/->CustomerRegistered 200 "Alice" "alice@example.com" 999000)
      state (proj/apply-customer-event nil reg)]
  (assert-eq "Customer name" "Alice" (:name state))
  (assert-eq "Customer email" "alice@example.com" (:email state))
  (assert-eq "Customer tier" "bronze" (:tier state))
  (assert-eq "Customer total-spent" 0 (:total-spent state))
  (assert-eq "Customer order-count" 0 (:order-count state)))

;; Customer tier upgrade
(let [reg (evt/->CustomerRegistered 200 "Alice" "alice@example.com" 999000)
      tier-change (evt/->CustomerTierChanged 200 "bronze" "silver" 1100000)
      s1 (proj/apply-customer-event nil reg)
      s2 (proj/apply-customer-event s1 tier-change)]
  (assert-eq "Customer tier after upgrade" "silver" (:tier s2)))

;; Inventory projection
(let [reserved (evt/->InventoryReserved 100 1 5 10)
      state (proj/apply-inventory-event nil reserved)]
  (assert-eq "Inventory item-id" 1 (:item-id state))
  (assert-eq "Inventory warehouse-id" 10 (:warehouse-id state))
  (assert-eq "Inventory reserved" 5 (:reserved state)))

;; Inventory release
(let [reserved (evt/->InventoryReserved 100 1 5 10)
      released (evt/->InventoryReleased 100 1 3 "cancelled")
      s1 (proj/apply-inventory-event nil reserved)
      s2 (proj/apply-inventory-event s1 released)]
  (assert-eq "Inventory after release reserved" 2 (:reserved s2)))

;; Shipment projection
(let [shipped (evt/->ItemShipped 100 1 "TRK-1" "UPS" 1003000)
      state (proj/apply-shipment-event nil shipped)]
  (assert-eq "Shipment tracking" "TRK-1" (:tracking-number state))
  (assert-eq "Shipment carrier" "UPS" (:carrier state))
  (assert-eq "Shipment shipped-at" 1003000 (:shipped-at state))
  (assert-nil "Shipment delivered-at nil" (:delivered-at state)))

;; Payment projection
(let [paid (evt/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
      state (proj/apply-payment-event nil paid)]
  (assert-eq "Payment amount-paid" 5000 (:amount-paid state))
  (assert-eq "Payment method" "credit-card" (:method state))
  (assert-eq "Payment status" "paid" (:status state)))

;; Helper predicates
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      shipped (evt/->ItemShipped 100 1 "TRK-1" "UPS" 1003000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 shipped)]
  (assert-true "is-fully-shipped single item" (proj/is-fully-shipped? s2)))

(let [placed (evt/->OrderPlaced 100 200
               [(evt/->OrderItem 1 "A" 1 1000) (evt/->OrderItem 2 "B" 1 2000)]
               3000 1000000)
      shipped1 (evt/->ItemShipped 100 1 "TRK-1" "UPS" 1003000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 shipped1)]
  (assert-false "not fully shipped yet" (proj/is-fully-shipped? s2)))

;; --- 3. Commands -----------------------------------------------------------

(println "=== Commands ===")

;; Place order
(let [e (cmd/place-order 100 200 [(evt/->OrderItem 1 "A" 2 1500)] 3000 1000000)]
  (assert-true "place-order returns OrderPlaced" (instance? pipeline.events.OrderPlaced e))
  (assert-eq "place-order order-id" 100 (:order-id e)))

;; Confirm order - valid
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      state (proj/apply-order-event nil placed)
      e (cmd/confirm-order state 1001000)]
  (assert-true "confirm-order returns OrderConfirmed" (instance? pipeline.events.OrderConfirmed e))
  (assert-eq "confirm-order confirmed-at" 1001000 (:confirmed-at e)))

;; Receive payment - valid
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      confirmed (evt/->OrderConfirmed 100 1001000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 confirmed)
      e (cmd/receive-payment s2 5000 "credit-card" "txn-1" 1002000)]
  (assert-true "receive-payment returns PaymentReceived" (instance? pipeline.events.PaymentReceived e))
  (assert-eq "receive-payment amount" 5000 (:amount e)))

;; Ship item - must be paid
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      confirmed (evt/->OrderConfirmed 100 1001000)
      paid (evt/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 confirmed)
      s3 (proj/apply-order-event s2 paid)
      e (cmd/ship-item s3 1 "TRK-1" "FedEx" 1003000)]
  (assert-true "ship-item returns ItemShipped" (instance? pipeline.events.ItemShipped e)))

;; Cancel order - can't cancel delivered
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      delivered (evt/->OrderDelivered 100 1004000)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 delivered)]
  (assert-throws "can't cancel delivered order"
    (cmd/cancel-order s2 "changed mind" 1005000)))

;; Reserve inventory
(let [state (evt/->InventoryState 1 10 100 0)
      e (cmd/reserve-inventory state 100 5 10)]
  (assert-true "reserve-inventory returns InventoryReserved"
    (instance? pipeline.events.InventoryReserved e))
  (assert-eq "reserve quantity" 5 (:quantity e)))

;; Can't reserve more than available
(let [state (evt/->InventoryState 1 10 3 0)]
  (assert-throws "can't reserve more than available"
    (cmd/reserve-inventory state 100 5 10)))

;; Register customer
(let [e (cmd/register-customer 200 "Bob" "bob@example.com" 1000000)]
  (assert-true "register-customer returns CustomerRegistered"
    (instance? pipeline.events.CustomerRegistered e)))

;; Issue refund - can't exceed paid
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      paid (evt/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
      os (-> nil (proj/apply-order-event placed))
      ps (proj/apply-payment-event nil paid)]
  (assert-throws "can't refund more than paid"
    (cmd/issue-refund os ps 6000 "mistake" 1006000)))

;; Valid refund
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      paid (evt/->PaymentReceived 100 5000 "credit-card" "txn-1" 1002000)
      os (-> nil (proj/apply-order-event placed))
      ps (proj/apply-payment-event nil paid)
      e (cmd/issue-refund os ps 3000 "partial" 1006000)]
  (assert-true "issue-refund returns RefundIssued" (instance? pipeline.events.RefundIssued e))
  (assert-eq "refund amount" 3000 (:amount e)))

;; --- 4. Handlers -----------------------------------------------------------

(println "=== Handlers ===")

;; For handlers we need a Projections lookup structure
;; Handlers receive events and produce downstream events

;; handle-order-placed should produce inventory reservations
(let [item1 (evt/->OrderItem 1 "Widget" 2 1500)
      item2 (evt/->OrderItem 2 "Gadget" 1 3000)
      placed (evt/->OrderPlaced 100 200 [item1 item2] 6000 1000000)
      inv-state1 (evt/->InventoryState 1 10 100 0)
      inv-state2 (evt/->InventoryState 2 10 50 0)
      lookup-inv (fn [item-id _wh-id] (if (= item-id 1) inv-state1 inv-state2))
      lookup-cust (fn [_] (proj/apply-customer-event nil
                            (evt/->CustomerRegistered 200 "Alice" "a@b.com" 999000)))
      projections {:lookup-inventory lookup-inv
                   :lookup-customer lookup-cust
                   :lookup-order (fn [_] nil)
                   :lookup-payment (fn [_] nil)}
      results (hdl/handle-order-placed placed projections)]
  (assert-true "handle-order-placed produces events" (pos? (count results)))
  (assert-true "produces InventoryReserved"
    (some #(instance? pipeline.events.InventoryReserved %) results)))

;; handle-order-cancelled should produce releases + refund if paid
(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 2 1500)] 3000 1000000)
      paid (evt/->PaymentReceived 100 3000 "credit-card" "txn-1" 1002000)
      cancelled (evt/->OrderCancelled 100 "changed mind" 1005000)
      os (-> nil
             (proj/apply-order-event placed)
             (proj/apply-order-event paid))
      ps (proj/apply-payment-event nil paid)
      projections {:lookup-inventory (fn [_ _] (evt/->InventoryState 1 10 100 2))
                   :lookup-customer (fn [_] nil)
                   :lookup-order (fn [_] os)
                   :lookup-payment (fn [_] ps)}
      results (hdl/handle-order-cancelled cancelled projections)]
  (assert-true "cancellation produces events" (pos? (count results)))
  (assert-true "produces InventoryReleased"
    (some #(instance? pipeline.events.InventoryReleased %) results))
  (assert-true "produces RefundIssued (order was paid)"
    (some #(instance? pipeline.events.RefundIssued %) results)))

;; --- 5. Queries ------------------------------------------------------------

(println "=== Queries ===")

(let [os1 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 1 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)))
      os2 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 2 200 [(evt/->OrderItem 2 "B" 1 3000)] 3000 1100000))
                  (proj/apply-order-event (evt/->OrderConfirmed 2 1101000)))
      os3 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 3 300 [(evt/->OrderItem 3 "C" 1 7000)] 7000 1200000))
                  (proj/apply-order-event (evt/->OrderCancelled 3 "no stock" 1201000)))
      orders [os1 os2 os3]]

  (assert-eq "orders-by-status placed" 1
    (count (qry/orders-by-status "placed" orders)))
  (assert-eq "orders-by-status confirmed" 1
    (count (qry/orders-by-status "confirmed" orders)))
  (assert-eq "orders-by-status cancelled" 1
    (count (qry/orders-by-status "cancelled" orders)))

  (assert-eq "orders-by-customer 200" 2
    (count (qry/orders-by-customer 200 orders)))
  (assert-eq "orders-by-customer 300" 1
    (count (qry/orders-by-customer 300 orders)))

  (assert-eq "average-order-value" 5000
    (qry/average-order-value orders))

  (assert-eq "revenue-by-period full range" 15000
    (qry/revenue-by-period 900000 1300000 orders)))

;; fulfillment-time
(let [placed (evt/->OrderPlaced 1 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      delivered (evt/->OrderDelivered 1 1500000)
      os (-> nil (proj/apply-order-event placed) (proj/apply-order-event delivered))]
  (assert-eq "fulfillment-time" 500000 (qry/fulfillment-time os)))

(let [placed (evt/->OrderPlaced 1 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      os (proj/apply-order-event nil placed)]
  (assert-nil "fulfillment-time nil if not delivered" (qry/fulfillment-time os)))

;; top customers
(let [c1 (-> nil (proj/apply-customer-event
                   (evt/->CustomerRegistered 1 "Alice" "a@b.com" 900000)))
      c2 (-> nil (proj/apply-customer-event
                   (evt/->CustomerRegistered 2 "Bob" "b@b.com" 900000)))
      ;; simulate spend via tier changes (proxy for total-spent in state)
      customers [c1 c2]
      top (qry/top-customers 1 customers)]
  (assert-eq "top-customers returns 1" 1 (count top)))

;; --- 6. Pipeline -----------------------------------------------------------

(println "=== Pipeline ===")

(let [store (pipe/empty-store)
      placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      store2 (pipe/append-event store placed)]
  (assert-eq "store version after append" 1 (:version store2))
  (assert-eq "store events count" 1 (count (:events store2))))

(let [store (pipe/empty-store)
      e1 (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      e2 (evt/->OrderConfirmed 100 1001000)
      store2 (pipe/append-events store [e1 e2])]
  (assert-eq "store version after batch" 2 (:version store2))
  (assert-eq "events-for-order" 2
    (count (pipe/events-for-order store2 100))))

;; events-since
(let [store (pipe/empty-store)
      e1 (evt/->CustomerRegistered 200 "Alice" "a@b.com" 999000)
      e2 (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      store2 (pipe/append-events store [e1 e2])
      since (pipe/events-since store2 1)]
  (assert-eq "events-since version 1" 1 (count since)))

;; --- 7. Notifications ------------------------------------------------------

(println "=== Notifications ===")

(let [placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      os (proj/apply-order-event nil placed)
      cs (proj/apply-customer-event nil
           (evt/->CustomerRegistered 200 "Alice" "alice@example.com" 999000))
      n (notif/build-order-confirmation os cs)]
  (assert-true "notification is NotificationSent" (instance? pipeline.events.NotificationSent n))
  (assert-eq "notification recipient" "alice@example.com" (:recipient n))
  (assert-eq "notification channel" "email" (:channel n)))

(let [shipped (evt/->ItemShipped 100 1 "TRK-123" "FedEx" 1003000)
      ss (proj/apply-shipment-event nil shipped)
      placed (evt/->OrderPlaced 100 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)
      os (proj/apply-order-event nil placed)
      n (notif/build-shipping-notice ss os)]
  (assert-eq "shipping notice channel" "sms" (:channel n)))

;; --- 8. Analytics ----------------------------------------------------------

(println "=== Analytics ===")

(let [os1 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 1 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000)))
      os2 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 2 200 [(evt/->OrderItem 2 "B" 1 3000)] 3000 1100000))
                  (proj/apply-order-event (evt/->OrderConfirmed 2 1101000)))
      os3 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 3 300 [(evt/->OrderItem 3 "C" 1 7000)] 7000 1200000))
                  (proj/apply-order-event (evt/->OrderConfirmed 3 1201000))
                  (proj/apply-order-event (evt/->PaymentReceived 3 7000 "cc" "t" 1202000)))
      orders [os1 os2 os3]
      funnel (analytics/conversion-funnel orders)]
  (assert-eq "funnel placed" 3 (get funnel "placed"))
  (assert-eq "funnel confirmed" 2 (get funnel "confirmed"))
  (assert-eq "funnel paid" 1 (get funnel "paid")))

(let [cs1 (-> nil (proj/apply-customer-event
                    (evt/->CustomerRegistered 1 "Alice" "a@b.com" 900000)))
      cs2 (-> nil (proj/apply-customer-event
                    (evt/->CustomerRegistered 2 "Bob" "b@b.com" 900000))
                  (proj/apply-customer-event
                    (evt/->CustomerTierChanged 2 "bronze" "silver" 1000000)))
      customers [cs1 cs2]
      dist (analytics/customer-tier-distribution customers)]
  (assert-eq "tier dist bronze" 1 (get dist "bronze"))
  (assert-eq "tier dist silver" 1 (get dist "silver")))

(let [ps1 (proj/apply-payment-event nil
            (evt/->PaymentReceived 1 5000 "credit-card" "t1" 1000000))
      ps2 (proj/apply-payment-event nil
            (evt/->PaymentReceived 2 3000 "paypal" "t2" 1000000))
      ps3 (proj/apply-payment-event nil
            (evt/->PaymentReceived 3 7000 "credit-card" "t3" 1000000))
      payments [ps1 ps2 ps3]
      breakdown (analytics/payment-method-breakdown payments)]
  (assert-eq "method credit-card count" 2 (get breakdown "credit-card"))
  (assert-eq "method paypal count" 1 (get breakdown "paypal")))

;; Cancellation reasons
(let [os1 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 1 200 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000000))
                  (proj/apply-order-event (evt/->OrderCancelled 1 "out of stock" 1001000)))
      os2 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 2 300 [(evt/->OrderItem 2 "B" 1 3000)] 3000 1100000))
                  (proj/apply-order-event (evt/->OrderCancelled 2 "out of stock" 1101000)))
      os3 (-> nil (proj/apply-order-event
                    (evt/->OrderPlaced 3 400 [(evt/->OrderItem 3 "C" 1 7000)] 7000 1200000))
                  (proj/apply-order-event (evt/->OrderCancelled 3 "customer request" 1201000)))
      orders [os1 os2 os3]
      reasons (analytics/cancellation-reasons orders)]
  (assert-eq "cancellation out of stock" 2 (get reasons "out of stock"))
  (assert-eq "cancellation customer request" 1 (get reasons "customer request")))

;; --- Summary ---------------------------------------------------------------

(println)
(println (str "=== RESULTS: " @*pass-count* " passed, " @*fail-count* " failed ==="))
(when (pos? @*fail-count*)
  (println "\nFailures:")
  (doseq [f @*failures*]
    (println (str "  FAIL: " (:label f)
                  " — expected: " (:expected f)
                  ", got: " (:actual f)))))

(System/exit (if (zero? @*fail-count*) 0 1))
