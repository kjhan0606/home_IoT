"""Rule schema + validation.

Rule JSON (shared 1:1 with the Flutter app, see app/lib/models/automation.dart)::

    {"id": "r1", "name": "취침 시 커튼 닫기", "enabled": true, "template": "bedtime-close-curtains",
     "trigger":    {"type": "allLightsOff"},
     "conditions": [{"type": "timeWindow", "start": "22:00", "end": "02:00"}],
     "actions":    [{"selector": {"capability": "curtain"}, "capability": "curtain",
                     "action": "close", "params": {}}]}

Triggers   time {at "HH:MM", days?}  |  allLightsOff  |  deviceState {selector, capability, field,
           equals, match any|all}    |  event {name}
Conditions timeWindow {start,end} (may cross midnight) | days {days} | allLightsOff | anyLightOn
           | deviceState (same fields as the trigger)
Selector   {deviceId?, kind?, room?, capability?}; an action's targets are all devices matching it
           that support the action. ``days`` are ISO weekdays, 1 = Monday .. 7 = Sunday.
"""
from __future__ import annotations

import re
import uuid
from typing import Any

from .. import capabilities as cap

TRIGGER_TYPES = ("time", "allLightsOff", "deviceState", "event")
CONDITION_TYPES = ("timeWindow", "days", "allLightsOff", "anyLightOn", "deviceState")
_HHMM = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")
_SELECTOR_KEYS = ("deviceId", "kind", "room", "capability")
MAX_ACTIONS = 20


def parse_hhmm(v: Any, what: str = "time") -> int:
    """'07:30' -> minutes after midnight."""
    if not isinstance(v, str) or not _HHMM.match(v):
        raise ValueError(f"{what} must be 'HH:MM' (24 h), got {v!r}")
    return int(v[:2]) * 60 + int(v[3:])


def _days(v: Any) -> list[int]:
    if v in (None, []):
        return []
    if not isinstance(v, list) or any(isinstance(d, bool) or not isinstance(d, int) or not 1 <= d <= 7 for d in v):
        raise ValueError("days must be a list of ISO weekdays 1..7 (1 = Monday)")
    return sorted(set(v))


def _selector(v: Any, what: str) -> dict[str, str]:
    if v in (None, {}):
        return {}
    if not isinstance(v, dict) or any(k not in _SELECTOR_KEYS for k in v):
        raise ValueError(f"{what}.selector may only contain {list(_SELECTOR_KEYS)}")
    out = {}
    for k, val in v.items():
        if not isinstance(val, str) or not val:
            raise ValueError(f"{what}.selector.{k} must be a non-empty string")
        out[k] = val
    return out


def _state_check(d: dict[str, Any], what: str) -> dict[str, Any]:
    capability, field = d.get("capability"), d.get("field")
    if capability not in cap.CANONICAL:
        raise ValueError(f"{what}.capability {capability!r} is not a canonical capability")
    if not isinstance(field, str) or not field:
        raise ValueError(f"{what}.field is required")
    if "equals" not in d:
        raise ValueError(f"{what}.equals is required")
    match = d.get("match", "any")
    if match not in ("any", "all"):
        raise ValueError(f"{what}.match must be 'any' or 'all'")
    return {"capability": capability, "field": field, "equals": d["equals"], "match": match,
            "selector": _selector(d.get("selector"), what)}


def _trigger(t: Any) -> dict[str, Any]:
    if not isinstance(t, dict) or t.get("type") not in TRIGGER_TYPES:
        raise ValueError(f"trigger.type must be one of {list(TRIGGER_TYPES)}")
    typ = t["type"]
    if typ == "time":
        parse_hhmm(t.get("at"), "trigger.at")
        return {"type": typ, "at": t["at"], "days": _days(t.get("days"))}
    if typ == "event":
        name = t.get("name")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_\-]{1,40}", name):
            raise ValueError("trigger.name must be 1..40 letters/digits/-/_")
        return {"type": typ, "name": name}
    if typ == "deviceState":
        return {"type": typ, **_state_check(t, "trigger")}
    return {"type": typ}


def _condition(c: Any, i: int) -> dict[str, Any]:
    what = f"conditions[{i}]"
    if not isinstance(c, dict) or c.get("type") not in CONDITION_TYPES:
        raise ValueError(f"{what}.type must be one of {list(CONDITION_TYPES)}")
    typ = c["type"]
    if typ == "timeWindow":
        parse_hhmm(c.get("start"), f"{what}.start")
        parse_hhmm(c.get("end"), f"{what}.end")
        return {"type": typ, "start": c["start"], "end": c["end"]}
    if typ == "days":
        d = _days(c.get("days"))
        if not d:
            raise ValueError(f"{what}.days must not be empty")
        return {"type": typ, "days": d}
    if typ == "deviceState":
        return {"type": typ, **_state_check(c, what)}
    return {"type": typ}


def _action(a: Any, i: int) -> dict[str, Any]:
    what = f"actions[{i}]"
    if not isinstance(a, dict):
        raise ValueError(f"{what} must be an object")
    cap.validate_action(str(a.get("capability")), str(a.get("action")))
    params = a.get("params") or {}
    if not isinstance(params, dict):
        raise ValueError(f"{what}.params must be an object")
    return {"selector": _selector(a.get("selector"), what), "capability": a["capability"],
            "action": a["action"], "params": params}


def normalize_rule(d: Any, rule_id: str | None = None) -> dict[str, Any]:
    """Validate a rule dict and return the normalized form. Raises ValueError."""
    if not isinstance(d, dict):
        raise ValueError("rule must be an object")
    name = d.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 100:
        raise ValueError("name is required (1..100 characters)")
    actions = d.get("actions")
    if not isinstance(actions, list) or not actions or len(actions) > MAX_ACTIONS:
        raise ValueError(f"actions must be a list of 1..{MAX_ACTIONS}")
    conds = d.get("conditions") or []
    if not isinstance(conds, list) or len(conds) > 10:
        raise ValueError("conditions must be a list (max 10)")
    return {
        "id": rule_id or d.get("id") or uuid.uuid4().hex[:12],
        "name": name.strip(),
        "enabled": bool(d.get("enabled", True)),
        "template": d.get("template") if isinstance(d.get("template"), str) else None,
        "trigger": _trigger(d.get("trigger")),
        "conditions": [_condition(c, i) for i, c in enumerate(conds)],
        "actions": [_action(a, i) for i, a in enumerate(actions)],
    }
