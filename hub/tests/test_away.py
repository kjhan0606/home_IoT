"""휴가/장기 외출 모드: seeded random evenings, safety (lights + curtains only), service, API."""
import json
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from homehub import server
from homehub.adapters import demo, registry
from homehub.automation import away
from homehub.automation.service import AutomationService
from homehub.manager import DeviceManager
from homehub.models import Device

FIX = json.loads((Path(__file__).resolve().parents[2] / "app/test/fixtures/away_scenarios.json").read_text())
ROOMS = ["거실", "주방", "욕실", "침실", "현관"]
PLAN = {"startDate": "2026-10-01", "endDate": "2026-10-05", "mode": "random", "seed": 42,
        "windowStart": "18:30", "windowEnd": "23:00", "lights": {"rooms": ROOMS},
        "curtains": {"enabled": True}}


def _dev(i, room, kind="light", on=False):
    caps = {"power": {"key": "power", "actions": ["turnOn", "turnOff"], "state": {"switch": "on" if on else "off"}}}
    if kind == "curtain":
        caps = {"curtain": {"key": "curtain", "actions": ["open", "close", "stop", "setPosition"],
                            "state": {"position": 100, "status": "open"}}}
    return Device.from_dict({"id": i, "name": i, "kind": kind, "reachable": True, "controllable": True,
                             "meta": {"room": room}, "capabilities": caps})


# ---------------------------------------------- shared scenarios (Dart too) --
@pytest.mark.parametrize("s", FIX["scenarios"], ids=[s["name"] for s in FIX["scenarios"]])
def test_shared_scenarios(s):
    plan = away.normalize_plan(s["plan"])
    assert plan == s["plan"]                                # normalisation is stable (Dart writes the same JSON)
    now = datetime.fromisoformat(s["now"])
    devs = [Device.from_dict(d) for d in s["devices"]]
    assert [{"deviceId": w.device_id, "action": w.action} for w in away.wants(plan, now, devs)] == s["wants"]
    assert away.status(plan, now) == s["status"]


@pytest.mark.parametrize("s", FIX["schedules"], ids=lambda s: f"seed{s['seed']}-{s['date']}")
def test_shared_schedules(s):
    plan = away.normalize_plan(s["plan"])
    for lid, iv in s["lights"].items():
        room = {"l-living": "거실", "l-kitchen": "주방", "l-bath": "욕실", "l-bed": "침실", "l-door": "현관",
                "l-off": "거실"}[lid]
        got = away.light_intervals(plan, date.fromisoformat(s["date"]), away.Target(lid, lid, room))
        assert [[a.isoformat(timespec="minutes"), b.isoformat(timespec="minutes")] for a, b in got] == iv


# ------------------------------------------------------ seeded randomness --
def test_same_seed_same_evening_and_other_seed_or_day_differs():
    plan = away.normalize_plan(PLAN)
    t = away.Target("l1", "l1", "거실")
    day = date(2026, 10, 2)
    a = away.light_intervals(plan, day, t)
    assert a == away.light_intervals(plan, day, t)                                  # reproducible
    assert a != away.light_intervals(plan, day + timedelta(days=1), t)              # differs day to day
    assert a != away.light_intervals(away.normalize_plan({**PLAN, "seed": 43}), day, t)


def test_rng_is_the_documented_integer_generator():
    r = away.Rng(42)
    assert [r.between(0, 99) for _ in range(5)] == [r2 for r2 in _expected_first_five()]


def _expected_first_five():
    st = 42 % (away._M - 1) + 1
    for _ in range(3):
        st = st * away._A % away._M
    out = []
    for _ in range(5):
        st = st * away._A % away._M
        out.append((st - 1) % 100)
    return out


def test_patterns_are_realistic_for_every_seed_and_day():
    plan = away.normalize_plan(PLAN)
    length = away.window_minutes(plan)
    assert length == 270
    for seed in range(25):
        p = {**plan, "seed": seed}
        for day in range(1, 6):
            d = date(2026, 10, day)
            per = {r: away.light_intervals(p, d, away.Target(f"x-{r}", "x", r)) for r in ROOMS}
            for r, ivs in per.items():
                assert ivs, (seed, day, r)
                for a, b in ivs:                                                  # inside the window, >= 3 min
                    assert a.replace(hour=18, minute=30) <= a and b <= a.replace(hour=23, minute=0)
                    assert b - a >= timedelta(minutes=3)
                assert all(x[1] < y[0] for x, y in zip(ivs, ivs[1:]))            # sorted, not overlapping
            living = sum((b - a).seconds for a, b in per["거실"])
            bath = sum((b - a).seconds for a, b in per["욕실"])
            kitchen = sum((b - a).seconds for a, b in per["주방"])
            assert living >= 60 * 60                                              # long evening
            assert bath <= 45 * 60 and all((b - a).seconds <= 30 * 60 for a, b in per["욕실"])   # brief visits
            assert kitchen <= 95 * 60 and all((b - a).seconds <= 35 * 60 for a, b in per["주방"])
            assert living > bath                                                  # living room lit longer than bathroom


def test_room_types():
    assert [away.room_type(r) for r in ("거실", "Living room", "욕실", "화장실", "주방", "안방", "침실", "현관", "서재", None)] \
        == ["living", "living", "bath", "bath", "kitchen", "bedroom", "bedroom", "entrance", "other", "other"]


# ------------------------------------------------------------------ safety --
def test_only_lights_and_curtains_are_ever_selected():
    devs = [_dev("l1", "거실"), _dev("c1", "거실", "curtain"),
            Device.from_dict({"id": "ac", "name": "에어컨", "kind": "air_conditioner", "reachable": True,
                              "controllable": True, "meta": {"room": "거실"},
                              "capabilities": {"power": {"key": "power", "actions": ["turnOn", "turnOff"],
                                                         "state": {"switch": "off"}}}}),
            Device.from_dict({"id": "lk", "name": "도어락", "kind": "lock", "reachable": True, "controllable": True,
                              "meta": {"room": "거실"},
                              "capabilities": {"lock": {"key": "lock", "actions": ["lock", "unlock"],
                                                        "state": {"locked": True}}}})]
    plan = away.normalize_plan({**PLAN, "lights": {"rooms": ["거실"], "devices": ["ac", "lk"]},
                                "curtains": {"enabled": True, "devices": ["c1", "ac", "lk"]}})
    assert [d.id for d in away.chosen_lights(plan, devs)] == ["l1"]
    assert [d.id for d in away.chosen_curtains(plan, devs)] == ["c1"]
    for h in range(0, 24):
        for w in away.wants(plan, datetime(2026, 10, 2, h, 10), devs):
            assert (w.capability, w.action) in {("power", "turnOn"), ("power", "turnOff"),
                                                ("curtain", "open"), ("curtain", "close")}
            assert w.device_id in {"l1", "c1"}


def test_service_refuses_to_command_anything_else(tmp_path):
    ac = Device.from_dict({"id": "ac", "name": "에어컨", "kind": "air_conditioner", "reachable": True,
                           "controllable": True, "meta": {},
                           "capabilities": {"power": {"key": "power", "actions": ["turnOn", "turnOff"],
                                                      "state": {"switch": "off"}}}})

    class M:
        def list_devices(self): return [ac]
        def execute(self, *a, **k): raise AssertionError("must never be called")

    svc = AutomationService(M(), tmp_path / "a.json")
    cur = svc.snapshot()
    for w in (away.Want("ac", "ac", "power", "turnOn", "x"), away.Want("ac", "ac", "power", "toggle", "x"),
              away.Want("ac", "ac", "lock", "unlock", "x"), away.Want("nope", "n", "power", "turnOn", "x")):
        assert svc._away_step(w, cur) is None


# -------------------------------------------------------------- validation --
def test_plan_validation():
    ok = away.normalize_plan(PLAN)
    assert ok["lights"]["rooms"] == ROOMS and isinstance(ok["seed"], int)
    seedless = away.normalize_plan({k: v for k, v in PLAN.items() if k != "seed"})
    assert 0 <= seedless["seed"] < 1_000_000
    for bad, msg in [
        ({**PLAN, "startDate": "10/01"}, "startDate"),
        ({**PLAN, "endDate": "2026-09-30"}, "before"),
        ({**PLAN, "endDate": "2027-01-01"}, "at most"),
        ({**PLAN, "mode": "chaos"}, "mode"),
        ({**PLAN, "lights": {}}, "at least one"),
        ({**PLAN, "windowStart": "25:00"}, "windowStart"),
        ({**PLAN, "windowStart": "20:00", "windowEnd": "20:30"}, "between 1 and 16"),
        ({**PLAN, "seed": -1}, "seed"),
        ({**PLAN, "curtains": {"enabled": True, "openAt": "8am"}}, "openAt"),
        ("nope", "object"),
    ]:
        with pytest.raises(ValueError, match=msg):
            away.normalize_plan(bad)


# ----------------------------------------------------------------- service --
class FakeManager:
    """Executes light/curtain commands on in-memory devices."""

    def __init__(self, devs):
        self.devs = {d.id: d for d in devs}
        self.sent = []
        self.fail = set()

    def list_devices(self): return list(self.devs.values())
    def scan(self, **k): return list(self.devs.values())

    def execute(self, did, capability, action, params):
        if did in self.fail:
            raise RuntimeError("vendor down")
        self.sent.append((did, capability, action))
        st = self.devs[did].capabilities[capability].state
        if capability == "power":
            st["switch"] = "on" if action == "turnOn" else "off"
        else:
            st["status"] = "open" if action == "open" else "closed"
            st["position"] = 100 if action == "open" else 0


def _svc(tmp_path, plan=None, on=()):
    devs = [_dev(f"l-{r}", r, on=(r in on)) for r in ROOMS] + [_dev("c1", "침실", "curtain")]
    mgr = FakeManager(devs)
    svc = AutomationService(mgr, tmp_path / "a.json")
    if plan:
        svc.set_away(plan)
    return svc, mgr


def _lit(mgr):
    return sorted(i for i, d in mgr.devs.items() if d.kind == "light" and d.capabilities["power"].state["switch"] == "on")


def test_week_simulation_matches_the_schedule_and_ends_clean(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "curtains": {"enabled": False}})
    plan = svc.get_away()["plan"]
    t = datetime(2026, 10, 1, 12, 0)
    seen_on = set()
    while t < datetime(2026, 10, 6, 12, 0):
        svc.tick(t)
        expected = {w.device_id for w in away.wants(plan, t, svc.manager.list_devices()) if w.action == "turnOn"}
        if away.status(plan, t)["state"] == "active":
            assert set(_lit(mgr)) == expected, t
        seen_on |= set(_lit(mgr))
        t += timedelta(minutes=5)
    assert seen_on == {f"l-{r}" for r in ROOMS}                      # every chosen room lit at some point
    assert _lit(mgr) == []                                            # everything ended off
    svc.clock = lambda: datetime(2026, 10, 6, 12, 0)
    assert svc.get_away()["status"]["state"] == "finished"
    n = len(mgr.sent)
    svc.tick(datetime(2026, 10, 7, 20, 0))
    assert len(mgr.sent) == n                                         # nothing more after the end
    assert all(c in ("power",) for _, c, _ in mgr.sent)


def test_sends_only_the_difference_and_recovers_after_a_missed_tick(tmp_path):
    svc, mgr = _svc(tmp_path, PLAN)
    svc.tick(datetime(2026, 10, 2, 20, 0))
    first = len(mgr.sent)
    svc.tick(datetime(2026, 10, 2, 20, 0))
    assert len(mgr.sent) == first                                     # already matching: no chatter
    living = "l-거실"
    mgr.devs[living].capabilities["power"].state["switch"] = "off"    # somebody/something switched it
    svc.tick(datetime(2026, 10, 2, 20, 1))
    plan = away.normalize_plan(PLAN)
    should_be_on = any(w.device_id == living and w.action == "turnOn"
                       for w in away.wants(plan, datetime(2026, 10, 2, 20, 1), mgr.list_devices()))
    assert (living in _lit(mgr)) == should_be_on


def test_curtains_open_in_morning_and_close_at_dusk(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": True, "openAt": "08:00", "closeAt": "18:30"}})
    svc.tick(datetime(2026, 10, 2, 7, 0))
    assert mgr.devs["c1"].capabilities["curtain"].state["status"] == "closed"     # before opening time
    svc.tick(datetime(2026, 10, 2, 9, 0))
    assert mgr.devs["c1"].capabilities["curtain"].state["status"] == "open"
    svc.tick(datetime(2026, 10, 2, 19, 0))
    assert mgr.devs["c1"].capabilities["curtain"].state["status"] == "closed"


def test_arriving_ends_the_mode_and_turns_off_only_what_it_turned_on(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "lights": {"rooms": ["거실", "주방"]}, "curtains": {"enabled": False}},
                    on=("침실",))                                      # 침실 was on before and is not part of the plan
    svc.tick(datetime(2026, 10, 2, 20, 0))
    assert _lit(mgr) == ["l-거실", "l-주방", "l-침실"]
    svc.emit_event("arriving")
    svc.tick(datetime(2026, 10, 2, 20, 5))
    assert _lit(mgr) == ["l-침실"]
    assert svc.get_away()["status"]["state"] == "stopped"
    svc.tick(datetime(2026, 10, 2, 20, 10))                            # stays stopped
    assert _lit(mgr) == ["l-침실"]


def test_stop_away_now_and_delete(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": False}})
    svc.tick(datetime(2026, 10, 2, 20, 0))
    assert len(_lit(mgr)) == 5
    svc.stop_away()
    assert _lit(mgr) == [] and svc.get_away()["plan"] is None


def test_failed_commands_are_logged_and_retried_later(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": False}})
    mgr.fail.add("l-거실")
    e = svc.tick(datetime(2026, 10, 2, 20, 0))
    assert e[-1]["status"] == "partial" and "l-거실" not in _lit(mgr)
    svc.tick(datetime(2026, 10, 2, 20, 1))                             # inside the back-off: not hammered
    assert sum(1 for s in mgr.sent if s[0] == "l-거실") == 0
    mgr.fail.clear()
    svc.tick(datetime(2026, 10, 2, 20, 10))
    assert "l-거실" in _lit(mgr)


def test_offline_lights_are_left_alone(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": False}})
    mgr.devs["l-거실"].reachable = False
    svc.tick(datetime(2026, 10, 2, 20, 0))
    assert not any(s[0] == "l-거실" for s in mgr.sent)


def test_plan_persists_across_restart_including_what_it_turned_on(tmp_path):
    svc, mgr = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": False}})
    svc.tick(datetime(2026, 10, 2, 20, 0))
    svc2 = AutomationService(mgr, tmp_path / "a.json")
    got = svc2.get_away()
    assert got["plan"] == svc.get_away()["plan"]
    svc2.stop_away()
    assert _lit(mgr) == []


def test_log_entries_are_labelled_with_the_day(tmp_path):
    svc, _ = _svc(tmp_path, {**PLAN, "mode": "fixed", "curtains": {"enabled": False}})
    svc.tick(datetime(2026, 10, 3, 20, 0))
    e = svc.run_log()[0]
    assert e["ruleName"] == "휴가 모드" and e["reason"] == "휴가 모드 3일째"


def test_status_days():
    plan = away.normalize_plan(PLAN)
    assert away.status(plan, datetime(2026, 9, 30, 12)) == {"state": "scheduled", "day": 0, "days": 5}
    assert away.status(plan, datetime(2026, 10, 3, 12)) == {"state": "active", "day": 3, "days": 5}
    assert away.status(plan, datetime(2026, 10, 5, 23, 0))["state"] == "finished"


# --------------------------------------------------------------------- API --
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


def test_api_away_roundtrip_with_demo_devices(api):
    assert api.get("/automation/away").json() == {"plan": None, "status": None, "schedule": []}
    assert api.put("/automation/away", json={**PLAN, "startDate": "nope"}).status_code == 400
    r = api.put("/automation/away", json={**PLAN, "lights": {"rooms": ["거실", "주방", "욕실"]},
                                          "curtains": {"enabled": True}})
    assert r.status_code == 200
    body = r.json()
    assert body["plan"]["mode"] == "random" and {s["deviceId"] for s in body["schedule"]} == {
        "demo:light-living", "demo:light-kitchen", "demo:light-bath"}
    server.automation.clock = lambda: datetime(2026, 10, 3, 20, 0)
    server.automation.tick()
    devs = {d["id"]: d for d in api.get("/devices").json()["devices"]}
    assert devs["demo:curtain-bedroom"]["capabilities"]["curtain"]["state"]["status"] == "closed"
    assert api.get("/automation/away").json()["status"]["state"] == "active"
    assert api.get("/automation/away").json()["status"]["day"] == 3
    assert api.delete("/automation/away").status_code == 200
    assert api.get("/automation/away").json()["plan"] is None
    devs = {d["id"]: d for d in api.get("/devices").json()["devices"]}
    assert devs["demo:light-living"]["capabilities"]["power"]["state"]["switch"] == "off"


def test_api_away_requires_token_for_writes(api, monkeypatch):
    monkeypatch.setattr(server.config, "API_TOKEN", "s3cret")
    assert api.get("/automation/away").status_code == 200
    assert api.put("/automation/away", json=PLAN).status_code == 401
    assert api.delete("/automation/away").status_code == 401
    assert api.put("/automation/away", json=PLAN, headers={"X-HomeHub-Token": "s3cret"}).status_code == 200
