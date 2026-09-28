import copy
import io
import logging
import os
import stat
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from homehub import capabilities as cap
from homehub import secret_store, server
from homehub.adapters import registry
from homehub.adapters.roborock import LinkError, RoborockAdapter
from homehub.cloud.roborock_backend import LibraryBackend, RoborockBackend, build_snapshot, map_payload
from homehub.discovery import engine
from homehub.manager import DeviceManager
from homehub.models import DiscoveredHost
from homehub.vacuum_map import apply

SECRET_TOKEN = "rriot-SECRET-hmac-9f8e7d"
LOCAL_KEY = "LocalKey-XYZ-123456"
PASSWORD = "hunter2-secret-pw"
RR_MAC = "b0:4a:39:11:22:33"

S7 = {
    "duid": "rr1", "name": "Roborock S7", "model": "roborock.vacuum.a15", "productName": "Roborock S7",
    "online": True, "transport": "local", "protocol": "v1",
    "status": {"state": "paused", "battery": 64, "error": None, "dockError": None, "cleanAreaM2": 12.5,
               "cleanTimeS": 900, "fanSpeed": "balanced", "waterLevel": "medium", "mopMode": "standard",
               "inCleaning": 3},
    "options": {"fanSpeeds": {"quiet": 101, "balanced": 102, "turbo": 103, "max": 104},
                "waterLevels": {"off": 200, "low": 201, "medium": 202, "high": 203},
                "mopModes": {"standard": 300, "deep": 301}},
    "rooms": [{"id": "16", "name": "Kitchen"}, {"id": "17", "name": "Living room"}],
    "consumables": {"main_brush_work_time": 540000, "side_brush_work_time": 72000,
                    "filter_work_time": 540000, "sensor_dirty_time": None, "moproller_work_time": 3600},
    "ip": "192.168.0.40", "mac": RR_MAC,
    "features": {"rooms": True, "zones": True, "goto": True, "map": True},
}
BASIC = {  # old/basic model: no mop, no rooms, no map
    "duid": "rr2", "name": "Roborock E4", "model": "roborock.vacuum.c1", "online": True,
    "transport": "cloud", "protocol": "v1",
    "status": {"state": "charging", "battery": 100, "error": "main_brush_jammed", "fanSpeed": "quiet"},
    "options": {"fanSpeeds": {"quiet": 38, "balanced": 60}, "waterLevels": {}, "mopModes": {}},
    "rooms": [], "consumables": {}, "features": {"rooms": False, "zones": False, "goto": False, "map": False},
}
Q10 = {"duid": "rr3", "name": "Q10", "model": "roborock.vacuum.ss07", "protocol": "other", "online": True}


class RoborockInvalidCode(Exception):
    pass


class RoborockRateLimit(Exception):
    pass


class FakeBackend(RoborockBackend):
    def __init__(self, snaps=None):
        self.snaps = snaps if snaps is not None else [copy.deepcopy(S7), copy.deepcopy(BASIC), copy.deepcopy(Q10)]
        self.calls = []
        self.fail_login: Exception | None = None
        self.map = None

    def request_code(self, email):
        self.calls.append(("request_code", email))

    def login(self, email, code=None, password=None):
        self.calls.append(("login", email, code, password))
        logging.getLogger("homehub").debug("login attempt for %s", email)
        if self.fail_login:
            raise self.fail_login
        return {"user_data": {"rruid": "u1", "rriot": {"h": SECRET_TOKEN, "s": "sss"}},
                "base_url": "https://usiot.roborock.com", "local_keys": {"rr1": LOCAL_KEY},
                "devices": [{"duid": "rr1", "name": "Roborock S7", "model": "roborock.vacuum.a15"}]}

    def connect(self, creds):
        self.calls.append(("connect", creds["username"]))

    def snapshots(self):
        return copy.deepcopy(self.snaps)

    def send(self, duid, method, params=None):
        self.calls.append(("send", duid, method, params))
        return {"result": ["ok"], "transport": "local"}

    def get_map(self, duid):
        return self.map


def _link(adapter):
    return adapter.login("juhan@example.com", code="123456")


@pytest.fixture
def fake():
    return FakeBackend()


@pytest.fixture
def rr(fake):
    a = RoborockAdapter(backend=fake)
    _link(a)
    return a


@pytest.fixture
def reg_rr(monkeypatch, fake):
    """Registry's singleton adapter wired to the fake backend."""
    a = registry.get_adapter("roborock")
    monkeypatch.setattr(a, "_backend", fake)
    a._maps.clear()
    return a


@pytest.fixture
def client(monkeypatch, reg_rr):
    monkeypatch.setattr(server, "manager", DeviceManager())
    monkeypatch.setattr(server, "_register_bonjour", lambda: (None, None))
    monkeypatch.setattr(engine, "scan", lambda **kw: [])
    with TestClient(server.app) as c:
        yield c


def _devs(a):
    return {d.meta["cloudId"]: d for d in a.list_devices()}


# ----------------------------------------------------------------- link flow --
def test_link_flow_stores_secrets_0600_and_never_logs_or_returns_them(fake, caplog):
    caplog.set_level(logging.DEBUG)
    a = RoborockAdapter(backend=fake)
    assert not a.enabled()
    assert a.request_code(" juhan@example.com ") == {"ok": True, "sentTo": "j***@example.com"}
    res = a.login("juhan@example.com", password=PASSWORD)
    assert res["linked"] and res["account"] == "j***@example.com"
    assert a.enabled()
    p = secret_store.path_for("roborock")
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(p.parent).st_mode) == 0o700
    stored = secret_store.load("roborock")
    assert stored["user_data"]["rriot"]["h"] == SECRET_TOKEN and stored["local_keys"] == {"rr1": LOCAL_KEY}
    assert PASSWORD not in p.read_text()                      # password is never persisted
    blob = repr(res) + repr(a.link_status()) + caplog.text
    for secret in (SECRET_TOKEN, LOCAL_KEY, PASSWORD):
        assert secret not in blob
    assert ("login", "juhan@example.com", None, PASSWORD) in fake.calls


def test_login_validation_and_error_translation(fake):
    a = RoborockAdapter(backend=fake)
    with pytest.raises(LinkError):
        a.login("juhan@example.com")                              # neither code nor password
    with pytest.raises(LinkError):
        a.login("juhan@example.com", code="12a")
    with pytest.raises(LinkError):
        a.login("not-an-email", code="1")
    fake.fail_login = RoborockInvalidCode("Invalid code")
    with pytest.raises(LinkError, match="Invalid code"):
        a.login("juhan@example.com", code="000000")
    assert not a.enabled() and secret_store.load("roborock") is None


def test_link_endpoints(client, fake):
    assert client.get("/integrations/roborock").json()["linked"] is False
    assert client.get("/health").json()["integrations"]["roborock"] is False
    r = client.post("/integrations/roborock/request-code", json={"email": "juhan@example.com"})
    assert r.status_code == 200 and r.json()["sentTo"] == "j***@example.com"
    r = client.post("/integrations/roborock/login", json={"email": "juhan@example.com", "code": "123456"})
    assert r.status_code == 200 and SECRET_TOKEN not in r.text and LOCAL_KEY not in r.text
    st = client.get("/integrations/roborock").json()
    assert st["linked"] and st["account"] == "j***@example.com" and SECRET_TOKEN not in repr(st)
    devs = client.post("/scan").json()["devices"]
    assert {d["id"] for d in devs} == {"roborock:rr1", "roborock:rr2", "roborock:rr3"}
    assert SECRET_TOKEN not in repr(devs) and LOCAL_KEY not in repr(devs)
    fake.fail_login = RoborockRateLimit("slow down")
    r = client.post("/integrations/roborock/login", json={"email": "juhan@example.com", "code": "1"})
    assert r.status_code == 429
    fake.fail_login = RoborockInvalidCode("bad code")
    assert client.post("/integrations/roborock/login", json={"email": "juhan@example.com", "code": "1"}).status_code == 400
    r = client.post("/integrations/roborock/unlink")
    assert r.status_code == 200 and r.json()["removed"] is True
    assert secret_store.load("roborock") is None
    assert client.get("/devices").json()["devices"] == []


# ------------------------------------------------------ listing / status map --
def test_listing_and_status_mapping(rr):
    d = _devs(rr)
    s7 = d["rr1"]
    assert s7.id == "roborock:rr1" and s7.kind == "vacuum" and s7.ip == "192.168.0.40" and s7.mac == RR_MAC
    assert s7.meta["transport"] == "local"
    v = s7.capabilities[cap.VACUUM].state
    assert v["status"] == "paused" and v["battery"] == 64 and v["error"] is None
    assert s7.capabilities[cap.ROOM_CLEANING].state["rooms"][0] == {"id": "16", "name": "Kitchen"}
    assert s7.capabilities[cap.FAN_SPEED].state == {"level": "balanced", "levels": ["quiet", "balanced", "turbo", "max"]}
    m = s7.capabilities[cap.MOPPING]
    assert m.actions == ["setWaterLevel", "setMopMode"] and m.state["waterLevel"] == "medium"
    items = {i["id"]: i for i in s7.capabilities[cap.CONSUMABLES].state["items"]}
    assert items["mainBrush"] == {"id": "mainBrush", "name": "Main brush", "usedHours": 150.0,
                                  "remainingPercent": 50, "resettable": True}
    assert items["filter"]["remainingPercent"] == 0 and "sensors" not in items
    assert items["mopRoller"]["resettable"] is False
    assert s7.capabilities[cap.CLEANING_STATS].state == {"areaM2": 12.5, "durationSeconds": 900}
    assert cap.VACUUM_MAP in s7.capabilities and cap.ZONE_CLEANING in s7.capabilities and cap.GO_TO in s7.capabilities

    basic = d["rr2"]
    assert set(basic.capabilities) == {cap.VACUUM, cap.CLEANING_STATS, cap.FAN_SPEED}
    assert basic.capabilities[cap.VACUUM].state["status"] == "charging"
    assert basic.capabilities[cap.VACUUM].state["error"] == "main_brush_jammed"

    q10 = d["rr3"]
    assert q10.controllable is False and q10.capabilities == {}


# ----------------------------------------------------- command translation ----
@pytest.mark.parametrize("capability,action,params,expected", [
    (cap.VACUUM, "start", {}, ("resume_segment_clean", None)),          # paused mid room-clean
    (cap.VACUUM, "pause", {}, ("app_pause", None)),
    (cap.VACUUM, "stop", {}, ("app_stop", None)),
    (cap.VACUUM, "dock", {}, ("app_charge", None)),
    (cap.ROOM_CLEANING, "cleanRooms", {"roomIds": ["16", 17], "repeat": 2},
     ("app_segment_clean", [{"segments": [16, 17], "repeat": 2}])),
    (cap.ZONE_CLEANING, "cleanZones", {"zones": [[27000, 26000, 25000, 24000], [1, 2, 3, 4]], "repeat": 3},
     ("app_zoned_clean", [[25000, 24000, 27000, 26000, 3], [1, 2, 3, 4, 3]])),
    (cap.GO_TO, "goTo", {"x": 25500.4, "y": 25000}, ("app_goto_target", [25500, 25000])),
    (cap.FAN_SPEED, "setLevel", {"level": "turbo"}, ("set_custom_mode", [103])),
    (cap.MOPPING, "setWaterLevel", {"level": "high"}, ("set_water_box_custom_mode", [203])),
    (cap.MOPPING, "setMopMode", {"mode": "deep"}, ("set_mop_mode", [301])),
    (cap.CONSUMABLES, "reset", {"id": "sideBrush"}, ("reset_consumable", ["side_brush_work_time"])),
])
def test_command_translation(rr, fake, capability, action, params, expected):
    s7 = _devs(rr)["rr1"]
    res = rr.execute(s7, capability, action, params)
    assert fake.calls[-1] == ("send", "rr1", *expected)
    assert res["transport"] == "local" and res["command"] == expected[0]


@pytest.mark.parametrize("duid,capability,action,params,match", [
    ("rr2", cap.MOPPING, "setWaterLevel", {"level": "high"}, "does not support"),
    ("rr2", cap.ROOM_CLEANING, "cleanRooms", {"roomIds": ["1"]}, "does not support"),
    ("rr2", cap.GO_TO, "goTo", {"x": 1, "y": 2}, "does not support"),
    ("rr2", cap.FAN_SPEED, "setLevel", {"level": "max"}, "unsupported level"),
    ("rr1", cap.ROOM_CLEANING, "cleanRooms", {"roomIds": ["99"]}, "unknown room"),
    ("rr1", cap.ROOM_CLEANING, "cleanRooms", {"roomIds": ["16"], "repeat": 4}, "repeat"),
    ("rr1", cap.ZONE_CLEANING, "cleanZones", {"zones": [[0, 0, 1, 1]] * 6}, "at most 5"),
    ("rr1", cap.ZONE_CLEANING, "cleanZones", {"zones": [[0, 0, 0, 5]]}, "non-zero"),
    ("rr1", cap.CONSUMABLES, "reset", {"id": "mopRoller"}, "cannot be reset"),
    ("rr1", cap.CONSUMABLES, "reset", {"id": "sensors"}, "unknown consumable"),
])
def test_unsupported_or_invalid_is_refused(rr, fake, duid, capability, action, params, match):
    dev = _devs(rr)[duid]
    n = len(fake.calls)
    with pytest.raises(ValueError, match=match):
        rr.execute(dev, capability, action, params)
    assert not [c for c in fake.calls[n:] if c[0] == "send"]


def test_unlinked_execute_raises_not_configured(fake):
    a = RoborockAdapter(backend=fake)
    dev = a.device_from_snapshot(copy.deepcopy(S7))
    from homehub.cloud.errors import CloudNotConfiguredError
    with pytest.raises(CloudNotConfiguredError):
        a.execute(dev, cap.VACUUM, "dock", {})


# ------------------------------------------- local -> cloud fallback (library) --
def _strategy(name, fail):
    from roborock.devices.rpc.v1_channel import RpcStrategy
    from roborock.exceptions import RoborockException
    from roborock.protocols.v1_protocol import ResponseMessage

    class StubChannel:
        def __init__(self):
            self.published = []
            self.cb = None

        async def subscribe(self, cb):
            self.cb = cb
            return lambda: None

        async def publish(self, msg):
            self.published.append(msg.method)
            if fail:
                raise RoborockException(f"{name} unreachable")
            self.cb(msg)

    ch = StubChannel()
    return RpcStrategy(name=name, channel=ch, encoder=lambda req: req,
                       decoder=lambda m: ResponseMessage(request_id=m.request_id, data=[name])), ch


@pytest.mark.parametrize("local_fails,expected", [(True, ["mqtt"]), (False, ["local"])])
def test_library_backend_prefers_local_then_falls_back_to_cloud(local_fails, expected):
    from roborock.devices.rpc.v1_channel import RpcChannel
    from roborock.devices.traits.v1.command import CommandTrait

    local, lch = _strategy("local", local_fails)
    mqtt, mch = _strategy("mqtt", False)
    cmd = CommandTrait()
    cmd._rpc_channel = RpcChannel(lambda: [local, mqtt], logging.getLogger("test.rpc"))
    dev = SimpleNamespace(duid="rr1", is_local_connected=True, v1_properties=SimpleNamespace(command=cmd))
    backend = LibraryBackend()
    backend._manager = SimpleNamespace(get_device=AsyncMock(return_value=dev))
    try:
        res = backend.send("rr1", "app_charge")
    finally:
        backend._manager = None
        backend._runner.stop()
    assert res["result"] == expected
    assert lch.published == ["app_charge"]
    assert mch.published == (["app_charge"] if local_fails else [])


def test_build_snapshot_from_library_objects():
    import asyncio

    from roborock.data.v1.v1_clean_modes import VacuumModes, WaterModes
    from roborock.data.v1.v1_code_mappings import RoborockErrorCode, RoborockInCleaning, RoborockStateCode

    status = SimpleNamespace(
        refresh=AsyncMock(), state=RoborockStateCode.segment_cleaning, battery=80,
        error_code=RoborockErrorCode.none, dock_error_status=None, square_meter_clean_area=3.2,
        clean_time=120, fan_speed_name="turbo", water_mode_name="low", mop_route_name=None,
        in_cleaning=RoborockInCleaning.segment_clean_not_complete, map_present=1,
        fan_speed_options=[VacuumModes.QUIET, VacuumModes.TURBO], water_mode_options=[WaterModes.OFF, WaterModes.LOW],
        mop_route_mapping={},
    )
    v1 = SimpleNamespace(
        status=status,
        consumables=SimpleNamespace(refresh=AsyncMock(side_effect=RuntimeError("boom")), main_brush_work_time=10),
        rooms=SimpleNamespace(refresh=AsyncMock(), rooms=[SimpleNamespace(segment_id=16, name="Kitchen")]),
        network_info=SimpleNamespace(refresh=AsyncMock(), ip="192.168.0.40", mac=RR_MAC),
        device_features=SimpleNamespace(is_support_water_mode=True),
    )
    dev = SimpleNamespace(duid="rr1", name="S8", product=SimpleNamespace(model="roborock.vacuum.a51", name="S8"),
                          device_info=SimpleNamespace(online=True), is_connected=True, is_local_connected=False,
                          v1_properties=v1)
    s = asyncio.run(build_snapshot(dev))
    assert s["transport"] == "cloud" and s["protocol"] == "v1"
    assert s["status"]["state"] == "segment_cleaning" and s["status"]["error"] is None
    assert s["status"]["inCleaning"] == 3
    assert s["options"]["fanSpeeds"] == {"quiet": 101, "turbo": 103}
    assert s["options"]["waterLevels"] == {"off": 200, "low": 201}
    assert s["rooms"] == [{"id": "16", "name": "Kitchen"}] and s["mac"] == RR_MAC
    assert s["consumables"]["main_brush_work_time"] == 10     # stale value kept when refresh fails
    a = RoborockAdapter(backend=FakeBackend([]))
    assert a.device_from_snapshot(s).capabilities[cap.VACUUM].state["status"] == "cleaning"


# ------------------------------------------------------------- LAN dedup -----
def test_lan_roborock_host_linked_with_cloud_device(monkeypatch, reg_rr):
    _link(reg_rr)
    lan = DiscoveredHost(ip="192.168.0.40", mac=RR_MAC.upper().replace(":", "-"), vendor="Roborock", sources=["arp"],
                         mdns_services=["_miio._udp.local."])
    monkeypatch.setattr(engine, "scan", lambda **kw: [lan])
    m = DeviceManager()
    devs = m.scan()
    vacs = [d for d in devs if d.kind == "vacuum" and d.ip == "192.168.0.40"]
    assert len(vacs) == 1 and vacs[0].id == "roborock:rr1"
    assert vacs[0].meta["lanHostId"].startswith("host:")
    assert m.get(vacs[0].meta["lanHostId"]).id == "roborock:rr1"     # old LAN id still resolves
    assert len(devs) == 3


# ------------------------------------------------------------------ map ------
def _real_map(rotate=0, scale=2):
    from PIL import Image
    from vacuum_map_parser_base.config.image_config import ImageConfig
    from vacuum_map_parser_base.map_data import ImageData, MapData, Point, Room

    md = MapData(25500, 1000)            # same calibration constants the Roborock parser uses
    md.image = ImageData(0, 480, 470, 60, 80, ImageConfig(scale=scale, rotate=rotate), None,
                         lambda p: Point(p.x / 50, p.y / 50))
    md.rooms = {16: Room(24000, 24500, 26000, 26500, 16), 17: Room(26000, 24500, 27500, 26000, 17, "LR")}
    md.vacuum_position = Point(25000, 25500, 90)
    md.charger = Point(25600, 25600)
    w, h = (80 * scale, 60 * scale) if rotate % 180 == 0 else (60 * scale, 80 * scale)
    buf = io.BytesIO()
    Image.new("RGB", (w, h)).save(buf, format="PNG")
    return md, buf.getvalue()


@pytest.mark.parametrize("rotate", [0, 90])
def test_map_metadata_transform_matches_library(rotate, rr, fake):
    md, png = _real_map(rotate=rotate)
    fake.map = (png, map_payload(md, {16: "Kitchen"}))
    s7 = _devs(rr)["rr1"]
    got_png, meta = rr.get_map(s7)
    assert got_png == png
    dims = md.image.dimensions
    exp = md.vacuum_position.to_img(dims).rotated(dims)
    assert meta["robot"]["image"] == pytest.approx({"x": exp.x, "y": exp.y}, abs=0.01)
    assert meta["robot"]["map"] == {"x": 25000, "y": 25500, "angle": 90}
    # round trip pixel -> map
    px = apply(meta["transform"]["mapToImage"], 25600, 25600)
    assert apply(meta["transform"]["imageToMap"], *px) == pytest.approx((25600, 25600), abs=1e-6)
    assert meta["image"]["width"] == (160 if rotate == 0 else 120)
    rooms = {r["id"]: r for r in meta["rooms"]}
    assert rooms["16"]["name"] == "Kitchen" and rooms["17"]["name"] == "LR"
    assert rooms["16"]["bbox"]["map"] == {"x0": 24000, "y0": 24500, "x1": 26000, "y1": 26500}
    ib = rooms["16"]["bbox"]["image"]
    assert ib["x0"] < ib["x1"] and ib["y0"] < ib["y1"]
    assert len(meta["calibrationPoints"]) == 3 and meta["coordinateSpace"] == "map"


def test_map_endpoints(client, fake, reg_rr):
    _link(reg_rr)
    md, png = _real_map()
    fake.map = (png, map_payload(md, {16: "Kitchen", 17: "Living room"}))
    client.post("/scan")
    r = client.get("/devices/roborock:rr1/map")
    assert r.status_code == 200
    j = r.json()
    assert j["image"]["pngBase64"] and j["image"]["width"] == 160 and j["imageUrl"].endswith("/map.png")
    assert [x["name"] for x in j["rooms"]] == ["Kitchen", "Living room"]
    assert set(j["transform"]) == {"mapToImage", "imageToMap"} and j["dock"]["map"] == {"x": 25600, "y": 25600}
    r = client.get("/devices/roborock:rr1/map.png")
    assert r.status_code == 200 and r.headers["content-type"] == "image/png" and r.content == png
    assert client.get("/devices/roborock:rr2/map").status_code == 404        # model without map
    assert client.get("/devices/nope/map").status_code == 404
    # command through the API
    r = client.post("/devices/roborock:rr1/commands",
                    json={"capability": "roomCleaning", "action": "cleanRooms", "params": {"roomIds": ["17"]}})
    assert r.status_code == 200 and fake.calls[-1] == ("send", "rr1", "app_segment_clean", [{"segments": [17], "repeat": 1}])
    r = client.post("/devices/roborock:rr2/commands",
                    json={"capability": "mopping", "action": "setWaterLevel", "params": {"level": "high"}})
    assert r.status_code == 400


def test_server_without_roborock_link(client):
    assert client.get("/integrations/roborock").json() == {"linked": False, "account": None, "linkedAt": None, "devices": []}
    assert client.post("/scan").json()["devices"] == []
    caps = client.get("/capabilities").json()["canonical"]
    assert {"roomCleaning", "zoneCleaning", "goTo", "fanSpeed", "mopping", "consumables", "cleaningStats", "vacuumMap"} <= set(caps)
