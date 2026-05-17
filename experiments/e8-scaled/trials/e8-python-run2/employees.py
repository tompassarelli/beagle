from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional
import catalog as cat
import orders as ord


@dataclass
class Employee:
    id: int
    name: str
    department: str
    role: str
    hire_date: int
    active: bool


@dataclass
class CommissionRule:
    id: int
    employee_id: int
    category_id: int
    rate_pct: int


@dataclass
class SalesTarget:
    id: int
    employee_id: int
    period: str
    target_amount: int
    actual_amount: int


def employee_id(r: Employee) -> int:
    return r.id


def employee_name(r: Employee) -> str:
    return r.name


def employee_department(r: Employee) -> str:
    return r.department


def employee_role(r: Employee) -> str:
    return r.role


def employee_hire_date(r: Employee) -> int:
    return r.hire_date


def employee_active(r: Employee) -> bool:
    return r.active


def commissionrule_id(r: CommissionRule) -> int:
    return r.id


def commissionrule_employee_id(r: CommissionRule) -> int:
    return r.employee_id


def commissionrule_category_id(r: CommissionRule) -> int:
    return r.category_id


def commissionrule_rate_pct(r: CommissionRule) -> int:
    return r.rate_pct


def salestarget_id(r: SalesTarget) -> int:
    return r.id


def salestarget_employee_id(r: SalesTarget) -> int:
    return r.employee_id


def salestarget_period(r: SalesTarget) -> str:
    return r.period


def salestarget_target_amount(r: SalesTarget) -> int:
    return r.target_amount


def salestarget_actual_amount(r: SalesTarget) -> int:
    return r.actual_amount


def find_employee_by_id(employees: list[Employee], id: int) -> Optional[Employee]:
    matches = [e for e in employees if employee_id(e) == id]
    return matches[0] if matches else None


def active_employees(employees: list[Employee]) -> list[Employee]:
    return [e for e in employees if employee_active(e)]


def employees_by_department(employees: list[Employee], dept: str) -> list[Employee]:
    return [e for e in employees if employee_department(e) == dept]


def employees_by_role(employees: list[Employee], role: str) -> list[Employee]:
    return [e for e in employees if employee_role(e) == role]


def employee_tenure_days(employee: Employee, now: int) -> int:
    return (now - employee_hire_date(employee)) // 86400


def senior_employees(employees: list[Employee], now: int, min_days: int) -> list[Employee]:
    return [e for e in employees if employee_tenure_days(e, now) >= min_days]


def rules_for_employee(rules: list[CommissionRule], employee_id: int) -> list[CommissionRule]:
    return [r for r in rules if commissionrule_employee_id(r) == employee_id]


def commission_rate(rules: list[CommissionRule], employee_id: int, category_id: int) -> int:
    matches = [r for r in rules if commissionrule_employee_id(r) == employee_id and commissionrule_category_id(r) == category_id]
    if not matches:
        return 0
    return commissionrule_rate_pct(matches[0])


def line_commission(rules: list[CommissionRule], employee_id: int, product: cat.Product, ol: ord.OrderLine) -> int:
    cat_id = cat.product_category_id(product)
    rate = commission_rate(rules, employee_id, cat_id)
    amount = ord.orderline_line_total(ol)
    return (rate * amount) // 100


def order_commission(rules: list[CommissionRule], employee_id: int, order: ord.Order, products: list[cat.Product]) -> int:
    lines = ord.order_lines(order)
    acc = 0
    for ol in lines:
        prod_id = ord.orderline_product_id(ol)
        product = cat.find_product_by_id(products, prod_id)
        if product is not None:
            acc += line_commission(rules, employee_id, product, ol)
    return acc


def total_commission(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    return functools.reduce(lambda acc, o: acc + order_commission(rules, employee_id, o, products), orders, 0)


def top_earner(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> Optional[Employee]:
    actives = active_employees(employees)
    if not actives:
        return None
    return functools.reduce(
        lambda best, e: e if total_commission(rules, employee_id(e), orders, products) > total_commission(rules, employee_id(best), orders, products) else best,
        actives[1:],
        actives[0],
    )


def targets_for_employee(targets: list[SalesTarget], employee_id: int) -> list[SalesTarget]:
    return [t for t in targets if salestarget_employee_id(t) == employee_id]


def target_for_period(targets: list[SalesTarget], employee_id: int, period: str) -> Optional[SalesTarget]:
    matches = [t for t in targets if salestarget_employee_id(t) == employee_id and salestarget_period(t) == period]
    return matches[0] if matches else None


def target_achievement_pct(target: SalesTarget) -> int:
    ta = salestarget_target_amount(target)
    if ta == 0:
        return 0
    return (salestarget_actual_amount(target) * 100) // ta


def on_target(target: SalesTarget) -> bool:
    return target_achievement_pct(target) >= 100


def targets_met_count(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    return len([t for t in emp_targets if on_target(t)])


def update_actual(target: SalesTarget, amount: int) -> SalesTarget:
    return SalesTarget(
        salestarget_id(target),
        salestarget_employee_id(target),
        salestarget_period(target),
        salestarget_target_amount(target),
        amount,
    )


def department_headcount(employees: list[Employee], dept: str) -> int:
    return len(employees_by_department(employees, dept))


def department_total_commission(rules: list[CommissionRule], employees: list[Employee], dept: str, orders: list[ord.Order], products: list[cat.Product]) -> int:
    dept_emps = employees_by_department(employees, dept)
    return functools.reduce(lambda acc, e: acc + total_commission(rules, employee_id(e), orders, products), dept_emps, 0)


def avg_commission_per_employee(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> int:
    actives = active_employees(employees)
    cnt = len(actives)
    if cnt == 0:
        return 0
    total = functools.reduce(lambda acc, e: acc + total_commission(rules, employee_id(e), orders, products), actives, 0)
    return total // cnt


def employee_summary(e: Employee) -> str:
    return employee_name(e) + " (" + employee_department(e) + "/" + employee_role(e) + ")"


def employee_detail(e: Employee, now: int) -> str:
    return (
        employee_name(e)
        + " | Dept: " + employee_department(e)
        + " | Role: " + employee_role(e)
        + " | Tenure: " + str(employee_tenure_days(e, now)) + " days"
        + " | Active: " + str(employee_active(e))
    )


def valid_employee(e: Employee) -> bool:
    return (
        employee_id(e) > 0
        and employee_name(e) != ""
        and employee_department(e) != ""
        and employee_role(e) != ""
    )


def valid_commission_rule(r: CommissionRule) -> bool:
    return (
        commissionrule_id(r) > 0
        and commissionrule_employee_id(r) > 0
        and commissionrule_category_id(r) > 0
        and commissionrule_rate_pct(r) > 0
        and commissionrule_rate_pct(r) <= 100
    )


def valid_sales_target(t: SalesTarget) -> bool:
    return (
        salestarget_id(t) > 0
        and salestarget_employee_id(t) > 0
        and salestarget_period(t) != ""
        and salestarget_target_amount(t) > 0
        and salestarget_actual_amount(t) >= 0
    )


def employee_commission_breakdown(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> list[dict]:
    emp_rules = rules_for_employee(rules, employee_id)
    result = []
    for r in emp_rules:
        cat_id = commissionrule_category_id(r)
        rate = commissionrule_rate_pct(r)
        cat_commission = 0
        for o in orders:
            lines = ord.order_lines(o)
            for ol in lines:
                prod_id = ord.orderline_product_id(ol)
                product = cat.find_product_by_id(products, prod_id)
                if product is not None and cat.product_category_id(product) == cat_id:
                    cat_commission += (rate * ord.orderline_line_total(ol)) // 100
        result.append({"category_id": cat_id, "rate": rate, "commission": cat_commission})
    return result


def employee_top_category(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    breakdown = employee_commission_breakdown(rules, employee_id, orders, products)
    if not breakdown:
        return 0
    best = functools.reduce(
        lambda b, item: item if item["commission"] > b["commission"] else b,
        breakdown[1:],
        breakdown[0],
    )
    return best["category_id"]


def employee_target_summary(targets: list[SalesTarget], employee_id: int) -> dict:
    emp_targets = targets_for_employee(targets, employee_id)
    total_target = functools.reduce(lambda acc, t: acc + salestarget_target_amount(t), emp_targets, 0)
    total_actual = functools.reduce(lambda acc, t: acc + salestarget_actual_amount(t), emp_targets, 0)
    met = targets_met_count(targets, employee_id)
    return {"total_target": total_target, "total_actual": total_actual, "targets_met": met, "total_targets": len(emp_targets)}


def best_performing_period(targets: list[SalesTarget], employee_id: int) -> Optional[str]:
    emp_targets = targets_for_employee(targets, employee_id)
    if not emp_targets:
        return None
    best = functools.reduce(
        lambda b, t: t if target_achievement_pct(t) > target_achievement_pct(b) else b,
        emp_targets[1:],
        emp_targets[0],
    )
    return salestarget_period(best)


def worst_performing_period(targets: list[SalesTarget], employee_id: int) -> Optional[str]:
    emp_targets = targets_for_employee(targets, employee_id)
    if not emp_targets:
        return None
    worst = functools.reduce(
        lambda b, t: t if target_achievement_pct(t) < target_achievement_pct(b) else b,
        emp_targets[1:],
        emp_targets[0],
    )
    return salestarget_period(worst)


def department_avg_tenure(employees: list[Employee], dept: str, now: int) -> int:
    dept_emps = employees_by_department(employees, dept)
    cnt = len(dept_emps)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, e: acc + employee_tenure_days(e, now), dept_emps, 0) // cnt


def department_active_count(employees: list[Employee], dept: str) -> int:
    return len([e for e in employees if employee_department(e) == dept and employee_active(e)])


def department_active_pct(employees: list[Employee], dept: str) -> int:
    total = department_headcount(employees, dept)
    if total == 0:
        return 0
    return (department_active_count(employees, dept) * 100) // total


def deactivate_employee(employees: list[Employee], target_id: int) -> list[Employee]:
    return [
        Employee(
            employee_id(e),
            employee_name(e),
            employee_department(e),
            employee_role(e),
            employee_hire_date(e),
            False,
        ) if employee_id(e) == target_id else e
        for e in employees
    ]


def activate_employee(employees: list[Employee], target_id: int) -> list[Employee]:
    return [
        Employee(
            employee_id(e),
            employee_name(e),
            employee_department(e),
            employee_role(e),
            employee_hire_date(e),
            True,
        ) if employee_id(e) == target_id else e
        for e in employees
    ]


def change_department(employee: Employee, new_dept: str) -> Employee:
    return Employee(
        employee_id(employee),
        employee_name(employee),
        new_dept,
        employee_role(employee),
        employee_hire_date(employee),
        employee_active(employee),
    )


def change_role(employee: Employee, new_role: str) -> Employee:
    return Employee(
        employee_id(employee),
        employee_name(employee),
        employee_department(employee),
        new_role,
        employee_hire_date(employee),
        employee_active(employee),
    )


def add_commission_rule(rules: list[CommissionRule], rule: CommissionRule) -> list[CommissionRule]:
    return rules + [rule]


def remove_commission_rule(rules: list[CommissionRule], rule_id: int) -> list[CommissionRule]:
    return [r for r in rules if commissionrule_id(r) != rule_id]


def update_commission_rate(rules: list[CommissionRule], rule_id: int, new_rate: int) -> list[CommissionRule]:
    return [
        CommissionRule(
            commissionrule_id(r),
            commissionrule_employee_id(r),
            commissionrule_category_id(r),
            new_rate,
        ) if commissionrule_id(r) == rule_id else r
        for r in rules
    ]


def employee_order_count(employee_id: int, orders: list[ord.Order]) -> int:
    return len(orders)


def employee_revenue(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    return total_commission(rules, employee_id, orders, products)


def rank_by_commission(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> list[Employee]:
    actives = active_employees(employees)
    return list(reversed(sorted(actives, key=lambda e: total_commission(rules, employee_id(e), orders, products))))


def rank_by_tenure(employees: list[Employee], now: int) -> list[Employee]:
    return list(reversed(sorted(employees, key=lambda e: employee_tenure_days(e, now))))


def commission_leaderboard(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> list[dict]:
    ranked = rank_by_commission(rules, employees, orders, products)
    return [{"employee_id": employee_id(e), "name": employee_name(e), "commission": total_commission(rules, employee_id(e), orders, products)} for e in ranked]


def total_headcount(employees: list[Employee]) -> int:
    return len(employees)


def active_headcount(employees: list[Employee]) -> int:
    return len(active_employees(employees))


def turnover_rate_pct(employees: list[Employee]) -> int:
    total = total_headcount(employees)
    if total == 0:
        return 0
    inactive = total - active_headcount(employees)
    return (inactive * 100) // total


def unique_departments(employees: list[Employee]) -> list[str]:
    seen: set[str] = set()
    result = []
    for e in employees:
        dept = employee_department(e)
        if dept not in seen:
            seen.add(dept)
            result.append(dept)
    return result


def unique_roles(employees: list[Employee]) -> list[str]:
    seen: set[str] = set()
    result = []
    for e in employees:
        role = employee_role(e)
        if role not in seen:
            seen.add(role)
            result.append(role)
    return result


def department_roster(employees: list[Employee], dept: str) -> list[dict]:
    dept_emps = employees_by_department(employees, dept)
    return [{"id": employee_id(e), "name": employee_name(e), "role": employee_role(e), "active": employee_active(e)} for e in dept_emps]


def target_gap(target: SalesTarget) -> int:
    diff = salestarget_target_amount(target) - salestarget_actual_amount(target)
    return diff if diff > 0 else 0


def target_surplus(target: SalesTarget) -> int:
    diff = salestarget_actual_amount(target) - salestarget_target_amount(target)
    return diff if diff > 0 else 0


def employee_total_target(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    return functools.reduce(lambda acc, t: acc + salestarget_target_amount(t), emp_targets, 0)


def employee_total_actual(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    return functools.reduce(lambda acc, t: acc + salestarget_actual_amount(t), emp_targets, 0)


def employee_total_gap(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    return functools.reduce(lambda acc, t: acc + target_gap(t), emp_targets, 0)


def employee_total_surplus(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    return functools.reduce(lambda acc, t: acc + target_surplus(t), emp_targets, 0)


def employee_overall_achievement_pct(targets: list[SalesTarget], employee_id: int) -> int:
    total_tgt = employee_total_target(targets, employee_id)
    if total_tgt == 0:
        return 0
    return (employee_total_actual(targets, employee_id) * 100) // total_tgt


def employees_above_commission(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product], threshold: int) -> list[Employee]:
    return [e for e in active_employees(employees) if total_commission(rules, employee_id(e), orders, products) >= threshold]


def employees_below_commission(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product], threshold: int) -> list[Employee]:
    return [e for e in active_employees(employees) if total_commission(rules, employee_id(e), orders, products) < threshold]


def commission_spread(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> int:
    actives = active_employees(employees)
    if not actives:
        return 0
    commissions = [total_commission(rules, employee_id(e), orders, products) for e in actives]
    return max(commissions) - min(commissions)


def median_commission(rules: list[CommissionRule], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> int:
    actives = active_employees(employees)
    if not actives:
        return 0
    commissions = sorted([total_commission(rules, employee_id(e), orders, products) for e in actives])
    cnt = len(commissions)
    mid = cnt // 2
    return commissions[mid]


def category_total_commission(rules: list[CommissionRule], employees: list[Employee], category_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    actives = active_employees(employees)
    acc = 0
    for e in actives:
        rate = commission_rate(rules, employee_id(e), category_id)
        for o in orders:
            lines = ord.order_lines(o)
            for ol in lines:
                prod_id = ord.orderline_product_id(ol)
                product = cat.find_product_by_id(products, prod_id)
                if product is not None and cat.product_category_id(product) == category_id:
                    acc += (rate * ord.orderline_line_total(ol)) // 100
    return acc


def category_avg_commission_rate(rules: list[CommissionRule], category_id: int) -> int:
    matching = [r for r in rules if commissionrule_category_id(r) == category_id]
    cnt = len(matching)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, r: acc + commissionrule_rate_pct(r), matching, 0) // cnt


def categories_with_rules(rules: list[CommissionRule]) -> list[int]:
    seen: set[int] = set()
    result = []
    for r in rules:
        cid = commissionrule_category_id(r)
        if cid not in seen:
            seen.add(cid)
            result.append(cid)
    return result


def rules_for_category(rules: list[CommissionRule], category_id: int) -> list[CommissionRule]:
    return [r for r in rules if commissionrule_category_id(r) == category_id]


def category_rule_count(rules: list[CommissionRule], category_id: int) -> int:
    return len(rules_for_category(rules, category_id))


def performance_score(rules: list[CommissionRule], targets: list[SalesTarget], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    comm = total_commission(rules, employee_id, orders, products)
    achievement = employee_overall_achievement_pct(targets, employee_id)
    met = targets_met_count(targets, employee_id)
    return (comm // 100) + (achievement * 2) + (met * 500)


def rank_by_performance(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> list[Employee]:
    actives = active_employees(employees)
    return list(reversed(sorted(actives, key=lambda e: performance_score(rules, targets, employee_id(e), orders, products))))


def top_performers(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product], n: int) -> list[Employee]:
    ranked = rank_by_performance(rules, targets, employees, orders, products)
    return list(ranked[:n])


def bottom_performers(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product], n: int) -> list[Employee]:
    ranked = rank_by_performance(rules, targets, employees, orders, products)
    return list(reversed(ranked))[:n]


def performance_report(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product]) -> list[dict]:
    actives = active_employees(employees)
    result = []
    for e in actives:
        eid = employee_id(e)
        result.append({
            "employee_id": eid,
            "name": employee_name(e),
            "department": employee_department(e),
            "commission": total_commission(rules, eid, orders, products),
            "achievement_pct": employee_overall_achievement_pct(targets, eid),
            "targets_met": targets_met_count(targets, eid),
            "score": performance_score(rules, targets, eid, orders, products),
        })
    return result


def department_commission_breakdown(rules: list[CommissionRule], employees: list[Employee], dept: str, orders: list[ord.Order], products: list[cat.Product]) -> list[dict]:
    dept_emps = employees_by_department(employees, dept)
    return [{"employee_id": employee_id(e), "name": employee_name(e), "commission": total_commission(rules, employee_id(e), orders, products)} for e in dept_emps]


def department_avg_commission(rules: list[CommissionRule], employees: list[Employee], dept: str, orders: list[ord.Order], products: list[cat.Product]) -> int:
    dept_emps = employees_by_department(employees, dept)
    cnt = len(dept_emps)
    if cnt == 0:
        return 0
    return department_total_commission(rules, employees, dept, orders, products) // cnt


def department_commission_spread(rules: list[CommissionRule], employees: list[Employee], dept: str, orders: list[ord.Order], products: list[cat.Product]) -> int:
    dept_emps = employees_by_department(employees, dept)
    if not dept_emps:
        return 0
    commissions = [total_commission(rules, employee_id(e), orders, products) for e in dept_emps]
    return max(commissions) - min(commissions)


def newest_employee(employees: list[Employee]) -> Optional[Employee]:
    if not employees:
        return None
    return functools.reduce(
        lambda newest, e: e if employee_hire_date(e) > employee_hire_date(newest) else newest,
        employees[1:],
        employees[0],
    )


def oldest_employee(employees: list[Employee]) -> Optional[Employee]:
    if not employees:
        return None
    return functools.reduce(
        lambda oldest, e: e if employee_hire_date(e) < employee_hire_date(oldest) else oldest,
        employees[1:],
        employees[0],
    )


def avg_tenure_days(employees: list[Employee], now: int) -> int:
    cnt = len(employees)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, e: acc + employee_tenure_days(e, now), employees, 0) // cnt


def tenure_spread_days(employees: list[Employee], now: int) -> int:
    if not employees:
        return 0
    tenures = [employee_tenure_days(e, now) for e in employees]
    return max(tenures) - min(tenures)


def employees_hired_in_period(employees: list[Employee], start: int, end: int) -> list[Employee]:
    return [e for e in employees if employee_hire_date(e) >= start and employee_hire_date(e) <= end]


def hire_count_in_period(employees: list[Employee], start: int, end: int) -> int:
    return len(employees_hired_in_period(employees, start, end))


def employee_order_revenue(rules: list[CommissionRule], employee_id: int, order: ord.Order, products: list[cat.Product]) -> int:
    return order_commission(rules, employee_id, order, products)


def employee_avg_order_commission(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> int:
    cnt = len(orders)
    if cnt == 0:
        return 0
    return total_commission(rules, employee_id, orders, products) // cnt


def employee_highest_commission_order(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> Optional[ord.Order]:
    if not orders:
        return None
    return functools.reduce(
        lambda best, o: o if order_commission(rules, employee_id, o, products) > order_commission(rules, employee_id, best, products) else best,
        orders[1:],
        orders[0],
    )


def employee_zero_commission_orders(rules: list[CommissionRule], employee_id: int, orders: list[ord.Order], products: list[cat.Product]) -> list[ord.Order]:
    return [o for o in orders if order_commission(rules, employee_id, o, products) == 0]


def increment_actual(target: SalesTarget, amount: int) -> SalesTarget:
    return SalesTarget(
        salestarget_id(target),
        salestarget_employee_id(target),
        salestarget_period(target),
        salestarget_target_amount(target),
        salestarget_actual_amount(target) + amount,
    )


def update_target_amount(target: SalesTarget, new_target: int) -> SalesTarget:
    return SalesTarget(
        salestarget_id(target),
        salestarget_employee_id(target),
        salestarget_period(target),
        new_target,
        salestarget_actual_amount(target),
    )


def remaining_to_target(target: SalesTarget) -> int:
    return target_gap(target)


def target_completion_rate(targets: list[SalesTarget], employee_id: int) -> int:
    emp_targets = targets_for_employee(targets, employee_id)
    cnt = len(emp_targets)
    if cnt == 0:
        return 0
    return (targets_met_count(targets, employee_id) * 100) // cnt


def employee_full_report(rules: list[CommissionRule], targets: list[SalesTarget], employee: Employee, orders: list[ord.Order], products: list[cat.Product], now: int) -> dict:
    eid = employee_id(employee)
    return {
        "employee_id": eid,
        "name": employee_name(employee),
        "department": employee_department(employee),
        "role": employee_role(employee),
        "tenure_days": employee_tenure_days(employee, now),
        "active": employee_active(employee),
        "total_commission": total_commission(rules, eid, orders, products),
        "achievement_pct": employee_overall_achievement_pct(targets, eid),
        "targets_met": targets_met_count(targets, eid),
        "performance_score": performance_score(rules, targets, eid, orders, products),
    }


def department_full_report(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], dept: str, orders: list[ord.Order], products: list[cat.Product], now: int) -> dict:
    dept_emps = employees_by_department(employees, dept)
    return {
        "department": dept,
        "headcount": len(dept_emps),
        "active_count": department_active_count(employees, dept),
        "avg_tenure": department_avg_tenure(employees, dept, now),
        "total_commission": department_total_commission(rules, employees, dept, orders, products),
        "avg_commission": department_avg_commission(rules, employees, dept, orders, products),
    }


def company_summary(rules: list[CommissionRule], targets: list[SalesTarget], employees: list[Employee], orders: list[ord.Order], products: list[cat.Product], now: int) -> dict:
    actives = active_employees(employees)
    total_comm = functools.reduce(lambda acc, e: acc + total_commission(rules, employee_id(e), orders, products), actives, 0)
    total_met = functools.reduce(lambda acc, e: acc + targets_met_count(targets, employee_id(e)), actives, 0)
    return {
        "total_employees": len(employees),
        "active_employees": len(actives),
        "departments": len(unique_departments(employees)),
        "total_commission": total_comm,
        "avg_commission": 0 if len(actives) == 0 else total_comm // len(actives),
        "avg_tenure": avg_tenure_days(employees, now),
        "total_targets_met": total_met,
        "turnover_rate": turnover_rate_pct(employees),
    }
