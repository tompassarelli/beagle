from __future__ import annotations
import functools
from dataclasses import dataclass
from typing import Optional

from customers import Customer
from orders import Order
from shipping import Shipment
from billing import Invoice


@dataclass
class Template:
    id: int
    name: str
    channel: str
    subject: str
    body_pattern: str


@dataclass
class Notification:
    id: int
    template_id: int
    customer_id: int
    reference_id: int
    reference_type: str
    status: str
    created_at: int
    sent_at: int


@dataclass
class Preference:
    customer_id: int
    channel: str
    enabled: bool


def template_id(r: Template) -> int:
    return r.id


def template_name(r: Template) -> str:
    return r.name


def template_channel(r: Template) -> str:
    return r.channel


def template_subject(r: Template) -> str:
    return r.subject


def template_body_pattern(r: Template) -> str:
    return r.body_pattern


def notification_id(r: Notification) -> int:
    return r.id


def notification_template_id(r: Notification) -> int:
    return r.template_id


def notification_customer_id(r: Notification) -> int:
    return r.customer_id


def notification_reference_id(r: Notification) -> int:
    return r.reference_id


def notification_reference_type(r: Notification) -> str:
    return r.reference_type


def notification_status(r: Notification) -> str:
    return r.status


def notification_created_at(r: Notification) -> int:
    return r.created_at


def notification_sent_at(r: Notification) -> int:
    return r.sent_at


def preference_customer_id(r: Preference) -> int:
    return r.customer_id


def preference_channel(r: Preference) -> str:
    return r.channel


def preference_enabled(r: Preference) -> bool:
    return r.enabled


def find_template_by_id(templates: list[Template], id: int) -> Optional[Template]:
    matches = [t for t in templates if template_id(t) == id]
    return matches[0] if matches else None


def find_template_by_name(templates: list[Template], name: str) -> Optional[Template]:
    matches = [t for t in templates if template_name(t) == name]
    return matches[0] if matches else None


def templates_for_channel(templates: list[Template], channel: str) -> list[Template]:
    return [t for t in templates if template_channel(t) == channel]


def create_notification(id: int, template: Template, customer: Customer, reference_id: int, reference_type: str, created_at: int) -> Notification:
    return Notification(id, template_id(template), customer.id, reference_id, reference_type, "pending", created_at, 0)


def send_notification(n: Notification, sent_at: int) -> Notification:
    if notification_status(n) == "pending":
        return Notification(notification_id(n), notification_template_id(n), notification_customer_id(n), notification_reference_id(n), notification_reference_type(n), "sent", notification_created_at(n), sent_at)
    return n


def fail_notification(n: Notification) -> Notification:
    if notification_status(n) == "pending":
        return Notification(notification_id(n), notification_template_id(n), notification_customer_id(n), notification_reference_id(n), notification_reference_type(n), "failed", notification_created_at(n), notification_sent_at(n))
    return n


def retry_notification(n: Notification) -> Notification:
    if notification_status(n) == "failed":
        return Notification(notification_id(n), notification_template_id(n), notification_customer_id(n), notification_reference_id(n), notification_reference_type(n), "pending", notification_created_at(n), notification_sent_at(n))
    return n


def find_notification_by_id(notifications: list[Notification], id: int) -> Optional[Notification]:
    matches = [n for n in notifications if notification_id(n) == id]
    return matches[0] if matches else None


def notifications_for_customer(notifications: list[Notification], customer_id: int) -> list[Notification]:
    return [n for n in notifications if notification_customer_id(n) == customer_id]


def notifications_by_status(notifications: list[Notification], status: str) -> list[Notification]:
    return [n for n in notifications if notification_status(n) == status]


def pending_notifications(notifications: list[Notification]) -> list[Notification]:
    return notifications_by_status(notifications, "pending")


def sent_notifications(notifications: list[Notification]) -> list[Notification]:
    return notifications_by_status(notifications, "sent")


def notifications_for_reference(notifications: list[Notification], reference_id: int, reference_type: str) -> list[Notification]:
    return [n for n in notifications if notification_reference_id(n) == reference_id and notification_reference_type(n) == reference_type]


def customer_preferences(prefs: list[Preference], customer_id: int) -> list[Preference]:
    return [p for p in prefs if preference_customer_id(p) == customer_id]


def channel_enabled(prefs: list[Preference], customer_id: int, channel: str) -> bool:
    matching = [p for p in prefs if preference_customer_id(p) == customer_id and preference_channel(p) == channel]
    if not matching:
        return True
    return preference_enabled(matching[0])


def set_preference(prefs: list[Preference], customer_id: int, channel: str, enabled: bool) -> list[Preference]:
    exists = any(preference_customer_id(p) == customer_id and preference_channel(p) == channel for p in prefs)
    if exists:
        return [Preference(customer_id, channel, enabled) if (preference_customer_id(p) == customer_id and preference_channel(p) == channel) else p for p in prefs]
    return prefs + [Preference(customer_id, channel, enabled)]


def delivery_rate_pct(notifications: list[Notification]) -> int:
    sent_count = len(notifications_by_status(notifications, "sent"))
    failed_count = len(notifications_by_status(notifications, "failed"))
    total = sent_count + failed_count
    if total == 0:
        return 100
    return (sent_count * 100) // total


def notifications_sent_count(notifications: list[Notification]) -> int:
    return len(notifications_by_status(notifications, "sent"))


def notifications_failed_count(notifications: list[Notification]) -> int:
    return len(notifications_by_status(notifications, "failed"))


def channel_delivery_rate(notifications: list[Notification], templates: list[Template], channel: str) -> int:
    channel_template_ids = [template_id(t) for t in templates_for_channel(templates, channel)]
    channel_notifs = [n for n in notifications if any(notification_template_id(n) == tid for tid in channel_template_ids)]
    return delivery_rate_pct(channel_notifs)


def avg_send_time(notifications: list[Notification]) -> int:
    sent = notifications_by_status(notifications, "sent")
    cnt = len(sent)
    if cnt == 0:
        return 0
    return functools.reduce(lambda acc, n: acc + (notification_sent_at(n) - notification_created_at(n)), sent, 0) // cnt


def order_notification(id: int, template: Template, order: Order, customer: Customer, created_at: int) -> Notification:
    return Notification(id, template_id(template), customer.id, order.id, "order", "pending", created_at, 0)


def shipment_notification(id: int, template: Template, shipment: Shipment, customer: Customer, created_at: int) -> Notification:
    return Notification(id, template_id(template), customer.id, shipment.id, "shipment", "pending", created_at, 0)


def invoice_notification(id: int, template: Template, invoice: Invoice, customer: Customer, created_at: int) -> Notification:
    return Notification(id, template_id(template), customer.id, invoice.id, "invoice", "pending", created_at, 0)


def should_notify(prefs: list[Preference], customer: Customer, template: Template) -> bool:
    return channel_enabled(prefs, customer.id, template_channel(template))


def valid_template(t: Template) -> bool:
    return (
        template_id(t) > 0
        and template_name(t) != ""
        and template_channel(t) != ""
        and template_subject(t) != ""
        and template_body_pattern(t) != ""
    )


def valid_notification(n: Notification) -> bool:
    return (
        notification_id(n) > 0
        and notification_template_id(n) > 0
        and notification_customer_id(n) > 0
        and notification_reference_id(n) > 0
        and notification_reference_type(n) != ""
    )


def sort_notifications_by_date(notifications: list[Notification]) -> list[Notification]:
    return sorted(notifications, key=notification_created_at)


def sort_notifications_by_sent(notifications: list[Notification]) -> list[Notification]:
    return sorted(notifications, key=notification_sent_at)


def notification_status_counts(notifications: list[Notification]) -> dict[str, int]:
    pending_count = len(pending_notifications(notifications))
    sent_count = len(sent_notifications(notifications))
    failed_count = len(notifications_by_status(notifications, "failed"))
    return {"pending": pending_count, "sent": sent_count, "failed": failed_count}


def notifications_by_reference_type(notifications: list[Notification], ref_type: str) -> list[Notification]:
    return [n for n in notifications if notification_reference_type(n) == ref_type]


def customer_notification_count(notifications: list[Notification], customer_id: int) -> int:
    return len(notifications_for_customer(notifications, customer_id))


def customer_sent_count(notifications: list[Notification], customer_id: int) -> int:
    return len([n for n in notifications if notification_customer_id(n) == customer_id and notification_status(n) == "sent"])


def template_notification_count(notifications: list[Notification], template_id: int) -> int:
    return len([n for n in notifications if notification_template_id(n) == template_id])


def template_sent_count(notifications: list[Notification], template_id: int) -> int:
    return len([n for n in notifications if notification_template_id(n) == template_id and notification_status(n) == "sent"])


def template_delivery_rate(notifications: list[Notification], template_id: int) -> int:
    tmpl_notifs = [n for n in notifications if notification_template_id(n) == template_id]
    return delivery_rate_pct(tmpl_notifs)


def send_all_pending(notifications: list[Notification], sent_at: int) -> list[Notification]:
    return [send_notification(n, sent_at) if notification_status(n) == "pending" else n for n in notifications]


def retry_all_failed(notifications: list[Notification]) -> list[Notification]:
    return [retry_notification(n) if notification_status(n) == "failed" else n for n in notifications]


def notifications_in_period(notifications: list[Notification], start: int, end: int) -> list[Notification]:
    return [n for n in notifications if notification_created_at(n) >= start and notification_created_at(n) <= end]


def notification_count_in_period(notifications: list[Notification], start: int, end: int) -> int:
    return len(notifications_in_period(notifications, start, end))


def sent_in_period(notifications: list[Notification], start: int, end: int) -> list[Notification]:
    return [n for n in notifications if notification_status(n) == "sent" and notification_sent_at(n) >= start and notification_sent_at(n) <= end]


def channel_opt_in_count(prefs: list[Preference], channel: str) -> int:
    return len([p for p in prefs if preference_channel(p) == channel and preference_enabled(p)])


def channel_opt_out_count(prefs: list[Preference], channel: str) -> int:
    return len([p for p in prefs if preference_channel(p) == channel and not preference_enabled(p)])


def unique_channels(prefs: list[Preference]) -> list[str]:
    seen: set[str] = set()
    result = []
    for p in prefs:
        ch = preference_channel(p)
        if ch not in seen:
            seen.add(ch)
            result.append(ch)
    return result


def preference_summary(prefs: list[Preference]) -> dict[str, int]:
    channels = unique_channels(prefs)
    return functools.reduce(lambda acc, ch: {**acc, ch: channel_opt_in_count(prefs, ch)}, channels, {})


def notification_summary(n: Notification) -> str:
    return (
        "Notification #" + str(notification_id(n))
        + " | Template: " + str(notification_template_id(n))
        + " | Customer: " + str(notification_customer_id(n))
        + " | " + notification_reference_type(n)
        + " #" + str(notification_reference_id(n))
        + " | " + notification_status(n)
    )


def template_summary(t: Template) -> str:
    return (
        "Template #" + str(template_id(t))
        + " | " + template_name(t)
        + " | Channel: " + template_channel(t)
        + " | Subject: " + template_subject(t)
    )
