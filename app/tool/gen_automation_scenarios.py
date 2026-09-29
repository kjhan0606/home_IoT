"""Regenerates app/test/fixtures/automation_scenarios.json (read by hub pytest AND flutter test)."""
import json
def light(i, on, reachable=True, room="침실"):
    return {"id": i, "name": i, "kind": "light", "reachable": reachable, "controllable": True, "meta": {"room": room},
            "capabilities": {"power": {"key": "power", "actions": ["turnOn", "turnOff", "toggle"], "state": {"switch": "on" if on else "off"}}}}
def curtain(i, status="open", pos=100, room="침실", reachable=True):
    return {"id": i, "name": i, "kind": "curtain", "reachable": reachable, "controllable": True, "meta": {"room": room},
            "capabilities": {"curtain": {"key": "curtain", "actions": ["open", "close", "stop", "setPosition"], "state": {"position": pos, "status": status}}}}
def lock(i, locked):
    return {"id": i, "name": i, "kind": "lock", "reachable": True, "controllable": True, "meta": {},
            "capabilities": {"lock": {"key": "lock", "actions": ["lock", "unlock"], "state": {"locked": locked}}}}
def snap(*ds): return {d["id"]: d for d in ds}

close_c = {"selector": {"capability": "curtain"}, "capability": "curtain", "action": "close", "params": {}}
open_c = {"selector": {"capability": "curtain"}, "capability": "curtain", "action": "open", "params": {}}
bedtime = {"id": "bed", "name": "취침 시 커튼 닫기", "enabled": True, "trigger": {"type": "allLightsOff"},
           "conditions": [{"type": "timeWindow", "start": "22:00", "end": "02:00"}], "actions": [close_c]}
wake = {"id": "wake", "name": "기상 시 커튼 열기", "enabled": True, "trigger": {"type": "time", "at": "07:00", "days": []},
        "conditions": [], "actions": [open_c]}
weekday_wake = {**wake, "id": "wk", "trigger": {"type": "time", "at": "07:00", "days": [1, 2, 3, 4, 5]}}
leave = {"id": "leave", "name": "외출", "enabled": True, "trigger": {"type": "event", "name": "leaving"}, "conditions": [],
         "actions": [{"selector": {"kind": "light"}, "capability": "power", "action": "turnOff", "params": {}},
                     {"selector": {}, "capability": "lock", "action": "lock", "params": {}}]}
door = {"id": "door", "name": "문 열리면 조명", "enabled": True,
        "trigger": {"type": "deviceState", "capability": "lock", "field": "locked", "equals": False, "match": "any", "selector": {}},
        "conditions": [], "actions": [{"selector": {"kind": "light"}, "capability": "power", "action": "turnOn", "params": {}}]}

S = []
def sc(name, rules, prev, cur, now, expect, events=(), last=None):
    S.append({"name": name, "rules": rules, "prev": prev, "cur": cur, "now": now, "events": list(events),
              "lastFired": last or {}, "expect": expect})
def fire(rule, reason, steps, key=None): return {"ruleId": rule, "reason": reason, "key": key, "steps": steps}
def step(dev, action, skip=None): return {"deviceId": dev, "action": action, "skip": skip}

on_state = snap(light("l1", True), light("l2", False), curtain("c1"), curtain("c2", "closed", 0, "거실"))
off_state = snap(light("l1", False), light("l2", False), curtain("c1"), curtain("c2", "closed", 0, "거실"))
sc("bedtime: last light goes off inside the window -> close curtains (skip the already-closed one)",
   [bedtime], on_state, off_state, "2026-09-29T23:10:00",
   [fire("bed", "모든 조명이 꺼짐", [step("c1", "close"), step("c2", "close", "already-closed")])])
sc("bedtime: lights off at 12:00 (outside window) -> nothing", [bedtime], on_state, off_state, "2026-09-29T12:00:00", [])
sc("bedtime: window crosses midnight (01:30 is inside)", [bedtime], on_state, off_state, "2026-09-30T01:30:00",
   [fire("bed", "모든 조명이 꺼짐", [step("c1", "close"), step("c2", "close", "already-closed")])])
sc("bedtime: window end is exclusive (02:00 is outside)", [bedtime], on_state, off_state, "2026-09-30T02:00:00", [])
sc("bedtime: one light still on -> nothing", [bedtime], snap(light("l1", True), light("l2", True), curtain("c1")),
   snap(light("l1", False), light("l2", True), curtain("c1")), "2026-09-29T23:10:00", [])
sc("bedtime: no previous snapshot (first look) -> nothing", [bedtime], None, off_state, "2026-09-29T23:10:00", [])
sc("bedtime: lights already off before (no transition) -> nothing", [bedtime], off_state, off_state, "2026-09-29T23:10:00", [])
sc("bedtime: an offline bulb that stays 'on' does not block, and going offline is not 'off'",
   [bedtime], snap(light("l1", True), light("l2", True, reachable=False), curtain("c1")),
   snap(light("l1", False), light("l2", True, reachable=False), curtain("c1")), "2026-09-29T22:05:00",
   [fire("bed", "모든 조명이 꺼짐", [step("c1", "close")])])
sc("bedtime: home without lights -> never fires", [bedtime], snap(curtain("c1")), snap(curtain("c1")), "2026-09-29T23:00:00", [])
sc("bedtime: disabled rule does not fire", [{**bedtime, "enabled": False}], on_state, off_state, "2026-09-29T23:10:00", [])
sc("bedtime: no curtains -> fires with no steps (logged as no-targets)", [bedtime],
   snap(light("l1", True)), snap(light("l1", False)), "2026-09-29T23:10:00", [fire("bed", "모든 조명이 꺼짐", [])])
sc("bedtime: unreachable curtain is not commanded", [bedtime], on_state,
   snap(light("l1", False), light("l2", False), curtain("c1", reachable=False)), "2026-09-29T23:10:00",
   [fire("bed", "모든 조명이 꺼짐", [])])

both = snap(curtain("c1", "closed", 0))
sc("wake: 07:00 exactly", [wake], both, both, "2026-09-29T07:00:00", [fire("wake", "시간 07:00", [step("c1", "open")], "2026-09-29@07:00")])
sc("wake: tick 9 minutes late still fires", [wake], both, both, "2026-09-29T07:09:00", [fire("wake", "시간 07:00", [step("c1", "open")], "2026-09-29@07:00")])
sc("wake: 10 minutes late is too late", [wake], both, both, "2026-09-29T07:10:00", [])
sc("wake: one minute early -> nothing", [wake], both, both, "2026-09-29T06:59:00", [])
sc("wake: already fired today (same key) -> nothing", [wake], both, both, "2026-09-29T07:03:00", [], last={"wake": "2026-09-29@07:00"})
sc("wake: fired yesterday -> fires again", [wake], both, both, "2026-09-29T07:00:00",
   [fire("wake", "시간 07:00", [step("c1", "open")], "2026-09-29@07:00")], last={"wake": "2026-09-28@07:00"})
sc("wake: weekday-only rule fires on Tuesday", [weekday_wake], both, both, "2026-09-29T07:00:00",
   [fire("wk", "시간 07:00", [step("c1", "open")], "2026-09-29@07:00")])
sc("wake: weekday-only rule skips Saturday", [weekday_wake], both, both, "2026-10-03T07:00:00", [])
sc("wake: time triggers work on the first look too (prev = None)", [wake], None, both, "2026-09-29T07:01:00",
   [fire("wake", "시간 07:00", [step("c1", "open")], "2026-09-29@07:00")])
sc("wake: curtain already open -> skipped step", [wake], snap(curtain("c1")), snap(curtain("c1")), "2026-09-29T07:00:00",
   [fire("wake", "시간 07:00", [step("c1", "open", "already-open")], "2026-09-29@07:00")])

st = snap(light("l1", True), light("l2", True), lock("d1", False), lock("d2", True))
sc("event: 'leaving' turns lights off and locks (skips the already-locked)", [leave], st, st, "2026-09-29T09:00:00",
   [fire("leave", "이벤트 leaving", [step("l1", "turnOff"), step("l2", "turnOff"), step("d1", "lock"), step("d2", "lock", "already-locked")])],
   events=["leaving"])
sc("event: other event name -> nothing", [leave], st, st, "2026-09-29T09:00:00", [], events=["arriving"])
sc("event: no event -> nothing", [leave], st, st, "2026-09-29T09:00:00", [])

sc("deviceState: door unlocks -> lights on (only changed lights get commands)", [door],
   snap(light("l1", False), light("l2", True), lock("d1", True)), snap(light("l1", False), light("l2", True), lock("d1", False)),
   "2026-09-29T18:00:00", [fire("door", "lock.locked = false", [step("l1", "turnOn"), step("l2", "turnOn", "already-on")])])
sc("deviceState: stays unlocked (no transition) -> nothing", [door],
   snap(light("l1", False), lock("d1", False)), snap(light("l1", False), lock("d1", False)), "2026-09-29T18:00:00", [])
sc("conditions: days condition blocks on Saturday", [{**bedtime, "id": "b2", "conditions": [{"type": "days", "days": [1, 2, 3, 4, 5]}]}],
   on_state, off_state, "2026-10-03T23:00:00", [])
sc("conditions: anyLightOn / allLightsOff / deviceState",
   [{**leave, "id": "cond", "conditions": [{"type": "anyLightOn"}, {"type": "deviceState", "capability": "lock", "field": "locked", "equals": False, "match": "any", "selector": {}}],
     "actions": [{"selector": {}, "capability": "lock", "action": "lock", "params": {}}]}],
   st, st, "2026-09-29T09:00:00", [fire("cond", "이벤트 leaving", [step("d1", "lock"), step("d2", "lock", "already-locked")])], events=["leaving"])
sc("setPosition action with params; curtain already there is skipped",
   [{"id": "half", "name": "반만", "enabled": True, "trigger": {"type": "event", "name": "half"}, "conditions": [],
     "actions": [{"selector": {"kind": "curtain"}, "capability": "curtain", "action": "setPosition", "params": {"position": 50}}]}],
   snap(curtain("c1", "partial", 50), curtain("c2")), snap(curtain("c1", "partial", 50), curtain("c2")), "2026-09-29T09:00:00",
   [fire("half", "이벤트 half", [step("c1", "setPosition", "already-there"), step("c2", "setPosition")])], events=["half"])
sc("selector by room", [{**bedtime, "actions": [{"selector": {"capability": "curtain", "room": "거실"}, "capability": "curtain", "action": "close", "params": {}}]}],
   on_state, snap(light("l1", False), light("l2", False), curtain("c1"), curtain("c2", "open", 100, "거실")), "2026-09-29T23:10:00",
   [fire("bed", "모든 조명이 꺼짐", [step("c2", "close")])])
sc("two rules fire from the same change (order = rule order)", [bedtime, {**bedtime, "id": "bed2", "actions": [{"selector": {}, "capability": "lock", "action": "lock", "params": {}}]}],
   snap(light("l1", True), curtain("c1"), lock("d1", False)), snap(light("l1", False), curtain("c1"), lock("d1", False)), "2026-09-29T23:10:00",
   [fire("bed", "모든 조명이 꺼짐", [step("c1", "close")]), fire("bed2", "모든 조명이 꺼짐", [step("d1", "lock")])])

from pathlib import Path
out = Path(__file__).resolve().parents[1] / "test/fixtures/automation_scenarios.json"
json.dump({"scenarios": S}, open(out, "w"), ensure_ascii=False, indent=1)
print(len(S), "scenarios")
