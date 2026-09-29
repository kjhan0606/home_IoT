"""Rules engine (pure), service (persistence, log, tick), HTTP API, and demo end-to-end."""
import json
from datetime import datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from homehub import server
from homehub.adapters import demo, registry
from homehub.automation import engine, rules as rules_mod
from homehub.automation.service import AutomationService
from homehub.models import Device
from homehub.manager import DeviceManager

SCENARIOS = json.loads((Path(__file__).resolve().parents[2] / "app/test/fixtures/automation_scenarios.json").read_text())["scenarios"]


def _snap(d):
    return None if d is None else {k: Device.from_dict(v) for k, v in d.items()}


@pytest.mark.parametrize("s", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_shared_scenarios(s):
    """The same scenarios run in the Dart engine (app/test/automation_test.dart)."""
    rs = [rules_mod.normalize_rule(r, r["id"]) for r in s["rules"]]
    fires = engine.evaluate(rs, _snap(s["prev"]), _snap(s["cur"]), datetime.fromisoformat(s["now"]), s["events"], s["lastFired"])
    got = [{"ruleId": f.rule_id, "reason": f.reason, "key": f.key,
            "steps": [{"deviceId": x.device_id, "action": x.action, "skip": x.skip} for x in f.steps]} for f in fires]
    assert got == s["expect"]


# ------------------------------------------------------------- validation --
def test_normalize_rejects_bad_rules():
    ok = {"name": "x", "trigger": {"type": "allLightsOff"},
          "actions": [{"capability": "curtain", "action": "close", "selector": {"capability": "curtain"}}]}
    assert rules_mod.normalize_rule(ok)["enabled"] is True
    for bad, msg in [
        ({**ok, "name": ""}, "name"),
        ({**ok, "actions": []}, "actions"),
        ({**ok, "actions": [{"capability": "curtain", "action": "explode"}]}, "not valid"),
        ({**ok, "actions": [{"capability": "nope", "action": "open"}]}, "unknown capability"),
        ({**ok, "trigger": {"type": "moonPhase"}}, "trigger.type"),
        ({**ok, "trigger": {"type": "time", "at": "7:00"}}, "HH:MM"),
        ({**ok, "trigger": {"type": "time", "at": "24:00"}}, "HH:MM"),
        ({**ok, "trigger": {"type": "time", "at": "07:00", "days": [0]}}, "days"),
        ({**ok, "conditions": [{"type": "timeWindow", "start": "22:00"}]}, "HH:MM"),
        ({**ok, "actions": [{**ok["actions"][0], "selector": {"brand": "samsung"}}]}, "selector"),
        ({**ok, "trigger": {"type": "event", "name": "bad name!"}}, "trigger.name"),
        ({**ok, "trigger": {"type": "deviceState", "capability": "lock", "field": "locked"}}, "equals"),
    ]:
        with pytest.raises(ValueError, match=msg):
            rules_mod.normalize_rule(bad)


def test_window_math():
    a, b = rules_mod.parse_hhmm("22:00"), rules_mod.parse_hhmm("02:00")
    assert engine.in_window(23 * 60, a, b) and engine.in_window(60, a, b)
    assert not engine.in_window(2 * 60, a, b) and not engine.in_window(12 * 60, a, b)
    assert engine.in_window(5, 8 * 60, 8 * 60)          # start == end -> always


# ---------------------------------------------------------------- service --
class FakeManager:
    """Mutable device set + command recorder standing in for DeviceManager."""

    def __init__(self, devices):
        self.devices = {d["id"]: Device.from_dict(d) for d in devices}
        self.commands = []
        self.fail = set()

    def list_devices(self):
        return list(self.devices.values())

    def execute(self, device_id, capability, action, params):
        if device_id in self.fail:
            raise RuntimeError("offline")
        self.commands.append((device_id, capability, action, params))
        st = self.devices[device_id].capabilities[capability].state
        if capability == "curtain":
            st["status"], st["position"] = ("closed", 0) if action == "close" else ("open", 100)
        if capability == "power":
            st["switch"] = "on" if action == "turnOn" else "off"

    def scan(self, **kw):
        pass


def _dev(i, kind, cap, actions, state, room="침실"):
    return {"id": i, "name": i, "kind": kind, "reachable": True, "controllable": True, "meta": {"room": room},
            "capabilities": {cap: {"key": cap, "actions": actions, "state": state}}}


def _home():
    return [_dev("l1", "light", "power", ["turnOn", "turnOff", "toggle"], {"switch": "on"}),
            _dev("c1", "curtain", "curtain", ["open", "close", "stop", "setPosition"], {"position": 100, "status": "open"}),
            _dev("c2", "curtain", "curtain", ["open", "close", "stop", "setPosition"], {"position": 100, "status": "open"}, "거실")]


BED = {"name": "취침 시 커튼 닫기", "trigger": {"type": "allLightsOff"},
       "conditions": [{"type": "timeWindow", "start": "22:00", "end": "02:00"}],
       "actions": [{"selector": {"capability": "curtain"}, "capability": "curtain", "action": "close"}]}


def _svc(tmp_path, mgr=None):
    mgr = mgr or FakeManager(_home())
    return AutomationService(mgr, tmp_path / "automation.json"), mgr


def test_sleep_scenario_end_to_end(tmp_path):
    svc, mgr = _svc(tmp_path)
    svc.upsert(BED)
    assert svc.tick(datetime(2026, 9, 29, 22, 30)) == []           # first look: only records state
    mgr.devices["l1"].capabilities["power"].state["switch"] = "off"  # user turns the last light off
    entries = svc.tick(datetime(2026, 9, 29, 22, 31))
    assert [e["status"] for e in entries] == ["ok"]
    assert {c[0] for c in mgr.commands} == {"c1", "c2"} and all(c[2] == "close" for c in mgr.commands)
    assert svc.tick(datetime(2026, 9, 29, 22, 32)) == []           # no repeat without a new transition
    assert svc.run_log()[0]["ruleName"] == "취침 시 커튼 닫기"


def test_time_rule_fires_once_and_not_retroactively(tmp_path):
    svc, mgr = _svc(tmp_path)
    at8 = datetime(2026, 9, 29, 8, 0)
    svc.clock = lambda: at8
    mgr.devices["c1"].capabilities["curtain"].state.update(position=0, status="closed")
    # created at 08:00 with a 07:00 trigger, i.e. an hour late -> must not fire (outside grace anyway)
    r = svc.upsert({"name": "기상", "trigger": {"type": "time", "at": "07:00"},
                    "actions": [{"selector": {"capability": "curtain"}, "capability": "curtain", "action": "open"}]})
    assert svc.tick(at8) == []
    # created at 07:03 for a 07:00 trigger: inside grace, but creating it marks today as done
    svc.clock = lambda: datetime(2026, 9, 30, 7, 3)
    r2 = svc.upsert({"name": "기상2", "trigger": {"type": "time", "at": "07:00"},
                     "actions": [{"selector": {"capability": "curtain"}, "capability": "curtain", "action": "open"}]})
    # r (older) fires on 9/30 at 07:04 as normal; r2 was created after its time that day -> skipped today
    assert {x["ruleId"] for x in svc.tick(datetime(2026, 9, 30, 7, 4))} == {r["id"]}
    # next morning both fire once; ticking again does not repeat
    e = svc.tick(datetime(2026, 10, 1, 7, 0))
    assert {x["ruleId"] for x in e} == {r["id"], r2["id"]}
    assert svc.tick(datetime(2026, 10, 1, 7, 1)) == []


def test_partial_failure_and_skip_statuses(tmp_path):
    svc, mgr = _svc(tmp_path)
    svc.upsert({**BED, "trigger": {"type": "event", "name": "sleep"}, "conditions": []})
    mgr.fail.add("c2")
    svc.emit_event("sleep")
    [entry] = svc.tick(datetime(2026, 9, 29, 23, 0))
    assert entry["status"] == "partial"
    bad = next(s for s in entry["steps"] if not s["ok"])
    assert bad["deviceId"] == "c2" and "offline" in bad["error"]
    svc.emit_event("sleep")
    mgr.fail.clear()
    [again] = svc.tick(datetime(2026, 9, 29, 23, 1))               # c1 is closed now, c2 still open
    assert {s["deviceId"]: s["skip"] for s in again["steps"]} == {"c1": "already-closed", "c2": None}
    svc.emit_event("sleep")
    [third] = svc.tick(datetime(2026, 9, 29, 23, 2))
    assert third["status"] == "skipped"


def test_persistence_and_crud(tmp_path):
    svc, _ = _svc(tmp_path)
    r = svc.upsert(BED)
    assert svc.set_enabled(r["id"], False)["enabled"] is False
    svc.emit_event("x")
    again, _ = _svc(tmp_path)
    assert [x["id"] for x in again.list_rules()] == [r["id"]] and again.list_rules()[0]["enabled"] is False
    again.delete(r["id"])
    with pytest.raises(KeyError):
        again.delete(r["id"])
    with pytest.raises(KeyError):
        again.upsert(BED, "nope")
    with pytest.raises(ValueError):
        again.emit_event("")


def test_corrupt_store_is_ignored(tmp_path):
    (tmp_path / "automation.json").write_text("{not json")
    svc, _ = _svc(tmp_path)
    assert svc.list_rules() == []


# -------------------------------------------------------------------- API --
@pytest.fixture
def api(monkeypatch, tmp_path):
    monkeypatch.setenv(demo.ENV, "1")
    a = demo.DemoAdapter()
    monkeypatch.setattr(registry, "CLOUD_ADAPTERS", [*registry.CLOUD_ADAPTERS, a])
    monkeypatch.setattr(registry, "_BY_ID", {**registry._BY_ID, "demo": a})
    mgr = DeviceManager()
    monkeypatch.setattr(server, "manager", mgr)
    monkeypatch.setattr(server, "automation", AutomationService(mgr, tmp_path / "automation.json"))
    monkeypatch.setattr(server, "_register_bonjour", lambda: (None, None))
    with TestClient(server.app) as c:
        yield c


def test_api_demo_bedtime_and_wake_scenario(api):
    devs = {d["id"]: d for d in api.get("/devices").json()["devices"]}
    assert {"demo:curtain-bedroom", "demo:curtain-living", "demo:light-living", "demo:light"} <= set(devs)
    r = api.post("/automation/rules", json=BED)
    assert r.status_code == 200
    rid = r.json()["id"]
    api.post("/automation/rules", json={"name": "외출", "trigger": {"type": "event", "name": "leaving"},
                                        "actions": [{"selector": {"kind": "light"}, "capability": "power", "action": "turnOff"}]})
    assert len(api.get("/automation/rules").json()["rules"]) == 2
    # validation errors are 400 with a message
    bad = api.post("/automation/rules", json={"name": "x", "trigger": {"type": "time", "at": "99:99"}, "actions": []})
    assert bad.status_code == 400
    # time window: force the clock inside it, then drive the demo lights
    server.automation.clock = lambda: datetime(2026, 9, 29, 23, 0)
    server.automation.tick()                                            # baseline (living light on, bedroom off)
    fired = api.post("/automation/events/leaving").json()["fired"]      # -> all lights off
    assert [f["ruleName"] for f in fired] == ["외출"] and fired[0]["status"] == "ok"
    server.automation.tick(datetime(2026, 9, 29, 23, 1))                # lights on -> off transition seen by rule 1
    devs = {d["id"]: d for d in api.get("/devices").json()["devices"]}
    assert devs["demo:curtain-bedroom"]["capabilities"]["curtain"]["state"] == {"position": 0, "status": "closed"}
    assert devs["demo:curtain-living"]["capabilities"]["curtain"]["state"]["status"] == "closed"
    log = api.get("/automation/log").json()["log"]
    assert {e["ruleName"] for e in log} == {"외출", "취침 시 커튼 닫기"}
    # disable, delete, clear
    assert api.post(f"/automation/rules/{rid}/enable", json={"enabled": False}).json()["enabled"] is False
    assert api.put(f"/automation/rules/{rid}", json={**BED, "name": "수정"}).json()["name"] == "수정"
    assert api.delete(f"/automation/rules/{rid}").status_code == 200
    assert api.delete(f"/automation/rules/{rid}").status_code == 404
    assert api.delete("/automation/log").status_code == 200 and api.get("/automation/log").json()["log"] == []


def test_api_requires_token_for_writes(api, monkeypatch):
    monkeypatch.setattr(server.config, "API_TOKEN", "s3cret")
    assert api.get("/automation/rules").status_code == 200
    assert api.post("/automation/rules", json=BED).status_code == 401
    assert api.post("/automation/events/wake").status_code == 401
    assert api.post("/automation/rules", json=BED, headers={"X-HomeHub-Token": "s3cret"}).status_code == 200


def test_ws_gets_automation_entry(api):
    api.post("/automation/rules", json={"name": "외출", "trigger": {"type": "event", "name": "leaving"},
                                        "actions": [{"selector": {"kind": "light"}, "capability": "power", "action": "turnOff"}]})
    with api.websocket_connect("/ws") as ws:
        assert ws.receive_json()["type"] == "devices"
        api.post("/automation/events/leaving")
        ev = ws.receive_json()
        assert ev["type"] == "automation" and ev["entry"]["ruleName"] == "외출"
