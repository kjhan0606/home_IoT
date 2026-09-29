"""Regenerates app/test/fixtures/away_scenarios.json (read by hub pytest AND flutter test).

Expected values come from the Python implementation (hub/homehub/automation/away.py); the Dart port must
reproduce them exactly -- including the seeded random evenings. Run from anywhere:
    hub/.venv/bin/python app/tool/gen_away_scenarios.py
"""
import json
import sys
from datetime import date, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "hub"))
from homehub.automation import away  # noqa: E402
from homehub.models import Device  # noqa: E402


def light(i, room, on=False, reachable=True, kind="light"):
    return {"id": i, "name": i, "kind": kind, "reachable": reachable, "controllable": True, "meta": {"room": room},
            "capabilities": {"power": {"key": "power", "actions": ["turnOn", "turnOff", "toggle"],
                                       "state": {"switch": "on" if on else "off"}}}}


def curtain(i, room="침실"):
    return {"id": i, "name": i, "kind": "curtain", "reachable": True, "controllable": True, "meta": {"room": room},
            "capabilities": {"curtain": {"key": "curtain", "actions": ["open", "close", "stop", "setPosition"],
                                         "state": {"position": 100, "status": "open"}}}}


def heater(i):          # must never be touched, even though it has a power capability
    return {"id": i, "name": i, "kind": "heater", "reachable": True, "controllable": True, "meta": {"room": "거실"},
            "capabilities": {"power": {"key": "power", "actions": ["turnOn", "turnOff"], "state": {"switch": "off"}}}}


HOME = [light("l-living", "거실"), light("l-kitchen", "주방"), light("l-bath", "욕실"), light("l-bed", "침실"),
        light("l-door", "현관"), light("l-off", "거실", reachable=False), heater("heater"), curtain("c-bed"),
        curtain("c-living", "거실")]

BASE = {"enabled": True, "startDate": "2026-10-01", "endDate": "2026-10-05", "mode": "random", "seed": 42,
        "windowStart": "18:30", "windowEnd": "23:00", "endOnArriving": True,
        "lights": {"rooms": ["거실", "주방", "욕실", "침실", "현관"], "devices": []},
        "curtains": {"enabled": False, "openAt": "08:00", "closeAt": "18:30", "rooms": [], "devices": []}}
WITH_CURTAINS = {**BASE, "curtains": {**BASE["curtains"], "enabled": True}}
FIXED = {**BASE, "mode": "fixed", "windowStart": "17:45", "windowEnd": "23:00",
         "lights": {"rooms": [], "devices": ["l-living", "heater", "c-bed"]}}
OVERNIGHT = {**BASE, "mode": "fixed", "windowStart": "22:00", "windowEnd": "02:00",
             "lights": {"rooms": ["거실"], "devices": []}}

S = []


def sc(name, plan, now):
    plan = away.normalize_plan(plan)
    devs = [Device.from_dict(d) for d in HOME]
    ws = [{"deviceId": w.device_id, "action": w.action} for w in away.wants(plan, datetime.fromisoformat(now), devs)]
    st = away.status(plan, datetime.fromisoformat(now))
    S.append({"name": name, "plan": plan, "devices": HOME, "now": now, "status": st, "wants": ws})


sc("random: before the first evening nothing is touched", BASE, "2026-10-01T12:00:00")
sc("random: first evening, before the window opens nothing is touched", BASE, "2026-10-01T18:00:00")
sc("random: first evening, inside the window", BASE, "2026-10-01T20:00:00")
sc("random: day 2, 21:00", BASE, "2026-10-02T21:00:00")
sc("random: day 3, 22:30", BASE, "2026-10-03T22:30:00")
sc("random: day 3 after the window everything is off", BASE, "2026-10-03T23:30:00")
sc("random: next morning lights stay off", BASE, "2026-10-04T09:00:00")
sc("random: last evening 20:15", BASE, "2026-10-05T20:15:00")
sc("random: after the last window the plan is finished (nothing to do)", BASE, "2026-10-05T23:05:00")
sc("random + curtains: morning opens", WITH_CURTAINS, "2026-10-02T09:00:00")
sc("random + curtains: dusk closes", WITH_CURTAINS, "2026-10-02T19:30:00")
sc("random + curtains: midday still open", WITH_CURTAINS, "2026-10-03T13:00:00")
sc("random + curtains: night closed", WITH_CURTAINS, "2026-10-03T23:50:00")
sc("fixed: lights stay on for the whole window", FIXED, "2026-10-02T20:00:00")
sc("fixed: only lights and curtains are ever chosen (a heater listed by id is ignored)", FIXED, "2026-10-02T23:00:00")
sc("fixed: window that crosses midnight, 23:30 on day 2 (on)", OVERNIGHT, "2026-10-02T23:30:00")
sc("fixed: window that crosses midnight, 01:30 the next day (still on)", OVERNIGHT, "2026-10-03T01:30:00")
sc("fixed: window that crosses midnight, 02:00 (off)", OVERNIGHT, "2026-10-03T02:00:00")
sc("fixed: the last night's window ends after midnight, still active at 01:00 on the day after endDate",
   OVERNIGHT, "2026-10-06T01:00:00")
sc("disabled plan does nothing", {**BASE, "enabled": False}, "2026-10-02T20:00:00")

# raw evening schedules (the "realistic patterns" contract)
SCHEDULES = []
for seed in (7, 42):
    plan = away.normalize_plan({**BASE, "seed": seed})
    for day in (date(2026, 10, 2), date(2026, 10, 3)):
        SCHEDULES.append({"seed": seed, "date": day.isoformat(), "plan": plan, "lights": {
            d["id"]: [[a.isoformat(timespec="minutes"), b.isoformat(timespec="minutes")]
                      for a, b in away.light_intervals(plan, day, away.Target(d["id"], d["id"], d["meta"]["room"]))]
            for d in HOME if d["kind"] == "light"}})

out = ROOT / "app/test/fixtures/away_scenarios.json"
out.write_text(json.dumps({"scenarios": S, "schedules": SCHEDULES}, ensure_ascii=False, indent=1))
print(len(S), "scenarios,", len(SCHEDULES), "schedules")
