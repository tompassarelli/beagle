(ns verify.e5b-schema-evolution
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
           (swap! *failures* conj {:label ~label :expected e# :actual a#})))))

(defmacro assert-true [label expr]
  `(if ~expr
     (swap! *pass-count* inc)
     (do (swap! *fail-count* inc)
         (swap! *failures* conj {:label ~label :expected true :actual false}))))

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

;; === Schema Evolution Assertions ===

(println "=== E5b: Schema Evolution Verification ===")

;; 1. OrderPlaced no longer has items or total
(println "--- OrderPlaced field removal ---")

(let [e (evt/->OrderPlaced 100 200 1000000)]
  (assert-eq "OrderPlaced order-id" 100 (:order-id e))
  (assert-eq "OrderPlaced customer-id" 200 (:customer-id e))
  (assert-eq "OrderPlaced placed-at" 1000000 (:placed-at e))
  (assert-nil "OrderPlaced has no items" (:items e))
  (assert-nil "OrderPlaced has no total" (:total e)))

;; 2. OrderPriced exists and carries items + total
(println "--- OrderPriced new event ---")

(let [items [(evt/->OrderItem 1 "Widget" 2 1500)]
      e (evt/->OrderPriced 100 items 3000 1000500)]
  (assert-eq "OrderPriced order-id" 100 (:order-id e))
  (assert-eq "OrderPriced total" 3000 (:total e))
  (assert-eq "OrderPriced items count" 1 (count (:items e)))
  (assert-eq "OrderPriced priced-at" 1000500 (:priced-at e)))

;; 3. Projection handles two-event flow
(println "--- Projection two-event flow ---")

(let [placed (evt/->OrderPlaced 100 200 1000000)
      priced (evt/->OrderPriced 100 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000500)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 priced)]
  (assert-eq "After placed - status" "placed" (:status s1))
  (assert-nil "After placed - no items yet" (:items s1))
  (assert-nil "After placed - no total yet" (:total s1))
  (assert-eq "After priced - items set" 1 (count (:items s2)))
  (assert-eq "After priced - total set" 5000 (:total s2))
  (assert-not-nil "After priced - priced-at set" (:priced-at s2)))

;; 4. Commands enforce pricing before confirmation
(println "--- Commands enforce pricing ---")

(let [placed (evt/->OrderPlaced 100 200 1000000)
      s1 (proj/apply-order-event nil placed)]
  (assert-throws "can't confirm unpriced order"
    (cmd/confirm-order s1 1001000)))

(let [placed (evt/->OrderPlaced 100 200 1000000)
      priced (evt/->OrderPriced 100 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000500)
      s1 (proj/apply-order-event nil placed)
      s2 (proj/apply-order-event s1 priced)
      e (cmd/confirm-order s2 1001000)]
  (assert-true "can confirm priced order" (instance? pipeline.events.OrderConfirmed e)))

;; 5. place-order command takes fewer args
(println "--- place-order slim signature ---")

(let [e (cmd/place-order 100 200 1000000)]
  (assert-true "place-order returns OrderPlaced" (instance? pipeline.events.OrderPlaced e))
  (assert-eq "place-order order-id" 100 (:order-id e)))

;; 6. New price-order command
(println "--- price-order new command ---")

(let [placed (evt/->OrderPlaced 100 200 1000000)
      s1 (proj/apply-order-event nil placed)
      items [(evt/->OrderItem 1 "A" 2 1500)]
      e (cmd/price-order s1 items 3000 1000500)]
  (assert-true "price-order returns OrderPriced" (instance? pipeline.events.OrderPriced e))
  (assert-eq "price-order total" 3000 (:total e)))

;; 7. Handlers: inventory reservation moved to handle-order-priced
(println "--- Handler restructuring ---")

(let [placed (evt/->OrderPlaced 100 200 1000000)
      projections {:lookup-inventory (fn [_ _] (evt/->InventoryState 1 10 100 0))
                   :lookup-customer (fn [_] nil)
                   :lookup-order (fn [_] nil)
                   :lookup-payment (fn [_] nil)}
      results (hdl/handle-order-placed placed projections)]
  ;; handle-order-placed should NOT produce InventoryReserved anymore
  (assert-true "placed handler no longer reserves inventory"
    (not (some #(instance? pipeline.events.InventoryReserved %) results))))

(let [priced (evt/->OrderPriced 100 [(evt/->OrderItem 1 "A" 2 1500)] 3000 1000500)
      projections {:lookup-inventory (fn [_ _] (evt/->InventoryState 1 10 100 0))
                   :lookup-customer (fn [_] nil)
                   :lookup-order (fn [_] (proj/apply-order-event nil (evt/->OrderPlaced 100 200 1000000)))
                   :lookup-payment (fn [_] nil)}
      results (hdl/handle-order-priced priced projections)]
  (assert-true "priced handler reserves inventory"
    (some #(instance? pipeline.events.InventoryReserved %) results)))

;; 8. Analytics: conversion funnel includes "priced" stage
(println "--- Analytics updated ---")

(let [placed (evt/->OrderPlaced 1 200 1000000)
      priced (evt/->OrderPriced 1 [(evt/->OrderItem 1 "A" 1 5000)] 5000 1000500)
      confirmed (evt/->OrderConfirmed 1 1001000)
      os (-> nil
             (proj/apply-order-event placed)
             (proj/apply-order-event priced)
             (proj/apply-order-event confirmed))
      funnel (analytics/conversion-funnel [os])]
  (assert-eq "funnel has placed" 1 (get funnel "placed"))
  (assert-eq "funnel has priced" 1 (get funnel "priced"))
  (assert-eq "funnel has confirmed" 1 (get funnel "confirmed")))

;; --- Summary ---------------------------------------------------------------

(println)
(println (str "=== E5b RESULTS: " @*pass-count* " passed, " @*fail-count* " failed ==="))
(when (pos? @*fail-count*)
  (println "\nFailures:")
  (doseq [f @*failures*]
    (println (str "  FAIL: " (:label f)
                  " — expected: " (:expected f)
                  ", got: " (:actual f)))))

(System/exit (if (zero? @*fail-count*) 0 1))
