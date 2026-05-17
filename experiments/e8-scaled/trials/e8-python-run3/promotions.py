from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional
import customers as cust
import orders as ord


@dataclass
class Campaign:
    id: int
    name: str
    start_date: int
    end_date: int
    status: str


@dataclass
class Coupon:
    id: int
    campaign_id: int
    code: str
    discount_type: str
    discount_value: int
    min_order: int
    max_uses: int
    current_uses: int


@dataclass
class PromotionRule:
    id: int
    campaign_id: int
    min_tier: str
    min_order_value: int
    category_id: int


def campaign_id(r: Campaign) -> int:
    return r.id


def campaign_name(r: Campaign) -> str:
    return r.name


def campaign_start_date(r: Campaign) -> int:
    return r.start_date


def campaign_end_date(r: Campaign) -> int:
    return r.end_date


def campaign_status(r: Campaign) -> str:
    return r.status


def coupon_id(r: Coupon) -> int:
    return r.id


def coupon_campaign_id(r: Coupon) -> int:
    return r.campaign_id


def coupon_code(r: Coupon) -> str:
    return r.code


def coupon_discount_type(r: Coupon) -> str:
    return r.discount_type


def coupon_discount_value(r: Coupon) -> int:
    return r.discount_value


def coupon_min_order(r: Coupon) -> int:
    return r.min_order


def coupon_max_uses(r: Coupon) -> int:
    return r.max_uses


def coupon_current_uses(r: Coupon) -> int:
    return r.current_uses


def promotionrule_id(r: PromotionRule) -> int:
    return r.id


def promotionrule_campaign_id(r: PromotionRule) -> int:
    return r.campaign_id


def promotionrule_min_tier(r: PromotionRule) -> str:
    return r.min_tier


def promotionrule_min_order_value(r: PromotionRule) -> int:
    return r.min_order_value


def promotionrule_category_id(r: PromotionRule) -> int:
    return r.category_id


def find_campaign_by_id(campaigns: list[Campaign], id: int) -> Optional[Campaign]:
    matches = [c for c in campaigns if c.id == id]
    return matches[0] if matches else None


def campaign_active(campaign: Campaign, now: int) -> bool:
    return (campaign.status == "active"
            and campaign.start_date <= now
            and now <= campaign.end_date)


def active_campaigns(campaigns: list[Campaign], now: int) -> list[Campaign]:
    return [c for c in campaigns if campaign_active(c, now)]


def activate_campaign(campaign: Campaign) -> Campaign:
    return Campaign(campaign.id, campaign.name, campaign.start_date, campaign.end_date, "active")


def deactivate_campaign(campaign: Campaign) -> Campaign:
    return Campaign(campaign.id, campaign.name, campaign.start_date, campaign.end_date, "inactive")


def campaigns_by_status(campaigns: list[Campaign], status: str) -> list[Campaign]:
    return [c for c in campaigns if c.status == status]


def campaign_duration_days(campaign: Campaign) -> int:
    return (campaign.end_date - campaign.start_date) // 86400


def find_coupon_by_code(coupons: list[Coupon], code: str) -> Optional[Coupon]:
    matches = [c for c in coupons if c.code == code]
    return matches[0] if matches else None


def find_coupon_by_id(coupons: list[Coupon], id: int) -> Optional[Coupon]:
    matches = [c for c in coupons if c.id == id]
    return matches[0] if matches else None


def coupons_for_campaign(coupons: list[Coupon], cid: int) -> list[Coupon]:
    return [c for c in coupons if c.campaign_id == cid]


def coupon_valid(coupon: Coupon) -> bool:
    return coupon.current_uses < coupon.max_uses


def use_coupon(coupon: Coupon) -> Coupon:
    if coupon_valid(coupon):
        return Coupon(coupon.id, coupon.campaign_id, coupon.code, coupon.discount_type,
                      coupon.discount_value, coupon.min_order, coupon.max_uses,
                      coupon.current_uses + 1)
    return coupon


def coupon_usage_pct(coupon: Coupon) -> int:
    if coupon.max_uses == 0:
        return 0
    return (coupon.current_uses * 100) // coupon.max_uses


def coupon_discount_amount(coupon: Coupon, order_total: int) -> int:
    if coupon.discount_type == "percentage":
        raw = (order_total * coupon.discount_value) // 100
    else:
        raw = coupon.discount_value
    return order_total if raw > order_total else raw


def best_coupon(coupons: list[Coupon], order_total: int) -> Optional[Coupon]:
    valid = [c for c in coupons if coupon_valid(c)]
    if not valid:
        return None
    return functools.reduce(
        lambda best, c: c if coupon_discount_amount(c, order_total) > coupon_discount_amount(best, order_total) else best,
        valid[1:],
        valid[0]
    )


def find_rules_for_campaign(rules: list[PromotionRule], cid: int) -> list[PromotionRule]:
    return [r for r in rules if r.campaign_id == cid]


def tier_qualifies(customer_tier: str, min_tier: str) -> bool:
    if min_tier == "":
        return True
    tier_val = (3 if customer_tier == "gold"
                else 2 if customer_tier == "silver"
                else 1 if customer_tier == "bronze"
                else 0)
    min_val = (3 if min_tier == "gold"
               else 2 if min_tier == "silver"
               else 1 if min_tier == "bronze"
               else 0)
    return tier_val >= min_val


def customer_eligible(rule: PromotionRule, customer: cust.Customer) -> bool:
    return tier_qualifies(customer.tier, rule.min_tier)


def order_eligible(rule: PromotionRule, order: ord.Order) -> bool:
    return order.total >= rule.min_order_value


def rule_applies(rule: PromotionRule, customer: cust.Customer, order: ord.Order) -> bool:
    return customer_eligible(rule, customer) and order_eligible(rule, order)


def total_discount_given(coupons: list[Coupon], orders: list[ord.Order]) -> int:
    return functools.reduce(lambda acc, o: acc + o.discount, orders, 0)


def campaign_coupon_count(coupons: list[Coupon], cid: int) -> int:
    return len(coupons_for_campaign(coupons, cid))


def campaign_total_uses(coupons: list[Coupon], cid: int) -> int:
    return functools.reduce(
        lambda acc, c: acc + c.current_uses,
        coupons_for_campaign(coupons, cid),
        0
    )


def campaign_total_discount(coupons: list[Coupon], cid: int, order_total_fn) -> int:
    camp_coupons = coupons_for_campaign(coupons, cid)
    return functools.reduce(
        lambda acc, c: acc + (c.current_uses * coupon_discount_amount(c, 10000)),
        camp_coupons,
        0
    )


def coupon_remaining_uses(coupon: Coupon) -> int:
    rem = coupon.max_uses - coupon.current_uses
    return 0 if rem < 0 else rem


def coupon_exhausted(coupon: Coupon) -> bool:
    return coupon.current_uses >= coupon.max_uses


def exhausted_coupons(coupons: list[Coupon]) -> list[Coupon]:
    return [c for c in coupons if coupon_exhausted(c)]


def valid_coupons(coupons: list[Coupon]) -> list[Coupon]:
    return [c for c in coupons if coupon_valid(c)]


def coupon_applicable(coupon: Coupon, order_total: int) -> bool:
    return coupon_valid(coupon) and order_total >= coupon.min_order


def applicable_coupons(coupons: list[Coupon], order_total: int) -> list[Coupon]:
    return [c for c in coupons if coupon_applicable(c, order_total)]


def reset_coupon_uses(coupon: Coupon) -> Coupon:
    return Coupon(coupon.id, coupon.campaign_id, coupon.code, coupon.discount_type,
                  coupon.discount_value, coupon.min_order, coupon.max_uses, 0)


def percentage_coupons(coupons: list[Coupon]) -> list[Coupon]:
    return [c for c in coupons if c.discount_type == "percentage"]


def fixed_coupons(coupons: list[Coupon]) -> list[Coupon]:
    return [c for c in coupons if c.discount_type == "fixed"]


def campaign_upcoming(campaign: Campaign, now: int) -> bool:
    return campaign.status == "active" and campaign.start_date > now


def campaign_expired(campaign: Campaign, now: int) -> bool:
    return campaign.end_date < now


def upcoming_campaigns(campaigns: list[Campaign], now: int) -> list[Campaign]:
    return [c for c in campaigns if campaign_upcoming(c, now)]


def expired_campaigns(campaigns: list[Campaign], now: int) -> list[Campaign]:
    return [c for c in campaigns if campaign_expired(c, now)]


def campaign_days_remaining(campaign: Campaign, now: int) -> int:
    diff = campaign.end_date - now
    return 0 if diff <= 0 else diff // 86400


def campaign_days_elapsed(campaign: Campaign, now: int) -> int:
    diff = now - campaign.start_date
    return 0 if diff <= 0 else diff // 86400


def campaign_progress_pct(campaign: Campaign, now: int) -> int:
    total = campaign.end_date - campaign.start_date
    elapsed = now - campaign.start_date
    if total <= 0:
        return 100
    if elapsed <= 0:
        return 0
    if elapsed >= total:
        return 100
    return (elapsed * 100) // total


def sort_campaigns_by_start(campaigns: list[Campaign]) -> list[Campaign]:
    return sorted(campaigns, key=lambda c: c.start_date)


def sort_campaigns_by_end(campaigns: list[Campaign]) -> list[Campaign]:
    return sorted(campaigns, key=lambda c: c.end_date)


def total_campaign_count(campaigns: list[Campaign]) -> int:
    return len(campaigns)


def campaign_count_by_status(campaigns: list[Campaign], status: str) -> int:
    return len(campaigns_by_status(campaigns, status))


def rules_for_category(rules: list[PromotionRule], cat_id: int) -> list[PromotionRule]:
    return [r for r in rules if r.category_id == cat_id]


def universal_rules(rules: list[PromotionRule]) -> list[PromotionRule]:
    return [r for r in rules if r.category_id == 0]


def category_specific_rules(rules: list[PromotionRule]) -> list[PromotionRule]:
    return [r for r in rules if r.category_id != 0]


def any_rule_applies(rules: list[PromotionRule], customer: cust.Customer, order: ord.Order) -> bool:
    return any(rule_applies(r, customer, order) for r in rules)


def matching_rules(rules: list[PromotionRule], customer: cust.Customer, order: ord.Order) -> list[PromotionRule]:
    return [r for r in rules if rule_applies(r, customer, order)]


def campaign_rule_count(rules: list[PromotionRule], cid: int) -> int:
    return len(find_rules_for_campaign(rules, cid))


def eligible_campaigns(campaigns: list[Campaign], rules: list[PromotionRule], customer: cust.Customer, order: ord.Order, now: int) -> list[Campaign]:
    active = active_campaigns(campaigns, now)
    return [camp for camp in active
            if any_rule_applies(find_rules_for_campaign(rules, camp.id), customer, order)]


def eligible_campaign_count(campaigns: list[Campaign], rules: list[PromotionRule], customer: cust.Customer, order: ord.Order, now: int) -> int:
    return len(eligible_campaigns(campaigns, rules, customer, order, now))


def best_eligible_coupon(campaigns: list[Campaign], coupons: list[Coupon], rules: list[PromotionRule], customer: cust.Customer, order: ord.Order, now: int) -> Optional[Coupon]:
    elig_camps = eligible_campaigns(campaigns, rules, customer, order, now)
    camp_ids = [camp.id for camp in elig_camps]
    camp_coupons = [c for c in coupons if any(cid == c.campaign_id for cid in camp_ids)]
    order_total = order.total
    usable = [c for c in camp_coupons if coupon_applicable(c, order_total)]
    if not usable:
        return None
    return functools.reduce(
        lambda best, c: c if coupon_discount_amount(c, order_total) > coupon_discount_amount(best, order_total) else best,
        usable[1:],
        usable[0]
    )


def valid_campaign(campaign: Campaign) -> bool:
    return (campaign.id > 0
            and campaign.name != ""
            and campaign.start_date < campaign.end_date)


def valid_coupon(coupon: Coupon) -> bool:
    return (coupon.id > 0
            and coupon.code != ""
            and coupon.discount_value > 0
            and coupon.min_order >= 0
            and coupon.max_uses > 0
            and coupon.current_uses >= 0)


def valid_rule(rule: PromotionRule) -> bool:
    return (rule.id > 0
            and rule.min_order_value >= 0
            and rule.category_id >= 0)


def campaign_summary(campaign: Campaign) -> str:
    return f"{campaign.name} [{campaign.status}] ({campaign.start_date} - {campaign.end_date})"


def campaign_detail(campaign: Campaign) -> str:
    return (f"Campaign #{campaign.id} | {campaign.name} | Status: {campaign.status}"
            f" | Duration: {campaign_duration_days(campaign)} days")


def coupon_summary(coupon: Coupon) -> str:
    return (f"{coupon.code} ({coupon.discount_type} {coupon.discount_value})"
            f" uses: {coupon.current_uses}/{coupon.max_uses}")


def coupon_detail(coupon: Coupon) -> str:
    return (f"Coupon #{coupon.id} | Code: {coupon.code} | Type: {coupon.discount_type}"
            f" | Value: {coupon.discount_value} | Min-order: {coupon.min_order}"
            f" | Uses: {coupon.current_uses}/{coupon.max_uses} | Campaign: {coupon.campaign_id}")


def rule_summary(rule: PromotionRule) -> str:
    min_tier_str = "any" if rule.min_tier == "" else rule.min_tier
    category_str = "any" if rule.category_id == 0 else str(rule.category_id)
    return (f"Rule #{rule.id} | Campaign: {rule.campaign_id} | Min-tier: {min_tier_str}"
            f" | Min-order: {rule.min_order_value} | Category: {category_str}")


def sort_coupons_by_value(coupons: list[Coupon]) -> list[Coupon]:
    return sorted(coupons, key=lambda c: c.discount_value, reverse=True)


def sort_coupons_by_usage(coupons: list[Coupon]) -> list[Coupon]:
    return sorted(coupons, key=lambda c: c.current_uses, reverse=True)


def sort_coupons_by_remaining(coupons: list[Coupon]) -> list[Coupon]:
    return sorted(coupons, key=lambda c: coupon_remaining_uses(c))


def sort_rules_by_min_order(rules: list[PromotionRule]) -> list[PromotionRule]:
    return sorted(rules, key=lambda r: r.min_order_value, reverse=True)


def total_coupon_uses(coupons: list[Coupon]) -> int:
    return functools.reduce(lambda acc, c: acc + c.current_uses, coupons, 0)


def total_coupon_capacity(coupons: list[Coupon]) -> int:
    return functools.reduce(lambda acc, c: acc + c.max_uses, coupons, 0)


def overall_coupon_usage_pct(coupons: list[Coupon]) -> int:
    cap = total_coupon_capacity(coupons)
    if cap == 0:
        return 0
    return (total_coupon_uses(coupons) * 100) // cap


def avg_coupon_discount_value(coupons: list[Coupon]) -> int:
    cnt = len(coupons)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, c: acc + c.discount_value, coupons, 0) // cnt


def avg_coupon_uses(coupons: list[Coupon]) -> int:
    cnt = len(coupons)
    if cnt == 0:
        return 0
    return total_coupon_uses(coupons) // cnt


def most_used_coupon(coupons: list[Coupon]) -> Optional[Coupon]:
    if not coupons:
        return None
    return functools.reduce(
        lambda best, c: c if c.current_uses > best.current_uses else best,
        coupons[1:],
        coupons[0]
    )


def nearly_exhausted_coupon(coupons: list[Coupon]) -> Optional[Coupon]:
    valid = valid_coupons(coupons)
    if not valid:
        return None
    return functools.reduce(
        lambda best, c: c if coupon_remaining_uses(c) < coupon_remaining_uses(best) else best,
        valid[1:],
        valid[0]
    )


def total_campaign_uses(campaigns: list[Campaign], coupons: list[Coupon]) -> int:
    return functools.reduce(
        lambda acc, camp: acc + campaign_total_uses(coupons, camp.id),
        campaigns,
        0
    )


def avg_uses_per_campaign(campaigns: list[Campaign], coupons: list[Coupon]) -> int:
    cnt = len(campaigns)
    if cnt == 0:
        return 0
    return total_campaign_uses(campaigns, coupons) // cnt


def most_popular_campaign(campaigns: list[Campaign], coupons: list[Coupon]) -> Optional[Campaign]:
    if not campaigns:
        return None
    return functools.reduce(
        lambda best, camp: camp if campaign_total_uses(coupons, camp.id) > campaign_total_uses(coupons, best.id) else best,
        campaigns[1:],
        campaigns[0]
    )


def campaign_with_most_coupons(campaigns: list[Campaign], coupons: list[Coupon]) -> Optional[Campaign]:
    if not campaigns:
        return None
    return functools.reduce(
        lambda best, camp: camp if campaign_coupon_count(coupons, camp.id) > campaign_coupon_count(coupons, best.id) else best,
        campaigns[1:],
        campaigns[0]
    )


def total_rule_count(rules: list[PromotionRule]) -> int:
    return len(rules)


def avg_rule_min_order(rules: list[PromotionRule]) -> int:
    cnt = len(rules)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, r: acc + r.min_order_value, rules, 0) // cnt


def max_rule_min_order(rules: list[PromotionRule]) -> int:
    if not rules:
        return 0
    return functools.reduce(
        lambda best, r: r.min_order_value if r.min_order_value > best else best,
        rules,
        0
    )


def rule_count_by_tier(rules: list[PromotionRule], tier: str) -> int:
    return len([r for r in rules if r.min_tier == tier])


def customer_total_discount(orders: list[ord.Order], cust_id: int) -> int:
    cust_orders = ord.orders_by_customer(orders, cust_id)
    return functools.reduce(lambda acc, o: acc + o.discount, cust_orders, 0)


def customer_avg_discount(orders: list[ord.Order], cust_id: int) -> int:
    cust_orders = ord.orders_by_customer(orders, cust_id)
    cnt = len(cust_orders)
    if cnt == 0:
        return 0
    return customer_total_discount(orders, cust_id) // cnt


def customer_discount_pct(orders: list[ord.Order], cust_id: int) -> int:
    cust_orders = ord.orders_by_customer(orders, cust_id)
    subtotal_sum = functools.reduce(lambda acc, o: acc + o.subtotal, cust_orders, 0)
    discount_sum = customer_total_discount(orders, cust_id)
    if subtotal_sum == 0:
        return 0
    return (discount_sum * 100) // subtotal_sum


def orders_with_discount_above(orders: list[ord.Order], threshold: int) -> list[ord.Order]:
    return [o for o in orders if o.discount > threshold]


def discounted_order_count(orders: list[ord.Order]) -> int:
    return len([o for o in orders if o.discount > 0])


def discount_frequency_pct(orders: list[ord.Order]) -> int:
    total = len(orders)
    if total == 0:
        return 0
    return (discounted_order_count(orders) * 100) // total


def avg_discount_per_discounted_order(orders: list[ord.Order]) -> int:
    discounted = [o for o in orders if o.discount > 0]
    cnt = len(discounted)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, o: acc + o.discount, discounted, 0) // cnt


def coupons_for_category(coupons: list[Coupon], rules: list[PromotionRule], cat_id: int) -> list[Coupon]:
    cat_rules = rules_for_category(rules, cat_id)
    camp_ids = list(dict.fromkeys(r.campaign_id for r in cat_rules))
    return [c for c in coupons if any(cid == c.campaign_id for cid in camp_ids)]


def category_campaign_count(campaigns: list[Campaign], rules: list[PromotionRule], cat_id: int, now: int) -> int:
    cat_rules = rules_for_category(rules, cat_id)
    camp_ids = list(dict.fromkeys(r.campaign_id for r in cat_rules))
    active = active_campaigns(campaigns, now)
    return len([camp for camp in active if any(cid == camp.id for cid in camp_ids)])


def customers_qualifying_for_tier(customers: list[cust.Customer], min_tier: str) -> list[cust.Customer]:
    return [c for c in customers if tier_qualifies(c.tier, min_tier)]


def rule_eligible_customer_count(rule: PromotionRule, customers: list[cust.Customer]) -> int:
    return len(customers_qualifying_for_tier(customers, rule.min_tier))


def simulate_coupon(coupon: Coupon, order_total: int) -> dict:
    disc = coupon_discount_amount(coupon, order_total)
    final = order_total - disc
    return {"original": order_total, "discount": disc, "final": final}


def simulate_all_coupons(coupons: list[Coupon], order_total: int) -> list[dict]:
    return [
        {"coupon_id": c.id, "code": c.code,
         "discount": coupon_discount_amount(c, order_total),
         "final": order_total - coupon_discount_amount(c, order_total)}
        for c in valid_coupons(coupons)
    ]


def bulk_use_coupons(coupons: list[Coupon]) -> list[Coupon]:
    return [use_coupon(c) if coupon_valid(c) else c for c in coupons]


def deactivate_expired(campaigns: list[Campaign], now: int) -> list[Campaign]:
    return [
        deactivate_campaign(c) if (c.status == "active" and c.end_date < now) else c
        for c in campaigns
    ]


def reset_campaign_coupons(coupons: list[Coupon], cid: int) -> list[Coupon]:
    return [reset_coupon_uses(c) if c.campaign_id == cid else c for c in coupons]


def promotions_dashboard(campaigns: list[Campaign], coupons: list[Coupon], rules: list[PromotionRule], orders: list[ord.Order], now: int) -> dict:
    active = active_campaigns(campaigns, now)
    total_uses = total_coupon_uses(coupons)
    total_cap = total_coupon_capacity(coupons)
    total_disc = total_discount_given(coupons, orders)
    return {
        "active_campaigns": len(active),
        "total_campaigns": len(campaigns),
        "total_coupons": len(coupons),
        "valid_coupons": len(valid_coupons(coupons)),
        "exhausted_coupons": len(exhausted_coupons(coupons)),
        "total_uses": total_uses,
        "total_capacity": total_cap,
        "usage_pct": 0 if total_cap == 0 else (total_uses * 100) // total_cap,
        "total_discount": total_disc,
        "total_rules": len(rules),
    }


def campaign_breakdown(campaigns: list[Campaign], coupons: list[Coupon], rules: list[PromotionRule]) -> list[dict]:
    result = []
    for camp in campaigns:
        cid = camp.id
        camp_coupons = coupons_for_campaign(coupons, cid)
        camp_rules = find_rules_for_campaign(rules, cid)
        result.append({
            "campaign_id": cid,
            "name": camp.name,
            "status": camp.status,
            "coupon_count": len(camp_coupons),
            "rule_count": len(camp_rules),
            "total_uses": campaign_total_uses(coupons, cid),
            "valid_coupons": len(valid_coupons(camp_coupons)),
            "exhausted_coupons": len(exhausted_coupons(camp_coupons)),
        })
    return result


def coupon_effectiveness_report(coupons: list[Coupon]) -> list[dict]:
    return [
        {
            "coupon_id": c.id,
            "code": c.code,
            "type": c.discount_type,
            "value": c.discount_value,
            "uses": c.current_uses,
            "max_uses": c.max_uses,
            "usage_pct": coupon_usage_pct(c),
            "remaining": coupon_remaining_uses(c),
            "exhausted": coupon_exhausted(c),
        }
        for c in coupons
    ]


def tier_distribution(rules: list[PromotionRule]) -> dict:
    return {
        "any": rule_count_by_tier(rules, ""),
        "bronze": rule_count_by_tier(rules, "bronze"),
        "silver": rule_count_by_tier(rules, "silver"),
        "gold": rule_count_by_tier(rules, "gold"),
    }


def top_coupons_by_usage(coupons: list[Coupon], n: int) -> list[Coupon]:
    return sorted(coupons, key=lambda c: c.current_uses, reverse=True)[:n]


def top_coupons_by_value(coupons: list[Coupon], n: int) -> list[Coupon]:
    return sort_coupons_by_value(coupons)[:n]


def top_campaigns_by_uses(campaigns: list[Campaign], coupons: list[Coupon], n: int) -> list[Campaign]:
    return sorted(campaigns, key=lambda camp: campaign_total_uses(coupons, camp.id), reverse=True)[:n]


def code_exists(coupons: list[Coupon], code: str) -> bool:
    return find_coupon_by_code(coupons, code) is not None


def all_coupon_codes(coupons: list[Coupon]) -> list[str]:
    return [c.code for c in coupons]


def coupon_campaign_ids(coupons: list[Coupon]) -> list[int]:
    return list(dict.fromkeys(c.campaign_id for c in coupons))


def coupon_count_by_type(coupons: list[Coupon], dtype: str) -> int:
    return len([c for c in coupons if c.discount_type == dtype])


def discount_type_distribution(coupons: list[Coupon]) -> dict:
    return {
        "percentage": coupon_count_by_type(coupons, "percentage"),
        "fixed": coupon_count_by_type(coupons, "fixed"),
    }


def avg_discount_by_type(coupons: list[Coupon], dtype: str) -> int:
    typed = [c for c in coupons if c.discount_type == dtype]
    cnt = len(typed)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, c: acc + c.discount_value, typed, 0) // cnt


def coupons_stackable(c1: Coupon, c2: Coupon) -> bool:
    return c1.campaign_id != c2.campaign_id


def stacked_discount(c1: Coupon, c2: Coupon, order_total: int) -> int:
    d1 = coupon_discount_amount(c1, order_total)
    d2 = coupon_discount_amount(c2, order_total)
    raw = d1 + d2
    return order_total if raw > order_total else raw


def best_stacked_discount(coupons: list[Coupon], order_total: int) -> int:
    valid = valid_coupons(coupons)
    if len(valid) < 2:
        return 0
    return functools.reduce(
        lambda best_val, c1: functools.reduce(
            lambda inner_best, c2: stacked_discount(c1, c2, order_total)
            if (coupons_stackable(c1, c2) and stacked_discount(c1, c2, order_total) > inner_best)
            else inner_best,
            valid,
            best_val
        ),
        valid,
        0
    )


def lowest_min_order(coupons: list[Coupon]) -> int:
    valid = valid_coupons(coupons)
    if not valid:
        return 0
    return functools.reduce(
        lambda best, c: c.min_order if c.min_order < best else best,
        valid[1:],
        valid[0].min_order
    )


def highest_min_order(coupons: list[Coupon]) -> int:
    valid = valid_coupons(coupons)
    if not valid:
        return 0
    return functools.reduce(
        lambda best, c: c.min_order if c.min_order > best else best,
        valid[1:],
        valid[0].min_order
    )


def avg_min_order(coupons: list[Coupon]) -> int:
    cnt = len(coupons)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, c: acc + c.min_order, coupons, 0) // cnt
