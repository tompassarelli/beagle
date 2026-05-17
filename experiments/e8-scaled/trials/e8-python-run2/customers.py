from __future__ import annotations
from dataclasses import dataclass
import functools
from typing import Optional


@dataclass
class Address:
    street: str
    city: str
    state: str
    zip: str


@dataclass
class Customer:
    id: int
    name: str
    email: str
    tier: str
    address: Address
    created_year: int


@dataclass
class PurchaseRecord:
    customer_id: int
    order_id: int
    amount: int
    year: int


@dataclass
class LoyaltyBalance:
    customer_id: int
    points: int
    lifetime_points: int


TIER_GOLD = "gold"
TIER_SILVER = "silver"
TIER_BRONZE = "bronze"


def customer_id(r: Customer) -> int:
    return r.id


def customer_name(r: Customer) -> str:
    return r.name


def customer_email(r: Customer) -> str:
    return r.email


def customer_tier(r: Customer) -> str:
    return r.tier


def customer_address(r: Customer) -> Address:
    return r.address


def customer_created_year(r: Customer) -> int:
    return r.created_year


def tier_discount_pct(tier: str) -> int:
    if tier == "gold":
        return 15
    elif tier == "silver":
        return 10
    elif tier == "bronze":
        return 5
    else:
        return 0


def tier_rank(tier: str) -> int:
    if tier == "gold":
        return 3
    elif tier == "silver":
        return 2
    elif tier == "bronze":
        return 1
    else:
        return 0


def higher_tier(t1: str, t2: str) -> bool:
    return tier_rank(t1) > tier_rank(t2)


def tier_from_spend(total_spend: int) -> str:
    if total_spend >= 100000:
        return "gold"
    elif total_spend >= 50000:
        return "silver"
    elif total_spend >= 10000:
        return "bronze"
    else:
        return "none"


def find_customer_by_id(customers: list[Customer], id: int) -> Optional[Customer]:
    matches = [c for c in customers if c.id == id]
    return matches[0] if matches else None


def find_customer_by_email(customers: list[Customer], email: str) -> Optional[Customer]:
    matches = [c for c in customers if c.email == email]
    return matches[0] if matches else None


def customers_by_tier(customers: list[Customer], tier: str) -> list[Customer]:
    return [c for c in customers if c.tier == tier]


def customers_by_state(customers: list[Customer], state: str) -> list[Customer]:
    return [c for c in customers if c.address.state == state]


def customers_by_city(customers: list[Customer], city: str) -> list[Customer]:
    return [c for c in customers if c.address.city == city]


def sort_by_name(customers: list[Customer]) -> list[Customer]:
    return sorted(customers, key=lambda c: c.name)


def sort_by_tier(customers: list[Customer]) -> list[Customer]:
    return sorted(customers, key=lambda c: tier_rank(c.tier))


def sort_by_created(customers: list[Customer]) -> list[Customer]:
    return sorted(customers, key=lambda c: c.created_year)


def customer_purchases(records: list[PurchaseRecord], cust_id: int) -> list[PurchaseRecord]:
    return [r for r in records if r.customer_id == cust_id]


def customer_total_spend(records: list[PurchaseRecord], cust_id: int) -> int:
    return functools.reduce(lambda acc, r: acc + r.amount, customer_purchases(records, cust_id), 0)


def customer_purchase_count(records: list[PurchaseRecord], cust_id: int) -> int:
    return len(customer_purchases(records, cust_id))


def customer_avg_order_value(records: list[PurchaseRecord], cust_id: int) -> int:
    purchases = customer_purchases(records, cust_id)
    cnt = len(purchases)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, r: acc + r.amount, purchases, 0) // cnt


def customer_purchases_in_year(records: list[PurchaseRecord], cust_id: int, year: int) -> list[PurchaseRecord]:
    return [r for r in records if r.customer_id == cust_id and r.year == year]


def customer_spend_in_year(records: list[PurchaseRecord], cust_id: int, year: int) -> int:
    return functools.reduce(lambda acc, r: acc + r.amount, customer_purchases_in_year(records, cust_id, year), 0)


def assess_tier(records: list[PurchaseRecord], cust_id: int) -> str:
    return tier_from_spend(customer_total_spend(records, cust_id))


def tier_upgrade_needed(c: Customer, records: list[PurchaseRecord]) -> bool:
    assessed = assess_tier(records, c.id)
    current = c.tier
    return higher_tier(assessed, current)


def customers_needing_upgrade(customers: list[Customer], records: list[PurchaseRecord]) -> list[Customer]:
    return [c for c in customers if tier_upgrade_needed(c, records)]


def upgrade_customer_tier(c: Customer, new_tier: str) -> Customer:
    return Customer(c.id, c.name, c.email, new_tier, c.address, c.created_year)


def count_by_tier(customers: list[Customer]) -> dict:
    gold = len(customers_by_tier(customers, "gold"))
    silver = len(customers_by_tier(customers, "silver"))
    bronze = len(customers_by_tier(customers, "bronze"))
    return {"gold": gold, "silver": silver, "bronze": bronze}


def total_customer_count(customers: list[Customer]) -> int:
    return len(customers)


def customers_since_year(customers: list[Customer], year: int) -> list[Customer]:
    return [c for c in customers if c.created_year >= year]


def customer_tenure(c: Customer, current_year: int) -> int:
    return current_year - c.created_year


def avg_customer_tenure(customers: list[Customer], current_year: int) -> int:
    cnt = len(customers)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, c: acc + customer_tenure(c, current_year), customers, 0) // cnt


def top_spenders(customers: list[Customer], records: list[PurchaseRecord], n: int) -> list[Customer]:
    return list(sorted(customers, key=lambda c: customer_total_spend(records, c.id), reverse=True))[:n]


def most_active_customers(customers: list[Customer], records: list[PurchaseRecord], n: int) -> list[Customer]:
    return list(sorted(customers, key=lambda c: customer_purchase_count(records, c.id), reverse=True))[:n]


def customer_summary(c: Customer) -> str:
    return f"{c.name} ({c.tier}) - {c.email}"


def customer_detail(c: Customer) -> str:
    addr = c.address
    return f"{c.name} | {c.email} | Tier: {c.tier} | {addr.city}, {addr.state}"


def address_oneline(a: Address) -> str:
    return f"{a.street}, {a.city}, {a.state} {a.zip}"


def valid_customer(c: Customer) -> bool:
    return c.id > 0 and c.name != "" and c.email != ""


def valid_address(a: Address) -> bool:
    return a.street != "" and a.city != "" and a.state != "" and a.zip != ""


def unique_states(customers: list[Customer]) -> list[str]:
    seen = []
    for state in [c.address.state for c in customers]:
        if state not in seen:
            seen.append(state)
    return seen


def state_customer_count(customers: list[Customer], state: str) -> int:
    return len(customers_by_state(customers, state))


def points_for_purchase(amount: int, tier: str) -> int:
    base_points = amount // 100
    if tier == "gold":
        multiplier = 3
    elif tier == "silver":
        multiplier = 2
    elif tier == "bronze":
        multiplier = 1
    else:
        multiplier = 1
    return base_points * multiplier


def add_points(bal: LoyaltyBalance, amount: int, tier: str) -> LoyaltyBalance:
    earned = points_for_purchase(amount, tier)
    return LoyaltyBalance(bal.customer_id, bal.points + earned, bal.lifetime_points + earned)


def redeem_points(bal: LoyaltyBalance, points: int) -> LoyaltyBalance:
    available = bal.points
    to_redeem = min(points, available)
    return LoyaltyBalance(bal.customer_id, available - to_redeem, bal.lifetime_points)


def points_to_dollars(points: int) -> int:
    return points // 10


def find_loyalty_balance(balances: list[LoyaltyBalance], cust_id: int) -> Optional[LoyaltyBalance]:
    matches = [b for b in balances if b.customer_id == cust_id]
    return matches[0] if matches else None


def top_loyalty_customers(balances: list[LoyaltyBalance], n: int) -> list[LoyaltyBalance]:
    return list(sorted(balances, key=lambda b: b.points, reverse=True))[:n]


def customer_segment(records: list[PurchaseRecord], cust_id: int) -> str:
    spend = customer_total_spend(records, cust_id)
    cnt = customer_purchase_count(records, cust_id)
    if spend >= 100000 and cnt >= 10:
        return "vip"
    elif spend >= 50000 and cnt >= 5:
        return "regular"
    elif cnt >= 1:
        return "occasional"
    else:
        return "inactive"


def customers_by_segment(customers: list[Customer], records: list[PurchaseRecord], segment: str) -> list[Customer]:
    return [c for c in customers if customer_segment(records, c.id) == segment]


def segment_distribution(customers: list[Customer], records: list[PurchaseRecord]) -> dict:
    return {
        "vip": len(customers_by_segment(customers, records, "vip")),
        "regular": len(customers_by_segment(customers, records, "regular")),
        "occasional": len(customers_by_segment(customers, records, "occasional")),
        "inactive": len(customers_by_segment(customers, records, "inactive")),
    }


def years_since_last_purchase(records: list[PurchaseRecord], cust_id: int, current_year: int) -> int:
    purchases = customer_purchases(records, cust_id)
    if not purchases:
        return 999
    latest = functools.reduce(
        lambda best, r: r if r.year > best.year else best,
        purchases[1:],
        purchases[0],
    )
    return current_year - latest.year


def at_risk_customers(customers: list[Customer], records: list[PurchaseRecord], current_year: int, threshold_years: int) -> list[Customer]:
    return [c for c in customers if years_since_last_purchase(records, c.id, current_year) >= threshold_years]


def customer_retention_rate(customers: list[Customer], records: list[PurchaseRecord], current_year: int, threshold: int) -> int:
    total = len(customers)
    at_risk = len(at_risk_customers(customers, records, current_year, threshold))
    if total == 0:
        return 100
    return ((total - at_risk) * 100) // total


def update_customer_email(c: Customer, new_email: str) -> Customer:
    return Customer(c.id, c.name, new_email, c.tier, c.address, c.created_year)


def update_customer_address(c: Customer, new_addr: Address) -> Customer:
    return Customer(c.id, c.name, c.email, c.tier, new_addr, c.created_year)
