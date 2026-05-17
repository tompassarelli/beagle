import functools
from typing import Any

import catalog as cat
import inventory as inv
import customers as cust
import orders as ord


def inventory_summary_report(levels: list, products: list, warehouses: list) -> list:
    return [
        {
            "warehouse-name": wh.name,
            "location": wh.location,
            "item-count": inv.warehouse_item_count(levels, wh.id),
            "total-units": inv.warehouse_total_units(levels, wh.id),
            "value": inv.stock_value_at_warehouse(levels, wh.id, products),
            "utilization-pct": inv.warehouse_utilization_pct(levels, wh),
        }
        for wh in warehouses
    ]


def low_stock_report(levels: list, products: list) -> list:
    low = inv.low_stock_items(levels)
    result = []
    for sl in low:
        prod = cat.find_product_by_id(products, sl.product_id)
        pname = "unknown" if prod is None else prod.name
        result.append({
            "product-name": pname,
            "product-id": sl.product_id,
            "quantity": sl.quantity,
            "min-quantity": sl.min_quantity,
            "deficit": sl.min_quantity - sl.quantity,
        })
    return result


def reorder_report(levels: list, products: list, suppliers: list) -> list:
    needed = inv.reorder_needed(levels)
    result = []
    for sl in needed:
        prod = cat.find_product_by_id(products, sl.product_id)
        pname = "unknown" if prod is None else prod.name
        sup_id = 0 if prod is None else prod.supplier_id
        sup = cat.find_supplier_by_id(suppliers, sup_id)
        sup_name = "unknown" if sup is None else sup.name
        qty = inv.reorder_quantity(sl)
        cost = 0 if prod is None else qty * prod.unit_cost
        result.append({
            "product-name": pname,
            "supplier-name": sup_name,
            "reorder-qty": qty,
            "estimated-cost": cost,
            "lead-time": 0 if sup is None else sup.lead_time_days,
        })
    return result


def sales_summary(orders: list) -> dict:
    all_orders = orders
    active = ord.active_orders(all_orders)
    pending = ord.pending_orders(all_orders)
    return {
        "total-orders": len(all_orders),
        "active-orders": len(active),
        "pending-orders": len(pending),
        "total-revenue": ord.total_revenue(all_orders),
        "total-tax": ord.total_tax_collected(all_orders),
        "total-discounts": ord.total_discounts_given(all_orders),
        "avg-order-value": ord.avg_order_value(all_orders),
    }


def product_sales_report(orders: list, products: list) -> list:
    return [
        {
            "product-name": p.name,
            "sku": p.sku,
            "units-sold": ord.product_units_ordered(orders, p.id),
            "revenue": ord.product_revenue(orders, p.id),
            "margin-pct": cat.product_margin_pct(p),
        }
        for p in cat.active_products(products)
    ]


def top_products_by_revenue(orders: list, products: list, n: int) -> list:
    report = product_sales_report(orders, products)
    sorted_report = sorted(report, key=lambda r: r["revenue"], reverse=True)
    return sorted_report[:n]


def top_products_by_units(orders: list, products: list, n: int) -> list:
    report = product_sales_report(orders, products)
    sorted_report = sorted(report, key=lambda r: r["units-sold"], reverse=True)
    return sorted_report[:n]


def customer_report(customers: list, orders: list) -> list:
    return [
        {
            "customer-name": c.name,
            "tier": c.tier,
            "order-count": ord.customer_order_count(orders, c.id),
            "total-spend": ord.customer_total_spend(orders, c.id),
            "avg-order": ord.customer_avg_order(orders, c.id),
        }
        for c in customers
    ]


def top_customers_by_spend(customers: list, orders: list, n: int) -> list:
    report = customer_report(customers, orders)
    sorted_report = sorted(report, key=lambda r: r["total-spend"], reverse=True)
    return sorted_report[:n]


def tier_revenue_report(customers: list, orders: list) -> list:
    tiers = ["gold", "silver", "bronze"]
    result = []
    for tier in tiers:
        tier_custs = cust.customers_by_tier(customers, tier)
        cust_ids = [c.id for c in tier_custs]
        tier_orders = [o for o in orders if any(o.customer_id == cid for cid in cust_ids)]
        revenue = ord.total_revenue(tier_orders)
        result.append({
            "tier": tier,
            "customer-count": len(tier_custs),
            "order-count": len(tier_orders),
            "revenue": revenue,
        })
    return result


def category_performance_report(orders: list, products: list, categories: list) -> list:
    result = []
    for c in categories:
        cat_prods = cat.products_by_category(products, c.id)
        revenue = functools.reduce(
            lambda acc, p: acc + ord.product_revenue(orders, p.id),
            cat_prods,
            0,
        )
        units = functools.reduce(
            lambda acc, p: acc + ord.product_units_ordered(orders, p.id),
            cat_prods,
            0,
        )
        result.append({
            "category-name": c.name,
            "product-count": len(cat_prods),
            "total-revenue": revenue,
            "total-units": units,
            "avg-margin": cat.category_avg_margin(products, c.id),
        })
    return result


def supplier_performance_report(orders: list, products: list, suppliers: list) -> list:
    result = []
    for s in suppliers:
        sup_prods = cat.products_by_supplier(products, s.id)
        revenue = functools.reduce(
            lambda acc, p: acc + ord.product_revenue(orders, p.id),
            sup_prods,
            0,
        )
        units = functools.reduce(
            lambda acc, p: acc + ord.product_units_ordered(orders, p.id),
            sup_prods,
            0,
        )
        result.append({
            "supplier-name": s.name,
            "product-count": len(sup_prods),
            "total-revenue": revenue,
            "total-units": units,
            "lead-time": s.lead_time_days,
        })
    return result


def fulfillment_report(orders: list, levels: list) -> list:
    pending = ord.pending_orders(orders)
    return [
        {
            "order-id": o.id,
            "customer-id": o.customer_id,
            "total": o.total,
            "can-fulfill": ord.can_fulfill_order(levels, o),
            "unfulfillable-line-count": len(ord.unfulfillable_lines(levels, o)),
        }
        for o in pending
    ]


def fulfillment_rate(orders: list, levels: list) -> int:
    pending = ord.pending_orders(orders)
    cnt = len(pending)
    if cnt == 0:
        return 100
    fulfillable = len([o for o in pending if ord.can_fulfill_order(levels, o)])
    return (fulfillable * 100) // cnt


def dashboard(products: list, suppliers: list, categories: list, levels: list, warehouses: list, customers: list, orders: list) -> dict:
    return {
        "catalog": {
            "total-products": len(products),
            "active-products": len(cat.active_products(products)),
            "total-value": cat.total_catalog_value(products),
            "avg-price": cat.avg_unit_price(products),
        },
        "inventory": {
            "total-value": inv.total_inventory_value(levels, products),
            "retail-value": inv.stock_retail_value(levels, products),
            "low-stock-count": len(inv.low_stock_items(levels)),
            "reorder-cost": inv.reorder_cost(levels, products),
        },
        "customers": {
            "total-count": cust.total_customer_count(customers),
            "tier-counts": cust.count_by_tier(customers),
        },
        "orders": {
            "total-orders": len(orders),
            "total-revenue": ord.total_revenue(orders),
            "avg-order-value": ord.avg_order_value(orders),
            "fulfillment-rate": fulfillment_rate(orders, levels),
        },
    }


def format_report_line(label: str, value: int) -> str:
    return label + ": " + cat.format_price(value)


def format_report_header(title: str) -> str:
    return "=== " + title + " ==="


def print_inventory_summary(levels: list, products: list, warehouses: list) -> list:
    report = inventory_summary_report(levels, products, warehouses)
    print(format_report_header("Inventory Summary"))
    for r in report:
        print(
            r["warehouse-name"] + " (" + r["location"] + ")"
            + " | Items: " + str(r["item-count"])
            + " | Units: " + str(r["total-units"])
            + " | Value: " + cat.format_price(r["value"])
            + " | Util: " + str(r["utilization-pct"]) + "%"
        )
    return report


def print_sales_summary(orders: list) -> dict:
    report = sales_summary(orders)
    print(format_report_header("Sales Summary"))
    print("Orders: " + str(report["total-orders"]))
    print(format_report_line("Revenue", report["total-revenue"]))
    print(format_report_line("Tax", report["total-tax"]))
    print(format_report_line("Discounts", report["total-discounts"]))
    return report


def product_profitability(orders: list, products: list) -> list:
    result = []
    for p in cat.active_products(products):
        revenue = ord.product_revenue(orders, p.id)
        units = ord.product_units_ordered(orders, p.id)
        cost_of_goods = units * p.unit_cost
        gross_profit = revenue - cost_of_goods
        margin = 0 if revenue == 0 else (gross_profit * 100) // revenue
        result.append({
            "product-name": p.name,
            "revenue": revenue,
            "cost-of-goods": cost_of_goods,
            "gross-profit": gross_profit,
            "margin-pct": margin,
        })
    return result


def most_profitable_products(orders: list, products: list, n: int) -> list:
    report = product_profitability(orders, products)
    sorted_report = sorted(report, key=lambda r: r["gross-profit"], reverse=True)
    return sorted_report[:n]


def unprofitable_products(orders: list, products: list) -> list:
    return [r for r in product_profitability(orders, products) if r["gross-profit"] <= 0]


def customer_lifetime_value(c: Any, orders: list, current_year: int) -> dict:
    total_spend = ord.customer_total_spend(orders, c.id)
    tenure = cust.customer_tenure(c, current_year)
    annual_value = total_spend if tenure == 0 else total_spend // tenure
    return {
        "customer-name": c.name,
        "tier": c.tier,
        "total-spend": total_spend,
        "tenure-years": tenure,
        "annual-value": annual_value,
    }


def clv_report(customers: list, orders: list, current_year: int) -> list:
    return [customer_lifetime_value(c, orders, current_year) for c in customers]


def top_clv_customers(customers: list, orders: list, current_year: int, n: int) -> list:
    report = clv_report(customers, orders, current_year)
    sorted_report = sorted(report, key=lambda r: r["annual-value"], reverse=True)
    return sorted_report[:n]


def period_comparison(orders: list, p1_start: int, p1_end: int, p2_start: int, p2_end: int) -> dict:
    p1_orders = ord.orders_in_period(orders, p1_start, p1_end)
    p2_orders = ord.orders_in_period(orders, p2_start, p2_end)
    p1_rev = ord.total_revenue(p2_orders)
    p2_rev = ord.total_revenue(p2_orders)
    rev_change = p2_rev - p1_rev
    rev_change_pct = 0 if p1_rev == 0 else (rev_change * 100) // p1_rev
    return {
        "period1-revenue": p1_rev,
        "period1-orders": len(p1_orders),
        "period2-revenue": p2_rev,
        "period2-orders": len(p2_orders),
        "revenue-change": rev_change,
        "revenue-change-pct": rev_change_pct,
    }


def inventory_turnover(orders: list, levels: list, products: list) -> dict:
    total_cogs = functools.reduce(
        lambda acc, p: acc + ord.product_units_ordered(orders, p.id) * p.unit_cost,
        products,
        0,
    )
    avg_inv_value = inv.total_inventory_value(levels, products)
    return {
        "cost-of-goods-sold": total_cogs,
        "avg-inventory-value": avg_inv_value,
        "turnover-ratio": 0 if avg_inv_value == 0 else (total_cogs * 100) // avg_inv_value,
    }


def product_360_report(p: Any, orders: list, levels: list) -> dict:
    units_sold = ord.product_units_ordered(orders, p.id)
    revenue = ord.product_revenue(orders, p.id)
    stock_qty = inv.total_stock_for_product(levels, p.id)
    margin = cat.product_margin(p)
    margin_pct = cat.product_margin_pct(p)
    return {
        "name": p.name,
        "sku": p.sku,
        "price": p.unit_price,
        "cost": p.unit_cost,
        "margin": margin,
        "margin-pct": margin_pct,
        "units-sold": units_sold,
        "revenue": revenue,
        "stock-on-hand": stock_qty,
        "active": p.active,
    }


def full_product_report(products: list, orders: list, levels: list) -> list:
    return [product_360_report(p, orders, levels) for p in products]


def executive_summary(products: list, suppliers: list, categories: list, levels: list, warehouses: list, customers: list, orders: list) -> dict:
    dash = dashboard(products, suppliers, categories, levels, warehouses, customers, orders)
    top_prods = top_products_by_revenue(orders, products, 3)
    top_custs = top_customers_by_spend(customers, orders, 3)
    fulfill = fulfillment_rate(orders, levels)
    return {
        "dashboard": dash,
        "top-products": [r["product-name"] for r in top_prods],
        "top-customers": [r["customer-name"] for r in top_custs],
        "fulfillment-rate": fulfill,
    }
