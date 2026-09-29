import pytest
import responses
from fastapi.testclient import TestClient

from homehub import capabilities as cap
from homehub import mappings, server
from homehub.manager import DeviceManager

from .fixtures import ST_BASE, ST_DRYER, ST_DRYER_STATUS


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(server, "manager", DeviceManager())
    monkeypatch.setattr(server, "_register_bonjour", lambda: (None, None))
    with TestClient(server.app) as c:
        yield c


def test_new_capabilities_are_mapped():
    for key in (cap.WASHER, cap.DRYER, cap.REFRIGERATION):
        assert key in cap.CANONICAL
        d = mappings.describe(key)
        assert d["smartthings"] and d["matter"]
    assert mappings.describe(cap.WASHER)["smartthings"] == "washerOperatingState"
    assert "setCleaningMode" in cap.CANONICAL[cap.VACUUM].actions
    cap.validate_action(cap.REFRIGERATION, "setFreezerSetpoint")


def test_endpoints_without_tokens(client):
    h = client.get("/health").json()
    assert h["ok"] and h["integrations"] == {"samsung_local": True, "smartthings": False, "lg_thinq": False, "roborock": False}
    caps = client.get("/capabilities").json()
    assert {"washer", "dryer", "refrigeration"} <= set(caps["canonical"])
    assert client.get("/devices").json() == {"devices": []}
    i = client.get("/integrations").json()
    assert i["integrations"]["lg_thinq"]["type"] == "cloud"


@responses.activate
def test_cloud_scan_and_remote_disabled_is_403(client, monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat")
    responses.get(f"{ST_BASE}/devices", json={"items": [ST_DRYER]})
    responses.get(f"{ST_BASE}/devices/dryer-1/status", json=ST_DRYER_STATUS)
    r = client.post("/scan", params={"lan": "false"})
    assert r.status_code == 200
    ids = [d["id"] for d in r.json()["devices"]]
    assert ids == ["smartthings:dryer-1"]
    r = client.post("/devices/smartthings:dryer-1/commands", json={"capability": "dryer", "action": "start"})
    assert r.status_code == 403 and "Remote Start" in r.json()["detail"]


def test_curtain_capability_is_canonical_and_mapped():
    assert cap.CURTAIN in cap.CANONICAL
    spec = cap.CANONICAL[cap.CURTAIN]
    assert set(spec.actions) == {"open", "close", "stop", "setPosition"} and spec.ui_hint == "curtain-controls"
    cap.validate_action(cap.CURTAIN, "setPosition")
    d = mappings.describe(cap.CURTAIN)
    assert d["smartthings"] == "windowShade" and d["smartthingsExtra"] == ["windowShadeLevel"]
    assert d["matter"] == {"cluster": "WindowCovering", "id": "0x102"}
