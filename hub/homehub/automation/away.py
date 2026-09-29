"""휴가/장기 외출 모드 ("away mode" / presence simulation): lights and curtains only.

While the family is away the hub makes the home look lived in:

* ``fixed``  the chosen lights stay on from ``windowStart`` to ``windowEnd`` every evening;
* ``random`` every chosen light gets its own believable pattern inside that window (living room: a long
  evening; kitchen: one or two short visits early on; bathroom: brief visits; bedroom: late, then off;
  entrance: a while at dusk). Times are drawn from a **seeded** generator, so the schedule of a given
  day is reproducible (tests) but different from day to day.

Curtains (optional) open in the morning and close at dusk, ±15 min in random mode.

Everything here is **pure** (no I/O, no clock): ``wants(plan, now, devices)`` returns what should be
commanded *right now*; the service compares it with the real state and sends only the difference, so a
missed tick or a restart never leaves the schedule wrong. The Flutter app has a line-for-line Dart port
(``app/lib/automation/away.dart``); both run ``app/test/fixtures/away_scenarios.json``.

SAFETY: only devices with ``kind == "light"`` + ``power`` and devices with the ``curtain`` capability are
ever selected, and only ``turnOn``/``turnOff``/``open``/``close`` are ever produced. Heating, cooling,
appliances, locks... can never be touched by this module, whatever the plan says.
"""
from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import Any, Iterable, Mapping

from ..models import Device
from .rules import parse_hhmm

MAX_DAYS = 60
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_M = 2147483647            # Park-Miller "minstd": integer-only, identical in Python and Dart (also on web)
_A = 48271

ROOM_KEYWORDS = {
    "living": ("거실", "living"),
    "bath": ("욕실", "화장실", "bath", "toilet", "wc"),
    "kitchen": ("주방", "부엌", "kitchen", "다이닝", "dining"),
    "bedroom": ("침실", "안방", "bed", "방"),
    "entrance": ("현관", "entr", "porch", "front"),
}


# --------------------------------------------------------------- plan ------
def _iso_date(v: Any, what: str) -> date:
    if not isinstance(v, str) or not _DATE.match(v):
        raise ValueError(f"{what} must be 'YYYY-MM-DD'")
    try:
        return date.fromisoformat(v)
    except ValueError as e:
        raise ValueError(f"{what}: {e}") from e


def _strs(v: Any, what: str) -> list[str]:
    if v in (None, []):
        return []
    if not isinstance(v, list) or any(not isinstance(x, str) or not x for x in v) or len(v) > 100:
        raise ValueError(f"{what} must be a list of strings")
    return list(dict.fromkeys(v))


def window_minutes(plan: Mapping[str, Any]) -> int:
    """Length of the nightly window in minutes (it may cross midnight)."""
    a, b = parse_hhmm(plan["windowStart"]), parse_hhmm(plan["windowEnd"])
    return (b - a) % 1440


def normalize_plan(d: Any) -> dict[str, Any]:
    """Validate an away plan and return the normalized form. Raises ValueError."""
    if not isinstance(d, dict):
        raise ValueError("plan must be an object")
    start, end = _iso_date(d.get("startDate"), "startDate"), _iso_date(d.get("endDate"), "endDate")
    if end < start:
        raise ValueError("endDate must not be before startDate")
    if (end - start).days + 1 > MAX_DAYS:
        raise ValueError(f"at most {MAX_DAYS} days")
    mode = d.get("mode", "random")
    if mode not in ("fixed", "random"):
        raise ValueError("mode must be 'fixed' or 'random'")
    ws, we = d.get("windowStart", "18:30"), d.get("windowEnd", "23:00")
    parse_hhmm(ws, "windowStart"), parse_hhmm(we, "windowEnd")
    lights = d.get("lights") or {}
    if not isinstance(lights, dict):
        raise ValueError("lights must be an object {rooms, devices}")
    rooms, devs = _strs(lights.get("rooms"), "lights.rooms"), _strs(lights.get("devices"), "lights.devices")
    if not rooms and not devs:
        raise ValueError("choose at least one light or room")
    cur = d.get("curtains") or {}
    if not isinstance(cur, dict):
        raise ValueError("curtains must be an object")
    curtains = {"enabled": bool(cur.get("enabled", False)), "openAt": cur.get("openAt", "08:00"),
                "closeAt": cur.get("closeAt", ws), "rooms": _strs(cur.get("rooms"), "curtains.rooms"),
                "devices": _strs(cur.get("devices"), "curtains.devices")}
    parse_hhmm(curtains["openAt"], "curtains.openAt"), parse_hhmm(curtains["closeAt"], "curtains.closeAt")
    seed = d.get("seed")
    if seed is None:
        seed = uuid.uuid4().int % 1_000_000
    if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed < 2**31 - 1:
        raise ValueError("seed must be a non-negative integer")
    plan = {"enabled": bool(d.get("enabled", True)), "startDate": start.isoformat(), "endDate": end.isoformat(),
            "mode": mode, "seed": seed, "windowStart": ws, "windowEnd": we,
            "lights": {"rooms": rooms, "devices": devs}, "curtains": curtains,
            "endOnArriving": bool(d.get("endOnArriving", True))}
    if not 60 <= window_minutes(plan) <= 960:
        raise ValueError("the evening window must be between 1 and 16 hours")
    return plan


# ------------------------------------------------------- deterministic rng --
class Rng:
    """Tiny integer-only generator (Park-Miller). Same numbers in Python and Dart."""

    def __init__(self, seed: int) -> None:
        self.state = seed % (_M - 1) + 1
        for _ in range(3):
            self.next()

    def next(self) -> int:
        self.state = self.state * _A % _M
        return self.state

    def between(self, lo: int, hi: int) -> int:
        """Integer in [lo, hi]."""
        if hi <= lo:
            return lo
        return lo + (self.next() - 1) % (hi - lo + 1)


def _hash(s: str) -> int:
    h = 0
    for ch in s:
        h = (h * 31 + ord(ch)) % _M
    return h


def epoch_day(d: date) -> int:
    return (d - date(1970, 1, 1)).days


def room_type(room: str | None) -> str:
    r = (room or "").lower()
    for kind in ("living", "bath", "kitchen", "entrance", "bedroom"):      # "방" (bedroom) is the loosest: last
        if any(k in r for k in ROOM_KEYWORDS[kind]):
            return kind
    return "other"


def _pattern(kind: str, length: int, rng: Rng) -> list[tuple[int, int]]:
    """On-intervals in minutes after windowStart, inside [0, length]."""
    iv: list[tuple[int, int]] = []
    if kind == "living":
        s = rng.between(0, min(60, length // 4))
        e = s + rng.between(max(60, length // 2), max(90, length * 3 // 4))
        iv = [(s, min(e, length))]
    elif kind == "kitchen":
        s = rng.between(0, max(0, length // 3))
        e = s + rng.between(15, 35)
        iv = [(s, e)]
        if rng.between(0, 1):
            s2 = e + rng.between(20, 60)
            iv.append((s2, s2 + rng.between(10, 20)))
    elif kind == "bath":
        for _ in range(rng.between(1, 3)):
            s = rng.between(length // 4, max(length // 4, length - 15))
            iv.append((s, s + rng.between(5, 15)))
    elif kind == "bedroom":
        s = rng.between(length * 2 // 3, length * 5 //6)
        iv = [(s, s + rng.between(20, 60))]
    elif kind == "entrance":
        s = rng.between(0, 20)
        iv = [(s, s + rng.between(30, 90))]
    else:
        s = rng.between(0, length // 2)
        iv = [(s, s + rng.between(30, 90))]
    # clip to the window, sort, merge overlaps, drop anything shorter than 3 minutes
    iv = sorted((max(0, a), min(length, b)) for a, b in iv)
    merged: list[tuple[int, int]] = []
    for a, b in iv:
        if b - a < 3:
            continue
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


@dataclass(frozen=True)
class Target:
    """What the schedule generator needs to know about a device."""
    id: str
    name: str
    room: str | None


def is_light(d: Device) -> bool:
    return d.kind == "light" and "power" in d.capabilities and "turnOn" in d.capabilities["power"].actions


def is_curtain(d: Device) -> bool:
    return "curtain" in d.capabilities


def _pick(devices: Iterable[Device], sel: Mapping[str, Any], eligible, default_all: bool) -> list[Device]:
    rooms, ids = set(sel.get("rooms") or []), set(sel.get("devices") or [])
    out = []
    for d in sorted(devices, key=lambda x: x.id):
        if not (d.controllable and eligible(d)):
            continue
        if d.id in ids or d.meta.get("room") in rooms or (default_all and not rooms and not ids):
            out.append(d)
    return out


def chosen_lights(plan: Mapping[str, Any], devices: Iterable[Device]) -> list[Device]:
    return _pick(devices, plan["lights"], is_light, False)


def chosen_curtains(plan: Mapping[str, Any], devices: Iterable[Device]) -> list[Device]:
    return _pick(devices, plan["curtains"], is_curtain, True) if plan["curtains"]["enabled"] else []


# ------------------------------------------------------------ schedule ------
def _at(day: date, minutes: int) -> datetime:
    return datetime.combine(day, time(0)) + timedelta(minutes=minutes)


def light_intervals(plan: Mapping[str, Any], day: date, t: Target) -> list[tuple[datetime, datetime]]:
    """When light ``t`` is on during the window that *starts* on ``day``."""
    length = window_minutes(plan)
    start = parse_hhmm(plan["windowStart"])
    if plan["mode"] == "fixed":
        rel = [(0, length)]
    else:
        rng = Rng(plan["seed"] * 1000003 + epoch_day(day) * 7919 + _hash(t.id))
        rel = _pattern(room_type(t.room), length, rng)
    return [(_at(day, start + a), _at(day, start + b)) for a, b in rel]


def _dates(plan: Mapping[str, Any]) -> tuple[date, date]:
    return date.fromisoformat(plan["startDate"]), date.fromisoformat(plan["endDate"])


def end_moment(plan: Mapping[str, Any]) -> datetime:
    """The plan is over once the last evening's window has ended."""
    _, last = _dates(plan)
    return _at(last, parse_hhmm(plan["windowStart"]) + window_minutes(plan))


def status(plan: Mapping[str, Any], now: datetime) -> dict[str, Any]:
    """``state``: scheduled | active | finished; ``day``/``days``: "3일째" of the away period."""
    now = now.replace(tzinfo=None)
    first, last = _dates(plan)
    days = (last - first).days + 1
    if now >= end_moment(plan):
        return {"state": "finished", "day": days, "days": days}
    if now.date() < first:
        return {"state": "scheduled", "day": 0, "days": days}
    return {"state": "active", "day": min(days, (now.date() - first).days + 1), "days": days}


@dataclass
class Want:
    device_id: str
    device_name: str
    capability: str
    action: str
    reason: str

    def to_dict(self) -> dict[str, Any]:
        return {"deviceId": self.device_id, "deviceName": self.device_name, "capability": self.capability,
                "action": self.action, "reason": self.reason}


def wants(plan: Mapping[str, Any], now: datetime, devices: Iterable[Device]) -> list[Want]:
    """The commands that make the home match the plan at ``now`` (empty when not active).

    Lights: inside the nightly window each light is on during its intervals and off otherwise; between
    windows they are off (on the first day nothing is touched before the first window starts, so
    nobody who is still at home gets their lights turned off).
    """
    now = now.replace(tzinfo=None)
    devices = list(devices)
    st = status(plan, now)
    if not plan.get("enabled", True) or st["state"] != "active":
        return []
    first, last = _dates(plan)
    today, tail = now.date(), f"휴가 모드 {st['day']}일째"
    out: list[Want] = []
    wstart = parse_hhmm(plan["windowStart"])
    for d in chosen_lights(plan, devices):
        if not d.reachable:
            continue
        t = Target(d.id, d.name, d.meta.get("room"))
        on = False
        for day in (today - timedelta(days=1), today):
            if first <= day <= last:
                on = on or any(a <= now < b for a, b in light_intervals(plan, day, t))
        before_first_window = today == first and now < _at(today, wstart)
        if not on and before_first_window:
            continue
        out.append(Want(d.id, d.name, "power", "turnOn" if on else "turnOff", tail))
    cur = plan["curtains"]
    if cur["enabled"]:
        open_m, close_m = parse_hhmm(cur["openAt"]), parse_hhmm(cur["closeAt"])
        for d in chosen_curtains(plan, devices):
            if not d.reachable:
                continue
            jitter = 0
            if plan["mode"] == "random":
                jitter = Rng(plan["seed"] * 999983 + epoch_day(today) * 104729 + _hash(d.id)).between(-15, 15)
            o, c = _at(today, open_m + jitter), _at(today, close_m + jitter)
            if o <= now < c:
                out.append(Want(d.id, d.name, "curtain", "open", tail))
            elif now >= c or today > first:          # dusk .. midnight, and the night/early morning after it
                out.append(Want(d.id, d.name, "curtain", "close", tail))
    return out


# ------------------------------------------------------------- summary ------
def describe(plan: Mapping[str, Any], now: datetime) -> dict[str, Any]:
    """Data for the app's summary card (and the plan screen)."""
    return {**status(plan, now), "mode": plan["mode"], "endDate": plan["endDate"], "startDate": plan["startDate"],
            "enabled": plan.get("enabled", True)}
