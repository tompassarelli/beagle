from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional
import catalog as cat
import inventory as inv


@dataclass
class PurchaseOrder:
    id: int
    supplier_id: int
    status: str
    created_at: int
    expected_at: int
    total: int


@dataclass
class POLine:
    po_id: int
    product_id: int
    quantity: int
    unit_cost: int


@dataclass
class GoodsReceipt:
    id: int
    po_id: int
    warehouse_id: int
    received_at: int
    line_count: int


def purchaseorder_id(r: PurchaseOrder) -> int:
    return r.id


def purchaseorder_supplier_id(r: PurchaseOrder) -> int:
    return r.supplier_id


def purchaseorder_status(r: PurchaseOrder) -> str:
    return r.status


def purchaseorder_created_at(r: PurchaseOrder) -> int:
    return r.created_at


def purchaseorder_expected_at(r: PurchaseOrder) -> int:
    return r.expected_at


def purchaseorder_total(r: PurchaseOrder) -> int:
    return r.total


def poline_po_id(r: POLine) -> int:
    return r.po_id


def poline_product_id(r: POLine) -> int:
    return r.product_id


def poline_quantity(r: POLine) -> int:
    return r.quantity


def poline_unit_cost(r: POLine) -> int:
    return r.unit_cost


def goodsreceipt_id(r: GoodsReceipt) -> int:
    return r.id


def goodsreceipt_po_id(r: GoodsReceipt) -> int:
    return r.po_id


def goodsreceipt_warehouse_id(r: GoodsReceipt) -> int:
    return r.warehouse_id


def goodsreceipt_received_at(r: GoodsReceipt) -> int:
    return r.received_at


def goodsreceipt_line_count(r: GoodsReceipt) -> int:
    return r.line_count


def poline_total(line: POLine) -> int:
    return poline_quantity(line) * poline_unit_cost(line)


def po_total_from_lines(lines: list[POLine]) -> int:
    return functools.reduce(lambda acc, line: acc + poline_total(line), lines, 0)


def po_line_count(lines: list[POLine], po_id: int) -> int:
    return len([line for line in lines if poline_po_id(line) == po_id])


def lines_for_po(lines: list[POLine], po_id: int) -> list[POLine]:
    return [line for line in lines if poline_po_id(line) == po_id]


def lines_for_product(lines: list[POLine], product_id: int) -> list[POLine]:
    return [line for line in lines if poline_product_id(line) == product_id]


def total_quantity_for_product(lines: list[POLine], product_id: int) -> int:
    return functools.reduce(
        lambda acc, line: acc + poline_quantity(line),
        lines_for_product(lines, product_id),
        0,
    )


def total_spend_for_product(lines: list[POLine], product_id: int) -> int:
    return functools.reduce(
        lambda acc, line: acc + poline_total(line),
        lines_for_product(lines, product_id),
        0,
    )


def avg_unit_cost_for_product(lines: list[POLine], product_id: int) -> int:
    prod_lines = lines_for_product(lines, product_id)
    cnt = len(prod_lines)
    if cnt == 0:
        return 0
    return total_spend_for_product(lines, product_id) // total_quantity_for_product(lines, product_id)


def unique_products_in_lines(lines: list[POLine]) -> list[int]:
    seen: set[int] = set()
    result = []
    for line in lines:
        pid = poline_product_id(line)
        if pid not in seen:
            seen.add(pid)
            result.append(pid)
    return result


def create_purchase_order(
    id: int,
    supplier_id: int,
    lines: list[POLine],
    created_at: int,
    expected_at: int,
) -> PurchaseOrder:
    total = po_total_from_lines(lines)
    return PurchaseOrder(id, supplier_id, "pending", created_at, expected_at, total)


def find_po_by_id(pos: list[PurchaseOrder], id: int) -> Optional[PurchaseOrder]:
    matches = [po for po in pos if purchaseorder_id(po) == id]
    return matches[0] if matches else None


def pos_for_supplier(pos: list[PurchaseOrder], supplier_id: int) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_supplier_id(po) == supplier_id]


def pos_by_status(pos: list[PurchaseOrder], status: str) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_status(po) == status]


def pending_pos(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_status(po) == "pending"]


def approved_pos(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_status(po) == "approved"]


def completed_pos(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_status(po) == "completed"]


def cancelled_pos(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return [po for po in pos if purchaseorder_status(po) == "cancelled"]


def pos_in_period(pos: list[PurchaseOrder], start: int, end: int) -> list[PurchaseOrder]:
    return [
        po for po in pos
        if purchaseorder_created_at(po) >= start and purchaseorder_created_at(po) <= end
    ]


def sort_pos_by_total(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return list(reversed(sorted(pos, key=purchaseorder_total)))


def sort_pos_by_date(pos: list[PurchaseOrder]) -> list[PurchaseOrder]:
    return sorted(pos, key=purchaseorder_created_at)


def approve_po(po: PurchaseOrder) -> PurchaseOrder:
    if purchaseorder_status(po) == "pending":
        return PurchaseOrder(
            purchaseorder_id(po),
            purchaseorder_supplier_id(po),
            "approved",
            purchaseorder_created_at(po),
            purchaseorder_expected_at(po),
            purchaseorder_total(po),
        )
    return po


def complete_po(po: PurchaseOrder) -> PurchaseOrder:
    return PurchaseOrder(
        purchaseorder_id(po),
        purchaseorder_supplier_id(po),
        "completed",
        purchaseorder_created_at(po),
        purchaseorder_expected_at(po),
        purchaseorder_total(po),
    )


def cancel_po(po: PurchaseOrder) -> PurchaseOrder:
    if purchaseorder_status(po) == "pending":
        return PurchaseOrder(
            purchaseorder_id(po),
            purchaseorder_supplier_id(po),
            "cancelled",
            purchaseorder_created_at(po),
            purchaseorder_expected_at(po),
            purchaseorder_total(po),
        )
    return po


def po_open(po: PurchaseOrder) -> bool:
    return purchaseorder_status(po) == "pending" or purchaseorder_status(po) == "approved"


def po_closed(po: PurchaseOrder) -> bool:
    return purchaseorder_status(po) == "completed" or purchaseorder_status(po) == "cancelled"


def po_expected_lead_days(po: PurchaseOrder) -> int:
    elapsed = purchaseorder_expected_at(po) - purchaseorder_created_at(po)
    return elapsed // 86400


def valid_po(po: PurchaseOrder) -> bool:
    return (
        purchaseorder_id(po) > 0
        and purchaseorder_supplier_id(po) > 0
        and purchaseorder_status(po) != ""
        and purchaseorder_total(po) >= 0
    )


def valid_poline(line: POLine) -> bool:
    return (
        poline_product_id(line) > 0
        and poline_quantity(line) > 0
        and poline_unit_cost(line) >= 0
    )


def valid_lines(lines: list[POLine]) -> list[POLine]:
    return [line for line in lines if valid_poline(line)]


def all_lines_valid(lines: list[POLine]) -> bool:
    return all(valid_poline(line) for line in lines)


def create_goods_receipt(
    id: int,
    po_id: int,
    warehouse_id: int,
    received_at: int,
    lines: list[POLine],
) -> GoodsReceipt:
    lc = len([line for line in lines if poline_po_id(line) == po_id])
    return GoodsReceipt(id, po_id, warehouse_id, received_at, lc)


def receipts_for_po(receipts: list[GoodsReceipt], po_id: int) -> list[GoodsReceipt]:
    return [r for r in receipts if goodsreceipt_po_id(r) == po_id]


def receipts_for_warehouse(receipts: list[GoodsReceipt], warehouse_id: int) -> list[GoodsReceipt]:
    return [r for r in receipts if goodsreceipt_warehouse_id(r) == warehouse_id]


def find_receipt_by_id(receipts: list[GoodsReceipt], id: int) -> Optional[GoodsReceipt]:
    matches = [r for r in receipts if goodsreceipt_id(r) == id]
    return matches[0] if matches else None


def receipts_in_period(receipts: list[GoodsReceipt], start: int, end: int) -> list[GoodsReceipt]:
    return [
        r for r in receipts
        if goodsreceipt_received_at(r) >= start and goodsreceipt_received_at(r) <= end
    ]


def total_lines_received_for_po(receipts: list[GoodsReceipt], po_id: int) -> int:
    return functools.reduce(
        lambda acc, r: acc + goodsreceipt_line_count(r),
        receipts_for_po(receipts, po_id),
        0,
    )


def po_has_receipt(receipts: list[GoodsReceipt], po_id: int) -> bool:
    return len(receipts_for_po(receipts, po_id)) > 0


def warehouse_receipt_count(receipts: list[GoodsReceipt], warehouse_id: int) -> int:
    return len(receipts_for_warehouse(receipts, warehouse_id))


def supplier_total_ordered(pos: list[PurchaseOrder], lines: list[POLine], supplier_id: int) -> int:
    supplier_pos = pos_for_supplier(pos, supplier_id)
    supplier_po_ids = [purchaseorder_id(po) for po in supplier_pos]
    matching_lines = [
        line for line in lines
        if any(pid == poline_po_id(line) for pid in supplier_po_ids)
    ]
    return functools.reduce(lambda acc, line: acc + poline_total(line), matching_lines, 0)


def supplier_order_count(pos: list[PurchaseOrder], supplier_id: int) -> int:
    return len(pos_for_supplier(pos, supplier_id))


def supplier_avg_order_value(pos: list[PurchaseOrder], supplier_id: int) -> int:
    spos = pos_for_supplier(pos, supplier_id)
    cnt = len(spos)
    if cnt == 0:
        return 0
    total = functools.reduce(lambda acc, po: acc + purchaseorder_total(po), spos, 0)
    return total // cnt


def supplier_completed_count(pos: list[PurchaseOrder], supplier_id: int) -> int:
    return len([
        po for po in pos_for_supplier(pos, supplier_id)
        if purchaseorder_status(po) == "completed"
    ])


def supplier_completion_rate(pos: list[PurchaseOrder], supplier_id: int) -> int:
    spos = pos_for_supplier(pos, supplier_id)
    total = len(spos)
    completed = len([po for po in spos if purchaseorder_status(po) == "completed"])
    if total == 0:
        return 0
    return (completed * 100) // total


def supplier_cancellation_rate(pos: list[PurchaseOrder], supplier_id: int) -> int:
    spos = pos_for_supplier(pos, supplier_id)
    total = len(spos)
    cancelled = len([po for po in spos if purchaseorder_status(po) == "cancelled"])
    if total == 0:
        return 0
    return (cancelled * 100) // total


def supplier_completed_spend(pos: list[PurchaseOrder], supplier_id: int) -> int:
    return functools.reduce(
        lambda acc, po: acc + purchaseorder_total(po),
        [po for po in pos_for_supplier(pos, supplier_id) if purchaseorder_status(po) == "completed"],
        0,
    )


def overdue_pos(pos: list[PurchaseOrder], now: int) -> list[PurchaseOrder]:
    return [
        po for po in pos
        if po_open(po) and purchaseorder_expected_at(po) < now
    ]


def overdue_count(pos: list[PurchaseOrder], now: int) -> int:
    return len(overdue_pos(pos, now))


def overdue_total(pos: list[PurchaseOrder], now: int) -> int:
    return functools.reduce(
        lambda acc, po: acc + purchaseorder_total(po),
        overdue_pos(pos, now),
        0,
    )


def po_days_overdue(po: PurchaseOrder, now: int) -> int:
    diff = now - purchaseorder_expected_at(po)
    if diff > 0:
        return diff // 86400
    return 0


def auto_reorder_lines(levels: list[inv.StockLevel], products: list[cat.Product]) -> list[POLine]:
    needed = inv.reorder_needed(levels)
    result = []
    for sl in needed:
        prod_id = inv.stocklevel_product_id(sl)
        qty = inv.reorder_quantity(sl)
        prod = cat.find_product_by_id(products, prod_id)
        cost = 0 if prod is None else cat.product_unit_cost(prod)
        result.append(POLine(0, prod_id, qty, cost))
    return result


def auto_reorder_cost(levels: list[inv.StockLevel], products: list[cat.Product]) -> int:
    return po_total_from_lines(auto_reorder_lines(levels, products))


def auto_reorder_product_count(levels: list[inv.StockLevel]) -> int:
    return len(inv.reorder_needed(levels))


def total_procurement_spend(pos: list[PurchaseOrder]) -> int:
    return functools.reduce(
        lambda acc, po: acc + purchaseorder_total(po),
        [po for po in pos if purchaseorder_status(po) == "completed"],
        0,
    )


def open_procurement_value(pos: list[PurchaseOrder]) -> int:
    return functools.reduce(
        lambda acc, po: acc + purchaseorder_total(po),
        [po for po in pos if po_open(po)],
        0,
    )


def gross_procurement_value(pos: list[PurchaseOrder]) -> int:
    return functools.reduce(lambda acc, po: acc + purchaseorder_total(po), pos, 0)


def avg_po_value(pos: list[PurchaseOrder]) -> int:
    cnt = len(pos)
    if cnt == 0:
        return 0
    return gross_procurement_value(pos) // cnt


def period_procurement_spend(pos: list[PurchaseOrder], start: int, end: int) -> int:
    return functools.reduce(
        lambda acc, po: acc + purchaseorder_total(po),
        [
            po for po in pos
            if purchaseorder_status(po) == "completed"
            and purchaseorder_created_at(po) >= start
            and purchaseorder_created_at(po) <= end
        ],
        0,
    )


def avg_lead_time_actual(pos: list[PurchaseOrder], receipts: list[GoodsReceipt]) -> int:
    completed = [po for po in pos if purchaseorder_status(po) == "completed"]
    with_receipt = [
        po for po in completed
        if len(receipts_for_po(receipts, purchaseorder_id(po))) > 0
    ]
    if not with_receipt:
        return 0
    total_days = 0
    for po in with_receipt:
        po_receipts = receipts_for_po(receipts, purchaseorder_id(po))
        first_receipt = po_receipts[0]
        elapsed = goodsreceipt_received_at(first_receipt) - purchaseorder_created_at(po)
        days = elapsed // 86400
        total_days = total_days + days
    return total_days // len(with_receipt)


def po_actual_lead_days(po: PurchaseOrder, receipts: list[GoodsReceipt]) -> int:
    po_receipts = receipts_for_po(receipts, purchaseorder_id(po))
    if not po_receipts:
        return 0
    first_receipt = po_receipts[0]
    elapsed = goodsreceipt_received_at(first_receipt) - purchaseorder_created_at(po)
    return elapsed // 86400


def po_lead_variance_days(po: PurchaseOrder, receipts: list[GoodsReceipt]) -> int:
    actual = po_actual_lead_days(po, receipts)
    expected = po_expected_lead_days(po)
    return actual - expected


def max_lead_time_actual(pos: list[PurchaseOrder], receipts: list[GoodsReceipt]) -> int:
    completed = [po for po in pos if purchaseorder_status(po) == "completed"]
    with_receipt = [
        po for po in completed
        if len(receipts_for_po(receipts, purchaseorder_id(po))) > 0
    ]
    if not with_receipt:
        return 0
    return functools.reduce(
        lambda mx, po: po_actual_lead_days(po, receipts) if po_actual_lead_days(po, receipts) > mx else mx,
        with_receipt,
        0,
    )


def po_summary(po: PurchaseOrder) -> str:
    return (
        "PO#" + str(purchaseorder_id(po))
        + " supplier:" + str(purchaseorder_supplier_id(po))
        + " status:" + purchaseorder_status(po)
        + " total:" + str(purchaseorder_total(po))
    )


def poline_summary(line: POLine) -> str:
    return (
        "POLine po:" + str(poline_po_id(line))
        + " product:" + str(poline_product_id(line))
        + " qty:" + str(poline_quantity(line))
        + " @" + str(poline_unit_cost(line))
        + " = " + str(poline_total(line))
    )


def receipt_summary(r: GoodsReceipt) -> str:
    return (
        "GR#" + str(goodsreceipt_id(r))
        + " po:" + str(goodsreceipt_po_id(r))
        + " wh:" + str(goodsreceipt_warehouse_id(r))
        + " lines:" + str(goodsreceipt_line_count(r))
    )


def po_detail(po: PurchaseOrder, lines: list[POLine], products: list[cat.Product]) -> str:
    po_lines = lines_for_po(lines, purchaseorder_id(po))
    line_strs = []
    for line in po_lines:
        prod = cat.find_product_by_id(products, poline_product_id(line))
        pname = "unknown" if prod is None else cat.product_name(prod)
        line_strs.append(
            "  " + pname
            + " qty:" + str(poline_quantity(line))
            + " @" + str(poline_unit_cost(line))
        )
    return po_summary(po) + "\n" + functools.reduce(lambda acc, s: acc + s + "\n", line_strs, "")


def enrich_lines(
    lines: list[POLine],
    products: list[cat.Product],
    levels: list[inv.StockLevel],
) -> list[dict]:
    result = []
    for line in lines:
        prod_id = poline_product_id(line)
        prod = cat.find_product_by_id(products, prod_id)
        pname = "unknown" if prod is None else cat.product_name(prod)
        stock = inv.total_stock_for_product(levels, prod_id)
        result.append({
            "po-id": poline_po_id(line),
            "product-id": prod_id,
            "product-name": pname,
            "quantity": poline_quantity(line),
            "unit-cost": poline_unit_cost(line),
            "line-total": poline_total(line),
            "current-stock": stock,
        })
    return result


def orphan_line_product_ids(lines: list[POLine], products: list[cat.Product]) -> list[int]:
    return [
        pid for pid in unique_products_in_lines(lines)
        if cat.find_product_by_id(products, pid) is None
    ]


def po_count_by_status(pos: list[PurchaseOrder]) -> dict[str, int]:
    return {
        "pending": len(pending_pos(pos)),
        "approved": len(approved_pos(pos)),
        "completed": len(completed_pos(pos)),
        "cancelled": len(cancelled_pos(pos)),
    }


def total_line_count(lines: list[POLine]) -> int:
    return len(lines)


def total_units_ordered(lines: list[POLine]) -> int:
    return functools.reduce(lambda acc, line: acc + poline_quantity(line), lines, 0)


def avg_line_value(lines: list[POLine]) -> int:
    cnt = len(lines)
    if cnt == 0:
        return 0
    return po_total_from_lines(lines) // cnt


def avg_line_quantity(lines: list[POLine]) -> int:
    cnt = len(lines)
    if cnt == 0:
        return 0
    return total_units_ordered(lines) // cnt


def largest_po(pos: list[PurchaseOrder]) -> Optional[PurchaseOrder]:
    if not pos:
        return None
    return functools.reduce(
        lambda best, po: po if purchaseorder_total(po) > purchaseorder_total(best) else best,
        pos[1:],
        pos[0],
    )


def smallest_active_po(pos: list[PurchaseOrder]) -> Optional[PurchaseOrder]:
    active = [po for po in pos if purchaseorder_status(po) != "cancelled"]
    if not active:
        return None
    return functools.reduce(
        lambda best, po: po if purchaseorder_total(po) < purchaseorder_total(best) else best,
        active[1:],
        active[0],
    )


def cost_variance(lines: list[POLine], products: list[cat.Product], product_id: int) -> int:
    avg_po_cost = avg_unit_cost_for_product(lines, product_id)
    prod = cat.find_product_by_id(products, product_id)
    cat_cost = 0 if prod is None else cat.product_unit_cost(prod)
    return avg_po_cost - cat_cost


def products_over_catalog_cost(lines: list[POLine], products: list[cat.Product]) -> list[int]:
    pids = unique_products_in_lines(lines)
    return [pid for pid in pids if cost_variance(lines, products, pid) > 0]


def procurement_dashboard(
    pos: list[PurchaseOrder],
    lines: list[POLine],
    receipts: list[GoodsReceipt],
    now: int,
) -> dict:
    total_spend = total_procurement_spend(pos)
    open_value = open_procurement_value(pos)
    overdue_cnt = overdue_count(pos, now)
    overdue_val = overdue_total(pos, now)
    avg_lead = avg_lead_time_actual(pos, receipts)
    po_cnt = len(pos)
    line_cnt = total_line_count(lines)
    units = total_units_ordered(lines)
    return {
        "total-spend": total_spend,
        "open-value": open_value,
        "overdue-count": overdue_cnt,
        "overdue-value": overdue_val,
        "avg-lead-time-days": avg_lead,
        "po-count": po_cnt,
        "line-count": line_cnt,
        "total-units": units,
    }


def warehouse_received_value(
    pos: list[PurchaseOrder],
    receipts: list[GoodsReceipt],
    lines: list[POLine],
    warehouse_id: int,
) -> int:
    wh_receipts = receipts_for_warehouse(receipts, warehouse_id)
    return functools.reduce(
        lambda acc, r: acc + (
            lambda po: 0 if po is None else purchaseorder_total(po)
        )(find_po_by_id(pos, goodsreceipt_po_id(r))),
        wh_receipts,
        0,
    )
