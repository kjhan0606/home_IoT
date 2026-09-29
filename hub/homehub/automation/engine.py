"""Pure rule evaluation (no I/O, no clock, no threads) -- easy to test.

``evaluate`` compares the previous and current device snapshots and returns the
rules that fire, each with the concrete steps (device + canonical command) to run.
The Flutter app has a line-for-line Dart port (app/lib/automation/engine.dart);
both run the shared scenarios in app/test/fixtures/automation_scenarios.json.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Iterable, Mapping

from ..models import Device
from .rules import parse_hhmm

#: A time trigger still fires up to this many minutes late (tick jitter, app opened a bit late).
TIME_GRACE_MINUTES = 10


@dataclass
class Step:
    device_id: str
    device_name: str
    capability: str
    action: str
    params: dict[str, Any]
    skip: str | None = None        # e.g. "already-closed": nothing needs to be sent

    def to_dict(self) -> dict[str, Any]:
        return {"deviceId": self.device_id, "deviceName": self.device_name, "capability": self.capability,
                "action": self.action, "params": self.params, "skip": self.skip}


@dataclass
class Fire:
    rule_id: str
    rule_name: str
    reason: str
    key: str | None                # last-fired key for time triggers (de-duplication)
    steps: list[Step] = field(default_factory=list)


# ---------------------------------------------------------------- helpers --
def is_light(d: Device) -> bool:
    return d.kind == "light" and "power" in d.capabilities


def light_is_on(d: Device) -> bool:
    return d.capabilities["power"].state.get("switch") == "on"


def lights(devices: Iterable[Device]) -> list[Device]:
    """Controllable, reachable lights (an offline bulb must not block "all lights off")."""
    return [d for d in devices if is_light(d) and d.reachable]


def all_lights_off(devices: Iterable[Device]) -> bool | None:
    """True/False, or None when the home has no (reachable) light at all."""
    ls = lights(devices)
    return None if not ls else not any(light_is_on(d) for d in ls)


def in_window(now_min: int, start: int, end: int) -> bool:
    """[start, end) on a 24 h clock; a window with start > end crosses midnight."""
    if start == end:
        return True
    return start <= now_min < end if start < end else (now_min >= start or now_min < end)


def matches(d: Device, sel: Mapping[str, str]) -> bool:
    if sel.get("deviceId") and d.id != sel["deviceId"]:
        return False
    if sel.get("kind") and d.kind != sel["kind"]:
        return False
    if sel.get("room") and d.meta.get("room") != sel["room"]:
        return False
    if sel.get("capability") and sel["capability"] not in d.capabilities:
        return False
    return True


def _state_true(devices: Iterable[Device], chk: Mapping[str, Any]) -> bool:
    hits = [d for d in devices if matches(d, chk.get("selector") or {}) and chk["capability"] in d.capabilities
            and d.reachable]
    if not hits:
        return False
    vals = [d.capabilities[chk["capability"]].state.get(chk["field"]) == chk["equals"] for d in hits]
    return all(vals) if chk.get("match") == "all" else any(vals)


def _condition_ok(c: Mapping[str, Any], devices: list[Device], now: datetime) -> bool:
    t = c["type"]
    if t == "timeWindow":
        return in_window(now.hour * 60 + now.minute, parse_hhmm(c["start"]), parse_hhmm(c["end"]))
    if t == "days":
        return now.isoweekday() in c["days"]
    if t == "allLightsOff":
        return all_lights_off(devices) is True
    if t == "anyLightOn":
        return all_lights_off(devices) is False
    if t == "deviceState":
        return _state_true(devices, c)
    return False


def _already(d: Device, capability: str, action: str, params: Mapping[str, Any]) -> str | None:
    """Reason to skip a command that would change nothing (saves cloud calls)."""
    st = d.capabilities[capability].state
    if capability == "power" and action in ("turnOn", "turnOff"):
        if st.get("switch") == ("on" if action == "turnOn" else "off"):
            return "already-on" if action == "turnOn" else "already-off"
    if capability == "curtain":
        pos, status = st.get("position"), st.get("status")
        if action == "close" and (status == "closed" or pos == 0):
            return "already-closed"
        if action == "open" and (status == "open" or pos == 100):
            return "already-open"
        if action == "setPosition" and pos is not None and pos == params.get("position"):
            return "already-there"
    if capability == "lock" and action in ("lock", "unlock"):
        if st.get("locked") is (action == "lock"):
            return "already-locked" if action == "lock" else "already-unlocked"
    return None


def _steps(rule: Mapping[str, Any], devices: list[Device]) -> list[Step]:
    steps: list[Step] = []
    for a in rule["actions"]:
        for d in sorted(devices, key=lambda x: x.id):
            if not (d.controllable and d.reachable and matches(d, a.get("selector") or {})):
                continue
            inst = d.capabilities.get(a["capability"])
            if inst is None or a["action"] not in inst.actions:
                continue
            steps.append(Step(d.id, d.name, a["capability"], a["action"], dict(a.get("params") or {}),
                              _already(d, a["capability"], a["action"], a.get("params") or {})))
    return steps


def time_key(rule: Mapping[str, Any], now: datetime) -> str | None:
    """Key like '2026-09-29@07:00' while a time trigger is due (within the grace window)."""
    t = rule["trigger"]
    if t["type"] != "time":
        return None
    days = t.get("days") or []
    if days and now.isoweekday() not in days:
        return None
    late = now.hour * 60 + now.minute - parse_hhmm(t["at"])
    return f"{now.date().isoformat()}@{t['at']}" if 0 <= late < TIME_GRACE_MINUTES else None


# ------------------------------------------------------------------ main ---
def evaluate(
    rules: list[Mapping[str, Any]],
    prev: Mapping[str, Device] | None,
    cur: Mapping[str, Device],
    now: datetime,
    events: Iterable[str] = (),
    last_fired: Mapping[str, str] | None = None,
) -> list[Fire]:
    """Rules that fire between the ``prev`` and ``cur`` snapshots (``prev`` None = first look:
    state-change triggers cannot fire because there is no earlier state to compare with)."""
    last_fired = last_fired or {}
    events = set(events)
    cur_list = list(cur.values())
    prev_list = list(prev.values()) if prev is not None else None
    out: list[Fire] = []
    for rule in rules:
        if not rule.get("enabled", True):
            continue
        t = rule["trigger"]
        reason, key = None, None
        if t["type"] == "time":
            key = time_key(rule, now)
            if key and last_fired.get(rule["id"]) != key:
                reason = f"시간 {t['at']}"
            else:
                key = None
        elif t["type"] == "event":
            if t["name"] in events:
                reason = f"이벤트 {t['name']}"
        elif t["type"] == "allLightsOff":
            if prev_list is not None and all_lights_off(prev_list) is False and all_lights_off(cur_list) is True:
                reason = "모든 조명이 꺼짐"
        elif t["type"] == "deviceState":
            if prev_list is not None and not _state_true(prev_list, t) and _state_true(cur_list, t):
                eq = str(t["equals"]).lower() if isinstance(t["equals"], bool) else t["equals"]
                reason = f"{t['capability']}.{t['field']} = {eq}"
        if reason is None:
            continue
        if not all(_condition_ok(c, cur_list, now) for c in rule.get("conditions", [])):
            continue
        out.append(Fire(rule["id"], rule["name"], reason, key, _steps(rule, cur_list)))
    return out
