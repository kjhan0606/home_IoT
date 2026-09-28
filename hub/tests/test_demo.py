"""Dev-only demo adapter (HOMEHUB_FAKE_DEVICES=1) + API behaviour it relies on."""
import base64

import pytest
from fastapi.testclient import TestClient

from homehub import server, vacuum_map
from homehub.adapters import demo, registry


@pytest.fixture
def demo_hub(monkeypatch):
    monkeypatch.setenv(demo.ENV, "1")
    a = demo.DemoAdapter()
    monkeypatch.setattr(registry, "CLOUD_ADAPTERS", [*registry.CLOUD_ADAPTERS, a])
    monkeypatch.setattr(registry, "_BY_ID", {**registry._BY_ID, "demo": a})
    monkeypatch.setattr(server, "manager", server.DeviceManager())
    with TestClient(server.app) as c:      # lifespan syncs demo devices
        yield c


def test_env_flag(monkeypatch):
    monkeypatch.delenv(demo.ENV, raising=False)
    assert not demo.enabled_by_env()
    assert registry.get_adapter("demo") is None          # not registered by default
    monkeypatch.setenv(demo.ENV, "1")
    assert demo.enabled_by_env()


def test_devices_listed_and_marked_example(demo_hub):
    devs = {d["id"]: d for d in demo_hub.get("/devices").json()["devices"]}
    assert {"demo:tv", "demo:washer", "demo:fridge", "demo:vacuum", "demo:light", "demo:lock"} <= set(devs)
    assert all(d["meta"]["demo"] and "(예시)" in d["name"] for d in devs.values())
    assert devs["demo:vacuum"]["capabilities"]["roomCleaning"]["state"]["rooms"][0] == {"id": "16", "name": "거실"}


def test_commands_mutate_state(demo_hub):
    r = demo_hub.post("/devices/demo:tv/commands", json={"capability": "volume", "action": "setLevel",
                                                         "params": {"level": 40}})
    assert r.status_code == 200
    assert demo_hub.get("/devices/demo:tv").json()["capabilities"]["volume"]["state"]["level"] == 40
    demo_hub.post("/devices/demo:light/commands", json={"capability": "power", "action": "toggle"})
    assert demo_hub.get("/devices/demo:light").json()["capabilities"]["power"]["state"]["switch"] == "on"
    r = demo_hub.post("/devices/demo:vacuum/commands", json={"capability": "fanSpeed", "action": "setLevel",
                                                             "params": {"level": "nope"}})
    assert r.status_code == 400


def test_washer_remote_start_refused_403(demo_hub):
    r = demo_hub.post("/devices/demo:washer/commands", json={"capability": "washer", "action": "start"})
    assert r.status_code == 403
    assert "Remote Start" in r.json()["detail"]
    assert demo_hub.post("/devices/demo:washer/commands",
                         json={"capability": "washer", "action": "pause"}).status_code == 200


def test_room_and_zone_validation(demo_hub):
    ok = demo_hub.post("/devices/demo:vacuum/commands", json={
        "capability": "roomCleaning", "action": "cleanRooms", "params": {"roomIds": ["16", "18"], "repeat": 2}})
    assert ok.status_code == 200
    bad = demo_hub.post("/devices/demo:vacuum/commands", json={
        "capability": "zoneCleaning", "action": "cleanZones", "params": {"zones": [[0, 0, 1, 1]] * 6}})
    assert bad.status_code == 400


def test_map_metadata_and_goto_moves_robot(demo_hub):
    m = demo_hub.get("/devices/demo:vacuum/map").json()
    assert m["demo"] and m["image"]["width"] == demo.IMG_W and m["image"]["pngBase64"]
    png = base64.b64decode(m["image"]["pngBase64"])
    assert png[:4] == b"\x89PNG"
    # y axis flipped: map (20000, 30000) is the image's top-left corner
    assert vacuum_map.apply(m["transform"]["mapToImage"], 20000, 30000) == pytest.approx((0, 0))
    assert vacuum_map.apply(m["transform"]["imageToMap"], 300, 300) == pytest.approx((26000, 24000))
    living = next(r for r in m["rooms"] if r["id"] == "16")
    assert living["bbox"]["image"] == {"x0": 20.0, "y0": 20.0, "x1": 300.0, "y1": 400.0}
    demo_hub.post("/devices/demo:vacuum/commands", json={
        "capability": "goTo", "action": "goTo", "params": {"x": 30000, "y": 20000}})
    m2 = demo_hub.get("/devices/demo:vacuum/map?image=false").json()
    assert m2["robot"]["image"] == {"x": 500.0, "y": 500.0}
    assert "pngBase64" not in m2["image"]
    assert demo_hub.get("/devices/demo:vacuum/map.png").content[:4] == b"\x89PNG"


def test_ws_command_event_carries_device(demo_hub):
    with demo_hub.websocket_connect("/ws") as ws:
        first = ws.receive_json()
        assert first["type"] == "devices"
        demo_hub.post("/devices/demo:lock/commands", json={"capability": "lock", "action": "unlock"})
        ev = ws.receive_json()
        assert ev["type"] == "command" and ev["device"]["capabilities"]["lock"]["state"]["locked"] is False


def test_cors_closed_by_default():
    with TestClient(server.app) as c:
        r = c.options("/devices", headers={"Origin": "http://evil.example",
                                           "Access-Control-Request-Method": "GET"})
        assert "access-control-allow-origin" not in r.headers
