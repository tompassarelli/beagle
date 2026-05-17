from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional

from orders import Order, order_id


@dataclass
class Carrier:
    id: int
    name: str
    base_rate: int
    per_kg_rate: int
    max_weight: int
    active: bool


@dataclass
class Shipment:
    id: int
    order_id: int
    carrier_id: int
    warehouse_id: int
    status: str
    tracking_number: str
    weight_kg: int
    shipping_cost: int
    created_at: int
    delivered_at: int


@dataclass
class DeliveryZone:
    id: int
    name: str
    surcharge_pct: int


def carrier_id(r: Carrier) -> int:
    return r.id


def carrier_name(r: Carrier) -> str:
    return r.name


def carrier_base_rate(r: Carrier) -> int:
    return r.base_rate


def carrier_per_kg_rate(r: Carrier) -> int:
    return r.per_kg_rate


def carrier_max_weight(r: Carrier) -> int:
    return r.max_weight


def carrier_active(r: Carrier) -> bool:
    return r.active


def shipment_id(r: Shipment) -> int:
    return r.id


def shipment_order_id(r: Shipment) -> int:
    return r.order_id


def shipment_carrier_id(r: Shipment) -> int:
    return r.carrier_id


def shipment_warehouse_id(r: Shipment) -> int:
    return r.warehouse_id


def shipment_status(r: Shipment) -> str:
    return r.status


def shipment_tracking_number(r: Shipment) -> str:
    return r.tracking_number


def shipment_weight_kg(r: Shipment) -> int:
    return r.weight_kg


def shipment_shipping_cost(r: Shipment) -> int:
    return r.shipping_cost


def shipment_created_at(r: Shipment) -> int:
    return r.created_at


def shipment_delivered_at(r: Shipment) -> int:
    return r.delivered_at


def deliveryzone_id(r: DeliveryZone) -> int:
    return r.id


def deliveryzone_name(r: DeliveryZone) -> str:
    return r.name


def deliveryzone_surcharge_pct(r: DeliveryZone) -> int:
    return r.surcharge_pct


def orders_with_shipments(shipments: list[Shipment], orders: list) -> list:
    return [o for o in orders if len([s for s in shipments if shipment_order_id(s) == order_id(o)]) > 0]


def find_carrier_by_id(carriers: list[Carrier], id: int) -> Optional[Carrier]:
    matches = [c for c in carriers if carrier_id(c) == id]
    return matches[0] if matches else None


def active_carriers(carriers: list[Carrier]) -> list[Carrier]:
    return [c for c in carriers if carrier_active(c)]


def carrier_total_cost(c: Carrier, weight_kg: int) -> int:
    return carrier_base_rate(c) + carrier_per_kg_rate(c) * weight_kg


def carriers_for_weight(carriers: list[Carrier], weight_kg: int) -> list[Carrier]:
    return [c for c in carriers if carrier_active(c) and carrier_max_weight(c) >= weight_kg]


def cheapest_carrier(carriers: list[Carrier], weight_kg: int) -> Optional[Carrier]:
    eligible = carriers_for_weight(carriers, weight_kg)
    if not eligible:
        return None
    return functools.reduce(
        lambda best, c: c if carrier_total_cost(c, weight_kg) < carrier_total_cost(best, weight_kg) else best,
        eligible[1:],
        eligible[0],
    )


def zone_surcharge(zone: DeliveryZone, cost: int) -> int:
    return (cost * deliveryzone_surcharge_pct(zone)) // 100


def create_shipment(id: int, order: Order, c: Carrier, warehouse_id: int, weight_kg: int, zone: DeliveryZone) -> Shipment:
    base_cost = carrier_total_cost(c, weight_kg)
    surcharge = zone_surcharge(zone, base_cost)
    total_cost = base_cost + surcharge
    return Shipment(id, order_id(order), carrier_id(c), warehouse_id, "pending", "", weight_kg, total_cost, 0, 0)


def ship_shipment(s: Shipment, timestamp: int) -> Shipment:
    if shipment_status(s) == "pending":
        return Shipment(
            shipment_id(s),
            shipment_order_id(s),
            shipment_carrier_id(s),
            shipment_warehouse_id(s),
            "shipped",
            shipment_tracking_number(s),
            shipment_weight_kg(s),
            shipment_shipping_cost(s),
            shipment_created_at(s),
            shipment_delivered_at(s),
        )
    return s


def deliver_shipment(s: Shipment, timestamp: int) -> Shipment:
    if shipment_status(s) == "shipped":
        return Shipment(
            shipment_id(s),
            shipment_order_id(s),
            shipment_carrier_id(s),
            shipment_warehouse_id(s),
            "delivered",
            shipment_tracking_number(s),
            shipment_weight_kg(s),
            shipment_shipping_cost(s),
            shipment_created_at(s),
            timestamp,
        )
    return s


def cancel_shipment(s: Shipment) -> Shipment:
    if shipment_status(s) == "pending":
        return Shipment(
            shipment_id(s),
            shipment_order_id(s),
            shipment_carrier_id(s),
            shipment_warehouse_id(s),
            "cancelled",
            shipment_tracking_number(s),
            shipment_weight_kg(s),
            shipment_shipping_cost(s),
            shipment_created_at(s),
            shipment_delivered_at(s),
        )
    return s


def find_shipment_by_id(shipments: list[Shipment], id: int) -> Optional[Shipment]:
    matches = [s for s in shipments if shipment_id(s) == id]
    return matches[0] if matches else None


def shipments_for_order(shipments: list[Shipment], order_id: int) -> list[Shipment]:
    return [s for s in shipments if shipment_order_id(s) == order_id]


def shipments_by_carrier(shipments: list[Shipment], carrier_id: int) -> list[Shipment]:
    return [s for s in shipments if shipment_carrier_id(s) == carrier_id]


def shipments_by_status(shipments: list[Shipment], status: str) -> list[Shipment]:
    return [s for s in shipments if shipment_status(s) == status]


def pending_shipments(shipments: list[Shipment]) -> list[Shipment]:
    return shipments_by_status(shipments, "pending")


def delivered_shipments(shipments: list[Shipment]) -> list[Shipment]:
    return shipments_by_status(shipments, "delivered")


def shipment_delivered(s: Shipment) -> bool:
    return shipment_status(s) == "delivered"


def total_shipping_revenue(shipments: list[Shipment]) -> int:
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), delivered_shipments(shipments), 0)


def avg_shipping_cost(shipments: list[Shipment]) -> int:
    non_cancelled = [s for s in shipments if shipment_status(s) != "cancelled"]
    cnt = len(non_cancelled)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), non_cancelled, 0) // cnt


def carrier_revenue(shipments: list[Shipment], carrier_id: int) -> int:
    carrier_delivered = [s for s in shipments if shipment_carrier_id(s) == carrier_id and shipment_status(s) == "delivered"]
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), carrier_delivered, 0)


def carrier_shipment_count(shipments: list[Shipment], carrier_id: int) -> int:
    return len(shipments_by_carrier(shipments, carrier_id))


def carrier_on_time_count(shipments: list[Shipment], carrier_id: int, max_days: int) -> int:
    max_seconds = max_days * 86400
    carrier_delivered = [s for s in shipments if shipment_carrier_id(s) == carrier_id and shipment_status(s) == "delivered"]
    return len([s for s in carrier_delivered if (shipment_delivered_at(s) - shipment_created_at(s)) <= max_seconds])


def carrier_on_time_pct(shipments: list[Shipment], carrier_id: int, max_days: int) -> int:
    carrier_delivered = [s for s in shipments if shipment_carrier_id(s) == carrier_id and shipment_status(s) == "delivered"]
    total = len(carrier_delivered)
    if total == 0:
        return 0
    return (carrier_on_time_count(shipments, carrier_id, max_days) * 100) // total


def shipping_cost_for_order(shipments: list[Shipment], order_id: int) -> int:
    order_shipments = shipments_for_order(shipments, order_id)
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), order_shipments, 0)


def order_fully_shipped(shipments: list[Shipment], order: Order) -> bool:
    oid = order_id(order)
    order_ships = [s for s in shipments if shipment_order_id(s) == oid and shipment_status(s) != "cancelled"]
    return len(order_ships) > 0


def unshipped_orders(shipments: list[Shipment], orders: list[Order]) -> list[Order]:
    return [
        o for o in orders
        if len([s for s in shipments if shipment_order_id(s) == order_id(o)]) == 0
    ]


def warehouse_shipment_count(shipments: list[Shipment], warehouse_id: int) -> int:
    return len([s for s in shipments if shipment_warehouse_id(s) == warehouse_id])


def set_tracking_number(s: Shipment, tracking: str) -> Shipment:
    return Shipment(
        shipment_id(s),
        shipment_order_id(s),
        shipment_carrier_id(s),
        shipment_warehouse_id(s),
        shipment_status(s),
        tracking,
        shipment_weight_kg(s),
        shipment_shipping_cost(s),
        shipment_created_at(s),
        shipment_delivered_at(s),
    )


def set_created_at(s: Shipment, ts: int) -> Shipment:
    return Shipment(
        shipment_id(s),
        shipment_order_id(s),
        shipment_carrier_id(s),
        shipment_warehouse_id(s),
        shipment_status(s),
        shipment_tracking_number(s),
        shipment_weight_kg(s),
        shipment_shipping_cost(s),
        ts,
        shipment_delivered_at(s),
    )


def delivery_time_seconds(s: Shipment) -> int:
    if shipment_status(s) == "delivered":
        return shipment_delivered_at(s) - shipment_created_at(s)
    return 0


def delivery_time_days(s: Shipment) -> int:
    return delivery_time_seconds(s) // 86400


def avg_delivery_time_days(shipments: list[Shipment]) -> int:
    delivered = delivered_shipments(shipments)
    cnt = len(delivered)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + delivery_time_days(s), delivered, 0) // cnt


def fastest_delivery(shipments: list[Shipment]) -> Optional[Shipment]:
    delivered = delivered_shipments(shipments)
    if not delivered:
        return None
    return functools.reduce(
        lambda best, s: s if delivery_time_seconds(s) < delivery_time_seconds(best) else best,
        delivered[1:],
        delivered[0],
    )


def slowest_delivery(shipments: list[Shipment]) -> Optional[Shipment]:
    delivered = delivered_shipments(shipments)
    if not delivered:
        return None
    return functools.reduce(
        lambda worst, s: s if delivery_time_seconds(s) > delivery_time_seconds(worst) else worst,
        delivered[1:],
        delivered[0],
    )


def carrier_avg_delivery_days(shipments: list[Shipment], carrier_id: int) -> int:
    carrier_delivered = [s for s in shipments if shipment_carrier_id(s) == carrier_id and shipment_status(s) == "delivered"]
    cnt = len(carrier_delivered)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + delivery_time_days(s), carrier_delivered, 0) // cnt


def carrier_avg_cost(shipments: list[Shipment], carrier_id: int) -> int:
    carrier_ships = shipments_by_carrier(shipments, carrier_id)
    cnt = len(carrier_ships)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), carrier_ships, 0) // cnt


def rank_carriers_by_cost(carriers: list[Carrier], weight_kg: int) -> list[Carrier]:
    eligible = carriers_for_weight(carriers, weight_kg)
    return sorted(eligible, key=lambda c: carrier_total_cost(c, weight_kg))


def rank_carriers_by_revenue(carriers: list[Carrier], shipments: list[Shipment]) -> list[Carrier]:
    return sorted(carriers, key=lambda c: carrier_revenue(shipments, carrier_id(c)), reverse=True)


def total_weight_shipped(shipments: list[Shipment]) -> int:
    return functools.reduce(lambda acc, s: acc + shipment_weight_kg(s), delivered_shipments(shipments), 0)


def avg_shipment_weight(shipments: list[Shipment]) -> int:
    non_cancelled = [s for s in shipments if shipment_status(s) != "cancelled"]
    cnt = len(non_cancelled)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + shipment_weight_kg(s), non_cancelled, 0) // cnt


def heaviest_shipment(shipments: list[Shipment]) -> Optional[Shipment]:
    if not shipments:
        return None
    return functools.reduce(
        lambda best, s: s if shipment_weight_kg(s) > shipment_weight_kg(best) else best,
        shipments[1:],
        shipments[0],
    )


def lightest_shipment(shipments: list[Shipment]) -> Optional[Shipment]:
    non_cancelled = [s for s in shipments if shipment_status(s) != "cancelled"]
    if not non_cancelled:
        return None
    return functools.reduce(
        lambda best, s: s if shipment_weight_kg(s) < shipment_weight_kg(best) else best,
        non_cancelled[1:],
        non_cancelled[0],
    )


def cost_per_kg(s: Shipment) -> int:
    w = shipment_weight_kg(s)
    if w == 0:
        return 0
    return shipment_shipping_cost(s) // w


def avg_cost_per_kg(shipments: list[Shipment]) -> int:
    delivered = delivered_shipments(shipments)
    cnt = len(delivered)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + cost_per_kg(s), delivered, 0) // cnt


def warehouse_total_shipping_cost(shipments: list[Shipment], warehouse_id: int) -> int:
    wh_ships = [s for s in shipments if shipment_warehouse_id(s) == warehouse_id]
    return functools.reduce(lambda acc, s: acc + shipment_shipping_cost(s), wh_ships, 0)
