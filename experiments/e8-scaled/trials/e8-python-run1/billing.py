from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional

import catalog
import orders as ord


@dataclass
class Invoice:
    id: int
    order_id: int
    customer_id: int
    subtotal: int
    tax: int
    discount: int
    total: int
    status: str
    issued_at: int
    due_at: int
    paid_at: int


@dataclass
class Payment:
    id: int
    invoice_id: int
    amount: int
    method: str
    status: str
    processed_at: int


@dataclass
class CreditNote:
    id: int
    customer_id: int
    amount: int
    reason: str
    issued_at: int


def invoice_id(r: Invoice) -> int:
    return r.id


def invoice_order_id(r: Invoice) -> int:
    return r.order_id


def invoice_customer_id(r: Invoice) -> int:
    return r.customer_id


def invoice_subtotal(r: Invoice) -> int:
    return r.subtotal


def invoice_tax(r: Invoice) -> int:
    return r.tax


def invoice_discount(r: Invoice) -> int:
    return r.discount


def invoice_total(r: Invoice) -> int:
    return r.total


def invoice_status(r: Invoice) -> str:
    return r.status


def invoice_issued_at(r: Invoice) -> int:
    return r.issued_at


def invoice_due_at(r: Invoice) -> int:
    return r.due_at


def invoice_paid_at(r: Invoice) -> int:
    return r.paid_at


def payment_id(r: Payment) -> int:
    return r.id


def payment_invoice_id(r: Payment) -> int:
    return r.invoice_id


def payment_amount(r: Payment) -> int:
    return r.amount


def payment_method(r: Payment) -> str:
    return r.method


def payment_status(r: Payment) -> str:
    return r.status


def payment_processed_at(r: Payment) -> int:
    return r.processed_at


def creditnote_id(r: CreditNote) -> int:
    return r.id


def creditnote_customer_id(r: CreditNote) -> int:
    return r.customer_id


def creditnote_amount(r: CreditNote) -> int:
    return r.amount


def creditnote_reason(r: CreditNote) -> str:
    return r.reason


def creditnote_issued_at(r: CreditNote) -> int:
    return r.issued_at


def create_invoice(id: int, order: ord.Order, customer: object, issued_at: int, due_at: int) -> Invoice:
    sub = order.subtotal
    tx = order.tax
    disc = order.discount
    tot = order.total
    cid = ord.order_customer_id(order)
    oid = order.id
    return Invoice(id, oid, cid, sub, tx, disc, tot, "unpaid", issued_at, due_at, 0)


def find_invoice_by_id(invoices: list, id: int) -> Optional[Invoice]:
    matches = [inv for inv in invoices if inv.id == id]
    return matches[0] if matches else None


def invoices_for_customer(invoices: list, customer_id: int) -> list:
    return [inv for inv in invoices if inv.customer_id == customer_id]


def invoices_for_order(invoices: list, order_id: int) -> list:
    return [inv for inv in invoices if inv.order_id == order_id]


def invoices_by_status(invoices: list, status: str) -> list:
    return [inv for inv in invoices if inv.status == status]


def unpaid_invoices(invoices: list) -> list:
    return invoices_by_status(invoices, "unpaid")


def paid_invoices(invoices: list) -> list:
    return invoices_by_status(invoices, "paid")


def overdue_invoices(invoices: list, now: int) -> list:
    return [inv for inv in invoices if inv.status == "unpaid" and inv.due_at < now]


def mark_invoice_paid(inv: Invoice, paid_at: int) -> Invoice:
    return Invoice(inv.id, inv.order_id, inv.customer_id, inv.subtotal, inv.tax, inv.discount, inv.total, "paid", inv.issued_at, inv.due_at, paid_at)


def invoice_age_days(inv: Invoice, now: int) -> int:
    return (now - inv.issued_at) // 86400


def create_payment(id: int, invoice_id: int, amount: int, method: str, processed_at: int) -> Payment:
    return Payment(id, invoice_id, amount, method, "completed", processed_at)


def find_payment_by_id(payments: list, id: int) -> Optional[Payment]:
    matches = [p for p in payments if p.id == id]
    return matches[0] if matches else None


def payments_for_invoice(payments: list, invoice_id: int) -> list:
    return [p for p in payments if p.invoice_id == invoice_id]


def total_payments_for_invoice(payments: list, invoice_id: int) -> int:
    return functools.reduce(
        lambda acc, p: acc + p.amount,
        [p for p in payments if p.invoice_id == invoice_id and p.status == "completed"],
        0
    )


def invoice_balance(inv: Invoice, payments: list) -> int:
    paid = total_payments_for_invoice(payments, inv.id)
    owed = inv.total
    bal = owed - paid
    return 0 if bal <= 0 else bal


def invoice_fully_paid(inv: Invoice, payments: list) -> bool:
    return invoice_balance(inv, payments) == 0


def payments_by_method(payments: list, method: str) -> list:
    return [p for p in payments if p.method == method]


def refund_payment(p: Payment) -> Payment:
    return Payment(p.id, p.invoice_id, p.amount, p.method, "refunded", p.processed_at)


def create_credit_note(id: int, customer_id: int, amount: int, reason: str, issued_at: int) -> CreditNote:
    return CreditNote(id, customer_id, amount, reason, issued_at)


def credits_for_customer(credits: list, customer_id: int) -> list:
    return [cn for cn in credits if cn.customer_id == customer_id]


def total_credits_for_customer(credits: list, customer_id: int) -> int:
    return functools.reduce(
        lambda acc, cn: acc + cn.amount,
        credits_for_customer(credits, customer_id),
        0
    )


def total_revenue_collected(payments: list) -> int:
    return functools.reduce(
        lambda acc, p: acc + p.amount,
        [p for p in payments if p.status == "completed"],
        0
    )


def total_outstanding(invoices: list, payments: list) -> int:
    return functools.reduce(
        lambda acc, inv: acc + invoice_balance(inv, payments),
        unpaid_invoices(invoices),
        0
    )


def customer_total_billed(invoices: list, customer_id: int) -> int:
    return functools.reduce(
        lambda acc, inv: acc + inv.total,
        invoices_for_customer(invoices, customer_id),
        0
    )


def customer_total_paid(payments: list, invoices: list, customer_id: int) -> int:
    cust_invoices = invoices_for_customer(invoices, customer_id)
    cust_inv_ids = [inv.id for inv in cust_invoices]
    return functools.reduce(
        lambda acc, p: acc + p.amount if (p.status == "completed" and any(p.invoice_id == iid for iid in cust_inv_ids)) else acc,
        payments,
        0
    )


def revenue_by_method(payments: list) -> dict:
    completed = [p for p in payments if p.status == "completed"]
    return functools.reduce(
        lambda acc, p: {**acc, p.method: acc.get(p.method, 0) + p.amount},
        completed,
        {}
    )


def avg_days_to_pay(invoices: list) -> int:
    pd = paid_invoices(invoices)
    cnt = len(pd)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, inv: acc + (inv.paid_at - inv.issued_at) // 86400, pd, 0) // cnt


def collection_rate_pct(invoices: list, payments: list) -> int:
    total_invoiced = functools.reduce(lambda acc, inv: acc + inv.total, invoices, 0)
    collected = total_revenue_collected(payments)
    if total_invoiced == 0:
        return 100
    return (collected * 100) // total_invoiced


def invoice_summary(inv: Invoice) -> str:
    return f"Invoice #{inv.id} | Order #{inv.order_id} | {inv.status} | Total: {catalog.format_price(inv.total)}"


def invoice_detail(inv: Invoice) -> str:
    return (f"Invoice #{inv.id} | Customer: {inv.customer_id} | Sub: {catalog.format_price(inv.subtotal)}"
            f" | Tax: {catalog.format_price(inv.tax)} | Disc: {catalog.format_price(inv.discount)}"
            f" | Total: {catalog.format_price(inv.total)} | Status: {inv.status}")


def payment_summary(p: Payment) -> str:
    return f"Payment #{p.id} | Invoice #{p.invoice_id} | {catalog.format_price(p.amount)} | {p.method} | {p.status}"


def credit_note_summary(cn: CreditNote) -> str:
    return f"Credit #{cn.id} | Customer: {cn.customer_id} | {catalog.format_price(cn.amount)} | {cn.reason}"


def valid_invoice(inv: Invoice) -> bool:
    return (inv.id > 0 and inv.order_id > 0 and inv.customer_id > 0
            and inv.total >= 0 and inv.status != "")


def valid_payment(p: Payment) -> bool:
    return p.id > 0 and p.invoice_id > 0 and p.amount > 0 and p.method != ""


def valid_credit_note(cn: CreditNote) -> bool:
    return cn.id > 0 and cn.customer_id > 0 and cn.amount > 0 and cn.reason != ""


def sort_invoices_by_total(invoices: list) -> list:
    return sorted(invoices, key=lambda inv: inv.total)


def sort_invoices_by_date(invoices: list) -> list:
    return sorted(invoices, key=lambda inv: inv.issued_at)


def sort_invoices_by_due(invoices: list) -> list:
    return sorted(invoices, key=lambda inv: inv.due_at)


def sort_payments_by_date(payments: list) -> list:
    return sorted(payments, key=lambda p: p.processed_at)


def invoices_in_period(invoices: list, start_ts: int, end_ts: int) -> list:
    return [inv for inv in invoices if inv.issued_at >= start_ts and inv.issued_at <= end_ts]


def payments_in_period(payments: list, start_ts: int, end_ts: int) -> list:
    return [p for p in payments if p.processed_at >= start_ts and p.processed_at <= end_ts]


def invoices_for_amount_range(invoices: list, lo: int, hi: int) -> list:
    return [inv for inv in invoices if inv.total >= lo and inv.total <= hi]


def customer_invoice_count(invoices: list, customer_id: int) -> int:
    return len(invoices_for_customer(invoices, customer_id))


def customer_unpaid_count(invoices: list, customer_id: int) -> int:
    return len([inv for inv in invoices if inv.customer_id == customer_id and inv.status == "unpaid"])


def customer_outstanding_balance(invoices: list, payments: list, customer_id: int) -> int:
    cust_unpaid = [inv for inv in invoices if inv.customer_id == customer_id and inv.status == "unpaid"]
    return functools.reduce(lambda acc, inv: acc + invoice_balance(inv, payments), cust_unpaid, 0)


def customer_avg_invoice_value(invoices: list, customer_id: int) -> int:
    cust_invs = invoices_for_customer(invoices, customer_id)
    cnt = len(cust_invs)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, inv: acc + inv.total, cust_invs, 0) // cnt


def payment_count_by_method(payments: list, method: str) -> int:
    return len([p for p in payments if p.method == method and p.status == "completed"])


def total_refunded(payments: list) -> int:
    return functools.reduce(
        lambda acc, p: acc + p.amount,
        [p for p in payments if p.status == "refunded"],
        0
    )


def net_revenue(payments: list) -> int:
    return total_revenue_collected(payments) - total_refunded(payments)


def completed_payment_count(payments: list) -> int:
    return len([p for p in payments if p.status == "completed"])


def avg_payment_amount(payments: list) -> int:
    completed = [p for p in payments if p.status == "completed"]
    cnt = len(completed)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, p: acc + p.amount, completed, 0) // cnt


def total_credits_issued(credits: list) -> int:
    return functools.reduce(lambda acc, cn: acc + cn.amount, credits, 0)


def credit_note_count(credits: list) -> int:
    return len(credits)


def customer_credit_count(credits: list, customer_id: int) -> int:
    return len(credits_for_customer(credits, customer_id))


def avg_credit_note_amount(credits: list) -> int:
    cnt = len(credits)
    if cnt == 0:
        return 0
    return total_credits_issued(credits) // cnt


def invoice_matches_order(inv: Invoice, orders: list) -> bool:
    o = ord.find_order_by_id(orders, inv.order_id)
    if o is None:
        return False
    return inv.total == o.total


def invoice_order_status(inv: Invoice, orders: list) -> str:
    o = ord.find_order_by_id(orders, inv.order_id)
    if o is None:
        return "unknown"
    return o.status


def customer_billing_summary(invoices: list, payments: list, credits: list, customer_id: int) -> str:
    billed = customer_total_billed(invoices, customer_id)
    paid = customer_total_paid(payments, invoices, customer_id)
    outstanding = customer_outstanding_balance(invoices, payments, customer_id)
    credit_amt = total_credits_for_customer(credits, customer_id)
    return (f"Customer #{customer_id} | Billed: {catalog.format_price(billed)}"
            f" | Paid: {catalog.format_price(paid)}"
            f" | Outstanding: {catalog.format_price(outstanding)}"
            f" | Credits: {catalog.format_price(credit_amt)}")


def invoice_age_bucket(inv: Invoice, now: int) -> str:
    days = invoice_age_days(inv, now)
    if days < 30:
        return "current"
    elif days < 60:
        return "30-60"
    elif days < 90:
        return "60-90"
    else:
        return "90+"


def aging_report(invoices: list, now: int) -> dict:
    unpaid = unpaid_invoices(invoices)
    current_cnt = len([inv for inv in unpaid if invoice_age_bucket(inv, now) == "current"])
    d30_cnt = len([inv for inv in unpaid if invoice_age_bucket(inv, now) == "30-60"])
    d60_cnt = len([inv for inv in unpaid if invoice_age_bucket(inv, now) == "60-90"])
    d90_cnt = len([inv for inv in unpaid if invoice_age_bucket(inv, now) == "90+"])
    return {"current": current_cnt, "30-60": d30_cnt, "60-90": d60_cnt, "90+": d90_cnt}


def aging_total(invoices: list, payments: list, now: int) -> dict:
    unpaid = unpaid_invoices(invoices)
    def bucket_total(bucket_name: str) -> int:
        return functools.reduce(
            lambda acc, inv: acc + invoice_balance(inv, payments) if invoice_age_bucket(inv, now) == bucket_name else acc,
            unpaid,
            0
        )
    return {"current": bucket_total("current"), "30-60": bucket_total("30-60"), "60-90": bucket_total("60-90"), "90+": bucket_total("90+")}


def bulk_create_invoices(specs: list) -> list:
    return [create_invoice(spec[0], spec[1], spec[2], spec[3], spec[4]) for spec in specs]


def overdue_invoice_ids(invoices: list, now: int) -> list:
    return [inv.id for inv in overdue_invoices(invoices, now)]


def largest_invoices(invoices: list, n: int) -> list:
    return list(reversed(sort_invoices_by_total(invoices)))[:n]


def largest_payments(payments: list, n: int) -> list:
    return list(reversed(sorted(payments, key=lambda p: p.amount)))[:n]


def most_indebted_customer_ids(invoices: list, payments: list) -> list:
    unpaid = unpaid_invoices(invoices)
    cids = list(dict.fromkeys(inv.customer_id for inv in unpaid))
    return list(reversed(sorted(cids, key=lambda cid: customer_outstanding_balance(invoices, payments, cid))))


def sum_invoice_totals_in_period(invoices: list, start_ts: int, end_ts: int) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.total, invoices_in_period(invoices, start_ts, end_ts), 0)


def sum_payments_in_period(payments: list, start_ts: int, end_ts: int) -> int:
    return functools.reduce(
        lambda acc, p: acc + p.amount,
        [p for p in payments_in_period(payments, start_ts, end_ts) if p.status == "completed"],
        0
    )


def invoice_payment_gap(invoices: list, payments: list, start_ts: int, end_ts: int) -> int:
    return sum_invoice_totals_in_period(invoices, start_ts, end_ts) - sum_payments_in_period(payments, start_ts, end_ts)


def days_past_due(inv: Invoice, now: int) -> int:
    diff = now - inv.due_at
    return 0 if diff <= 0 else diff // 86400


def severely_overdue(invoices: list, now: int, threshold_days: int) -> list:
    return [inv for inv in invoices if inv.status == "unpaid" and days_past_due(inv, now) > threshold_days]


def overdue_total(invoices: list, now: int) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.total, overdue_invoices(invoices, now), 0)


def avg_days_past_due(invoices: list, now: int) -> int:
    unpaid = unpaid_invoices(invoices)
    cnt = len(unpaid)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, inv: acc + days_past_due(inv, now), unpaid, 0) // cnt


def apply_payment_to_invoice(inv: Invoice, payments: list, pay_id: int, amount: int, method: str, processed_at: int) -> dict:
    bal = invoice_balance(inv, payments)
    applied = bal if amount > bal else amount
    remaining = amount - applied
    new_payment = create_payment(pay_id, inv.id, applied, method, processed_at)
    new_bal = bal - applied
    new_inv = mark_invoice_paid(inv, processed_at) if new_bal == 0 else inv
    return {"invoice": new_inv, "payment": new_payment, "remaining": remaining}


def split_payment_across_invoices(invoices: list, payments: list, start_pay_id: int, total_amount: int, method: str, processed_at: int) -> list:
    sorted_unpaid = sort_invoices_by_date(unpaid_invoices(invoices))
    def step(state, inv):
        created, remaining, next_id = state
        if remaining <= 0:
            return state
        bal = invoice_balance(inv, payments)
        applied = bal if remaining > bal else remaining
        pay = create_payment(next_id, inv.id, applied, method, processed_at)
        left = remaining - applied
        return [created + [pay], left, next_id + 1]
    result = functools.reduce(step, sorted_unpaid, [[], total_amount, start_pay_id])
    return result[0]


def invoice_lifecycle_status(inv: Invoice, payments: list, now: int) -> str:
    if inv.status == "paid":
        return "paid"
    if invoice_fully_paid(inv, payments):
        return "paid-pending-mark"
    if days_past_due(inv, now) > 90:
        return "severely-overdue"
    if days_past_due(inv, now) > 0:
        return "overdue"
    return "current"


def invoice_health_score(inv: Invoice, payments: list, now: int) -> int:
    status = invoice_lifecycle_status(inv, payments, now)
    if status == "paid":
        return 100
    elif status == "paid-pending-mark":
        return 95
    elif status == "current":
        return 80
    elif status == "overdue":
        dpd = days_past_due(inv, now)
        return 0 if dpd > 90 else 60 - (dpd * 60) // 90
    else:
        return 0


def portfolio_health(invoices: list, payments: list, now: int) -> int:
    cnt = len(invoices)
    if cnt == 0:
        return 100
    return functools.reduce(lambda acc, inv: acc + invoice_health_score(inv, payments, now), invoices, 0) // cnt


def recognized_revenue(invoices: list) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.total, paid_invoices(invoices), 0)


def unrecognized_revenue(invoices: list) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.total, unpaid_invoices(invoices), 0)


def deferred_revenue_pct(invoices: list) -> int:
    total = functools.reduce(lambda acc, inv: acc + inv.total, invoices, 0)
    if total == 0:
        return 0
    return (unrecognized_revenue(invoices) * 100) // total


def customer_net_position(invoices: list, payments: list, credits: list, customer_id: int) -> int:
    billed = customer_total_billed(invoices, customer_id)
    paid = customer_total_paid(payments, invoices, customer_id)
    cred = total_credits_for_customer(credits, customer_id)
    return billed - (paid + cred)


def customer_has_credit(credits: list, customer_id: int) -> bool:
    return total_credits_for_customer(credits, customer_id) > 0


def customer_lifetime_value(payments: list, invoices: list, customer_id: int) -> int:
    return customer_total_paid(payments, invoices, customer_id)


def customer_payment_velocity(invoices: list, customer_id: int) -> int:
    cust_paid = [inv for inv in invoices if inv.customer_id == customer_id and inv.status == "paid"]
    cnt = len(cust_paid)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, inv: acc + (inv.paid_at - inv.issued_at) // 86400, cust_paid, 0) // cnt


def total_tax_billed(invoices: list) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.tax, invoices, 0)


def total_discounts_billed(invoices: list) -> int:
    return functools.reduce(lambda acc, inv: acc + inv.discount, invoices, 0)


def effective_tax_rate(invoices: list) -> int:
    total_sub = functools.reduce(lambda acc, inv: acc + inv.subtotal, invoices, 0)
    if total_sub == 0:
        return 0
    return (total_tax_billed(invoices) * 100) // total_sub


def effective_discount_rate(invoices: list) -> int:
    total_sub = functools.reduce(lambda acc, inv: acc + inv.subtotal, invoices, 0)
    if total_sub == 0:
        return 0
    return (total_discounts_billed(invoices) * 100) // total_sub


def revenue_collected_in_period(payments: list, start_ts: int, end_ts: int) -> int:
    return functools.reduce(
        lambda acc, p: acc + p.amount,
        [p for p in payments if p.status == "completed" and p.processed_at >= start_ts and p.processed_at <= end_ts],
        0
    )


def invoiced_in_period(invoices: list, start_ts: int, end_ts: int) -> int:
    return sum_invoice_totals_in_period(invoices, start_ts, end_ts)


def period_collection_rate(invoices: list, payments: list, start_ts: int, end_ts: int) -> int:
    issued = invoiced_in_period(invoices, start_ts, end_ts)
    collected = revenue_collected_in_period(payments, start_ts, end_ts)
    if issued == 0:
        return 100
    return (collected * 100) // issued


def orders_without_invoices(orders: list, invoices: list) -> list:
    invoiced_order_ids = [inv.order_id for inv in invoices]
    return [o for o in orders if not any(o.id == ioid for ioid in invoiced_order_ids)]


def invoices_without_orders(invoices: list, orders: list) -> list:
    return [inv for inv in invoices if ord.find_order_by_id(orders, inv.order_id) is None]


def duplicate_invoices_for_order(invoices: list, order_id: int) -> list:
    matches = invoices_for_order(invoices, order_id)
    return matches if len(matches) > 1 else []


def billing_summary(invoices: list, payments: list, credits: list, now: int) -> dict:
    total_billed = functools.reduce(lambda acc, inv: acc + inv.total, invoices, 0)
    collected = total_revenue_collected(payments)
    outstanding = total_outstanding(invoices, payments)
    overdue_amt = overdue_total(invoices, now)
    refunded = total_refunded(payments)
    credited = total_credits_issued(credits)
    inv_count = len(invoices)
    paid_count = len(paid_invoices(invoices))
    unpaid_count = len(unpaid_invoices(invoices))
    overdue_count = len(overdue_invoices(invoices, now))
    return {
        "total-billed": total_billed,
        "total-collected": collected,
        "total-outstanding": outstanding,
        "total-overdue": overdue_amt,
        "total-refunded": refunded,
        "total-credits": credited,
        "invoice-count": inv_count,
        "paid-count": paid_count,
        "unpaid-count": unpaid_count,
        "overdue-count": overdue_count,
        "collection-rate": collection_rate_pct(invoices, payments),
        "health-score": portfolio_health(invoices, payments, now),
    }


def customer_billing_snapshot(invoices: list, payments: list, credits: list, customer_id: int, now: int) -> dict:
    billed = customer_total_billed(invoices, customer_id)
    paid = customer_total_paid(payments, invoices, customer_id)
    outstanding = customer_outstanding_balance(invoices, payments, customer_id)
    credit_amt = total_credits_for_customer(credits, customer_id)
    net_pos = customer_net_position(invoices, payments, credits, customer_id)
    inv_cnt = customer_invoice_count(invoices, customer_id)
    unpaid_cnt = customer_unpaid_count(invoices, customer_id)
    velocity = customer_payment_velocity(invoices, customer_id)
    return {
        "customer-id": customer_id,
        "total-billed": billed,
        "total-paid": paid,
        "outstanding": outstanding,
        "credits": credit_amt,
        "net-position": net_pos,
        "invoice-count": inv_cnt,
        "unpaid-count": unpaid_cnt,
        "avg-days-to-pay": velocity,
    }


def method_payment_count_map(payments: list) -> dict:
    completed = [p for p in payments if p.status == "completed"]
    return functools.reduce(
        lambda acc, p: {**acc, p.method: acc.get(p.method, 0) + 1},
        completed,
        {}
    )


def method_avg_payment(payments: list, method: str) -> int:
    matching = [p for p in payments if p.method == method and p.status == "completed"]
    cnt = len(matching)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, p: acc + p.amount, matching, 0) // cnt


def candidates_for_write_off(invoices: list, payments: list, now: int, threshold_days: int) -> list:
    return [inv for inv in invoices
            if inv.status == "unpaid"
            and invoice_age_days(inv, now) > threshold_days
            and total_payments_for_invoice(payments, inv.id) == 0]


def write_off_exposure(invoices: list, payments: list, now: int, threshold_days: int) -> int:
    return functools.reduce(
        lambda acc, inv: acc + inv.total,
        candidates_for_write_off(invoices, payments, now, threshold_days),
        0
    )


def partial_payment_invoices(invoices: list, payments: list) -> list:
    return [inv for inv in invoices
            if 0 < invoice_balance(inv, payments) < inv.total]


def customer_statement_lines(invoices: list, payments: list, customer_id: int) -> list:
    cust_invs = sort_invoices_by_date(invoices_for_customer(invoices, customer_id))
    return [
        (lambda bal: (
            f"Invoice #{inv.id} | Issued: {inv.issued_at} | Due: {inv.due_at}"
            f" | Total: {catalog.format_price(inv.total)}"
            f" | Paid: {catalog.format_price(inv.total - bal)}"
            f" | Balance: {catalog.format_price(bal)}"
            f" | Status: {inv.status}"
        ))(invoice_balance(inv, payments))
        for inv in cust_invs
    ]


def payment_receipt(p: Payment) -> str:
    return (f"=== Payment Receipt ==="
            f"\nPayment ID: {p.id}"
            f"\nInvoice: #{p.invoice_id}"
            f"\nAmount: {catalog.format_price(p.amount)}"
            f"\nMethod: {p.method}"
            f"\nStatus: {p.status}"
            f"\nProcessed: {p.processed_at}"
            f"\n========================")
