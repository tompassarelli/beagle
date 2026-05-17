from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional

import catalog as cat
import inventory as inv
import customers as cust


@dataclass
class OrderLine:
    product_id: int
    quantity: int
    unit_price: int
    line_total: int


@dataclass
class Order:
    id: int
    customer_id: int
    status: str
    lines: list[OrderLine]
    subtotal: int
    tax: int
    discount: int
    total: int
    created_at: int


@dataclass
class ReturnRequest:
    id: int
    order_id: int
    product_id: int
    quantity: int
    reason: str
    status: str


def orderline_product_id(r: OrderLine) -> int:
    return r.product_id


def orderline_quantity(r: OrderLine) -> int:
    return r.quantity


def orderline_unit_price(r: OrderLine) -> int:
    return r.unit_price


def orderline_line_total(r: OrderLine) -> int:
    return r.line_total


def order_id(r: Order) -> int:
    return r.id


def order_customer_id(r: Order) -> int:
    return r.customer_id


def order_status(r: Order) -> str:
    return r.status


def order_lines(r: Order) -> list[OrderLine]:
    return r.lines


def order_subtotal(r: Order) -> int:
    return r.subtotal


def order_tax(r: Order) -> int:
    return r.tax


def order_discount(r: Order) -> int:
    return r.discount


def order_total(r: Order) -> int:
    return r.total


def order_created_at(r: Order) -> int:
    return r.created_at


def returnrequest_id(r: ReturnRequest) -> int:
    return r.id


def returnrequest_order_id(r: ReturnRequest) -> int:
    return r.order_id


def returnrequest_product_id(r: ReturnRequest) -> int:
    return r.product_id


def returnrequest_quantity(r: ReturnRequest) -> int:
    return r.quantity


def returnrequest_reason(r: ReturnRequest) -> str:
    return r.reason


def returnrequest_status(r: ReturnRequest) -> str:
    return r.status


def make_order_line(products: list, prod_id: int, qty: int) -> OrderLine:
    prod = cat.find_product_by_id(products, prod_id)
    price = 0 if prod is None else prod.unit_price
    total = price * qty
    return OrderLine(prod_id, qty, price, total)


def order_line_product_name(ol: OrderLine, products: list) -> str:
    prod = cat.find_product_by_id(products, ol.product_id)
    return "unknown" if prod is None else prod.name


def calculate_subtotal(lines: list[OrderLine]) -> int:
    return functools.reduce(lambda acc, ol: acc + ol.line_total, lines, 0)


def calculate_tax(subtotal: int, tax_rate: float) -> int:
    return int(float(subtotal) * tax_rate)


def calculate_discount(subtotal: int, discount_pct: int) -> int:
    return (subtotal * discount_pct) // 100


def calculate_total(subtotal: int, tax: int, discount: int) -> int:
    return (subtotal + tax) - discount


def customer_discount_pct(customers: list, cust_id: int) -> int:
    c = cust.find_customer_by_id(customers, cust_id)
    return 0 if c is None else cust.tier_discount_pct(c.tier)


def create_order(id: int, cust_id: int, line_specs: list, products: list, categories: list, customers: list, timestamp: int) -> Order:
    lines = [make_order_line(products, spec[0], spec[1]) for spec in line_specs]
    subtotal = calculate_subtotal(lines)
    disc_pct = customer_discount_pct(customers, cust_id)
    discount = calculate_discount(subtotal, disc_pct)
    tax = calculate_tax(subtotal - discount, 0.1)
    total = calculate_total(subtotal, tax, discount)
    return Order(id, cust_id, "pending", lines, subtotal, tax, discount, total, timestamp)


status_pending = "pending"
status_confirmed = "confirmed"
status_shipped = "shipped"
status_delivered = "delivered"
status_cancelled = "cancelled"


def update_status(o: Order, new_status: str) -> Order:
    return Order(o.id, o.customer_id, new_status, o.lines, o.subtotal, o.tax, o.discount, o.total, o.created_at)


def confirm_order(o: Order) -> Order:
    return update_status(o, "confirmed")


def ship_order(o: Order) -> Order:
    return update_status(o, "shipped")


def deliver_order(o: Order) -> Order:
    return update_status(o, "delivered")


def cancel_order(o: Order) -> Order:
    return update_status(o, "cancelled")


def order_pending(o: Order) -> bool:
    return o.status == "pending"


def order_active(o: Order) -> bool:
    return o.status != "cancelled" and o.status != "delivered"


def can_fulfill_line(levels: list, ol: OrderLine) -> bool:
    return inv.can_fulfill(levels, ol.product_id, ol.quantity)


def can_fulfill_order(levels: list, o: Order) -> bool:
    return all(can_fulfill_line(levels, ol) for ol in o.lines)


def unfulfillable_lines(levels: list, o: Order) -> list[OrderLine]:
    return [ol for ol in o.lines if not can_fulfill_line(levels, ol)]


def fulfillment_shortage(levels: list, ol: OrderLine) -> int:
    avail = inv.available_quantity(levels, ol.product_id)
    needed = ol.quantity
    return 0 if avail >= needed else needed - avail


def orders_by_customer(orders: list[Order], cust_id: int) -> list[Order]:
    return [o for o in orders if o.customer_id == cust_id]


def orders_by_status(orders: list[Order], status: str) -> list[Order]:
    return [o for o in orders if o.status == status]


def pending_orders(orders: list[Order]) -> list[Order]:
    return orders_by_status(orders, "pending")


def active_orders(orders: list[Order]) -> list[Order]:
    return [o for o in orders if order_active(o)]


def orders_above_total(orders: list[Order], min_total: int) -> list[Order]:
    return [o for o in orders if o.total >= min_total]


def find_order_by_id(orders: list[Order], id: int) -> Optional[Order]:
    matches = [o for o in orders if o.id == id]
    return matches[0] if matches else None


def sort_by_total(orders: list[Order]) -> list[Order]:
    return sorted(orders, key=lambda o: o.total)


def sort_by_date(orders: list[Order]) -> list[Order]:
    return sorted(orders, key=lambda o: o.created_at)


def total_revenue(orders: list[Order]) -> int:
    return functools.reduce(lambda acc, o: acc + o.total, orders, 0)


def total_discounts_given(orders: list[Order]) -> int:
    return functools.reduce(lambda acc, o: acc + o.discount, orders, 0)


def total_tax_collected(orders: list[Order]) -> int:
    return functools.reduce(lambda acc, o: acc + o.tax, orders, 0)


def avg_order_value(orders: list[Order]) -> int:
    cnt = len(orders)
    return 0 if cnt == 0 else total_revenue(orders) // cnt


def order_count_by_status(orders: list[Order], status: str) -> int:
    return len(orders_by_status(orders, status))


def largest_order(orders: list[Order]) -> Order:
    return functools.reduce(
        lambda best, o: o if o.total > best.total else best,
        orders[1:],
        orders[0],
    )


def smallest_order(orders: list[Order]) -> Order:
    return functools.reduce(
        lambda best, o: o if o.total < best.total else best,
        orders[1:],
        orders[0],
    )


def customer_order_count(orders: list[Order], cust_id: int) -> int:
    return len(orders_by_customer(orders, cust_id))


def customer_total_spend(orders: list[Order], cust_id: int) -> int:
    return total_revenue(orders_by_customer(orders, cust_id))


def customer_avg_order(orders: list[Order], cust_id: int) -> int:
    return avg_order_value(orders_by_customer(orders, cust_id))


def total_line_count(orders: list[Order]) -> int:
    return functools.reduce(lambda acc, o: acc + len(o.lines), orders, 0)


def total_units_ordered(orders: list[Order]) -> int:
    return functools.reduce(
        lambda acc, o: acc + functools.reduce(lambda a, ol: a + ol.quantity, o.lines, 0),
        orders,
        0,
    )


def product_units_ordered(orders: list[Order], prod_id: int) -> int:
    return functools.reduce(
        lambda acc, o: acc + functools.reduce(
            lambda a, ol: a + ol.quantity if ol.product_id == prod_id else a,
            o.lines,
            0,
        ),
        orders,
        0,
    )


def product_revenue(orders: list[Order], prod_id: int) -> int:
    return functools.reduce(
        lambda acc, o: acc + functools.reduce(
            lambda a, ol: a + ol.line_total if ol.product_id == prod_id else a,
            o.lines,
            0,
        ),
        orders,
        0,
    )


def order_summary(o: Order) -> str:
    return "Order #" + str(o.id) + " | " + o.status + " | " + cat.format_price(o.total) + " (" + str(len(o.lines)) + " items)"


def order_line_summary(ol: OrderLine, products: list) -> str:
    return (
        order_line_product_name(ol, products)
        + " x" + str(ol.quantity)
        + " @ " + cat.format_price(ol.unit_price)
        + " = " + cat.format_price(ol.line_total)
    )


def valid_order(o: Order) -> bool:
    return o.id > 0 and o.customer_id > 0 and len(o.lines) > 0 and o.total >= 0


def valid_order_line(ol: OrderLine) -> bool:
    return ol.product_id > 0 and ol.quantity > 0 and ol.unit_price > 0


def create_return(id: int, order_id: int, prod_id: int, qty: int, reason: str) -> ReturnRequest:
    return ReturnRequest(id, order_id, prod_id, qty, reason, "pending")


def approve_return(r: ReturnRequest) -> ReturnRequest:
    return ReturnRequest(r.id, r.order_id, r.product_id, r.quantity, r.reason, "approved")


def deny_return(r: ReturnRequest) -> ReturnRequest:
    return ReturnRequest(r.id, r.order_id, r.product_id, r.quantity, r.reason, "denied")


def return_refund_amount(r: ReturnRequest, products: list) -> int:
    prod = cat.find_product_by_id(products, r.product_id)
    price = 0 if prod is None else prod.unit_price
    return price * r.quantity


def returns_for_order(returns: list[ReturnRequest], order_id: int) -> list[ReturnRequest]:
    return [r for r in returns if r.order_id == order_id]


def approved_returns(returns: list[ReturnRequest]) -> list[ReturnRequest]:
    return [r for r in returns if r.status == "approved"]


def total_return_value(returns: list[ReturnRequest], products: list) -> int:
    return functools.reduce(
        lambda acc, r: acc + return_refund_amount(r, products),
        approved_returns(returns),
        0,
    )


def partial_fulfill_order(levels: list, o: Order) -> list[dict]:
    return [
        {
            "product_id": ol.product_id,
            "requested": ol.quantity,
            "shipping": min(ol.quantity, inv.available_quantity(levels, ol.product_id)),
            "backordered": ol.quantity - min(ol.quantity, inv.available_quantity(levels, ol.product_id)),
        }
        for ol in o.lines
    ]


def partial_fulfillment_value(levels: list, o: Order) -> int:
    parts = partial_fulfill_order(levels, o)
    acc = 0
    for part in parts:
        prod_id = part["product_id"]
        qty = part["shipping"]
        ol = next((l for l in o.lines if l.product_id == prod_id), None)
        price = 0 if ol is None else ol.unit_price
        acc += price * qty
    return acc


def add_line_to_order(o: Order, new_line: OrderLine) -> Order:
    new_lines = o.lines + [new_line]
    new_subtotal = calculate_subtotal(new_lines)
    disc = o.discount
    tax = calculate_tax(new_subtotal - disc, 0.1)
    total = calculate_total(new_subtotal, tax, disc)
    return Order(o.id, o.customer_id, o.status, new_lines, new_subtotal, tax, disc, total, o.created_at)


def remove_line_from_order(o: Order, prod_id: int) -> Order:
    new_lines = [ol for ol in o.lines if ol.product_id != prod_id]
    new_subtotal = calculate_subtotal(new_lines)
    disc = o.discount
    tax = calculate_tax(new_subtotal - disc, 0.1)
    total = calculate_total(new_subtotal, tax, disc)
    return Order(o.id, o.customer_id, o.status, new_lines, new_subtotal, tax, disc, total, o.created_at)


def order_product_ids(o: Order) -> list[int]:
    return [ol.product_id for ol in o.lines]


def repeat_order(o: Order, new_id: int, new_timestamp: int) -> Order:
    return Order(new_id, o.customer_id, "pending", o.lines, o.subtotal, o.tax, o.discount, o.total, new_timestamp)


def customer_reorder_rate(orders: list[Order], cust_id: int) -> int:
    cust_orders = orders_by_customer(orders, cust_id)
    cnt = len(cust_orders)
    if cnt <= 1:
        return 0
    all_prods = [order_product_ids(o) for o in cust_orders]
    first_prods = all_prods[0]
    repeat_count = len([
        prods for prods in all_prods[1:]
        if any(pid in first_prods for pid in prods)
    ])
    return (repeat_count * 100) // (cnt - 1)


def orders_in_period(orders: list[Order], start_ts: int, end_ts: int) -> list[Order]:
    return [o for o in orders if o.created_at >= start_ts and o.created_at <= end_ts]


def revenue_in_period(orders: list[Order], start_ts: int, end_ts: int) -> int:
    return total_revenue(orders_in_period(orders, start_ts, end_ts))


def order_frequency(orders: list[Order], cust_id: int) -> int:
    return customer_order_count(orders, cust_id)


def high_value_orders(orders: list[Order], threshold: int) -> list[Order]:
    return orders_above_total(orders, threshold)


def average_items_per_order(orders: list[Order]) -> int:
    cnt = len(orders)
    return 0 if cnt == 0 else total_line_count(orders) // cnt
