(ns e4.verify
  (:require [catalog :as cat]
            [customers :as cust]
            [inventory :as inv]
            [orders :as ord]
            [reports :as rep]
            [shipping :as ship]
            [billing :as bill]
            [procurement :as proc]
            [promotions :as promo]
            [employees :as emp]
            [analytics :as analytics]
            [notifications :as notif]
            [audit :as audit]))

;; ---------------------------------------------------------------------------
;; Assertion helpers
;; ---------------------------------------------------------------------------

(def ^:dynamic *pass-count* (atom 0))
(def ^:dynamic *fail-count* (atom 0))

(defn assert-eq [label expected actual]
  (if (= expected actual)
    (swap! *pass-count* inc)
    (do (swap! *fail-count* inc)
        (println (str "FAIL: " label "\n  expected: " expected "\n  actual:   " actual)))))

(defn assert-true [label val]
  (assert-eq label true val))

(defn assert-false [label val]
  (assert-eq label false val))

;; ---------------------------------------------------------------------------
;; Test Data (from E1 master.verify.clj)
;; ---------------------------------------------------------------------------

;; Suppliers
(def sup1 (cat/->Supplier 1 "Acme Corp" 7))
(def sup2 (cat/->Supplier 2 "Widget Co" 14))
(def sup3 (cat/->Supplier 3 "Parts R Us" 3))
(def suppliers [sup1 sup2 sup3])

;; Categories
(def cat1 (cat/->Category 1 "Electronics" 0.15))
(def cat2 (cat/->Category 2 "Office" 0.08))
(def cat3 (cat/->Category 3 "Industrial" 0.12))
(def categories [cat1 cat2 cat3])

;; Products
(def prod1 (cat/->Product 1 "Widget A" "WGT-001" 500 1200 1 1 true))
(def prod2 (cat/->Product 2 "Gadget B" "GDG-002" 800 1500 1 1 true))
(def prod3 (cat/->Product 3 "Stapler" "STP-003" 200 450 2 2 true))
(def prod4 (cat/->Product 4 "Desk Lamp" "DLM-004" 350 750 2 2 true))
(def prod5 (cat/->Product 5 "Bolt Pack" "BLT-005" 50 120 3 3 true))
(def prod6 (cat/->Product 6 "Gear Set" "GRS-006" 1200 2200 3 3 true))
(def prod7 (cat/->Product 7 "Old Widget" "OWG-007" 300 600 1 1 false))
(def products [prod1 prod2 prod3 prod4 prod5 prod6 prod7])

;; Warehouses
(def wh1 (inv/->Warehouse 1 "Main DC" "Chicago" 10000))
(def wh2 (inv/->Warehouse 2 "West Hub" "Portland" 5000))
(def warehouses [wh1 wh2])

;; Stock levels
(def sl-1-1 (inv/->StockLevel 1 1 100 20))
(def sl-1-2 (inv/->StockLevel 1 2 50 15))
(def sl-1-3 (inv/->StockLevel 1 3 200 50))
(def sl-1-4 (inv/->StockLevel 1 4 30 10))
(def sl-1-5 (inv/->StockLevel 1 5 500 100))
(def sl-1-6 (inv/->StockLevel 1 6 8 10))
(def sl-2-1 (inv/->StockLevel 2 1 75 20))
(def sl-2-2 (inv/->StockLevel 2 2 25 10))
(def sl-2-3 (inv/->StockLevel 2 3 0 30))
(def sl-2-5 (inv/->StockLevel 2 5 300 50))
(def stock-levels [sl-1-1 sl-1-2 sl-1-3 sl-1-4 sl-1-5 sl-1-6
                   sl-2-1 sl-2-2 sl-2-3 sl-2-5])

;; Customers
(def addr1 (cust/->Address "123 Main St" "Chicago" "IL" "60601"))
(def addr2 (cust/->Address "456 Oak Ave" "Portland" "OR" "97201"))
(def addr3 (cust/->Address "789 Pine Rd" "Austin" "TX" "78701"))

(def cust1 (cust/->Customer 1 "Alice Smith" "alice@example.com" "gold" addr1 2020))
(def cust2 (cust/->Customer 2 "Bob Jones" "bob@example.com" "silver" addr2 2021))
(def cust3 (cust/->Customer 3 "Carol White" "carol@example.com" "bronze" addr3 2023))
(def customers [cust1 cust2 cust3])

;; Purchase records
(def pr1 (cust/->PurchaseRecord 1 101 15000 2024))
(def pr2 (cust/->PurchaseRecord 1 102 22000 2024))
(def pr3 (cust/->PurchaseRecord 1 103 18000 2025))
(def pr4 (cust/->PurchaseRecord 2 201 8000 2024))
(def pr5 (cust/->PurchaseRecord 2 202 12000 2025))
(def pr6 (cust/->PurchaseRecord 3 301 5000 2025))
(def purchase-records [pr1 pr2 pr3 pr4 pr5 pr6])

;; Orders
(def order1 (ord/create-order 1001 1 [[1 5] [2 2]] products categories customers 1700000000))
(def order2 (ord/create-order 1002 2 [[3 10] [5 20]] products categories customers 1700100000))
(def order3 (ord/create-order 1003 1 [[6 1] [4 3]] products categories customers 1700200000))
(def order4 (ord/create-order 1004 3 [[1 2]] products categories customers 1700300000))
(def orders [order1 order2 order3 order4])

;; ---------------------------------------------------------------------------
;; E4 Test Data (new modules)
;; ---------------------------------------------------------------------------

;; Carriers
(def carrier1 (ship/->Carrier 1 "FastShip" 500 100 50 true))
(def carrier2 (ship/->Carrier 2 "EcoFreight" 300 50 100 true))
(def carrier3 (ship/->Carrier 3 "OvernightExpress" 1500 200 30 false))
(def carriers [carrier1 carrier2 carrier3])

;; Delivery Zones
(def zone1 (ship/->DeliveryZone 1 "Local" 0))
(def zone2 (ship/->DeliveryZone 2 "Remote" 20))
(def zones [zone1 zone2])

;; Shipments
(def shipment1 (ship/->Shipment 1 1001 1 1 "delivered" "TRK001" 5 1000 1000 3000))
(def shipment2 (ship/->Shipment 2 1002 2 1 "shipped" "TRK002" 10 800 2000 0))
(def shipment3 (ship/->Shipment 3 1003 1 2 "pending" "TRK003" 3 800 3000 0))
(def shipments [shipment1 shipment2 shipment3])

;; Invoices
(def inv1 (bill/->Invoice 1 1 1 9000 765 1350 8415 "paid" 1000 3000 2000))
(def inv2 (bill/->Invoice 2 2 2 15000 1275 1500 14775 "paid" 2000 4000 3500))
(def inv3 (bill/->Invoice 3 3 1 5000 425 750 4675 "unpaid" 3000 5000 0))
(def inv4 (bill/->Invoice 4 4 3 20000 1700 1000 20700 "unpaid" 4000 6000 0))
(def invoices [inv1 inv2 inv3 inv4])

;; Payments
(def pay1 (bill/->Payment 1 1 8415 "card" "completed" 2000))
(def pay2 (bill/->Payment 2 2 10000 "bank" "completed" 3000))
(def pay3 (bill/->Payment 3 2 4775 "card" "completed" 3500))
(def payments [pay1 pay2 pay3])

;; Credit Notes
(def cn1 (bill/->CreditNote 1 1 500 "damaged goods" 2500))
(def credit-notes [cn1])

;; Purchase Orders
(def po1 (proc/->PurchaseOrder 1 1 "completed" 1000 5000 6000))
(def po2 (proc/->PurchaseOrder 2 2 "pending" 3000 8000 4500))
(def purchase-orders [po1 po2])

;; PO Lines
(def poline1 (proc/->POLine 1 1 10 400))
(def poline2 (proc/->POLine 1 3 4 500))
(def poline3 (proc/->POLine 2 5 10 450))
(def po-lines [poline1 poline2 poline3])

;; Goods Receipts
(def gr1 (proc/->GoodsReceipt 1 1 1 4000 2))
(def goods-receipts [gr1])

;; Campaigns
(def campaign1 (promo/->Campaign 1 "Summer Sale" 1000 5000 "active"))
(def campaign2 (promo/->Campaign 2 "VIP Only" 2000 6000 "active"))
(def campaigns [campaign1 campaign2])

;; Coupons
(def coupon1 (promo/->Coupon 1 1 "SUMMER10" "percentage" 10 5000 100 30))
(def coupon2 (promo/->Coupon 2 1 "SAVE500" "fixed" 500 3000 50 50))
(def coupon3 (promo/->Coupon 3 2 "VIP20" "percentage" 20 10000 20 5))
(def coupons [coupon1 coupon2 coupon3])

;; Promotion Rules
(def rule1 (promo/->PromotionRule 1 1 "" 5000 0))
(def rule2 (promo/->PromotionRule 2 2 "gold" 10000 0))
(def promo-rules [rule1 rule2])

;; Employees
(def emp1 (emp/->Employee 1 "Alice" "sales" "rep" 100 true))
(def emp2 (emp/->Employee 2 "Bob" "sales" "manager" 200 true))
(def emp3 (emp/->Employee 3 "Carol" "support" "rep" 500 false))
(def employees [emp1 emp2 emp3])

;; Commission Rules
(def cr1 (emp/->CommissionRule 1 1 1 5))
(def cr2 (emp/->CommissionRule 2 1 2 8))
(def cr3 (emp/->CommissionRule 3 2 1 3))
(def commission-rules [cr1 cr2 cr3])

;; Sales Targets
(def st1 (emp/->SalesTarget 1 1 "2024-Q1" 50000 35000))
(def st2 (emp/->SalesTarget 2 2 "2024-Q1" 80000 90000))
(def sales-targets [st1 st2])

;; Templates
(def tmpl1 (notif/->Template 1 "order-confirm" "email" "Order Confirmed" "Your order {id} is confirmed"))
(def tmpl2 (notif/->Template 2 "ship-notify" "sms" "Shipped" "Order {id} shipped"))
(def tmpl3 (notif/->Template 3 "invoice-due" "email" "Invoice Due" "Invoice {id} is due"))
(def templates [tmpl1 tmpl2 tmpl3])

;; Notifications
(def notif1 (notif/->Notification 1 1 1 1 "order" "sent" 1000 1100))
(def notif2 (notif/->Notification 2 2 1 1 "shipment" "sent" 2000 2050))
(def notif3 (notif/->Notification 3 1 2 2 "order" "pending" 2000 0))
(def notif4 (notif/->Notification 4 3 1 3 "invoice" "failed" 3000 0))
(def notifications [notif1 notif2 notif3 notif4])

;; Preferences
(def pref1 (notif/->Preference 1 "email" true))
(def pref2 (notif/->Preference 1 "sms" false))
(def pref3 (notif/->Preference 2 "email" true))
(def preferences [pref1 pref2 pref3])

;; Audit Entries
(def ae1 (audit/->AuditEntry 1 "order" 1 "create" 1 1000 "pending"))
(def ae2 (audit/->AuditEntry 2 "order" 1 "update" 1 1500 "confirmed"))
(def ae3 (audit/->AuditEntry 3 "shipment" 1 "create" 2 2000 "pending"))
(def ae4 (audit/->AuditEntry 4 "invoice" 1 "create" 1 1000 "unpaid"))
(def audit-entries [ae1 ae2 ae3 ae4])

;; Analytics metrics
(def metric1 (analytics/->PeriodMetric "2024-Q1" "revenue" 50000))
(def metric2 (analytics/->PeriodMetric "2024-Q2" "revenue" 65000))
(def metric3 (analytics/->PeriodMetric "2024-Q3" "revenue" 55000))
(def metric4 (analytics/->PeriodMetric "2024-Q1" "order-count" 100))
(def metric5 (analytics/->PeriodMetric "2024-Q2" "order-count" 130))
(def metric6 (analytics/->PeriodMetric "2024-Q3" "order-count" 110))
(def metrics [metric1 metric2 metric3 metric4 metric5 metric6])


;; ===========================================================================
;; CATALOG TESTS (abbreviated, key functions)
;; ===========================================================================

(println "--- CATALOG ---")

(assert-eq "cat/product-margin Widget A" 700 (cat/product-margin prod1))
(assert-eq "cat/product-margin-pct Widget A" 58 (cat/product-margin-pct prod1))
(assert-true "cat/product-profitable? Widget A" (cat/product-profitable? prod1))
(assert-eq "cat/active-products count" 6 (count (cat/active-products products)))
(assert-eq "cat/inactive-products count" 1 (count (cat/inactive-products products)))
(assert-eq "cat/products-by-category cat 1" 3 (count (cat/products-by-category products 1)))
(assert-eq "cat/find-product-by-id 1 name" "Widget A" (cat/product-name (cat/find-product-by-id products 1)))
(assert-eq "cat/find-product-by-id 99" nil (cat/find-product-by-id products 99))
(assert-eq "cat/find-product-by-sku WGT-001" "Widget A" (cat/product-name (cat/find-product-by-sku products "WGT-001")))
(assert-eq "cat/sort-by-price first" "Bolt Pack" (cat/product-name (first (cat/sort-by-price products))))
(assert-eq "cat/total-catalog-value" 6820 (cat/total-catalog-value products))
(assert-eq "cat/total-catalog-cost" 3400 (cat/total-catalog-cost products))
(assert-eq "cat/avg-unit-price" 974 (cat/avg-unit-price products))
(assert-eq "cat/cheapest-product" "Bolt Pack" (cat/product-name (cat/cheapest-product products)))
(assert-eq "cat/most-expensive-product" "Gear Set" (cat/product-name (cat/most-expensive-product products)))
(assert-eq "cat/format-price 1200" "$12.00" (cat/format-price 1200))
(assert-eq "cat/format-price 50" "$0.50" (cat/format-price 50))
(assert-eq "cat/product-tax Widget A" 180 (cat/product-tax prod1 cat1))
(assert-eq "cat/high-margin-products 50" 5 (count (cat/high-margin-products products 50)))
(assert-eq "cat/products-in-price-range 400-800" 3 (count (cat/products-in-price-range products 400 800)))
(assert-eq "cat/top-n-by-price first" "Gear Set" (cat/product-name (first (cat/top-n-by-price products 2))))
(assert-eq "cat/category-total-value cat 1" 3300 (cat/category-total-value products 1))
(assert-eq "cat/supplier-avg-lead-time" 8 (cat/supplier-avg-lead-time suppliers))
(assert-eq "cat/price-spread" 2080 (cat/price-spread products))
(assert-eq "cat/cost-spread" 1150 (cat/cost-spread products))
(assert-eq "cat/product-price-diff prod1 prod5" 1080 (cat/product-price-diff prod1 prod5))
(assert-true "cat/valid-product? prod1" (cat/valid-product? prod1))
(let [tiers (cat/make-standard-tiers)]
  (assert-eq "cat/quantity-price Widget A qty 100" 102000 (cat/quantity-price prod1 tiers 100))
  (assert-eq "cat/quantity-price Widget A qty 1" 1200 (cat/quantity-price prod1 tiers 1)))
(assert-eq "cat/product-summary Widget A" "Widget A (WGT-001) $12.00" (cat/product-summary prod1))


;; ===========================================================================
;; CUSTOMERS TESTS
;; ===========================================================================

(println "--- CUSTOMERS ---")

(assert-eq "cust/tier-discount-pct gold" 15 (cust/tier-discount-pct "gold"))
(assert-eq "cust/tier-discount-pct silver" 10 (cust/tier-discount-pct "silver"))
(assert-eq "cust/tier-discount-pct bronze" 5 (cust/tier-discount-pct "bronze"))
(assert-eq "cust/tier-rank gold" 3 (cust/tier-rank "gold"))
(assert-true "cust/higher-tier? gold vs silver" (cust/higher-tier? "gold" "silver"))
(assert-false "cust/higher-tier? bronze vs gold" (cust/higher-tier? "bronze" "gold"))
(assert-eq "cust/tier-from-spend 100000" "gold" (cust/tier-from-spend 100000))
(assert-eq "cust/tier-from-spend 50000" "silver" (cust/tier-from-spend 50000))
(assert-eq "cust/tier-from-spend 10000" "bronze" (cust/tier-from-spend 10000))
(assert-eq "cust/tier-from-spend 5000" "none" (cust/tier-from-spend 5000))
(assert-eq "cust/find-customer-by-id 1" "Alice Smith" (cust/customer-name (cust/find-customer-by-id customers 1)))
(assert-eq "cust/find-customer-by-id 99" nil (cust/find-customer-by-id customers 99))
(assert-eq "cust/customer-total-spend Alice" 55000 (cust/customer-total-spend purchase-records 1))
(assert-eq "cust/customer-total-spend Bob" 20000 (cust/customer-total-spend purchase-records 2))
(assert-eq "cust/customer-purchase-count Alice" 3 (cust/customer-purchase-count purchase-records 1))
(assert-eq "cust/customer-avg-order-value Alice" 18333 (cust/customer-avg-order-value purchase-records 1))
(assert-eq "cust/customer-spend-in-year Alice 2024" 37000 (cust/customer-spend-in-year purchase-records 1 2024))
(assert-eq "cust/assess-tier Alice" "silver" (cust/assess-tier purchase-records 1))
(assert-eq "cust/assess-tier Bob" "bronze" (cust/assess-tier purchase-records 2))
(assert-eq "cust/count-by-tier" {:gold 1 :silver 1 :bronze 1} (cust/count-by-tier customers))
(assert-eq "cust/total-customer-count" 3 (cust/total-customer-count customers))
(assert-eq "cust/customer-tenure Alice 2025" 5 (cust/customer-tenure cust1 2025))
(assert-eq "cust/avg-customer-tenure 2025" 3 (cust/avg-customer-tenure customers 2025))
(assert-true "cust/valid-customer? cust1" (cust/valid-customer? cust1))
(assert-true "cust/valid-address? addr1" (cust/valid-address? addr1))
(assert-eq "cust/address-oneline addr1" "123 Main St, Chicago, IL 60601" (cust/address-oneline addr1))
(assert-eq "cust/unique-states count" 3 (count (cust/unique-states customers)))
(assert-eq "cust/points-for-purchase 15000 gold" 450 (cust/points-for-purchase 15000 "gold"))
(assert-eq "cust/points-for-purchase 10000 silver" 200 (cust/points-for-purchase 10000 "silver"))
(assert-eq "cust/points-to-dollars 450" 45 (cust/points-to-dollars 450))
(assert-eq "cust/customer-segment Alice" "occasional" (cust/customer-segment purchase-records 1))


;; ===========================================================================
;; INVENTORY TESTS
;; ===========================================================================

(println "--- INVENTORY ---")

(assert-eq "inv/total-stock-for-product prod 1" 175 (inv/total-stock-for-product stock-levels 1))
(assert-eq "inv/total-stock-in-warehouse wh 1" 888 (inv/total-stock-in-warehouse stock-levels 1))
(assert-eq "inv/total-stock-in-warehouse wh 2" 400 (inv/total-stock-in-warehouse stock-levels 2))
(assert-true "inv/in-stock? wh1 prod1" (inv/in-stock? stock-levels 1 1))
(assert-false "inv/in-stock? wh2 prod3" (inv/in-stock? stock-levels 2 3))
(assert-true "inv/below-minimum? sl-1-6" (inv/below-minimum? sl-1-6))
(assert-false "inv/below-minimum? sl-1-1" (inv/below-minimum? sl-1-1))
(assert-eq "inv/low-stock-items count" 2 (count (inv/low-stock-items stock-levels)))
(assert-eq "inv/out-of-stock-items count" 1 (count (inv/out-of-stock-items stock-levels)))
(assert-true "inv/can-fulfill? prod1 100" (inv/can-fulfill? stock-levels 1 100))
(assert-false "inv/can-fulfill? prod1 176" (inv/can-fulfill? stock-levels 1 176))
(assert-eq "inv/stock-value-at-warehouse wh1" 175100 (inv/stock-value-at-warehouse stock-levels 1 products))
(assert-eq "inv/stock-value-at-warehouse wh2" 72500 (inv/stock-value-at-warehouse stock-levels 2 products))
(assert-eq "inv/total-inventory-value" 247600 (inv/total-inventory-value stock-levels products))
(assert-eq "inv/stock-retail-value" 548600 (inv/stock-retail-value stock-levels products))
(assert-eq "inv/reorder-quantity sl-1-6" 4 (inv/reorder-quantity sl-1-6))
(assert-eq "inv/reorder-quantity sl-2-3" 60 (inv/reorder-quantity sl-2-3))
(assert-eq "inv/reorder-cost" 16800 (inv/reorder-cost stock-levels products))
(assert-eq "inv/warehouse-utilization-pct wh1" 8 (inv/warehouse-utilization-pct stock-levels wh1))
(assert-eq "inv/warehouse-item-count wh1" 6 (inv/warehouse-item-count stock-levels 1))
(assert-eq "inv/days-of-stock prod1 demand 5" 35 (inv/days-of-stock stock-levels 1 5))
(assert-eq "inv/days-of-stock zero demand" 999 (inv/days-of-stock stock-levels 1 0))
(assert-eq "inv/safety-stock 10 7 2" 140 (inv/safety-stock 10 7 2))
(assert-eq "inv/stock-summary sl-1-1" "WH:1 Prod:1 Qty:100/20" (inv/stock-summary sl-1-1))
(assert-eq "inv/warehouse-summary wh1" "Main DC (Chicago) cap:10000" (inv/warehouse-summary wh1))


;; ===========================================================================
;; ORDERS TESTS
;; ===========================================================================

(println "--- ORDERS ---")

(assert-eq "order1 subtotal" 9000 (ord/order-subtotal order1))
(assert-eq "order1 discount" 1350 (ord/order-discount order1))
(assert-eq "order1 tax" 765 (ord/order-tax order1))
(assert-eq "order1 total" 8415 (ord/order-total order1))
(assert-eq "order2 subtotal" 6900 (ord/order-subtotal order2))
(assert-eq "order2 total" 6831 (ord/order-total order2))
(assert-eq "order3 total" 4161 (ord/order-total order3))
(assert-eq "order4 total" 2508 (ord/order-total order4))
(assert-eq "order1 status" "pending" (ord/order-status order1))
(assert-true "ord/can-fulfill-order? order1" (ord/can-fulfill-order? stock-levels order1))
(assert-eq "ord/total-revenue" 21915 (ord/total-revenue orders))
(assert-eq "ord/avg-order-value" 5478 (ord/avg-order-value orders))
(assert-eq "ord/total-discounts-given" 2827 (ord/total-discounts-given orders))
(assert-eq "ord/total-tax-collected" 1992 (ord/total-tax-collected orders))
(assert-eq "ord/product-units-ordered prod1" 7 (ord/product-units-ordered orders 1))
(assert-eq "ord/product-revenue prod1" 8400 (ord/product-revenue orders 1))
(assert-eq "ord/total-units-ordered" 43 (ord/total-units-ordered orders))
(assert-eq "ord/largest-order" 1001 (ord/order-id (ord/largest-order orders)))
(assert-eq "ord/smallest-order" 1004 (ord/order-id (ord/smallest-order orders)))
(assert-eq "ord/customer-order-count Alice" 2 (ord/customer-order-count orders 1))
(assert-eq "ord/customer-total-spend Alice" 12576 (ord/customer-total-spend orders 1))
(assert-true "ord/valid-order? order1" (ord/valid-order? order1))
(assert-eq "ord/find-order-by-id 1001" 1001 (ord/order-id (ord/find-order-by-id orders 1001)))
(assert-eq "ord/find-order-by-id 9999" nil (ord/find-order-by-id orders 9999))


;; ===========================================================================
;; REPORTS TESTS
;; ===========================================================================

(println "--- REPORTS ---")

(let [ss (rep/sales-summary orders)]
  (assert-eq "rep/sales-summary total-orders" 4 (:total-orders ss))
  (assert-eq "rep/sales-summary total-revenue" 21915 (:total-revenue ss))
  (assert-eq "rep/sales-summary total-tax" 1992 (:total-tax ss))
  (assert-eq "rep/sales-summary avg-order-value" 5478 (:avg-order-value ss)))

(assert-eq "rep/fulfillment-rate" 100 (rep/fulfillment-rate orders stock-levels))

(let [dash (rep/dashboard products suppliers categories stock-levels warehouses customers orders)]
  (assert-eq "rep/dashboard catalog total-products" 7 (get-in dash [:catalog :total-products]))
  (assert-eq "rep/dashboard catalog active-products" 6 (get-in dash [:catalog :active-products]))
  (assert-eq "rep/dashboard inventory total-value" 247600 (get-in dash [:inventory :total-value]))
  (assert-eq "rep/dashboard customers total-count" 3 (get-in dash [:customers :total-count]))
  (assert-eq "rep/dashboard orders total-revenue" 21915 (get-in dash [:orders :total-revenue])))

(let [top2 (rep/top-products-by-revenue orders products 2)]
  (assert-eq "rep/top-products-by-revenue #1" "Widget A" (:product-name (first top2)))
  (assert-eq "rep/top-products-by-revenue #2" "Stapler" (:product-name (second top2))))

(let [cr (rep/customer-report customers orders)]
  (assert-eq "rep/customer-report count" 3 (count cr)))

(let [trr (rep/tier-revenue-report customers orders)
      by-tier (into {} (mapv (fn [r] [(:tier r) r]) trr))]
  (assert-eq "rep/tier-revenue gold revenue" 12576 (:revenue (get by-tier "gold")))
  (assert-eq "rep/tier-revenue silver revenue" 6831 (:revenue (get by-tier "silver")))
  (assert-eq "rep/tier-revenue bronze revenue" 2508 (:revenue (get by-tier "bronze"))))


;; ===========================================================================
;; SHIPPING TESTS
;; ===========================================================================

(println "--- SHIPPING ---")

;; Find carrier
(assert-eq "ship/find-carrier-by-id 1" "FastShip" (ship/carrier-name (ship/find-carrier-by-id carriers 1)))
(assert-eq "ship/find-carrier-by-id 2" "EcoFreight" (ship/carrier-name (ship/find-carrier-by-id carriers 2)))
(assert-eq "ship/find-carrier-by-id 99" nil (ship/find-carrier-by-id carriers 99))

;; Active carriers
(assert-eq "ship/active-carriers count" 2 (count (ship/active-carriers carriers)))

;; Carrier total cost: base + per-kg * weight
;; FastShip 10kg: 500 + 100*10 = 1500
(assert-eq "ship/carrier-total-cost FastShip 10kg" 1500 (ship/carrier-total-cost carrier1 10))
;; EcoFreight 10kg: 300 + 50*10 = 800
(assert-eq "ship/carrier-total-cost EcoFreight 10kg" 800 (ship/carrier-total-cost carrier2 10))

;; Carriers for weight: active AND max-weight >= weight
;; weight=40: FastShip(max 50, active), EcoFreight(max 100, active) = 2
(assert-eq "ship/carriers-for-weight 40" 2 (count (ship/carriers-for-weight carriers 40)))
;; weight=60: only EcoFreight(max 100) = 1
(assert-eq "ship/carriers-for-weight 60" 1 (count (ship/carriers-for-weight carriers 60)))
;; weight=200: none
(assert-eq "ship/carriers-for-weight 200" 0 (count (ship/carriers-for-weight carriers 200)))

;; Cheapest carrier for 10kg:
;; FastShip=1500, EcoFreight=800 -> EcoFreight
(assert-eq "ship/cheapest-carrier 10kg" "EcoFreight" (ship/carrier-name (ship/cheapest-carrier carriers 10)))
;; For 60kg: only EcoFreight eligible (max 50 for FastShip)
(assert-eq "ship/cheapest-carrier 60kg" "EcoFreight" (ship/carrier-name (ship/cheapest-carrier carriers 60)))
;; For 200kg: nil
(assert-eq "ship/cheapest-carrier 200kg" nil (ship/cheapest-carrier carriers 200))

;; Zone surcharge: cost * surcharge-pct / 100
;; Local (0%): any cost -> 0
(assert-eq "ship/zone-surcharge local" 0 (ship/zone-surcharge zone1 1000))
;; Remote (20%): 1000 * 20 / 100 = 200
(assert-eq "ship/zone-surcharge remote" 200 (ship/zone-surcharge zone2 1000))

;; Create shipment
(let [s (ship/create-shipment 10 order1 carrier1 1 5 zone1)]
  ;; cost = carrier-total-cost(carrier1, 5) + zone-surcharge(zone1, cost)
  ;; = (500 + 100*5) + 0 = 1000
  (assert-eq "ship/create-shipment cost local" 1000 (ship/shipment-shipping-cost s))
  (assert-eq "ship/create-shipment status" "pending" (ship/shipment-status s))
  (assert-eq "ship/create-shipment weight" 5 (ship/shipment-weight-kg s)))

(let [s (ship/create-shipment 11 order1 carrier2 1 10 zone2)]
  ;; cost = carrier-total-cost(carrier2, 10) + zone-surcharge(zone2, cost)
  ;; = (300 + 50*10) + quot(800*20/100) = 800 + 160 = 960
  (assert-eq "ship/create-shipment cost remote" 960 (ship/shipment-shipping-cost s)))

;; Ship/deliver transitions
(let [shipped (ship/ship-shipment shipment3 4000)]
  (assert-eq "ship/ship-shipment status" "shipped" (ship/shipment-status shipped)))

(let [delivered (ship/deliver-shipment shipment2 5000)]
  (assert-eq "ship/deliver-shipment status" "delivered" (ship/shipment-status delivered))
  (assert-eq "ship/deliver-shipment delivered-at" 5000 (ship/shipment-delivered-at delivered)))

;; Cancel: only pending
(let [cancelled (ship/cancel-shipment shipment3)]
  (assert-eq "ship/cancel-shipment pending" "cancelled" (ship/shipment-status cancelled)))
;; Cancel shipped: no change
(let [same (ship/cancel-shipment shipment2)]
  (assert-eq "ship/cancel-shipment shipped no change" "shipped" (ship/shipment-status same)))

;; Shipment queries
(assert-eq "ship/find-shipment-by-id 1" 1 (ship/shipment-id (ship/find-shipment-by-id shipments 1)))
(assert-eq "ship/shipments-for-order 1001" 1 (count (ship/shipments-for-order shipments 1001)))
(assert-eq "ship/shipments-by-carrier 1" 2 (count (ship/shipments-by-carrier shipments 1)))
(assert-eq "ship/shipments-by-status pending" 1 (count (ship/shipments-by-status shipments "pending")))
(assert-eq "ship/pending-shipments" 1 (count (ship/pending-shipments shipments)))
(assert-eq "ship/delivered-shipments" 1 (count (ship/delivered-shipments shipments)))
(assert-true "ship/shipment-delivered? s1" (ship/shipment-delivered? shipment1))
(assert-false "ship/shipment-delivered? s2" (ship/shipment-delivered? shipment2))

;; Revenue: sum of shipping-cost for delivered only = 1000
(assert-eq "ship/total-shipping-revenue" 1000 (ship/total-shipping-revenue shipments))

;; Avg shipping cost (non-cancelled): (1000+800+800)/3 = 866
(assert-eq "ship/avg-shipping-cost" 866 (ship/avg-shipping-cost shipments))

;; Carrier revenue: only delivered for carrier 1 = 1000
(assert-eq "ship/carrier-revenue carrier1" 1000 (ship/carrier-revenue shipments 1))
(assert-eq "ship/carrier-revenue carrier2" 0 (ship/carrier-revenue shipments 2))

;; Carrier shipment count
(assert-eq "ship/carrier-shipment-count carrier1" 2 (ship/carrier-shipment-count shipments 1))
(assert-eq "ship/carrier-shipment-count carrier2" 1 (ship/carrier-shipment-count shipments 2))

;; Shipping cost for order
(assert-eq "ship/shipping-cost-for-order 1001" 1000 (ship/shipping-cost-for-order shipments 1001))
(assert-eq "ship/shipping-cost-for-order 1002" 800 (ship/shipping-cost-for-order shipments 1002))

;; Order fully shipped? (has non-cancelled shipments)
(assert-true "ship/order-fully-shipped? order1" (ship/order-fully-shipped? shipments order1))
;; Order 4 has no shipments
(assert-false "ship/order-fully-shipped? order4" (ship/order-fully-shipped? shipments order4))

;; Unshipped orders: order4 has no shipments at all
(assert-eq "ship/unshipped-orders" 1 (count (ship/unshipped-orders shipments orders)))

;; Warehouse shipment count
(assert-eq "ship/warehouse-shipment-count wh1" 2 (ship/warehouse-shipment-count shipments 1))
(assert-eq "ship/warehouse-shipment-count wh2" 1 (ship/warehouse-shipment-count shipments 2))

;; Set tracking
(let [s (ship/set-tracking-number shipment3 "NEWTRK")]
  (assert-eq "ship/set-tracking-number" "NEWTRK" (ship/shipment-tracking-number s)))

;; Delivery time: shipment1 delivered-at(3000) - created-at(1000) = 2000 seconds
(assert-eq "ship/delivery-time-seconds s1" 2000 (ship/delivery-time-seconds shipment1))
;; Days: quot(2000, 86400) = 0
(assert-eq "ship/delivery-time-days s1" 0 (ship/delivery-time-days shipment1))
;; Not delivered -> 0
(assert-eq "ship/delivery-time-seconds s2" 0 (ship/delivery-time-seconds shipment2))

;; Avg delivery days: only 1 delivered, days=0 -> 0
(assert-eq "ship/avg-delivery-time-days" 0 (ship/avg-delivery-time-days shipments))

;; Fastest/slowest delivery (only 1 delivered)
(assert-eq "ship/fastest-delivery" 1 (ship/shipment-id (ship/fastest-delivery shipments)))
(assert-eq "ship/slowest-delivery" 1 (ship/shipment-id (ship/slowest-delivery shipments)))

;; Total weight shipped (delivered only): 5
(assert-eq "ship/total-weight-shipped" 5 (ship/total-weight-shipped shipments))

;; Avg shipment weight (non-cancelled): (5+10+3)/3 = 6
(assert-eq "ship/avg-shipment-weight" 6 (ship/avg-shipment-weight shipments))

;; Heaviest: 10kg (shipment2)
(assert-eq "ship/heaviest-shipment" 2 (ship/shipment-id (ship/heaviest-shipment shipments)))
;; Lightest (non-cancelled): 3kg (shipment3)
(assert-eq "ship/lightest-shipment" 3 (ship/shipment-id (ship/lightest-shipment shipments)))

;; Cost per kg: shipment1 = 1000/5 = 200
(assert-eq "ship/cost-per-kg s1" 200 (ship/cost-per-kg shipment1))
;; Shipment2: 800/10 = 80
(assert-eq "ship/cost-per-kg s2" 80 (ship/cost-per-kg shipment2))

;; On-time: shipment1 delivered, elapsed=2000sec, max-days=1 -> max-sec=86400
;; 2000 <= 86400 -> on time
(assert-eq "ship/carrier-on-time-count carrier1 1day" 1 (ship/carrier-on-time-count shipments 1 1))
(assert-eq "ship/carrier-on-time-pct carrier1 1day" 100 (ship/carrier-on-time-pct shipments 1 1))


;; ===========================================================================
;; BILLING TESTS
;; ===========================================================================

(println "--- BILLING ---")

;; Create invoice from order
(let [i (bill/create-invoice 10 order1 cust1 5000 7000)]
  (assert-eq "bill/create-invoice total" 8415 (bill/invoice-total i))
  (assert-eq "bill/create-invoice status" "unpaid" (bill/invoice-status i))
  (assert-eq "bill/create-invoice customer-id" 1 (bill/invoice-customer-id i))
  (assert-eq "bill/create-invoice order-id" 1001 (bill/invoice-order-id i)))

;; Find invoice
(assert-eq "bill/find-invoice-by-id 1" 1 (bill/invoice-id (bill/find-invoice-by-id invoices 1)))
(assert-eq "bill/find-invoice-by-id 99" nil (bill/find-invoice-by-id invoices 99))

;; Invoices for customer
(assert-eq "bill/invoices-for-customer 1" 2 (count (bill/invoices-for-customer invoices 1)))
(assert-eq "bill/invoices-for-customer 2" 1 (count (bill/invoices-for-customer invoices 2)))
(assert-eq "bill/invoices-for-customer 3" 1 (count (bill/invoices-for-customer invoices 3)))

;; Invoices for order
(assert-eq "bill/invoices-for-order 1" 1 (count (bill/invoices-for-order invoices 1)))

;; Status-based queries
(assert-eq "bill/unpaid-invoices count" 2 (count (bill/unpaid-invoices invoices)))
(assert-eq "bill/paid-invoices count" 2 (count (bill/paid-invoices invoices)))

;; Overdue: unpaid AND due-at < now; now=5500
;; inv3: unpaid, due=5000 < 5500 -> overdue
;; inv4: unpaid, due=6000 > 5500 -> not overdue
(assert-eq "bill/overdue-invoices now=5500" 1 (count (bill/overdue-invoices invoices 5500)))
;; now=7000: both unpaid overdue
(assert-eq "bill/overdue-invoices now=7000" 2 (count (bill/overdue-invoices invoices 7000)))

;; Mark paid
(let [paid (bill/mark-invoice-paid inv3 6000)]
  (assert-eq "bill/mark-invoice-paid status" "paid" (bill/invoice-status paid))
  (assert-eq "bill/mark-invoice-paid paid-at" 6000 (bill/invoice-paid-at paid)))

;; Invoice age: (now - issued) / 86400
;; inv1: (5000 - 1000) / 86400 = 0
(assert-eq "bill/invoice-age-days inv1 now=5000" 0 (bill/invoice-age-days inv1 5000))
;; inv1: (100000 - 1000) / 86400 = 1
(assert-eq "bill/invoice-age-days inv1 now=100000" 1 (bill/invoice-age-days inv1 100000))

;; Create payment
(let [p (bill/create-payment 10 3 4675 "card" 5000)]
  (assert-eq "bill/create-payment amount" 4675 (bill/payment-amount p))
  (assert-eq "bill/create-payment status" "completed" (bill/payment-status p))
  (assert-eq "bill/create-payment method" "card" (bill/payment-method p)))

;; Find payment
(assert-eq "bill/find-payment-by-id 1" 1 (bill/payment-id (bill/find-payment-by-id payments 1)))

;; Payments for invoice
(assert-eq "bill/payments-for-invoice inv1" 1 (count (bill/payments-for-invoice payments 1)))
(assert-eq "bill/payments-for-invoice inv2" 2 (count (bill/payments-for-invoice payments 2)))

;; Total payments for invoice: inv2 = 10000 + 4775 = 14775
(assert-eq "bill/total-payments-for-invoice inv2" 14775 (bill/total-payments-for-invoice payments 2))
(assert-eq "bill/total-payments-for-invoice inv1" 8415 (bill/total-payments-for-invoice payments 1))

;; Invoice balance: total - paid, min 0
;; inv1: 8415 - 8415 = 0
(assert-eq "bill/invoice-balance inv1" 0 (bill/invoice-balance inv1 payments))
;; inv2: 14775 - 14775 = 0
(assert-eq "bill/invoice-balance inv2" 0 (bill/invoice-balance inv2 payments))
;; inv3: 4675 - 0 = 4675
(assert-eq "bill/invoice-balance inv3" 4675 (bill/invoice-balance inv3 payments))
;; inv4: 20700 - 0 = 20700
(assert-eq "bill/invoice-balance inv4" 20700 (bill/invoice-balance inv4 payments))

;; Fully paid?
(assert-true "bill/invoice-fully-paid? inv1" (bill/invoice-fully-paid? inv1 payments))
(assert-true "bill/invoice-fully-paid? inv2" (bill/invoice-fully-paid? inv2 payments))
(assert-false "bill/invoice-fully-paid? inv3" (bill/invoice-fully-paid? inv3 payments))

;; Payments by method
(assert-eq "bill/payments-by-method card" 2 (count (bill/payments-by-method payments "card")))
(assert-eq "bill/payments-by-method bank" 1 (count (bill/payments-by-method payments "bank")))

;; Refund payment
(let [refunded (bill/refund-payment pay1)]
  (assert-eq "bill/refund-payment status" "refunded" (bill/payment-status refunded)))

;; Credit notes
(assert-eq "bill/credits-for-customer 1" 1 (count (bill/credits-for-customer credit-notes 1)))
(assert-eq "bill/total-credits-for-customer 1" 500 (bill/total-credits-for-customer credit-notes 1))
(assert-eq "bill/total-credits-for-customer 2" 0 (bill/total-credits-for-customer credit-notes 2))

;; Revenue collected: sum of completed payments = 8415 + 10000 + 4775 = 23190
(assert-eq "bill/total-revenue-collected" 23190 (bill/total-revenue-collected payments))

;; Total outstanding: sum of balance for unpaid invoices
;; unpaid: inv3(4675), inv4(20700) -> balances 4675 + 20700 = 25375
(assert-eq "bill/total-outstanding" 25375 (bill/total-outstanding invoices payments))

;; Customer total billed: customer 1 has inv1(8415) + inv3(4675) = 13090
(assert-eq "bill/customer-total-billed cust1" 13090 (bill/customer-total-billed invoices 1))
(assert-eq "bill/customer-total-billed cust2" 14775 (bill/customer-total-billed invoices 2))
(assert-eq "bill/customer-total-billed cust3" 20700 (bill/customer-total-billed invoices 3))

;; Customer total paid: customer 1 has pay1(8415) for inv1 = 8415
(assert-eq "bill/customer-total-paid cust1" 8415 (bill/customer-total-paid payments invoices 1))
;; customer 2 has pay2+pay3 for inv2 = 14775
(assert-eq "bill/customer-total-paid cust2" 14775 (bill/customer-total-paid payments invoices 2))

;; Revenue by method
(let [rbm (bill/revenue-by-method payments)]
  ;; card: 8415 + 4775 = 13190
  (assert-eq "bill/revenue-by-method card" 13190 (get rbm "card"))
  ;; bank: 10000
  (assert-eq "bill/revenue-by-method bank" 10000 (get rbm "bank")))

;; Avg days to pay: paid invoices are inv1 and inv2
;; inv1: (2000-1000)/86400 = 0, inv2: (3500-2000)/86400 = 0
;; avg = (0+0)/2 = 0
(assert-eq "bill/avg-days-to-pay" 0 (bill/avg-days-to-pay invoices))

;; Collection rate: collected * 100 / total-invoiced
;; total-invoiced = 8415+14775+4675+20700 = 48565
;; collected = 23190
;; rate = 23190*100/48565 = 47
(assert-eq "bill/collection-rate-pct" 47 (bill/collection-rate-pct invoices payments))

;; Validation
(assert-true "bill/valid-invoice? inv1" (bill/valid-invoice? inv1))
(assert-true "bill/valid-payment? pay1" (bill/valid-payment? pay1))
(assert-true "bill/valid-credit-note? cn1" (bill/valid-credit-note? cn1))

;; Invoices in period
(assert-eq "bill/invoices-in-period 1000-2000" 2 (count (bill/invoices-in-period invoices 1000 2000)))
(assert-eq "bill/invoices-in-period 1000-4000" 4 (count (bill/invoices-in-period invoices 1000 4000)))

;; Payments in period
(assert-eq "bill/payments-in-period 2000-3000" 2 (count (bill/payments-in-period payments 2000 3000)))


;; ===========================================================================
;; PROCUREMENT TESTS
;; ===========================================================================

(println "--- PROCUREMENT ---")

;; PO Line total: qty * unit-cost
(assert-eq "proc/poline-total line1" 4000 (proc/poline-total poline1))
(assert-eq "proc/poline-total line2" 2000 (proc/poline-total poline2))
(assert-eq "proc/poline-total line3" 4500 (proc/poline-total poline3))

;; PO total from lines
(assert-eq "proc/po-total-from-lines all" 10500 (proc/po-total-from-lines po-lines))
(assert-eq "proc/po-total-from-lines po1 lines" 6000 (proc/po-total-from-lines (proc/lines-for-po po-lines 1)))

;; Lines for PO
(assert-eq "proc/lines-for-po 1" 2 (count (proc/lines-for-po po-lines 1)))
(assert-eq "proc/lines-for-po 2" 1 (count (proc/lines-for-po po-lines 2)))

;; PO line count
(assert-eq "proc/po-line-count po1" 2 (proc/po-line-count po-lines 1))
(assert-eq "proc/po-line-count po2" 1 (proc/po-line-count po-lines 2))

;; Lines for product
(assert-eq "proc/lines-for-product 1" 1 (count (proc/lines-for-product po-lines 1)))
(assert-eq "proc/lines-for-product 5" 1 (count (proc/lines-for-product po-lines 5)))

;; Total quantity for product
(assert-eq "proc/total-quantity-for-product 1" 10 (proc/total-quantity-for-product po-lines 1))
(assert-eq "proc/total-quantity-for-product 3" 4 (proc/total-quantity-for-product po-lines 3))
(assert-eq "proc/total-quantity-for-product 5" 10 (proc/total-quantity-for-product po-lines 5))

;; Total spend for product
(assert-eq "proc/total-spend-for-product 1" 4000 (proc/total-spend-for-product po-lines 1))
(assert-eq "proc/total-spend-for-product 3" 2000 (proc/total-spend-for-product po-lines 3))

;; Avg unit cost for product: total-spend / total-qty
;; prod 1: 4000 / 10 = 400
(assert-eq "proc/avg-unit-cost-for-product 1" 400 (proc/avg-unit-cost-for-product po-lines 1))
(assert-eq "proc/avg-unit-cost-for-product 3" 500 (proc/avg-unit-cost-for-product po-lines 3))

;; Unique products
(assert-eq "proc/unique-products-in-lines" 3 (count (proc/unique-products-in-lines po-lines)))

;; Create purchase order
(let [new-lines [(proc/->POLine 99 1 5 500)]
      po (proc/create-purchase-order 99 1 new-lines 1000 5000)]
  (assert-eq "proc/create-purchase-order status" "pending" (proc/purchaseorder-status po))
  (assert-eq "proc/create-purchase-order total" 2500 (proc/purchaseorder-total po)))

;; Find PO
(assert-eq "proc/find-po-by-id 1" 1 (proc/purchaseorder-id (proc/find-po-by-id purchase-orders 1)))
(assert-eq "proc/find-po-by-id 99" nil (proc/find-po-by-id purchase-orders 99))

;; POs for supplier
(assert-eq "proc/pos-for-supplier 1" 1 (count (proc/pos-for-supplier purchase-orders 1)))
(assert-eq "proc/pos-for-supplier 2" 1 (count (proc/pos-for-supplier purchase-orders 2)))

;; POs by status
(assert-eq "proc/pos-by-status completed" 1 (count (proc/pos-by-status purchase-orders "completed")))
(assert-eq "proc/pos-by-status pending" 1 (count (proc/pos-by-status purchase-orders "pending")))
(assert-eq "proc/pending-pos" 1 (count (proc/pending-pos purchase-orders)))
(assert-eq "proc/completed-pos" 1 (count (proc/completed-pos purchase-orders)))

;; Approve PO (only from pending)
(let [approved (proc/approve-po po2)]
  (assert-eq "proc/approve-po status" "approved" (proc/purchaseorder-status approved)))
;; Approve completed -> no change
(let [same (proc/approve-po po1)]
  (assert-eq "proc/approve-po completed no change" "completed" (proc/purchaseorder-status same)))

;; Complete PO
(let [completed (proc/complete-po po2)]
  (assert-eq "proc/complete-po status" "completed" (proc/purchaseorder-status completed)))

;; Cancel PO (only from pending)
(let [cancelled (proc/cancel-po po2)]
  (assert-eq "proc/cancel-po status" "cancelled" (proc/purchaseorder-status cancelled)))

;; PO open/closed
(assert-false "proc/po-open? po1 completed" (proc/po-open? po1))
(assert-true "proc/po-open? po2 pending" (proc/po-open? po2))
(assert-true "proc/po-closed? po1" (proc/po-closed? po1))
(assert-false "proc/po-closed? po2" (proc/po-closed? po2))

;; Expected lead days: (expected - created) / 86400
;; po1: (5000-1000)/86400 = 0
(assert-eq "proc/po-expected-lead-days po1" 0 (proc/po-expected-lead-days po1))

;; Validation
(assert-true "proc/valid-po? po1" (proc/valid-po? po1))
(assert-true "proc/valid-poline? poline1" (proc/valid-poline? poline1))
(assert-true "proc/all-lines-valid?" (proc/all-lines-valid? po-lines))

;; Goods receipt
(let [r (proc/create-goods-receipt 10 1 1 5000 po-lines)]
  (assert-eq "proc/create-goods-receipt po-id" 1 (proc/goodsreceipt-po-id r))
  (assert-eq "proc/create-goods-receipt line-count" 2 (proc/goodsreceipt-line-count r)))

(assert-eq "proc/receipts-for-po 1" 1 (count (proc/receipts-for-po goods-receipts 1)))
(assert-eq "proc/receipts-for-warehouse 1" 1 (count (proc/receipts-for-warehouse goods-receipts 1)))
(assert-eq "proc/find-receipt-by-id 1" 1 (proc/goodsreceipt-id (proc/find-receipt-by-id goods-receipts 1)))

;; POs in period
(assert-eq "proc/pos-in-period 1000-3000" 2 (count (proc/pos-in-period purchase-orders 1000 3000)))
(assert-eq "proc/pos-in-period 2000-3000" 1 (count (proc/pos-in-period purchase-orders 2000 3000)))


;; ===========================================================================
;; PROMOTIONS TESTS
;; ===========================================================================

(println "--- PROMOTIONS ---")

;; Find campaign
(assert-eq "promo/find-campaign-by-id 1" "Summer Sale" (promo/campaign-name (promo/find-campaign-by-id campaigns 1)))
(assert-eq "promo/find-campaign-by-id 99" nil (promo/find-campaign-by-id campaigns 99))

;; Campaign active: status="active" AND start <= now <= end
;; campaign1: active, 1000-5000, now=3000 -> true
(assert-true "promo/campaign-active? c1 now=3000" (promo/campaign-active? campaign1 3000))
;; now=6000: past end -> false
(assert-false "promo/campaign-active? c1 now=6000" (promo/campaign-active? campaign1 6000))
;; now=500: before start -> false
(assert-false "promo/campaign-active? c1 now=500" (promo/campaign-active? campaign1 500))

;; Active campaigns at now=3000: both are in range
(assert-eq "promo/active-campaigns now=3000" 2 (count (promo/active-campaigns campaigns 3000)))
;; at now=5500: only campaign2 (2000-6000 range)
(assert-eq "promo/active-campaigns now=5500" 1 (count (promo/active-campaigns campaigns 5500)))

;; Activate/deactivate
(let [inactive (promo/deactivate-campaign campaign1)]
  (assert-eq "promo/deactivate-campaign" "inactive" (promo/campaign-status inactive)))
(let [active (promo/activate-campaign (promo/deactivate-campaign campaign1))]
  (assert-eq "promo/activate-campaign" "active" (promo/campaign-status active)))

;; Campaign duration: (end - start) / 86400
;; campaign1: (5000-1000)/86400 = 0
(assert-eq "promo/campaign-duration-days c1" 0 (promo/campaign-duration-days campaign1))

;; Find coupon by code
(assert-eq "promo/find-coupon-by-code SUMMER10" 1 (promo/coupon-id (promo/find-coupon-by-code coupons "SUMMER10")))
(assert-eq "promo/find-coupon-by-code VIP20" 3 (promo/coupon-id (promo/find-coupon-by-code coupons "VIP20")))
(assert-eq "promo/find-coupon-by-code NOPE" nil (promo/find-coupon-by-code coupons "NOPE"))

;; Coupons for campaign
(assert-eq "promo/coupons-for-campaign 1" 2 (count (promo/coupons-for-campaign coupons 1)))
(assert-eq "promo/coupons-for-campaign 2" 1 (count (promo/coupons-for-campaign coupons 2)))

;; Coupon valid: current-uses < max-uses
(assert-true "promo/coupon-valid? coupon1" (promo/coupon-valid? coupon1))   ;; 30 < 100
(assert-false "promo/coupon-valid? coupon2" (promo/coupon-valid? coupon2))  ;; 50 = 50
(assert-true "promo/coupon-valid? coupon3" (promo/coupon-valid? coupon3))   ;; 5 < 20

;; Use coupon
(let [used (promo/use-coupon coupon1)]
  (assert-eq "promo/use-coupon increments uses" 31 (promo/coupon-current-uses used)))
;; Use exhausted coupon: no change
(let [same (promo/use-coupon coupon2)]
  (assert-eq "promo/use-coupon exhausted" 50 (promo/coupon-current-uses same)))

;; Coupon usage pct: current*100/max
;; coupon1: 30*100/100 = 30
(assert-eq "promo/coupon-usage-pct coupon1" 30 (promo/coupon-usage-pct coupon1))
;; coupon2: 50*100/50 = 100
(assert-eq "promo/coupon-usage-pct coupon2" 100 (promo/coupon-usage-pct coupon2))
;; coupon3: 5*100/20 = 25
(assert-eq "promo/coupon-usage-pct coupon3" 25 (promo/coupon-usage-pct coupon3))

;; Coupon discount amount
;; coupon1 (percentage 10%): 10000 * 10 / 100 = 1000
(assert-eq "promo/coupon-discount-amount coupon1 10000" 1000 (promo/coupon-discount-amount coupon1 10000))
;; coupon2 (fixed 500): always 500
(assert-eq "promo/coupon-discount-amount coupon2 10000" 500 (promo/coupon-discount-amount coupon2 10000))
;; coupon3 (percentage 20%): 10000 * 20 / 100 = 2000
(assert-eq "promo/coupon-discount-amount coupon3 10000" 2000 (promo/coupon-discount-amount coupon3 10000))
;; Cap at order-total: coupon3 on order of 500: quot(500*20/100)=100
(assert-eq "promo/coupon-discount-amount coupon3 500" 100 (promo/coupon-discount-amount coupon3 500))

;; Best coupon for order 10000: valid coupons are coupon1 and coupon3
;; coupon1: 1000, coupon3: 2000 -> coupon3 wins
(assert-eq "promo/best-coupon 10000" 3 (promo/coupon-id (promo/best-coupon coupons 10000)))

;; Remaining uses
(assert-eq "promo/coupon-remaining-uses coupon1" 70 (promo/coupon-remaining-uses coupon1))
(assert-eq "promo/coupon-remaining-uses coupon2" 0 (promo/coupon-remaining-uses coupon2))
(assert-eq "promo/coupon-remaining-uses coupon3" 15 (promo/coupon-remaining-uses coupon3))

;; Exhausted coupons
(assert-eq "promo/exhausted-coupons" 1 (count (promo/exhausted-coupons coupons)))
(assert-eq "promo/valid-coupons" 2 (count (promo/valid-coupons coupons)))

;; Coupon exhausted?
(assert-false "promo/coupon-exhausted? coupon1" (promo/coupon-exhausted? coupon1))
(assert-true "promo/coupon-exhausted? coupon2" (promo/coupon-exhausted? coupon2))

;; Coupon applicable: valid AND order-total >= min-order
;; coupon1: valid, min=5000, order=10000 -> true
(assert-true "promo/coupon-applicable? coupon1 10000" (promo/coupon-applicable? coupon1 10000))
;; coupon1: valid, min=5000, order=3000 -> false
(assert-false "promo/coupon-applicable? coupon1 3000" (promo/coupon-applicable? coupon1 3000))
;; coupon2: not valid -> false
(assert-false "promo/coupon-applicable? coupon2 10000" (promo/coupon-applicable? coupon2 10000))

;; Applicable coupons for 10000: coupon1(valid, min=5000<=10000), coupon3(valid, min=10000<=10000)
(assert-eq "promo/applicable-coupons 10000" 2 (count (promo/applicable-coupons coupons 10000)))

;; Promotion rules
(assert-eq "promo/find-rules-for-campaign 1" 1 (count (promo/find-rules-for-campaign promo-rules 1)))
(assert-eq "promo/find-rules-for-campaign 2" 1 (count (promo/find-rules-for-campaign promo-rules 2)))

;; Tier qualifies
(assert-true "promo/tier-qualifies? gold gold" (promo/tier-qualifies? "gold" "gold"))
(assert-true "promo/tier-qualifies? gold silver" (promo/tier-qualifies? "gold" "silver"))
(assert-false "promo/tier-qualifies? bronze gold" (promo/tier-qualifies? "bronze" "gold"))
(assert-true "promo/tier-qualifies? any empty" (promo/tier-qualifies? "bronze" ""))

;; Customer eligible
(assert-true "promo/customer-eligible? rule1 cust1" (promo/customer-eligible? rule1 cust1))   ;; min-tier=""
(assert-true "promo/customer-eligible? rule2 cust1" (promo/customer-eligible? rule2 cust1))   ;; gold >= gold
(assert-false "promo/customer-eligible? rule2 cust2" (promo/customer-eligible? rule2 cust2))  ;; silver < gold

;; Campaign coupon count
(assert-eq "promo/campaign-coupon-count 1" 2 (promo/campaign-coupon-count coupons 1))
(assert-eq "promo/campaign-coupon-count 2" 1 (promo/campaign-coupon-count coupons 2))

;; Campaign total uses: sum of current-uses for campaign coupons
;; campaign 1: 30 + 50 = 80
(assert-eq "promo/campaign-total-uses 1" 80 (promo/campaign-total-uses coupons 1))
(assert-eq "promo/campaign-total-uses 2" 5 (promo/campaign-total-uses coupons 2))


;; ===========================================================================
;; EMPLOYEES TESTS
;; ===========================================================================

(println "--- EMPLOYEES ---")

;; Find employee
(assert-eq "emp/find-employee-by-id 1" "Alice" (emp/employee-name (emp/find-employee-by-id employees 1)))
(assert-eq "emp/find-employee-by-id 99" nil (emp/find-employee-by-id employees 99))

;; Active employees
(assert-eq "emp/active-employees" 2 (count (emp/active-employees employees)))

;; By department
(assert-eq "emp/employees-by-department sales" 2 (count (emp/employees-by-department employees "sales")))
(assert-eq "emp/employees-by-department support" 1 (count (emp/employees-by-department employees "support")))

;; By role
(assert-eq "emp/employees-by-role rep" 2 (count (emp/employees-by-role employees "rep")))
(assert-eq "emp/employees-by-role manager" 1 (count (emp/employees-by-role employees "manager")))

;; Tenure: (now - hire-date) / 86400
;; emp1: (10000 - 100) / 86400 = 0
(assert-eq "emp/employee-tenure-days emp1 now=10000" 0 (emp/employee-tenure-days emp1 10000))
;; emp1: (100000 - 100) / 86400 = 1
(assert-eq "emp/employee-tenure-days emp1 now=100000" 1 (emp/employee-tenure-days emp1 100000))

;; Commission rate
;; emp1, cat1: 5%
(assert-eq "emp/commission-rate emp1 cat1" 5 (emp/commission-rate commission-rules 1 1))
;; emp1, cat2: 8%
(assert-eq "emp/commission-rate emp1 cat2" 8 (emp/commission-rate commission-rules 1 2))
;; emp2, cat1: 3%
(assert-eq "emp/commission-rate emp2 cat1" 3 (emp/commission-rate commission-rules 2 1))
;; emp1, cat3: 0 (no rule)
(assert-eq "emp/commission-rate emp1 cat3" 0 (emp/commission-rate commission-rules 1 3))

;; Order commission: for order1 (lines: prod1 x5=6000, prod2 x2=3000)
;; emp1: prod1 cat=1 rate=5%: quot(5*6000/100)=300, prod2 cat=1 rate=5%: quot(5*3000/100)=150
;; total = 450
(assert-eq "emp/order-commission emp1 order1" 450 (emp/order-commission commission-rules 1 order1 products))

;; emp2: prod1 cat=1 rate=3%: quot(3*6000/100)=180, prod2 cat=1 rate=3%: quot(3*3000/100)=90
;; total = 270
(assert-eq "emp/order-commission emp2 order1" 270 (emp/order-commission commission-rules 2 order1 products))

;; Total commission across all orders for emp1:
;; order1: 450 (above)
;; order2: prod3 cat=2 rate=8%: quot(8*4500/100)=360, prod5 cat=3 rate=0%: 0 -> 360
;; order3: prod6 cat=3 rate=0%: 0, prod4 cat=2 rate=8%: quot(8*2250/100)=180 -> 180
;; order4: prod1 cat=1 rate=5%: quot(5*2400/100)=120 -> 120
;; total = 450 + 360 + 180 + 120 = 1110
(assert-eq "emp/total-commission emp1" 1110 (emp/total-commission commission-rules 1 orders products))

;; Top earner
(let [top (emp/top-earner commission-rules employees orders products)]
  (assert-eq "emp/top-earner" "Alice" (emp/employee-name top)))

;; Sales targets
(assert-eq "emp/targets-for-employee 1" 1 (count (emp/targets-for-employee sales-targets 1)))
(assert-eq "emp/targets-for-employee 2" 1 (count (emp/targets-for-employee sales-targets 2)))

;; Target for period
(let [t (emp/target-for-period sales-targets 1 "2024-Q1")]
  (assert-eq "emp/target-for-period emp1 Q1 target" 50000 (emp/salestarget-target-amount t))
  (assert-eq "emp/target-for-period emp1 Q1 actual" 35000 (emp/salestarget-actual-amount t)))

;; Target achievement pct: actual*100/target
;; st1: 35000*100/50000 = 70
(assert-eq "emp/target-achievement-pct st1" 70 (emp/target-achievement-pct st1))
;; st2: 90000*100/80000 = 112
(assert-eq "emp/target-achievement-pct st2" 112 (emp/target-achievement-pct st2))

;; On target?
(assert-false "emp/on-target? st1" (emp/on-target? st1))
(assert-true "emp/on-target? st2" (emp/on-target? st2))


;; ===========================================================================
;; ANALYTICS TESTS
;; ===========================================================================

(println "--- ANALYTICS ---")

;; Make period metric
(let [m (analytics/make-period-metric "2024-Q4" "revenue" 70000)]
  (assert-eq "analytics/make-period-metric period" "2024-Q4" (analytics/periodmetric-period m))
  (assert-eq "analytics/make-period-metric name" "revenue" (analytics/periodmetric-metric-name m))
  (assert-eq "analytics/make-period-metric value" 70000 (analytics/periodmetric-value m)))

;; Metrics for period
(assert-eq "analytics/metrics-for-period Q1" 2 (count (analytics/metrics-for-period metrics "2024-Q1")))
(assert-eq "analytics/metrics-for-period Q2" 2 (count (analytics/metrics-for-period metrics "2024-Q2")))

;; Metric values: sorted by period, returns values
;; revenue: Q1=50000, Q2=65000, Q3=55000
(assert-eq "analytics/metric-values revenue" [50000 65000 55000] (analytics/metric-values metrics "revenue"))
(assert-eq "analytics/metric-values order-count" [100 130 110] (analytics/metric-values metrics "order-count"))

;; Latest metric: highest period alphabetically
;; revenue: Q3 is last -> 55000
(let [latest (analytics/latest-metric metrics "revenue")]
  (assert-eq "analytics/latest-metric revenue period" "2024-Q3" (analytics/periodmetric-period latest))
  (assert-eq "analytics/latest-metric revenue value" 55000 (analytics/periodmetric-value latest)))

;; Earliest metric
(let [earliest (analytics/earliest-metric metrics "revenue")]
  (assert-eq "analytics/earliest-metric revenue period" "2024-Q1" (analytics/periodmetric-period earliest))
  (assert-eq "analytics/earliest-metric revenue value" 50000 (analytics/periodmetric-value earliest)))

;; Metric count
(assert-eq "analytics/metric-count revenue" 3 (analytics/metric-count metrics "revenue"))
(assert-eq "analytics/metric-count order-count" 3 (analytics/metric-count metrics "order-count"))
(assert-eq "analytics/metric-count nonexist" 0 (analytics/metric-count metrics "nonexist"))

;; Metric sum: 50000+65000+55000 = 170000
(assert-eq "analytics/metric-sum revenue" 170000 (analytics/metric-sum metrics "revenue"))
;; order-count: 100+130+110 = 340
(assert-eq "analytics/metric-sum order-count" 340 (analytics/metric-sum metrics "order-count"))

;; Metric avg: 170000/3 = 56666
(assert-eq "analytics/metric-avg revenue" 56666 (analytics/metric-avg metrics "revenue"))
;; order-count: 340/3 = 113
(assert-eq "analytics/metric-avg order-count" 113 (analytics/metric-avg metrics "order-count"))

;; Metric max
(assert-eq "analytics/metric-max revenue" 65000 (analytics/metric-max metrics "revenue"))
(assert-eq "analytics/metric-max order-count" 130 (analytics/metric-max metrics "order-count"))

;; Metric min
(assert-eq "analytics/metric-min revenue" 50000 (analytics/metric-min metrics "revenue"))
(assert-eq "analytics/metric-min order-count" 100 (analytics/metric-min metrics "order-count"))

;; Empty metrics
(assert-eq "analytics/metric-max empty" 0 (analytics/metric-max metrics "nonexist"))
(assert-eq "analytics/metric-min empty" 0 (analytics/metric-min metrics "nonexist"))
(assert-eq "analytics/metric-avg empty" 0 (analytics/metric-avg metrics "nonexist"))

;; All metric names
(assert-eq "analytics/all-metric-names" 2 (count (analytics/all-metric-names metrics)))

;; All periods
(assert-eq "analytics/all-periods" 3 (count (analytics/all-periods metrics)))

;; Revenue by period (using actual orders)
(let [periods [[1700000000 1700100000 "P1"] [1700200000 1700300000 "P2"]]
      rbp (analytics/revenue-by-period orders periods)]
  ;; P1: orders 1+2 = 8415+6831 = 15246
  (assert-eq "analytics/revenue-by-period P1" 15246 (analytics/periodmetric-value (first rbp)))
  ;; P2: orders 3+4 = 4161+2508 = 6669
  (assert-eq "analytics/revenue-by-period P2" 6669 (analytics/periodmetric-value (second rbp))))

;; Order count by period
(let [periods [[1700000000 1700100000 "P1"] [1700200000 1700300000 "P2"]]
      ocbp (analytics/order-count-by-period orders periods)]
  (assert-eq "analytics/order-count-by-period P1" 2 (analytics/periodmetric-value (first ocbp)))
  (assert-eq "analytics/order-count-by-period P2" 2 (analytics/periodmetric-value (second ocbp))))


;; ===========================================================================
;; NOTIFICATIONS TESTS
;; ===========================================================================

(println "--- NOTIFICATIONS ---")

;; Find template
(assert-eq "notif/find-template-by-id 1" "order-confirm" (notif/template-name (notif/find-template-by-id templates 1)))
(assert-eq "notif/find-template-by-id 99" nil (notif/find-template-by-id templates 99))
(assert-eq "notif/find-template-by-name order-confirm" 1 (notif/template-id (notif/find-template-by-name templates "order-confirm")))

;; Templates for channel
(assert-eq "notif/templates-for-channel email" 2 (count (notif/templates-for-channel templates "email")))
(assert-eq "notif/templates-for-channel sms" 1 (count (notif/templates-for-channel templates "sms")))

;; Create notification
(let [n (notif/create-notification 10 tmpl1 cust1 1001 "order" 5000)]
  (assert-eq "notif/create-notification status" "pending" (notif/notification-status n))
  (assert-eq "notif/create-notification template-id" 1 (notif/notification-template-id n))
  (assert-eq "notif/create-notification customer-id" 1 (notif/notification-customer-id n)))

;; Send notification
(let [sent (notif/send-notification notif3 3000)]
  (assert-eq "notif/send-notification status" "sent" (notif/notification-status sent))
  (assert-eq "notif/send-notification sent-at" 3000 (notif/notification-sent-at sent)))
;; Send already sent: no change
(let [same (notif/send-notification notif1 5000)]
  (assert-eq "notif/send-notification already sent" "sent" (notif/notification-status same))
  (assert-eq "notif/send-notification preserves sent-at" 1100 (notif/notification-sent-at same)))

;; Fail notification (only from pending)
(let [failed (notif/fail-notification notif3)]
  (assert-eq "notif/fail-notification status" "failed" (notif/notification-status failed)))
;; Fail non-pending: no change
(let [same (notif/fail-notification notif1)]
  (assert-eq "notif/fail-notification already sent" "sent" (notif/notification-status same)))

;; Retry notification (only from failed)
(let [retried (notif/retry-notification notif4)]
  (assert-eq "notif/retry-notification status" "pending" (notif/notification-status retried)))
;; Retry non-failed: no change
(let [same (notif/retry-notification notif3)]
  (assert-eq "notif/retry-notification not failed" "pending" (notif/notification-status same)))

;; Find notification
(assert-eq "notif/find-notification-by-id 1" 1 (notif/notification-id (notif/find-notification-by-id notifications 1)))

;; Notifications for customer
(assert-eq "notif/notifications-for-customer 1" 3 (count (notif/notifications-for-customer notifications 1)))
(assert-eq "notif/notifications-for-customer 2" 1 (count (notif/notifications-for-customer notifications 2)))

;; Notifications by status
(assert-eq "notif/notifications-by-status sent" 2 (count (notif/notifications-by-status notifications "sent")))
(assert-eq "notif/notifications-by-status pending" 1 (count (notif/notifications-by-status notifications "pending")))
(assert-eq "notif/notifications-by-status failed" 1 (count (notif/notifications-by-status notifications "failed")))
(assert-eq "notif/pending-notifications" 1 (count (notif/pending-notifications notifications)))
(assert-eq "notif/sent-notifications" 2 (count (notif/sent-notifications notifications)))

;; Notifications for reference
(assert-eq "notif/notifications-for-reference order 1" 1 (count (notif/notifications-for-reference notifications 1 "order")))
(assert-eq "notif/notifications-for-reference order 2" 1 (count (notif/notifications-for-reference notifications 2 "order")))
(assert-eq "notif/notifications-for-reference shipment 1" 1 (count (notif/notifications-for-reference notifications 1 "shipment")))

;; Preferences
(assert-eq "notif/customer-preferences cust1" 2 (count (notif/customer-preferences preferences 1)))
(assert-eq "notif/customer-preferences cust2" 1 (count (notif/customer-preferences preferences 2)))

;; Channel enabled
(assert-true "notif/channel-enabled? cust1 email" (notif/channel-enabled? preferences 1 "email"))
(assert-false "notif/channel-enabled? cust1 sms" (notif/channel-enabled? preferences 1 "sms"))
(assert-true "notif/channel-enabled? cust2 email" (notif/channel-enabled? preferences 2 "email"))
;; No preference -> defaults to true
(assert-true "notif/channel-enabled? cust2 sms (no pref)" (notif/channel-enabled? preferences 2 "sms"))

;; Set preference (update existing)
(let [updated (notif/set-preference preferences 1 "sms" true)]
  (assert-true "notif/set-preference update" (notif/channel-enabled? updated 1 "sms")))
;; Set preference (add new)
(let [added (notif/set-preference preferences 3 "email" false)]
  (assert-eq "notif/set-preference add" 4 (count added))
  (assert-false "notif/set-preference add check" (notif/channel-enabled? added 3 "email")))

;; Delivery rate: sent / (sent + failed) * 100
;; sent=2, failed=1, total=3 -> 2*100/3 = 66
(assert-eq "notif/delivery-rate-pct" 66 (notif/delivery-rate-pct notifications))


;; ===========================================================================
;; AUDIT TESTS
;; ===========================================================================

(println "--- AUDIT ---")

;; Create audit entry
(let [e (audit/create-audit-entry 10 "order" 5 "create" 1 5000 "test")]
  (assert-eq "audit/create-audit-entry entity-type" "order" (audit/auditentry-entity-type e))
  (assert-eq "audit/create-audit-entry entity-id" 5 (audit/auditentry-entity-id e))
  (assert-eq "audit/create-audit-entry action" "create" (audit/auditentry-action e))
  (assert-eq "audit/create-audit-entry actor-id" 1 (audit/auditentry-actor-id e)))

;; Audit order
(let [e (audit/audit-order 20 order1 1 "create" 5000)]
  (assert-eq "audit/audit-order entity-type" "order" (audit/auditentry-entity-type e))
  (assert-eq "audit/audit-order entity-id" 1001 (audit/auditentry-entity-id e))
  (assert-eq "audit/audit-order detail" "pending" (audit/auditentry-detail e)))

;; Audit shipment
(let [e (audit/audit-shipment 21 shipment1 2 "deliver" 5000)]
  (assert-eq "audit/audit-shipment entity-type" "shipment" (audit/auditentry-entity-type e))
  (assert-eq "audit/audit-shipment entity-id" 1 (audit/auditentry-entity-id e))
  (assert-eq "audit/audit-shipment detail" "delivered" (audit/auditentry-detail e)))

;; Audit product
(let [e (audit/audit-product 22 prod1 1 "update" 5000)]
  (assert-eq "audit/audit-product entity-type" "product" (audit/auditentry-entity-type e))
  (assert-eq "audit/audit-product entity-id" 1 (audit/auditentry-entity-id e))
  (assert-eq "audit/audit-product detail" "Widget A" (audit/auditentry-detail e)))

;; Entries for entity
(assert-eq "audit/entries-for-entity order 1" 2 (count (audit/entries-for-entity audit-entries "order" 1)))
(assert-eq "audit/entries-for-entity shipment 1" 1 (count (audit/entries-for-entity audit-entries "shipment" 1)))
(assert-eq "audit/entries-for-entity invoice 1" 1 (count (audit/entries-for-entity audit-entries "invoice" 1)))
(assert-eq "audit/entries-for-entity order 99" 0 (count (audit/entries-for-entity audit-entries "order" 99)))

;; Entries by actor
(assert-eq "audit/entries-by-actor 1" 3 (count (audit/entries-by-actor audit-entries 1)))
(assert-eq "audit/entries-by-actor 2" 1 (count (audit/entries-by-actor audit-entries 2)))
(assert-eq "audit/entries-by-actor 99" 0 (count (audit/entries-by-actor audit-entries 99)))

;; Entries by action
(assert-eq "audit/entries-by-action create" 3 (count (audit/entries-by-action audit-entries "create")))
(assert-eq "audit/entries-by-action update" 1 (count (audit/entries-by-action audit-entries "update")))

;; Entries in period
(assert-eq "audit/entries-in-period 1000-1500" 4 (count (audit/entries-in-period audit-entries 1000 2000)))
(assert-eq "audit/entries-in-period 1500-2000" 2 (count (audit/entries-in-period audit-entries 1500 2000)))
(assert-eq "audit/entries-in-period 3000-4000" 0 (count (audit/entries-in-period audit-entries 3000 4000)))

;; Entry count by type
(assert-eq "audit/entry-count-by-type order" 2 (audit/entry-count-by-type audit-entries "order"))
(assert-eq "audit/entry-count-by-type shipment" 1 (audit/entry-count-by-type audit-entries "shipment"))
(assert-eq "audit/entry-count-by-type invoice" 1 (audit/entry-count-by-type audit-entries "invoice"))

;; Recent entries (sorted by timestamp desc, take n)
(let [recent (audit/recent-entries audit-entries 2)]
  (assert-eq "audit/recent-entries count" 2 (count recent))
  (assert-eq "audit/recent-entries first ts" 2000 (audit/auditentry-timestamp (first recent))))

;; Actor action count
(assert-eq "audit/actor-action-count 1" 3 (audit/actor-action-count audit-entries 1))
(assert-eq "audit/actor-action-count 2" 1 (audit/actor-action-count audit-entries 2))

;; Entries by entity type
(assert-eq "audit/entries-by-entity-type order" 2 (count (audit/entries-by-entity-type audit-entries "order")))

;; Distinct actors
(assert-eq "audit/distinct-actors count" 2 (count (audit/distinct-actors audit-entries)))

;; Distinct entity types
(assert-eq "audit/distinct-entity-types count" 3 (count (audit/distinct-entity-types audit-entries)))


;; ===========================================================================
;; CROSS-MODULE TESTS
;; ===========================================================================

(println "--- CROSS-MODULE ---")

;; Shipping + Orders: create shipment from order
(let [s (ship/create-shipment 100 order1 carrier2 1 8 zone2)]
  ;; EcoFreight 8kg: 300 + 50*8 = 700
  ;; Remote 20% surcharge: quot(700*20/100) = 140
  ;; Total: 700 + 140 = 840
  (assert-eq "cross: ship from order cost" 840 (ship/shipment-shipping-cost s))
  (assert-eq "cross: ship from order order-id" 1001 (ship/shipment-order-id s)))

;; Billing + Orders: create invoice from order
(let [i (bill/create-invoice 100 order2 cust2 5000 7000)]
  (assert-eq "cross: invoice from order subtotal" 6900 (bill/invoice-subtotal i))
  (assert-eq "cross: invoice from order total" 6831 (bill/invoice-total i))
  (assert-eq "cross: invoice from order cust-id" 2 (bill/invoice-customer-id i)))

;; Employees + Orders + Catalog: commission calculation crosses modules
;; emp2 on order2: prod3(cat=2, no rule for emp2 cat2) -> 0, prod5(cat=3, no rule) -> 0
(assert-eq "cross: emp2 commission order2" 0 (emp/order-commission commission-rules 2 order2 products))
;; emp1 on order2: prod3(cat=2, rate=8%): quot(8*4500/100)=360, prod5(cat=3, rate=0%): 0
(assert-eq "cross: emp1 commission order2" 360 (emp/order-commission commission-rules 1 order2 products))

;; Promotions + Orders + Customers: rule eligibility
;; rule2 requires gold tier + order >= 10000
;; order1 total=8415, cust1=gold -> order < 10000 -> false
(assert-false "cross: rule2 order1 not eligible" (promo/order-eligible? rule2 order1))
;; rule1 requires order >= 5000: order1(8415) -> true
(assert-true "cross: rule1 order1 eligible" (promo/order-eligible? rule1 order1))
(assert-true "cross: rule1 applies cust1 order1" (promo/rule-applies? rule1 cust1 order1))

;; Audit + Orders: audit an order
(let [e (audit/audit-order 200 order1 1 "ship" 5000)]
  (assert-eq "cross: audit order entity-id" 1001 (audit/auditentry-entity-id e)))

;; Notifications + Customers: create notification using customer
(let [n (notif/create-notification 200 tmpl2 cust2 2 "shipment" 5000)]
  (assert-eq "cross: notification customer-id" 2 (notif/notification-customer-id n))
  (assert-eq "cross: notification template-id" 2 (notif/notification-template-id n)))

;; Procurement + Catalog: lines reference product costs
;; The PO lines use unit-costs that may differ from catalog
(assert-eq "cross: poline1 vs catalog cost" 400 (proc/poline-unit-cost poline1))
;; catalog prod1 cost = 500, PO got 400 (discount)

;; Billing + Shipping: total cost of fulfilling an order
;; order1: total=8415, shipping-cost=1000
(let [order-total (ord/order-total order1)
      ship-cost (ship/shipping-cost-for-order shipments 1001)
      all-in (+ order-total ship-cost)]
  (assert-eq "cross: order1 all-in cost" 9415 all-in))


;; ===========================================================================
;; Summary
;; ===========================================================================

(println "")
(println "---")
(let [passes @*pass-count*
      fails @*fail-count*]
  (println (str passes " passed, " fails " failed"))
  (when (> fails 0)
    (System/exit 1)))
