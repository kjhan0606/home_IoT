import json

import pytest
import responses

from homehub import capabilities as cap
from homehub.adapters.smartthings import SmartThingsAdapter
from homehub.cloud.errors import CloudAuthError, CloudNotConfiguredError, RemoteControlDisabledError

from .fixtures import (ST_BASE, st_attr, st_component, ST_DRYER, ST_DRYER_STATUS, ST_FRIDGE, ST_FRIDGE_STATUS, ST_TV,
                       ST_TV_STATUS, ST_VACUUM, ST_VACUUM_STATUS, ST_WASHER, st_washer_status)


@pytest.fixture
def st(monkeypatch):
    monkeypatch.setenv("SMARTTHINGS_TOKEN", "pat-123")
    return SmartThingsAdapter()


def _register_all(rs, washer_remote="true"):
    rs.get(f"{ST_BASE}/devices", json={
        "items": [ST_TV, ST_WASHER, ST_DRYER],
        "_links": {"next": {"href": f"{ST_BASE}/devices?page=2"}},
    }, match=[responses.matchers.query_string_matcher("")])
    rs.get(f"{ST_BASE}/devices", json={"items": [ST_FRIDGE, ST_VACUUM], "_links": {}},
           match=[responses.matchers.query_param_matcher({"page": "2"})])
    rs.get(f"{ST_BASE}/devices/tv-1/status", json=ST_TV_STATUS)
    rs.get(f"{ST_BASE}/devices/washer-1/status", json=st_washer_status(washer_remote))
    rs.get(f"{ST_BASE}/devices/dryer-1/status", json=ST_DRYER_STATUS)
    rs.get(f"{ST_BASE}/devices/fridge-1/status", json=ST_FRIDGE_STATUS)
    rs.get(f"{ST_BASE}/devices/vac-1/status", json=ST_VACUUM_STATUS)


def _devices(st):
    return {d.meta["cloudId"]: d for d in st.list_devices()}


def _last_command(rs):
    call = [c for c in rs.calls if c.request.method == "POST"][-1]
    return json.loads(call.request.body)["commands"][0]


def test_disabled_without_token():
    a = SmartThingsAdapter()
    assert a.enabled() is False
    with pytest.raises(CloudNotConfiguredError, match="SMARTTHINGS_TOKEN"):
        a.list_devices()


@responses.activate
def test_list_devices_paginates_and_sends_bearer(st):
    _register_all(responses)
    devs = _devices(st)
    assert set(devs) == {"tv-1", "washer-1", "dryer-1", "fridge-1", "vac-1"}
    assert responses.calls[0].request.headers["Authorization"] == "Bearer pat-123"
    kinds = {k: d.kind for k, d in devs.items()}
    assert kinds == {"tv-1": "tv", "washer-1": "washer", "dryer-1": "dryer",
                     "fridge-1": "refrigerator", "vac-1": "vacuum"}
    assert all(d.id.startswith("smartthings:") for d in devs.values())


@responses.activate
def test_tv_status_mapping(st):
    _register_all(responses)
    tv = _devices(st)["tv-1"]
    assert tv.capabilities[cap.POWER].state == {"switch": "on"}
    assert tv.capabilities[cap.VOLUME].state == {"level": 12, "muted": False}
    assert "setLevel" in tv.capabilities[cap.VOLUME].actions
    assert tv.capabilities[cap.CHANNEL].state["channel"] == "11"
    assert tv.capabilities[cap.MEDIA_INPUT].state == {"sources": ["digitalTv", "HDMI1", "HDMI2"], "selected": "HDMI1"}
    assert tv.meta["match"]["model"] == "UN55KS8500FXZA"


@responses.activate
@pytest.mark.parametrize("capability,action,params,expected", [
    (cap.POWER, "turnOff", {}, ("switch", "off", [])),
    (cap.POWER, "toggle", {}, ("switch", "off", [])),          # state is "on"
    (cap.VOLUME, "setLevel", {"level": 30}, ("audioVolume", "setVolume", [30])),
    (cap.VOLUME, "volumeUp", {}, ("audioVolume", "volumeUp", [])),
    (cap.VOLUME, "mute", {}, ("audioMute", "mute", [])),
    (cap.CHANNEL, "setChannel", {"channel": 7}, ("tvChannel", "setTvChannel", ["7"])),
    (cap.MEDIA_INPUT, "select", {"source": "HDMI2"}, ("mediaInputSource", "setInputSource", ["HDMI2"])),
    (cap.MEDIA_PLAYBACK, "pause", {}, ("mediaPlayback", "pause", [])),
])
def test_tv_command_translation(st, capability, action, params, expected):
    _register_all(responses)
    responses.post(f"{ST_BASE}/devices/tv-1/commands", json={"results": [{"status": "ACCEPTED"}]})
    tv = _devices(st)["tv-1"]
    res = st.execute(tv, capability, action, params)
    assert res["ok"]
    c = _last_command(responses)
    assert (c["capability"], c["command"], c["arguments"]) == expected
    assert c["component"] == "main"


@responses.activate
def test_washer_mapping_and_commands(st):
    _register_all(responses)
    w = _devices(st)["washer-1"]
    s = w.capabilities[cap.WASHER].state
    assert s["machineState"] == "run" and s["jobState"] == "rinse"
    assert s["remainingMinutes"] == 42 and s["remoteControlEnabled"] is True
    assert w.capabilities[cap.WASHER].actions == ["start", "pause", "stop"]

    responses.post(f"{ST_BASE}/devices/washer-1/commands", json={"results": []})
    st.execute(w, cap.WASHER, "start", {})
    assert _last_command(responses)["arguments"] == ["run"]
    st.execute(w, cap.WASHER, "pause", {})
    assert (_last_command(responses)["capability"], _last_command(responses)["arguments"]) == ("washerOperatingState", ["pause"])


@responses.activate
def test_washer_start_refused_when_remote_disabled_live(st):
    # Scan saw remote enabled; user switched it off since -> live re-read refuses.
    _register_all(responses)
    w = _devices(st)["washer-1"]
    responses.replace(responses.GET, f"{ST_BASE}/devices/washer-1/status", json=st_washer_status("false"))
    responses.post(f"{ST_BASE}/devices/washer-1/commands", json={})
    with pytest.raises(RemoteControlDisabledError, match="Remote Start"):
        st.execute(w, cap.WASHER, "start", {})
    assert not [c for c in responses.calls if c.request.method == "POST"]
    # pause/stop are still forwarded (vendor decides)
    st.execute(w, cap.WASHER, "stop", {})
    assert _last_command(responses)["arguments"] == ["stop"]


@responses.activate
def test_dryer_mapping_and_refusal(st):
    _register_all(responses)
    d = _devices(st)["dryer-1"]
    s = d.capabilities[cap.DRYER].state
    assert s == {"machineState": "stop", "jobState": "none", "remainingMinutes": 0,
                 "completionTime": "2020-01-01T00:00:00Z", "remoteControlEnabled": False}
    with pytest.raises(RemoteControlDisabledError):
        st.execute(d, cap.DRYER, "start", {})


@responses.activate
def test_fridge_mapping_and_commands(st):
    _register_all(responses)
    f = _devices(st)["fridge-1"]
    inst = f.capabilities[cap.REFRIGERATION]
    assert inst.state["fridgeTemperature"] == 4 and inst.state["freezerSetpoint"] == -19
    assert inst.state["unit"] == "C"
    assert inst.state["doors"] == {"main": False, "cooler": True, "freezer": False}
    assert inst.state["doorOpen"] is True
    assert inst.state["rapidCooling"] is False and inst.state["rapidFreezing"] is True
    assert set(inst.actions) == {"setFridgeSetpoint", "setFreezerSetpoint", "setRapidCooling", "setRapidFreezing"}

    responses.post(f"{ST_BASE}/devices/fridge-1/commands", json={})
    st.execute(f, cap.REFRIGERATION, "setFreezerSetpoint", {"temperature": -20})
    c = _last_command(responses)
    assert (c["component"], c["capability"], c["command"], c["arguments"]) == \
        ("freezer", "thermostatCoolingSetpoint", "setCoolingSetpoint", [-20])
    st.execute(f, cap.REFRIGERATION, "setRapidCooling", {"enabled": True})
    c = _last_command(responses)
    assert (c["capability"], c["command"], c["arguments"]) == ("refrigeration", "setRapidCooling", ["on"])
    with pytest.raises(ValueError):
        st.execute(f, cap.REFRIGERATION, "setFridgeSetpoint", {"temperature": "cold"})


@responses.activate
def test_vacuum_mapping_and_commands(st):
    _register_all(responses)
    v = _devices(st)["vac-1"]
    s = v.capabilities[cap.VACUUM].state
    assert s["status"] == "charging" and s["battery"] == 87 and s["cleaningMode"] == "auto"
    responses.post(f"{ST_BASE}/devices/vac-1/commands", json={})
    st.execute(v, cap.VACUUM, "start", {})
    assert _last_command(responses)["arguments"] == ["cleaning"]
    st.execute(v, cap.VACUUM, "dock", {})
    assert _last_command(responses)["arguments"] == ["homing"]
    st.execute(v, cap.VACUUM, "setCleaningMode", {"mode": "repeat"})
    c = _last_command(responses)
    assert (c["capability"], c["arguments"]) == ("robotCleanerCleaningMode", ["repeat"])


@responses.activate
def test_401_raises_auth_error(st):
    responses.get(f"{ST_BASE}/devices", status=401, json={"error": "invalid_token"})
    with pytest.raises(CloudAuthError, match="24 h"):
        st.list_devices()


@responses.activate
def test_refresh_updates_state(st):
    _register_all(responses)
    w = _devices(st)["washer-1"]
    responses.replace(responses.GET, f"{ST_BASE}/devices/washer-1/status",
                      json=st_washer_status("true", machine="pause"))
    st.refresh_state(w)
    assert w.capabilities[cap.WASHER].state["machineState"] == "pause"


# ------------------------------------------------ curtain / blind + light --
ST_CURTAIN = {
    "deviceId": "cur-1", "label": "Bedroom Blind", "manufacturerName": "SmartThings",
    "components": [st_component("main", ["windowShade", "windowShadeLevel", "switchLevel"], ["Blind"])],
}


def st_curtain_status(shade="open", level=100, supported=("open", "close", "pause")):
    return {"components": {"main": {
        "windowShade": {"windowShade": st_attr(shade), "supportedWindowShadeCommands": st_attr(list(supported))},
        "windowShadeLevel": {"shadeLevel": st_attr(level, "%")},
    }}}


ST_LEVEL_ONLY = {
    "deviceId": "cur-2", "label": "Level-only shade", "manufacturerName": "Acme",
    "components": [st_component("main", ["windowShadeLevel"], ["Curtain"])],
}
ST_LIGHT = {
    "deviceId": "light-1", "label": "Bedroom Light", "manufacturerName": "Acme",
    "components": [st_component("main", ["switch", "switchLevel"], ["Light"])],
}
ST_LEGACY_LIGHT = {
    "deviceId": "light-2", "label": "Legacy Light", "manufacturerName": "Acme",
    "components": [st_component("main", ["light"], ["Light"])],
}


@responses.activate
def test_curtain_mapping_and_commands(st):
    responses.get(f"{ST_BASE}/devices", json={"items": [ST_CURTAIN, ST_LEVEL_ONLY]})
    responses.get(f"{ST_BASE}/devices/cur-1/status", json=st_curtain_status("partially open", 40))
    responses.get(f"{ST_BASE}/devices/cur-2/status",
                  json={"components": {"main": {"windowShadeLevel": {"shadeLevel": st_attr(0)}}}})
    devs = _devices(st)
    c = devs["cur-1"]
    assert c.kind == "curtain"                       # from the Blind category
    inst = c.capabilities[cap.CURTAIN]
    assert set(inst.actions) == {"open", "close", "stop", "setPosition"}
    assert inst.state == {"position": 40, "status": "partial"}

    for action, params, expected in [
        ("open", {}, ("windowShade", "open", [])),
        ("close", {}, ("windowShade", "close", [])),
        ("stop", {}, ("windowShade", "pause", [])),
        ("setPosition", {"position": 25}, ("windowShadeLevel", "setShadeLevel", [25])),
    ]:
        responses.post(f"{ST_BASE}/devices/cur-1/commands", json={"results": [{"status": "ACCEPTED"}]})
        st.execute(c, cap.CURTAIN, action, params)
        cmd = _last_command(responses)
        assert (cmd["capability"], cmd["command"], cmd["arguments"]) == expected
    for bad in ({"position": 101}, {"position": -1}, {}, {"position": "x"}):
        with pytest.raises(ValueError):
            st.execute(c, cap.CURTAIN, "setPosition", bad)

    # a shade with only windowShadeLevel: open/close are emulated with 100 / 0, kind inferred from caps
    lvl = devs["cur-2"]
    assert lvl.kind == "curtain" and lvl.capabilities[cap.CURTAIN].state == {"position": 0, "status": "closed"}
    responses.post(f"{ST_BASE}/devices/cur-2/commands", json={"results": []})
    st.execute(lvl, cap.CURTAIN, "open", {})
    cmd = _last_command(responses)
    assert (cmd["capability"], cmd["command"], cmd["arguments"]) == ("windowShadeLevel", "setShadeLevel", [100])
    st.execute(lvl, cap.CURTAIN, "close", {})
    assert _last_command(responses)["arguments"] == [0]


@responses.activate
def test_curtain_respects_supported_commands_and_refresh(st):
    responses.get(f"{ST_BASE}/devices", json={"items": [ST_CURTAIN]})
    responses.get(f"{ST_BASE}/devices/cur-1/status",
                  json=st_curtain_status("closed", 0, supported=("open", "close")))
    c = _devices(st)["cur-1"]
    assert "stop" not in c.capabilities[cap.CURTAIN].actions      # this shade cannot pause
    responses.replace(responses.GET, f"{ST_BASE}/devices/cur-1/status", json=st_curtain_status("opening", 70))
    st.refresh_state(c)
    assert c.capabilities[cap.CURTAIN].state == {"position": 70, "status": "opening"}


@responses.activate
def test_light_and_legacy_light_map_to_power(st):
    responses.get(f"{ST_BASE}/devices", json={"items": [ST_LIGHT, ST_LEGACY_LIGHT]})
    responses.get(f"{ST_BASE}/devices/light-1/status", json={"components": {"main": {
        "switch": {"switch": st_attr("on")}, "switchLevel": {"level": st_attr(80)}}}})
    responses.get(f"{ST_BASE}/devices/light-2/status", json={"components": {"main": {
        "light": {"switch": st_attr("off")}}}})
    devs = _devices(st)
    assert devs["light-1"].kind == "light" and devs["light-1"].capabilities[cap.POWER].state == {"switch": "on"}
    assert cap.BRIGHTNESS in devs["light-1"].capabilities
    legacy = devs["light-2"]
    assert legacy.capabilities[cap.POWER].state == {"switch": "off"}
    responses.post(f"{ST_BASE}/devices/light-2/commands", json={"results": []})
    st.execute(legacy, cap.POWER, "turnOn", {})
    cmd = _last_command(responses)
    assert (cmd["capability"], cmd["command"]) == ("light", "on")     # legacy capability keeps its own name
    responses.post(f"{ST_BASE}/devices/light-1/commands", json={"results": []})
    st.execute(devs["light-1"], cap.POWER, "turnOff", {})
    assert (_last_command(responses)["capability"], _last_command(responses)["command"]) == ("switch", "off")
