import json

import pytest
import responses

from homehub import capabilities as cap
from homehub.adapters.lg_thinq import LGThinQAdapter, region_for_country
from homehub.cloud.errors import CloudAuthError, CloudNotConfiguredError, RemoteControlDisabledError

from .fixtures import (LG_BASE, LG_DEVICES, LG_FRIDGE_PROFILE, LG_FRIDGE_STATE, LG_ROBOT_PROFILE,
                       lg_env, lg_laundry_profile, lg_laundry_state, lg_robot_state)


@pytest.fixture
def lg(monkeypatch):
    monkeypatch.setenv("LG_THINQ_TOKEN", "lg-pat")
    monkeypatch.setenv("LG_THINQ_CLIENT_ID", "homehub-test-client")
    return LGThinQAdapter()


def _register(rs, washer_remote=True):
    rs.get(f"{LG_BASE}/devices", json=lg_env(LG_DEVICES))
    rs.get(f"{LG_BASE}/devices/lg-washer/profile", json=lg_env(lg_laundry_profile("washerOperationMode")))
    rs.get(f"{LG_BASE}/devices/lg-washer/state", json=lg_env(lg_laundry_state(remote=washer_remote)))
    rs.get(f"{LG_BASE}/devices/lg-dryer/profile", json=lg_env(lg_laundry_profile("dryerOperationMode")))
    rs.get(f"{LG_BASE}/devices/lg-dryer/state", json=lg_env(lg_laundry_state("PAUSE", remote=False)))
    rs.get(f"{LG_BASE}/devices/lg-fridge/profile", json=lg_env(LG_FRIDGE_PROFILE))
    rs.get(f"{LG_BASE}/devices/lg-fridge/state", json=lg_env(LG_FRIDGE_STATE))
    rs.get(f"{LG_BASE}/devices/lg-robot/profile", json=lg_env(LG_ROBOT_PROFILE))
    rs.get(f"{LG_BASE}/devices/lg-robot/state", json=lg_env(lg_robot_state()))


def _devices(lg):
    return {d.meta["cloudId"]: d for d in lg.list_devices()}


def _last_post(rs):
    return [c for c in rs.calls if c.request.method == "POST"][-1]


def test_region_mapping_and_default_country(monkeypatch):
    assert region_for_country("KR") == "kic"
    assert region_for_country("US") == "aic"
    assert region_for_country("DE") == "eic"
    a = LGThinQAdapter()
    assert a.country == "KR" and a.base_url == "https://api-kic.lgthinq.com"
    monkeypatch.setenv("LG_THINQ_COUNTRY", "us")
    assert LGThinQAdapter().base_url == "https://api-aic.lgthinq.com"


def test_disabled_without_token():
    a = LGThinQAdapter()
    assert a.enabled() is False
    with pytest.raises(CloudNotConfiguredError, match="LG_THINQ_TOKEN"):
        a.list_devices()


@responses.activate
def test_list_devices_headers_and_kinds(lg):
    _register(responses)
    devs = _devices(lg)
    assert {k: d.kind for k, d in devs.items()} == {
        "lg-washer": "washer", "lg-dryer": "dryer", "lg-fridge": "refrigerator",
        "lg-robot": "vacuum", "lg-styler": "styler"}
    assert devs["lg-styler"].controllable is False            # unmapped type listed passively
    h = responses.calls[0].request.headers
    assert h["Authorization"] == "Bearer lg-pat"
    assert h["x-country"] == "KR" and h["x-client-id"] == "homehub-test-client"
    assert h["x-api-key"] and h["x-service-phase"] == "OP"
    assert len(h["x-message-id"]) == 22
    assert responses.calls[1].request.headers["x-message-id"] != h["x-message-id"]
    assert "x-conditional-control" not in h


@responses.activate
def test_washer_mapping_and_control(lg):
    _register(responses)
    w = _devices(lg)["lg-washer"]
    inst = w.capabilities[cap.WASHER]
    assert inst.state == {"machineState": "run", "jobState": "running", "remainingMinutes": 65,
                          "completionTime": None, "remoteControlEnabled": True}
    assert inst.actions == ["start", "pause", "stop"]
    assert w.meta["location"] == "MAIN"

    responses.post(f"{LG_BASE}/devices/lg-washer/control", json=lg_env({}))
    lg.execute(w, cap.WASHER, "start", {})
    call = _last_post(responses)
    assert json.loads(call.request.body) == {"location": {"locationName": "MAIN"},
                                             "operation": {"washerOperationMode": "START"}}
    assert call.request.headers["x-conditional-control"] == "true"
    lg.execute(w, cap.WASHER, "pause", {})
    assert json.loads(_last_post(responses).request.body)["operation"] == {"washerOperationMode": "STOP"}


@responses.activate
def test_washer_start_refused_when_remote_disabled(lg):
    _register(responses, washer_remote=False)
    w = _devices(lg)["lg-washer"]
    responses.post(f"{LG_BASE}/devices/lg-washer/control", json=lg_env({}))
    with pytest.raises(RemoteControlDisabledError):
        lg.execute(w, cap.WASHER, "start", {})
    assert not [c for c in responses.calls if c.request.method == "POST"]


@responses.activate
def test_vendor_remote_off_error_code_maps_to_refusal(lg):
    _register(responses)
    w = _devices(lg)["lg-washer"]
    responses.post(f"{LG_BASE}/devices/lg-washer/control", status=400,
                   json={"error": {"code": "2301", "message": "Command not supported in remote off"}})
    with pytest.raises(RemoteControlDisabledError, match="2301"):
        lg.execute(w, cap.WASHER, "stop", {})


@responses.activate
def test_dryer_mapping_and_control(lg):
    _register(responses)
    d = _devices(lg)["lg-dryer"]
    s = d.capabilities[cap.DRYER].state
    assert s["machineState"] == "pause" and s["remoteControlEnabled"] is False
    with pytest.raises(RemoteControlDisabledError):
        lg.execute(d, cap.DRYER, "start", {})
    responses.post(f"{LG_BASE}/devices/lg-dryer/control", json=lg_env({}))
    lg.execute(d, cap.DRYER, "stop", {})
    assert json.loads(_last_post(responses).request.body)["operation"] == {"dryerOperationMode": "POWER_OFF"}


@responses.activate
def test_fridge_mapping_and_control(lg):
    _register(responses)
    f = _devices(lg)["lg-fridge"]
    inst = f.capabilities[cap.REFRIGERATION]
    assert inst.state["fridgeSetpoint"] == 3 and inst.state["freezerSetpoint"] == -20
    assert inst.state["fridgeTemperature"] is None           # not exposed by ThinQ Connect
    assert inst.state["doorOpen"] is True and inst.state["doors"] == {"main": True}
    assert inst.state["rapidCooling"] is True and inst.state["rapidFreezing"] is False
    assert set(inst.actions) == {"setFridgeSetpoint", "setFreezerSetpoint", "setRapidCooling", "setRapidFreezing"}

    responses.post(f"{LG_BASE}/devices/lg-fridge/control", json=lg_env({}))
    lg.execute(f, cap.REFRIGERATION, "setFridgeSetpoint", {"temperature": 4})
    assert json.loads(_last_post(responses).request.body) == {
        "temperatureInUnits": {"locationName": "FRIDGE", "targetTemperatureC": 4}}
    lg.execute(f, cap.REFRIGERATION, "setRapidFreezing", {"enabled": True})
    assert json.loads(_last_post(responses).request.body) == {"refrigeration": {"rapidFreeze": True}}


@responses.activate
def test_robot_mapping_and_control(lg):
    _register(responses)
    r = _devices(lg)["lg-robot"]
    inst = r.capabilities[cap.VACUUM]
    assert inst.state["status"] == "paused" and inst.state["battery"] == 76
    assert inst.state["cleaningModes"] == ["ZIGZAG", "SECTOR_BASE"]
    assert inst.actions == ["start", "pause", "dock"]
    responses.post(f"{LG_BASE}/devices/lg-robot/control", json=lg_env({}))
    lg.execute(r, cap.VACUUM, "start", {})            # paused -> RESUME
    assert json.loads(_last_post(responses).request.body) == {"operation": {"cleanOperationMode": "RESUME"}}
    lg.execute(r, cap.VACUUM, "dock", {})
    assert json.loads(_last_post(responses).request.body) == {"operation": {"cleanOperationMode": "HOMING"}}


@responses.activate
def test_invalid_token_error(lg):
    responses.get(f"{LG_BASE}/devices", status=401, json={"error": {"code": "1103", "message": "Invalid token"}})
    with pytest.raises(CloudAuthError):
        lg.list_devices()
