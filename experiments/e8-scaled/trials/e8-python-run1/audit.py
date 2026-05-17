from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional

import catalog as cat
import customers as cust
import inventory as inv
import orders as ord
import shipping as ship
import billing
import procurement as proc
import employees as emp
import analytics
import notifications as notif
import promotions as promo


@dataclass
class AuditEntry:
    id: int
    entity_type: str
    entity_id: int
    action: str
    actor_id: int
    timestamp: int
    detail: str


@dataclass
class ReconciliationResult:
    period: str
    expected: int
    actual: int
    discrepancy: int
    status: str


@dataclass
class ComplianceCheck:
    id: int
    check_type: str
    entity_id: int
    passed: bool
    detail: str
    checked_at: int


def auditentry_id(r: AuditEntry) -> int:
    return r.id


def auditentry_entity_type(r: AuditEntry) -> str:
    return r.entity_type


def auditentry_entity_id(r: AuditEntry) -> int:
    return r.entity_id


def auditentry_action(r: AuditEntry) -> str:
    return r.action


def auditentry_actor_id(r: AuditEntry) -> int:
    return r.actor_id


def auditentry_timestamp(r: AuditEntry) -> int:
    return r.timestamp


def auditentry_detail(r: AuditEntry) -> str:
    return r.detail


def reconciliationresult_period(r: ReconciliationResult) -> str:
    return r.period


def reconciliationresult_expected(r: ReconciliationResult) -> int:
    return r.expected


def reconciliationresult_actual(r: ReconciliationResult) -> int:
    return r.actual


def reconciliationresult_discrepancy(r: ReconciliationResult) -> int:
    return r.discrepancy


def reconciliationresult_status(r: ReconciliationResult) -> str:
    return r.status


def compliancecheck_id(r: ComplianceCheck) -> int:
    return r.id


def compliancecheck_check_type(r: ComplianceCheck) -> str:
    return r.check_type


def compliancecheck_entity_id(r: ComplianceCheck) -> int:
    return r.entity_id


def compliancecheck_passed(r: ComplianceCheck) -> bool:
    return r.passed


def compliancecheck_detail(r: ComplianceCheck) -> str:
    return r.detail


def compliancecheck_checked_at(r: ComplianceCheck) -> int:
    return r.checked_at


def create_audit_entry(id: int, entity_type: str, entity_id: int, action: str, actor_id: int, timestamp: int, detail: str) -> AuditEntry:
    return AuditEntry(id, entity_type, entity_id, action, actor_id, timestamp, detail)


def audit_order(id: int, order: ord.Order, actor_id: int, action: str, timestamp: int) -> AuditEntry:
    return AuditEntry(id, "order", ord.order_id(order), action, actor_id, timestamp, ord.order_status(order))


def audit_shipment(id: int, shipment: ship.Shipment, actor_id: int, action: str, timestamp: int) -> AuditEntry:
    return AuditEntry(id, "shipment", ship.shipment_id(shipment), action, actor_id, timestamp, ship.shipment_status(shipment))


def audit_invoice(id: int, invoice: billing.Invoice, actor_id: int, action: str, timestamp: int) -> AuditEntry:
    return AuditEntry(id, "invoice", billing.invoice_id(invoice), action, actor_id, timestamp, billing.invoice_status(invoice))


def audit_product(id: int, product: cat.Product, actor_id: int, action: str, timestamp: int) -> AuditEntry:
    return AuditEntry(id, "product", cat.product_id(product), action, actor_id, timestamp, cat.product_name(product))


def entries_for_entity(entries: list[AuditEntry], entity_type: str, entity_id: int) -> list[AuditEntry]:
    return [e for e in entries if auditentry_entity_type(e) == entity_type and auditentry_entity_id(e) == entity_id]


def entries_by_actor(entries: list[AuditEntry], actor_id: int) -> list[AuditEntry]:
    return [e for e in entries if auditentry_actor_id(e) == actor_id]


def entries_by_action(entries: list[AuditEntry], action: str) -> list[AuditEntry]:
    return [e for e in entries if auditentry_action(e) == action]


def entries_in_period(entries: list[AuditEntry], start: int, end: int) -> list[AuditEntry]:
    return [e for e in entries if auditentry_timestamp(e) >= start and auditentry_timestamp(e) <= end]


def entry_count_by_type(entries: list[AuditEntry], entity_type: str) -> int:
    return len([e for e in entries if auditentry_entity_type(e) == entity_type])


def recent_entries(entries: list[AuditEntry], n: int) -> list[AuditEntry]:
    sorted_entries = list(reversed(sorted(entries, key=auditentry_timestamp)))
    return sorted_entries[:n]


def actor_action_count(entries: list[AuditEntry], actor_id: int) -> int:
    return len(entries_by_actor(entries, actor_id))


def entries_by_entity_type(entries: list[AuditEntry], entity_type: str) -> list[AuditEntry]:
    return [e for e in entries if auditentry_entity_type(e) == entity_type]


def distinct_actors(entries: list[AuditEntry]) -> list[int]:
    seen: set[int] = set()
    result = []
    for e in entries:
        aid = auditentry_actor_id(e)
        if aid not in seen:
            seen.add(aid)
            result.append(aid)
    return result


def distinct_entity_types(entries: list[AuditEntry]) -> list[str]:
    seen: set[str] = set()
    result = []
    for e in entries:
        et = auditentry_entity_type(e)
        if et not in seen:
            seen.add(et)
            result.append(et)
    return result


def entries_for_actor_in_period(entries: list[AuditEntry], actor_id: int, start: int, end: int) -> list[AuditEntry]:
    return [e for e in entries if auditentry_actor_id(e) == actor_id and auditentry_timestamp(e) >= start and auditentry_timestamp(e) <= end]


def actor_most_recent_entry(entries: list[AuditEntry], actor_id: int) -> Optional[AuditEntry]:
    actor_entries = entries_by_actor(entries, actor_id)
    if not actor_entries:
        return None
    sorted_entries = list(reversed(sorted(actor_entries, key=auditentry_timestamp)))
    return sorted_entries[0]


def audit_entry_summary(e: AuditEntry) -> str:
    return ("Audit #" + str(auditentry_id(e)) + " | " + auditentry_entity_type(e) + " #" +
            str(auditentry_entity_id(e)) + " | " + auditentry_action(e) + " | Actor: " +
            str(auditentry_actor_id(e)) + " | " + auditentry_detail(e))


def audit_entry_detail(e: AuditEntry) -> str:
    return ("Audit #" + str(auditentry_id(e)) + " | Entity: " + auditentry_entity_type(e) + " #" +
            str(auditentry_entity_id(e)) + " | Action: " + auditentry_action(e) + " | Actor: " +
            str(auditentry_actor_id(e)) + " | Timestamp: " + str(auditentry_timestamp(e)) +
            " | Detail: " + auditentry_detail(e))


def valid_audit_entry(e: AuditEntry) -> bool:
    return (auditentry_id(e) > 0 and
            auditentry_entity_type(e) != "" and
            auditentry_entity_id(e) > 0 and
            auditentry_action(e) != "" and
            auditentry_actor_id(e) > 0 and
            auditentry_timestamp(e) > 0)


def audit_entry_count(entries: list[AuditEntry]) -> int:
    return len(entries)


def action_distribution(entries: list[AuditEntry]) -> dict[str, int]:
    creates = len(entries_by_action(entries, "create"))
    updates = len(entries_by_action(entries, "update"))
    cancels = len(entries_by_action(entries, "cancel"))
    deletes = len(entries_by_action(entries, "delete"))
    return {"create": creates, "update": updates, "cancel": cancels, "delete": deletes}


def entity_type_distribution(entries: list[AuditEntry]) -> dict[str, int]:
    orders_cnt = entry_count_by_type(entries, "order")
    shipments_cnt = entry_count_by_type(entries, "shipment")
    invoices_cnt = entry_count_by_type(entries, "invoice")
    products_cnt = entry_count_by_type(entries, "product")
    return {"order": orders_cnt, "shipment": shipments_cnt, "invoice": invoices_cnt, "product": products_cnt}


def actor_activity_summary(entries: list[AuditEntry]) -> list[dict]:
    actors = distinct_actors(entries)
    return [{"actor-id": aid, "entry-count": actor_action_count(entries, aid)} for aid in actors]


def most_active_actor(entries: list[AuditEntry]) -> int:
    actors = distinct_actors(entries)
    if not actors:
        return 0
    return functools.reduce(
        lambda best, aid: aid if actor_action_count(entries, aid) > actor_action_count(entries, best) else best,
        actors[1:],
        actors[0],
    )


def entries_per_day(entries: list[AuditEntry], start: int, end: int) -> int:
    period_entries = entries_in_period(entries, start, end)
    days = (end - start) // 86400
    if days <= 0:
        return len(period_entries)
    return len(period_entries) // days


def reconcile_revenue(orders: list[ord.Order], invoices: list[billing.Invoice], period_start: int, period_end: int) -> ReconciliationResult:
    period_orders = ord.orders_in_period(orders, period_start, period_end)
    expected = ord.total_revenue(period_orders)
    period_invoices = [i for i in invoices if billing.invoice_issued_at(i) >= period_start and billing.invoice_issued_at(i) <= period_end]
    actual = functools.reduce(lambda acc, i: acc + billing.invoice_total(i), period_invoices, 0)
    disc = expected - actual
    status = "balanced" if disc == 0 else "discrepancy"
    period_label = str(period_start) + "-" + str(period_end)
    return ReconciliationResult(period_label, expected, actual, disc, status)


def reconcile_inventory(levels: list[inv.StockLevel], products: list[cat.Product], movements: list[inv.StockMovement]) -> ReconciliationResult:
    expected = inv.total_inventory_value(levels, products)
    actual = 0
    for m in movements:
        prod = cat.find_product_by_id(products, inv.stockmovement_product_id(m))
        cost = 0 if prod is None else cat.product_unit_cost(prod)
        qty = inv.stockmovement_quantity_change(m)
        actual = actual + (qty * cost)
    disc = expected - actual
    status = "balanced" if disc == 0 else "discrepancy"
    return ReconciliationResult("current", expected, actual, disc, status)


def reconciliation_healthy(result: ReconciliationResult) -> bool:
    return reconciliationresult_status(result) == "balanced"


def reconcile_billing_payments(invoices: list[billing.Invoice], payments: list[billing.Payment]) -> ReconciliationResult:
    total_billed = functools.reduce(lambda acc, i: acc + billing.invoice_total(i), invoices, 0)
    total_collected = billing.total_revenue_collected(payments)
    disc = total_billed - total_collected
    status = "balanced" if disc == 0 else "discrepancy"
    return ReconciliationResult("billing", total_billed, total_collected, disc, status)


def reconcile_shipping_orders(orders: list[ord.Order], shipments: list[ship.Shipment]) -> ReconciliationResult:
    active = ord.active_orders(orders)
    expected = len(active)
    shipped = len(ship.orders_with_shipments(shipments, active))
    disc = expected - shipped
    status = "balanced" if disc == 0 else "discrepancy"
    return ReconciliationResult("shipping-coverage", int(expected), int(shipped), int(disc), status)


def reconcile_procurement_inventory(pos: list[proc.PurchaseOrder], levels: list[inv.StockLevel], products: list[cat.Product]) -> ReconciliationResult:
    expected = proc.total_procurement_spend(pos)
    actual = inv.total_inventory_value(levels, products)
    disc = expected - actual
    status = "balanced" if disc == 0 else "discrepancy"
    return ReconciliationResult("procurement-inventory", expected, actual, disc, status)


def reconciliation_result_summary(r: ReconciliationResult) -> str:
    return ("Period: " + reconciliationresult_period(r) + " | Expected: " +
            str(reconciliationresult_expected(r)) + " | Actual: " +
            str(reconciliationresult_actual(r)) + " | Discrepancy: " +
            str(reconciliationresult_discrepancy(r)) + " | Status: " +
            reconciliationresult_status(r))


def discrepancy_pct(result: ReconciliationResult) -> int:
    exp = reconciliationresult_expected(result)
    if exp == 0:
        return 0
    disc = reconciliationresult_discrepancy(result)
    abs_disc = -disc if disc < 0 else disc
    return (abs_disc * 100) // exp


def check_order_has_customer(order: ord.Order, customers: list[cust.Customer]) -> ComplianceCheck:
    cust_id = ord.order_customer_id(order)
    customer = cust.find_customer_by_id(customers, cust_id)
    passed = customer is not None
    detail = ("Customer #" + str(cust_id) + " exists") if passed else ("Customer #" + str(cust_id) + " not found")
    return ComplianceCheck(0, "order-has-customer", ord.order_id(order), passed, detail, 0)


def check_invoice_matches_order(invoice: billing.Invoice, orders: list[ord.Order]) -> ComplianceCheck:
    order = ord.find_order_by_id(billing.invoice_order_id(invoice))
    if order is None:
        passed = False
        detail = "Order #" + str(billing.invoice_order_id(invoice)) + " not found"
    else:
        passed = billing.invoice_total(invoice) == ord.order_total(order)
        if passed:
            detail = "Invoice total matches order total: " + str(billing.invoice_total(invoice))
        else:
            detail = "Invoice total " + str(billing.invoice_total(invoice)) + " != order total " + str(ord.order_total(order))
    return ComplianceCheck(0, "invoice-matches-order", billing.invoice_id(invoice), passed, detail, 0)


def check_shipment_has_order(shipment: ship.Shipment, orders: list[ord.Order]) -> ComplianceCheck:
    order_id = ship.shipment_order_id(shipment)
    order = ord.find_order_by_id(orders, order_id)
    passed = order is not None
    detail = ("Order #" + str(order_id) + " exists") if passed else ("Order #" + str(order_id) + " not found")
    return ComplianceCheck(0, "shipment-has-order", ship.shipment_id(shipment), passed, detail, 0)


def check_payment_within_invoice(payment: billing.Payment, invoices: list[billing.Invoice]) -> ComplianceCheck:
    inv_rec = billing.find_invoice_by_id(invoices, billing.payment_invoice_id(payment))
    if inv_rec is None:
        passed = False
        detail = "Invoice #" + str(billing.payment_invoice_id(payment)) + " not found"
    else:
        passed = billing.payment_amount(payment) <= billing.invoice_total(inv_rec)
        if passed:
            detail = "Payment " + str(billing.payment_amount(payment)) + " <= invoice total " + str(billing.invoice_total(inv_rec))
        else:
            detail = "Payment " + str(billing.payment_amount(payment)) + " > invoice total " + str(billing.invoice_total(inv_rec))
    return ComplianceCheck(0, "payment-within-invoice", billing.payment_id(payment), passed, detail, 0)


def check_employee_exists(actor_id: int, employees: list[emp.Employee]) -> ComplianceCheck:
    employee = emp.find_employee_by_id(employees, actor_id)
    passed = employee is not None
    if passed:
        detail = "Employee #" + str(actor_id) + " exists: " + emp.employee_name(employee)
    else:
        detail = "Employee #" + str(actor_id) + " not found"
    return ComplianceCheck(0, "employee-exists", actor_id, passed, detail, 0)


def check_product_active(product: cat.Product) -> ComplianceCheck:
    passed = cat.product_active(product)
    if passed:
        detail = "Product #" + str(cat.product_id(product)) + " is active"
    else:
        detail = "Product #" + str(cat.product_id(product)) + " is inactive"
    return ComplianceCheck(0, "product-active", cat.product_id(product), passed, detail, 0)


def check_invoice_not_overdue(invoice: billing.Invoice, now: int) -> ComplianceCheck:
    is_overdue = billing.invoice_status(invoice) == "unpaid" and billing.invoice_due_at(invoice) < now
    passed = not is_overdue
    if passed:
        detail = "Invoice #" + str(billing.invoice_id(invoice)) + " is current"
    else:
        detail = "Invoice #" + str(billing.invoice_id(invoice)) + " is overdue"
    return ComplianceCheck(0, "invoice-not-overdue", billing.invoice_id(invoice), passed, detail, now)


def check_po_within_budget(po: proc.PurchaseOrder, budget_limit: int) -> ComplianceCheck:
    po_total = proc.purchaseorder_total(po)
    passed = po_total <= budget_limit
    if passed:
        detail = "PO #" + str(proc.purchaseorder_id(po)) + " total " + str(po_total) + " within budget " + str(budget_limit)
    else:
        detail = "PO #" + str(proc.purchaseorder_id(po)) + " total " + str(po_total) + " exceeds budget " + str(budget_limit)
    return ComplianceCheck(0, "po-within-budget", proc.purchaseorder_id(po), passed, detail, 0)


def run_order_checks(orders: list[ord.Order], customers: list[cust.Customer]) -> list[ComplianceCheck]:
    return [check_order_has_customer(o, customers) for o in orders]


def run_invoice_checks(invoices: list[billing.Invoice], orders: list[ord.Order]) -> list[ComplianceCheck]:
    return [check_invoice_matches_order(inv_rec, orders) for inv_rec in invoices]


def run_shipment_checks(shipments: list[ship.Shipment], orders: list[ord.Order]) -> list[ComplianceCheck]:
    return [check_shipment_has_order(s, orders) for s in shipments]


def run_payment_checks(payments: list[billing.Payment], invoices: list[billing.Invoice]) -> list[ComplianceCheck]:
    return [check_payment_within_invoice(p, invoices) for p in payments]


def compliance_pass_rate(checks: list[ComplianceCheck]) -> int:
    total = len(checks)
    if total == 0:
        return 100
    passed_count = len([c for c in checks if compliancecheck_passed(c)])
    return (passed_count * 100) // total


def failed_checks(checks: list[ComplianceCheck]) -> list[ComplianceCheck]:
    return [c for c in checks if not compliancecheck_passed(c)]


def passed_checks(checks: list[ComplianceCheck]) -> list[ComplianceCheck]:
    return [c for c in checks if compliancecheck_passed(c)]


def compliance_summary(order_checks: list[ComplianceCheck], invoice_checks: list[ComplianceCheck], shipment_checks: list[ComplianceCheck]) -> dict:
    all_checks = list(order_checks) + list(invoice_checks) + list(shipment_checks)
    total = len(all_checks)
    passed_cnt = len(passed_checks(all_checks))
    failed_cnt = len(failed_checks(all_checks))
    rate = compliance_pass_rate(all_checks)
    return {"total-checks": total, "passed": passed_cnt, "failed": failed_cnt, "pass-rate": rate}


def compliance_check_summary(c: ComplianceCheck) -> str:
    return ("Check #" + str(compliancecheck_id(c)) + " | " + compliancecheck_check_type(c) +
            " | Entity: " + str(compliancecheck_entity_id(c)) + " | " +
            ("PASSED" if compliancecheck_passed(c) else "FAILED") + " | " + compliancecheck_detail(c))


def audit_order_lifecycle(base_id: int, order: ord.Order, actor_id: int, timestamp: int) -> list[AuditEntry]:
    oid = ord.order_id(order)
    status = ord.order_status(order)
    return [
        AuditEntry(base_id, "order", oid, "create", actor_id, timestamp, "pending"),
        AuditEntry(base_id + 1, "order", oid, "update", actor_id, timestamp + 1, status),
    ]


def audit_shipment_lifecycle(base_id: int, shipment: ship.Shipment, actor_id: int, timestamp: int) -> list[AuditEntry]:
    sid = ship.shipment_id(shipment)
    status = ship.shipment_status(shipment)
    return [
        AuditEntry(base_id, "shipment", sid, "create", actor_id, timestamp, "pending"),
        AuditEntry(base_id + 1, "shipment", sid, "update", actor_id, timestamp + 1, status),
    ]


def audit_invoice_lifecycle(base_id: int, invoice: billing.Invoice, actor_id: int, timestamp: int) -> list[AuditEntry]:
    iid = billing.invoice_id(invoice)
    status = billing.invoice_status(invoice)
    return [
        AuditEntry(base_id, "invoice", iid, "create", actor_id, timestamp, "unpaid"),
        AuditEntry(base_id + 1, "invoice", iid, "update", actor_id, timestamp + 1, status),
    ]


def check_order_invoice_coverage(orders: list[ord.Order], invoices: list[billing.Invoice]) -> list[ComplianceCheck]:
    result = []
    for o in orders:
        oid = ord.order_id(o)
        matching = billing.invoices_for_order(invoices, oid)
        passed = len(matching) > 0
        detail = ("Order #" + str(oid) + " has invoice") if passed else ("Order #" + str(oid) + " missing invoice")
        result.append(ComplianceCheck(0, "order-invoice-coverage", oid, passed, detail, 0))
    return result


def check_shipment_carrier_valid(shipments: list[ship.Shipment], carriers: list[ship.Carrier]) -> list[ComplianceCheck]:
    result = []
    for s in shipments:
        cid = ship.shipment_carrier_id(s)
        carrier = ship.find_carrier_by_id(carriers, cid)
        passed = carrier is not None
        detail = ("Carrier #" + str(cid) + " exists") if passed else ("Carrier #" + str(cid) + " not found")
        result.append(ComplianceCheck(0, "shipment-carrier-valid", ship.shipment_id(s), passed, detail, 0))
    return result


def check_notification_template_valid(notifications: list[notif.Notification], templates: list[notif.Template]) -> list[ComplianceCheck]:
    result = []
    for n in notifications:
        tid = notif.notification_template_id(n)
        tmpl = notif.find_template_by_id(templates, tid)
        passed = tmpl is not None
        detail = ("Template #" + str(tid) + " exists") if passed else ("Template #" + str(tid) + " not found")
        result.append(ComplianceCheck(0, "notification-template-valid", notif.notification_id(n), passed, detail, 0))
    return result


def total_system_revenue(payments: list[billing.Payment]) -> int:
    return billing.total_revenue_collected(payments)


def revenue_vs_shipping(orders: list[ord.Order], shipments: list[ship.Shipment]) -> dict:
    rev = ord.total_revenue(orders)
    ship_cost = ship.total_shipping_revenue(shipments)
    net = rev - ship_cost
    ship_pct = 0 if rev == 0 else (ship_cost * 100) // rev
    return {"revenue": rev, "shipping-cost": ship_cost, "net-after-shipping": net, "shipping-pct": ship_pct}


def revenue_vs_procurement(orders: list[ord.Order], pos: list[proc.PurchaseOrder]) -> dict:
    rev = ord.total_revenue(orders)
    spend = proc.total_procurement_spend(pos)
    margin = rev - spend
    margin_pct = 0 if rev == 0 else (margin * 100) // rev
    return {"revenue": rev, "procurement-spend": spend, "gross-margin": margin, "margin-pct": margin_pct}


def revenue_vs_commissions(orders: list[ord.Order], rules: list[emp.CommissionRule], employees: list[emp.Employee], products: list[cat.Product]) -> dict:
    rev = ord.total_revenue(orders)
    total_comm = functools.reduce(
        lambda acc, e: acc + emp.total_commission(rules, emp.employee_id(e), orders, products),
        emp.active_employees(employees),
        0,
    )
    comm_pct = 0 if rev == 0 else (total_comm * 100) // rev
    return {"revenue": rev, "total-commissions": total_comm, "commission-pct": comm_pct}


def inventory_health_check(levels: list[inv.StockLevel], products: list[cat.Product], orders: list[ord.Order]) -> dict:
    total_value = inv.total_inventory_value(levels, products)
    low_stock = len(inv.low_stock_items(levels))
    out_of_stock = len(inv.out_of_stock_items(levels))
    total_items = len(levels)
    health_pct = 100 if total_items == 0 else ((total_items - low_stock) * 100) // total_items
    reorder_cost = inv.reorder_cost(levels, products)
    return {
        "total-value": total_value,
        "low-stock-count": low_stock,
        "out-of-stock-count": out_of_stock,
        "total-items": total_items,
        "health-pct": health_pct,
        "reorder-cost": reorder_cost,
    }


def customer_health_check(customer: cust.Customer, orders: list[ord.Order], invoices: list[billing.Invoice], payments: list[billing.Payment], notifications: list[notif.Notification]) -> dict:
    cid = cust.customer_id(customer)
    order_count = ord.customer_order_count(orders, cid)
    total_spend = ord.customer_total_spend(orders, cid)
    outstanding = billing.customer_outstanding_balance(invoices, payments, cid)
    unpaid_count = billing.customer_unpaid_count(invoices, cid)
    notif_count = notif.customer_notification_count(notifications, cid)
    tier = cust.customer_tier(customer)
    return {
        "customer-id": cid,
        "name": cust.customer_name(customer),
        "tier": tier,
        "order-count": order_count,
        "total-spend": total_spend,
        "outstanding-balance": outstanding,
        "unpaid-invoices": unpaid_count,
        "notification-count": notif_count,
    }


def promotion_impact_assessment(orders: list[ord.Order], campaigns: list[promo.Campaign], coupons: list[promo.Coupon], now: int) -> dict:
    total_rev = ord.total_revenue(orders)
    total_disc = ord.total_discounts_given(orders)
    active_camps = len(promo.active_campaigns(campaigns, now))
    total_coupon_uses = promo.total_coupon_uses(coupons)
    disc_pct = 0 if total_rev == 0 else (total_disc * 100) // (total_rev + total_disc)
    return {
        "total-revenue": total_rev,
        "total-discounts": total_disc,
        "discount-pct": disc_pct,
        "active-campaigns": active_camps,
        "total-coupon-uses": total_coupon_uses,
    }


def employee_audit_trail(entries: list[AuditEntry], employee_id: int, employees: list[emp.Employee]) -> dict:
    employee = emp.find_employee_by_id(employees, employee_id)
    actor_entries = entries_by_actor(entries, employee_id)
    name = "unknown" if employee is None else emp.employee_name(employee)
    return {
        "employee-id": employee_id,
        "employee-name": name,
        "entry-count": len(actor_entries),
        "entries": actor_entries,
    }


def notification_compliance_check(notifications: list[notif.Notification], templates: list[notif.Template]) -> dict:
    total = len(notifications)
    del_rate = notif.delivery_rate_pct(notifications)
    sent_cnt = notif.notifications_sent_count(notifications)
    failed_cnt = notif.notifications_failed_count(notifications)
    avg_time = notif.avg_send_time(notifications)
    return {
        "total-notifications": total,
        "delivery-rate": del_rate,
        "sent-count": sent_cnt,
        "failed-count": failed_cnt,
        "avg-send-time": avg_time,
        "healthy": del_rate >= 80,
    }


def audit_dashboard(entries: list[AuditEntry], orders: list[ord.Order], invoices: list[billing.Invoice], payments: list[billing.Payment], shipments: list[ship.Shipment], levels: list[inv.StockLevel], products: list[cat.Product], movements: list[inv.StockMovement]) -> dict:
    entry_cnt = len(entries)
    action_dist = action_distribution(entries)
    entity_dist = entity_type_distribution(entries)
    rev_recon = reconcile_revenue(orders, invoices, 0, 999999999)
    inv_recon = reconcile_inventory(levels, products, movements)
    bill_recon = reconcile_billing_payments(invoices, payments)
    return {
        "audit-entries": entry_cnt,
        "action-distribution": action_dist,
        "entity-distribution": entity_dist,
        "revenue-reconciliation": {"status": reconciliationresult_status(rev_recon), "discrepancy": reconciliationresult_discrepancy(rev_recon)},
        "inventory-reconciliation": {"status": reconciliationresult_status(inv_recon), "discrepancy": reconciliationresult_discrepancy(inv_recon)},
        "billing-reconciliation": {"status": reconciliationresult_status(bill_recon), "discrepancy": reconciliationresult_discrepancy(bill_recon)},
    }


def full_compliance_report(orders: list[ord.Order], customers: list[cust.Customer], invoices: list[billing.Invoice], shipments: list[ship.Shipment], payments: list[billing.Payment]) -> dict:
    order_checks = run_order_checks(orders, customers)
    invoice_checks = run_invoice_checks(invoices, orders)
    shipment_checks = run_shipment_checks(shipments, orders)
    payment_checks = run_payment_checks(payments, invoices)
    all_checks = list(order_checks) + list(invoice_checks) + list(shipment_checks) + list(payment_checks)
    total = len(all_checks)
    passed_cnt = len(passed_checks(all_checks))
    failed_cnt = len(failed_checks(all_checks))
    rate = compliance_pass_rate(all_checks)
    return {
        "order-checks": {"total": len(order_checks), "pass-rate": compliance_pass_rate(order_checks)},
        "invoice-checks": {"total": len(invoice_checks), "pass-rate": compliance_pass_rate(invoice_checks)},
        "shipment-checks": {"total": len(shipment_checks), "pass-rate": compliance_pass_rate(shipment_checks)},
        "payment-checks": {"total": len(payment_checks), "pass-rate": compliance_pass_rate(payment_checks)},
        "overall": {"total-checks": total, "passed": passed_cnt, "failed": failed_cnt, "pass-rate": rate},
    }


def system_health_score(orders: list[ord.Order], invoices: list[billing.Invoice], payments: list[billing.Payment], shipments: list[ship.Shipment], levels: list[inv.StockLevel], products: list[cat.Product], notifications: list[notif.Notification]) -> int:
    coll_rate = billing.collection_rate_pct(invoices, payments)
    total_items = len(levels)
    low_stock = len(inv.low_stock_items(levels))
    inv_health = 100 if total_items == 0 else ((total_items - low_stock) * 100) // total_items
    notif_health = notif.delivery_rate_pct(notifications)
    active = ord.active_orders(orders)
    active_count = len(active)
    shipped_count = len(ship.orders_with_shipments(shipments, active))
    ship_health = 100 if active_count == 0 else (shipped_count * 100) // active_count
    score = (coll_rate * 30 + inv_health * 25 + notif_health * 20 + ship_health * 25) // 100
    return score


def sort_entries_by_timestamp(entries: list[AuditEntry]) -> list[AuditEntry]:
    return sorted(entries, key=auditentry_timestamp)


def sort_entries_by_id(entries: list[AuditEntry]) -> list[AuditEntry]:
    return sorted(entries, key=auditentry_id)


def entries_with_detail(entries: list[AuditEntry], detail: str) -> list[AuditEntry]:
    return [e for e in entries if auditentry_detail(e) == detail]


def entries_for_entity_action(entries: list[AuditEntry], entity_type: str, action: str) -> list[AuditEntry]:
    return [e for e in entries if auditentry_entity_type(e) == entity_type and auditentry_action(e) == action]


def audit_kpi_snapshot(orders: list[ord.Order], invoices: list[billing.Invoice], payments: list[billing.Payment], shipments: list[ship.Shipment], levels: list[inv.StockLevel], products: list[cat.Product]) -> dict:
    kpi = analytics.kpi_dashboard(orders, invoices, payments, shipments, levels, products)
    return {
        "total-revenue": kpi["total-revenue"],
        "total-collected": kpi["total-collected"],
        "total-outstanding": kpi["total-outstanding"],
        "total-shipping": kpi["total-shipping"],
        "inventory-value": kpi["inventory-value"],
        "order-count": kpi["order-count"],
    }


def high_value_order_entries(entries: list[AuditEntry], orders: list[ord.Order], threshold: int) -> list[AuditEntry]:
    high_orders = ord.orders_above_total(orders, threshold)
    high_ids = [ord.order_id(o) for o in high_orders]
    return [
        e for e in entries
        if auditentry_entity_type(e) == "order" and any(auditentry_entity_id(e) == oid for oid in high_ids)
    ]


def actors_with_cancellations(entries: list[AuditEntry]) -> list[int]:
    cancel_entries = entries_by_action(entries, "cancel")
    seen: set[int] = set()
    result = []
    for e in cancel_entries:
        aid = auditentry_actor_id(e)
        if aid not in seen:
            seen.add(aid)
            result.append(aid)
    return result


def entity_change_frequency(entries: list[AuditEntry], entity_type: str, entity_id: int) -> int:
    return len(entries_for_entity(entries, entity_type, entity_id))
