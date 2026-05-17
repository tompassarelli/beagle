from __future__ import annotations
from dataclasses import dataclass
from typing import Optional
import functools
import catalog as cat


@dataclass
class Warehouse:
    id: int
    name: str
    location: str
    capacity: int


@dataclass
class StockLevel:
    warehouse_id: int
    product_id: int
    quantity: int
    min_quantity: int


@dataclass
class StockMovement:
    id: int
    warehouse_id: int
    product_id: int
    quantity_change: int
    movement_type: str
    timestamp: int


@dataclass
class Transfer:
    id: int
    from_warehouse: int
    to_warehouse: int
    product_id: int
    quantity: int
    timestamp: int


def warehouse_id(r: Warehouse) -> int:
    return r.id


def warehouse_name(r: Warehouse) -> str:
    return r.name


def warehouse_location(r: Warehouse) -> str:
    return r.location


def warehouse_capacity(r: Warehouse) -> int:
    return r.capacity


def stocklevel_warehouse_id(r: StockLevel) -> int:
    return r.warehouse_id


def stocklevel_product_id(r: StockLevel) -> int:
    return r.product_id


def stocklevel_quantity(r: StockLevel) -> int:
    return r.quantity


def stocklevel_min_quantity(r: StockLevel) -> int:
    return r.min_quantity


def stockmovement_id(r: StockMovement) -> int:
    return r.id


def stockmovement_warehouse_id(r: StockMovement) -> int:
    return r.warehouse_id


def stockmovement_product_id(r: StockMovement) -> int:
    return r.product_id


def stockmovement_quantity_change(r: StockMovement) -> int:
    return r.quantity_change


def stockmovement_movement_type(r: StockMovement) -> str:
    return r.movement_type


def stockmovement_timestamp(r: StockMovement) -> int:
    return r.timestamp


def find_warehouse_by_id(warehouses: list, id: int) -> Optional[Warehouse]:
    matches = [w for w in warehouses if w.id == id]
    return matches[0] if matches else None


def warehouses_by_location(warehouses: list, loc: str) -> list:
    return [w for w in warehouses if w.location == loc]


def sort_by_capacity(warehouses: list) -> list:
    return sorted(warehouses, key=lambda w: w.capacity)


def find_stock(levels: list, wh_id: int, prod_id: int) -> Optional[StockLevel]:
    matches = [s for s in levels if s.warehouse_id == wh_id and s.product_id == prod_id]
    return matches[0] if matches else None


def stock_for_product(levels: list, prod_id: int) -> list:
    return [s for s in levels if s.product_id == prod_id]


def stock_for_warehouse(levels: list, wh_id: int) -> list:
    return [s for s in levels if s.warehouse_id == wh_id]


def total_stock_for_product(levels: list, prod_id: int) -> int:
    return functools.reduce(lambda acc, s: acc + s.quantity, stock_for_product(levels, prod_id), 0)


def total_stock_in_warehouse(levels: list, wh_id: int) -> int:
    return functools.reduce(lambda acc, s: acc + s.quantity, stock_for_warehouse(levels, wh_id), 0)


def in_stock(levels: list, wh_id: int, prod_id: int) -> bool:
    sl = find_stock(levels, wh_id, prod_id)
    if sl is None:
        return False
    return sl.quantity > 0


def below_minimum(sl: StockLevel) -> bool:
    return sl.quantity < sl.min_quantity


def low_stock_items(levels: list) -> list:
    return [s for s in levels if below_minimum(s)]


def out_of_stock_items(levels: list) -> list:
    return [s for s in levels if s.quantity == 0]


def available_quantity(levels: list, prod_id: int) -> int:
    return total_stock_for_product(levels, prod_id)


def can_fulfill(levels: list, prod_id: int, qty: int) -> bool:
    return available_quantity(levels, prod_id) >= qty


def stock_value_at_warehouse(levels: list, wh_id: int, products: list) -> int:
    wh_stock = stock_for_warehouse(levels, wh_id)
    def step(acc, sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        cost = 0 if prod is None else prod.unit_cost
        return acc + sl.quantity * cost
    return functools.reduce(step, wh_stock, 0)


def stock_value_for_product(levels: list, prod_id: int, products: list) -> int:
    prod = cat.find_product_by_id(products, prod_id)
    cost = 0 if prod is None else prod.unit_cost
    qty = total_stock_for_product(levels, prod_id)
    return qty * cost


def total_inventory_value(levels: list, products: list) -> int:
    def step(acc, sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        cost = 0 if prod is None else prod.unit_cost
        return acc + sl.quantity * cost
    return functools.reduce(step, levels, 0)


def stock_retail_value(levels: list, products: list) -> int:
    def step(acc, sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        price = 0 if prod is None else prod.unit_price
        return acc + sl.quantity * price
    return functools.reduce(step, levels, 0)


def reorder_needed(levels: list) -> list:
    return [sl for sl in levels if sl.quantity < sl.min_quantity]


def reorder_quantity(sl: StockLevel) -> int:
    deficit = sl.min_quantity - sl.quantity
    return deficit * 2 if deficit > 0 else 0


def reorder_list(levels: list, products: list) -> list:
    needed = reorder_needed(levels)
    def make_entry(sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        pname = "unknown" if prod is None else prod.name
        qty = reorder_quantity(sl)
        return {"product-id": sl.product_id, "product-name": pname, "warehouse-id": sl.warehouse_id, "reorder-qty": qty}
    return [make_entry(sl) for sl in needed]


def reorder_cost(levels: list, products: list) -> int:
    needed = reorder_needed(levels)
    def step(acc, sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        cost = 0 if prod is None else prod.unit_cost
        qty = reorder_quantity(sl)
        return acc + qty * cost
    return functools.reduce(step, needed, 0)


def movements_for_product(movements: list, prod_id: int) -> list:
    return [m for m in movements if m.product_id == prod_id]


def movements_for_warehouse(movements: list, wh_id: int) -> list:
    return [m for m in movements if m.warehouse_id == wh_id]


def movements_by_type(movements: list, mtype: str) -> list:
    return [m for m in movements if m.movement_type == mtype]


def net_movement(movements: list, prod_id: int) -> int:
    return functools.reduce(lambda acc, m: acc + m.quantity_change, movements_for_product(movements, prod_id), 0)


def total_received(movements: list, prod_id: int) -> int:
    filtered = [m for m in movements if m.product_id == prod_id and m.movement_type == "receive"]
    return functools.reduce(lambda acc, m: acc + m.quantity_change, filtered, 0)


def total_shipped(movements: list, prod_id: int) -> int:
    filtered = [m for m in movements if m.product_id == prod_id and m.movement_type == "ship"]
    return functools.reduce(lambda acc, m: acc + (0 - m.quantity_change), filtered, 0)


def apply_movement(levels: list, mv: StockMovement) -> list:
    wh_id = mv.warehouse_id
    prod_id = mv.product_id
    change = mv.quantity_change
    return [
        StockLevel(wh_id, prod_id, sl.quantity + change, sl.min_quantity)
        if sl.warehouse_id == wh_id and sl.product_id == prod_id
        else sl
        for sl in levels
    ]


def apply_movements(levels: list, movements: list) -> list:
    return functools.reduce(apply_movement, movements, levels)


def warehouse_item_count(levels: list, wh_id: int) -> int:
    return len(stock_for_warehouse(levels, wh_id))


def warehouse_total_units(levels: list, wh_id: int) -> int:
    return total_stock_in_warehouse(levels, wh_id)


def warehouse_utilization_pct(levels: list, wh: Warehouse) -> int:
    total = warehouse_total_units(levels, wh.id)
    cap = wh.capacity
    return 0 if cap == 0 else (total * 100) // cap


def stock_summary(sl: StockLevel) -> str:
    return f"WH:{sl.warehouse_id} Prod:{sl.product_id} Qty:{sl.quantity}/{sl.min_quantity}"


def warehouse_summary(wh: Warehouse) -> str:
    return f"{wh.name} ({wh.location}) cap:{wh.capacity}"


def stock_with_product_names(levels: list, products: list) -> list:
    def make_entry(sl):
        prod = cat.find_product_by_id(products, sl.product_id)
        pname = "unknown" if prod is None else prod.name
        return {"product-name": pname, "warehouse-id": sl.warehouse_id, "quantity": sl.quantity, "min-quantity": sl.min_quantity}
    return [make_entry(sl) for sl in levels]


def products_out_of_stock(levels: list, products: list) -> list:
    oos_ids = [sl.product_id for sl in out_of_stock_items(levels)]
    return [p for p in products if any(p.id == id for id in oos_ids)]


def create_transfer(id: int, from_wh: int, to_wh: int, prod_id: int, qty: int, ts: int) -> Transfer:
    return Transfer(id, from_wh, to_wh, prod_id, qty, ts)


def can_transfer(levels: list, from_wh: int, prod_id: int, qty: int) -> bool:
    sl = find_stock(levels, from_wh, prod_id)
    if sl is None:
        return False
    return sl.quantity >= qty


def apply_transfer(levels: list, tr: Transfer) -> list:
    from_wh = tr.from_warehouse
    to_wh = tr.to_warehouse
    prod_id = tr.product_id
    qty = tr.quantity
    result = []
    for sl in levels:
        if sl.warehouse_id == from_wh and sl.product_id == prod_id:
            result.append(StockLevel(from_wh, prod_id, sl.quantity - qty, sl.min_quantity))
        elif sl.warehouse_id == to_wh and sl.product_id == prod_id:
            result.append(StockLevel(to_wh, prod_id, sl.quantity + qty, sl.min_quantity))
        else:
            result.append(sl)
    return result


def transfers_for_product(transfers: list, prod_id: int) -> list:
    return [t for t in transfers if t.product_id == prod_id]


def transfers_from_warehouse(transfers: list, wh_id: int) -> list:
    return [t for t in transfers if t.from_warehouse == wh_id]


def transfers_to_warehouse(transfers: list, wh_id: int) -> list:
    return [t for t in transfers if t.to_warehouse == wh_id]


def product_stock_value(levels: list, prod_id: int, products: list) -> int:
    return stock_value_for_product(levels, prod_id, products)


def classify_abc(value: int, total_value: int) -> str:
    pct = 0 if total_value == 0 else (value * 100) // total_value
    if pct >= 20:
        return "A"
    elif pct >= 5:
        return "B"
    else:
        return "C"


def abc_analysis(levels: list, products: list) -> list:
    total = total_inventory_value(levels, products)
    def make_entry(p):
        pid = p.id
        value = product_stock_value(levels, pid, products)
        cls = classify_abc(value, total)
        return {"product-id": pid, "product-name": p.name, "stock-value": value, "abc-class": cls}
    return [make_entry(p) for p in products]


def safety_stock(avg_daily_demand: int, lead_time_days: int, safety_factor: int) -> int:
    return avg_daily_demand * lead_time_days * safety_factor


def recommended_min_quantity(avg_daily_demand: int, supplier, safety_factor: int) -> int:
    lead_time = 7 if supplier is None else supplier.lead_time_days
    return safety_stock(avg_daily_demand, lead_time, safety_factor)


def batch_receive(levels: list, wh_id: int, items: list) -> list:
    def apply_item(lvls, item):
        prod_id = item[0]
        qty = item[1]
        return [
            StockLevel(wh_id, prod_id, sl.quantity + qty, sl.min_quantity)
            if sl.warehouse_id == wh_id and sl.product_id == prod_id
            else sl
            for sl in lvls
        ]
    return functools.reduce(apply_item, items, levels)


def batch_ship(levels: list, wh_id: int, items: list) -> list:
    def apply_item(lvls, item):
        prod_id = item[0]
        qty = item[1]
        return [
            StockLevel(wh_id, prod_id, sl.quantity - qty, sl.min_quantity)
            if sl.warehouse_id == wh_id and sl.product_id == prod_id
            else sl
            for sl in lvls
        ]
    return functools.reduce(apply_item, items, levels)


def days_of_stock(levels: list, prod_id: int, daily_demand: int) -> int:
    qty = total_stock_for_product(levels, prod_id)
    return 999 if daily_demand == 0 else qty // daily_demand


def overstocked_products(levels: list, products: list, max_days: int, daily_demands: dict) -> list:
    def is_overstocked(p):
        pid = p.id
        raw = daily_demands.get(pid)
        demand = 1 if raw is None else raw
        return days_of_stock(levels, pid, demand) > max_days
    return [p for p in products if is_overstocked(p)]
