#!/usr/bin/env python3
"""E8 full verification script — Python port of e8-full.verify.clj"""

import sys
import os

sys.path.insert(0, '.')

import catalog as cat
import customers as cust
import inventory as inv
import orders as ord
import reports as rep
import shipping as ship
import billing as bill
import procurement as proc
import promotions as promo
import employees as emp
import analytics
import notifications as notif
import audit

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

pass_count = 0
fail_count = 0


def assert_eq(label, expected, actual):
    global pass_count, fail_count
    if expected == actual:
        pass_count += 1
    else:
        fail_count += 1
        print(f"FAIL: {label}\n  expected: {expected}\n  actual:   {actual}")


def assert_true(label, val):
    assert_eq(label, True, val)


def assert_false(label, val):
    assert_eq(label, False, val)


# ---------------------------------------------------------------------------
# Test Data (from E1 master.verify.clj)
# ---------------------------------------------------------------------------

# Suppliers
sup1 = cat.Supplier(id=1, name="Acme Corp", lead_time_days=7)
sup2 = cat.Supplier(id=2, name="Widget Co", lead_time_days=14)
sup3 = cat.Supplier(id=3, name="Parts R Us", lead_time_days=3)
suppliers = [sup1, sup2, sup3]

# Categories
cat1 = cat.Category(id=1, name="Electronics", tax_rate=0.15)
cat2 = cat.Category(id=2, name="Office", tax_rate=0.08)
cat3 = cat.Category(id=3, name="Industrial", tax_rate=0.12)
categories = [cat1, cat2, cat3]

# Products
prod1 = cat.Product(id=1, name="Widget A", sku="WGT-001", unit_cost=500, unit_price=1200, supplier_id=1, category_id=1, active=True)
prod2 = cat.Product(id=2, name="Gadget B", sku="GDG-002", unit_cost=800, unit_price=1500, supplier_id=1, category_id=1, active=True)
prod3 = cat.Product(id=3, name="Stapler", sku="STP-003", unit_cost=200, unit_price=450, supplier_id=2, category_id=2, active=True)
prod4 = cat.Product(id=4, name="Desk Lamp", sku="DLM-004", unit_cost=350, unit_price=750, supplier_id=2, category_id=2, active=True)
prod5 = cat.Product(id=5, name="Bolt Pack", sku="BLT-005", unit_cost=50, unit_price=120, supplier_id=3, category_id=3, active=True)
prod6 = cat.Product(id=6, name="Gear Set", sku="GRS-006", unit_cost=1200, unit_price=2200, supplier_id=3, category_id=3, active=True)
prod7 = cat.Product(id=7, name="Old Widget", sku="OWG-007", unit_cost=300, unit_price=600, supplier_id=1, category_id=1, active=False)
products = [prod1, prod2, prod3, prod4, prod5, prod6, prod7]

# Warehouses
wh1 = inv.Warehouse(id=1, name="Main DC", location="Chicago", capacity=10000)
wh2 = inv.Warehouse(id=2, name="West Hub", location="Portland", capacity=5000)
warehouses = [wh1, wh2]

# Stock levels
sl_1_1 = inv.StockLevel(warehouse_id=1, product_id=1, quantity=100, min_quantity=20)
sl_1_2 = inv.StockLevel(warehouse_id=1, product_id=2, quantity=50, min_quantity=15)
sl_1_3 = inv.StockLevel(warehouse_id=1, product_id=3, quantity=200, min_quantity=50)
sl_1_4 = inv.StockLevel(warehouse_id=1, product_id=4, quantity=30, min_quantity=10)
sl_1_5 = inv.StockLevel(warehouse_id=1, product_id=5, quantity=500, min_quantity=100)
sl_1_6 = inv.StockLevel(warehouse_id=1, product_id=6, quantity=8, min_quantity=10)
sl_2_1 = inv.StockLevel(warehouse_id=2, product_id=1, quantity=75, min_quantity=20)
sl_2_2 = inv.StockLevel(warehouse_id=2, product_id=2, quantity=25, min_quantity=10)
sl_2_3 = inv.StockLevel(warehouse_id=2, product_id=3, quantity=0, min_quantity=30)
sl_2_5 = inv.StockLevel(warehouse_id=2, product_id=5, quantity=300, min_quantity=50)
stock_levels = [sl_1_1, sl_1_2, sl_1_3, sl_1_4, sl_1_5, sl_1_6,
                sl_2_1, sl_2_2, sl_2_3, sl_2_5]

# Customers
addr1 = cust.Address(street="123 Main St", city="Chicago", state="IL", zip="60601")
addr2 = cust.Address(street="456 Oak Ave", city="Portland", state="OR", zip="97201")
addr3 = cust.Address(street="789 Pine Rd", city="Austin", state="TX", zip="78701")

cust1 = cust.Customer(id=1, name="Alice Smith", email="alice@example.com", tier="gold", address=addr1, created_year=2020)
cust2 = cust.Customer(id=2, name="Bob Jones", email="bob@example.com", tier="silver", address=addr2, created_year=2021)
cust3 = cust.Customer(id=3, name="Carol White", email="carol@example.com", tier="bronze", address=addr3, created_year=2023)
customers = [cust1, cust2, cust3]

# Purchase records
pr1 = cust.PurchaseRecord(customer_id=1, order_id=101, amount=15000, year=2024)
pr2 = cust.PurchaseRecord(customer_id=1, order_id=102, amount=22000, year=2024)
pr3 = cust.PurchaseRecord(customer_id=1, order_id=103, amount=18000, year=2025)
pr4 = cust.PurchaseRecord(customer_id=2, order_id=201, amount=8000, year=2024)
pr5 = cust.PurchaseRecord(customer_id=2, order_id=202, amount=12000, year=2025)
pr6 = cust.PurchaseRecord(customer_id=3, order_id=301, amount=5000, year=2025)
purchase_records = [pr1, pr2, pr3, pr4, pr5, pr6]

# Orders
order1 = ord.create_order(1001, 1, [[1, 5], [2, 2]], products, categories, customers, 1700000000)
order2 = ord.create_order(1002, 2, [[3, 10], [5, 20]], products, categories, customers, 1700100000)
order3 = ord.create_order(1003, 1, [[6, 1], [4, 3]], products, categories, customers, 1700200000)
order4 = ord.create_order(1004, 3, [[1, 2]], products, categories, customers, 1700300000)
orders = [order1, order2, order3, order4]

# ---------------------------------------------------------------------------
# E4 Test Data (new modules)
# ---------------------------------------------------------------------------

# Carriers
carrier1 = ship.Carrier(id=1, name="FastShip", base_rate=500, per_kg_rate=100, max_weight=50, active=True)
carrier2 = ship.Carrier(id=2, name="EcoFreight", base_rate=300, per_kg_rate=50, max_weight=100, active=True)
carrier3 = ship.Carrier(id=3, name="OvernightExpress", base_rate=1500, per_kg_rate=200, max_weight=30, active=False)
carriers = [carrier1, carrier2, carrier3]

# Delivery Zones
zone1 = ship.DeliveryZone(id=1, name="Local", surcharge_pct=0)
zone2 = ship.DeliveryZone(id=2, name="Remote", surcharge_pct=20)
zones = [zone1, zone2]

# Shipments
shipment1 = ship.Shipment(id=1, order_id=1001, carrier_id=1, warehouse_id=1, status="delivered", tracking_number="TRK001", weight_kg=5, shipping_cost=1000, created_at=1000, delivered_at=3000)
shipment2 = ship.Shipment(id=2, order_id=1002, carrier_id=2, warehouse_id=1, status="shipped", tracking_number="TRK002", weight_kg=10, shipping_cost=800, created_at=2000, delivered_at=0)
shipment3 = ship.Shipment(id=3, order_id=1003, carrier_id=1, warehouse_id=2, status="pending", tracking_number="TRK003", weight_kg=3, shipping_cost=800, created_at=3000, delivered_at=0)
shipments = [shipment1, shipment2, shipment3]

# Invoices
inv1 = bill.Invoice(id=1, order_id=1, customer_id=1, subtotal=9000, tax=765, discount=1350, total=8415, status="paid", issued_at=1000, due_at=3000, paid_at=2000)
inv2 = bill.Invoice(id=2, order_id=2, customer_id=2, subtotal=15000, tax=1275, discount=1500, total=14775, status="paid", issued_at=2000, due_at=4000, paid_at=3500)
inv3 = bill.Invoice(id=3, order_id=3, customer_id=1, subtotal=5000, tax=425, discount=750, total=4675, status="unpaid", issued_at=3000, due_at=5000, paid_at=0)
inv4 = bill.Invoice(id=4, order_id=4, customer_id=3, subtotal=20000, tax=1700, discount=1000, total=20700, status="unpaid", issued_at=4000, due_at=6000, paid_at=0)
invoices = [inv1, inv2, inv3, inv4]

# Payments
pay1 = bill.Payment(id=1, invoice_id=1, amount=8415, method="card", status="completed", processed_at=2000)
pay2 = bill.Payment(id=2, invoice_id=2, amount=10000, method="bank", status="completed", processed_at=3000)
pay3 = bill.Payment(id=3, invoice_id=2, amount=4775, method="card", status="completed", processed_at=3500)
payments = [pay1, pay2, pay3]

# Credit Notes
cn1 = bill.CreditNote(id=1, customer_id=1, amount=500, reason="damaged goods", issued_at=2500)
credit_notes = [cn1]

# Purchase Orders
po1 = proc.PurchaseOrder(id=1, supplier_id=1, status="completed", created_at=1000, expected_at=5000, total=6000)
po2 = proc.PurchaseOrder(id=2, supplier_id=2, status="pending", created_at=3000, expected_at=8000, total=4500)
purchase_orders = [po1, po2]

# PO Lines
poline1 = proc.POLine(po_id=1, product_id=1, quantity=10, unit_cost=400)
poline2 = proc.POLine(po_id=1, product_id=3, quantity=4, unit_cost=500)
poline3 = proc.POLine(po_id=2, product_id=5, quantity=10, unit_cost=450)
po_lines = [poline1, poline2, poline3]

# Goods Receipts
gr1 = proc.GoodsReceipt(id=1, po_id=1, warehouse_id=1, received_at=4000, line_count=2)
goods_receipts = [gr1]

# Campaigns
campaign1 = promo.Campaign(id=1, name="Summer Sale", start_date=1000, end_date=5000, status="active")
campaign2 = promo.Campaign(id=2, name="VIP Only", start_date=2000, end_date=6000, status="active")
campaigns = [campaign1, campaign2]

# Coupons
coupon1 = promo.Coupon(id=1, campaign_id=1, code="SUMMER10", discount_type="percentage", discount_value=10, min_order=5000, max_uses=100, current_uses=30)
coupon2 = promo.Coupon(id=2, campaign_id=1, code="SAVE500", discount_type="fixed", discount_value=500, min_order=3000, max_uses=50, current_uses=50)
coupon3 = promo.Coupon(id=3, campaign_id=2, code="VIP20", discount_type="percentage", discount_value=20, min_order=10000, max_uses=20, current_uses=5)
coupons = [coupon1, coupon2, coupon3]

# Promotion Rules
rule1 = promo.PromotionRule(id=1, campaign_id=1, min_tier="", min_order_value=5000, category_id=0)
rule2 = promo.PromotionRule(id=2, campaign_id=2, min_tier="gold", min_order_value=10000, category_id=0)
promo_rules = [rule1, rule2]

# Employees
emp1 = emp.Employee(id=1, name="Alice", department="sales", role="rep", hire_date=100, active=True)
emp2 = emp.Employee(id=2, name="Bob", department="sales", role="manager", hire_date=200, active=True)
emp3 = emp.Employee(id=3, name="Carol", department="support", role="rep", hire_date=500, active=False)
employees = [emp1, emp2, emp3]

# Commission Rules
cr1 = emp.CommissionRule(id=1, employee_id=1, category_id=1, rate_pct=5)
cr2 = emp.CommissionRule(id=2, employee_id=1, category_id=2, rate_pct=8)
cr3 = emp.CommissionRule(id=3, employee_id=2, category_id=1, rate_pct=3)
commission_rules = [cr1, cr2, cr3]

# Sales Targets
st1 = emp.SalesTarget(id=1, employee_id=1, period="2024-Q1", target_amount=50000, actual_amount=35000)
st2 = emp.SalesTarget(id=2, employee_id=2, period="2024-Q1", target_amount=80000, actual_amount=90000)
sales_targets = [st1, st2]

# Templates
tmpl1 = notif.Template(id=1, name="order-confirm", channel="email", subject="Order Confirmed", body_pattern="Your order {id} is confirmed")
tmpl2 = notif.Template(id=2, name="ship-notify", channel="sms", subject="Shipped", body_pattern="Order {id} shipped")
tmpl3 = notif.Template(id=3, name="invoice-due", channel="email", subject="Invoice Due", body_pattern="Invoice {id} is due")
templates = [tmpl1, tmpl2, tmpl3]

# Notifications
notif1 = notif.Notification(id=1, template_id=1, customer_id=1, reference_id=1, reference_type="order", status="sent", created_at=1000, sent_at=1100)
notif2 = notif.Notification(id=2, template_id=2, customer_id=1, reference_id=1, reference_type="shipment", status="sent", created_at=2000, sent_at=2050)
notif3 = notif.Notification(id=3, template_id=1, customer_id=2, reference_id=2, reference_type="order", status="pending", created_at=2000, sent_at=0)
notif4 = notif.Notification(id=4, template_id=3, customer_id=1, reference_id=3, reference_type="invoice", status="failed", created_at=3000, sent_at=0)
notifications = [notif1, notif2, notif3, notif4]

# Preferences
pref1 = notif.Preference(customer_id=1, channel="email", enabled=True)
pref2 = notif.Preference(customer_id=1, channel="sms", enabled=False)
pref3 = notif.Preference(customer_id=2, channel="email", enabled=True)
preferences = [pref1, pref2, pref3]

# Audit Entries
ae1 = audit.AuditEntry(id=1, entity_type="order", entity_id=1, action="create", actor_id=1, timestamp=1000, detail="pending")
ae2 = audit.AuditEntry(id=2, entity_type="order", entity_id=1, action="update", actor_id=1, timestamp=1500, detail="confirmed")
ae3 = audit.AuditEntry(id=3, entity_type="shipment", entity_id=1, action="create", actor_id=2, timestamp=2000, detail="pending")
ae4 = audit.AuditEntry(id=4, entity_type="invoice", entity_id=1, action="create", actor_id=1, timestamp=1000, detail="unpaid")
audit_entries = [ae1, ae2, ae3, ae4]

# Analytics metrics
metric1 = analytics.PeriodMetric(period="2024-Q1", metric_name="revenue", value=50000)
metric2 = analytics.PeriodMetric(period="2024-Q2", metric_name="revenue", value=65000)
metric3 = analytics.PeriodMetric(period="2024-Q3", metric_name="revenue", value=55000)
metric4 = analytics.PeriodMetric(period="2024-Q1", metric_name="order-count", value=100)
metric5 = analytics.PeriodMetric(period="2024-Q2", metric_name="order-count", value=130)
metric6 = analytics.PeriodMetric(period="2024-Q3", metric_name="order-count", value=110)
metrics = [metric1, metric2, metric3, metric4, metric5, metric6]


# ===========================================================================
# CATALOG TESTS (abbreviated, key functions)
# ===========================================================================

print("--- CATALOG ---")

assert_eq("cat/product-margin Widget A", 700, cat.product_margin(prod1))
assert_eq("cat/product-margin-pct Widget A", 58, cat.product_margin_pct(prod1))
assert_true("cat/product-profitable? Widget A", cat.product_profitable(prod1))
assert_eq("cat/active-products count", 6, len(cat.active_products(products)))
assert_eq("cat/inactive-products count", 1, len(cat.inactive_products(products)))
assert_eq("cat/products-by-category cat 1", 3, len(cat.products_by_category(products, 1)))
assert_eq("cat/find-product-by-id 1 name", "Widget A", cat.product_name(cat.find_product_by_id(products, 1)))
assert_eq("cat/find-product-by-id 99", None, cat.find_product_by_id(products, 99))
assert_eq("cat/find-product-by-sku WGT-001", "Widget A", cat.product_name(cat.find_product_by_sku(products, "WGT-001")))
assert_eq("cat/sort-by-price first", "Bolt Pack", cat.product_name(cat.sort_by_price(products)[0]))
assert_eq("cat/total-catalog-value", 6820, cat.total_catalog_value(products))
assert_eq("cat/total-catalog-cost", 3400, cat.total_catalog_cost(products))
assert_eq("cat/avg-unit-price", 974, cat.avg_unit_price(products))
assert_eq("cat/cheapest-product", "Bolt Pack", cat.product_name(cat.cheapest_product(products)))
assert_eq("cat/most-expensive-product", "Gear Set", cat.product_name(cat.most_expensive_product(products)))
assert_eq("cat/format-price 1200", "$12.00", cat.format_price(1200))
assert_eq("cat/format-price 50", "$0.50", cat.format_price(50))
assert_eq("cat/product-tax Widget A", 180, cat.product_tax(prod1, cat1))
assert_eq("cat/high-margin-products 50", 5, len(cat.high_margin_products(products, 50)))
assert_eq("cat/products-in-price-range 400-800", 3, len(cat.products_in_price_range(products, 400, 800)))
assert_eq("cat/top-n-by-price first", "Gear Set", cat.product_name(cat.top_n_by_price(products, 2)[0]))
assert_eq("cat/category-total-value cat 1", 3300, cat.category_total_value(products, 1))
assert_eq("cat/supplier-avg-lead-time", 8, cat.supplier_avg_lead_time(suppliers))
assert_eq("cat/price-spread", 2080, cat.price_spread(products))
assert_eq("cat/cost-spread", 1150, cat.cost_spread(products))
assert_eq("cat/product-price-diff prod1 prod5", 1080, cat.product_price_diff(prod1, prod5))
assert_true("cat/valid-product? prod1", cat.valid_product(prod1))
tiers = cat.make_standard_tiers()
assert_eq("cat/quantity-price Widget A qty 100", 102000, cat.quantity_price(prod1, tiers, 100))
assert_eq("cat/quantity-price Widget A qty 1", 1200, cat.quantity_price(prod1, tiers, 1))
assert_eq("cat/product-summary Widget A", "Widget A (WGT-001) $12.00", cat.product_summary(prod1))


# ===========================================================================
# CUSTOMERS TESTS
# ===========================================================================

print("--- CUSTOMERS ---")

assert_eq("cust/tier-discount-pct gold", 15, cust.tier_discount_pct("gold"))
assert_eq("cust/tier-discount-pct silver", 10, cust.tier_discount_pct("silver"))
assert_eq("cust/tier-discount-pct bronze", 5, cust.tier_discount_pct("bronze"))
assert_eq("cust/tier-rank gold", 3, cust.tier_rank("gold"))
assert_true("cust/higher-tier? gold vs silver", cust.higher_tier("gold", "silver"))
assert_false("cust/higher-tier? bronze vs gold", cust.higher_tier("bronze", "gold"))
assert_eq("cust/tier-from-spend 100000", "gold", cust.tier_from_spend(100000))
assert_eq("cust/tier-from-spend 50000", "silver", cust.tier_from_spend(50000))
assert_eq("cust/tier-from-spend 10000", "bronze", cust.tier_from_spend(10000))
assert_eq("cust/tier-from-spend 5000", "none", cust.tier_from_spend(5000))
assert_eq("cust/find-customer-by-id 1", "Alice Smith", cust.find_customer_by_id(customers, 1).name)
assert_eq("cust/find-customer-by-id 99", None, cust.find_customer_by_id(customers, 99))
assert_eq("cust/customer-total-spend Alice", 55000, cust.customer_total_spend(purchase_records, 1))
assert_eq("cust/customer-total-spend Bob", 20000, cust.customer_total_spend(purchase_records, 2))
assert_eq("cust/customer-purchase-count Alice", 3, cust.customer_purchase_count(purchase_records, 1))
assert_eq("cust/customer-avg-order-value Alice", 18333, cust.customer_avg_order_value(purchase_records, 1))
assert_eq("cust/customer-spend-in-year Alice 2024", 37000, cust.customer_spend_in_year(purchase_records, 1, 2024))
assert_eq("cust/assess-tier Alice", "silver", cust.assess_tier(purchase_records, 1))
assert_eq("cust/assess-tier Bob", "bronze", cust.assess_tier(purchase_records, 2))
assert_eq("cust/count-by-tier", {"gold": 1, "silver": 1, "bronze": 1}, cust.count_by_tier(customers))
assert_eq("cust/total-customer-count", 3, cust.total_customer_count(customers))
assert_eq("cust/customer-tenure Alice 2025", 5, cust.customer_tenure(cust1, 2025))
assert_eq("cust/avg-customer-tenure 2025", 3, cust.avg_customer_tenure(customers, 2025))
assert_true("cust/valid-customer? cust1", cust.valid_customer(cust1))
assert_true("cust/valid-address? addr1", cust.valid_address(addr1))
assert_eq("cust/address-oneline addr1", "123 Main St, Chicago, IL 60601", cust.address_oneline(addr1))
assert_eq("cust/unique-states count", 3, len(cust.unique_states(customers)))
assert_eq("cust/points-for-purchase 15000 gold", 450, cust.points_for_purchase(15000, "gold"))
assert_eq("cust/points-for-purchase 10000 silver", 200, cust.points_for_purchase(10000, "silver"))
assert_eq("cust/points-to-dollars 450", 45, cust.points_to_dollars(450))
assert_eq("cust/customer-segment Alice", "occasional", cust.customer_segment(purchase_records, 1))


# ===========================================================================
# INVENTORY TESTS
# ===========================================================================

print("--- INVENTORY ---")

assert_eq("inv/total-stock-for-product prod 1", 175, inv.total_stock_for_product(stock_levels, 1))
assert_eq("inv/total-stock-in-warehouse wh 1", 888, inv.total_stock_in_warehouse(stock_levels, 1))
assert_eq("inv/total-stock-in-warehouse wh 2", 400, inv.total_stock_in_warehouse(stock_levels, 2))
assert_true("inv/in-stock? wh1 prod1", inv.in_stock(stock_levels, 1, 1))
assert_false("inv/in-stock? wh2 prod3", inv.in_stock(stock_levels, 2, 3))
assert_true("inv/below-minimum? sl-1-6", inv.below_minimum(sl_1_6))
assert_false("inv/below-minimum? sl-1-1", inv.below_minimum(sl_1_1))
assert_eq("inv/low-stock-items count", 2, len(inv.low_stock_items(stock_levels)))
assert_eq("inv/out-of-stock-items count", 1, len(inv.out_of_stock_items(stock_levels)))
assert_true("inv/can-fulfill? prod1 100", inv.can_fulfill(stock_levels, 1, 100))
assert_false("inv/can-fulfill? prod1 176", inv.can_fulfill(stock_levels, 1, 176))
assert_eq("inv/stock-value-at-warehouse wh1", 175100, inv.stock_value_at_warehouse(stock_levels, 1, products))
assert_eq("inv/stock-value-at-warehouse wh2", 72500, inv.stock_value_at_warehouse(stock_levels, 2, products))
assert_eq("inv/total-inventory-value", 247600, inv.total_inventory_value(stock_levels, products))
assert_eq("inv/stock-retail-value", 548600, inv.stock_retail_value(stock_levels, products))
assert_eq("inv/reorder-quantity sl-1-6", 4, inv.reorder_quantity(sl_1_6))
assert_eq("inv/reorder-quantity sl-2-3", 60, inv.reorder_quantity(sl_2_3))
assert_eq("inv/reorder-cost", 16800, inv.reorder_cost(stock_levels, products))
assert_eq("inv/warehouse-utilization-pct wh1", 8, inv.warehouse_utilization_pct(stock_levels, wh1))
assert_eq("inv/warehouse-item-count wh1", 6, inv.warehouse_item_count(stock_levels, 1))
assert_eq("inv/days-of-stock prod1 demand 5", 35, inv.days_of_stock(stock_levels, 1, 5))
assert_eq("inv/days-of-stock zero demand", 999, inv.days_of_stock(stock_levels, 1, 0))
assert_eq("inv/safety-stock 10 7 2", 140, inv.safety_stock(10, 7, 2))
assert_eq("inv/stock-summary sl-1-1", "WH:1 Prod:1 Qty:100/20", inv.stock_summary(sl_1_1))
assert_eq("inv/warehouse-summary wh1", "Main DC (Chicago) cap:10000", inv.warehouse_summary(wh1))


# ===========================================================================
# ORDERS TESTS
# ===========================================================================

print("--- ORDERS ---")

assert_eq("order1 subtotal", 9000, ord.order_subtotal(order1))
assert_eq("order1 discount", 1350, ord.order_discount(order1))
assert_eq("order1 tax", 765, ord.order_tax(order1))
assert_eq("order1 total", 8415, ord.order_total(order1))
assert_eq("order2 subtotal", 6900, ord.order_subtotal(order2))
assert_eq("order2 total", 6831, ord.order_total(order2))
assert_eq("order3 total", 4161, ord.order_total(order3))
assert_eq("order4 total", 2508, ord.order_total(order4))
assert_eq("order1 status", "pending", ord.order_status(order1))
assert_true("ord/can-fulfill-order? order1", ord.can_fulfill_order(stock_levels, order1))
assert_eq("ord/total-revenue", 21915, ord.total_revenue(orders))
assert_eq("ord/avg-order-value", 5478, ord.avg_order_value(orders))
assert_eq("ord/total-discounts-given", 2827, ord.total_discounts_given(orders))
assert_eq("ord/total-tax-collected", 1992, ord.total_tax_collected(orders))
assert_eq("ord/product-units-ordered prod1", 7, ord.product_units_ordered(orders, 1))
assert_eq("ord/product-revenue prod1", 8400, ord.product_revenue(orders, 1))
assert_eq("ord/total-units-ordered", 43, ord.total_units_ordered(orders))
assert_eq("ord/largest-order", 1001, ord.order_id(ord.largest_order(orders)))
assert_eq("ord/smallest-order", 1004, ord.order_id(ord.smallest_order(orders)))
assert_eq("ord/customer-order-count Alice", 2, ord.customer_order_count(orders, 1))
assert_eq("ord/customer-total-spend Alice", 12576, ord.customer_total_spend(orders, 1))
assert_true("ord/valid-order? order1", ord.valid_order(order1))
assert_eq("ord/find-order-by-id 1001", 1001, ord.order_id(ord.find_order_by_id(orders, 1001)))
assert_eq("ord/find-order-by-id 9999", None, ord.find_order_by_id(orders, 9999))


# ===========================================================================
# REPORTS TESTS
# ===========================================================================

print("--- REPORTS ---")

ss = rep.sales_summary(orders)
assert_eq("rep/sales-summary total-orders", 4, ss["total-orders"])
assert_eq("rep/sales-summary total-revenue", 21915, ss["total-revenue"])
assert_eq("rep/sales-summary total-tax", 1992, ss["total-tax"])
assert_eq("rep/sales-summary avg-order-value", 5478, ss["avg-order-value"])

assert_eq("rep/fulfillment-rate", 100, rep.fulfillment_rate(orders, stock_levels))

dash = rep.dashboard(products, suppliers, categories, stock_levels, warehouses, customers, orders)
assert_eq("rep/dashboard catalog total-products", 7, dash["catalog"]["total-products"])
assert_eq("rep/dashboard catalog active-products", 6, dash["catalog"]["active-products"])
assert_eq("rep/dashboard inventory total-value", 247600, dash["inventory"]["total-value"])
assert_eq("rep/dashboard customers total-count", 3, dash["customers"]["total-count"])
assert_eq("rep/dashboard orders total-revenue", 21915, dash["orders"]["total-revenue"])

top2 = rep.top_products_by_revenue(orders, products, 2)
assert_eq("rep/top-products-by-revenue #1", "Widget A", top2[0]["product-name"])
assert_eq("rep/top-products-by-revenue #2", "Stapler", top2[1]["product-name"])

cr = rep.customer_report(customers, orders)
assert_eq("rep/customer-report count", 3, len(cr))

trr = rep.tier_revenue_report(customers, orders)
by_tier = {r["tier"]: r for r in trr}
assert_eq("rep/tier-revenue gold revenue", 12576, by_tier["gold"]["revenue"])
assert_eq("rep/tier-revenue silver revenue", 6831, by_tier["silver"]["revenue"])
assert_eq("rep/tier-revenue bronze revenue", 2508, by_tier["bronze"]["revenue"])


# ===========================================================================
# SHIPPING TESTS
# ===========================================================================

print("--- SHIPPING ---")

# Find carrier
assert_eq("ship/find-carrier-by-id 1", "FastShip", ship.carrier_name(ship.find_carrier_by_id(carriers, 1)))
assert_eq("ship/find-carrier-by-id 2", "EcoFreight", ship.carrier_name(ship.find_carrier_by_id(carriers, 2)))
assert_eq("ship/find-carrier-by-id 99", None, ship.find_carrier_by_id(carriers, 99))

# Active carriers
assert_eq("ship/active-carriers count", 2, len(ship.active_carriers(carriers)))

# Carrier total cost
assert_eq("ship/carrier-total-cost FastShip 10kg", 1500, ship.carrier_total_cost(carrier1, 10))
assert_eq("ship/carrier-total-cost EcoFreight 10kg", 800, ship.carrier_total_cost(carrier2, 10))

# Carriers for weight
assert_eq("ship/carriers-for-weight 40", 2, len(ship.carriers_for_weight(carriers, 40)))
assert_eq("ship/carriers-for-weight 60", 1, len(ship.carriers_for_weight(carriers, 60)))
assert_eq("ship/carriers-for-weight 200", 0, len(ship.carriers_for_weight(carriers, 200)))

# Cheapest carrier
assert_eq("ship/cheapest-carrier 10kg", "EcoFreight", ship.carrier_name(ship.cheapest_carrier(carriers, 10)))
assert_eq("ship/cheapest-carrier 60kg", "EcoFreight", ship.carrier_name(ship.cheapest_carrier(carriers, 60)))
assert_eq("ship/cheapest-carrier 200kg", None, ship.cheapest_carrier(carriers, 200))

# Zone surcharge
assert_eq("ship/zone-surcharge local", 0, ship.zone_surcharge(zone1, 1000))
assert_eq("ship/zone-surcharge remote", 200, ship.zone_surcharge(zone2, 1000))

# Create shipment
s = ship.create_shipment(10, order1, carrier1, 1, 5, zone1)
assert_eq("ship/create-shipment cost local", 1000, ship.shipment_shipping_cost(s))
assert_eq("ship/create-shipment status", "pending", ship.shipment_status(s))
assert_eq("ship/create-shipment weight", 5, ship.shipment_weight_kg(s))

s = ship.create_shipment(11, order1, carrier2, 1, 10, zone2)
assert_eq("ship/create-shipment cost remote", 960, ship.shipment_shipping_cost(s))

# Ship/deliver transitions
shipped = ship.ship_shipment(shipment3, 4000)
assert_eq("ship/ship-shipment status", "shipped", ship.shipment_status(shipped))

delivered = ship.deliver_shipment(shipment2, 5000)
assert_eq("ship/deliver-shipment status", "delivered", ship.shipment_status(delivered))
assert_eq("ship/deliver-shipment delivered-at", 5000, ship.shipment_delivered_at(delivered))

# Cancel: only pending
cancelled = ship.cancel_shipment(shipment3)
assert_eq("ship/cancel-shipment pending", "cancelled", ship.shipment_status(cancelled))
# Cancel shipped: no change
same = ship.cancel_shipment(shipment2)
assert_eq("ship/cancel-shipment shipped no change", "shipped", ship.shipment_status(same))

# Shipment queries
assert_eq("ship/find-shipment-by-id 1", 1, ship.shipment_id(ship.find_shipment_by_id(shipments, 1)))
assert_eq("ship/shipments-for-order 1001", 1, len(ship.shipments_for_order(shipments, 1001)))
assert_eq("ship/shipments-by-carrier 1", 2, len(ship.shipments_by_carrier(shipments, 1)))
assert_eq("ship/shipments-by-status pending", 1, len(ship.shipments_by_status(shipments, "pending")))
assert_eq("ship/pending-shipments", 1, len(ship.pending_shipments(shipments)))
assert_eq("ship/delivered-shipments", 1, len(ship.delivered_shipments(shipments)))
assert_true("ship/shipment-delivered? s1", ship.shipment_delivered(shipment1))
assert_false("ship/shipment-delivered? s2", ship.shipment_delivered(shipment2))

# Revenue: sum of shipping-cost for delivered only = 1000
assert_eq("ship/total-shipping-revenue", 1000, ship.total_shipping_revenue(shipments))

# Avg shipping cost (non-cancelled): (1000+800+800)/3 = 866
assert_eq("ship/avg-shipping-cost", 866, ship.avg_shipping_cost(shipments))

# Carrier revenue: only delivered for carrier 1 = 1000
assert_eq("ship/carrier-revenue carrier1", 1000, ship.carrier_revenue(shipments, 1))
assert_eq("ship/carrier-revenue carrier2", 0, ship.carrier_revenue(shipments, 2))

# Carrier shipment count
assert_eq("ship/carrier-shipment-count carrier1", 2, ship.carrier_shipment_count(shipments, 1))
assert_eq("ship/carrier-shipment-count carrier2", 1, ship.carrier_shipment_count(shipments, 2))

# Shipping cost for order
assert_eq("ship/shipping-cost-for-order 1001", 1000, ship.shipping_cost_for_order(shipments, 1001))
assert_eq("ship/shipping-cost-for-order 1002", 800, ship.shipping_cost_for_order(shipments, 1002))

# Order fully shipped?
assert_true("ship/order-fully-shipped? order1", ship.order_fully_shipped(shipments, order1))
assert_false("ship/order-fully-shipped? order4", ship.order_fully_shipped(shipments, order4))

# Unshipped orders
assert_eq("ship/unshipped-orders", 1, len(ship.unshipped_orders(shipments, orders)))

# Warehouse shipment count
assert_eq("ship/warehouse-shipment-count wh1", 2, ship.warehouse_shipment_count(shipments, 1))
assert_eq("ship/warehouse-shipment-count wh2", 1, ship.warehouse_shipment_count(shipments, 2))

# Set tracking
s = ship.set_tracking_number(shipment3, "NEWTRK")
assert_eq("ship/set-tracking-number", "NEWTRK", ship.shipment_tracking_number(s))

# Delivery time
assert_eq("ship/delivery-time-seconds s1", 2000, ship.delivery_time_seconds(shipment1))
assert_eq("ship/delivery-time-days s1", 0, ship.delivery_time_days(shipment1))
assert_eq("ship/delivery-time-seconds s2", 0, ship.delivery_time_seconds(shipment2))

# Avg delivery days
assert_eq("ship/avg-delivery-time-days", 0, ship.avg_delivery_time_days(shipments))

# Fastest/slowest delivery
assert_eq("ship/fastest-delivery", 1, ship.shipment_id(ship.fastest_delivery(shipments)))
assert_eq("ship/slowest-delivery", 1, ship.shipment_id(ship.slowest_delivery(shipments)))

# Total weight shipped (delivered only): 5
assert_eq("ship/total-weight-shipped", 5, ship.total_weight_shipped(shipments))

# Avg shipment weight (non-cancelled): (5+10+3)/3 = 6
assert_eq("ship/avg-shipment-weight", 6, ship.avg_shipment_weight(shipments))

# Heaviest/lightest
assert_eq("ship/heaviest-shipment", 2, ship.shipment_id(ship.heaviest_shipment(shipments)))
assert_eq("ship/lightest-shipment", 3, ship.shipment_id(ship.lightest_shipment(shipments)))

# Cost per kg
assert_eq("ship/cost-per-kg s1", 200, ship.cost_per_kg(shipment1))
assert_eq("ship/cost-per-kg s2", 80, ship.cost_per_kg(shipment2))

# On-time
assert_eq("ship/carrier-on-time-count carrier1 1day", 1, ship.carrier_on_time_count(shipments, 1, 1))
assert_eq("ship/carrier-on-time-pct carrier1 1day", 100, ship.carrier_on_time_pct(shipments, 1, 1))


# ===========================================================================
# BILLING TESTS
# ===========================================================================

print("--- BILLING ---")

# Create invoice from order
i = bill.create_invoice(10, order1, cust1, 5000, 7000)
assert_eq("bill/create-invoice total", 8415, i.total)
assert_eq("bill/create-invoice status", "unpaid", i.status)
assert_eq("bill/create-invoice customer-id", 1, i.customer_id)
assert_eq("bill/create-invoice order-id", 1001, i.order_id)

# Find invoice
assert_eq("bill/find-invoice-by-id 1", 1, bill.find_invoice_by_id(invoices, 1).id)
assert_eq("bill/find-invoice-by-id 99", None, bill.find_invoice_by_id(invoices, 99))

# Invoices for customer
assert_eq("bill/invoices-for-customer 1", 2, len(bill.invoices_for_customer(invoices, 1)))
assert_eq("bill/invoices-for-customer 2", 1, len(bill.invoices_for_customer(invoices, 2)))
assert_eq("bill/invoices-for-customer 3", 1, len(bill.invoices_for_customer(invoices, 3)))

# Invoices for order
assert_eq("bill/invoices-for-order 1", 1, len(bill.invoices_for_order(invoices, 1)))

# Status-based queries
assert_eq("bill/unpaid-invoices count", 2, len(bill.unpaid_invoices(invoices)))
assert_eq("bill/paid-invoices count", 2, len(bill.paid_invoices(invoices)))

# Overdue
assert_eq("bill/overdue-invoices now=5500", 1, len(bill.overdue_invoices(invoices, 5500)))
assert_eq("bill/overdue-invoices now=7000", 2, len(bill.overdue_invoices(invoices, 7000)))

# Mark paid
paid = bill.mark_invoice_paid(inv3, 6000)
assert_eq("bill/mark-invoice-paid status", "paid", paid.status)
assert_eq("bill/mark-invoice-paid paid-at", 6000, paid.paid_at)

# Invoice age
assert_eq("bill/invoice-age-days inv1 now=5000", 0, bill.invoice_age_days(inv1, 5000))
assert_eq("bill/invoice-age-days inv1 now=100000", 1, bill.invoice_age_days(inv1, 100000))

# Create payment
p = bill.create_payment(10, 3, 4675, "card", 5000)
assert_eq("bill/create-payment amount", 4675, p.amount)
assert_eq("bill/create-payment status", "completed", p.status)
assert_eq("bill/create-payment method", "card", p.method)

# Find payment
assert_eq("bill/find-payment-by-id 1", 1, bill.find_payment_by_id(payments, 1).id)

# Payments for invoice
assert_eq("bill/payments-for-invoice inv1", 1, len(bill.payments_for_invoice(payments, 1)))
assert_eq("bill/payments-for-invoice inv2", 2, len(bill.payments_for_invoice(payments, 2)))

# Total payments for invoice
assert_eq("bill/total-payments-for-invoice inv2", 14775, bill.total_payments_for_invoice(payments, 2))
assert_eq("bill/total-payments-for-invoice inv1", 8415, bill.total_payments_for_invoice(payments, 1))

# Invoice balance
assert_eq("bill/invoice-balance inv1", 0, bill.invoice_balance(inv1, payments))
assert_eq("bill/invoice-balance inv2", 0, bill.invoice_balance(inv2, payments))
assert_eq("bill/invoice-balance inv3", 4675, bill.invoice_balance(inv3, payments))
assert_eq("bill/invoice-balance inv4", 20700, bill.invoice_balance(inv4, payments))

# Fully paid?
assert_true("bill/invoice-fully-paid? inv1", bill.invoice_fully_paid(inv1, payments))
assert_true("bill/invoice-fully-paid? inv2", bill.invoice_fully_paid(inv2, payments))
assert_false("bill/invoice-fully-paid? inv3", bill.invoice_fully_paid(inv3, payments))

# Payments by method
assert_eq("bill/payments-by-method card", 2, len(bill.payments_by_method(payments, "card")))
assert_eq("bill/payments-by-method bank", 1, len(bill.payments_by_method(payments, "bank")))

# Refund payment
refunded = bill.refund_payment(pay1)
assert_eq("bill/refund-payment status", "refunded", refunded.status)

# Credit notes
assert_eq("bill/credits-for-customer 1", 1, len(bill.credits_for_customer(credit_notes, 1)))
assert_eq("bill/total-credits-for-customer 1", 500, bill.total_credits_for_customer(credit_notes, 1))
assert_eq("bill/total-credits-for-customer 2", 0, bill.total_credits_for_customer(credit_notes, 2))

# Revenue collected
assert_eq("bill/total-revenue-collected", 23190, bill.total_revenue_collected(payments))

# Total outstanding
assert_eq("bill/total-outstanding", 25375, bill.total_outstanding(invoices, payments))

# Customer total billed
assert_eq("bill/customer-total-billed cust1", 13090, bill.customer_total_billed(invoices, 1))
assert_eq("bill/customer-total-billed cust2", 14775, bill.customer_total_billed(invoices, 2))
assert_eq("bill/customer-total-billed cust3", 20700, bill.customer_total_billed(invoices, 3))

# Customer total paid
assert_eq("bill/customer-total-paid cust1", 8415, bill.customer_total_paid(payments, invoices, 1))
assert_eq("bill/customer-total-paid cust2", 14775, bill.customer_total_paid(payments, invoices, 2))

# Revenue by method
rbm = bill.revenue_by_method(payments)
assert_eq("bill/revenue-by-method card", 13190, rbm["card"])
assert_eq("bill/revenue-by-method bank", 10000, rbm["bank"])

# Avg days to pay
assert_eq("bill/avg-days-to-pay", 0, bill.avg_days_to_pay(invoices))

# Collection rate
assert_eq("bill/collection-rate-pct", 47, bill.collection_rate_pct(invoices, payments))

# Validation
assert_true("bill/valid-invoice? inv1", bill.valid_invoice(inv1))
assert_true("bill/valid-payment? pay1", bill.valid_payment(pay1))
assert_true("bill/valid-credit-note? cn1", bill.valid_credit_note(cn1))

# Invoices in period
assert_eq("bill/invoices-in-period 1000-2000", 2, len(bill.invoices_in_period(invoices, 1000, 2000)))
assert_eq("bill/invoices-in-period 1000-4000", 4, len(bill.invoices_in_period(invoices, 1000, 4000)))

# Payments in period
assert_eq("bill/payments-in-period 2000-3000", 2, len(bill.payments_in_period(payments, 2000, 3000)))


# ===========================================================================
# PROCUREMENT TESTS
# ===========================================================================

print("--- PROCUREMENT ---")

# PO Line total
assert_eq("proc/poline-total line1", 4000, proc.poline_total(poline1))
assert_eq("proc/poline-total line2", 2000, proc.poline_total(poline2))
assert_eq("proc/poline-total line3", 4500, proc.poline_total(poline3))

# PO total from lines
assert_eq("proc/po-total-from-lines all", 10500, proc.po_total_from_lines(po_lines))
assert_eq("proc/po-total-from-lines po1 lines", 6000, proc.po_total_from_lines(proc.lines_for_po(po_lines, 1)))

# Lines for PO
assert_eq("proc/lines-for-po 1", 2, len(proc.lines_for_po(po_lines, 1)))
assert_eq("proc/lines-for-po 2", 1, len(proc.lines_for_po(po_lines, 2)))

# PO line count
assert_eq("proc/po-line-count po1", 2, proc.po_line_count(po_lines, 1))
assert_eq("proc/po-line-count po2", 1, proc.po_line_count(po_lines, 2))

# Lines for product
assert_eq("proc/lines-for-product 1", 1, len(proc.lines_for_product(po_lines, 1)))
assert_eq("proc/lines-for-product 5", 1, len(proc.lines_for_product(po_lines, 5)))

# Total quantity for product
assert_eq("proc/total-quantity-for-product 1", 10, proc.total_quantity_for_product(po_lines, 1))
assert_eq("proc/total-quantity-for-product 3", 4, proc.total_quantity_for_product(po_lines, 3))
assert_eq("proc/total-quantity-for-product 5", 10, proc.total_quantity_for_product(po_lines, 5))

# Total spend for product
assert_eq("proc/total-spend-for-product 1", 4000, proc.total_spend_for_product(po_lines, 1))
assert_eq("proc/total-spend-for-product 3", 2000, proc.total_spend_for_product(po_lines, 3))

# Avg unit cost for product
assert_eq("proc/avg-unit-cost-for-product 1", 400, proc.avg_unit_cost_for_product(po_lines, 1))
assert_eq("proc/avg-unit-cost-for-product 3", 500, proc.avg_unit_cost_for_product(po_lines, 3))

# Unique products
assert_eq("proc/unique-products-in-lines", 3, len(proc.unique_products_in_lines(po_lines)))

# Create purchase order
new_lines = [proc.POLine(po_id=99, product_id=1, quantity=5, unit_cost=500)]
po = proc.create_purchase_order(99, 1, new_lines, 1000, 5000)
assert_eq("proc/create-purchase-order status", "pending", proc.purchaseorder_status(po))
assert_eq("proc/create-purchase-order total", 2500, proc.purchaseorder_total(po))

# Find PO
assert_eq("proc/find-po-by-id 1", 1, proc.purchaseorder_id(proc.find_po_by_id(purchase_orders, 1)))
assert_eq("proc/find-po-by-id 99", None, proc.find_po_by_id(purchase_orders, 99))

# POs for supplier
assert_eq("proc/pos-for-supplier 1", 1, len(proc.pos_for_supplier(purchase_orders, 1)))
assert_eq("proc/pos-for-supplier 2", 1, len(proc.pos_for_supplier(purchase_orders, 2)))

# POs by status
assert_eq("proc/pos-by-status completed", 1, len(proc.pos_by_status(purchase_orders, "completed")))
assert_eq("proc/pos-by-status pending", 1, len(proc.pos_by_status(purchase_orders, "pending")))
assert_eq("proc/pending-pos", 1, len(proc.pending_pos(purchase_orders)))
assert_eq("proc/completed-pos", 1, len(proc.completed_pos(purchase_orders)))

# Approve PO (only from pending)
approved = proc.approve_po(po2)
assert_eq("proc/approve-po status", "approved", proc.purchaseorder_status(approved))
# Approve completed -> no change
same = proc.approve_po(po1)
assert_eq("proc/approve-po completed no change", "completed", proc.purchaseorder_status(same))

# Complete PO
completed = proc.complete_po(po2)
assert_eq("proc/complete-po status", "completed", proc.purchaseorder_status(completed))

# Cancel PO (only from pending)
cancelled = proc.cancel_po(po2)
assert_eq("proc/cancel-po status", "cancelled", proc.purchaseorder_status(cancelled))

# PO open/closed
assert_false("proc/po-open? po1 completed", proc.po_open(po1))
assert_true("proc/po-open? po2 pending", proc.po_open(po2))
assert_true("proc/po-closed? po1", proc.po_closed(po1))
assert_false("proc/po-closed? po2", proc.po_closed(po2))

# Expected lead days
assert_eq("proc/po-expected-lead-days po1", 0, proc.po_expected_lead_days(po1))

# Validation
assert_true("proc/valid-po? po1", proc.valid_po(po1))
assert_true("proc/valid-poline? poline1", proc.valid_poline(poline1))
assert_true("proc/all-lines-valid?", proc.all_lines_valid(po_lines))

# Goods receipt
r = proc.create_goods_receipt(10, 1, 1, 5000, po_lines)
assert_eq("proc/create-goods-receipt po-id", 1, proc.goodsreceipt_po_id(r))
assert_eq("proc/create-goods-receipt line-count", 2, proc.goodsreceipt_line_count(r))

assert_eq("proc/receipts-for-po 1", 1, len(proc.receipts_for_po(goods_receipts, 1)))
assert_eq("proc/receipts-for-warehouse 1", 1, len(proc.receipts_for_warehouse(goods_receipts, 1)))
assert_eq("proc/find-receipt-by-id 1", 1, proc.goodsreceipt_id(proc.find_receipt_by_id(goods_receipts, 1)))

# POs in period
assert_eq("proc/pos-in-period 1000-3000", 2, len(proc.pos_in_period(purchase_orders, 1000, 3000)))
assert_eq("proc/pos-in-period 2000-3000", 1, len(proc.pos_in_period(purchase_orders, 2000, 3000)))


# ===========================================================================
# PROMOTIONS TESTS
# ===========================================================================

print("--- PROMOTIONS ---")

# Find campaign
assert_eq("promo/find-campaign-by-id 1", "Summer Sale", promo.campaign_name(promo.find_campaign_by_id(campaigns, 1)))
assert_eq("promo/find-campaign-by-id 99", None, promo.find_campaign_by_id(campaigns, 99))

# Campaign active
assert_true("promo/campaign-active? c1 now=3000", promo.campaign_active(campaign1, 3000))
assert_false("promo/campaign-active? c1 now=6000", promo.campaign_active(campaign1, 6000))
assert_false("promo/campaign-active? c1 now=500", promo.campaign_active(campaign1, 500))

# Active campaigns
assert_eq("promo/active-campaigns now=3000", 2, len(promo.active_campaigns(campaigns, 3000)))
assert_eq("promo/active-campaigns now=5500", 1, len(promo.active_campaigns(campaigns, 5500)))

# Activate/deactivate
inactive = promo.deactivate_campaign(campaign1)
assert_eq("promo/deactivate-campaign", "inactive", promo.campaign_status(inactive))
active = promo.activate_campaign(promo.deactivate_campaign(campaign1))
assert_eq("promo/activate-campaign", "active", promo.campaign_status(active))

# Campaign duration
assert_eq("promo/campaign-duration-days c1", 0, promo.campaign_duration_days(campaign1))

# Find coupon by code
assert_eq("promo/find-coupon-by-code SUMMER10", 1, promo.coupon_id(promo.find_coupon_by_code(coupons, "SUMMER10")))
assert_eq("promo/find-coupon-by-code VIP20", 3, promo.coupon_id(promo.find_coupon_by_code(coupons, "VIP20")))
assert_eq("promo/find-coupon-by-code NOPE", None, promo.find_coupon_by_code(coupons, "NOPE"))

# Coupons for campaign
assert_eq("promo/coupons-for-campaign 1", 2, len(promo.coupons_for_campaign(coupons, 1)))
assert_eq("promo/coupons-for-campaign 2", 1, len(promo.coupons_for_campaign(coupons, 2)))

# Coupon valid
assert_true("promo/coupon-valid? coupon1", promo.coupon_valid(coupon1))
assert_false("promo/coupon-valid? coupon2", promo.coupon_valid(coupon2))
assert_true("promo/coupon-valid? coupon3", promo.coupon_valid(coupon3))

# Use coupon
used = promo.use_coupon(coupon1)
assert_eq("promo/use-coupon increments uses", 31, promo.coupon_current_uses(used))
same = promo.use_coupon(coupon2)
assert_eq("promo/use-coupon exhausted", 50, promo.coupon_current_uses(same))

# Coupon usage pct
assert_eq("promo/coupon-usage-pct coupon1", 30, promo.coupon_usage_pct(coupon1))
assert_eq("promo/coupon-usage-pct coupon2", 100, promo.coupon_usage_pct(coupon2))
assert_eq("promo/coupon-usage-pct coupon3", 25, promo.coupon_usage_pct(coupon3))

# Coupon discount amount
assert_eq("promo/coupon-discount-amount coupon1 10000", 1000, promo.coupon_discount_amount(coupon1, 10000))
assert_eq("promo/coupon-discount-amount coupon2 10000", 500, promo.coupon_discount_amount(coupon2, 10000))
assert_eq("promo/coupon-discount-amount coupon3 10000", 2000, promo.coupon_discount_amount(coupon3, 10000))
assert_eq("promo/coupon-discount-amount coupon3 500", 100, promo.coupon_discount_amount(coupon3, 500))

# Best coupon
assert_eq("promo/best-coupon 10000", 3, promo.coupon_id(promo.best_coupon(coupons, 10000)))

# Remaining uses
assert_eq("promo/coupon-remaining-uses coupon1", 70, promo.coupon_remaining_uses(coupon1))
assert_eq("promo/coupon-remaining-uses coupon2", 0, promo.coupon_remaining_uses(coupon2))
assert_eq("promo/coupon-remaining-uses coupon3", 15, promo.coupon_remaining_uses(coupon3))

# Exhausted coupons
assert_eq("promo/exhausted-coupons", 1, len(promo.exhausted_coupons(coupons)))
assert_eq("promo/valid-coupons", 2, len(promo.valid_coupons(coupons)))

# Coupon exhausted?
assert_false("promo/coupon-exhausted? coupon1", promo.coupon_exhausted(coupon1))
assert_true("promo/coupon-exhausted? coupon2", promo.coupon_exhausted(coupon2))

# Coupon applicable
assert_true("promo/coupon-applicable? coupon1 10000", promo.coupon_applicable(coupon1, 10000))
assert_false("promo/coupon-applicable? coupon1 3000", promo.coupon_applicable(coupon1, 3000))
assert_false("promo/coupon-applicable? coupon2 10000", promo.coupon_applicable(coupon2, 10000))

# Applicable coupons
assert_eq("promo/applicable-coupons 10000", 2, len(promo.applicable_coupons(coupons, 10000)))

# Promotion rules
assert_eq("promo/find-rules-for-campaign 1", 1, len(promo.find_rules_for_campaign(promo_rules, 1)))
assert_eq("promo/find-rules-for-campaign 2", 1, len(promo.find_rules_for_campaign(promo_rules, 2)))

# Tier qualifies
assert_true("promo/tier-qualifies? gold gold", promo.tier_qualifies("gold", "gold"))
assert_true("promo/tier-qualifies? gold silver", promo.tier_qualifies("gold", "silver"))
assert_false("promo/tier-qualifies? bronze gold", promo.tier_qualifies("bronze", "gold"))
assert_true("promo/tier-qualifies? any empty", promo.tier_qualifies("bronze", ""))

# Customer eligible
assert_true("promo/customer-eligible? rule1 cust1", promo.customer_eligible(rule1, cust1))
assert_true("promo/customer-eligible? rule2 cust1", promo.customer_eligible(rule2, cust1))
assert_false("promo/customer-eligible? rule2 cust2", promo.customer_eligible(rule2, cust2))

# Campaign coupon count
assert_eq("promo/campaign-coupon-count 1", 2, promo.campaign_coupon_count(coupons, 1))
assert_eq("promo/campaign-coupon-count 2", 1, promo.campaign_coupon_count(coupons, 2))

# Campaign total uses
assert_eq("promo/campaign-total-uses 1", 80, promo.campaign_total_uses(coupons, 1))
assert_eq("promo/campaign-total-uses 2", 5, promo.campaign_total_uses(coupons, 2))


# ===========================================================================
# EMPLOYEES TESTS
# ===========================================================================

print("--- EMPLOYEES ---")

# Find employee
assert_eq("emp/find-employee-by-id 1", "Alice", emp.employee_name(emp.find_employee_by_id(employees, 1)))
assert_eq("emp/find-employee-by-id 99", None, emp.find_employee_by_id(employees, 99))

# Active employees
assert_eq("emp/active-employees", 2, len(emp.active_employees(employees)))

# By department
assert_eq("emp/employees-by-department sales", 2, len(emp.employees_by_department(employees, "sales")))
assert_eq("emp/employees-by-department support", 1, len(emp.employees_by_department(employees, "support")))

# By role
assert_eq("emp/employees-by-role rep", 2, len(emp.employees_by_role(employees, "rep")))
assert_eq("emp/employees-by-role manager", 1, len(emp.employees_by_role(employees, "manager")))

# Tenure
assert_eq("emp/employee-tenure-days emp1 now=10000", 0, emp.employee_tenure_days(emp1, 10000))
assert_eq("emp/employee-tenure-days emp1 now=100000", 1, emp.employee_tenure_days(emp1, 100000))

# Commission rate
assert_eq("emp/commission-rate emp1 cat1", 5, emp.commission_rate(commission_rules, 1, 1))
assert_eq("emp/commission-rate emp1 cat2", 8, emp.commission_rate(commission_rules, 1, 2))
assert_eq("emp/commission-rate emp2 cat1", 3, emp.commission_rate(commission_rules, 2, 1))
assert_eq("emp/commission-rate emp1 cat3", 0, emp.commission_rate(commission_rules, 1, 3))

# Order commission
assert_eq("emp/order-commission emp1 order1", 450, emp.order_commission(commission_rules, 1, order1, products))
assert_eq("emp/order-commission emp2 order1", 270, emp.order_commission(commission_rules, 2, order1, products))

# Total commission
assert_eq("emp/total-commission emp1", 1110, emp.total_commission(commission_rules, 1, orders, products))

# Top earner
top = emp.top_earner(commission_rules, employees, orders, products)
assert_eq("emp/top-earner", "Alice", emp.employee_name(top))

# Sales targets
assert_eq("emp/targets-for-employee 1", 1, len(emp.targets_for_employee(sales_targets, 1)))
assert_eq("emp/targets-for-employee 2", 1, len(emp.targets_for_employee(sales_targets, 2)))

# Target for period
t = emp.target_for_period(sales_targets, 1, "2024-Q1")
assert_eq("emp/target-for-period emp1 Q1 target", 50000, emp.salestarget_target_amount(t))
assert_eq("emp/target-for-period emp1 Q1 actual", 35000, emp.salestarget_actual_amount(t))

# Target achievement pct
assert_eq("emp/target-achievement-pct st1", 70, emp.target_achievement_pct(st1))
assert_eq("emp/target-achievement-pct st2", 112, emp.target_achievement_pct(st2))

# On target?
assert_false("emp/on-target? st1", emp.on_target(st1))
assert_true("emp/on-target? st2", emp.on_target(st2))


# ===========================================================================
# ANALYTICS TESTS
# ===========================================================================

print("--- ANALYTICS ---")

# Make period metric
m = analytics.make_period_metric("2024-Q4", "revenue", 70000)
assert_eq("analytics/make-period-metric period", "2024-Q4", analytics.periodmetric_period(m))
assert_eq("analytics/make-period-metric name", "revenue", analytics.periodmetric_metric_name(m))
assert_eq("analytics/make-period-metric value", 70000, analytics.periodmetric_value(m))

# Metrics for period
assert_eq("analytics/metrics-for-period Q1", 2, len(analytics.metrics_for_period(metrics, "2024-Q1")))
assert_eq("analytics/metrics-for-period Q2", 2, len(analytics.metrics_for_period(metrics, "2024-Q2")))

# Metric values
assert_eq("analytics/metric-values revenue", [50000, 65000, 55000], analytics.metric_values(metrics, "revenue"))
assert_eq("analytics/metric-values order-count", [100, 130, 110], analytics.metric_values(metrics, "order-count"))

# Latest metric
latest = analytics.latest_metric(metrics, "revenue")
assert_eq("analytics/latest-metric revenue period", "2024-Q3", analytics.periodmetric_period(latest))
assert_eq("analytics/latest-metric revenue value", 55000, analytics.periodmetric_value(latest))

# Earliest metric
earliest = analytics.earliest_metric(metrics, "revenue")
assert_eq("analytics/earliest-metric revenue period", "2024-Q1", analytics.periodmetric_period(earliest))
assert_eq("analytics/earliest-metric revenue value", 50000, analytics.periodmetric_value(earliest))

# Metric count
assert_eq("analytics/metric-count revenue", 3, analytics.metric_count(metrics, "revenue"))
assert_eq("analytics/metric-count order-count", 3, analytics.metric_count(metrics, "order-count"))
assert_eq("analytics/metric-count nonexist", 0, analytics.metric_count(metrics, "nonexist"))

# Metric sum
assert_eq("analytics/metric-sum revenue", 170000, analytics.metric_sum(metrics, "revenue"))
assert_eq("analytics/metric-sum order-count", 340, analytics.metric_sum(metrics, "order-count"))

# Metric avg
assert_eq("analytics/metric-avg revenue", 56666, analytics.metric_avg(metrics, "revenue"))
assert_eq("analytics/metric-avg order-count", 113, analytics.metric_avg(metrics, "order-count"))

# Metric max
assert_eq("analytics/metric-max revenue", 65000, analytics.metric_max(metrics, "revenue"))
assert_eq("analytics/metric-max order-count", 130, analytics.metric_max(metrics, "order-count"))

# Metric min
assert_eq("analytics/metric-min revenue", 50000, analytics.metric_min(metrics, "revenue"))
assert_eq("analytics/metric-min order-count", 100, analytics.metric_min(metrics, "order-count"))

# Empty metrics
assert_eq("analytics/metric-max empty", 0, analytics.metric_max(metrics, "nonexist"))
assert_eq("analytics/metric-min empty", 0, analytics.metric_min(metrics, "nonexist"))
assert_eq("analytics/metric-avg empty", 0, analytics.metric_avg(metrics, "nonexist"))

# All metric names
assert_eq("analytics/all-metric-names", 2, len(analytics.all_metric_names(metrics)))

# All periods
assert_eq("analytics/all-periods", 3, len(analytics.all_periods(metrics)))

# Revenue by period (using actual orders)
periods = [[1700000000, 1700100000, "P1"], [1700200000, 1700300000, "P2"]]
rbp = analytics.revenue_by_period(orders, periods)
assert_eq("analytics/revenue-by-period P1", 15246, analytics.periodmetric_value(rbp[0]))
assert_eq("analytics/revenue-by-period P2", 6669, analytics.periodmetric_value(rbp[1]))

# Order count by period
ocbp = analytics.order_count_by_period(orders, periods)
assert_eq("analytics/order-count-by-period P1", 2, analytics.periodmetric_value(ocbp[0]))
assert_eq("analytics/order-count-by-period P2", 2, analytics.periodmetric_value(ocbp[1]))


# ===========================================================================
# NOTIFICATIONS TESTS
# ===========================================================================

print("--- NOTIFICATIONS ---")

# Find template
assert_eq("notif/find-template-by-id 1", "order-confirm", notif.template_name(notif.find_template_by_id(templates, 1)))
assert_eq("notif/find-template-by-id 99", None, notif.find_template_by_id(templates, 99))
assert_eq("notif/find-template-by-name order-confirm", 1, notif.template_id(notif.find_template_by_name(templates, "order-confirm")))

# Templates for channel
assert_eq("notif/templates-for-channel email", 2, len(notif.templates_for_channel(templates, "email")))
assert_eq("notif/templates-for-channel sms", 1, len(notif.templates_for_channel(templates, "sms")))

# Create notification
n = notif.create_notification(10, tmpl1, cust1, 1001, "order", 5000)
assert_eq("notif/create-notification status", "pending", notif.notification_status(n))
assert_eq("notif/create-notification template-id", 1, notif.notification_template_id(n))
assert_eq("notif/create-notification customer-id", 1, notif.notification_customer_id(n))

# Send notification
sent = notif.send_notification(notif3, 3000)
assert_eq("notif/send-notification status", "sent", notif.notification_status(sent))
assert_eq("notif/send-notification sent-at", 3000, notif.notification_sent_at(sent))
# Send already sent: no change
same = notif.send_notification(notif1, 5000)
assert_eq("notif/send-notification already sent", "sent", notif.notification_status(same))
assert_eq("notif/send-notification preserves sent-at", 1100, notif.notification_sent_at(same))

# Fail notification (only from pending)
failed = notif.fail_notification(notif3)
assert_eq("notif/fail-notification status", "failed", notif.notification_status(failed))
# Fail non-pending: no change
same = notif.fail_notification(notif1)
assert_eq("notif/fail-notification already sent", "sent", notif.notification_status(same))

# Retry notification (only from failed)
retried = notif.retry_notification(notif4)
assert_eq("notif/retry-notification status", "pending", notif.notification_status(retried))
# Retry non-failed: no change
same = notif.retry_notification(notif3)
assert_eq("notif/retry-notification not failed", "pending", notif.notification_status(same))

# Find notification
assert_eq("notif/find-notification-by-id 1", 1, notif.notification_id(notif.find_notification_by_id(notifications, 1)))

# Notifications for customer
assert_eq("notif/notifications-for-customer 1", 3, len(notif.notifications_for_customer(notifications, 1)))
assert_eq("notif/notifications-for-customer 2", 1, len(notif.notifications_for_customer(notifications, 2)))

# Notifications by status
assert_eq("notif/notifications-by-status sent", 2, len(notif.notifications_by_status(notifications, "sent")))
assert_eq("notif/notifications-by-status pending", 1, len(notif.notifications_by_status(notifications, "pending")))
assert_eq("notif/notifications-by-status failed", 1, len(notif.notifications_by_status(notifications, "failed")))
assert_eq("notif/pending-notifications", 1, len(notif.pending_notifications(notifications)))
assert_eq("notif/sent-notifications", 2, len(notif.sent_notifications(notifications)))

# Notifications for reference
assert_eq("notif/notifications-for-reference order 1", 1, len(notif.notifications_for_reference(notifications, 1, "order")))
assert_eq("notif/notifications-for-reference order 2", 1, len(notif.notifications_for_reference(notifications, 2, "order")))
assert_eq("notif/notifications-for-reference shipment 1", 1, len(notif.notifications_for_reference(notifications, 1, "shipment")))

# Preferences
assert_eq("notif/customer-preferences cust1", 2, len(notif.customer_preferences(preferences, 1)))
assert_eq("notif/customer-preferences cust2", 1, len(notif.customer_preferences(preferences, 2)))

# Channel enabled
assert_true("notif/channel-enabled? cust1 email", notif.channel_enabled(preferences, 1, "email"))
assert_false("notif/channel-enabled? cust1 sms", notif.channel_enabled(preferences, 1, "sms"))
assert_true("notif/channel-enabled? cust2 email", notif.channel_enabled(preferences, 2, "email"))
assert_true("notif/channel-enabled? cust2 sms (no pref)", notif.channel_enabled(preferences, 2, "sms"))

# Set preference (update existing)
updated = notif.set_preference(preferences, 1, "sms", True)
assert_true("notif/set-preference update", notif.channel_enabled(updated, 1, "sms"))
# Set preference (add new)
added = notif.set_preference(preferences, 3, "email", False)
assert_eq("notif/set-preference add", 4, len(added))
assert_false("notif/set-preference add check", notif.channel_enabled(added, 3, "email"))

# Delivery rate
assert_eq("notif/delivery-rate-pct", 66, notif.delivery_rate_pct(notifications))


# ===========================================================================
# AUDIT TESTS
# ===========================================================================

print("--- AUDIT ---")

# Create audit entry
e = audit.create_audit_entry(10, "order", 5, "create", 1, 5000, "test")
assert_eq("audit/create-audit-entry entity-type", "order", audit.auditentry_entity_type(e))
assert_eq("audit/create-audit-entry entity-id", 5, audit.auditentry_entity_id(e))
assert_eq("audit/create-audit-entry action", "create", audit.auditentry_action(e))
assert_eq("audit/create-audit-entry actor-id", 1, audit.auditentry_actor_id(e))

# Audit order
e = audit.audit_order(20, order1, 1, "create", 5000)
assert_eq("audit/audit-order entity-type", "order", audit.auditentry_entity_type(e))
assert_eq("audit/audit-order entity-id", 1001, audit.auditentry_entity_id(e))
assert_eq("audit/audit-order detail", "pending", audit.auditentry_detail(e))

# Audit shipment
e = audit.audit_shipment(21, shipment1, 2, "deliver", 5000)
assert_eq("audit/audit-shipment entity-type", "shipment", audit.auditentry_entity_type(e))
assert_eq("audit/audit-shipment entity-id", 1, audit.auditentry_entity_id(e))
assert_eq("audit/audit-shipment detail", "delivered", audit.auditentry_detail(e))

# Audit product
e = audit.audit_product(22, prod1, 1, "update", 5000)
assert_eq("audit/audit-product entity-type", "product", audit.auditentry_entity_type(e))
assert_eq("audit/audit-product entity-id", 1, audit.auditentry_entity_id(e))
assert_eq("audit/audit-product detail", "Widget A", audit.auditentry_detail(e))

# Entries for entity
assert_eq("audit/entries-for-entity order 1", 2, len(audit.entries_for_entity(audit_entries, "order", 1)))
assert_eq("audit/entries-for-entity shipment 1", 1, len(audit.entries_for_entity(audit_entries, "shipment", 1)))
assert_eq("audit/entries-for-entity invoice 1", 1, len(audit.entries_for_entity(audit_entries, "invoice", 1)))
assert_eq("audit/entries-for-entity order 99", 0, len(audit.entries_for_entity(audit_entries, "order", 99)))

# Entries by actor
assert_eq("audit/entries-by-actor 1", 3, len(audit.entries_by_actor(audit_entries, 1)))
assert_eq("audit/entries-by-actor 2", 1, len(audit.entries_by_actor(audit_entries, 2)))
assert_eq("audit/entries-by-actor 99", 0, len(audit.entries_by_actor(audit_entries, 99)))

# Entries by action
assert_eq("audit/entries-by-action create", 3, len(audit.entries_by_action(audit_entries, "create")))
assert_eq("audit/entries-by-action update", 1, len(audit.entries_by_action(audit_entries, "update")))

# Entries in period
assert_eq("audit/entries-in-period 1000-1500", 4, len(audit.entries_in_period(audit_entries, 1000, 2000)))
assert_eq("audit/entries-in-period 1500-2000", 2, len(audit.entries_in_period(audit_entries, 1500, 2000)))
assert_eq("audit/entries-in-period 3000-4000", 0, len(audit.entries_in_period(audit_entries, 3000, 4000)))

# Entry count by type
assert_eq("audit/entry-count-by-type order", 2, audit.entry_count_by_type(audit_entries, "order"))
assert_eq("audit/entry-count-by-type shipment", 1, audit.entry_count_by_type(audit_entries, "shipment"))
assert_eq("audit/entry-count-by-type invoice", 1, audit.entry_count_by_type(audit_entries, "invoice"))

# Recent entries
recent = audit.recent_entries(audit_entries, 2)
assert_eq("audit/recent-entries count", 2, len(recent))
assert_eq("audit/recent-entries first ts", 2000, audit.auditentry_timestamp(recent[0]))

# Actor action count
assert_eq("audit/actor-action-count 1", 3, audit.actor_action_count(audit_entries, 1))
assert_eq("audit/actor-action-count 2", 1, audit.actor_action_count(audit_entries, 2))

# Entries by entity type
assert_eq("audit/entries-by-entity-type order", 2, len(audit.entries_by_entity_type(audit_entries, "order")))

# Distinct actors
assert_eq("audit/distinct-actors count", 2, len(audit.distinct_actors(audit_entries)))

# Distinct entity types
assert_eq("audit/distinct-entity-types count", 3, len(audit.distinct_entity_types(audit_entries)))


# ===========================================================================
# CROSS-MODULE TESTS
# ===========================================================================

print("--- CROSS-MODULE ---")

# Shipping + Orders: create shipment from order
s = ship.create_shipment(100, order1, carrier2, 1, 8, zone2)
assert_eq("cross: ship from order cost", 840, ship.shipment_shipping_cost(s))
assert_eq("cross: ship from order order-id", 1001, ship.shipment_order_id(s))

# Billing + Orders: create invoice from order
i = bill.create_invoice(100, order2, cust2, 5000, 7000)
assert_eq("cross: invoice from order subtotal", 6900, i.subtotal)
assert_eq("cross: invoice from order total", 6831, i.total)
assert_eq("cross: invoice from order cust-id", 2, i.customer_id)

# Employees + Orders + Catalog: commission calculation
assert_eq("cross: emp2 commission order2", 0, emp.order_commission(commission_rules, 2, order2, products))
assert_eq("cross: emp1 commission order2", 360, emp.order_commission(commission_rules, 1, order2, products))

# Promotions + Orders + Customers: rule eligibility
assert_false("cross: rule2 order1 not eligible", promo.order_eligible(rule2, order1))
assert_true("cross: rule1 order1 eligible", promo.order_eligible(rule1, order1))
assert_true("cross: rule1 applies cust1 order1", promo.rule_applies(rule1, cust1, order1))

# Audit + Orders: audit an order
e = audit.audit_order(200, order1, 1, "ship", 5000)
assert_eq("cross: audit order entity-id", 1001, audit.auditentry_entity_id(e))

# Notifications + Customers: create notification using customer
n = notif.create_notification(200, tmpl2, cust2, 2, "shipment", 5000)
assert_eq("cross: notification customer-id", 2, notif.notification_customer_id(n))
assert_eq("cross: notification template-id", 2, notif.notification_template_id(n))

# Procurement + Catalog: lines reference product costs
assert_eq("cross: poline1 vs catalog cost", 400, proc.poline_unit_cost(poline1))

# Billing + Shipping: total cost of fulfilling an order
order_total = ord.order_total(order1)
ship_cost = ship.shipping_cost_for_order(shipments, 1001)
all_in = order_total + ship_cost
assert_eq("cross: order1 all-in cost", 9415, all_in)


# ===========================================================================
# Summary
# ===========================================================================

print("")
print("---")
print(f"{pass_count} passed, {fail_count} failed")
if fail_count > 0:
    sys.exit(1)
