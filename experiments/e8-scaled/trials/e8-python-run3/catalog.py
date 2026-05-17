from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional


@dataclass
class Supplier:
    id: int
    name: str
    lead_time_days: int


@dataclass
class Category:
    id: int
    name: str
    tax_rate: float


@dataclass
class Product:
    id: int
    name: str
    sku: str
    unit_cost: int
    unit_price: int
    supplier_id: int
    category_id: int
    active: bool


@dataclass
class PriceTier:
    min_qty: int
    discount_pct: int


def supplier_id(r: Supplier) -> int:
    return r.id


def supplier_name(r: Supplier) -> str:
    return r.name


def supplier_lead_time_days(r: Supplier) -> int:
    return r.lead_time_days


def category_id(r: Category) -> int:
    return r.id


def category_name(r: Category) -> str:
    return r.name


def category_tax_rate(r: Category) -> float:
    return r.tax_rate


def product_id(r: Product) -> int:
    return r.id


def product_name(r: Product) -> str:
    return r.name


def product_sku(r: Product) -> str:
    return r.sku


def product_unit_cost(r: Product) -> int:
    return r.unit_cost


def product_unit_price(r: Product) -> int:
    return r.unit_price


def product_supplier_id(r: Product) -> int:
    return r.supplier_id


def product_category_id(r: Product) -> int:
    return r.category_id


def product_active(r: Product) -> bool:
    return r.active


def pricetier_min_qty(r: PriceTier) -> int:
    return r.min_qty


def pricetier_discount_pct(r: PriceTier) -> int:
    return r.discount_pct


def product_margin(p: Product) -> int:
    return product_unit_price(p) - product_unit_cost(p)


def product_margin_pct(p: Product) -> int:
    margin = product_margin(p)
    price = product_unit_price(p)
    if price == 0:
        return 0
    return (margin * 100) // price


def product_profitable(p: Product) -> bool:
    return product_margin(p) > 0


def format_price(cents: int) -> str:
    dollars = cents // 100
    remainder = cents % 100
    return "$" + str(dollars) + "." + ("0" if remainder < 10 else "") + str(remainder)


def product_tax(p: Product, cat: Category) -> int:
    price = product_unit_price(p)
    rate = category_tax_rate(cat)
    return int(float(price) * rate)


def product_price_with_tax(p: Product, cat: Category) -> int:
    return product_unit_price(p) + product_tax(p, cat)


def active_products(products: list[Product]) -> list[Product]:
    return [p for p in products if product_active(p)]


def inactive_products(products: list[Product]) -> list[Product]:
    return [p for p in products if not product_active(p)]


def products_by_category(products: list[Product], cat_id: int) -> list[Product]:
    return [p for p in products if product_category_id(p) == cat_id]


def products_by_supplier(products: list[Product], sup_id: int) -> list[Product]:
    return [p for p in products if product_supplier_id(p) == sup_id]


def products_above_margin(products: list[Product], threshold: int) -> list[Product]:
    return [p for p in products if product_margin(p) > threshold]


def products_in_price_range(products: list[Product], lo: int, hi: int) -> list[Product]:
    return [p for p in products if product_unit_price(p) >= lo and product_unit_price(p) <= hi]


def high_margin_products(products: list[Product], min_pct: int) -> list[Product]:
    return [p for p in products if product_margin_pct(p) >= min_pct]


def find_product_by_id(products: list[Product], id: int) -> Optional[Product]:
    matches = [p for p in products if product_id(p) == id]
    return matches[0] if matches else None


def find_product_by_sku(products: list[Product], sku: str) -> Optional[Product]:
    matches = [p for p in products if product_sku(p) == sku]
    return matches[0] if matches else None


def find_supplier_by_id(suppliers: list[Supplier], id: int) -> Optional[Supplier]:
    matches = [s for s in suppliers if supplier_id(s) == id]
    return matches[0] if matches else None


def find_category_by_id(categories: list[Category], id: int) -> Optional[Category]:
    matches = [c for c in categories if category_id(c) == id]
    return matches[0] if matches else None


def sort_by_price(products: list[Product]) -> list[Product]:
    return sorted(products, key=product_unit_price)


def sort_by_cost(products: list[Product]) -> list[Product]:
    return sorted(products, key=product_unit_cost)


def sort_by_name(products: list[Product]) -> list[Product]:
    return sorted(products, key=product_name)


def sort_by_margin(products: list[Product]) -> list[Product]:
    return sorted(products, key=product_margin)


def total_catalog_value(products: list[Product]) -> int:
    return functools.reduce(lambda acc, p: acc + product_unit_price(p), products, 0)


def total_catalog_cost(products: list[Product]) -> int:
    return functools.reduce(lambda acc, p: acc + product_unit_cost(p), products, 0)


def avg_unit_price(products: list[Product]) -> int:
    cnt = len(products)
    if cnt == 0:
        return 0
    return total_catalog_value(products) // cnt


def avg_unit_cost(products: list[Product]) -> int:
    cnt = len(products)
    if cnt == 0:
        return 0
    return total_catalog_cost(products) // cnt


def cheapest_product(products: list[Product]) -> Product:
    return functools.reduce(
        lambda best, p: p if product_unit_cost(p) < product_unit_cost(best) else best,
        products[1:],
        products[0],
    )


def most_expensive_product(products: list[Product]) -> Product:
    return functools.reduce(
        lambda best, p: p if product_unit_price(p) > product_unit_price(best) else best,
        products[1:],
        products[0],
    )


def category_product_count(products: list[Product], cat_id: int) -> int:
    return len(products_by_category(products, cat_id))


def category_total_value(products: list[Product], cat_id: int) -> int:
    return total_catalog_value(products_by_category(products, cat_id))


def category_avg_price(products: list[Product], cat_id: int) -> int:
    return avg_unit_price(products_by_category(products, cat_id))


def category_avg_margin(products: list[Product], cat_id: int) -> int:
    cat_prods = products_by_category(products, cat_id)
    cnt = len(cat_prods)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, p: acc + product_margin_pct(p), cat_prods, 0) // cnt


def supplier_product_count(products: list[Product], sup_id: int) -> int:
    return len(products_by_supplier(products, sup_id))


def supplier_total_cost(products: list[Product], sup_id: int) -> int:
    return total_catalog_cost(products_by_supplier(products, sup_id))


def supplier_avg_lead_time(suppliers: list[Supplier]) -> int:
    cnt = len(suppliers)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, s: acc + supplier_lead_time_days(s), suppliers, 0) // cnt


def apply_price_increase(products: list[Product], pct: int) -> list[Product]:
    return [
        Product(
            product_id(p),
            product_name(p),
            product_sku(p),
            product_unit_cost(p),
            product_unit_price(p) + (product_unit_price(p) * pct) // 100,
            product_supplier_id(p),
            product_category_id(p),
            product_active(p),
        )
        for p in products
    ]


def deactivate_product(products: list[Product], target_id: int) -> list[Product]:
    return [
        Product(
            product_id(p),
            product_name(p),
            product_sku(p),
            product_unit_cost(p),
            product_unit_price(p),
            product_supplier_id(p),
            product_category_id(p),
            False,
        )
        if product_id(p) == target_id
        else p
        for p in products
    ]


def activate_product(products: list[Product], target_id: int) -> list[Product]:
    return [
        Product(
            product_id(p),
            product_name(p),
            product_sku(p),
            product_unit_cost(p),
            product_unit_price(p),
            product_supplier_id(p),
            product_category_id(p),
            True,
        )
        if product_id(p) == target_id
        else p
        for p in products
    ]


def product_summary(p: Product) -> str:
    return product_name(p) + " (" + product_sku(p) + ") " + format_price(product_unit_price(p))


def product_detail(p: Product) -> str:
    return (
        product_name(p)
        + " | SKU: " + product_sku(p)
        + " | Cost: " + format_price(product_unit_cost(p))
        + " | Price: " + format_price(product_unit_price(p))
        + " | Margin: " + str(product_margin_pct(p)) + "%"
    )


def top_n_by_price(products: list[Product], n: int) -> list[Product]:
    return list(reversed(sort_by_price(products)))[:n]


def bottom_n_by_cost(products: list[Product], n: int) -> list[Product]:
    return sort_by_cost(products)[:n]


def valid_product(p: Product) -> bool:
    return (
        product_id(p) > 0
        and product_name(p) != ""
        and product_sku(p) != ""
        and product_unit_cost(p) >= 0
        and product_unit_price(p) > 0
        and product_supplier_id(p) > 0
        and product_category_id(p) > 0
    )


def products_needing_review(products: list[Product], min_margin: int) -> list[Product]:
    return [p for p in products if product_active(p) and product_margin(p) < min_margin]


def make_standard_tiers() -> list[PriceTier]:
    return [
        PriceTier(1, 0),
        PriceTier(10, 5),
        PriceTier(50, 10),
        PriceTier(100, 15),
        PriceTier(500, 20),
    ]


def applicable_tier(tiers: list[PriceTier], qty: int) -> Optional[PriceTier]:
    valid = [t for t in tiers if pricetier_min_qty(t) <= qty]
    sorted_tiers = sorted(valid, key=pricetier_min_qty, reverse=True)
    return sorted_tiers[0] if sorted_tiers else None


def quantity_price(p: Product, tiers: list[PriceTier], qty: int) -> int:
    tier = applicable_tier(tiers, qty)
    base = product_unit_price(p)
    disc = 0 if tier is None else pricetier_discount_pct(tier)
    return qty * (base - (base * disc) // 100)


def quantity_discount(p: Product, tiers: list[PriceTier], qty: int) -> int:
    full_price = product_unit_price(p) * qty
    discounted = quantity_price(p, tiers, qty)
    return full_price - discounted


def quantity_unit_price(p: Product, tiers: list[PriceTier], qty: int) -> int:
    tier = applicable_tier(tiers, qty)
    base = product_unit_price(p)
    disc = 0 if tier is None else pricetier_discount_pct(tier)
    return base - (base * disc) // 100


def cheaper_product(p1: Product, p2: Product) -> Product:
    return p1 if product_unit_price(p1) <= product_unit_price(p2) else p2


def higher_margin_product(p1: Product, p2: Product) -> Product:
    return p1 if product_margin_pct(p1) >= product_margin_pct(p2) else p2


def product_price_diff(p1: Product, p2: Product) -> int:
    return product_unit_price(p1) - product_unit_price(p2)


def products_within_price_of(products: list[Product], target: Product, range: int) -> list[Product]:
    target_price = product_unit_price(target)
    return [
        p for p in products
        if product_id(p) != product_id(target)
        and (product_unit_price(p) - target_price) <= range
        and (product_unit_price(p) - target_price) >= -range
    ]


def supplier_avg_product_margin(products: list[Product], sup_id: int) -> int:
    sup_prods = products_by_supplier(products, sup_id)
    cnt = len(sup_prods)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, p: acc + product_margin_pct(p), sup_prods, 0) // cnt


def supplier_score(supplier: Supplier, products: list[Product]) -> int:
    sup_id = supplier_id(supplier)
    avg_margin = supplier_avg_product_margin(products, sup_id)
    lead_penalty = supplier_lead_time_days(supplier)
    prod_count = supplier_product_count(products, sup_id)
    return (avg_margin * 2) + (prod_count * 5) + (-(lead_penalty * 3))


def rank_suppliers(suppliers: list[Supplier], products: list[Product]) -> list[Supplier]:
    return sorted(suppliers, key=lambda s: supplier_score(s, products), reverse=True)


def price_spread(products: list[Product]) -> int:
    prices = [product_unit_price(p) for p in products]
    if not prices:
        return 0
    return max(prices) - min(prices)


def cost_spread(products: list[Product]) -> int:
    costs = [product_unit_cost(p) for p in products]
    if not costs:
        return 0
    return max(costs) - min(costs)


def catalog_margin_distribution(products: list[Product]) -> dict[str, int]:
    low = len([p for p in products if product_margin_pct(p) < 20])
    mid = len([p for p in products if product_margin_pct(p) >= 20 and product_margin_pct(p) < 40])
    high = len([p for p in products if product_margin_pct(p) >= 40])
    return {"low": low, "mid": mid, "high": high}


def unique_category_ids(products: list[Product]) -> list[int]:
    seen: set[int] = set()
    result = []
    for p in products:
        cid = product_category_id(p)
        if cid not in seen:
            seen.add(cid)
            result.append(cid)
    return result


def unique_supplier_ids(products: list[Product]) -> list[int]:
    seen: set[int] = set()
    result = []
    for p in products:
        sid = product_supplier_id(p)
        if sid not in seen:
            seen.add(sid)
            result.append(sid)
    return result
