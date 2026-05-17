from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional
import catalog as cat
import inventory as inv
import orders as ord
import billing as bil
import shipping as ship


@dataclass
class PeriodMetric:
    period: str
    metric_name: str
    value: int


@dataclass
class TrendResult:
    metric_name: str
    direction: str
    change_pct: int


@dataclass
class Bucket:
    label: str
    count: int
    total: int


def periodmetric_period(r: PeriodMetric) -> str:
    return r.period


def periodmetric_metric_name(r: PeriodMetric) -> str:
    return r.metric_name


def periodmetric_value(r: PeriodMetric) -> int:
    return r.value


def trendresult_metric_name(r: TrendResult) -> str:
    return r.metric_name


def trendresult_direction(r: TrendResult) -> str:
    return r.direction


def trendresult_change_pct(r: TrendResult) -> int:
    return r.change_pct


def bucket_label(r: Bucket) -> str:
    return r.label


def bucket_count(r: Bucket) -> int:
    return r.count


def bucket_total(r: Bucket) -> int:
    return r.total


def make_period_metric(period: str, metric_name: str, value: int) -> PeriodMetric:
    return PeriodMetric(period, metric_name, value)


def metrics_for_period(metrics: list[PeriodMetric], period: str) -> list[PeriodMetric]:
    return [m for m in metrics if m.period == period]


def metric_values(metrics: list[PeriodMetric], metric_name: str) -> list[int]:
    matching = [m for m in metrics if m.metric_name == metric_name]
    sorted_m = sorted(matching, key=periodmetric_period)
    return [m.value for m in sorted_m]


def latest_metric(metrics: list[PeriodMetric], metric_name: str) -> Optional[PeriodMetric]:
    matching = [m for m in metrics if m.metric_name == metric_name]
    sorted_m = sorted(matching, key=periodmetric_period)
    if not sorted_m:
        return None
    return sorted_m[-1]


def earliest_metric(metrics: list[PeriodMetric], metric_name: str) -> Optional[PeriodMetric]:
    matching = [m for m in metrics if m.metric_name == metric_name]
    sorted_m = sorted(matching, key=periodmetric_period)
    if not sorted_m:
        return None
    return sorted_m[0]


def metric_count(metrics: list[PeriodMetric], metric_name: str) -> int:
    return len([m for m in metrics if m.metric_name == metric_name])


def metric_sum(metrics: list[PeriodMetric], metric_name: str) -> int:
    return functools.reduce(lambda acc, v: acc + v, metric_values(metrics, metric_name), 0)


def metric_avg(metrics: list[PeriodMetric], metric_name: str) -> int:
    vals = metric_values(metrics, metric_name)
    cnt = len(vals)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, v: acc + v, vals, 0) // cnt


def metric_max(metrics: list[PeriodMetric], metric_name: str) -> int:
    vals = metric_values(metrics, metric_name)
    if not vals:
        return 0
    return functools.reduce(lambda best, v: v if v > best else best, vals[1:], vals[0])


def metric_min(metrics: list[PeriodMetric], metric_name: str) -> int:
    vals = metric_values(metrics, metric_name)
    if not vals:
        return 0
    return functools.reduce(lambda best, v: v if v < best else best, vals[1:], vals[0])


def all_metric_names(metrics: list[PeriodMetric]) -> list[str]:
    seen: set[str] = set()
    result = []
    for m in metrics:
        name = m.metric_name
        if name not in seen:
            seen.add(name)
            result.append(name)
    return result


def all_periods(metrics: list[PeriodMetric]) -> list[str]:
    seen: set[str] = set()
    result = []
    for m in metrics:
        p = m.period
        if p not in seen:
            seen.add(p)
            result.append(p)
    return result


def revenue_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "revenue", ord.total_revenue(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def order_count_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "order-count", len(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def avg_order_value_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "avg-order-value", ord.avg_order_value(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def discount_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "discounts", ord.total_discounts_given(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def tax_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "tax", ord.total_tax_collected(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def units_by_period(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "units-ordered", ord.total_units_ordered(ord.orders_in_period(orders, p[0], p[1])))
        for p in periods
    ]


def inventory_value_metric(levels: list[inv.StockLevel], products: list[cat.Product], label: str) -> PeriodMetric:
    val = inv.total_inventory_value(levels, products)
    return PeriodMetric(label, "inventory-value", val)


def low_stock_count_metric(levels: list[inv.StockLevel], label: str) -> PeriodMetric:
    cnt = len(inv.low_stock_items(levels))
    return PeriodMetric(label, "low-stock-count", cnt)


def out_of_stock_count_metric(levels: list[inv.StockLevel], label: str) -> PeriodMetric:
    cnt = len(inv.out_of_stock_items(levels))
    return PeriodMetric(label, "out-of-stock-count", cnt)


def retail_value_metric(levels: list[inv.StockLevel], products: list[cat.Product], label: str) -> PeriodMetric:
    val = inv.stock_retail_value(levels, products)
    return PeriodMetric(label, "retail-value", val)


def inventory_snapshot(levels: list[inv.StockLevel], products: list[cat.Product], label: str) -> list[PeriodMetric]:
    return [
        inventory_value_metric(levels, products, label),
        retail_value_metric(levels, products, label),
        low_stock_count_metric(levels, label),
        out_of_stock_count_metric(levels, label),
    ]


def collection_by_period(payments: list[bil.Payment], invoices: list[bil.Invoice], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_payments = [
            pay for pay in payments
            if pay.status == "completed" and pay.processed_at >= start and pay.processed_at <= end
        ]
        total = functools.reduce(lambda acc, pay: acc + pay.amount, period_payments, 0)
        return PeriodMetric(label, "collections", total)
    return [make_metric(p) for p in periods]


def outstanding_by_period(invoices: list[bil.Invoice], payments: list[bil.Payment], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "outstanding", bil.total_outstanding(invoices, payments))
        for p in periods
    ]


def invoiced_by_period(invoices: list[bil.Invoice], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_invoices = [
            inv_item for inv_item in invoices
            if inv_item.issued_at >= start and inv_item.issued_at <= end
        ]
        total = functools.reduce(lambda acc, inv_item: acc + inv_item.total, period_invoices, 0)
        return PeriodMetric(label, "invoiced", total)
    return [make_metric(p) for p in periods]


def overdue_count_by_period(invoices: list[bil.Invoice], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        end = p[1]
        label = p[2]
        overdue = bil.overdue_invoices(invoices, end)
        cnt = len(overdue)
        return PeriodMetric(label, "overdue-count", cnt)
    return [make_metric(p) for p in periods]


def collection_rate_by_period(invoices: list[bil.Invoice], payments: list[bil.Payment], periods: list[list]) -> list[PeriodMetric]:
    return [
        PeriodMetric(p[2], "collection-rate", bil.collection_rate_pct(invoices, payments))
        for p in periods
    ]


def shipping_cost_by_period(shipments: list[ship.Shipment], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_delivered = [
            s for s in shipments
            if s.status == "delivered" and s.created_at >= start and s.created_at <= end
        ]
        total = functools.reduce(lambda acc, s: acc + s.shipping_cost, period_delivered, 0)
        return PeriodMetric(label, "shipping-cost", total)
    return [make_metric(p) for p in periods]


def delivery_count_by_period(shipments: list[ship.Shipment], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_delivered = [
            s for s in shipments
            if s.status == "delivered" and s.created_at >= start and s.created_at <= end
        ]
        cnt = len(period_delivered)
        return PeriodMetric(label, "deliveries", cnt)
    return [make_metric(p) for p in periods]


def shipment_count_by_period(shipments: list[ship.Shipment], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_ships = [
            s for s in shipments
            if s.status != "cancelled" and s.created_at >= start and s.created_at <= end
        ]
        cnt = len(period_ships)
        return PeriodMetric(label, "shipment-count", cnt)
    return [make_metric(p) for p in periods]


def avg_shipping_cost_by_period(shipments: list[ship.Shipment], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_ships = [
            s for s in shipments
            if s.status != "cancelled" and s.created_at >= start and s.created_at <= end
        ]
        cnt = len(period_ships)
        total = functools.reduce(lambda acc, s: acc + s.shipping_cost, period_ships, 0)
        avg_cost = 0 if cnt == 0 else total // cnt
        return PeriodMetric(label, "avg-shipping-cost", avg_cost)
    return [make_metric(p) for p in periods]


def total_weight_by_period(shipments: list[ship.Shipment], periods: list[list]) -> list[PeriodMetric]:
    def make_metric(p: list) -> PeriodMetric:
        start = p[0]
        end = p[1]
        label = p[2]
        period_delivered = [
            s for s in shipments
            if s.status == "delivered" and s.created_at >= start and s.created_at <= end
        ]
        total_wt = functools.reduce(lambda acc, s: acc + s.weight_kg, period_delivered, 0)
        return PeriodMetric(label, "total-weight", total_wt)
    return [make_metric(p) for p in periods]


def calculate_trend(metrics: list[PeriodMetric], metric_name: str) -> TrendResult:
    vals = metric_values(metrics, metric_name)
    if len(vals) < 2:
        return TrendResult(metric_name, "flat", 0)
    first_val = vals[0]
    last_val = vals[-1]
    if first_val == last_val:
        return TrendResult(metric_name, "flat", 0)
    elif last_val > first_val:
        change = 0 if first_val == 0 else ((last_val - first_val) * 100) // first_val
        return TrendResult(metric_name, "up", change)
    else:
        change = 0 if first_val == 0 else ((first_val - last_val) * 100) // first_val
        return TrendResult(metric_name, "down", change)


def compare_periods(metrics: list[PeriodMetric], metric_name: str, period1: str, period2: str) -> TrendResult:
    matching = [m for m in metrics if m.metric_name == metric_name]
    m1_list = [m for m in matching if m.period == period1]
    m2_list = [m for m in matching if m.period == period2]
    m1 = m1_list[0] if m1_list else None
    m2 = m2_list[0] if m2_list else None
    v1 = 0 if m1 is None else m1.value
    v2 = 0 if m2 is None else m2.value
    if v1 == v2:
        return TrendResult(metric_name, "flat", 0)
    elif v2 > v1:
        change = 0 if v1 == 0 else ((v2 - v1) * 100) // v1
        return TrendResult(metric_name, "up", change)
    else:
        change = 0 if v1 == 0 else ((v1 - v2) * 100) // v1
        return TrendResult(metric_name, "down", change)


def trend_direction(tr: TrendResult) -> str:
    return tr.direction


def trend_is_positive(tr: TrendResult) -> bool:
    return tr.direction == "up"


def trend_is_negative(tr: TrendResult) -> bool:
    return tr.direction == "down"


def trend_magnitude(tr: TrendResult) -> int:
    return tr.change_pct


def trend_summary(tr: TrendResult) -> str:
    name = tr.metric_name
    direction = tr.direction
    pct = tr.change_pct
    if direction == "flat":
        return name + ": flat (no change)"
    elif direction == "up":
        return name + ": up " + str(pct) + "%"
    else:
        return name + ": down " + str(pct) + "%"


def multi_trend(metrics: list[PeriodMetric], metric_names: list[str]) -> list[TrendResult]:
    return [calculate_trend(metrics, name) for name in metric_names]


def bucket_orders_by_value(orders: list[ord.Order], thresholds: list[list]) -> list[Bucket]:
    def make_bucket(t: list) -> Bucket:
        label = t[0]
        lo = t[1]
        hi = t[2]
        matching = [o for o in orders if ord.order_total(o) >= lo and ord.order_total(o) <= hi]
        cnt = len(matching)
        total = functools.reduce(lambda acc, o: acc + ord.order_id(o), matching, 0)
        return Bucket(label, cnt, total)
    return [make_bucket(t) for t in thresholds]


def bucket_customers_by_spend(customers: list[int], orders: list[ord.Order], thresholds: list[list]) -> list[Bucket]:
    def make_bucket(t: list) -> Bucket:
        label = t[0]
        lo = t[1]
        hi = t[2]
        results = functools.reduce(
            lambda acc, cid: (
                {"count": acc["count"] + 1, "total": acc["total"] + ord.customer_total_spend(orders, cid)}
                if ord.customer_total_spend(orders, cid) >= lo and ord.customer_total_spend(orders, cid) <= hi
                else acc
            ),
            customers,
            {"count": 0, "total": 0},
        )
        return Bucket(label, results["count"], results["total"])
    return [make_bucket(t) for t in thresholds]


def sum_bucket_totals(buckets: list[Bucket]) -> int:
    return functools.reduce(lambda acc, b: acc + b.total, buckets, 0)


def sum_bucket_counts(buckets: list[Bucket]) -> int:
    return functools.reduce(lambda acc, b: acc + b.count, buckets, 0)


def largest_bucket(buckets: list[Bucket]) -> Optional[Bucket]:
    if not buckets:
        return None
    return functools.reduce(lambda best, b: b if b.total > best.total else best, buckets[1:], buckets[0])


def most_populated_bucket(buckets: list[Bucket]) -> Optional[Bucket]:
    if not buckets:
        return None
    return functools.reduce(lambda best, b: b if b.count > best.count else best, buckets[1:], buckets[0])


def bucket_summary(b: Bucket) -> str:
    return b.label + ": " + str(b.count) + " items" + ", total " + cat.format_price(b.total)


def bucket_distribution(buckets: list[Bucket]) -> list[dict]:
    grand = functools.reduce(lambda acc, b: acc + b.total, buckets, 0)
    return [
        {"label": b.label, "count": b.count, "total": b.total, "pct": 0 if grand == 0 else (b.total * 100) // grand}
        for b in buckets
    ]


def gross_margin_metric(orders: list[ord.Order], label: str) -> PeriodMetric:
    rev = ord.total_revenue(orders)
    disc = ord.total_discounts_given(orders)
    margin = rev - disc
    return PeriodMetric(label, "gross-margin", margin)


def shipping_to_revenue_pct(orders: list[ord.Order], shipments: list[ship.Shipment]) -> int:
    rev = ord.total_revenue(orders)
    ship_cost = ship.total_shipping_revenue(shipments)
    if rev == 0:
        return 0
    return (ship_cost * 100) // rev


def inventory_turnover_ratio(orders: list[ord.Order], levels: list[inv.StockLevel], products: list[cat.Product]) -> int:
    rev = ord.total_revenue(orders)
    inv_val = inv.total_inventory_value(levels, products)
    if inv_val == 0:
        return 0
    return (rev * 100) // inv_val


def revenue_per_order_line(orders: list[ord.Order]) -> int:
    rev = ord.total_revenue(orders)
    lines = ord.total_line_count(orders)
    if lines == 0:
        return 0
    return rev // lines


def order_size_distribution(orders: list[ord.Order], small_max: int, large_min: int) -> dict:
    small_cnt = len([o for o in orders if ord.order_total(o) <= small_max])
    large_cnt = len([o for o in orders if ord.order_total(o) >= large_min])
    medium_cnt = len([o for o in orders if ord.order_total(o) > small_max and ord.order_total(o) < large_min])
    return {"small": small_cnt, "medium": medium_cnt, "large": large_cnt}


def kpi_dashboard(
    orders: list[ord.Order],
    invoices: list[bil.Invoice],
    payments: list[bil.Payment],
    shipments: list[ship.Shipment],
    levels: list[inv.StockLevel],
    products: list[cat.Product],
) -> dict:
    total_rev = ord.total_revenue(orders)
    total_collected = bil.total_revenue_collected(payments)
    total_out = bil.total_outstanding(invoices, payments)
    total_ship = ship.total_shipping_revenue(shipments)
    inv_val = inv.total_inventory_value(levels, products)
    order_cnt = len(orders)
    return {
        "total-revenue": total_rev,
        "total-collected": total_collected,
        "total-outstanding": total_out,
        "total-shipping": total_ship,
        "inventory-value": inv_val,
        "order-count": order_cnt,
    }


def extended_kpi_dashboard(
    orders: list[ord.Order],
    invoices: list[bil.Invoice],
    payments: list[bil.Payment],
    shipments: list[ship.Shipment],
    levels: list[inv.StockLevel],
    products: list[cat.Product],
) -> dict:
    base = kpi_dashboard(orders, invoices, payments, shipments, levels, products)
    avg_order = ord.avg_order_value(orders)
    total_lines = ord.total_line_count(orders)
    total_units = ord.total_units_ordered(orders)
    total_disc = ord.total_discounts_given(orders)
    total_tax = ord.total_tax_collected(orders)
    pending_cnt = len(ord.pending_orders(orders))
    active_cnt = len(ord.active_orders(orders))
    low_stock_cnt = len(inv.low_stock_items(levels))
    oos_cnt = len(inv.out_of_stock_items(levels))
    ship_rev = ship.total_shipping_revenue(shipments)
    avg_ship = ship.avg_shipping_cost(shipments)
    avg_delivery = ship.avg_delivery_time_days(shipments)
    coll_rate = bil.collection_rate_pct(invoices, payments)
    overdue_cnt = len(bil.overdue_invoices(invoices, 0))
    net_rev = bil.net_revenue(payments)
    return {
        "total-revenue": base["total-revenue"],
        "total-collected": base["total-collected"],
        "total-outstanding": base["total-outstanding"],
        "total-shipping": base["total-shipping"],
        "inventory-value": base["inventory-value"],
        "order-count": base["order-count"],
        "avg-order-value": avg_order,
        "total-line-items": total_lines,
        "total-units-ordered": total_units,
        "total-discounts": total_disc,
        "total-tax": total_tax,
        "pending-orders": pending_cnt,
        "active-orders": active_cnt,
        "low-stock-count": low_stock_cnt,
        "out-of-stock-count": oos_cnt,
        "avg-shipping-cost": avg_ship,
        "avg-delivery-days": avg_delivery,
        "collection-rate": coll_rate,
        "overdue-invoices": overdue_cnt,
        "net-revenue": net_rev,
    }


def period_over_period(
    metrics: list[PeriodMetric], metric_name: str, period1: str, period2: str
) -> dict:
    matching = [m for m in metrics if m.metric_name == metric_name]
    m1_list = [m for m in matching if m.period == period1]
    m2_list = [m for m in matching if m.period == period2]
    m1 = m1_list[0] if m1_list else None
    m2 = m2_list[0] if m2_list else None
    v1 = 0 if m1 is None else m1.value
    v2 = 0 if m2 is None else m2.value
    abs_change = v2 - v1
    pct_change = 0 if v1 == 0 else (abs_change * 100) // v1
    return {
        "metric": metric_name,
        "period1": period1,
        "period2": period2,
        "value1": v1,
        "value2": v2,
        "change": abs_change,
        "change-pct": pct_change,
    }


def generate_all_metrics(orders: list[ord.Order], periods: list[list]) -> list[PeriodMetric]:
    rev = revenue_by_period(orders, periods)
    cnt = order_count_by_period(orders, periods)
    avg_val = avg_order_value_by_period(orders, periods)
    disc = discount_by_period(orders, periods)
    tx = tax_by_period(orders, periods)
    units = units_by_period(orders, periods)
    return list(rev + cnt + avg_val + disc + tx + units)


def format_metric(m: PeriodMetric) -> str:
    return "[" + m.period + "] " + m.metric_name + " = " + str(m.value)


def format_trend(tr: TrendResult) -> str:
    return tr.metric_name + ": " + tr.direction + " " + str(tr.change_pct) + "%"


def format_bucket(b: Bucket) -> str:
    return b.label + ": " + str(b.count) + " items, " + cat.format_price(b.total)


def valid_period_metric(m: PeriodMetric) -> bool:
    return m.period != "" and m.metric_name != ""


def valid_trend_result(tr: TrendResult) -> bool:
    return (
        tr.metric_name != ""
        and (tr.direction == "up" or tr.direction == "down" or tr.direction == "flat")
        and tr.change_pct >= 0
    )


def valid_bucket(b: Bucket) -> bool:
    return b.label != "" and b.count >= 0 and b.total >= 0


def sort_metrics_by_value(metrics: list[PeriodMetric]) -> list[PeriodMetric]:
    return sorted(metrics, key=periodmetric_value)


def sort_metrics_by_period(metrics: list[PeriodMetric]) -> list[PeriodMetric]:
    return sorted(metrics, key=periodmetric_period)


def sort_buckets_by_total(buckets: list[Bucket]) -> list[Bucket]:
    return sorted(buckets, key=bucket_total)


def sort_buckets_by_count(buckets: list[Bucket]) -> list[Bucket]:
    return sorted(buckets, key=bucket_count)


def top_metrics(metrics: list[PeriodMetric], metric_name: str, n: int) -> list[PeriodMetric]:
    matching = [m for m in metrics if m.metric_name == metric_name]
    sorted_m = list(reversed(sorted(matching, key=periodmetric_value)))
    return list(sorted_m[:n])


def bottom_metrics(metrics: list[PeriodMetric], metric_name: str, n: int) -> list[PeriodMetric]:
    matching = [m for m in metrics if m.metric_name == metric_name]
    sorted_m = sorted(matching, key=periodmetric_value)
    return list(sorted_m[:n])


def analytics_summary(
    orders: list[ord.Order],
    invoices: list[bil.Invoice],
    payments: list[bil.Payment],
    shipments: list[ship.Shipment],
    levels: list[inv.StockLevel],
    products: list[cat.Product],
    periods: list[list],
) -> dict:
    rev_metrics = revenue_by_period(orders, periods)
    cnt_metrics = order_count_by_period(orders, periods)
    coll_metrics = collection_by_period(payments, invoices, periods)
    ship_metrics = shipping_cost_by_period(shipments, periods)
    del_metrics = delivery_count_by_period(shipments, periods)
    rev_trend = calculate_trend(rev_metrics, "revenue")
    cnt_trend = calculate_trend(cnt_metrics, "order-count")
    coll_trend = calculate_trend(coll_metrics, "collections")
    ship_trend = calculate_trend(ship_metrics, "shipping-cost")
    kpi = kpi_dashboard(orders, invoices, payments, shipments, levels, products)
    return {
        "kpi": kpi,
        "revenue-trend": rev_trend.direction,
        "revenue-change-pct": rev_trend.change_pct,
        "order-count-trend": cnt_trend.direction,
        "order-count-change-pct": cnt_trend.change_pct,
        "collections-trend": coll_trend.direction,
        "collections-change-pct": coll_trend.change_pct,
        "shipping-trend": ship_trend.direction,
        "shipping-change-pct": ship_trend.change_pct,
        "revenue-metrics": rev_metrics,
        "order-count-metrics": cnt_metrics,
        "collection-metrics": coll_metrics,
        "shipping-cost-metrics": ship_metrics,
        "delivery-metrics": del_metrics,
    }
